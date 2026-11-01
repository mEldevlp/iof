"use strict";

// Страница «Добавить сервер». Справка для формы: GET api/nodes/add-info,
// добавление: POST api/nodes (задача iof node add [+ iof hy2 install]), ход: GET api/jobs.
// Поля входа на сервер и карточка задачи общие со страницей «Перенос», они в common.js

const NAME_RE = /^[A-Za-z0-9._-]{1,40}$/;
const add = { info: null, jobId: null, timer: null, nameTouched: false };

// Имя узла по умолчанию из хоста, пока его не меняли руками: 203.0.113.44 -> node-203-0-113-44
function suggestName(host) {
  const short = host.split(".")[0];
  const base = /^\d+$/.test(short) ? "node-" + host.replace(/\./g, "-") : short;
  return base.replace(/[^A-Za-z0-9._-]/g, "").slice(0, 40);
}


// Проверка формы, те же правила, что у iof node add

function collect() {
  const v = (id) => $(id).value.trim();
  const errors = {};
  const data = collectLogin(errors);
  Object.assign(data, { name: v("#f-name"), title: v("#f-title"), addr: v("#f-addr"), install_hy2: $("#f-hy2").checked });
  if (!NAME_RE.test(data.name)) errors["#f-name"] = "латиница, цифры, точка, дефис, подчёркивание";
  else if (add.info && add.info.nodes.includes(data.name)) errors["#f-name"] = "такой узел уже есть";
  if (data.title.includes("|")) errors["#f-title"] = "без символа |";
  if (data.addr && !HOST_RE.test(data.addr)) errors["#f-addr"] = "IPv4 или домен";
  return { data, errors };
}


// Задача и её лог

function renderJob(job) {
  const lvl = renderJobCard(job);
  if (!job) return;
  const demo = DEMO ? "?demo" : "";
  const name = esc(nameFromTitle(job.title));
  const added = job.log.some((l) => l.startsWith("$ iof hy2 install"));
  const reason = failReason(job.log);
  jobResult(lvl, {
    ok: `${icon("good")}<div>Сервер добавлен. <a href="./${demo}">Открыть обзор</a> · <a href="hy2.html${demo}">Ссылки Hysteria2</a></div>`,
    warn: `${icon("warn")}<div>Сервер добавлен, но Hysteria2 установить не удалось, подробности в логе.
      Повторить: <code>sudo iof hy2 install ${name}</code></div>`,
    error: added
      ? `${icon("crit")}<div>Сервер добавлен, но установка Hysteria2 прервалась. Повторить: <code>sudo iof hy2 install ${name}</code></div>`
      : `${icon("crit")}<div>Сервер не добавлен${reason ? `: <b>${esc(reason)}</b>` : ", причина в логе"}</div>`,
  }[job.state]);
  $("#submit").disabled = job.state === "running";
}

function nameFromTitle(title) {
  const m = /сервера (\S+)/.exec(title);
  return m ? m[1] : "<имя>";
}

async function pollJob() {
  clearTimeout(add.timer);
  try {
    const job = await pageJob("node", add.jobId, demoJobs);
    renderJob(job);
    if (job && job.state === "running") {
      add.timer = setTimeout(pollJob, 1000);
    } else if (job && job.id === add.jobId) {
      add.jobId = null;
      if (job.state !== "error") {
        $("#form").reset();
        add.nameTouched = false;
      }
      loadInfo();
    }
  } catch (e) {
    add.timer = setTimeout(pollJob, 3000);
  }
}


// Справка для формы: известные узлы, ключ iof, есть ли шаблон Hysteria2, идёт ли перенос

async function loadInfo() {
  try {
    add.info = DEMO ? demoAddInfo() : await getJson("api/nodes/add-info");
  } catch (e) {
    $("#alert").hidden = false;
    $("#alert").innerHTML = `${icon("crit")} Нет связи с панелью: ${esc(e.message)}`;
    return;
  }
  $("#alert").hidden = true;
  const i = add.info;
  renderMigrate(i.migrate);
  $("#known").innerHTML = i.nodes.length ? i.nodes.map((n) => `<span class="chip">${esc(n)}</span>`).join("") : '<span class="hint">пока пусто</span>';
  $("#pubkey-cmd").textContent = pubkeyCommand(i.pubkey);
  $("#copy-pubkey").disabled = !i.pubkey;
  if (!i.hy2_template) {
    $("#f-hy2").checked = false;
    $("#f-hy2").disabled = true;
    $("#hy2-hint").innerHTML = "Нет <code>/etc/hysteria/config.yaml</code> на этом сервере, ставить Hysteria2 не по чему";
  }
}


// Отправка

async function submit(e) {
  e.preventDefault();
  formError("");
  if (add.info && add.info.migrate && add.info.migrate.role === "source") {
    formError("Идёт перенос управления на другой сервер, добавлять серверы нужно уже там");
    return;
  }
  const { data, errors } = collect();
  showErrors(errors);
  if (Object.keys(errors).length) return;

  $("#submit").disabled = true;
  try {
    add.jobId = DEMO ? demoStart(data) : (await postJson("api/nodes", data)).job;
    clearSecrets();
    $("#job").scrollIntoView({ behavior: "smooth", block: "start" });
    pollJob();
  } catch (err) {
    formError(err.message);
    $("#submit").disabled = false;
  }
}

document.addEventListener("DOMContentLoaded", () => {
  keepDemoInLinks();
  initLoginForm();
  $("#f-host").addEventListener("input", () => {
    if (!add.nameTouched) $("#f-name").value = suggestName($("#f-host").value.trim());
  });
  $("#f-name").addEventListener("input", () => { add.nameTouched = $("#f-name").value !== ""; });
  $("#form").addEventListener("submit", submit);

  loadInfo();
  pollJob();
});


// Демо без сервера: ход задачи по таймеру

let demoJob = null;

function demoAddInfo() {
  return {
    nodes: ["main", "node-1", "node-2"],
    pubkey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoDemoDemoDemoDemoDemoDemoDemoDemoDemo iof@main",
    hy2_template: true,
    busy: false,
    migrate: null,
  };
}

function demoJobs() {
  return demoJob ? [demoJob] : [];
}

function demoStart(d) {
  const lines = [
    `$ iof node add ${d.name} ${d.host} ${d.title || "''"} ${d.port} --user ${d.user} --addr ${d.addr || d.host} --${d.auth === "installed" ? "key-installed" : d.auth + "-stdin"}`,
    "Раздаю SSH-ключ на узлы: 1, одновременно до 20",
    "Добавлено в nodes.conf: 1",
    `Дальше: sudo iof hy2 install ${d.name}`,
  ];
  if (d.install_hy2) {
    lines.push(`$ iof hy2 install ${d.name}`, "Шаблон конфига: /etc/hysteria/config.yaml (пароль, порт и маскировка будут как на этом сервере)",
      "Сертификат: свой на каждом узле, CN=bing.com", "Устанавливаю Hysteria2 на узлах: 1, одновременно до 20", "",
      "Установлено: 1", `  ${d.name} (v2.13.0)`, "Добавляю новые узлы в группы ссылок...", "Готово. Ссылки: sudo iof hy2 list");
  }
  demoJob = { id: "demo", kind: "node", title: `Добавление сервера ${d.name} (${d.host})`, state: "running", log: [] };
  let i = 0;
  const tick = () => {
    if (i < lines.length) { if (lines[i]) demoJob.log.push(lines[i]); i++; setTimeout(tick, 350); } else { demoJob.state = "ok"; }
  };
  tick();
  return "demo";
}
