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
  const chip = $("#demo-chip");
  if (chip) chip.hidden = false;
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
// Куда уходят уведомления iof одного типа (страницы «Сервис» и «Безопасность»). bot — через бота:
// {username, subs: {тип: сколько админов подписано}}; chat — TG_TOKEN и TG_CHAT в iof.env (без бота туда
// уходят только узлы и аудит). -> [ячейка для kv, подсказка или ""]
function tgView(bot, chat, kind, title) {
  const page = `<a href="bot.html${DEMO ? "?demo" : ""}">«Телеграм бот»</a>`;
  if (bot) {
    const n = (bot.subs || {})[kind] || 0;
    const name = bot.username ? ` @${esc(bot.username)}` : "";
    return [`через бота${name}<span class="sub-line">${n
      ? badge("good", `получают ${n} ${plural(n, ["админ", "админа", "админов"])}`)
      : badge("warn", "нет подписчиков")}</span>`,
    n ? "" : `Отметь админам «${title}» на странице ${page}.`];
  }
  if (chat) {
    return [badge("good", "в TG_CHAT из iof.env"),
      `Бот выключен, поэтому сообщения идут в <code>TG_CHAT</code> из <code>/root/iof/iof.env</code>. Через бота (страница ${page}) они приходят каждому админу, кому отмечены.`];
  }
  return [badge("none", "не настроен"), `Сообщения в Telegram: включи бота на странице ${page} и отметь админам «${title}».`];
}

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

async function getJson(url, signal) {
  const r = await fetch(url, { cache: "no-store", credentials: "same-origin", signal });
  if (r.status === 401) location.replace("login.html");
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
  if (r.status === 401 && url !== "api/login") location.replace("login.html");
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
async function pageJob(kind, id, demoJobs, signal) {
  const jobs = DEMO ? demoJobs() : (await getJson("api/jobs", signal)).jobs;
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
  const w = { id: null, shown: null, timer: null, kind: null, request: null, ready: false };
  const getKind = () => typeof kind === "function" ? kind() : kind;
  async function poll() {
    clearTimeout(w.timer);
    const current = getKind();
    if (w.kind !== current) {
      Object.assign(w, { kind: current, ready: false, shown: w.id });
    }
    w.request?.abort();
    const request = w.request = new AbortController();
    const card = $("#job");
    const finish = w.ready ? null : skeleton(card, skeletonJob(Boolean(w.id)));
    if (finish) card.hidden = false;
    const active = () => request === w.request && current === getKind();
    try {
      const job = await pageJob(current, w.id, demoJobs, request.signal);
      if (!active()) return;
      finish?.();
      w.ready = true;
      const visible = job && (all || job.state === "running" || job.id === w.shown);
      if (visible) w.shown = job.id;
      render(visible ? job : undefined);
      if (job && job.state === "running") {
        w.timer = setTimeout(poll, 1000);
      } else if (job && job.id === w.id) {
        w.id = null;
        done?.(job);
      }
    } catch {
      if (active()) {
        if (finish) {
          finish();
          render(undefined);
        }
        w.ready = true;
        w.timer = setTimeout(poll, 3000);
      }
    }
  }
  return {
    poll,
    start(id) { w.id = id; w.shown = id; w.ready = false; poll(); },
    hide() { w.shown = null; render(undefined); },
    reset() { w.id = null; w.shown = null; render(undefined); poll(); },
  };
}

// Причина из вывода iof: строка после «Не удалось (N)…» или «Ошибки (N):», иначе «Ошибка: …»
function failReason(log) {
  const i = log.findIndex((l) => l.startsWith("Не удалось (") || l.startsWith("Ошибки ("));
  if (i >= 0 && log[i + 1]) return log[i + 1].trim().split(/\s{2,}/).pop();
  const err = log.find((l) => l.startsWith("Ошибка: "));
  return err ? err.slice(8) : "";
}


// Заглушка занимает место содержимого, сохраняя его DOM и значения полей до ответа.
// Завершение старого запроса не убирает заглушку нового.
const skeletons = new WeakMap();

function skeleton(el, html) {
  skeletons.get(el)?.();
  const template = document.createElement("template");
  template.innerHTML = html;
  const parts = [...template.content.children];
  for (const part of parts) {
    part.classList.add("skeleton-part");
    part.setAttribute("aria-hidden", "true");
  }
  el.append(template.content);
  el.classList.add("skeleton-active");
  el.setAttribute("aria-busy", "true");
  function finish() {
    if (skeletons.get(el) !== finish) return;
    parts.forEach((part) => part.remove());
    el.classList.remove("skeleton-active");
    el.removeAttribute("aria-busy");
    skeletons.delete(el);
  }
  skeletons.set(el, finish);
  return finish;
}

function skeletonBar(size = "medium", shape = "line") {
  return `<span class="skeleton-slot skeleton-${shape}"><i class="skeleton-fill skeleton-${size}"></i></span>`;
}

function skeletonHealth() {
  return `<span class="skeleton-fill big-ico"></span><div class="skeleton-grow">
    ${skeletonBar("medium", "heading")}${skeletonBar("long")}</div>`;
}

function skeletonMeter() {
  return `<div class="meter">${skeletonBar("short", "sub")}${skeletonBar("full", "track")}${skeletonBar("medium", "sub")}</div>`;
}

function skeletonLinks(count, url = false) {
  return `<ol class="links">${Array.from({ length: count }, () => `<li class="link">
    <div class="link-main">${skeletonBar()}${url ? skeletonBar("long", "sub") : ""}</div>
    <div class="link-actions">${skeletonBar("medium", "button")}${url ? skeletonBar("short", "button") : ""}</div>
  </li>`).join("")}</ol>`;
}

function skeletonJob(log = true) {
  return `<div class="card-head">${skeletonBar()}${skeletonBar("short")}</div>${log
    ? `<div class="skeleton-log">${skeletonBar("long")}${skeletonBar("medium")}</div>` : ""}`;
}

function skeletonFields(count) {
  return `<div class="form-grid">${Array.from({ length: count }, () =>
    `<div class="field">${skeletonBar("short")}${skeletonBar("full", "field")}</div>`).join("")}</div>`;
}

function skeletonTable(labels, classes, count, meters = false, head = "") {
  const cells = labels.map((label, i) => {
    const nodes = classes === "nodes";
    const name = i === 0;
    const action = classes === "admins" && i === labels.length - 1;
    const meter = meters && i >= 4 && i <= 6;
    const attrs = name ? `class="${nodes ? "cell-node" : "cell-name"}"`
      : action ? 'class="cell-act"' : `data-label="${esc(label)}"`;
    return `<td ${attrs}>${meter ? skeletonMeter() : skeletonBar("medium", action ? "button" : "line")}
      ${name ? skeletonBar("short", "sub") : ""}</td>`;
  }).join("");
  return `<table class="${classes}">${head || `<thead><tr>${labels.map((label) => `<th>${esc(label)}</th>`).join("")}</tr></thead>`}
    <tbody>${`<tr>${cells}</tr>`.repeat(count)}</tbody></table>`;
}

// Шаблоны используют те же сетки, строки и отступы, что и готовые данные.
function skeletonMarkup(el, shape, count) {
  switch (shape) {
    case "health": return skeletonHealth();
    case "kpis": return Array.from({ length: 5 }, () => `<div class="kpi">
      <div class="label">${skeletonBar()}</div><div class="value">${skeletonBar("short", "value")}</div>
      <div class="sub">${skeletonBar("long")}</div></div>`).join("");
    case "nodes": {
      const table = el.querySelector("table:not(.skeleton-part)");
      return skeletonTable([...table.querySelectorAll("th")].map((th) => th.textContent), "nodes",
        table.tBodies[0].rows.length || count, count === 3, table.tHead.outerHTML);
    }
    case "admins": return skeletonTable(["Админ", "ID", "Роль", "Звук в тихие часы", "Добавлен", "Удалить"], "admins",
      el.querySelector("tbody")?.rows.length || count);
    case "notify": return skeletonTable(["Админ", "Узлы", "Аудит", "Ночное обслуживание", "Обновления", "Доступ к РФ", "Админы"],
      "admins notify", el.querySelector("tbody")?.rows.length || count);
    case "kv":
    case "resources": {
      const keys = el.querySelectorAll("dt:not(.skeleton-part)");
      return Array.from({ length: keys.length || count }, (_, i) => {
        const meter = shape === "resources" && i >= 2 && i <= 4 && (!keys.length || keys[i].nextElementSibling.querySelector(".meter"));
        return `<dt>${skeletonBar("short")}</dt><dd>${meter ? skeletonMeter() : skeletonBar("long")}</dd>`;
      }).join("");
    }
    case "groups":
    case "list": return Array.from({ length: el.querySelectorAll(".item:not(.skeleton-part), .group-item:not(.skeleton-part)").length || count }, () =>
      `<div class="${shape === "groups" ? "group-item" : "item"}">
        <div class="item-head">${skeletonBar()}${skeletonBar("short")}</div>${skeletonBar("medium", "sub")}</div>`).join("");
    case "checks":
    case "jobs": {
      const rows = el.querySelectorAll("summary").length || count;
      const items = `<li><div class="skeleton-summary">
        ${skeletonBar("short")}${skeletonBar("medium")}${skeletonBar("short")}</div></li>`.repeat(rows);
      return shape === "checks" ? `<ul class="checks">${items}</ul>` : items;
    }
    case "settings": return Array.from({ length: count }, () => `<li><div class="skeleton-grow">
      ${skeletonBar()}${skeletonBar("long")}</div>${skeletonBar("short", "switch")}</li>`).join("");
    case "form": return `<div class="card-head">${skeletonBar()}</div>
      <div class="pad">${skeletonFields(count)}</div><div class="btn-row">${skeletonBar("medium", "button")}</div>`;
    case "detail":
    case "hy2-detail": return `<div class="card-head"><div class="skeleton-grow">${skeletonBar()}${skeletonBar("medium", "sub")}</div>
      ${skeletonBar("medium", "button")}</div>${shape === "hy2-detail"
      ? `<div class="group-body">${skeletonLinks(count, true)}<div class="qr-all"><span class="skeleton-fill skeleton-qr"></span></div></div>`
      : `<div class="pad">${skeletonLinks(count)}</div>`}<div class="hint">${skeletonBar("long")}</div>`;
    case "danger": return `<div class="card-head">${skeletonBar()}</div><div class="pad">${skeletonBar("long")}</div>
      <div class="btn-row">${skeletonBar("medium", "button")}</div>`;
    case "invites": return `<li>${skeletonBar("short", "pill")}${skeletonBar()}${skeletonBar("medium", "button")}</li>`
      .repeat(el.querySelectorAll("li:not(.skeleton-part)").length);
    case "server-select": return skeletonBar("full", "button") + skeletonBar("medium", "button");
    case "select": return skeletonBar("medium", "button");
    case "switch": return skeletonBar("full", "switch");
    case "time": return skeletonBar("short", "button").repeat(2);
    case "buttons": return skeletonBar("medium", "button").repeat(count);
    case "chips": return skeletonBar("short", "pill").repeat(count);
    case "code": return skeletonBar("long").repeat(count);
    default: return skeletonBar("long");
  }
}

function skeletonRegions(root = document, selector = "[data-skeleton]") {
  const finish = [...root.querySelectorAll(selector)].map((el) => {
    const [shape, count = 1] = el.dataset.skeleton.split(" ");
    return skeleton(el, skeletonMarkup(el, shape, Number(count)));
  });
  return () => finish.forEach((end) => end());
}

function pendingCard(el, html) {
  el.hidden = false;
  const finish = skeleton(el, html);
  return () => {
    finish();
    el.hidden = true;
  };
}

// Загрузка данных страницы, кнопка «Обновить», автообновление и строка состояния.
// page: { url (строка или функция), demo() -> Promise<data>, render(data, replace), init(rerender) }.
// Возвращает { state, reload }: reload() загружает данные заново, например после задачи

function startPage(page) {
  const state = { data: null, error: null, loading: false, replacing: false, rerender: false, timer: null, url: null, request: null };

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

  async function load({ force = false, replace = false } = {}) {
    const url = typeof page.url === "function" ? page.url() : page.url;
    const changed = state.url !== url;
    if (state.loading && !changed && !replace && !force) return;
    state.request?.abort();
    const request = state.request = new AbortController();
    state.url = url;
    if (changed) state.data = null;
    if (!state.data) page.reset?.();
    state.error = null;
    state.loading = true;
    state.replacing = !state.data || force || replace;
    const finish = state.replacing ? skeletonRegions() : null;
    $("#refresh").setAttribute("aria-busy", "true");
    renderAlert();
    renderStamp();
    const active = () => request === state.request && (typeof page.url !== "function" || page.url() === url);
    let data;
    try {
      data = DEMO ? await page.demo() : await getJson(
        force ? `${url}${url.includes("?") ? "&" : "?"}force=1` : url, request.signal);
    } catch (e) {
      if (active()) state.error = e.message || String(e);
    } finally {
      finish?.();
      if (!active()) return;
      state.loading = false;
      state.replacing = false;
      $("#refresh").removeAttribute("aria-busy");
      if (data) {
        state.data = data;
        renderMigrate(data.migrate);
        page.render(data, changed || force || replace);
      } else if (state.data && state.rerender) {
        page.render(state.data);
      }
      state.rerender = false;
      if (!state.data && page.empty) page.empty();
      renderAlert();
      renderStamp();
    }
  }

  function schedule() {
    clearInterval(state.timer);
    const sec = Number($("#auto").value);
    if (sec > 0) state.timer = setInterval(() => { if (!document.hidden) load(); }, sec * 1000);
  }

  document.addEventListener("DOMContentLoaded", () => {
    $("#auto").value = prefs.get("auto", "60");
    $("#refresh").addEventListener("click", () => load({ force: true }));
    $("#auto").addEventListener("change", () => { prefs.set("auto", $("#auto").value); schedule(); });
    if (page.init) page.init(() => {
      if (state.replacing) state.rerender = true;
      else if (state.data) page.render(state.data);
    });
    load();
    schedule();
  });

  return { state, reload: () => load({ replace: true }) };
}
