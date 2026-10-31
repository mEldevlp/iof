"use strict";

// Общее для страниц iof-web: форматирование, иконки, загрузка данных и автообновление.
// С параметром ?demo страницы работают на встроенных примерах (demo.js), без сервера.

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


// Загрузка данных страницы, кнопка «Обновить», автообновление и строка состояния.
// page: { url, demo() -> Promise<data>, render(data) }

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
    if (state.data) page.render(state.data);
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
        const r = await fetch(`${page.url}${force ? "?force=1" : ""}`, { cache: "no-store", credentials: "same-origin" });
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
    // Демо-режим сохраняется при переходе между страницами
    if (DEMO) document.querySelectorAll(".nav a").forEach((a) => { a.href += "?demo"; });

    $("#auto").value = prefs.get("auto", "60");
    $("#refresh").addEventListener("click", () => load(true));
    $("#auto").addEventListener("change", () => { prefs.set("auto", $("#auto").value); schedule(); });
    if (page.init) page.init(() => state.data && page.render(state.data));
    load();
    schedule();
  });

  return state;
}
