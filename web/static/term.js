"use strict";

// Терминал на странице узла, как окно PuTTY: xterm.js рисует, ввод и вывод идут через WebSocket к панели,
// а она запускает ssh на узел в псевдотерминале (для local — оболочку root на этом сервере).
// POST api/term выдаёт одноразовый билет (там обычная защита панели от CSRF), с ним открывается
// WebSocket api/term/ws. Двоичные сообщения — байты терминала, текстовые — JSON: resize, ping, exit.
// xterm.js грузится, только когда терминал открывают. В демо-режиме вместо узла выдуманная оболочка.
// Разметка в node.html: #term, #term-target, #term-state, #term-note, #term-box, #term-full, #term-close

const Term = (() => {
  const t = { xterm: null, fit: null, ws: null, node: null, state: "closed", ping: null, exit: null, demo: null };
  const enc = new TextEncoder();
  let loading = null;

  // xterm.js сам создаёт элементы <style>, а CSP панели (default-src 'self') их не применяет.
  // Поэтому такой элемент подменяется невидимым <template>, а его текст уходит в constructable
  // stylesheet (document.adoptedStyleSheets): на такие таблицы стилей CSP не распространяется.
  // Сама панель элементы <style> не создаёт, подмена нужна только для xterm.js
  function adoptScriptStyles() {
    if (document.createElement.adoptsStyles) return;
    const create = document.createElement.bind(document);
    const patched = (tag, opts) => {
      if (String(tag).toLowerCase() !== "style") return create(tag, opts);
      const el = create("template");
      const sheet = new CSSStyleSheet();
      let text = "";
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      Object.defineProperty(el, "textContent", {
        get: () => text,
        set: (v) => { text = String(v ?? ""); sheet.replaceSync(text); },
      });
      el.remove = () => {
        document.adoptedStyleSheets = document.adoptedStyleSheets.filter((s) => s !== sheet);
        Element.prototype.remove.call(el);
      };
      return el;
    };
    patched.adoptsStyles = true;
    document.createElement = patched;
  }

  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = src;
      s.addEventListener("load", resolve);
      s.addEventListener("error", () => reject(new Error(`не загрузился ${src}`)));
      document.head.appendChild(s);
    });
  }

  function loadXterm() {
    adoptScriptStyles();
    loading = loading || loadScript("xterm.js").then(() => loadScript("xterm-fit.js"));
    loading.catch(() => { loading = null; });
    return loading;
  }

  // Цвета терминала из app.css (--term-*), шрифт — моноширинный панели
  function theme() {
    const css = getComputedStyle($("#term-box"));
    const v = (name) => css.getPropertyValue(name).trim();
    return {
      background: v("--term-bg"), foreground: v("--term-fg"), cursor: v("--term-cursor"),
      cursorAccent: v("--term-bg"), selectionBackground: v("--term-sel"),
    };
  }

  const STATES = {
    connecting: () => '<span class="st"><span class="spinner" aria-hidden="true"></span>подключение…</span>',
    open: () => badge("good", "подключён"),
    closed: (why) => badge("none", why || "закрыт"),
    error: () => badge("crit", "ошибка"),
  };

  // Состояние в шапке карточки и подсказка под ней: ошибка или как подключиться снова
  function setState(state, text = "") {
    t.state = state;
    $("#term-state").innerHTML = STATES[state](state === "closed" ? text : "");
    const note = $("#term-note");
    note.hidden = state !== "error";
    note.className = "note crit";
    note.innerHTML = state === "error" ? `${icon("crit")}<div>${esc(text)}</div>` : "";
  }

  function say(text) {
    t.xterm.write(`\r\n\x1b[2m${text}\x1b[0m\r\n`);
  }

  function send(data) {
    if (t.state !== "open") return;
    if (t.demo) t.demo(data);
    else if (t.ws && t.ws.readyState === WebSocket.OPEN) t.ws.send(data);
  }

  function sendControl(obj) {
    if (!t.demo) send(JSON.stringify(obj));
  }

  // Ctrl+Shift+C и Ctrl+Insert копируют выделенное. Ctrl+Shift+V и Shift+Insert браузер сам вставит
  // как paste, xterm.js его подхватит. Обычный Ctrl+C уходит на узел (прервать команду), как в PuTTY
  function keys(e) {
    if (e.type !== "keydown" || !e.ctrlKey) return true;
    if ((e.shiftKey && e.code === "KeyC") || (!e.shiftKey && e.code === "Insert")) {
      if (t.xterm.hasSelection()) {
        copyText(t.xterm.getSelection()).then((ok) => toast(ok ? "Скопировано" : "Не удалось скопировать"));
      }
      e.preventDefault();
      return false;
    }
    return !(e.shiftKey && e.code === "KeyV");
  }

  function createXterm() {
    const xterm = new window.Terminal({
      fontFamily: getComputedStyle(document.documentElement).getPropertyValue("--mono").trim() || "monospace",
      fontSize: 13, lineHeight: 1.15, cursorBlink: true, scrollback: 5000, theme: theme(),
    });
    t.fit = new window.FitAddon.FitAddon();
    xterm.loadAddon(t.fit);
    xterm.open($("#term-box"));
    xterm.attachCustomKeyEventHandler(keys);
    xterm.onData((d) => {
      // После конца сессии Enter подключает заново
      if (t.state === "closed" && d === "\r") connect();
      else send(t.demo ? d : enc.encode(d));
    });
    xterm.onBinary((d) => send(t.demo ? d : Uint8Array.from(d, (c) => c.charCodeAt(0) & 255)));
    xterm.onResize(({ cols, rows }) => sendControl({ type: "resize", cols, rows }));
    t.xterm = xterm;
  }

  async function connect() {
    setState("connecting");
    t.exit = null;
    t.fit.fit();
    if (DEMO) { demoShell(); return; }
    let ticket;
    try {
      ({ ticket } = await postJson("api/term", { name: t.node, cols: t.xterm.cols, rows: t.xterm.rows }));
    } catch (e) {
      setState("error", e.message);
      return;
    }
    const url = new URL(`api/term/ws?t=${encodeURIComponent(ticket)}`, location.href);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    t.ws = ws;
    ws.addEventListener("open", () => {
      if (t.ws !== ws) return;
      setState("open");
      t.xterm.focus();
      // Панель считает связь пропавшей, если 90 секунд от браузера ничего нет
      t.ping = setInterval(() => sendControl({ type: "ping" }), 25000);
    });
    ws.addEventListener("message", (e) => {
      if (t.ws !== ws) return;
      if (typeof e.data !== "string") { t.xterm.write(new Uint8Array(e.data)); return; }
      try {
        const msg = JSON.parse(e.data);
        if (msg.type === "exit") t.exit = msg;
      } catch { /* не JSON: пропускаем */ }
    });
    ws.addEventListener("close", (e) => {
      if (t.ws !== ws) return;
      const opened = t.state === "open";
      clearInterval(t.ping);
      t.ws = null;
      ended(opened, e.code);
    });
  }

  // Конец сессии: процесс вышел (пришёл exit), связь оборвалась или не удалось подключиться
  function ended(opened, code) {
    const x = t.exit;
    if (x && x.error) { setState("error", x.error); return; }
    if (x) {
      say(`[сессия завершена${x.code ? `, код ${x.code}` : ""}. Enter — подключиться снова]`);
      setState("closed", "сессия завершена");
    } else if (opened) {
      say("[соединение с панелью прервалось. Enter — подключиться снова]");
      setState("closed", "соединение прервалось");
    } else {
      setState("error", `не удалось открыть WebSocket к панели (код ${code}). Если панель за nginx, ему нужны заголовки Upgrade и Connection для api/term/ws`);
    }
  }

  // Открыть терминал узла: node = { name, ssh, enabled }. Тот же узел уже открыт — только фокус
  async function open(node) {
    const card = $("#term");
    card.hidden = false;
    $("#term-target").textContent = node.ssh === "local" ? "этот сервер" : node.ssh;
    card.scrollIntoView({ behavior: "smooth", block: "nearest" });
    $("#term-body").hidden = !node.enabled && !DEMO;
    $("#term-full").hidden = $("#term-body").hidden;
    if (!node.enabled && !DEMO) {
      setState("closed", "выключен");
      const note = $("#term-note");
      note.className = "note warn";
      note.hidden = false;
      note.innerHTML = `${icon("warn")}<div>Терминал в панели выключен: он даёт root-доступ ко всем узлам прямо из браузера.
        Включить: <code>echo IOF_WEB_TERMINAL=1 | sudo tee -a /root/iof/web.env</code>, затем
        <code>sudo systemctl restart iof-web</code></div>`;
      return;
    }
    if (t.node === node.name && t.xterm) {
      t.xterm.focus();
      if (t.state === "closed" || t.state === "error") connect();
      return;
    }
    close(false);
    card.hidden = false;
    t.node = node.name;
    setState("connecting");
    try {
      await loadXterm();
    } catch (e) {
      setState("error", e.message);
      return;
    }
    if (t.node !== node.name) return;
    if (!t.xterm) createXterm();
    connect();
  }

  // Закрыть сессию и окно терминала. hide = false: только сессию, окно останется
  function close(hide = true) {
    clearInterval(t.ping);
    const ws = t.ws;
    t.ws = null;
    t.demo = null;
    if (ws) ws.close();
    if (t.xterm) { t.xterm.dispose(); t.xterm = null; }
    t.node = null;
    t.state = "closed";
    if (document.fullscreenElement) document.exitFullscreen();
    if (hide) $("#term").hidden = true;
  }

  function toggleFull() {
    if (document.fullscreenElement) document.exitFullscreen();
    else $("#term").requestFullscreen().catch(() => toast("Браузер не дал открыть во весь экран"));
  }

  // Выдуманная оболочка для демо-режима: строка ввода с Backspace и Ctrl+C, пара команд
  function demoShell() {
    const node = t.node;
    const prompt = `\x1b[1;32mroot@${node}\x1b[0m:\x1b[1;34m~\x1b[0m# `;
    const w = (s) => t.xterm.write(s);
    const answers = {
      help: "Демо-режим: настоящего сервера нет. Команды: uptime, df -h, free -h, hostname, whoami, ls, clear, exit",
      uptime: " 12:04:31 up 12 days,  3:41,  1 user,  load average: 0.08, 0.05, 0.01",
      "df -h": "Filesystem      Size  Used Avail Use% Mounted on\r\n/dev/vda1        24G  9.1G   15G  39% /\r\ntmpfs           983M     0  983M   0% /dev/shm",
      "free -h": "               total        used        free      shared  buff/cache   available\r\nMem:           1.9Gi       742Mi       318Mi       4.0Mi       1.0Gi       1.2Gi\r\nSwap:             0B          0B          0B",
      hostname: node,
      whoami: "root",
      ls: "\x1b[1;34mhysteria\x1b[0m  iof-hy2-install.log  \x1b[1;32mupdate.sh\x1b[0m",
    };
    let line = "";
    t.demo = (data) => {
      for (const ch of data) {
        if (ch === "\r") {
          const cmd = line.trim();
          line = "";
          w("\r\n");
          if (cmd === "exit") { t.demo = null; t.exit = { code: 0 }; ended(true); return; }
          if (cmd === "clear") w("\x1b[2J\x1b[H");
          else if (cmd) w(`${answers[cmd] || `${cmd.split(" ")[0]}: в демо такой команды нет, есть help`}\r\n`);
          w(prompt);
        } else if (ch === "\x7f") {
          if (line) { line = [...line].slice(0, -1).join(""); w("\b \b"); }
        } else if (ch === "\x03") {
          line = "";
          w("^C\r\n" + prompt);
        } else if (ch >= " ") {
          line += ch;
          w(ch);
        }
      }
    };
    setState("open");
    w(`Welcome to Ubuntu 24.04.1 LTS (демо-режим, сервера нет: команда help)\r\n\r\n${prompt}`);
    t.xterm.focus();
  }

  document.addEventListener("DOMContentLoaded", () => {
    $("#term-close").addEventListener("click", () => close());
    $("#term-full").addEventListener("click", toggleFull);
    // Размер терминала по окну: при сворачивании меню, повороте экрана и во весь экран
    new ResizeObserver(() => { if (t.xterm) t.fit.fit(); }).observe($("#term-box"));
    document.addEventListener("fullscreenchange", () => {
      $("#term-full").textContent = document.fullscreenElement ? "Свернуть" : "Во весь экран";
      if (t.xterm) t.xterm.focus();
    });
    // Перезагрузка или уход со страницы оборвёт сессию: браузер переспросит
    window.addEventListener("beforeunload", (e) => {
      if (t.state === "open" && !t.demo) e.preventDefault();
    });
  });

  return { open, close };
})();
