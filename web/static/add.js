"use strict";

// Страница «Добавить сервер». Справка для формы: GET api/nodes/add-info,
// добавление: POST api/nodes (задача iof node add [+ iof hy2 install]), ход: GET api/jobs

const NAME_RE = /^[A-Za-z0-9._-]{1,40}$/;
const HOST_RE = /^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$/;
const USER_RE = /^[a-z_][a-z0-9_-]{0,31}$/;
const add = { info: null, jobId: null, timer: null, nameTouched: false };

const JOB_STATES = {
  running: ["none", "выполняется…"],
  ok: ["good", "готово"],
  warn: ["warn", "готово с ошибками"],
  error: ["crit", "ошибка"],
};

function authMode() {
  return document.querySelector('input[name="auth"]:checked').value;
}

// Имя узла по умолчанию из хоста, пока его не меняли руками: 203.0.113.44 -> node-203-0-113-44
function suggestName(host) {
  const short = host.split(".")[0];
  const base = /^\d+$/.test(short) ? "node-" + host.replace(/\./g, "-") : short;
  return base.replace(/[^A-Za-z0-9._-]/g, "").slice(0, 40);
}


// Проверка формы, те же правила, что у iof node add

function collect() {
  const v = (id) => $(id).value.trim();
  const data = {
    host: v("#f-host"), port: v("#f-port") || "22", name: v("#f-name"), title: v("#f-title"),
    user: v("#f-user") || "root", addr: v("#f-addr"), auth: authMode(), install_hy2: $("#f-hy2").checked,
  };
  const errors = {};
  if (!HOST_RE.test(data.host)) errors["#f-host"] = "IPv4 или домен: латиница, цифры, точка, дефис";
  const port = Number(data.port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) errors["#f-port"] = "1–65535";
  if (!NAME_RE.test(data.name)) errors["#f-name"] = "латиница, цифры, точка, дефис, подчёркивание";
  else if (add.info && add.info.nodes.includes(data.name)) errors["#f-name"] = "такой узел уже есть";
  if (data.title.includes("|")) errors["#f-title"] = "без символа |";
  if (!USER_RE.test(data.user)) errors["#f-user"] = "строчная латиница, цифры, _ и -";
  if (data.addr && !HOST_RE.test(data.addr)) errors["#f-addr"] = "IPv4 или домен";
  if (data.auth === "password") {
    data.password = $("#f-password").value;
    if (!data.password) errors["#f-password"] = "введи пароль";
  } else if (data.auth === "key") {
    data.key = $("#f-key").value;
    if (!/PRIVATE KEY|PuTTY/.test(data.key)) errors["#f-key"] = "вставь приватный ключ целиком";
  }
  return { data, errors };
}

function showErrors(errors) {
  document.querySelectorAll(".field-error").forEach((e) => e.remove());
  document.querySelectorAll("[aria-invalid]").forEach((e) => e.removeAttribute("aria-invalid"));
  for (const [sel, text] of Object.entries(errors)) {
    const input = $(sel);
    input.setAttribute("aria-invalid", "true");
    const p = document.createElement("p");
    p.className = "field-error";
    p.textContent = text;
    input.closest(".field").appendChild(p);
  }
  const first = Object.keys(errors)[0];
  if (first) $(first).focus();
}

function formError(text) {
  const el = $("#form-error");
  el.hidden = !text;
  el.innerHTML = text ? `${icon("crit")} ${esc(text)}` : "";
}


// Задача и её лог

function renderJob(job) {
  const card = $("#job");
  if (!job) { card.hidden = true; return; }
  card.hidden = false;
  const [lvl, label] = JOB_STATES[job.state] || JOB_STATES.error;
  $("#job-title").textContent = job.title;
  $("#job-state").innerHTML = job.state === "running"
    ? `<span class="st"><span class="spinner" aria-hidden="true"></span>${label}</span>` : badge(lvl, label);

  const log = $("#job-log");
  const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 24;
  log.textContent = job.log.join("\n");
  if (atBottom) log.scrollTop = log.scrollHeight;

  const demo = DEMO ? "?demo" : "";
  const name = esc(nameFromTitle(job.title));
  const added = job.log.some((l) => l.startsWith("$ iof hy2 install"));
  const reason = failReason(job.log);
  const result = {
    ok: `${icon("good")}<div>Сервер добавлен. <a href="./${demo}">Открыть обзор</a> · <a href="hy2.html${demo}">Ссылки Hysteria2</a></div>`,
    warn: `${icon("warn")}<div>Сервер добавлен, но Hysteria2 установить не удалось, подробности в логе.
      Повторить: <code>sudo iof hy2 install ${name}</code></div>`,
    error: added
      ? `${icon("crit")}<div>Сервер добавлен, но установка Hysteria2 прервалась. Повторить: <code>sudo iof hy2 install ${name}</code></div>`
      : `${icon("crit")}<div>Сервер не добавлен${reason ? `: <b>${esc(reason)}</b>` : ", причина в логе"}</div>`,
  }[job.state];
  $("#job-result").className = result ? `note ${lvl === "good" ? "good" : lvl}` : "";
  $("#job-result").innerHTML = result || "";
  $("#submit").disabled = job.state === "running";
}

// Причина из вывода iof: строка после «Не удалось (N)…» или «Ошибка: …»
function failReason(log) {
  const i = log.findIndex((l) => l.startsWith("Не удалось ("));
  if (i >= 0 && log[i + 1]) return log[i + 1].trim().split(/\s{2,}/).pop();
  const err = log.find((l) => l.startsWith("Ошибка: "));
  return err ? err.slice(8) : "";
}

function nameFromTitle(title) {
  const m = /сервера (\S+)/.exec(title);
  return m ? m[1] : "<имя>";
}

async function pollJob() {
  clearTimeout(add.timer);
  try {
    const jobs = DEMO ? demoJobs() : (await getJson("api/jobs")).jobs;
    const job = jobs.find((j) => j.id === add.jobId) || jobs[0];
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

async function getJson(url) {
  const r = await fetch(url, { cache: "no-store", credentials: "same-origin" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}


// Справка для формы: известные узлы, ключ iof, есть ли шаблон Hysteria2

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
  $("#known").innerHTML = i.nodes.length ? i.nodes.map((n) => `<span class="chip">${esc(n)}</span>`).join("") : '<span class="hint">пока пусто</span>';
  $("#pubkey-cmd").textContent = i.pubkey
    ? `mkdir -p ~/.ssh && echo '${i.pubkey}' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`
    : "Ключа iof ещё нет: он создаётся при первом добавлении сервера по паролю или ключу.";
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
  const { data, errors } = collect();
  showErrors(errors);
  if (Object.keys(errors).length) return;

  $("#submit").disabled = true;
  try {
    let jobId;
    if (DEMO) {
      jobId = demoStart(data);
    } else {
      const r = await fetch("api/nodes", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-IOF-Request": "1" },
        body: JSON.stringify(data),
      });
      const body = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(body.error || `HTTP ${r.status}`);
      jobId = body.job;
    }
    // Секреты в странице больше не нужны
    $("#f-password").value = "";
    $("#f-key").value = "";
    add.jobId = jobId;
    $("#job").scrollIntoView({ behavior: "smooth", block: "start" });
    pollJob();
  } catch (err) {
    formError(err.message);
    $("#submit").disabled = false;
  }
}

document.addEventListener("DOMContentLoaded", () => {
  if (DEMO) document.querySelectorAll(".nav a").forEach((a) => { a.href += "?demo"; });

  document.querySelectorAll('input[name="auth"]').forEach((r) => r.addEventListener("change", () => {
    document.querySelectorAll(".auth-pane").forEach((p) => { p.hidden = p.dataset.auth !== authMode(); });
    $("#secret-note").hidden = authMode() === "installed";
  }));
  $("#f-host").addEventListener("input", () => {
    if (!add.nameTouched) $("#f-name").value = suggestName($("#f-host").value.trim());
  });
  $("#f-name").addEventListener("input", () => { add.nameTouched = $("#f-name").value !== ""; });
  $("#toggle-pass").addEventListener("click", () => {
    const p = $("#f-password");
    p.type = p.type === "password" ? "text" : "password";
    $("#toggle-pass").textContent = p.type === "password" ? "Показать" : "Скрыть";
  });
  // Файл ключа читается в браузере и уходит на сервер только при отправке формы
  $("#f-keyfile").addEventListener("change", async (e) => {
    const f = e.target.files[0];
    if (f) $("#f-key").value = await f.text();
    e.target.value = "";
  });
  $("#copy-pubkey").addEventListener("click", async () => {
    toast(await copyText($("#pubkey-cmd").textContent) ? "Команда скопирована" : "Не удалось скопировать");
  });
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
  demoJob = { id: "demo", title: `Добавление сервера ${d.name} (${d.host})`, state: "running", log: [] };
  let i = 0;
  const tick = () => {
    if (i < lines.length) { if (lines[i]) demoJob.log.push(lines[i]); i++; setTimeout(tick, 350); } else { demoJob.state = "ok"; }
  };
  tick();
  return "demo";
}
