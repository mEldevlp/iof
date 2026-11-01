"use strict";

// Страница «Перенос»: управляющий сервер переезжает на другой, а этот остаётся узлом.
// Состояние: GET api/migrate, действия: POST api/migrate (задачи iof migrate start | finish | cancel),
// ход: GET api/jobs. На старом сервере страница начинает и отменяет перенос, на новом завершает

const TARGET_RE = /^[a-z_][a-z0-9_-]{0,31}@[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(:\d{1,5})?$/;
const mig = { info: null, jobId: null, timer: null };

// root@203.0.113.5:2222 -> { user, host, port }
function parseTarget(t) {
  const m = /^([^@]+)@([^:]+)(?::(\d+))?$/.exec(t || "");
  return m ? { user: m[1], host: m[2], port: m[3] || "22" } : null;
}

// Туннель к панели нового сервера на порт 8089, чтобы не мешал туннелю к этой
function tunnelCommand(peer) {
  const t = parseTarget(peer);
  return t ? `ssh ${t.port !== "22" ? `-p ${t.port} ` : ""}-L 8089:127.0.0.1:8088 ${t.user}@${t.host}` : "";
}

// "2026-11-01 10:03:15" -> "с 01.11.2026 10:03"
function fmtStarted(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})/.exec(s || "");
  return m ? `с ${m[3]}.${m[2]}.${m[1]} ${m[4]}:${m[5]}` : "";
}


// Состояние переноса: формы нет, если перенос уже идёт

function render() {
  const i = mig.info;
  const m = i.migrate;
  const role = m ? m.role : "";
  $("#form").hidden = role !== "";
  $("#source").hidden = role !== "source";
  $("#target").hidden = role !== "target";
  if (role === "source") {
    $("#source-peer").textContent = m.peer;
    $("#source-started").textContent = fmtStarted(m.started);
    $("#tunnel-cmd").textContent = tunnelCommand(m.peer);
  } else if (role === "target") {
    $("#target-peer").textContent = m.peer;
    $("#target-started").textContent = fmtStarted(m.started);
  } else {
    $("#f-self").placeholder = i.self_addr ? `root@${i.self_addr}` : "root@адрес-этого-сервера";
    $("#self-hint").textContent = i.self_addr
      ? `По SSH с ключом iof, как на обычный узел. Пусто — root@${i.self_addr}, порт SSH определится сам`
      : "Этот сервер не VPN-узел (в nodes.conf нет local), поэтому адрес нужно указать: root@адрес или root@адрес:порт";
    $("#pubkey-cmd").textContent = pubkeyCommand(i.pubkey);
    $("#copy-pubkey").disabled = !i.pubkey;
  }
}

async function loadInfo() {
  try {
    mig.info = DEMO ? demoInfo() : await getJson("api/migrate");
  } catch (e) {
    $("#alert").hidden = false;
    $("#alert").innerHTML = `${icon("crit")} Нет связи с панелью: ${esc(e.message)}`;
    return;
  }
  $("#alert").hidden = true;
  render();
}


// Задача и её лог. Итог зависит от действия: первая строка лога "$ iof migrate <действие> ..."

function renderJob(job) {
  const lvl = renderJobCard(job);
  if (!job) return;
  const running = job.state === "running";
  ["#submit", "#retry", "#cancel", "#finish"].forEach((sel) => { $(sel).disabled = running; });

  const action = (/^\$ iof migrate (\w+)/.exec(job.log[0] || "") || [])[1];
  const reason = esc(failReason(job.log));
  const why = reason ? `: <b>${reason}</b>` : ", причина в логе";
  const demo = DEMO ? "?demo" : "";
  const results = {
    start: {
      ok: `${icon("good")}<div>Управление скопировано. Открой панель нового сервера и заверши перенос там.</div>`,
      warn: `${icon("warn")}<div>Управление скопировано, но новый сервер видит не все узлы, список в логе.
        Почини доступ и проверь на нём <code>sudo iof status</code>, потом заверши перенос.</div>`,
      error: `${icon("crit")}<div>Перенос не прошёл${why}. Если изменения здесь уже заблокированы, повтори перенос или отмени его.</div>`,
    },
    finish: {
      ok: `${icon("good")}<div>Перенос завершён, управляющий сервер теперь этот. <a href="./${demo}">Открыть обзор</a></div>`,
      error: `${icon("crit")}<div>Перенос не завершён${why}</div>`,
    },
    cancel: {
      ok: `${icon("good")}<div>Перенос отменён, этот сервер снова управляющий без ограничений.</div>`,
      warn: `${icon("warn")}<div>Перенос отменён, но новый сервер недоступен: убери с него копию вручную, команда в логе.</div>`,
      error: `${icon("crit")}<div>Не удалось отменить перенос${why}</div>`,
    },
  };
  jobResult(lvl, (results[action] || {})[job.state]);
}

async function pollJob() {
  clearTimeout(mig.timer);
  try {
    const job = await pageJob("migrate", mig.jobId, demoJobs);
    renderJob(job);
    if (job && job.state === "running") {
      mig.timer = setTimeout(pollJob, 1000);
    } else if (job && job.id === mig.jobId) {
      mig.jobId = null;
      loadInfo();
    }
  } catch (e) {
    mig.timer = setTimeout(pollJob, 3000);
  }
}


// Действия

async function run(body, errorSel) {
  formError("", errorSel);
  try {
    mig.jobId = DEMO ? demoRun(body) : (await postJson("api/migrate", body)).job;
    $("#job").scrollIntoView({ behavior: "smooth", block: "start" });
    pollJob();
    return true;
  } catch (err) {
    formError(err.message, errorSel);
    return false;
  }
}

async function submit(e) {
  e.preventDefault();
  formError("");
  const errors = {};
  const data = collectLogin(errors);
  data.self = $("#f-self").value.trim();
  if (data.self && !TARGET_RE.test(data.self)) errors["#f-self"] = "вид root@адрес или root@адрес:порт";
  else if (!data.self && !mig.info.self_addr) errors["#f-self"] = "укажи адрес этого сервера";
  showErrors(errors);
  if (Object.keys(errors).length) return;
  if (!confirm(`Перенести управление на ${data.host}? Пока перенос не завершён или не отменён, изменения здесь будут заблокированы.`)) return;

  $("#submit").disabled = true;
  data.action = "start";
  if (await run(data, "#form-error")) clearSecrets();
  else $("#submit").disabled = false;
}

// Повтор: ключ iof на новом сервере уже лежит, пароль не нужен
function retry() {
  const m = mig.info.migrate;
  const t = parseTarget(m.peer);
  if (!t) return formError(`не разобрать адрес ${m.peer}`, "#source-error");
  run({ action: "start", host: t.host, port: t.port, user: t.user, auth: "installed", self: m.self || "" }, "#source-error");
}

function cancel() {
  const peer = mig.info.migrate.peer;
  if (!confirm(`Отменить перенос на ${peer}? С нового сервера будут удалены iof и копия данных, изменения, сделанные там, пропадут.`)) return;
  run({ action: "cancel" }, "#source-error");
}

function finish() {
  const skip = $("#f-skip-old").checked;
  const peer = mig.info.migrate.peer;
  const text = skip
    ? `Завершить перенос без старого сервера ${peer}? Снять с него iof придётся вручную.`
    : `Завершить перенос? С ${peer} уберутся панель, команды iof и задания cron, он останется VPN-узлом.`;
  if (!confirm(text)) return;
  run({ action: "finish", skip_old: skip }, "#target-error");
}

document.addEventListener("DOMContentLoaded", () => {
  keepDemoInLinks();
  document.querySelectorAll("[data-icon]").forEach((el) => { el.outerHTML = icon(el.dataset.icon); });
  if (DEMO) $("#overview-link").href += "?demo";
  initLoginForm();
  $("#form").addEventListener("submit", submit);
  $("#retry").addEventListener("click", retry);
  $("#cancel").addEventListener("click", cancel);
  $("#finish").addEventListener("click", finish);

  loadInfo();
  pollJob();
});


// Демо без сервера: ?demo — переноса нет, ?demo=source — идёт отсюда, ?demo=target — сюда

let demoJob = null;
let demoRole = new URLSearchParams(location.search).get("demo") || "";

function demoInfo() {
  const migrate = {
    source: { role: "source", peer: "root@203.0.113.50", self: "root@192.0.2.10", started: "2026-11-01 10:03:15" },
    target: { role: "target", peer: "root@192.0.2.10", self: "", started: "2026-11-01 10:03:15" },
  }[demoRole] || null;
  return {
    migrate,
    self_addr: "192.0.2.10",
    nodes: 6,
    pubkey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoDemoDemoDemoDemoDemoDemoDemoDemoDemo iof@main",
    busy: false,
  };
}

function demoJobs() {
  return demoJob ? [demoJob] : [];
}

function demoRun(d) {
  const host = d.host || "203.0.113.50";
  const scripts = {
    start: [
      `$ iof migrate start ${host} ${d.port || 22} --user ${d.user || "root"} --${d.auth === "installed" ? "key-installed" : d.auth + "-stdin"}`,
      `== Вход на root@${host}`, "   ключ iof работает",
      `== Проверка root@${host}`, "   ubuntu 24.04, можно переносить",
      `== Копирую на root@${host} данные iof, ключ iof и клон репозитория`,
      `== Ставлю iof на root@${host}`, "[new-server] ставлю git, python3 и qrencode", "[new-server] ставлю iof и панель",
      "iof: /usr/local/bin/iof (b5bf105 2026-10-31)", "iof-web: работает, http://127.0.0.1:8088/ (с компьютера через SSH-туннель)",
      "   готово, версия b5bf105",
      "== Проверка: видит ли новый сервер все узлы", `Узлов: 6, на связи с ${host}: 6`, "",
      `Управление скопировано на root@${host}. Этот сервер пока управляющий, но изменения на нём заблокированы.`,
    ],
    finish: [
      `$ iof migrate finish${d.skip_old ? " --skip-old" : ""}`,
      "== Снимаю управление со старого сервера root@192.0.2.10",
      "[main] из cron убраны задания iof", "[main] управление снято, сервер остался узлом",
      "В cron добавлено:", "  0 4 * * * /usr/local/sbin/iof-nightly", "",
      "Перенос завершён, управляющий сервер теперь этот.",
      "Старый сервер остался узлом. Его прежние данные iof: /root/iof.moved-20261101-101500, удали их, когда убедишься, что всё работает.",
    ],
    cancel: [
      "$ iof migrate cancel", "== Убираю копию с root@203.0.113.50", "[new-server] iof и копия данных удалены",
      "Перенос отменён, этот сервер снова управляющий без ограничений.",
    ],
  };
  const lines = scripts[d.action];
  const title = { start: `Перенос управления на ${host}`, finish: "Завершение переноса", cancel: "Отмена переноса" }[d.action];
  demoJob = { id: "demo-" + Date.now(), kind: "migrate", title, state: "running", log: [] };
  let i = 0;
  const tick = () => {
    if (i < lines.length) { if (lines[i]) demoJob.log.push(lines[i]); i++; setTimeout(tick, 300); return; }
    demoJob.state = "ok";
    demoRole = d.action === "start" ? "source" : "";
  };
  tick();
  return demoJob.id;
}
