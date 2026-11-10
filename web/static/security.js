"use strict";

// Страница «Безопасность». Блоки «Аудит сервера» (server) и «Защита от РКН» (dpi): последние проверки
// iof audit по узлам, что проверка показала, почему это важно и как исправить. Данные: GET api/security
// (iof api audit, узлы при этом не опрашиваются), проверка: POST api/security {block, node} — задача
// iof audit run <блок>. Оценки и тексты приходят готовыми из iof, здесь только отрисовка

const sec = { data: null, running: false };
// Блоки страницы: у каждого в html есть #<блок>-node, -run, -stamp, -health, -checks
const BLOCKS = ["server", "dpi"];
// Что проверял запуск из истории (поле block)
const RUN_WORDS = { server: "аудит сервера", dpi: "защита от РКН", all: "оба блока" };
const WORDS = { good: "в порядке", warn: "внимание", crit: "проблема", none: "нет данных" };
const RANK = { none: 0, good: 1, warn: 2, crit: 3 };

const job = watchJob({
  kind: "audit",
  demoJobs,
  all: false,
  render: renderJob,
  done: () => load(),
});

function fmtWhen(ts) {
  return new Date(ts * 1000).toLocaleString("ru-RU", { dateStyle: "short", timeStyle: "short" });
}

// Выбранный узел блока, пусто — все узлы
function picked(block) {
  return $(`#${block}-node`).value;
}

// Узлы блока с результатом последней проверки в res (нет, если узел ещё не проверялся)
function blockNodes(block) {
  const saved = (sec.data.blocks[block] || {}).nodes || {};
  const pick = picked(block);
  return sec.data.nodes.filter((n) => !pick || n.name === pick).map((n) => ({ ...n, res: saved[n.name] }));
}

// Оценка проверки на узле: результат iof или «нет данных» с причиной
function checkOf(res, id) {
  const none = (value) => ({ status: "none", value, detail: [], hint: "", cmd: "" });
  if (!res) return none("узел ещё не проверялся");
  if (!res.reachable) return none("нет связи с узлом");
  return res.checks.find((c) => c.id === id) || none("нет данных");
}

function worst(per) {
  return per.reduce((a, p) => (RANK[p.c.status] > RANK[a] ? p.c.status : a), "none");
}


// Отрисовка блока

function renderNodeSelect(block) {
  const el = $(`#${block}-node`);
  const names = sec.data.nodes.map((n) => n.name);
  if (el.dataset.names === names.join(" ")) return;
  const pick = el.value;
  el.dataset.names = names.join(" ");
  el.innerHTML = `<option value="">Все узлы</option>` + names.map((n) => `<option>${esc(n)}</option>`).join("");
  el.value = names.includes(pick) ? pick : "";
}

function renderStamp(block, nodes) {
  const times = nodes.filter((n) => n.res).map((n) => n.res.at);
  const from = Math.min(...times), to = Math.max(...times);
  $(`#${block}-stamp`).textContent = !times.length ? ""
    : to - from < 120 ? `проверено ${fmtWhen(to)}` : `проверено с ${fmtWhen(from)} по ${fmtWhen(to)}`;
}

function renderHealth(block, nodes, rows) {
  const el = $(`#${block}-health`);
  const single = nodes.length === 1;
  const checked = nodes.filter((n) => n.res && n.res.reachable);
  const down = nodes.filter((n) => n.res && !n.res.reachable);
  const fresh = nodes.filter((n) => !n.res);

  if (!nodes.length) {
    el.className = "health";
    el.innerHTML = `${icon("none", "ico big-ico")}<div><h2>Узлов нет</h2>
      <p class="sub">Добавь серверы на странице «Добавить сервер» или командой <code>sudo iof node add</code></p></div>`;
    return;
  }
  if (!checked.length && !down.length) {
    el.className = "health";
    el.innerHTML = `${icon("none", "ico big-ico")}<div><h2>Проверка ещё не запускалась</h2>
      <p class="sub">«Проверить» опросит ${single ? "узел" : "все узлы"} и покажет результат здесь.
      То же в терминале: <code>sudo iof audit run ${block}</code></p></div>`;
    return;
  }

  const count = { crit: 0, warn: 0, good: 0, none: 0 };
  const critNodes = new Set();
  for (const r of rows) {
    for (const p of r.per) {
      if (!p.n.res || !p.n.res.reachable) continue;
      count[p.c.status]++;
      if (p.c.status === "crit") critNodes.add(p.n.name);
    }
  }
  const level = count.crit ? "crit" : count.warn || down.length || fresh.length ? "warn" : "good";
  let title;
  if (count.crit && single) {
    title = `Проверка показала ${count.crit} ${plural(count.crit, ["проблему", "проблемы", "проблем"])}`;
  } else if (count.crit) {
    title = `Проверка показала проблемы на ${critNodes.size} из ${nodes.length} ${plural(nodes.length, ["узла", "узлов", "узлов"])}`;
  } else if (count.warn) {
    title = `Проблем проверка не показала, есть ${count.warn} ${plural(count.warn, ["замечание", "замечания", "замечаний"])}`;
  } else if (down.length || fresh.length) {
    title = "Проверены не все узлы";
  } else {
    title = "Замечаний нет";
  }

  const items = rows.filter((r) => r.per.some((p) => p.c.status === "crit")).map((r) => {
    const bad = r.per.filter((p) => p.c.status === "crit");
    const text = single ? bad[0].c.value : bad.map((p) => p.n.name).join(", ");
    return `<li>${icon("crit")}<span><b>${esc(r.k.title)}</b> — ${esc(text)}</span></li>`;
  });
  for (const n of down) {
    items.push(`<li>${icon("warn")}<span><a class="node-link" href="${nodeHref(n.name)}"><b>${esc(n.name)}</b></a> —
      проверить не удалось: ${esc(n.res.error || "нет связи по SSH")}</span></li>`);
  }
  if (fresh.length) {
    items.push(`<li>${icon("none")}<span>Ещё не проверялись: ${esc(fresh.map((n) => n.name).join(", "))}</span></li>`);
  }
  el.className = `health ${level}`;
  el.innerHTML = `${icon(level, "ico big-ico")}<div>
    <h2>${esc(title)}</h2>
    <p class="sub">Проблем: ${count.crit} · внимание: ${count.warn} · в порядке: ${count.good} · нет данных: ${count.none}${
      single ? "" : ` · узлов проверено: ${checked.length} из ${nodes.length}`}</p>
    ${items.length ? `<ul class="issues">${items.join("")}</ul>` : ""}
  </div>`;
}

// Значение в строке проверки, когда узлов несколько: на скольких узлах худшая оценка и на каких
function spread(per, lvl) {
  const names = (st) => per.filter((p) => p.c.status === st).map((p) => p.n.name);
  const top = names(lvl);
  if (top.length === per.length) {
    const same = new Set(per.map((p) => p.c.value)).size === 1;
    return same ? `${esc(per[0].c.value)} · все узлы` : "на всех узлах";
  }
  let s = `на ${top.length} из ${per.length}: ${esc(top.join(", "))}`;
  if (lvl === "crit" && names("warn").length) s += ` · внимание: ${esc(names("warn").join(", "))}`;
  return s;
}

function detailLines(c) {
  return c.detail.map((line) => `<span class="check-detail">${esc(line)}</span>`).join("");
}

// «Как исправить»: одинаковые советы для нескольких узлов показываются один раз, со списком узлов
function fixes(per, single) {
  const groups = new Map();
  for (const p of per) {
    if (RANK[p.c.status] < RANK.warn || !(p.c.hint || p.c.cmd)) continue;
    const key = `${p.c.hint}\n${p.c.cmd}`;
    if (!groups.has(key)) groups.set(key, { c: p.c, names: [] });
    groups.get(key).names.push(p.n.name);
  }
  return [...groups.values()].map((g) => `<div class="fix">
    <h4>Как исправить${single ? "" : ` <span class="muted">${esc(g.names.join(", "))}</span>`}</h4>
    ${g.c.hint ? `<p>${esc(g.c.hint)}</p>` : ""}
    ${g.c.cmd ? `<div class="cmd"><pre class="code">${esc(g.c.cmd)}</pre><button class="btn small" type="button" data-copy>Копировать</button></div>` : ""}
  </div>`).join("");
}

function checkRow(r, single, open) {
  const lvl = worst(r.per);
  const value = single ? esc(r.per[0].c.value) : spread(r.per, lvl);
  // Сначала узлы с проблемой, потом остальные
  const byLevel = r.per.slice().sort((a, b) => RANK[b.c.status] - RANK[a.c.status]);
  const body = single
    ? (r.per[0].c.detail.length ? `<p class="check-facts">${detailLines(r.per[0].c)}</p>` : "")
    : `<dl class="check-nodes">${byLevel.map((p) => `<dt><a class="node-link" href="${nodeHref(p.n.name)}">${esc(p.n.name)}</a></dt>
        <dd><span class="check-status">${icon(p.c.status)}<span>${esc(p.c.value)}</span></span>${detailLines(p.c)}</dd>`).join("")}</dl>`;
  return `<li><details data-id="${esc(r.k.id)}"${open.has(r.k.id) ? " open" : ""}>
    <summary>${badge(lvl, WORDS[lvl])}<span class="item-title">${esc(r.k.title)}</span><span class="check-value">${value}</span></summary>
    <div class="check-body">
      <p class="check-why">${esc(r.k.why)}</p>
      ${body}
      ${fixes(r.per, single)}
    </div>
  </details></li>`;
}

// Список перерисовывается целиком, раскрытые проверки остаются раскрытыми
function renderChecks(block, rows, single) {
  const box = $(`#${block}-checks`);
  const open = new Set([...box.querySelectorAll("details[open]")].map((d) => d.dataset.id));
  box.innerHTML = sec.data.groups.filter((g) => g.block === block).map((g) => {
    const items = rows.filter((r) => r.k.group === g.id);
    return items.length ? `<h3 class="check-group">${esc(g.title)}</h3>
      <ul class="checks">${items.map((r) => checkRow(r, single, open)).join("")}</ul>` : "";
  }).join("");
}

function renderBlock(block) {
  renderNodeSelect(block);
  const nodes = blockNodes(block);
  const rows = sec.data.catalog.filter((k) => k.block === block)
    .map((k) => ({ k, per: nodes.map((n) => ({ n, c: checkOf(n.res, k.id) })) }));
  renderStamp(block, nodes);
  renderHealth(block, nodes, rows);
  renderChecks(block, rows, nodes.length === 1);
}


// Расписание и последние запуски

function renderSchedule() {
  const d = sec.data, s = d.settings;
  const when = s.cron.trim().split(/\s+/).slice(0, 5).join(" ");
  $("#sched").innerHTML =
    `<dt>Расписание</dt><dd>${s.cron ? `<code>${esc(when)}</code> · iof audit cron` : badge("warn", "не запланирована")}</dd>
     <dt>Telegram</dt><dd>${s.tg ? badge("good", "настроен") : badge("none", "не настроен")}</dd>`;
  const hints = [];
  if (!s.cron) hints.push("Раз в сутки, после ночного обслуживания: <code>sudo crontab -e</code>, строка <code>30 5 * * * /usr/local/bin/iof audit cron >/dev/null 2>&1</code>");
  if (!s.tg) hints.push("Сообщения о том, что стало хуже: <code>TG_TOKEN</code> и <code>TG_CHAT</code> в <code>/root/iof/iof.env</code>");
  else hints.push("В Telegram уходит сообщение, только когда проверка из cron оказалась хуже прошлой.");
  $("#sched-hint").hidden = !hints.length;
  $("#sched-hint").innerHTML = hints.join("<br>");

  const titles = Object.fromEntries(d.catalog.map((k) => [k.id, k.title]));
  const runs = d.history.slice(-6).reverse();
  $("#history").innerHTML = runs.length ? runs.map((h) => {
    const notes = [];
    if (h.down.length) notes.push(`${icon("warn")} нет связи: ${esc(h.down.join(", "))}`);
    if (h.worse.length) notes.push(`${icon("warn")} стало хуже: ${esc(h.worse.map((w) => `${w.node} — ${titles[w.id] || w.id}`).join("; "))}`);
    return `<div class="item">
      <div class="item-head"><span class="item-title">${fmtWhen(h.at)}</span>
        <span class="item-meta">${esc(RUN_WORDS[h.block] || h.block)} · узлов: ${h.nodes} · проблем: ${h.counts.crit} · внимание: ${h.counts.warn}</span></div>
      ${notes.map((n) => `<p class="hint check-note">${n}</p>`).join("")}
    </div>`;
  }).join("") : `<p class="empty">Проверок ещё не было.</p>`;
}

function syncButtons() {
  const off = sec.running || !sec.data || !!sec.data.error;
  document.querySelectorAll("[data-run]").forEach((b) => { b.disabled = off; });
}

function render() {
  const d = sec.data;
  renderMigrate(d.migrate);
  $("#alert").hidden = !d.error;
  if (d.error) {
    $("#alert").innerHTML = `${icon("crit")} iof не ответил: ${esc(d.error)}`;
    syncButtons();
    return;
  }
  BLOCKS.forEach(renderBlock);
  renderSchedule();
  syncButtons();
}

async function load() {
  $("#refresh").setAttribute("aria-busy", "true");
  try {
    sec.data = DEMO ? await demoAudit() : await getJson("api/security");
    render();
  } catch (e) {
    $("#alert").hidden = false;
    $("#alert").innerHTML = `${icon("crit")} Нет связи с панелью: ${esc(e.message)}`;
  } finally {
    $("#refresh").removeAttribute("aria-busy");
  }
}


// Проверка: задача iof audit run, по окончании данные загружаются заново

async function run(block) {
  formError("", "#action-error");
  const body = { block, node: picked(block) };
  try {
    const id = DEMO ? demoAuditJob(body) : (await postJson("api/security", body)).job;
    job.start(id);
    $("#job").scrollIntoView({ behavior: "smooth", block: "nearest" });
  } catch (e) {
    formError(e.message, "#action-error");
  }
}

function renderJob(j) {
  const lvl = renderJobCard(j);
  sec.running = !!j && j.state === "running";
  syncButtons();
  if (!j) return;
  $("#job-hide").hidden = sec.running;
  if (j.state === "ok") {
    jobResult(lvl, `${icon("good")}<div>Проверка завершена, результат ниже</div>`);
  } else if (j.state === "warn") {
    jobResult(lvl, `${icon("warn")}<div>Проверены не все узлы${failReason(j.log) ? `: <b>${esc(failReason(j.log))}</b>` : ""}</div>`);
  } else if (j.state === "error") {
    const reason = failReason(j.log);
    jobResult(lvl, `${icon("crit")}<div>Проверка не прошла${reason ? `: <b>${esc(reason)}</b>` : ", причина в логе"}</div>`);
  } else {
    jobResult(lvl, "");
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  $("#refresh").addEventListener("click", load);
  $("#job-hide").addEventListener("click", () => job.hide());
  for (const block of BLOCKS) {
    $(`#${block}-run`).addEventListener("click", () => run(block));
    $(`#${block}-node`).addEventListener("change", () => sec.data && !sec.data.error && renderBlock(block));
    $(`#${block}-checks`).addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-copy]");
      if (btn) toast(await copyText(btn.previousElementSibling.textContent) ? "Скопировано" : "Не удалось скопировать");
    });
  }
  await load();
  job.poll();
});


// Демо: шесть узлов из demo.js со всеми видами оценок в каждом блоке, node-5 без связи.
// Тексты как у iof audit

const demoAuditState = {
  at: { server: Math.floor(Date.now() / 1000) - 5 * 3600, dpi: Math.floor(Date.now() / 1000) - 5 * 3600 },
  runs: [{ ago: 86400, block: "all" }, { ago: 0, block: "all" }],
};

const DEMO_AUDIT_GROUPS = [["ssh", "SSH"], ["net", "Сеть и защита от подбора"], ["upd", "Обновления"], ["sys", "Система"]];
const DEMO_AUDIT_CATALOG = [
  ["ssh_root", "ssh", "Вход root по SSH", "Имя root известно заранее, поэтому пароль подбирают в первую очередь к нему. Вход только по ключу подбором не взять. iof заходит на узлы по ключу, пароль root ему не нужен."],
  ["ssh_password", "ssh", "Вход по паролю", "Пароль можно подобрать или подсмотреть, ключ нельзя. Боты перебирают пароли SSH на любом сервере круглые сутки."],
  ["ssh_port", "ssh", "Порт SSH", "На порт 22 приходит основной поток автоматического подбора. При входе только по ключу это шум в журнале, при входе по паролю — риск."],
  ["ssh_keys", "ssh", "Вход по ключу", "По ключу iof выполняет команды на узле. Если authorized_keys доступен на запись другим пользователям, в него можно дописать чужой ключ."],
  ["firewall", "net", "Файрвол", "Без запрета по умолчанию снаружи доступно всё, что слушает порт, в том числе службы, поставленные случайно. Файрвол хостера (security group) с узла не виден: если он есть, это предупреждение можно оставить."],
  ["ban", "net", "Блокировка подбора", "fail2ban или CrowdSec блокируют адрес после нескольких неудачных входов. При входе по паролю это основная защита от подбора, при входе только по ключу — чистый журнал."],
  ["ban_port", "net", "Порт sshd в fail2ban", "Если jail sshd следит не за тем портом, на котором слушает SSH, блокировка адреса не закрывает ему SSH."],
  ["auth_fail", "net", "Неудачные входы за сутки", "Много попыток значит, что сервер перебирают. При входе только по ключу они безвредны."],
  ["ports", "net", "Слушающие порты", "Каждый открытый порт — это служба, которую можно атаковать и по которой узел можно опознать. Ожидаемые: SSH, Hysteria2, контейнер AmneziaWG, порты ретранслятора. То, что слушает только 127.0.0.1, снаружи недоступно."],
  ["updates", "upd", "Ожидающие обновления", "Обновления безопасности закрывают известные уязвимости. iof-nightly ставит их каждую ночь, если он запланирован в cron."],
  ["reboot", "upd", "Перезагрузка", "Новое ядро и системные библиотеки начинают работать только после перезагрузки. iof-nightly перезагружает узел после обновления."],
  ["nightly", "upd", "Ночное обслуживание", "iof-nightly обновляет пакеты и перезагружает узел. Если он давно не отрабатывал, узел остаётся без обновлений."],
  ["sudo_log", "sys", "Журнал sudo", "По журналу sudo видно, кто и какие команды выполнял от root. Без него не разобраться, что происходило на сервере."],
  ["pwquality", "sys", "Требования к паролям", "pam_pwquality не даёт задать короткий или простой пароль. Важно там, где по паролю входят в SSH или вызывают sudo."],
  ["suid", "sys", "SUID-файлы", "SUID-файл выполняется с правами владельца, обычно root. Лишний такой файл — способ повысить права, его же оставляют после взлома."],
];

// Проверки узла: всё в порядке, поверх — отличия over {id: [статус, значение, подробности, совет, команды]}
function demoAuditChecks(awgPort, over) {
  const night = `отработало ${fmtWhen(new Date().setHours(4, 5, 0, 0) / 1000)}`;
  const reload = "sshd -t && systemctl reload ssh";
  const base = {
    ssh_root: ["good", "только по ключу (prohibit-password)"],
    ssh_password: ["good", "выключен"],
    ssh_port: ["good", "22, вход только по ключу"],
    ssh_keys: ["good", "включён, ключей у root: 2"],
    firewall: ["good", "ufw: входящие по умолчанию запрещены"],
    ban: ["good", "fail2ban работает, jail: sshd"],
    ban_port: ["good", "совпадает: ssh"],
    auth_fail: ["good", "214, вход только по ключу"],
    ports: ["good", `только ожидаемые: 22/tcp SSH, 443/udp Hysteria2${awgPort ? `, ${awgPort}/udp amnezia-awg2` : ""}`,
      ["Только локально (loopback): 53/tcp systemd-resolve, 53/udp systemd-resolve"]],
    updates: ["good", "нет", [`Списки пакетов обновлялись ${fmtWhen(new Date().setHours(4, 5, 0, 0) / 1000)}`]],
    reboot: ["good", "не нужна"],
    nightly: ["good", night],
    sudo_log: ["good", "в журнале systemd и /var/log/auth.log"],
    pwquality: ["warn", "не настроено", ["Вход по паролю в SSH выключен: это касается только локальных паролей и sudo"], "На узле от root:",
      "apt-get install -y libpam-pwquality && sed -i -E 's/^#? ?minlen.*/minlen = 12/' /etc/security/pwquality.conf"],
    suid: ["good", "13, все из стандартного набора Ubuntu 24.04"],
  };
  const all = { ...base, ...over(reload) };
  return Object.entries(all).map(([id, [status, value, detail = [], hint = "", cmd = ""]]) => ({ id, status, value, detail, hint, cmd }));
}

function demoAuditNodes() {
  const fw = (ports) => ["apt-get install -y ufw", "ufw allow 22/tcp", ...ports.map((p) => `ufw allow ${p}`), "ufw default deny incoming", "ufw --force enable"].join("\n");
  const fwHint = "Команды сначала открывают порты SSH, Hysteria2, AmneziaWG и ретранслятора этого узла, потом включают запрет остального. Сверь список со своими службами. На узле от root:";
  const cron = ["На управляющем сервере: sudo crontab -e, строка ниже. Каждую ночь в 4:00 обновятся и перезагрузятся все узлы.", "0 4 * * * /usr/local/sbin/iof-nightly"];
  const checks = {
    main: demoAuditChecks("41234", () => ({
      ports: ["good", "только ожидаемые: 22/tcp SSH, 443/udp Hysteria2, 41234/udp amnezia-awg2",
        ["Только локально (loopback): 53/tcp systemd-resolve, 53/udp systemd-resolve, 8088/tcp python3"]],
    })),
    "node-1": demoAuditChecks("42345", (reload) => ({
      ssh_root: ["crit", "разрешён, в том числе по паролю", [],
        "iof заходит на этот узел под root по ключу, поэтому совсем запрещать root нельзя: оставь ему вход только по ключу. На узле от root:",
        `echo 'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/00-iof-root.conf && ${reload}`],
      ssh_password: ["crit", "включён, root тоже", [],
        "Сначала убедись, что сам входишь на сервер по ключу: iof уже ходит по ключу, ему пароль не нужен. На узле от root:",
        `printf 'PasswordAuthentication no\\nKbdInteractiveAuthentication no\\n' > /etc/ssh/sshd_config.d/00-iof-password.conf && ${reload}`],
      ssh_port: ["warn", "22, вход по паролю включён", [],
        "Надёжнее выключить вход по паролю (проверка «Вход по паролю»): тогда порт не важен. Если пароли нужны, порт можно сменить, например на 2222: открой его в файрволе, затем выполни команду ниже. После неё на управляющем сервере в /root/iof/nodes.conf поставь узлу node-1 адрес SSH root@198.51.100.20:2222. На узле от root:",
        "echo 'Port 2222' > /etc/ssh/sshd_config.d/00-iof-port.conf && sshd -t && systemctl daemon-reload && { systemctl restart ssh.socket 2>/dev/null; systemctl restart ssh; }"],
      firewall: ["crit", "нет, снаружи доступно всё, что слушает порт, есть лишние порты", [], fwHint, fw(["42345/udp", "443/udp"])],
      ban: ["crit", "нет, а вход по паролю включён", [], "В Ubuntu jail sshd включён сразу после установки. На узле от root:",
        "apt-get install -y fail2ban && systemctl enable --now fail2ban"],
      ban_port: ["none", "fail2ban не работает"],
      auth_fail: ["crit", "1840, вход по паролю включён", [], "Выключи вход по паролю и поставь fail2ban: проверки «Вход по паролю» и «Блокировка подбора»."],
      ports: ["crit", "лишние: 3306/tcp mysqld, 8080/tcp python3, файрвола нет",
        ["Ожидаемые: 22/tcp SSH, 443/udp Hysteria2, 42345/udp amnezia-awg2", "Только локально (loopback): 53/tcp systemd-resolve, 53/udp systemd-resolve"],
        "Узнай, что это за служба. Если она не нужна, останови её, иначе закрой порт файрволом. На узле от root:",
        "ss -tulnp | grep -E ':(3306|8080) '\nsystemctl disable --now <служба>"],
      pwquality: ["warn", "не настроено", [], "На узле от root:",
        "apt-get install -y libpam-pwquality && sed -i -E 's/^#? ?minlen.*/minlen = 12/' /etc/security/pwquality.conf"],
    })),
    "node-2": demoAuditChecks("43456", () => ({
      ports: ["good", "только ожидаемые: 22/tcp SSH, 443/udp Hysteria2, 43456/udp amnezia-awg2",
        ["Ретранслятор (DNAT, без сокета): 45001/udp → 192.0.2.10:443, 45002/udp → 192.0.2.10:41234", "Только локально (loopback): 53/tcp systemd-resolve, 53/udp systemd-resolve"]],
      updates: ["warn", "12, из них безопасности: 4", [`Списки пакетов обновлялись ${fmtWhen(Date.now() / 1000 - 9000)}`],
        "Чтобы обновления ставились сами каждую ночь, запланируй iof-nightly (проверка «Ночное обслуживание»). Поставить сейчас. На узле от root:",
        "apt-get update && apt-get -y upgrade"],
      reboot: ["warn", "нужна (linux-image-6.8.0-48-generic)", [], "Клиенты узла отключатся на минуту. iof-nightly перезагружает узлы сам. На узле от root:", "reboot"],
      nightly: ["warn", `давно: последний раз ${fmtWhen(Date.now() / 1000 - 6 * 86400)}`, [], ...cron],
    })),
    "node-3": demoAuditChecks("", () => ({
      firewall: ["warn", "нет, снаружи доступно всё, что слушает порт", [], fwHint, fw(["443/udp"])],
      ban: ["warn", "нет, вход только по ключу", [], "В Ubuntu jail sshd включён сразу после установки. На узле от root:",
        "apt-get install -y fail2ban && systemctl enable --now fail2ban"],
      ban_port: ["none", "fail2ban не работает"],
      suid: ["warn", "вне стандартного набора Ubuntu 24.04: 1 из 14", ["/usr/local/bin/backup-helper"],
        "Узнай, из какого пакета файл. Если он не нужен, сними с него SUID. На узле от root:", "dpkg -S /usr/local/bin/backup-helper\nchmod u-s <путь>"],
    })),
    "node-4": demoAuditChecks("", () => ({
      ssh_keys: ["warn", "ключей у root: 2, но authorized_keys доступен на запись не только владельцу (права 664)", [], "На узле от root:", "chmod 600 ~root/.ssh/authorized_keys"],
      ban_port: ["warn", "jail следит за ssh, а SSH слушает 2222", [], "На узле от root:",
        "printf '[sshd]\\nenabled = true\\nport = 2222\\n' > /etc/fail2ban/jail.d/iof-sshd.local && systemctl restart fail2ban"],
      ssh_port: ["good", "2222, вход только по ключу"],
      ports: ["good", "только ожидаемые: 2222/tcp SSH, 443/udp Hysteria2",
        ["Только локально (loopback): 53/tcp systemd-resolve, 53/udp systemd-resolve"]],
      sudo_log: ["crit", "выключен (Defaults !syslog в sudoers)", [], "Найди эту строку и убери её через visudo. На узле от root:",
        "grep -rn '!syslog' /etc/sudoers /etc/sudoers.d"],
    })),
  };
  return demoBlockNodes(checks, demoAuditState.at.server);
}

// Результат блока по узлам из demo.js: checks {узел: проверки}, недоступный узел без оценок
function demoBlockNodes(checks, at) {
  const out = {};
  for (const n of demoNodes()) {
    out[n.name] = n.reachable
      ? { addr: n.addr, reachable: true, at, checked: at, error: "", checks: checks[n.name] || [] }
      : { addr: n.addr, reachable: false, at, checked: 0, error: "нет связи по SSH", checks: [] };
  }
  return out;
}

const DEMO_DPI_GROUPS = [["hy2", "Hysteria2"], ["awg", "AmneziaWG"], ["probe", "Что видно снаружи"], ["scan", "Сканеры"],
  ["rep", "Репутация адреса"], ["hyg", "Гигиена"]];
const DEMO_DPI_CATALOG = [
  ["hy2_mode", "hy2", "Режим маскировки", "Без маскировки Hysteria2 — это QUIC, который на запрос по HTTP/3 отвечает ошибкой 404: такой сервер легко отличить от сайта. Salamander делает трафик похожим на случайный шум, но на QUIC он уже не похож. Без Salamander с masquerade сервер выглядит как сайт с HTTP/3, но QUIC к зарубежным адресам фильтры режут. Это выбор, а не ошибка."],
  ["hy2_masq", "hy2", "Masquerade", "Тому, кто пришёл на порт Hysteria2 без пароля, сервер показывает сайт из masquerade. Если цель не отвечает, зонд увидит ошибку вместо сайта. Под Salamander masquerade снаружи не виден."],
  ["hy2_quic", "hy2", "Ответ на зонд QUIC", "Управляющий сервер отправляет на порт Hysteria2 пакет QUIC с несуществующей версией. Обычный сервер QUIC отвечает согласованием версий, под Salamander порт так не отвечает. Так видно, что получит тот, кто зондирует порт, и доходит ли до узла UDP."],
  ["hy2_port", "hy2", "Порт", "HTTP/3 работает на 443/udp, QUIC на другом порту встречается редко и заметнее. Под Salamander трафик не похож на QUIC на любом порту."],
  ["hy2_hop", "hy2", "Смена портов (port hopping)", "Клиент раз в полминуты меняет порт, поэтому блокировка одного порта или долгого потока UDP не обрывает связь. Для этого нужен диапазон портов на сервере и он же в ссылке клиента."],
  ["hy2_template", "hy2", "Конфиг и шаблон", "iof hy2 install ставит на узлы конфиг по шаблону с управляющего сервера. Если конфиг узла потом правили вручную, маскировка на нём отличается от остальных, а повторная установка затрёт правки."],
  ["awg_params", "awg", "Параметры обфускации", "AmneziaWG отличается от WireGuard мусорными пакетами (Jc, Jmin, Jmax), добавками к пакетам (S1–S4) и своими заголовками (H1–H4). С нулями и заголовками 1, 2, 3, 4 это обычный WireGuard, который фильтры узнают по первому пакету."],
  ["awg_same", "awg", "Одинаковые параметры на узлах", "С одинаковыми параметрами трафик узлов выглядит одинаково: признак, найденный для одного узла, подойдёт ко всем. Сравнение идёт по хэшу, сами значения в панель и в файлы не попадают."],
  ["tcp_web", "probe", "Порты 80 и 443/tcp", "Сайт с HTTP/3 отвечает и по обычному HTTPS на 443/tcp. Если на 443/udp есть QUIC, а 443/tcp закрыт, сервер на сайт не похож. Посторонняя служба на этих портах показывает зонду свои заголовки и сертификат."],
  ["tls_cert", "probe", "Сертификат", "Сертификат видит любой, кто подключится к порту. Самоподписанный сертификат на имя известного сайта на адресе, который этому сайту не принадлежит, — заметный признак."],
  ["icmp", "probe", "Ответ на ping", "Обычный сервер чаще отвечает на ping. Молчание само ничего не выдаёт: так настроено у многих хостеров."],
  ["names", "probe", "Имя сервера и PTR", "Обратную запись DNS (PTR) видит любой по адресу узла, имя сервера попадает в приветствия служб. Слова vpn, proxy, wg в них говорят о назначении сервера."],
  ["banners", "probe", "Лишние порты снаружи", "Служба на лишнем порту отвечает приветствием с названием и версией программы. По нему сканер понимает, что стоит на сервере."],
  ["panel", "probe", "Панель iof-web", "Панель управляет всеми узлами от root. Она должна слушать только 127.0.0.1 и открываться через SSH-туннель: на внешнем адресе её найдёт любой сканер."],
  ["blocklist", "scan", "Блок-лист сканеров", "Список адресов, с которых узлы сканируют и зондируют. Если пакеты от них отбрасывать, сканер видит закрытый сервер. iof пока только проверяет, применён ли список на узле."],
  ["asn", "rep", "Сеть и хостер", "Сети крупных хостеров VPS фильтры знают и относятся к ним строже, чем к домашним. Это справка: изменить её можно только переездом к другому хостеру."],
  ["registry", "rep", "Адрес в реестре", "Если адрес узла есть в выгрузке реестра блокировок, у части провайдеров он уже недоступен и клиенты до него не дойдут."],
  ["journald", "hyg", "Срок хранения журнала", "В журнале остаются адреса клиентов и время подключений. Если сервер изымут или взломают, журнал покажет, кто им пользовался. Чем короче срок хранения, тем меньше можно узнать."],
  ["hy2_log", "hyg", "Журнал Hysteria2", "На уровне info Hysteria2 пишет в журнал адрес каждого подключившегося клиента, на debug ещё и адреса, куда он ходит."],
  ["awg_log", "hyg", "Лог контейнера AmneziaWG", "Docker по умолчанию пишет вывод контейнера в файл без ограничения размера. Со временем он занимает диск и хранит историю дольше, чем нужно."],
  ["time", "hyg", "Время", "При сбитых часах не проходит проверка сертификатов, а время в журналах узлов не сходится между собой."],
];

// Проверки блока dpi для узла: частый случай, поверх — отличия over {id: [статус, значение, подробности, совет, команды]}
function demoDpiChecks(addr, over) {
  const listDay = fmtWhen(new Date().setHours(5, 30, 0, 0) / 1000);
  const restart = "systemctl restart hysteria-server";
  const base = {
    hy2_mode: ["good", "без Salamander, с masquerade: сервер выглядит как сайт с HTTP/3",
      ["QUIC к зарубежным адресам фильтры могут резать. Salamander прячет QUIC, но делает трафик непохожим ни на что: это иной компромисс, а не улучшение"]],
    hy2_masq: ["good", "proxy на https://example.org/, цель с узла отвечает (200)"],
    hy2_quic: ["good", "порт 443/udp отвечает как сервер QUIC (согласование версий)"],
    hy2_port: ["good", "443/udp, как у HTTP/3"],
    hy2_hop: ["warn", "нет: клиенты всегда ходят на порт 443", [],
      "Из iof смена портов пока не включается: в ссылки групп попадает один порт, и после sudo iof hy2 refresh диапазон из ссылки пропадёт. Вручную: перенаправь диапазон на порт Hysteria2 командой ниже (после перезагрузки правило надо вернуть, файрвол должен пропускать этот диапазон UDP) и замени в ссылке клиента порт на диапазон, например :20000-50000. На узле от root:",
      "iptables -t nat -A PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443"],
    hy2_template: ["good", "совпадает с шаблоном", ["Шаблон: /etc/hysteria/config.yaml. Пользователи auth.userpass не сравниваются: на узлах они свои"]],
    awg_params: ["none", "AmneziaWG на узле не установлен"],
    awg_same: ["none", "AmneziaWG на узле не установлен"],
    tcp_web: ["good", "отвечает 80/tcp masquerade Hysteria2 (ответ 301), 443/tcp masquerade Hysteria2 (ответ 200)"],
    tls_cert: ["warn", "443/tcp: самоподписанный на чужое имя bing.com", ["На 443/tcp отвечает masquerade Hysteria2 со своим сертификатом"],
      "Сертификат на имя чужого сайта снаружи выглядит подделкой. Варианты: свой домен и блок acme в конфиге Hysteria2 (сертификат выдаст Let's Encrypt, в ссылках клиентов пропадёт insecure) или Salamander, под которым рукопожатие снаружи не видно."],
    icmp: ["good", "отвечает"],
    names: ["good", "имя сервера: srv-12, PTR: нет"],
    banners: ["good", "лишних портов нет"],
    panel: ["good", "панели на узле нет"],
    blocklist: ["warn", "на узле не применён", [`В списке записей: 1840, скачан ${listDay}`],
      "Применять список iof пока не умеет, это появится отдельной командой. Сейчас проверка только показывает, что пакеты от адресов из списка узел принимает."],
    asn: ["good", "AS64500, Example Hosting B.V. (NL)", [`Адрес ${addr}, данные whois регионального реестра`]],
    registry: ["good", `адреса ${addr} в выгрузке нет`, [`В выгрузке записей: 412560, скачана ${listDay}`]],
    journald: ["good", "хранится не дольше 7day", ["Журнал занимает 48.0M"]],
    hy2_log: ["warn", "уровень info: в журнал пишется адрес каждого клиента", [],
      "С уровнем warn в журнале остаются предупреждения и ошибки. Служба перезапустится, клиенты переподключатся сами. На узле от root:",
      `mkdir -p /etc/systemd/system/hysteria-server.service.d && printf '[Service]\\nEnvironment=HYSTERIA_LOG_LEVEL=warn\\n' > /etc/systemd/system/hysteria-server.service.d/iof-log.conf && systemctl daemon-reload && ${restart}`],
    awg_log: ["none", "AmneziaWG на узле не установлен"],
    time: ["good", "синхронизировано"],
  };
  const all = { ...base, ...over(restart) };
  return Object.entries(all).map(([id, [status, value, detail = [], hint = "", cmd = ""]]) => ({ id, status, value, detail, hint, cmd }));
}

function demoDpiNodes() {
  const awgFix = "Параметры должны совпадать на сервере и у всех клиентов, поэтому вручную их не правят. Переустанови AmneziaWG на сервере из приложения Amnezia (оно подберёт значения в границах) и выдай ключи заново. На управляющем сервере:";
  const sameFix = "Так бывает, если серверы ставили копированием настроек. Свои параметры узел получит, если переустановить на нём AmneziaWG из приложения Amnezia. После этого на управляющем сервере:";
  const logFix = (c) => ["Ограничение задаётся при создании контейнера, приложение Amnezia его не ставит. Для новых контейнеров его можно задать в /etc/docker/daemon.json (log-opts max-size), а текущий лог обрезать командой ниже. На узле от root:",
    `truncate -s 0 "$(docker inspect -f '{{.LogPath}}' ${c})"`];
  const jdFix = ["Ограничь срок, например неделей: старые записи journald удалит сам. Совсем короткий журнал мешает разбираться в сбоях, неделя — середина. На узле от root:",
    "mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\\nMaxRetentionSec=7day\\n' > /etc/systemd/journald.conf.d/iof.conf && systemctl restart systemd-journald"];
  const local = "Проверено с самого управляющего сервера, а не снаружи: файрвол на пути не участвует";
  const awg = ["Контейнер amnezia-awg2, интерфейс awg0", "Пакеты-подписи I1–I5: заданы I1"];
  const checks = {
    main: demoDpiChecks("192.0.2.10", () => ({
      hy2_quic: ["good", "порт 443/udp отвечает как сервер QUIC (согласование версий)", [local]],
      awg_params: ["good", "заданы и в допустимых границах", awg],
      awg_same: ["warn", "такие же параметры на: node-2", [], sameFix, "sudo iof awg refresh"],
      tcp_web: ["good", "отвечает 80/tcp masquerade Hysteria2 (ответ 301), 443/tcp masquerade Hysteria2 (ответ 200)", [local]],
      icmp: ["good", "отвечает", [local]],
      panel: ["good", "слушает только 127.0.0.1:8088"],
      awg_log: ["warn", "json-file без ограничения размера, сейчас 212 МБ", [], ...logFix("amnezia-awg2")],
    })),
    "node-1": demoDpiChecks("198.51.100.20", (restart) => ({
      hy2_mode: ["warn", "ни Salamander, ни masquerade: на запрос по HTTP/3 сервер отвечает 404", [],
        "Выбери одно. Masquerade: сервер показывает зонду чужой сайт, ссылки клиентов не меняются (команда ниже, адрес сайта замени на тот, что открывается с узла). Salamander: блок obfs в конфиге и новые ссылки клиентам. Чтобы новые узлы ставились так же, внеси блок и в шаблон на управляющем сервере. На узле от root:",
        `printf '\\nmasquerade:\\n  type: proxy\\n  proxy:\\n    url: https://example.org/\\n    rewriteHost: true\\n' >> /etc/hysteria/config.yaml\n${restart}`],
      hy2_masq: ["warn", "не настроен: на запрос по HTTP/3 сервер отвечает 404", [], "Как добавить, написано в проверке «Режим маскировки»."],
      hy2_quic: ["warn", "порт 8443/udp на зонд QUIC не ответил", [],
        "UDP от управляющего сервера до узла не дошёл: порт закрыт файрволом узла или хостера, либо QUIC режется по пути. Клиенты могут видеть то же самое. На узле от root:",
        "systemctl is-active hysteria-server\nss -uln | grep ':8443 '\nufw status | grep -w 8443"],
      hy2_port: ["warn", "8443/udp, а HTTP/3 обычно на 443", [],
        "QUIC на нестандартном порту заметнее. Зато 443/udp фильтруют чаще: если так задумано, оставь. Сменить порт: команда на узле, затем на управляющем сервере sudo iof hy2 refresh (ссылки клиентов изменятся). На узле от root:",
        `sed -i -E 's/^listen:.*/listen: :443/' /etc/hysteria/config.yaml && ${restart}`],
      hy2_hop: ["warn", "нет: клиенты всегда ходят на порт 8443", [],
        "Из iof смена портов пока не включается: в ссылки групп попадает один порт, и после sudo iof hy2 refresh диапазон из ссылки пропадёт. Вручную: перенаправь диапазон на порт Hysteria2 командой ниже (после перезагрузки правило надо вернуть, файрвол должен пропускать этот диапазон UDP) и замени в ссылке клиента порт на диапазон, например :20000-50000. На узле от root:",
        "iptables -t nat -A PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 8443"],
      hy2_template: ["warn", "отличается от шаблона, блоки: listen, masquerade (на узле нет)", ["Шаблон: /etc/hysteria/config.yaml"],
        "Если правки на узле нужны, внеси их и в шаблон. Вернуть узлу конфиг по шаблону — команда ниже. При auth userpass пользователи узла создадутся заново с новыми паролями: ссылки на этот узел изменятся, раздай их снова (sudo iof hy2 show). На управляющем сервере:",
        "sudo iof hy2 install node-1 --force"],
      awg_params: ["crit", "как у обычного WireGuard: параметры обфускации не заданы", ["Контейнер amnezia-awg, интерфейс wg0"],
        "Такой трафик фильтры узнают по первому пакету. Параметры задаёт приложение Amnezia при установке: поставь на сервер из приложения протокол AmneziaWG вместо WireGuard и выдай ключи заново. На управляющем сервере:",
        "sudo iof awg refresh"],
      awg_same: ["none", "параметров обфускации в конфиге нет, сравнивать нечего"],
      tcp_web: ["none", "отвечает 80/tcp nginx/1.24.0 (Ubuntu) (ответ 301), 443/tcp nginx/1.24.0 (Ubuntu) (ответ 200)",
        ["Это не Hysteria2: что увидит зонд, зависит от этой службы. Оценки здесь нет, смотри проверку «Сертификат»"]],
      tls_cert: ["good", "443/tcp: выдан Let's Encrypt на shop.example.net"],
      icmp: ["none", "не отвечает: ICMP закрыт на узле, у хостера или режется по пути"],
      names: ["warn", "имя сервера: vpn-nl-1, PTR: vpn-nl-1.example.net", ["В имени сервера есть «vpn»", "В PTR есть «vpn»"],
        "PTR (reverse DNS) меняется в панели хостера. Имя сервера меняется командой ниже. На узле от root:", "hostnamectl set-hostname srv-node-1"],
      banners: ["warn", "снаружи открыты: 3306/tcp (5.7.44-log MySQL), 8080/tcp (HTTP, Server: SimpleHTTP/0.6 Python/3.12.3)", [],
        "Останови службу или закрой порт файрволом: что это за порты, показывает проверка «Слушающие порты» в аудите сервера. На узле от root:",
        "ss -tulnp | grep -E ':(3306|8080) '\nsystemctl disable --now <служба>"],
      journald: ["warn", `срок не ограничен: самая старая запись от ${fmtWhen(Date.now() / 1000 - 74 * 86400)} (74 дн.)`, ["Журнал занимает 1.2G"], ...jdFix],
      hy2_log: ["warn", "уровень debug: в журнал пишется адрес каждого клиента и адреса, куда он ходит", [],
        "С уровнем warn в журнале остаются предупреждения и ошибки. Служба перезапустится, клиенты переподключатся сами. На узле от root:",
        `mkdir -p /etc/systemd/system/hysteria-server.service.d && printf '[Service]\\nEnvironment=HYSTERIA_LOG_LEVEL=warn\\n' > /etc/systemd/system/hysteria-server.service.d/iof-log.conf && systemctl daemon-reload && ${restart}`],
      awg_log: ["warn", "json-file без ограничения размера, сейчас 38 МБ", [], ...logFix("amnezia-awg")],
    })),
    "node-2": demoDpiChecks("203.0.113.30", () => ({
      hy2_mode: ["good", "Salamander: трафик похож на случайный шум",
        ["Другой вариант — без Salamander с masquerade: сервер выглядит как сайт с HTTP/3. Это иной компромисс, а не улучшение"]],
      hy2_masq: ["none", "под Salamander masquerade снаружи не виден"],
      hy2_quic: ["good", "порт 20000/udp на зонд QUIC не отвечает: так и выглядит Salamander", ["Доходит ли до узла UDP, под Salamander этот зонд не показывает"]],
      hy2_port: ["none", "диапазон портов 20000-50000/udp (смена портов), один порт оценивать нечего"],
      hy2_hop: ["good", "диапазон 20000-50000 в listen, Hysteria2 перенаправляет его сама"],
      hy2_template: ["warn", "отличается от шаблона, блоки: listen, masquerade (на узле нет), obfs (в шаблоне нет)", ["Шаблон: /etc/hysteria/config.yaml"],
        "Если правки на узле нужны, внеси их и в шаблон. Вернуть узлу конфиг по шаблону — команда ниже. При auth userpass пользователи узла создадутся заново с новыми паролями: ссылки на этот узел изменятся, раздай их снова (sudo iof hy2 show). На управляющем сервере:",
        "sudo iof hy2 install node-2 --force"],
      awg_params: ["warn", "вне допустимых границ: Jc, S1 и S2", [...awg, "Jc: нужно от 1 до 128, иначе мусорные пакеты перед рукопожатием не идут",
        "S1 + 56 = S2: пакеты начала и ответа рукопожатия выходят одной длины"], awgFix, "sudo iof awg refresh"],
      awg_same: ["warn", "такие же параметры на: main", [], sameFix, "sudo iof awg refresh"],
      tcp_web: ["good", "закрыты: 80/tcp закрыт, 443/tcp не отвечает"],
      tls_cert: ["none", "снаружи не виден: 443/tcp закрыт, рукопожатие QUIC скрыто под Salamander"],
      blocklist: ["good", `применён: записей 1840, обновлён ${fmtWhen(new Date().setHours(5, 31, 0, 0) / 1000)}`,
        [`В списке записей: 1840, скачан ${fmtWhen(new Date().setHours(5, 30, 0, 0) / 1000)}`]],
      asn: ["none", "не определён", ["Реестр не отдал номер AS для 203.0.113.30. Сеть: Example Cloud LLC (US)"]],
      registry: ["crit", "адрес 203.0.113.30 есть в выгрузке (запись 203.0.113.0/27)", [`В выгрузке записей: 412560, скачана ${fmtWhen(new Date().setHours(5, 30, 0, 0) / 1000)}`],
        "У провайдеров, которые блокируют по реестру, узел недоступен. Помогает только другой адрес: новый IP у хостера или новый сервер (страница «Добавить сервер»). Старый узел убирается так, на управляющем сервере:",
        "sudo iof node del node-2\nsudo iof refresh"],
      hy2_log: ["good", "уровень warn: адреса клиентов в журнал не пишутся"],
      awg_log: ["good", "ограничен: max-size 10m, сейчас 3.2 МБ"],
      time: ["warn", "не синхронизировано, служба времени выключена", ["С управляющим сервером часы сейчас сходятся"],
        "Без синхронизации часы со временем уходят. В контейнере без своих часов это предупреждение можно оставить. На узле от root:",
        "timedatectl set-ntp true && sleep 5 && timedatectl show -p NTPSynchronized"],
    })),
    "node-3": demoDpiChecks("203.0.113.41", () => ({
      hy2_masq: ["warn", "proxy на https://old-site.example/, цель с узла не отвечает (код нет ответа)", [],
        "Зонд вместо сайта получит ошибку. Проверь адрес в masquerade.proxy.url или выбери другой сайт. На узле от root:",
        "curl -sI -m 8 'https://old-site.example/' | head -n 1"],
      hy2_template: ["warn", "отличается от шаблона, блоки: masquerade", ["Шаблон: /etc/hysteria/config.yaml"],
        "Если правки на узле нужны, внеси их и в шаблон. Вернуть узлу конфиг по шаблону — команда ниже. При auth userpass пользователи узла создадутся заново с новыми паролями: ссылки на этот узел изменятся, раздай их снова (sudo iof hy2 show). На управляющем сервере:",
        "sudo iof hy2 install node-3 --force"],
      tcp_web: ["warn", "закрыты, а на 443/udp сервер изображает сайт с HTTP/3", [],
        "Настоящий сайт с HTTP/3 отвечает и по TCP. В Hysteria2 для этого есть masquerade.listenHTTPS и listenHTTP: команда добавляет их в блок masquerade. Если включён файрвол, открой 80/tcp и 443/tcp. На узле от root:",
        "sed -i '/^masquerade:/a\\  listenHTTP: :80\\n  listenHTTPS: :443\\n  forceHTTPS: true' /etc/hysteria/config.yaml && systemctl restart hysteria-server"],
      tls_cert: ["warn", "Hysteria2: самоподписанный на чужое имя bing.com", ["Сертификат Hysteria2 виден при рукопожатии QUIC на 443/udp"],
        "Сертификат на имя чужого сайта снаружи выглядит подделкой. Варианты: свой домен и блок acme в конфиге Hysteria2 (сертификат выдаст Let's Encrypt, в ссылках клиентов пропадёт insecure) или Salamander, под которым рукопожатие снаружи не видно."],
      names: ["good", "имя сервера: srv-41, PTR: static.41.113.0.203.example-host.net"],
      blocklist: ["warn", `применён: записей 1795, но не обновлялся с ${fmtWhen(Date.now() / 1000 - 12 * 86400)}`,
        [`В списке записей: 1840, скачан ${fmtWhen(new Date().setHours(5, 30, 0, 0) / 1000)}`],
        "Список на узле старше недели: адреса сканеров меняются. Обновление списка из iof появится вместе с его применением."],
    })),
    "node-4": demoDpiChecks("203.0.113.42", () => ({
      awg_params: ["none", "контейнер amnezia-awg2 остановлен"],
      awg_same: ["none", "контейнер amnezia-awg2 остановлен"],
      icmp: ["none", "не отвечает: ICMP закрыт на узле, у хостера или режется по пути"],
      journald: ["warn", `срок не ограничен: самая старая запись от ${fmtWhen(Date.now() / 1000 - 31 * 86400)} (31 дн.)`, ["Журнал занимает 412.0M"], ...jdFix],
      awg_log: ["good", "драйвер local: размер ограничен, старое удаляется само, сейчас 1.4 МБ"],
    })),
  };
  return demoBlockNodes(checks, demoAuditState.at.dpi);
}

function demoAudit() {
  const blocks = { server: { nodes: demoAuditNodes() }, dpi: { nodes: demoDpiNodes() } };
  const count = (list) => {
    const counts = { none: 0, good: 0, warn: 0, crit: 0 };
    list.forEach((b) => Object.values(blocks[b].nodes).forEach((n) => n.checks.forEach((c) => { counts[c.status]++; })));
    return counts;
  };
  const now = Math.floor(Date.now() / 1000) - 5 * 3600;
  const history = demoAuditState.runs.map((r, i) => ({
    at: r.at || now - r.ago, block: r.block, nodes: r.nodes || demoNodes().length,
    counts: count(r.block === "all" ? BLOCKS : [r.block]), down: r.nodes === 1 ? [] : ["node-5"],
    worse: i === 0 ? [{ node: "node-2", id: "reboot", from: "good", to: "warn" }, { node: "node-3", id: "hy2_masq", from: "good", to: "warn" }] : [],
  }));
  const catalog = (block, list) => list.map(([id, group, title, why]) => ({ id, block, group, title, why }));
  return demoDelay({
    blocks,
    titles: { server: "Аудит сервера", dpi: "Защита от РКН (ТСПУ)" },
    groups: [...DEMO_AUDIT_GROUPS.map(([id, title]) => ({ block: "server", id, title })),
      ...DEMO_DPI_GROUPS.map(([id, title]) => ({ block: "dpi", id, title }))],
    catalog: [...catalog("server", DEMO_AUDIT_CATALOG), ...catalog("dpi", DEMO_DPI_CATALOG)],
    nodes: demoNodes().map(({ name, addr, title }) => ({ name, addr, title })),
    history,
    settings: { cron: "30 5 * * * /usr/local/bin/iof audit cron >/dev/null 2>&1", tg: true },
    error: null,
    busy: false,
    migrate: null,
  });
}

function demoAuditJob(body) {
  const names = demoNodes().map((n) => n.name).filter((n) => !body.node || n === body.node);
  const down = names.includes("node-5");
  const lines = [`$ iof ${body.node ? `-n ${body.node} ` : ""}audit run ${body.block}`, `Проверяю узлы: ${names.length}, одновременно до 20`,
    ...names.filter((n) => n !== "node-5").map((n) => `== ${n}: проверен`)];
  if (down) lines.push("Ошибки (1):", "  node-5               нет связи по SSH");
  lines.push("Подробно и как исправить: sudo iof audit show [узел], в панели — страница «Безопасность»");
  const title = body.block === "dpi" ? "Защита от РКН" : "Аудит сервера";
  return demoRunJob("audit", `${title}: ${body.node || "все узлы"}`, lines, down ? "warn" : "ok", () => {
    demoAuditState.at[body.block] = Math.floor(Date.now() / 1000);
    demoAuditState.runs.push({ at: demoAuditState.at[body.block], block: body.block, nodes: names.length });
  });
}
