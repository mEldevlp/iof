"use strict";

// Страница «Телеграм бот»: выключатель и токен, настройки, админы и приглашения. Данные: GET api/bot
// (bot.json без хэшей приглашений, есть ли токен, состояние потока бота в панели), изменения:
// POST api/bot (iof bot сразу, без очереди задач). Токен панель не отдаёт, код приглашения
// приходит один раз в ответе на invite и живёт только в окне диалога

const ROLES = { main: "главный", regular: "обычный" };
const ROLE_HINTS = {
  main: "Главный: просмотр, ссылки Hysteria2 и действия из бота, если они разрешены в настройках, все уведомления.",
  regular: "Обычный: просмотр и ссылки Hysteria2, без действий; уведомления все, кроме новых админов.",
};
// Типы уведомлений: как NOTIFY в BOT_PY iof.sh (сверяет ci/lint.sh). [тип, колонка, когда приходит]
const NOTIFY = [
  ["nodes", "Узлы", "узел перестал работать или снова в порядке: <code>iof check</code> из cron"],
  ["audit", "Аудит", "проверка из cron (<code>iof audit cron</code>) оказалась хуже прошлой"],
  ["nightly", "Ночное обслуживание", "запущены обновление пакетов и перезагрузка (<code>iof-nightly</code>): на скольких узлах и где не вышло"],
  ["updates", "Обновления iof", "на GitHub вышла новая версия iof, один раз на версию: <code>iof check</code> раз в сутки"],
  ["ru", "Доступ к РФ", "с узла отвечает меньше половины российских серверов (RU_TARGETS), а зарубежные отвечают, и когда снова отвечают: <code>iof check</code> раз в сутки"],
  ["admins", "Новые админы", "по приглашению добавился админ: утёкший код видно сразу. Только главным"],
];
const NOTIFY_MAIN = ["admins"];
const TOKEN_RE = /^[0-9]{1,20}:[A-Za-z0-9_-]{20,100}$/;

const bot = { data: null, busy: false, timer: null, shown: {} };


// Форматирование

function fmtWhen(ts) {
  const d = new Date(ts * 1000);
  const today = d.toDateString() === new Date().toDateString();
  const time = d.toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });
  return today ? `сегодня в ${time}` : `${d.toLocaleDateString("ru-RU", { day: "2-digit", month: "2-digit" })} в ${time}`;
}

// С какого времени: «с 12:25» сегодня, иначе «с 10.11 12:25»
function fmtSince(ts) {
  const d = new Date(ts * 1000);
  const time = d.toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });
  return d.toDateString() === new Date().toDateString() ? `с ${time}`
    : `с ${d.toLocaleDateString("ru-RU", { day: "2-digit", month: "2-digit" })} ${time}`;
}

function fmtDate(ts) {
  return ts ? new Date(ts * 1000).toLocaleDateString("ru-RU") : "—";
}

// Сколько осталось до времени ts: «через 23 ч», «через 40 мин»
function fmtLeft(ts, now) {
  const s = Math.max(0, ts - now);
  if (s >= 3600) return `через ${Math.floor(s / 3600)} ч`;
  return `через ${Math.max(1, Math.round(s / 60))} мин`;
}

// "+0300" -> "UTC+03:00"
function fmtTz(tz) {
  const m = /^([+-])(\d\d)(\d\d)$/.exec(tz || "");
  return m ? `UTC${m[1]}${m[2]}:${m[3]}` : "";
}

function botName(d) {
  const name = (d.thread && d.thread.username) || (d.config && d.config.username);
  return name ? `@${name}` : "бот";
}

// Имя в Telegram текстом: внешних ссылок в панели нет (ci/lint.sh, правило CSP)
function tgName(name) {
  return `@${esc(name)}`;
}


// Состояние бота: (уровень, заголовок, пояснение, крутится ли). Поток бота замечает изменение
// bot.json за пару секунд, а выключение с настоящим Telegram — только после ответа на текущий
// опрос (до 50 с), поэтому промежуточные состояния показываются отдельно

function stateView(d) {
  const c = d.config, t = d.thread;
  if (!t) {
    return ["crit", "Бот не работает: модуль не загрузился",
      `${d.thread_error || "причина в журнале панели"}. Панель работает без бота. Переустанови: <code>sudo iof update</code>, подробности: <code>journalctl -u iof-web</code>`];
  }
  if (!c) return ["crit", "bot.json не читается", esc(d.config_error)];
  if (t.state === "migrate") {
    return ["warn", "Не работает: идёт перенос", "Этот сервер принимает управление. Бот запустится сам после завершения переноса: иначе один токен опрашивали бы два сервера."];
  }
  if (!c.enabled) {
    if (["running", "error", "conflict", "starting"].includes(t.state)) {
      return ["none", "Выключается…", "Бот закончит текущий запрос к Telegram, это до 50 секунд", true];
    }
    return ["none", "Выключен", d.token ? "Включи выключателем справа вверху." : "Сначала токен: создай бота у @BotFather и вставь токен ниже."];
  }
  if (!d.token || t.state === "no_token") {
    return ["warn", "Нет токена", "Бот включён, но токена нет. Создай бота у @BotFather и вставь его токен ниже."];
  }
  const since = t.since ? ` ${fmtSince(t.since)}` : "";
  if (t.state === "running") return ["good", "Работает", `${esc(botName(d))} отвечает админам в личном чате. Работает${since}.`];
  if (t.state === "conflict") {
    return ["crit", "Токен опрашивает кто-то ещё (409)", `Telegram отдаёт сообщения только одному опросу, а этот токен опрашивает ещё
      другая программа или другой сервер. Останови её или выпусти новый токен у @BotFather (/revoke) и вставь его ниже. Так${since}.`];
  }
  if (t.state === "error") {
    const title = /не принял токен/.test(t.error || "") ? "Telegram не принял токен"
      : /^нет связи/.test(t.error || "") ? "Нет связи с Telegram" : "Ошибка бота";
    const text = String(t.error || "");
    return ["crit", title, `${esc(text.charAt(0).toUpperCase() + text.slice(1))}. Так${since}, бот повторяет попытки сам, пауза растёт до минуты.`];
  }
  return ["none", "Запускается…", "Бот проверяет токен и ставит меню команд", true];
}

function renderState(d) {
  const [lvl, title, sub, spin] = stateView(d);
  const el = $("#bot-state");
  el.className = `health${lvl === "none" ? "" : ` ${lvl}`}`;
  const mark = spin ? '<span class="spinner big-ico" aria-hidden="true"></span>' : icon(lvl, "ico big-ico");
  el.innerHTML = `${mark}<div><h2>${esc(title)}</h2><p class="sub">${sub}</p></div>`;

  const c = d.config || {}, t = d.thread;
  const name = (t && t.username) || c.username;
  const admins = c.admins || [], mains = admins.filter((a) => a.role === "main").length;
  const rows = [
    ["Бот", name ? tgName(name) : '<span class="muted">появится, когда будет токен</span>'],
    ["Админов", admins.length ? `${admins.length}: главных ${mains}, обычных ${admins.length - mains}` : '<span class="muted">нет</span>'],
  ];
  if (t && t.api) rows.push(["Bot API", `<span class="mono">${esc(t.api)}</span> <span class="muted">(IOF_TG_API в web.env)</span>`]);
  $("#bot-kv").innerHTML = rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v}</dd>`).join("");

  $("#bot-enable").checked = !!c.enabled;
  $("#token-label").textContent = d.token ? "Новый токен от @BotFather" : "Токен от @BotFather";
  $("#f-token").placeholder = d.token ? "сохранён; введи новый, чтобы заменить" : "123456789:AAF…";
  $("#token-hint").innerHTML = d.token
    ? "Панель токен не показывает. Новый проверяется запросом getMe и заменяет прежний."
    : "У @BotFather: команда /newbot, имя и username бота. Он пришлёт токен — вставь его сюда.";
  $("#token-del").hidden = !d.token;
}

// Настройки перерисовываются, только когда поменялись: иначе опрос сбросил бы недописанное время
function renderSettings(d) {
  const c = d.config;
  $("#quiet-tz").textContent = d.tz ? `Время сервера, ${fmtTz(d.tz)}.` : "Время сервера.";
  if (!c) return;
  const key = JSON.stringify([c.actions, c.hy2_links, c.quiet]);
  if (bot.shown.settings === key) return;
  bot.shown.settings = key;
  $("#set-actions").checked = c.actions;
  $("#set-links").checked = c.hy2_links;
  $("#set-quiet").checked = !!c.quiet;
  if (c.quiet) {
    $("#quiet-from").value = c.quiet.from;
    $("#quiet-to").value = c.quiet.to;
  }
  quietChanged();
}

// «Сохранить» у тихих часов — только когда они включены и время отличается от сохранённого
function quietChanged() {
  const q = bot.data && bot.data.config && bot.data.config.quiet;
  const on = $("#set-quiet").checked;
  $("#quiet-save").hidden = !on || !q || (q.from === $("#quiet-from").value && q.to === $("#quiet-to").value);
}

function renderAdmins(d) {
  const c = d.config;
  if (!c) return;
  const key = JSON.stringify([c.admins, c.invites, c.username]);
  if (bot.shown.admins === key) return;
  bot.shown.admins = key;
  const mains = c.admins.filter((a) => a.role === "main").length;
  $("#admins-count").textContent = c.admins.length || "";
  $("#admins").innerHTML = c.admins.length ? `<table class="admins">
    <thead><tr><th>Админ</th><th>ID</th><th>Роль</th><th>Звук в тихие часы</th><th>Добавлен</th><th><span class="sr-only">Удалить</span></th></tr></thead>
    <tbody>${c.admins.map((a) => `<tr>
      <td class="cell-name"><span class="item-title">${esc(a.name || "без имени")}</span>${a.username ? `<span class="sub-line">${tgName(a.username)}</span>` : ""}</td>
      <td data-label="ID"><span class="mono">${a.id}</span></td>
      <td data-label="Роль"><select data-role="${a.id}" data-lock aria-label="Роль ${esc(a.name)}">
        ${Object.entries(ROLES).map(([v, t]) => `<option value="${v}"${a.role === v ? " selected" : ""}>${t}</option>`).join("")}
      </select></td>
      <td data-label="Звук в тихие часы"><label class="switch"><input type="checkbox" role="switch" data-sound="${a.id}" data-lock${a.sound ? " checked" : ""}
        aria-label="Звук в тихие часы: ${esc(a.name)}"><span class="switch-track" aria-hidden="true"></span><span>${a.sound ? "со звуком" : "без звука"}</span></label></td>
      <td data-label="Добавлен">${fmtDate(a.added)}</td>
      <td class="cell-act"><button class="btn small danger" type="button" data-del="${a.id}" data-lock>Удалить</button></td>
    </tr>`).join("")}</tbody></table>`
    : `<p class="empty">Админов пока нет. Нажми «Добавить админа», выбери роль и передай код будущему админу:
        он отправит его боту в личном чате и станет админом.</p>`;
  if (c.admins.length && !mains) {
    $("#admins").insertAdjacentHTML("beforeend", `<p class="note warn admins-note">${icon("warn")}<span>Главных админов нет: действия из бота запускать некому.
      Сделай главным кого-то из списка или пригласи нового.</span></p>`);
  }

  $("#admins").querySelectorAll("[data-role]").forEach((s) => s.addEventListener("change", () => {
    const a = c.admins.find((x) => String(x.id) === s.dataset.role);
    if (a.role === "main" && s.value !== "main" && mains === 1
        && !confirm(`${a.name || a.id} — последний главный админ. Без главных действия из бота запускать некому. Сменить роль?`)) {
      s.value = a.role;
      return;
    }
    act({ action: "admin_set", id: a.id, role: s.value });
  }));
  $("#admins").querySelectorAll("[data-sound]").forEach((i) => i.addEventListener("change", () => {
    act({ action: "admin_set", id: Number(i.dataset.sound), sound: i.checked });
  }));
  $("#admins").querySelectorAll("[data-del]").forEach((b) => b.addEventListener("click", () => {
    const a = c.admins.find((x) => String(x.id) === b.dataset.del);
    const last = a.role === "main" && mains === 1 ? " Это последний главный админ." : "";
    if (confirm(`Удалить админа ${a.name || a.id}? Бот перестанет ему отвечать, вернуть его можно только новым приглашением.${last}`)) {
      act({ action: "admin_del", id: a.id });
    }
  }));

  const inv = c.invites;
  $("#invites-box").hidden = !inv.length;
  $("#invites-count").textContent = inv.length || "";
  $("#invites").innerHTML = inv.map((i) => `<li>
      <span class="tag">${ROLES[i.role] || i.role}</span>
      <span class="invite-when">действует до ${fmtWhen(i.expires)} · ${fmtLeft(i.expires, d.now)}</span>
      <code class="muted" title="Начало хэша кода: по нему приглашение отзывают">${esc(i.hash)}</code>
      <button class="btn small danger" type="button" data-revoke="${esc(i.hash)}" data-lock>Отозвать</button>
    </li>`).join("");
  $("#invites").querySelectorAll("[data-revoke]").forEach((b) => b.addEventListener("click", () => {
    if (confirm("Отозвать приглашение? Код перестанет действовать.")) act({ action: "invite_del", hash: b.dataset.revoke });
  }));
}

// Уведомления: галочки типов у каждого админа. У обычного нет «новых админов». notify = null (ещё не
// настраивали) значит то же, что ничего не отмечено. Перерисовка, только когда поменялись данные
function renderNotify(d) {
  const c = d.config;
  if (!c) return;
  const key = JSON.stringify([c.admins, c.enabled, d.token]);
  if (bot.shown.notify === key) return;
  bot.shown.notify = key;
  const admins = c.admins;
  const allowed = (a, k) => a.role === "main" || !NOTIFY_MAIN.includes(k);
  const anyone = admins.some((a) => (a.notify || []).length);
  const hints = [];
  if (!admins.length) hints.push("Уведомления получают админы бота: сначала добавь админа.");
  else if (!anyone) hints.push("Пока никому ничего не приходит: отметь типы. Новому админу ничего не отмечено.");
  else hints.push("Каждый админ получает отмеченные типы в личный чат с ботом. В тихие часы — без звука, кроме тех, у кого «со звуком».");
  if (!c.enabled || !d.token) hints.push("Бот выключен: без него узлы и аудит уходят в <code>TG_CHAT</code> из <code>/root/iof/iof.env</code>, если он задан, остальное не уходит.");
  $("#notify-hint").innerHTML = hints.join(" ");
  $("#notify").innerHTML = admins.length ? `<table class="admins notify">
    <thead><tr><th>Админ</th>${NOTIFY.map(([, title]) => `<th>${esc(title)}</th>`).join("")}</tr></thead>
    <tbody>${admins.map((a) => `<tr>
      <td class="cell-name"><span class="item-title">${esc(a.name || "без имени")}</span><span class="sub-line">${ROLES[a.role] || a.role}</span></td>
      ${NOTIFY.map(([k, title]) => `<td data-label="${esc(title)}">${allowed(a, k)
        ? `<input type="checkbox" data-notify="${a.id}" value="${k}" data-lock${(a.notify || []).includes(k) ? " checked" : ""}
            aria-label="${esc(title)}: ${esc(a.name || a.id)}">`
        : '<span class="muted" title="Только главным админам">—</span>'}</td>`).join("")}
    </tr>`).join("")}</tbody></table>` : "";
  $("#notify").querySelectorAll("[data-notify]").forEach((i) => i.addEventListener("change", () => {
    const id = i.dataset.notify;
    const kinds = [...$("#notify").querySelectorAll(`[data-notify="${id}"]:checked`)].map((x) => x.value);
    act({ action: "admin_set", id: Number(id), notify: kinds });
  }));
  $("#notify-types").innerHTML = NOTIFY.map(([, title, about]) => `<dt>${esc(title)}</dt><dd>${about}</dd>`).join("");
}

// Пока идёт запрос, кнопки и выключатели заблокированы. При переносе отсюда iof всё равно откажет,
// поэтому всё заблокировано сразу
function lock() {
  const d = bot.data;
  const frozen = bot.busy || !d || !d.config || (d.migrate && d.migrate.role === "source");
  document.querySelectorAll("[data-lock]").forEach((el) => { el.disabled = frozen; });
  // Включить без токена нельзя, выключить можно всегда
  if (d && d.config && !d.token && !d.config.enabled) $("#bot-enable").disabled = true;
  $("#quiet-from").disabled = $("#quiet-to").disabled = frozen || !$("#set-quiet").checked;
}

function render() {
  const d = bot.data;
  renderMigrate(d.migrate);
  renderState(d);
  renderSettings(d);
  renderAdmins(d);
  renderNotify(d);
  lock();
}

// Опрос: чаще, пока бот включается или выключается, и реже в остальное время
function schedule() {
  clearTimeout(bot.timer);
  const spin = bot.data && stateView(bot.data)[3];
  bot.timer = setTimeout(async () => {
    if (!document.hidden && !bot.busy) await load();
    schedule();
  }, spin ? 2000 : 15000);
}

async function load() {
  $("#refresh").setAttribute("aria-busy", "true");
  try {
    bot.data = DEMO ? demoGet() : await getJson("api/bot");
    $("#alert").hidden = true;
    render();
  } catch (e) {
    $("#alert").hidden = false;
    $("#alert").innerHTML = `${icon("crit")} Нет связи с панелью: ${esc(e.message)}`;
  } finally {
    $("#refresh").removeAttribute("aria-busy");
  }
}

// Изменение: iof bot на сервере, в ответе свежее состояние страницы. Ошибка — в плашке над карточками,
// а выключатели и выбор возвращаются к сохранённому
async function act(body) {
  formError("", "#action-error");
  bot.busy = true;
  lock();
  let res = null;
  try {
    res = DEMO ? await demoPost(body) : await postJson("api/bot", body);
    if (res.message) toast(res.message);
  } catch (e) {
    formError(e.message, "#action-error");
  }
  bot.busy = false;
  bot.shown = {};
  if (res && res.bot) {
    bot.data = res.bot;
    render();
  } else {
    await load();
  }
  schedule();
  return res;
}


// Токен

async function saveToken(e) {
  e.preventDefault();
  const token = $("#f-token").value.trim();
  showErrors({});
  if (!TOKEN_RE.test(token)) {
    showErrors({ "#f-token": token ? "это не токен: он выглядит как 123456789:AAF…" : "вставь токен от @BotFather" });
    return;
  }
  const res = await act({ action: "token", token });
  if (res) {
    $("#f-token").value = "";
    $("#f-token").type = "password";
    $("#toggle-token").textContent = "Показать";
  }
}

function deleteToken() {
  if (confirm("Удалить токен? Бот выключится и перестанет отвечать. Админы и настройки сохранятся.")) {
    act({ action: "token", delete: true });
  }
}


// Приглашение: роль → код в том же окне. Код живёт только в окне: закрыл — его больше нигде нет

function openInvite() {
  const d = bot.data, running = d.thread && d.thread.state === "running" && d.config.enabled;
  $("#invite-title").textContent = "Добавить админа";
  $("#invite-body").innerHTML = `
    <p>Админ добавляется приглашением: панель покажет одноразовый код, ты передашь его будущему админу,
      он отправит код боту — и станет админом.</p>
    <div class="seg" role="radiogroup" aria-label="Роль">
      <label><input type="radio" name="role" value="main"><span>Главный</span></label>
      <label><input type="radio" name="role" value="regular" checked><span>Обычный</span></label>
    </div>
    <p id="role-hint" class="hint">${ROLE_HINTS.regular}</p>
    ${running ? "" : `<p class="note warn">${icon("warn")}<span>Бот сейчас не работает: код примет только работающий бот.
      Включи его, прежде чем передавать код.</span></p>`}
    <div class="btn-row"><button id="invite-go" class="btn primary" type="button" data-lock>Создать приглашение</button></div>`;
  $("#invite-body").querySelectorAll('input[name="role"]').forEach((r) => r.addEventListener("change", () => {
    $("#role-hint").textContent = ROLE_HINTS[r.value];
  }));
  $("#invite-go").addEventListener("click", createInvite);
  $("#invite-dialog").showModal();
}

async function createInvite() {
  const role = $('#invite-body input[name="role"]:checked').value;
  const res = await act({ action: "invite", role });
  if (!res || !res.invite) {
    $("#invite-dialog").close();
    $("#invite-body").innerHTML = "";
    return;
  }
  const inv = res.invite, name = botName(bot.data);
  $("#invite-title").textContent = `Приглашение: ${ROLES[inv.role]} админ`;
  $("#invite-body").innerHTML = `
    <p class="note good">${icon("good")}<span>Код действует ${inv.expires ? `до ${fmtWhen(inv.expires)}` : "24 часа"}, один раз.
      Панель показывает его только сейчас: на сервере хранится лишь хэш.</span></p>
    <div class="dialog-field"><span>Код</span>
      <div class="cmd"><pre class="code">${esc(inv.code)}</pre><button class="btn small" type="button" data-copy="code">Копировать</button></div>
    </div>
    ${inv.link ? `<div class="dialog-field"><span>Ссылка</span>
      <div class="cmd"><pre class="code">${esc(inv.link)}</pre><button class="btn small" type="button" data-copy="link">Копировать</button></div>
    </div>` : ""}
    <p>Будущий админ отправляет этот код боту <b>${esc(name)}</b> в личном чате${inv.link ? " — или открывает ссылку, и Telegram сам отправит код по кнопке «Старт»" : ""}.</p>
    <p class="hint">Закроешь окно — код больше не увидишь. Не успел передать — отзови приглашение и создай новое.</p>`;
  $("#invite-body").querySelectorAll("[data-copy]").forEach((b) => b.addEventListener("click", async () => {
    const text = b.dataset.copy === "code" ? inv.code : inv.link;
    toast(await copyText(text) ? (b.dataset.copy === "code" ? "Код скопирован" : "Ссылка скопирована") : "Не удалось скопировать");
  }));
}


// Демо: ?demo — бот работает, ?demo=notoken, =off, =409, =neterr, =nomodule, =migrate

const DEMO_KIND = new URLSearchParams(location.search).get("demo") || "";
let demoState = null;

function demoInit() {
  const now = Date.now() / 1000;
  const s = {
    token: true,
    config: {
      enabled: true, username: "island_of_freedom_bot", actions: false, hy2_links: true,
      quiet: { from: "23:00", to: "08:00" },
      admins: [
        { id: 184467302, name: "Алексей", username: "alexey_k", role: "main", sound: true, added: now - 86400 * 12,
          notify: ["nodes", "audit", "updates", "ru", "admins"] },
        { id: 529901144, name: "Марина", username: "", role: "regular", sound: false, added: now - 86400 * 3,
          notify: ["nodes", "ru"] },
        { id: 733015920, name: "Илья", username: "ilya_ops", role: "regular", sound: false, added: now - 3600 * 20, notify: null },
      ],
      invites: [{ hash: "4f1c9a07be52", role: "regular", created: now - 3600 * 5, expires: now + 3600 * 19 }],
    },
    thread: { state: "running", error: null, since: now - 3600 * 7, username: "island_of_freedom_bot", api: null },
    thread_error: null, tz: "+0300", migrate: null,
  };
  if (DEMO_KIND === "notoken") {
    Object.assign(s, { token: false });
    Object.assign(s.config, { enabled: false, username: "", admins: [], invites: [], quiet: null });
    Object.assign(s.thread, { state: "off", error: "выключен", username: "" });
  } else if (DEMO_KIND === "off") {
    s.config.enabled = false;
    Object.assign(s.thread, { state: "off", error: "выключен" });
  } else if (DEMO_KIND === "409") {
    Object.assign(s.thread, { state: "conflict", since: now - 140,
      error: "этот токен опрашивает кто-то ещё (409): Conflict: terminated by other getUpdates request; make sure that only one bot instance is running. Останови другую программу с этим токеном или выпусти новый у @BotFather" });
  } else if (DEMO_KIND === "neterr") {
    Object.assign(s.thread, { state: "error", since: now - 600,
      error: "нет связи с https://api.telegram.org: [Errno 101] Network is unreachable" });
  } else if (DEMO_KIND === "nomodule") {
    Object.assign(s, { thread: null, thread_error: "модуль iof_bot не загрузился: SyntaxError: invalid syntax (iof_bot.py, line 212)" });
  } else if (DEMO_KIND === "migrate") {
    Object.assign(s.thread, { state: "migrate", error: "не работает, пока сервер принимает управление при переносе" });
    s.migrate = { role: "target", peer: "root@203.0.113.10", self: "", started: String(Math.floor(now - 1800)) };
  }
  return s;
}

function demoGet() {
  if (!demoState) demoState = demoInit();
  return JSON.parse(JSON.stringify({ ...demoState, config_error: null, now: Date.now() / 1000 }));
}

// Как POST api/bot: те же проверки, что у iof bot, и ответ с новым состоянием
async function demoPost(b) {
  await new Promise((r) => setTimeout(r, 300));
  const s = demoState, c = s.config, now = Date.now() / 1000;
  const fail = (text) => { throw new Error(text); };
  const admin = () => c.admins.find((a) => a.id === b.id) || fail(`админа с ID ${b.id} нет: sudo iof bot show`);
  let message = "Готово", invite = null;
  if (b.action === "token" && b.delete) {
    Object.assign(s, { token: false });
    Object.assign(c, { enabled: false, username: "" });
    Object.assign(s.thread || {}, { state: "off", error: "выключен", username: "" });
    message = "Токен удалён, бот выключен";
  } else if (b.action === "token") {
    if (/^0:/.test(b.token)) fail("Telegram не принял токен (401 Unauthorized): проверь его у @BotFather, /mybots → API Token");
    Object.assign(s, { token: true });
    c.username = "island_of_freedom_bot";
    if (s.thread) Object.assign(s.thread, { username: c.username, ...(c.enabled ? { state: "running", error: null, since: now } : {}) });
    message = `Токен сохранён: бот @${c.username}`;
  } else if (b.action === "enable") {
    if (b.on && !s.token) fail("сначала токен бота: sudo iof bot token (токен даёт @BotFather)");
    c.enabled = b.on;
    message = b.on ? `Бот включён: @${c.username}, работает внутри панели iof-web` : "Бот выключен";
    // Поток бота замечает изменение не сразу: страница покажет «включается…» или «выключается…»
    if (s.thread && !["conflict", "error", "migrate"].includes(s.thread.state)) {
      setTimeout(() => Object.assign(s.thread, c.enabled ? { state: "running", error: null, since: Date.now() / 1000 } : { state: "off", error: "выключен" }), 2500);
    }
  } else if (b.action === "set" && b.key === "quiet") {
    if (b.value === "off") {
      c.quiet = null;
      message = "Тихие часы выключены";
    } else {
      const [from, to] = b.value.split("-");
      if (from === to) fail("у тихих часов начало и конец совпадают");
      c.quiet = { from, to };
      message = `Тихие часы: ${from}–${to}, время сервера`;
    }
  } else if (b.action === "set") {
    const key = b.key === "links" ? "hy2_links" : "actions";
    c[key] = b.on;
    message = key === "actions" ? `Действия из бота: ${b.on ? "разрешены главным админам" : "выключены"}`
      : `Ссылки Hysteria2 в боте: ${b.on ? "выдаются" : "не выдаются"}`;
  } else if (b.action === "invite") {
    if (c.invites.length >= 20) fail("неиспользованных приглашений уже 20, отзови лишние: sudo iof bot invite del <хэш>");
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    const code = [...bytes].map((x) => x.toString(16).padStart(2, "0")).join("");
    const hash = [...crypto.getRandomValues(new Uint8Array(6))].map((x) => x.toString(16).padStart(2, "0")).join("");
    c.invites.push({ hash, role: b.role, created: now, expires: now + 86400 });
    invite = { code, role: b.role, hash, expires: now + 86400, link: c.username ? `https://t.me/${c.username}?start=${code}` : null };
    message = "Приглашение создано";
  } else if (b.action === "invite_del") {
    c.invites = c.invites.filter((i) => !i.hash.startsWith(b.hash));
    message = `Приглашение ${b.hash}… отозвано`;
  } else if (b.action === "admin_set" && b.notify) {
    const a = admin();
    a.notify = NOTIFY.map(([k]) => k).filter((k) => b.notify.includes(k) && (a.role === "main" || !NOTIFY_MAIN.includes(k)));
    message = `Админ ${a.id}: уведомления — ${a.notify.length ? NOTIFY.filter(([k]) => a.notify.includes(k)).map(([, t]) => t.toLowerCase()).join(", ") : "нет"}`;
  } else if (b.action === "admin_set") {
    const a = admin();
    if (b.role) {
      a.role = b.role;
      // Как iof: типы, недоступные новой роли, снимаются
      if (a.notify) a.notify = a.notify.filter((k) => a.role === "main" || !NOTIFY_MAIN.includes(k));
    } else a.sound = b.sound;
    message = b.role ? `Админ ${a.id}: роль ${ROLES[a.role]}` : `Админ ${a.id}: уведомления в тихие часы ${a.sound ? "со звуком" : "без звука"}`;
  } else if (b.action === "admin_del") {
    const a = admin();
    c.admins = c.admins.filter((x) => x !== a);
    message = `Админ ${a.id} удалён: бот больше ему не отвечает`;
  }
  return { message, invite, bot: demoGet() };
}


document.addEventListener("DOMContentLoaded", async () => {
  $("#refresh").addEventListener("click", load);
  $("#bot-enable").addEventListener("change", (e) => act({ action: "enable", on: e.target.checked }));
  $("#set-actions").addEventListener("change", (e) => act({ action: "set", key: "actions", on: e.target.checked }));
  $("#set-links").addEventListener("change", (e) => act({ action: "set", key: "links", on: e.target.checked }));
  $("#set-quiet").addEventListener("change", (e) => {
    const value = e.target.checked ? `${$("#quiet-from").value}-${$("#quiet-to").value}` : "off";
    act({ action: "set", key: "quiet", value });
  });
  ["#quiet-from", "#quiet-to"].forEach((s) => $(s).addEventListener("input", quietChanged));
  $("#quiet-form").addEventListener("submit", (e) => {
    e.preventDefault();
    act({ action: "set", key: "quiet", value: `${$("#quiet-from").value}-${$("#quiet-to").value}` });
  });
  $("#token-form").addEventListener("submit", saveToken);
  $("#token-del").addEventListener("click", deleteToken);
  $("#toggle-token").addEventListener("click", () => {
    const t = $("#f-token");
    t.type = t.type === "password" ? "text" : "password";
    $("#toggle-token").textContent = t.type === "password" ? "Показать" : "Скрыть";
  });
  $("#add-admin").addEventListener("click", openInvite);
  // Код приглашения не остаётся в странице после закрытия окна: ни кнопкой, ни кликом по фону, ни Escape
  const closeInvite = () => {
    $("#invite-dialog").close();
    $("#invite-body").innerHTML = "";
  };
  $("#invite-close").addEventListener("click", closeInvite);
  $("#invite-dialog").addEventListener("click", (e) => { if (e.target === e.currentTarget) closeInvite(); });
  $("#invite-dialog").addEventListener("close", (e) => { if (!e.currentTarget.open) $("#invite-body").innerHTML = ""; });
  await load();
  schedule();
});
