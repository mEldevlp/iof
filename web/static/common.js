"use strict";

// Общее для страниц iof-web: каркас с боковым меню, форматирование, иконки, загрузка данных
// и автообновление. С параметром ?demo страницы работают на встроенных примерах (demo.js), без сервера.
// Подключается в <head> без defer, чтобы выбранная тема применилась до первой отрисовки

const DEMO = new URLSearchParams(location.search).has("demo");
const $ = (sel) => document.querySelector(sel);

// Хранилище браузера только для мелких настроек вида, может быть недоступно
const prefs = {
  get(key, def) {
    try { const v = localStorage.getItem("iof-web." + key); return v === null ? def : v; } catch { return def; }
  },
  set(key, value) {
    try { localStorage.setItem("iof-web." + key, value); } catch { /* приватный режим */ }
  },
};

// Тема: auto (как в системе), light или dark. Цвета обеих тем в app.css
function applyTheme(theme) {
  if (theme === "light" || theme === "dark") document.documentElement.dataset.theme = theme;
  else delete document.documentElement.dataset.theme;
}
applyTheme(prefs.get("theme", "auto"));


// Каркас страницы: боковое меню, переключатель темы, на узком экране меню по кнопке

function initTheme() {
  const buttons = document.querySelectorAll("[data-set-theme]");
  const mark = (theme) => buttons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.setTheme === theme)));
  mark(prefs.get("theme", "auto"));
  buttons.forEach((b) => b.addEventListener("click", () => {
    prefs.set("theme", b.dataset.setTheme);
    applyTheme(b.dataset.setTheme);
    mark(b.dataset.setTheme);
  }));
}

// Меню выезжает слева, закрывается по фону, Escape и переходу по ссылке
function initDrawer() {
  const btn = $("#menu-btn");
  if (!btn) return;
  const scrim = document.createElement("div");
  scrim.className = "scrim";
  document.body.appendChild(scrim);
  const isOpen = () => document.body.classList.contains("nav-open");
  const toggle = (open) => {
    document.body.classList.toggle("nav-open", open);
    btn.setAttribute("aria-expanded", String(open));
    if (open) $("#sidebar .nav a").focus();
  };
  btn.addEventListener("click", () => toggle(!isOpen()));
  scrim.addEventListener("click", () => toggle(false));
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && isOpen()) { toggle(false); btn.focus(); }
  });
}

// Демо-режим сохраняется при переходе между страницами
function keepDemoInLinks() {
  if (!DEMO) return;
  document.querySelectorAll(".sidebar a").forEach((a) => { a.href += "?demo"; });
  $("#demo-chip").hidden = false;
}

document.addEventListener("DOMContentLoaded", () => {
  keepDemoInLinks();
  initTheme();
  initDrawer();
});


// Форматирование

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function plural(n, forms) {
  const a = Math.abs(n) % 100, b = a % 10;
  if (a > 10 && a < 20) return forms[2];
  if (b === 1) return forms[0];
  if (b >= 2 && b <= 4) return forms[1];
  return forms[2];
}

function fmtMs(ms) {
  return ms < 1000 ? `${ms} мс` : `${Math.floor(ms / 1000)}.${Math.floor((ms % 1000) / 100)} с`;
}

function fmtUptime(s) {
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d} д ${h} ч`;
  if (h > 0) return `${h} ч ${m} мин`;
  return `${m} мин`;
}

// Объём в гигабайтах: gb(число, делитель до ГБ), как в iof
function gb(v, div) {
  const g = v / div;
  return g >= 10 ? g.toFixed(0) : g.toFixed(1);
}

function fmtTime(ts) {
  return new Date(ts * 1000).toLocaleTimeString("ru-RU");
}

function fmtCreated(s) {
  // "2026-10-31 12:03:15" -> "31.10.2026"
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s || "");
  return m ? `${m[3]}.${m[2]}.${m[1]}` : esc(s);
}

const ICONS = {
  good: '<path d="M4.5 8.2l2.3 2.3 4.7-4.9" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/><circle cx="8" cy="8" r="7" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  warn: '<path d="M8 1.8l6.6 11.6H1.4z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/><path d="M8 6.2v3.3" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="8" cy="11.4" r=".9" fill="currentColor"/>',
  crit: '<circle cx="8" cy="8" r="7" fill="currentColor"/><path d="M5.6 5.6l4.8 4.8M10.4 5.6l-4.8 4.8" stroke="#fff" stroke-width="1.7" stroke-linecap="round"/>',
  none: '<path d="M4.5 8h7" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>',
};

function icon(level, cls = "ico") {
  return `<svg class="${cls} ${level}" viewBox="0 0 16 16" aria-hidden="true">${ICONS[level]}</svg>`;
}

function badge(level, text) {
  return `<span class="st">${icon(level)}<span>${esc(text)}</span></span>`;
}

// Ячейка Hysteria2 узла, как в iof status
function hy2Cell(n, withSub = true) {
  const h = n.hy2;
  if (!h.installed) return '<span class="muted">не установлена</span>';
  let main;
  if (h.state !== "active") main = badge("crit", `не работает (${h.state || "?"})`);
  else if (!h.udp) main = badge("crit", `не слушает :${h.port}`);
  else main = badge("good", `работает :${h.port}`);
  if (!withSub) return main;
  const sub = [h.version, hy2Access(h)].filter(Boolean).join(" · ");
  return main + (sub ? `<span class="sub-line">${esc(sub)}</span>` : "");
}

function hy2Access(h) {
  return h.auth === "password" ? "общий пароль" : h.auth === "userpass" ? `${h.users} польз.` : "";
}

// Оценка состояния узла и его ячейки, общие для «Обзора» и страницы узла. Пороги те же, что в iof status

function warnings(n) {
  if (!n.reachable) return [];
  const w = [];
  if (n.cpu.pct >= 90) w.push(`ЦП ${n.cpu.pct}%`);
  if (n.mem.pct >= 90) w.push(`память ${n.mem.pct}%`);
  if (n.disk.pct >= 80 && n.disk.pct < 90) w.push(`диск ${n.disk.pct}%`);
  return w;
}

function nodeLevel(n) {
  if (!n.reachable || n.issues.length) return "crit";
  return warnings(n).length ? "warn" : "good";
}

function awgCell(n) {
  const a = n.awg;
  if (a.state === "running") {
    return badge("good", `работает :${a.port}`) +
      `<span class="sub-line">${a.peers} ${plural(a.peers, ["клиент", "клиента", "клиентов"])} · онлайн ${a.online}</span>`;
  }
  if (a.state === "stopped") return badge("crit", "контейнер остановлен");
  return '<span class="muted">не установлен</span>';
}

function meter(label, pct, warnAt, critAt, sub) {
  const level = critAt && pct >= critAt ? "crit" : pct >= warnAt ? "warn" : "";
  const width = Math.max(0, Math.min(100, pct));
  return `<div class="meter" role="meter" aria-label="${esc(label)}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pct}">
    <div class="top">${level ? icon(level) : ""}<span>${pct}%</span></div>
    <div class="track"><i class="${level}" data-w="${width}"></i></div>
    <span class="sub-line">${esc(sub)}</span>
  </div>`;
}

// Ширина полосок meter через CSSOM: inline style= запрещён политикой CSP сервера
function applyWidths(root) {
  root.querySelectorAll(".track i[data-w]").forEach((i) => { i.style.width = i.dataset.w + "%"; });
}

// Ссылка на страницу узла
function nodeHref(name) {
  return `node.html${DEMO ? "?demo" : ""}#n=${encodeURIComponent(name)}`;
}

function emptyList(text, cmd) {
  return `<p class="empty">${esc(text)}${cmd ? `<br><code>${esc(cmd)}</code>` : ""}</p>`;
}

// Копирование в буфер. navigator.clipboard есть только в безопасном контексте
// (https или 127.0.0.1 через SSH-туннель), иначе запасной путь через textarea
async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.className = "sr-only";
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch { ok = false; }
    ta.remove();
    return ok;
  }
}

let toastTimer = null;
function toast(text) {
  let el = $("#toast");
  if (!el) {
    el = document.createElement("div");
    el.id = "toast";
    el.className = "toast";
    el.setAttribute("role", "status");
    document.body.appendChild(el);
  }
  el.textContent = text;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 2200);
}

// Плашка и отметка в меню о незавершённом переносе управляющего сервера (поле migrate в ответах панели).
// На самой странице «Перенос» плашки нет
function renderMigrate(m) {
  const badge = $("#nav-migrate");
  badge.hidden = !m;
  badge.textContent = m ? (m.role === "source" ? "идёт" : "завершить") : "";
  const el = $("#migrate-banner");
  if (!el) return;
  el.hidden = !m;
  if (!m) return;
  const link = `migrate.html${DEMO ? "?demo" : ""}`;
  el.innerHTML = m.role === "source"
    ? `${icon("warn")}<div>Идёт перенос управления на <b>${esc(m.peer)}</b>, изменения на этом сервере заблокированы. <a href="${link}">Подробнее</a></div>`
    : `${icon("warn")}<div>Этот сервер принимает управление от <b>${esc(m.peer)}</b>. Проверь, что все узлы на связи, и <a href="${link}">заверши перенос</a></div>`;
}


// Формы с задачей iof: «Добавить сервер» и «Перенос». Поля входа на сервер: #f-host, #f-port,
// #f-user, радио auth, #f-password, #f-key, #f-keyfile, #toggle-pass, #pubkey-cmd, #copy-pubkey,
// #secret-note. Карточка задачи: #job, #job-title, #job-state, #job-result, #job-log

const HOST_RE = /^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$/;
const USER_RE = /^[a-z_][a-z0-9_-]{0,31}$/;

const JOB_STATES = {
  running: ["none", "выполняется…"],
  ok: ["good", "готово"],
  warn: ["warn", "готово с ошибками"],
  error: ["crit", "ошибка"],
};

async function getJson(url) {
  const r = await fetch(url, { cache: "no-store", credentials: "same-origin" });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

// Изменения только POST с JSON и заголовком X-IOF-Request: по ним сервер отсекает запросы с чужих сайтов
async function postJson(url, data) {
  const r = await fetch(url, {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", "X-IOF-Request": "1" },
    body: JSON.stringify(data),
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || `HTTP ${r.status}`);
  return body;
}

function authMode() {
  return document.querySelector('input[name="auth"]:checked').value;
}

// Хост, порт, пользователь и пароль или ключ, те же правила, что у iof. Ошибки кладёт в errors
// по селекторам полей
function collectLogin(errors) {
  const v = (id) => $(id).value.trim();
  const data = { host: v("#f-host"), port: v("#f-port") || "22", user: v("#f-user") || "root", auth: authMode() };
  if (!HOST_RE.test(data.host)) errors["#f-host"] = "IPv4 или домен: латиница, цифры, точка, дефис";
  const port = Number(data.port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) errors["#f-port"] = "1–65535";
  if (!USER_RE.test(data.user)) errors["#f-user"] = "строчная латиница, цифры, _ и -";
  if (data.auth === "password") {
    data.password = $("#f-password").value;
    if (!data.password) errors["#f-password"] = "введи пароль";
  } else if (data.auth === "key") {
    data.key = $("#f-key").value;
    if (!/PRIVATE KEY|PuTTY/.test(data.key)) errors["#f-key"] = "вставь приватный ключ целиком";
  }
  return data;
}

// После отправки секреты в странице больше не нужны
function clearSecrets() {
  $("#f-password").value = "";
  $("#f-key").value = "";
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
  // Фокус на первое поле с ошибкой по порядку на странице
  const first = document.querySelector('[aria-invalid="true"]');
  if (first) first.focus();
}

function formError(text, sel = "#form-error") {
  const el = $(sel);
  el.hidden = !text;
  el.innerHTML = text ? `${icon("crit")} ${esc(text)}` : "";
}

// Команда для сервера, которая добавляет ключ iof в authorized_keys
function pubkeyCommand(pubkey) {
  return pubkey
    ? `mkdir -p ~/.ssh && echo '${pubkey}' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`
    : "Ключа iof ещё нет: он создаётся при первом добавлении сервера по паролю или ключу.";
}

// Переключатель способа входа, показ пароля, ключ из файла и копирование команды с ключом iof
function initLoginForm() {
  document.querySelectorAll('input[name="auth"]').forEach((r) => r.addEventListener("change", () => {
    document.querySelectorAll(".auth-pane").forEach((p) => { p.hidden = p.dataset.auth !== authMode(); });
    $("#secret-note").hidden = authMode() === "installed";
  }));
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
}

// Задача страницы: запущенная с неё (id), иначе последняя задача этого вида (node или migrate)
async function pageJob(kind, id, demoJobs) {
  const jobs = DEMO ? demoJobs() : (await getJson("api/jobs")).jobs;
  return jobs.find((j) => j.id === id) || jobs.find((j) => (j.kind || "node") === kind);
}

// Шапка и лог карточки задачи, итог под шапкой страница задаёт через jobResult.
// Возвращает уровень значка: good, warn, crit или none
function renderJobCard(job) {
  const card = $("#job");
  if (!job) { card.hidden = true; return null; }
  card.hidden = false;
  const [lvl, label] = JOB_STATES[job.state] || JOB_STATES.error;
  $("#job-title").textContent = job.title;
  $("#job-state").innerHTML = job.state === "running"
    ? `<span class="st"><span class="spinner" aria-hidden="true"></span>${label}</span>` : badge(lvl, label);

  const log = $("#job-log");
  const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 24;
  log.textContent = job.log.join("\n");
  if (atBottom) log.scrollTop = log.scrollHeight;
  return lvl;
}

function jobResult(lvl, html) {
  $("#job-result").className = html ? `note ${lvl}` : "";
  $("#job-result").innerHTML = html || "";
}

// Задача страницы и её опрос раз в секунду, пока идёт. render(job) получает задачу или undefined,
// done(job) вызывается, когда закончилась задача, запущенная с этой страницы (start).
// all: показывать последнюю задачу этого вида, иначе только идущую или запущенную отсюда
function watchJob({ kind, demoJobs, render, done, all = true }) {
  const w = { id: null, shown: null, timer: null };
  async function poll() {
    clearTimeout(w.timer);
    try {
      const job = await pageJob(typeof kind === "function" ? kind() : kind, w.id, demoJobs);
      const visible = job && (all || job.state === "running" || job.id === w.shown);
      if (visible) w.shown = job.id;
      render(visible ? job : undefined);
      if (job && job.state === "running") {
        w.timer = setTimeout(poll, 1000);
      } else if (job && job.id === w.id) {
        w.id = null;
        done(job);
      }
    } catch {
      w.timer = setTimeout(poll, 3000);
    }
  }
  return {
    poll,
    start(id) { w.id = id; w.shown = id; poll(); },
    hide() { w.shown = null; render(undefined); },
  };
}

// Причина из вывода iof: строка после «Не удалось (N)…» или «Ошибки (N):», иначе «Ошибка: …»
function failReason(log) {
  const i = log.findIndex((l) => l.startsWith("Не удалось (") || l.startsWith("Ошибки ("));
  if (i >= 0 && log[i + 1]) return log[i + 1].trim().split(/\s{2,}/).pop();
  const err = log.find((l) => l.startsWith("Ошибка: "));
  return err ? err.slice(8) : "";
}


// Загрузка данных страницы, кнопка «Обновить», автообновление и строка состояния.
// page: { url (строка или функция), demo() -> Promise<data>, render(data), init(rerender) }.
// Возвращает { state, reload }: reload() загружает данные заново, например после задачи

function startPage(page) {
  const state = { data: null, error: null, loading: false, timer: null };

  function renderAlert() {
    const el = $("#alert");
    if (!state.error) { el.hidden = true; return; }
    el.hidden = false;
    el.innerHTML = state.data
      ? `${icon("crit")} Не удалось обновить данные: ${esc(state.error)}. Показано состояние на ${fmtTime(state.data.status_at)}.`
      : `${icon("crit")} Нет связи с панелью: ${esc(state.error)}`;
  }

  function renderStamp() {
    const d = state.data, el = $("#stamp");
    if (state.loading) { el.textContent = "Опрашиваю узлы…"; return; }
    if (!d) { el.textContent = "Нет данных"; return; }
    el.textContent = `Опрос узлов в ${fmtTime(d.status_at)} · ${d.probe_s.toFixed(1)} с` +
      (d.cached ? " · из кэша" : "") + (DEMO ? " · демо" : "");
  }

  function render() {
    renderAlert();
    renderStamp();
    if (state.data) {
      renderMigrate(state.data.migrate);
      page.render(state.data);
    }
  }

  async function load(force = false) {
    if (state.loading) return;
    state.loading = true;
    $("#refresh").setAttribute("aria-busy", "true");
    renderStamp();
    try {
      if (DEMO) {
        state.data = await page.demo();
      } else {
        const url = typeof page.url === "function" ? page.url() : page.url;
        const r = await fetch(force ? `${url}${url.includes("?") ? "&" : "?"}force=1` : url,
          { cache: "no-store", credentials: "same-origin" });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        state.data = await r.json();
      }
      state.error = null;
    } catch (e) {
      state.error = e.message || String(e);
    } finally {
      state.loading = false;
      $("#refresh").removeAttribute("aria-busy");
      render();
    }
  }

  function schedule() {
    clearInterval(state.timer);
    const sec = Number($("#auto").value);
    if (sec > 0) state.timer = setInterval(() => { if (!document.hidden) load(); }, sec * 1000);
  }

  document.addEventListener("DOMContentLoaded", () => {
    $("#auto").value = prefs.get("auto", "60");
    $("#refresh").addEventListener("click", () => load(true));
    $("#auto").addEventListener("change", () => { prefs.set("auto", $("#auto").value); schedule(); });
    if (page.init) page.init(() => state.data && page.render(state.data));
    load();
    schedule();
  });

  return { state, reload: () => load() };
}
