"use strict";

// Страница узла: состояние, Hysteria2, AmneziaWG, группы ссылок и ретрансляторы с этим узлом, действия.
// Данные: GET api/node?n=<имя>, действия: POST api/node (задачи iof hy2 restart | install, iof node del + refresh).
// Кнопка «Терминал» открывает окно терминала на узел (term.js). Узел в адресе: node.html#n=<имя>

const nd = { data: null, running: false };

function nodeName() {
  const m = /^#n=(.+)$/.exec(location.hash);
  return m ? decodeURIComponent(m[1]) : "";
}

const ACTIONS = {
  restart_hy2: {
    body: { action: "restart_hy2" },
    ask: (n) => `Перезапустить Hysteria2 на ${n}? Подключённые клиенты на пару секунд потеряют связь и переподключатся.`,
  },
  install_hy2: {
    body: { action: "install_hy2" },
    ask: (n) => `Установить Hysteria2 на ${n} по образцу этого сервера? Узел сразу попадёт во все группы ссылок.`,
  },
  reinstall_hy2: {
    body: { action: "install_hy2", force: true },
    ask: (n) => `Перезаписать конфиг Hysteria2 на ${n} по шаблону этого сервера? Старый сохранится рядом как бэкап, группы ссылок пересоберутся.`,
  },
  delete: {
    body: { action: "delete" },
    ask: (n) => `Удалить узел ${n} из iof? Ссылки и ключи AmneziaWG пересоберутся без него. Сам сервер iof не тронет.`,
  },
};

const job = watchJob({
  kind: () => `node:${nodeName()}`,
  demoJobs: () => demoJobs(),
  all: false,
  render: renderJob,
  done: () => pageApi.reload(),
});


// Отрисовка

function kv(rows) {
  return rows.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v}</dd>`).join("");
}

// off: кнопка недоступна сама по себе (нет связи, нет шаблона), пока идёт задача — недоступны все
function actButton(act, label, off, cls = "") {
  return `<button class="btn small${cls}" type="button" data-act="${act}"${off ? ' data-off="1"' : ""}>${esc(label)}</button>`;
}

function syncButtons() {
  document.querySelectorAll("[data-act]").forEach((b) => { b.disabled = nd.running || b.dataset.off === "1"; });
}

function migrating(d) {
  return !!d.migrate && d.migrate.role === "source";
}

function renderHead(d) {
  const demo = DEMO ? "?demo" : "";
  document.title = `${d.name || "Узел"} · Island of Freedom`;
  $("#node-title").textContent = d.name || "Узел";
  $("#node-sub").innerHTML = `<a href="./${demo}">Обзор</a>` +
    (d.conf ? ` / ${esc(d.conf.title)} · <span class="mono">${esc(d.conf.addr)}</span>` : "");
}

function renderHealth(d) {
  const el = $("#health"), n = d.node;
  if (!d.conf) {
    el.className = "health";
    el.innerHTML = `${icon("none", "ico big-ico")}<div><h2>Узла ${esc(d.name || "")} нет в nodes.conf</h2>
      <p class="sub">Его удалили или ссылка неверная. Список узлов на <a href="./${DEMO ? "?demo" : ""}">Обзоре</a>.</p></div>`;
    return;
  }
  if (d.status_error || !n) {
    el.className = "health crit";
    el.innerHTML = `${icon("crit", "ico big-ico")}<div><h2>Нет данных об узле</h2>
      <p class="sub">${esc(d.status_error || "узел не попал в опрос, обнови страницу")}</p></div>`;
    return;
  }
  if (!n.reachable) {
    const t = parseSsh(d.conf.ssh);
    el.className = "health crit";
    el.innerHTML = `${icon("crit", "ico big-ico")}<div><h2>Нет связи по SSH</h2>
      <p class="sub">iof не смог зайти на <span class="mono">${esc(d.conf.ssh)}</span> своим ключом. Проверить с этого сервера:
      <code>ssh -i /root/.ssh/iof_ed25519${t.port !== "22" ? ` -p ${esc(t.port)}` : ""} ${esc(t.target)}</code></p></div>`;
    return;
  }
  const lvl = nodeLevel(n);
  const items = [...n.issues.map((t) => ["crit", t]), ...warnings(n).map((t) => ["warn", t])];
  const title = lvl === "crit" ? "Есть проблемы" : lvl === "warn" ? "Работает, но нужна внимательность" : "Всё в порядке";
  el.className = `health ${lvl}`;
  el.innerHTML = `${icon(lvl, "ico big-ico")}<div><h2>${title}</h2>
    <p class="sub">Работает ${fmtUptime(n.uptime_s)}, вход и сбор данных по SSH за ${fmtMs(n.ms)}</p>
    ${items.length ? `<ul class="issues">${items.map(([l, t]) => `<li>${icon(l)}<span>${esc(t)}</span></li>`).join("")}</ul>` : ""}
  </div>`;
}

// root@203.0.113.5:2222 -> { target: "root@203.0.113.5", port: "2222" }
function parseSsh(ssh) {
  const m = /^(.+?)(?::(\d+))?$/.exec(ssh || "");
  return { target: m ? m[1] : ssh, port: (m && m[2]) || "22" };
}

function renderHy2(d) {
  const n = d.node, up = !!n && n.reachable;
  const h = up ? n.hy2 : null;
  let rows;
  if (!up) rows = [["Состояние", '<span class="muted">нет данных</span>']];
  else if (!h.installed) rows = [["Состояние", '<span class="muted">не установлена</span>']];
  else rows = [["Состояние", hy2Cell(n, false)], ["Порт", `UDP ${esc(h.port)}`],
    ["Доступ", esc(hy2Access(h)) || "—"], ["Версия", esc(h.version) || "—"]];
  $("#hy2").innerHTML = kv(rows);

  const noTpl = !d.hy2_template, mig = migrating(d);
  const btns = h && h.installed
    ? [actButton("restart_hy2", "Перезапустить", !up), actButton("reinstall_hy2", "Переустановить по шаблону", !up || noTpl || mig)]
    : [actButton("install_hy2", "Установить Hysteria2", !up || noTpl || mig, " primary")];
  const hint = up && noTpl ? '<p class="hint">Ставить не по чему: на этом сервере нет шаблона /etc/hysteria/config.yaml</p>'
    : up && mig ? '<p class="hint">Идёт перенос управления, установка здесь заблокирована</p>' : "";
  $("#hy2-actions").innerHTML = btns.join("") + hint;
}

function renderAwg(d) {
  const n = d.node, up = !!n && n.reachable;
  const a = up ? n.awg : null;
  let rows;
  if (!up) rows = [["Состояние", '<span class="muted">нет данных</span>']];
  else if (a.state === "none") rows = [["Состояние", '<span class="muted">не установлен</span>']];
  else if (a.state !== "running") rows = [["Состояние", badge("crit", "контейнер остановлен")]];
  else rows = [["Состояние", badge("good", "работает")], ["Порт", `UDP ${esc(a.port)}`],
    ["Клиенты", `${a.peers}`], ["Онлайн", `${a.online} <span class="muted">за 3 мин</span>`]];
  $("#awg").innerHTML = kv(rows);
}

function renderRes(d) {
  const n = d.node, c = d.conf, up = !!n && n.reachable;
  const rows = [
    ["Адрес", `<span class="mono">${esc(c.addr)}</span> <span class="muted">для клиентов</span>`],
    ["SSH", c.ssh === "local" ? "этот сервер (local)" : `<span class="mono">${esc(c.ssh)}</span>`],
  ];
  if (up) {
    rows.push(
      ["ЦП", meter("ЦП", n.cpu.pct, 90, 0, `LA ${n.cpu.load1} · ${n.cpu.cpus} ${plural(n.cpu.cpus, ["ядро", "ядра", "ядер"])}`)],
      ["Память", meter("Память", n.mem.pct, 90, 0, `из ${gb(n.mem.total_mb, 1024)} ГБ`)],
      ["Диск", meter("Диск", n.disk.pct, 80, 90, `из ${gb(n.disk.total_kb, 1048576)} ГБ`)],
      ["Работает", fmtUptime(n.uptime_s)],
      ["Отклик", `${fmtMs(n.ms)} <span class="muted">вход по SSH и сбор данных</span>`],
    );
  }
  $("#res").innerHTML = kv(rows);
  applyWidths($("#res"));
}

function renderGroups(d) {
  const demo = DEMO ? "?demo" : "";
  const g = d.hy2_groups;
  const installed = d.node && d.node.reachable && d.node.hy2.installed;
  const missing = g.filter((x) => !x.has_link);
  $("#groups-count").textContent = g.length || "";
  $("#groups").innerHTML = g.length ? g.map((x) => `<a class="item item-link" href="hy2.html${demo}#g=${encodeURIComponent(x.name)}">
      <div class="item-head"><span class="item-title">${esc(x.label)}</span>
        <span class="item-meta">${x.has_link ? badge("good", "есть ссылка") : installed ? badge("warn", "нет ссылки") : '<span class="muted">нет ссылки</span>'}</span></div>
    </a>`).join("") + (installed && missing.length
    ? `<p class="hint">Новые ссылки появятся после пересборки групп на странице <a href="hy2.html${demo}">Hysteria2</a></p>` : "")
    : emptyList("Групп ссылок пока нет", 'sudo iof hy2 add "Подпись"');
}

function renderRelays(d) {
  const r = d.relays;
  $("#relays-count").textContent = r.length || "";
  const route = (proto, from, to) => from
    ? `<span class="proto">${proto}</span><span class="path">${esc(from)}<span class="arrow">→</span>${esc(to || "?")}</span>` : "";
  $("#relays").innerHTML = r.length ? r.map((x) => `<div class="item">
      <div class="item-head"><span class="item-title">${esc(x.label)}</span>
        <span class="item-meta">${x.node === d.name ? "узел за ретранслятором" : "ретранслятор"}</span></div>
      <div class="route">${route("HY2", x.hy2, x.hy2_target)}${route("AWG", x.awg, x.awg_target)}</div>
    </div>`).join("") : emptyList("Узел не участвует в ретрансляторах");
}

function renderDanger(d) {
  const used = d.relays[0];
  const notes = [];
  if (used) notes.push(`Сначала убери ретранслятор: <code>sudo iof relay del ${esc(used.node)} ${esc(used.via)}</code>`);
  if (migrating(d)) notes.push("Идёт перенос управления, удалять узлы здесь нельзя.");
  if (!used && d.conf.ssh === "local") {
    notes.push("Это сам управляющий сервер. После удаления он перестанет быть VPN-узлом в iof, но управлять остальными продолжит.");
  }
  $("#delete-note").hidden = !notes.length;
  $("#delete-note").innerHTML = notes.length ? `${icon("warn")}<div>${notes.join(" ")}</div>` : "";
  $("#delete").dataset.off = used || migrating(d) ? "1" : "";
}

function render(d) {
  nd.data = d;
  renderHead(d);
  renderHealth(d);
  const known = !!d.conf;
  ["#node-body", "#node-more", "#danger", "#term-open"].forEach((sel) => { $(sel).hidden = !known; });
  if (known) {
    renderHy2(d);
    renderAwg(d);
    renderRes(d);
    renderGroups(d);
    renderRelays(d);
    renderDanger(d);
  }
  syncButtons();
}


// Действия

async function act(key) {
  const a = ACTIONS[key], name = nd.data.name;
  if (!confirm(a.ask(name))) return;
  formError("", "#action-error");
  try {
    const body = { ...a.body, name };
    const id = DEMO ? demoNodeJob(body) : (await postJson("api/node", body)).job;
    job.start(id);
    $("#job").scrollIntoView({ behavior: "smooth", block: "nearest" });
  } catch (e) {
    formError(e.message, "#action-error");
  }
}

// Итог по первой строке лога: какая команда шла
function renderJob(j) {
  const lvl = renderJobCard(j);
  nd.running = !!j && j.state === "running";
  syncButtons();
  if (!j) return;
  $("#job-hide").hidden = nd.running;
  const first = j.log[0] || "";
  const reason = failReason(j.log);
  const why = reason ? `: <b>${esc(reason)}</b>` : ", причина в логе";
  const demo = DEMO ? "?demo" : "";
  const results = first.startsWith("$ iof node del") ? {
    ok: `${icon("good")}<div>Узел удалён, ссылки и ключи пересобраны без него. <a href="./${demo}">К обзору</a></div>`,
    warn: `${icon("warn")}<div>Узел удалён, но часть групп не пересобралась, подробности в логе. Повторить: <code>sudo iof refresh</code></div>`,
    error: j.log.includes("$ iof refresh")
      ? `${icon("crit")}<div>Узел удалён, но пересборка прервалась${why}. Повторить: <code>sudo iof refresh</code></div>`
      : `${icon("crit")}<div>Узел не удалён${why}</div>`,
  } : first.startsWith("$ iof hy2 install") ? {
    ok: `${icon("good")}<div>Hysteria2 установлена, узел добавлен в группы ссылок.</div>`,
    warn: `${icon("warn")}<div>Установить не удалось${why}. Подробности в логе, повторить можно той же кнопкой.</div>`,
    error: `${icon("crit")}<div>Установка прервалась${why}</div>`,
  } : {
    ok: `${icon("good")}<div>Hysteria2 перезапущена и работает.</div>`,
    error: `${icon("crit")}<div>Не удалось перезапустить${why}</div>`,
  };
  jobResult(lvl, results[j.state]);
}

const pageApi = startPage({
  url: () => `api/node?n=${encodeURIComponent(nodeName())}`,
  demo: () => demoNode(nodeName()),
  init() {
    // Другой узел в адресе: другие данные и свои задачи, терминал прошлого узла закрывается
    window.addEventListener("hashchange", () => { Term.close(); job.hide(); pageApi.reload(); job.poll(); });
    $("#term-open").addEventListener("click", () => {
      const d = nd.data;
      if (d && d.conf) Term.open({ name: d.name, ssh: d.conf.ssh, enabled: !!d.terminal });
    });
    document.querySelector("main").addEventListener("click", (e) => {
      const b = e.target.closest("[data-act]");
      if (b && !b.disabled) act(b.dataset.act);
    });
    $("#job-hide").addEventListener("click", () => job.hide());
    job.poll();
  },
  render,
});
