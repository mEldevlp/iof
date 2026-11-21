"use strict";

// Страница «Сервис»: обновление iof, расписание обслуживания, задания и журнал cron, запуски из панели.

const svc = { info: null, channel: "stable", jobs: [], schedule: null, saving: null, updates: null, checking: false, updating: null, request: null };
const scheduleDefaults = { nightly: "04:00", reach: "04:10" };


// Форматирование

// "e741874 2026-11-01 с правками" -> e741874 от 01.11.2026, с правками
function fmtVersion(v) {
  const m = /^(\S+) (\d{4})-(\d\d)-(\d\d)(.*)$/.exec(v || "");
  if (!m) return v ? `<code>${esc(v)}</code>` : '<span class="muted">неизвестно</span>';
  return `<code>${esc(m[1])}</code> от ${m[4]}.${m[3]}.${m[2]}${m[5] ? `<span class="muted">,${esc(m[5])}</span>` : ""}`;
}

// "2026-11-01 12:05:00" -> 01.11.2026 12:05
function fmtStamp(s) {
  const m = /^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d)/.exec(s || "");
  return m ? `${m[3]}.${m[2]}.${m[1]} ${m[4]}:${m[5]}` : esc(s);
}

// Расписание cron по-русски для частых случаев: */5 * * * * и 0 4 * * *
function cronHuman(line) {
  const f = line.trim().split(/\s+/);
  if (f[0] === "@reboot") return "при загрузке сервера";
  if (["@daily", "@midnight"].includes(f[0])) return "каждый день в 00:00";
  if (f.length < 5) return "";
  let m;
  if ((m = /^\*\/(\d+)$/.exec(f[0])) && f.slice(1, 5).every((x) => x === "*")) return `каждые ${m[1]} мин`;
  if (/^\d+$/.test(f[0]) && /^\d+$/.test(f[1]) && f.slice(2, 5).every((x) => x === "*")) {
    return `каждый день в ${f[1].padStart(2, "0")}:${f[0].padStart(2, "0")}`;
  }
  return "";
}

function cronCell(line) {
  const when = line.trim().split(/\s+/).slice(0, line.trim().startsWith("@") ? 1 : 5).join(" ");
  const human = cronHuman(line);
  return `<code>${esc(when)}</code>${human ? ` · ${human}` : ""}`;
}

function kv(rows) {
  return rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v}</dd>`).join("");
}

// Когда была задача: время сегодня или дата и время, плюс длительность
function fmtJobTime(j) {
  const d = new Date(j.started * 1000);
  const today = d.toDateString() === new Date().toDateString();
  const when = today ? d.toLocaleTimeString("ru-RU") : d.toLocaleString("ru-RU", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
  return j.finished ? `${when} · ${fmtMs(Math.round((j.finished - j.started) * 1000))}` : when;
}


// Отрисовка

function renderVersion() {
  const i = svc.info;
  const open = $("#version details")?.open;
  const rows = [
    ["Установлена", fmtVersion(i.version)],
    ["Клон", `<span class="mono">${esc(i.src)}</span>${i.src_version ? `, ${fmtVersion(i.src_version)}` : ' <span class="muted">— git-клона нет</span>'}`],
  ];
  if (i.update_log) {
    const when = new Date(i.update_log.at * 1000).toLocaleString("ru-RU", { dateStyle: "short", timeStyle: "short" });
    rows.push(["Обновлялась", `${when} из панели <details class="more"${open ? " open" : ""}><summary>вывод iof update</summary>
      <pre class="code">${esc(i.update_log.lines.join("\n"))}</pre></details>`]);
  }
  $("#version").innerHTML = kv(rows);
  renderUpdates();
}

function renderUpdates() {
  const i = svc.info, u = svc.updates;
  const target = u?.channels?.[svc.channel];
  const names = { stable: "Стабильная", test: "Тестовая" };
  let html = "";
  if (i.error) {
    html = `<div class="note crit">${icon("crit")}<div>iof не ответил: ${esc(i.error)}</div></div>`;
  } else if (svc.checking) {
    html = `<div class="note"><span class="spinner" aria-hidden="true"></span><div>Проверяю опубликованные релизы…</div></div>`;
  } else if (u?.error) {
    html = `<div class="note crit">${icon("crit")}<div>Не удалось проверить: ${esc(u.error)}</div></div>`;
  } else if (u?.channels) {
    html = `<dl class="kv">${kv(Object.entries(names).map(([channel, name]) => [name,
      u.channels[channel]?.tag ? `<code>${esc(u.channels[channel].tag)}</code>` : '<span class="muted">нет публикации</span>']))}</dl>`;
    const installed = names[u.installed_channel] || "не определён";
    html += `<p class="hint pad">Канал установленной версии: ${esc(installed)}.</p>`;
    const state = target?.state || "missing";
    const messages = {
      missing: "В выбранном канале пока нет опубликованных релизов.",
      current: "Этот коммит уже установлен. Переустановка не нужна.",
      older: svc.channel === "stable" ? "Стабильная версия старее установленной. Возврат доступен отдельным действием с подтверждением." : "Тестовый выпуск старее установленного коммита. Понижение не предлагается.",
      diverged: "История выбранного релиза разошлась с установленной версией. Установка запрещена.",
      update: `Можно установить ${svc.channel === "test" ? "тестовую" : "стабильную"} версию ${target?.tag || ""}.`,
    };
    const level = state === "current" ? "good" : ["older", "update"].includes(state) ? "warn" : "none";
    html += `<div class="note ${level}">${icon(level)}<div>${esc(messages[state] || messages.missing)}</div></div>`;
    if (target?.commits?.length) html += `<ul class="commits">${target.commits.map((c) => `<li><code>${esc(c.hash)}</code>${esc(c.subject)} <span class="muted">${esc(c.date)}</span></li>`).join("")}</ul>`;
  }
  $("#updates").innerHTML = html;
  if (svc.checking) $("#updates").setAttribute("aria-busy", "true");
  else $("#updates").removeAttribute("aria-busy");
  const busy = !!svc.updating || !!i.update_busy || svc.checking;
  $("#check-updates").disabled = busy || !i.src_version;
  $("#update-channel").disabled = busy || !u?.channels || !!u.error;
  $("#update-channel").value = svc.channel;
  $("#update").disabled = busy || !!u?.error || target?.state !== "update";
  const stable = u?.channels?.stable;
  $("#rollback").hidden = stable?.state !== "older" || !!u?.error;
  $("#rollback").disabled = busy;
  $("#rollback").textContent = `Вернуться на стабильную ${stable?.tag || ""}`;
}

function renderCheck() {
  const i = svc.info, c = i.check;
  const cron = svc.schedule ? svc.schedule.jobs.find((j) => j.kind === "check")?.schedule
    : i.cron.find((l) => /\biof check\b(?!-)/.test(l));
  let last = '<span class="muted">ещё не было</span>';
  if (c) {
    const res = c.bad
      ? badge("crit", `проблемы на ${c.bad} из ${c.total}`) + ` <span class="muted">${esc(c.problems.join(", "))}</span>`
      : badge("good", `все ${c.total} в порядке`);
    const stale = cron && Date.now() / 1000 - c.at > 3600 ? ` ${badge("warn", "давно, проверь cron")}` : "";
    const when = new Date(c.at * 1000).toLocaleString("ru-RU", { dateStyle: "short", timeStyle: "short" });
    last = `${when}${stale}<span class="sub-line">${res}</span>`;
  }
  const [tg, tgHint] = tgView(i.bot, i.tg, "nodes", "Узлы");
  $("#check").innerHTML = kv([
    ["Расписание", cron ? cronCell(cron) : badge("warn", "не запланирована")],
    ["Telegram", tg],
    ["Последняя", last],
    ["Раз в сутки", dailyCell(i.daily)],
  ]);
  const hints = [];
  if (!cron) hints.push("В «Задачах панели» укажи расписание <code>*/5 * * * *</code> и команду <code>/usr/local/bin/iof check >/dev/null 2>&1</code>.");
  if (tgHint) hints.push(tgHint);
  if ((i.bot || i.tg) && c) hints.push("В Telegram уходит сообщение, только когда состояние узла меняется.");
  hints.push("Раз в сутки <code>iof check</code> ещё проверяет, вышла ли новая версия iof и отвечают ли с узлов российские серверы (<code>RU_TARGETS</code> в <code>/root/iof/iof.env</code>): об этом бот пишет тем, кому отмечены «Обновления iof» и «Доступ к РФ». Сейчас: <code>sudo iof check --daily</code>.");
  $("#check-hint").hidden = !hints.length;
  $("#check-hint").innerHTML = hints.join("<br>");
}

// Ежедневная часть iof check: когда была, обновления iof, доступ к российским серверам с узлов
function dailyCell(d) {
  if (!d) return '<span class="muted">ещё не было</span>';
  const when = new Date(d.at * 1000).toLocaleString("ru-RU", { dateStyle: "short", timeStyle: "short" });
  const lines = [];
  if (d.updates === null) lines.push(badge("none", "обновления не проверены"));
  else lines.push(d.updates_release ? badge("warn", `доступен релиз ${d.updates_release}`) : badge("good", "обновлений нет"));
  const ru = d.ru;
  if (d.ru_off) lines.push(badge("none", "доступ к РФ не проверяется: RU_TARGETS пуст"));
  else if (ru) {
    if (ru.cut.length) lines.push(badge("crit", `РФ недоступна с: ${ru.cut.join(", ")}`));
    if (ru.noinet.length) lines.push(badge("warn", `нет интернета: ${ru.noinet.join(", ")}`));
    if (!ru.cut.length && !ru.noinet.length) lines.push(badge("good", `российские серверы отвечают с узлов: ${ru.nodes}`));
    if (ru.down.length) lines.push(badge("none", `не проверены, нет связи: ${ru.down.join(", ")}`));
  }
  return `${when}${lines.map((l) => `<span class="sub-line">${l}</span>`).join("")}`;
}

function renderNightly() {
  const i = svc.info, n = i.nightly, local = i.nightly_local;
  const cron = svc.schedule ? svc.schedule.jobs.find((j) => j.kind === "nightly")?.schedule
    : i.cron.find((l) => l.includes("iof-nightly"));
  let last = '<span class="muted">ещё не было</span>';
  if (n) {
    const m = /с ошибкой: (\d+)/.exec(n.summary);
    const res = !n.summary ? badge("warn", "итога в логе нет") : m && +m[1] ? badge("warn", n.summary.replace("Выполнено", "запущено")) : badge("good", n.summary.replace("Выполнено", "запущено"));
    last = `${fmtStamp(n.started)}<span class="sub-line">${res}</span>`;
  }
  // Итог запуска приходит только через бота: в TG_CHAT без бота уходят лишь узлы и аудит
  const [tg, tgHint] = tgView(i.bot, false, "nightly", "Ночное обслуживание");
  const rows = [
    ["Расписание", cron ? cronCell(cron) : badge("warn", "не запланировано")],
    ["Последний запуск", last],
    ["Telegram", tg],
  ];
  if (local) {
    const steps = local.steps.map((s) => {
      const m = /^\S+ (\d\d:\d\d):\d\d (.*)$/.exec(s);
      return m ? `${m[1]} ${esc(m[2])}` : esc(s);
    }).join("<br>");
    rows.push(["Этот сервер", steps + local.errors.map((e) => `<span class="sub-line">${icon("crit")} ${esc(e)}</span>`).join("")]);
  }
  $("#nightly").innerHTML = kv(rows);
  const hints = [];
  if (n) hints.push("Здесь видно, на скольких узлах запустилось обновление и перезагрузка. Как прошло на узле — в его <code>/var/log/iof-nightly.log</code>");
  if (cron && tgHint) hints.push(tgHint);
  $("#nightly-hint").hidden = !hints.length;
  $("#nightly-hint").innerHTML = hints.join("<br>");
  $("#nightly-more").hidden = !n;
  $("#nightly-log").textContent = n ? n.log.join("\n") : "";
}

function renderSchedule() {
  const plan = svc.schedule;
  if (!plan) return;
  const busy = !!svc.saving || !!svc.info?.migrate;
  $("#cron-add").disabled = busy || !!plan.error;
  for (const button of document.querySelectorAll(".cron-actions button")) button.disabled = busy;
  $("#schedule-zone").textContent = `Время управляющего сервера · ${plan.zone}`;
  for (const [kind, fallback] of Object.entries(scheduleDefaults)) {
    const data = plan.schedules[kind];
    const form = $(`#schedule-${kind}`);
    const input = form.querySelector("input");
    const shown = data.time || fallback;
    if (!input.dataset.saved || input.value === input.dataset.saved) input.value = shown;
    input.dataset.saved = shown;
    input.disabled = busy || !!data.error;
    form.querySelector("button").disabled = input.disabled;
    form.querySelector("[data-state]").textContent = svc.saving === kind ? "Сохраняю…"
      : data.error || (data.time ? `Каждый день в ${data.time}` : "Расписание ещё не задано");
  }
}

function renderCronTasks() {
  const list = $("#cron-tasks");
  const open = new Set([...list.querySelectorAll("details[open]")].map((d) => d.dataset.id));
  const plan = svc.schedule;
  $("#cron-count").textContent = plan.jobs.length || "";
  list.innerHTML = plan.jobs.map((j, index) => {
    const id = `${j.source}:${j.number}`;
    return `<li><details data-id="${esc(id)}"${open.has(id) ? " open" : ""}>
      <summary><span class="item-title">${esc(j.title)}</span><span class="item-meta">${esc(cronHuman(j.schedule) || j.schedule)}</span></summary>
      <dl class="kv">${kv([
        ...(j.description ? [["Действие", esc(j.description)]] : []),
        ["Расписание", `<code>${esc(j.schedule)}</code>`],
        ["Пользователь", esc(j.user)],
        ["Источник", `<code>${esc(j.source)}</code>`],
      ])}</dl>
      <pre class="code cron-command">${esc(j.command)}</pre>
      ${j.revision ? `<div class="actions cron-actions" data-index="${index}">
        ${j.type === "script" ? "" : `<button class="btn small" type="button" data-cron-action="edit">${j.managed ? "Изменить время" : "Изменить"}</button>`}
        <button class="btn small danger" type="button" data-cron-action="delete">${j.type === "script" ? "Отключить" : "Удалить"}</button>
      </div>` : ""}
    </details></li>`;
  }).join("") || `<li class="empty">${plan.error ? "Список cron недоступен." : "Заданий cron пока нет."}</li>`;
}

function applySchedule(plan) {
  svc.schedule = plan;
  formError(plan.error, "#schedule-error");
  renderCronTasks();
  renderSchedule();
  if (svc.info) {
    renderCheck();
    renderNightly();
  }
}

function cronFields() {
  const source = $("#cron-source").value;
  const anacron = svc.schedule.sources.find((s) => s.path === source)?.type === "anacron";
  $("#cron-user").disabled = anacron || source === "user" && !!svc.cronTarget;
  if (anacron) $("#cron-user").value = "root";
  $("#cron-expression").placeholder = anacron ? "1 5 my-job" : "30 5 * * 1-5";
  $("#cron-format").textContent = anacron ? "Период в днях, задержка в минутах и имя задания."
    : "Минуты, часы, день месяца, месяц, день недели. Можно ввести @reboot или @daily.";
}

function openCronDialog(action, job = null) {
  if (!svc.schedule || svc.saving || svc.info?.migrate) return;
  if (action === "edit" && job.managed && !$("#schedule-reach-time").disabled) {
    $("#schedule-reach-time").focus();
    return;
  }
  svc.cronTarget = job;
  svc.cronAction = action;
  const deleting = action === "delete";
  const script = job?.type === "script";
  $("#cron-fields").hidden = deleting;
  $("#cron-delete-details").hidden = !deleting;
  const submit = $("#cron-submit");
  submit.classList.toggle("danger", deleting);
  submit.classList.toggle("primary", !deleting);
  submit.textContent = deleting ? (script ? "Отключить" : "Удалить") : "Сохранить";
  $("#cron-dialog-title").textContent = deleting ? (script ? "Отключить скрипт cron?" : "Удалить задание cron?")
    : action === "edit" ? "Изменить задание cron" : "Добавить задание cron";
  formError("", "#cron-edit-error");
  if (deleting) {
    $("#cron-delete-note").textContent = script ? "Скрипт потеряет право на исполнение, и run-parts пропустит его."
      : job.managed ? "Будут удалены ежедневный запуск проверки из РФ и её запуск после перезагрузки."
      : `Расписание ${job.schedule} · ${job.user} · ${job.source}`;
    $("#cron-delete-command").textContent = job.command;
  } else {
    const source = $("#cron-source");
    const paths = new Set(svc.schedule.sources.map((s) => s.path));
    if (job && job.type !== "user") paths.add(job.source);
    source.replaceChildren(new Option("Crontab пользователя", "user"), ...[...paths].map((p) => new Option(p, p)));
    source.value = job && job.type !== "user" ? job.source : "user";
    source.disabled = !!job;
    const users = new Set(svc.schedule.users);
    if (job) users.add(job.user);
    $("#cron-user").replaceChildren(...[...users].map((u) => new Option(u, u)));
    $("#cron-user").value = job?.user || "root";
    $("#cron-expression").value = job?.schedule || "";
    $("#cron-command").value = job?.command || "";
    cronFields();
  }
  $("#cron-dialog").showModal();
  $(deleting ? "#cron-cancel" : "#cron-expression").focus();
}

async function submitCron(event) {
  event.preventDefault();
  if (svc.saving) return;
  const action = svc.cronAction;
  const job = svc.cronTarget;
  const data = { action, source: job?.source || $("#cron-source").value };
  if (job) Object.assign(data, { number: job.number, revision: job.revision });
  if (action !== "delete") {
    Object.assign(data, { user: $("#cron-user").value, schedule: $("#cron-expression").value,
      command: $("#cron-command").value });
    if (!data.schedule.trim() || !data.command.trim()) {
      formError("Введи расписание и команду.", "#cron-edit-error");
      $(data.schedule.trim() ? "#cron-command" : "#cron-expression").focus();
      return;
    }
  }
  svc.saving = "cron";
  $("#cron-submit").disabled = $("#cron-cancel").disabled = true;
  formError("", "#cron-edit-error");
  renderSchedule();
  try {
    applySchedule(DEMO ? demoChangeCron(data) : await postJson("api/service/schedule", data));
    $("#cron-dialog").close();
    const message = $("#cron-message");
    message.textContent = action === "add" ? "Задание добавлено." : action === "edit" ? "Задание изменено."
      : job.type === "script" ? "Скрипт отключён." : "Задание удалено.";
    message.hidden = false;
  } catch (e) {
    formError(e.message, "#cron-edit-error");
  } finally {
    svc.saving = null;
    $("#cron-submit").disabled = $("#cron-cancel").disabled = false;
    renderSchedule();
    if (!$("#cron-dialog").open) $("#cron-add").focus();
  }
}

function renderReach() {
  const result = svc.info.reach;
  $("#reach-more").hidden = !result;
  if (!result) return;
  $("#reach-summary").textContent = `Последняя проверка · ${fmtStamp(result.started)}`;
  $("#reach-log").textContent = result.log.join("\n");
}

async function loadSchedule(request) {
  const previous = svc.schedule;
  try {
    const plan = DEMO ? demoSchedule() : await getJson("api/service/schedule", request.signal);
    if (request !== svc.request || svc.saving || previous !== svc.schedule) return;
    applySchedule(plan);
  } catch (e) {
    if (request === svc.request) formError(`Не удалось загрузить расписание: ${e.message}`, "#schedule-error");
  }
}

async function saveSchedule(event, kind) {
  event.preventDefault();
  if (svc.saving) return;
  const at = event.currentTarget.querySelector("input").value;
  formError("", "#schedule-error");
  svc.saving = kind;
  renderSchedule();
  try {
    applySchedule(DEMO ? demoSchedule(kind, at) : await postJson("api/service/schedule", { task: kind, time: at }));
  } catch (e) {
    formError(e.message, "#schedule-error");
  } finally {
    svc.saving = null;
    renderSchedule();
  }
}

async function loadCronLog() {
  const button = $("#load-cron-log");
  if (button.disabled) return;
  button.disabled = true;
  const source = $("#cron-log-source");
  const log = $("#cron-log");
  source.textContent = "Загружаю журнал…";
  try {
    const data = DEMO ? demoCronLog() : await getJson("api/service/cron-log");
    source.textContent = data.error || `${data.source} · последние ${data.lines.length} ${plural(data.lines.length, ["запись", "записи", "записей"])}`;
    log.textContent = data.lines.join("\n");
    log.hidden = !data.lines.length;
    button.textContent = "Обновить журнал";
  } catch (e) {
    source.textContent = `Не удалось загрузить журнал: ${e.message}`;
  } finally {
    button.disabled = false;
  }
}

// Список задач перерисовывается целиком, раскрытые остаются раскрытыми
function renderJobs() {
  const open = new Set([...document.querySelectorAll("#jobs details[open]")].map((d) => d.dataset.id));
  const jobs = svc.jobs;
  $("#jobs-count").textContent = jobs.length || "";
  $("#jobs").innerHTML = jobs.length ? jobs.map((j) => {
    const [lvl, label] = JOB_STATES[j.state] || JOB_STATES.error;
    const st = j.state === "running" ? `<span class="st"><span class="spinner" aria-hidden="true"></span>${label}</span>` : badge(lvl, label);
    return `<li><details data-id="${esc(j.id)}"${open.has(j.id) ? " open" : ""}>
      <summary><span class="item-title">${esc(j.title)}</span>${st}<span class="item-meta">${fmtJobTime(j)}</span></summary>
      <pre class="log">${esc(j.log.join("\n"))}</pre>
    </details></li>`;
  }).join("") : `<li class="empty">Задач пока не было. Они появляются, когда что-то запускаешь из панели:
    добавление сервера, группы ссылок, действия с узлом, обновление.</li>`;
}

function render() {
  renderMigrate(svc.info.migrate);
  renderVersion();
  renderCheck();
  renderNightly();
  renderReach();
  renderSchedule();
}

async function loadInfo({ replace = false } = {}) {
  svc.request?.abort();
  const request = svc.request = new AbortController();
  const finish = !svc.info || replace ? skeletonRegions($("#service-info")) : null;
  $("#refresh").setAttribute("aria-busy", "true");
  const jobs = loadJobs(request, replace);
  const schedule = loadSchedule(request);
  try {
    const info = DEMO ? await demoService(false) : await getJson("api/service", request.signal);
    if (request !== svc.request) return false;
    finish?.();
    svc.info = info;
    if (svc.updating) svc.updating.from ??= info.version;
    $("#alert").hidden = true;
    render();
    await Promise.all([jobs, schedule]);
    return request === svc.request;
  } catch (e) {
    if (request !== svc.request) return false;
    $("#alert").hidden = false;
    $("#alert").innerHTML = `${icon("crit")} Нет связи с панелью: ${esc(e.message)}`;
    return false;
  } finally {
    finish?.();
    if (request === svc.request) $("#refresh").removeAttribute("aria-busy");
  }
}

async function loadJobs(request, replace) {
  const list = $("#jobs");
  const finish = !svc.jobsReady || replace ? skeleton(list, skeletonMarkup(list, "jobs", 3)) : null;
  try {
    const jobs = DEMO ? demoJobs() : (await getJson("api/jobs", request.signal)).jobs;
    if (request !== svc.request) return;
    finish?.();
    svc.jobs = jobs;
    svc.jobsReady = true;
    $("#jobs-error").hidden = true;
    renderJobs();
    // Страницу открыли, пока обновление уже идёт.
    const running = jobs.find((j) => j.kind === "service" && j.state === "running");
    if (running && !svc.updating) {
      const command = running.log.join("\n");
      const revision = /--revision ([0-9a-f]{40})\b/.exec(command)?.[1];
      const tag = /--tag (v\d+\.\d+)\b/.exec(command)?.[1];
      svc.updating = { id: running.id, target: revision && tag ? { revision, tag } : null,
        from: svc.info?.version, last: running, started: running.started };
      renderUpdateJob(running);
      pollUpdate();
    }
  } catch (e) {
    if (request === svc.request) formError(`Не удалось загрузить задачи: ${e.message}`, "#jobs-error");
  } finally {
    finish?.();
  }
}

async function checkUpdates() {
  if (!svc.info || svc.checking) return;
  svc.checking = true;
  renderUpdates();
  try {
    const d = DEMO ? await demoService(true) : await getJson("api/service?fetch=1");
    svc.updates = d.updates;
  } catch (e) {
    svc.updates = { error: e.message, commits: [] };
  }
  svc.checking = false;
  renderUpdates();
}


// Обновление. Пока панель жива, в карточке идёт лог задачи. Потом install.sh перезапускает панель:
// запросы не проходят, а после перезапуска задачи уже нет. Тогда сравниваем версию с той, что была

async function update(rollback = false) {
  const channel = rollback ? "stable" : svc.channel;
  const target = svc.updates?.channels?.[channel];
  if (!target?.tag || svc.updating || svc.checking) return;
  const question = rollback
    ? `Вернуться на стабильную ${target.tag}? Это понижение версии iof и панели. Настройки сохраняются, но старый код может не поддерживать новые возможности. Подтверждаешь возврат?`
    : `Установить ${channel === "test" ? "тестовую" : "стабильную"} версию ${target.tag}? Будет установлен именно этот тег. После установки панель перезапустится.`;
  if (!confirm(question)) return;
  formError("", "#action-error");
  try {
    const body = { action: rollback ? "rollback" : "update", channel, tag: target.tag, revision: target.revision };
    if (rollback) body.confirm_rollback = true;
    const id = DEMO ? demoUpdateJob(body) : (await postJson("api/service", body)).job;
    svc.updating = { id, target: { ...target }, channel, from: svc.info.version, last: null, started: Date.now() / 1000 };
    renderUpdates();
    $("#job").scrollIntoView({ behavior: "smooth", block: "nearest" });
    pollUpdate();
  } catch (e) {
    formError(e.message, "#action-error");
  }
}

function renderUpdateJob(j) {
  const lvl = renderJobCard(j);
  $("#job-hide").hidden = j.state === "running";
  const reason = failReason(j.log);
  if (j.state === "ok") jobResult("good", `${icon("good")}<div>Проверка обновления завершена. Подробности в логе.</div>`);
  else jobResult(lvl, j.state === "running" ? "" : `${icon("crit")}<div>Обновление не прошло${reason ? `: <b>${esc(reason)}</b>` : ", причина в логе"}</div>`);
}

async function pollUpdate() {
  const u = svc.updating;
  if (!u) return;
  const finish = !u.last && !u.polled ? pendingCard($("#job"), skeletonJob()) : null;
  u.polled = true;
  let jobs;
  try {
    jobs = DEMO ? demoJobs() : (await getJson("api/jobs")).jobs;
  } catch {
    if (u.last) {
      $("#job-state").innerHTML = `<span class="st"><span class="spinner" aria-hidden="true"></span>панель перезапускается…</span>`;
    }
    setTimeout(pollUpdate, 2000);
    return;
  } finally {
    finish?.();
  }
  const j = jobs.find((x) => x.id === u.id);
  if (j) {
    u.last = j;
    renderUpdateJob(j);
    if (j.state === "running") { setTimeout(pollUpdate, 1000); return; }
    svc.updating = null;
    loadInfo();
    return;
  }
  // Задачи нет: установщик перезапустил панель.
  svc.updating = null;
  if (!(await loadInfo())) { svc.updating = u; setTimeout(pollUpdate, 2000); return; }
  if (svc.info.update_busy) { svc.updating = u; setTimeout(pollUpdate, 1000); return; }
  const to = svc.info.version;
  $("#job").hidden = false;
  $("#job-hide").hidden = false;
  $("#job-title").textContent = "Обновление iof и панели";
  const reached = u.target && svc.info.revision === u.target.revision;
  $("#job-state").innerHTML = badge(reached ? "good" : "crit", reached ? "готово" : "цель не подтверждена");
  // Полный вывод — из /var/log/iof-update.log: задача успела показать только начало
  const ul = svc.info.update_log;
  $("#job-log").textContent = ul && ul.at > u.started - 60
    ? ["$ iof update --release", ...ul.lines].join("\n")
    : [...(u.last ? u.last.log : ["$ iof update --release"]), "… панель перезапущена"].join("\n");
  jobResult(reached ? "good" : "crit", !reached
    ? `${icon("crit")}<div>Панель доступна, но установка выбранного релиза ${esc(u.target?.tag || "")} не подтверждена. Проверь журнал обновления.</div>`
    : to === u.from
      ? `${icon("good")}<div>Версия ${fmtVersion(to)} уже установлена.</div>`
      : `${icon("good")}<div>Обновлено: ${fmtVersion(u.from)} → ${fmtVersion(to)}.
          <a href="${location.pathname}${location.search}">Перезагрузи страницу</a>, чтобы панель открылась в новой версии.</div>`);
  checkUpdates();
}

document.addEventListener("DOMContentLoaded", () => {
  $("#refresh").addEventListener("click", () => loadInfo({ replace: true }));
  $("#check-updates").addEventListener("click", checkUpdates);
  $("#update").addEventListener("click", () => update());
  $("#rollback").addEventListener("click", () => update(true));
  $("#update-channel").addEventListener("change", (event) => { svc.channel = event.target.value; renderUpdates(); });
  $("#job-hide").addEventListener("click", () => { $("#job").hidden = true; });
  for (const kind of Object.keys(scheduleDefaults)) {
    $(`#schedule-${kind}`).addEventListener("submit", (event) => saveSchedule(event, kind));
  }
  $("#cron-add").addEventListener("click", () => openCronDialog("add"));
  $("#cron-tasks").addEventListener("click", (event) => {
    const button = event.target.closest("[data-cron-action]");
    if (!button) return;
    const job = svc.schedule.jobs[button.closest(".cron-actions").dataset.index];
    openCronDialog(button.dataset.cronAction, job);
  });
  $("#cron-form").addEventListener("submit", submitCron);
  $("#cron-source").addEventListener("change", cronFields);
  $("#cron-cancel").addEventListener("click", () => $("#cron-dialog").close());
  $("#cron-dialog").addEventListener("cancel", (event) => { if (svc.saving) event.preventDefault(); });
  $("#load-cron-log").addEventListener("click", loadCronLog);
  $("#cron-journal-link").addEventListener("click", () => {
    if ($("#cron-log").hidden) loadCronLog();
  });
  loadInfo();
});
