"use strict";

// Страница «Сервис»: версия iof и обновление, проверка узлов по cron (iof check), ночное обслуживание
// и задачи панели. Данные: GET api/service[?fetch=1], GET api/jobs, обновление: POST api/service
// (задача iof update; в конце install.sh перезапускает панель, задача пропадает вместе с ней)

const svc = { info: null, jobs: [], updates: null, checking: false, updating: null };


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
  let m;
  if ((m = /^\*\/(\d+)$/.exec(f[0])) && f.slice(1, 5).every((x) => x === "*")) return `каждые ${m[1]} мин`;
  if (/^\d+$/.test(f[0]) && /^\d+$/.test(f[1]) && f.slice(2, 5).every((x) => x === "*")) {
    return `каждый день в ${f[1]}:${f[0].padStart(2, "0")}`;
  }
  return "";
}

function cronCell(line) {
  const when = line.trim().split(/\s+/).slice(0, 5).join(" ");
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
  const rows = [
    ["Установлена", fmtVersion(i.version)],
    ["Клон", `<span class="mono">${esc(i.src)}</span>${i.src_version ? `, ${fmtVersion(i.src_version)}` : ' <span class="muted">— git-клона нет</span>'}`],
  ];
  if (i.update_log) {
    const when = new Date(i.update_log.at * 1000).toLocaleString("ru-RU", { dateStyle: "short", timeStyle: "short" });
    rows.push(["Обновлялась", `${when} из панели <details class="more"><summary>вывод iof update</summary>
      <pre class="code">${esc(i.update_log.lines.join("\n"))}</pre></details>`]);
  }
  $("#version").innerHTML = kv(rows);

  const u = svc.updates;
  let html = "";
  if (i.error) {
    html = `<div class="note crit">${icon("crit")}<div>iof не ответил: ${esc(i.error)}</div></div>`;
  } else if (svc.checking) {
    html = `<div class="note"><span class="spinner" aria-hidden="true"></span><div>Проверяю: git fetch в ${esc(i.src)}…</div></div>`;
  } else if (u && u.error) {
    html = `<div class="note crit">${icon("crit")}<div>Не удалось проверить: ${esc(u.error)}</div></div>`;
  } else if (u && !u.commits.length) {
    html = `<div class="note good">${icon("good")}<div>Новых коммитов в <span class="mono">${esc(u.branch)}</span> нет</div></div>`;
  } else if (u) {
    html = `<div class="note warn">${icon("warn")}<div>Доступно обновление: ${u.commits.length}
      ${plural(u.commits.length, ["коммит", "коммита", "коммитов"])} в <span class="mono">${esc(u.branch)}</span></div></div>
      <ul class="commits">${u.commits.map((c) => `<li><code>${esc(c.hash)}</code>${esc(c.subject)} <span class="muted">${esc(c.date)}</span></li>`).join("")}</ul>`;
  } else if (i.src_version && i.version && i.src_version.split(" ")[0] !== i.version.split(" ")[0]) {
    html = `<div class="note warn">${icon("warn")}<div>В клоне не та версия, что установлена. Поставить её: «Обновить»
      или <code>sudo bash ${esc(i.src)}/install.sh</code></div></div>`;
  }
  $("#updates").innerHTML = html;
  $("#check-updates").disabled = svc.checking || !i.src_version;
  $("#update").disabled = !!svc.updating || !i.src_version;
}

function renderCheck() {
  const i = svc.info, c = i.check;
  const cron = i.cron.find((l) => /\biof check\b/.test(l));
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
  if (!cron) hints.push("Добавить в cron: <code>sudo crontab -e</code>, строка <code>*/5 * * * * /usr/local/bin/iof check >/dev/null 2>&1</code>");
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
  else lines.push(d.updates ? badge("warn", `вышла новая версия: ${d.updates} ${plural(d.updates, ["коммит", "коммита", "коммитов"])}`) : badge("good", "обновлений нет"));
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
  const cron = i.cron.find((l) => l.includes("iof-nightly"));
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
  if (!cron) hints.push("Добавить в cron: <code>sudo crontab -e</code>, строка <code>0 4 * * * /usr/local/sbin/iof-nightly</code>");
  if (n) hints.push("Здесь видно, на скольких узлах запустилось обновление и перезагрузка. Как прошло на узле — в его <code>/var/log/iof-nightly.log</code>");
  if (cron && tgHint) hints.push(tgHint);
  $("#nightly-hint").hidden = !hints.length;
  $("#nightly-hint").innerHTML = hints.join("<br>");
  $("#nightly-more").hidden = !n;
  $("#nightly-log").textContent = n ? n.log.join("\n") : "";
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
  renderJobs();
}

async function loadInfo() {
  $("#refresh").setAttribute("aria-busy", "true");
  try {
    svc.info = DEMO ? await demoService(false) : await getJson("api/service");
    svc.jobs = DEMO ? demoJobs() : (await getJson("api/jobs")).jobs;
    $("#alert").hidden = true;
    render();
    return true;
  } catch (e) {
    $("#alert").hidden = false;
    $("#alert").innerHTML = `${icon("crit")} Нет связи с панелью: ${esc(e.message)}`;
    return false;
  } finally {
    $("#refresh").removeAttribute("aria-busy");
  }
}

async function checkUpdates() {
  svc.checking = true;
  renderVersion();
  try {
    const d = DEMO ? await demoService(true) : await getJson("api/service?fetch=1");
    svc.updates = d.updates;
  } catch (e) {
    svc.updates = { error: e.message, commits: [] };
  }
  svc.checking = false;
  renderVersion();
}


// Обновление. Пока панель жива, в карточке идёт лог задачи. Потом install.sh перезапускает панель:
// запросы не проходят, а после перезапуска задачи уже нет. Тогда сравниваем версию с той, что была

async function update() {
  if (!confirm("Обновить iof и панель с GitHub? Это sudo iof update: git pull и install.sh. В конце панель перезапустится.")) return;
  formError("", "#action-error");
  try {
    const id = DEMO ? demoUpdateJob() : (await postJson("api/service", { action: "update" })).job;
    svc.updating = { id, from: svc.info.version, last: null, started: Date.now() / 1000 };
    renderVersion();
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
  jobResult(lvl, j.state === "running" ? "" : `${icon("crit")}<div>Обновление не прошло${reason ? `: <b>${esc(reason)}</b>` : ", причина в логе"}</div>`);
}

async function pollUpdate() {
  const u = svc.updating;
  if (!u) return;
  let jobs;
  try {
    jobs = DEMO ? demoJobs() : (await getJson("api/jobs")).jobs;
  } catch {
    if (u.last) {
      $("#job-state").innerHTML = `<span class="st"><span class="spinner" aria-hidden="true"></span>панель перезапускается…</span>`;
    }
    setTimeout(pollUpdate, 2000);
    return;
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
  // Задачи нет: панель перезапустилась с новой версией (или с той же, если новых коммитов не было)
  svc.updating = null;
  if (!(await loadInfo())) return;
  const to = svc.info.version;
  $("#job").hidden = false;
  $("#job-hide").hidden = false;
  $("#job-title").textContent = "Обновление iof и панели";
  $("#job-state").innerHTML = badge("good", "готово");
  // Полный вывод — из /var/log/iof-update.log: задача успела показать только начало
  const ul = svc.info.update_log;
  $("#job-log").textContent = ul && ul.at > u.started - 60
    ? ["$ iof update", ...ul.lines].join("\n")
    : [...(u.last ? u.last.log : ["$ iof update"]), "… панель перезапущена"].join("\n");
  jobResult("good", to === u.from
    ? `${icon("good")}<div>Панель перезапущена, версия та же: ${fmtVersion(to)}. Новых коммитов не было.</div>`
    : `${icon("good")}<div>Обновлено: ${fmtVersion(u.from)} → ${fmtVersion(to)}.
        <a href="${location.pathname}${location.search}">Перезагрузи страницу</a>, чтобы панель открылась в новой версии.</div>`);
}

document.addEventListener("DOMContentLoaded", async () => {
  $("#refresh").addEventListener("click", loadInfo);
  $("#check-updates").addEventListener("click", checkUpdates);
  $("#update").addEventListener("click", update);
  $("#job-hide").addEventListener("click", () => { $("#job").hidden = true; });
  await loadInfo();
  // Страницу открыли, пока обновление уже идёт
  const running = svc.jobs.find((j) => j.kind === "service" && j.state === "running");
  if (running && svc.info) {
    svc.updating = { id: running.id, from: svc.info.version, last: null };
    pollUpdate();
  }
});
