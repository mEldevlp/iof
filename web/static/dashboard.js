"use strict";

// Страница «Обзор». Данные: GET api/dashboard (см. iof-web.py)

// Отрисовка

function renderHealth(d) {
  const el = $("#health");
  const nodes = d.nodes;
  const bad = nodes.filter((n) => nodeLevel(n) === "crit");
  const warn = nodes.filter((n) => nodeLevel(n) === "warn");

  if (d.status_error) {
    el.className = "health crit";
    el.innerHTML = `${icon("crit", "ico big-ico")}<div><h2>Не удалось опросить узлы</h2>
      <p class="sub">${esc(d.status_error)}</p></div>`;
    return;
  }
  if (!nodes.length) {
    el.className = "health";
    el.innerHTML = `${icon("none", "ico big-ico")}<div><h2>Узлов нет</h2>
      <p class="sub">Добавь серверы: <code>sudo iof node add имя ip "Подпись"</code> или <code>sudo iof node import файл</code></p></div>`;
    return;
  }

  const level = bad.length ? "crit" : warn.length ? "warn" : "good";
  const title = bad.length
    ? `Проблемы на ${bad.length} из ${nodes.length} ${plural(nodes.length, ["узла", "узлов", "узлов"])}`
    : warn.length
      ? `Узлы работают, на ${warn.length} нужна внимательность`
      : `Все ${nodes.length} ${plural(nodes.length, ["узел работает", "узла работают", "узлов работают"])}`;
  const items = [
    ...bad.map((n) => ({ lvl: "crit", n, text: [...n.issues, ...warnings(n)].join("; ") })),
    ...warn.map((n) => ({ lvl: "warn", n, text: warnings(n).join("; ") })),
  ];
  el.className = `health ${level}`;
  el.innerHTML = `${icon(level, "ico big-ico")}<div>
    <h2>${esc(title)}</h2>
    <p class="sub">Проблемой считается: Hysteria2 не работает или не слушает порт, остановлен контейнер AWG, диск от 90%, нет связи по SSH.</p>
    ${items.length ? `<ul class="issues">${items.map((i) =>
      `<li>${icon(i.lvl)}<span><a class="node-link" href="${nodeHref(i.n.name)}"><b>${esc(i.n.name)}</b></a> <span class="muted">${esc(i.n.addr)}</span> — ${esc(i.text)}</span></li>`).join("")}</ul>` : ""}
  </div>`;
}

function kpi(label, value, small, subs, href) {
  const tag = href ? "a" : "div";
  return `<${tag} class="kpi${href ? " kpi-link" : ""}"${href ? ` href="${href}${DEMO ? "?demo" : ""}"` : ""}>
    <div class="label">${esc(label)}</div>
    <div class="value">${value}${small ? `<small>${esc(small)}</small>` : ""}</div>
    ${subs.filter(Boolean).map((s) => `<div class="sub">${s}</div>`).join("")}</${tag}>`;
}

function renderKpis(d) {
  const nodes = d.nodes, up = nodes.filter((n) => n.reachable);
  const lv = nodes.map(nodeLevel);
  const okCount = lv.filter((l) => l === "good").length;
  const warnCount = lv.filter((l) => l === "warn").length;
  const badCount = lv.filter((l) => l === "crit").length;

  const hy2 = up.filter((n) => n.hy2.installed);
  const hy2Ok = hy2.filter((n) => n.hy2.state === "active" && n.hy2.udp);
  const awg = up.filter((n) => n.awg.state !== "none");
  const awgOk = awg.filter((n) => n.awg.state === "running");
  const online = awgOk.reduce((s, n) => s + n.awg.online, 0);
  const peers = awgOk.reduce((s, n) => s + n.awg.peers, 0);

  const ms = up.map((n) => n.ms).sort((a, b) => a - b);
  const median = ms.length ? ms[Math.floor((ms.length - 1) / 2)] : 0;
  const slowest = up.reduce((m, n) => (!m || n.ms > m.ms ? n : m), null);

  const parts = [
    `${icon("good")} в порядке ${okCount}`,
    warnCount ? `${icon("warn")} внимание ${warnCount}` : "",
    badCount ? `${icon("crit")} проблемы ${badCount}` : "",
  ].filter(Boolean).map((s) => `<span class="st">${s}</span>`).join(" &nbsp;");

  $("#kpis").innerHTML = [
    kpi("Узлы", nodes.length, "", [parts]),
    kpi("Hysteria2", `${hy2Ok.length}`, `/ ${hy2.length} работает`,
      [`групп ссылок: ${d.hy2_groups.length}`], "hy2.html"),
    kpi("AmneziaWG онлайн", online, "за 3 мин",
      [`клиентов в iof: ${d.awg_clients.length} · пиров на узлах: ${peers}`,
       awg.length ? `контейнер работает на ${awgOk.length} из ${awg.length}` : "на узлах не установлен"]),
    kpi("Ретрансляторы", d.relays.length, "",
      [d.relays.length ? esc(d.relays.slice(0, 2).map((r) => r.label).join(", ")) + (d.relays.length > 2 ? "…" : "") : "нет"]),
    kpi("Отклик SSH", ms.length ? fmtMs(median) : "—", ms.length ? "медиана" : "",
      [slowest ? `самый медленный: ${esc(slowest.name)}, ${fmtMs(slowest.ms)}` : ""]),
  ].join("");
}

function nodeRow(n) {
  const level = nodeLevel(n);
  const tip = [...n.issues, ...warnings(n)].join("; ") || "в порядке";
  const head = `<td class="cell-node"><div class="node-cell"><span title="${esc(tip)}">${icon(level)}</span><div>
      <div class="node-name"><a class="node-link" href="${nodeHref(n.name)}">${esc(n.name)}</a></div>
      ${n.title && n.title !== n.name ? `<span class="sub-line">${esc(n.title)}</span>` : ""}
    </div></div></td>
    <td data-label="Адрес"><span class="mono">${esc(n.addr)}</span></td>`;
  if (!n.reachable) {
    return `<tr class="is-crit" data-href="${nodeHref(n.name)}">${head}<td class="cell-wide offline" colspan="7">${badge("crit", "нет связи по SSH")}</td></tr>`;
  }
  return `<tr class="${level === "good" ? "" : "is-" + level}" data-href="${nodeHref(n.name)}">${head}
    <td data-label="Hysteria2" class="cell-proto">${hy2Cell(n)}</td>
    <td data-label="AmneziaWG" class="cell-proto">${awgCell(n)}</td>
    <td data-label="ЦП">${meter("ЦП", n.cpu.pct, 90, 0, `LA ${n.cpu.load1} · ${n.cpu.cpus} ${plural(n.cpu.cpus, ["ядро", "ядра", "ядер"])}`)}</td>
    <td data-label="Память">${meter("Память", n.mem.pct, 90, 0, `из ${gb(n.mem.total_mb, 1024)} ГБ`)}</td>
    <td data-label="Диск">${meter("Диск", n.disk.pct, 80, 90, `из ${gb(n.disk.total_kb, 1048576)} ГБ`)}</td>
    <td data-label="Работает">${fmtUptime(n.uptime_s)}</td>
    <td data-label="Отклик" class="num">${fmtMs(n.ms)}</td>
  </tr>`;
}

function renderNodes(d) {
  const q = $("#q").value.trim().toLowerCase();
  const onlyBad = $("#onlybad").checked;
  const list = d.nodes.filter((n) =>
    (!onlyBad || nodeLevel(n) !== "good") &&
    (!q || [n.name, n.title, n.addr].some((s) => (s || "").toLowerCase().includes(q))));

  $("#nodes-count").textContent = list.length === d.nodes.length ? d.nodes.length : `${list.length} из ${d.nodes.length}`;
  $("#nodes").innerHTML = list.map(nodeRow).join("");
  applyWidths($("#nodes"));
  const empty = $("#nodes-empty");
  empty.hidden = list.length > 0;
  $("table.nodes").hidden = !list.length;
  if (!list.length) {
    empty.innerHTML = d.nodes.length ? "Под фильтр не подходит ни один узел" :
      d.status_error ? "Данных об узлах нет, см. ошибку выше" : "Узлов нет";
  }
}

function renderRelays(d) {
  $("#relays-count").textContent = d.relays.length || "";
  $("#relays").innerHTML = d.relays.length ? d.relays.map((r) => {
    const route = (proto, from, to) => from
      ? `<span class="proto">${proto}</span><span class="path">${esc(from)}<span class="arrow">→</span>${esc(to || "?")}</span>` : "";
    return `<div class="item">
      <div class="item-head"><span class="item-title">${esc(r.label)}</span><span class="item-meta">${esc(r.node)} через ${esc(r.via)}</span></div>
      <div class="route">${route("HY2", r.hy2, r.hy2_target)}${route("AWG", r.awg, r.awg_target)}</div>
    </div>`;
  }).join("") : emptyList("Ретрансляторов нет. Нужны, если IP узла заблокирован.", "sudo iof relay add узел через");
}

function renderHy2(d) {
  $("#hy2-count").textContent = d.hy2_groups.length || "";
  $("#hy2").innerHTML = d.hy2_groups.length ? d.hy2_groups.map((g) => `<a class="item item-link" href="hy2.html${DEMO ? "?demo" : ""}#g=${encodeURIComponent(g.name)}">
      <div class="item-head"><span class="item-title">${esc(g.label)}</span><span class="item-meta">${fmtCreated(g.created)}</span></div>
      <span class="sub-line">логин <span class="mono">${esc(g.name)}</span></span>
    </a>`).join("") : emptyList("Групп ссылок пока нет", 'sudo iof hy2 add "Подпись"');
}

function renderAwg(d) {
  $("#awg-count").textContent = d.awg_clients.length || "";
  $("#awg").innerHTML = d.awg_clients.length ? d.awg_clients.map((c) => `<div class="item">
      <div class="item-head"><span class="item-title">${esc(c.label)}</span><span class="item-meta">${fmtCreated(c.created)}</span></div>
      ${c.configs.length ? `<div class="chips">${c.configs.map((f) => `<span class="chip">${esc(f.replace(/_/g, " "))}</span>`).join("")}</div>` : ""}
    </div>`).join("") : emptyList("Клиентов, созданных через iof, пока нет", 'sudo iof awg add "Имя"');
}

const overview = startPage({
  url: "api/dashboard",
  demo: async () => {
    const d = await demoDashboard();
    if (["setup", "template-only", "setup-error"].includes(setupDemo)) {
      d.nodes = setup.info && setup.info.nodes ? d.nodes.slice(0, 1) : [];
      if (d.nodes.length && setup.info.local) Object.assign(d.nodes[0], setup.info.local);
    }
    return d;
  },
  init(rerender) {
    $("#onlybad").checked = prefs.get("onlybad", "0") === "1";
    $("#onlybad").addEventListener("change", () => { prefs.set("onlybad", $("#onlybad").checked ? "1" : "0"); rerender(); });
    $("#q").addEventListener("input", rerender);
    // Строка узла открывает его страницу, если не нажата ссылка и не выделяется текст
    $("#nodes").addEventListener("click", (e) => {
      const tr = e.target.closest("tr[data-href]");
      if (tr && !e.target.closest("a, button") && !String(getSelection())) location.href = tr.dataset.href;
    });
  },
  render(d) {
    renderHealth(d);
    renderKpis(d);
    renderNodes(d);
    renderRelays(d);
    renderHy2(d);
    renderAwg(d);
  },
});

// Мастер загружается отдельно: отсутствие узлов или ошибка SSH не мешают первой настройке.
const setup = { info: null, touched: false, running: false, demoJob: null };
const setupDemo = new URLSearchParams(location.search).get("demo");
function demoSetupInfo() {
  const empty = ["setup", "template-only", "setup-error"].includes(setupDemo);
  return { template: !["setup", "nodes-no-template"].includes(setupDemo), nodes: empty ? 0 : 6,
    local: null, state: setupDemo === "template-only" ? { mode: "template-only", phase: "done" } : {}, busy: false, migrate: null };
}
function setupMode() {
  const only = $("#setup-mode").value === "template-only";
  $("#setup-local").hidden = only;
  $("#setup-local").disabled = only || setup.running;
}
async function loadSetup() {
  try {
    const i = setup.info = DEMO ? (setup.info || demoSetupInfo()) : await getJson("api/setup");
    renderMigrate(i.migrate);
    $("#overview-content").hidden = !i.nodes;
    $("#setup").hidden = i.template && i.nodes > 0 && i.state.phase !== "installing";
    $("#setup-template").hidden = i.template;
    $("#setup-template").disabled = i.template || setup.running;
    if (!setup.touched) {
      $("#setup-mode").value = i.nodes || i.state.mode === "template-only" ? "template-only" : "local";
      const local = i.local || i.state;
      if (local.name) $("#setup-name").value = local.name;
      if (local.addr) $("#setup-addr").value = local.addr;
    }
    $("#setup-note").textContent = i.template
      ? "Шаблон готов. Добавь удалённый сервер или выбери установку VPN здесь. Существующий шаблон не изменится."
      : "Создадим шаблон Hysteria2 со случайными паролями. Можно установить VPN здесь или оставить этот сервер только управляющим.";
    const blocked = setup.running || i.busy || (i.migrate && i.migrate.role === "source");
    $("#setup-submit").disabled = Boolean(blocked);
    $("#setup-mode").disabled = Boolean(blocked);
    setupMode();
  } catch (e) { formError(`Не удалось загрузить состояние настройки: ${e.message}`, "#setup-error"); $("#setup").hidden = false; }
}
const setupJob = watchJob({
  kind: "setup", demoJobs: () => setup.demoJob ? [setup.demoJob] : [],
  render(j) {
    const lvl = renderJobCard(j);
    setup.running = Boolean(j && j.state === "running");
    $("#setup-submit").disabled = setup.running || Boolean(setup.info && setup.info.busy);
    $("#setup-form").querySelectorAll("input, select").forEach((el) => { el.disabled = setup.running; });
    if (setup.info) { $("#setup-template").disabled = setup.running || setup.info.template; setupMode(); }
    if (j && j.state !== "running" && setup.completed !== j.id) {
      setup.completed = j.id;
      loadSetup(); overview.reload();
    }
    if (j) jobResult(lvl, j.state === "ok"
      ? `${icon("good")}<div>Настройка завершена. <a href="hy2.html${DEMO ? "?demo" : ""}">Создать группу Hysteria2</a> · <a href="add.html${DEMO ? "?demo" : ""}">Добавить удалённый сервер</a></div>`
      : j.state === "error" ? `${icon("crit")}<div>Настройка прервалась. ${esc(failReason(j.log))} Исправь причину и повтори: созданные файлы и пароли сохранятся.</div>` : "");
  },
  done() { loadSetup(); overview.reload(); },
});
async function submitSetup(e) {
  e.preventDefault();
  formError("", "#setup-error");
  if (!setup.info || setup.running) return;
  const data = { mode: $("#setup-mode").value }, errors = {};
  if (data.mode === "local") {
    data.name = $("#setup-name").value.trim(); data.addr = $("#setup-addr").value.trim(); data.title = $("#setup-title").value.trim();
    if (!/^[A-Za-z0-9._-]{1,40}$/.test(data.name) || [".", "..", "all"].includes(data.name)) errors["#setup-name"] = "неверное имя узла";
    if (!HOST_RE.test(data.addr) || data.addr.toLowerCase() === "localhost" || data.addr.startsWith("127.") || data.addr === "0.0.0.0") errors["#setup-addr"] = "нужен адрес для клиентов, не localhost";
    if (/[|\r\n\t]/.test(data.title)) errors["#setup-title"] = "без | и переводов строк";
  }
  if (!setup.info.template) {
    data.port = $("#setup-port").value.trim(); data.obfs = $("#setup-obfs").value;
    if (!/^\d{1,5}$/.test(data.port) || Number(data.port) < 1 || Number(data.port) > 65535) errors["#setup-port"] = "число от 1 до 65535";
  }
  showErrors(errors);
  if (Object.keys(errors).length) return;
  $("#setup-submit").disabled = true;
  try {
    let id;
    if (DEMO) {
      setup.demoJob = { id: "setup-demo", kind: "setup", title: "Первоначальная настройка", state: "running", log: ["Подготовка шаблона и узлов…"] };
      id = setup.demoJob.id;
      setTimeout(() => {
        const failed = setupDemo === "setup-error";
        setup.demoJob.state = failed ? "error" : "ok";
        setup.demoJob.log.push(failed ? "Ошибка: не удалось запустить службу (демо)" : "Готово. Создай группу Hysteria2 или добавь удалённый сервер.");
        if (!failed) Object.assign(setup.info, { template: true, nodes: data.mode === "local" ? 1 : 0,
          local: data.mode === "local" ? { name: data.name, addr: data.addr } : null, state: { mode: data.mode, phase: "done" } });
      }, 1800);
    } else id = (await postJson("api/setup", data)).job;
    setupJob.start(id);
  } catch (err) { formError(err.message, "#setup-error"); loadSetup(); }
}
document.addEventListener("DOMContentLoaded", () => {
  $("#setup-form").addEventListener("submit", submitSetup);
  $("#setup-form").addEventListener("input", () => { setup.touched = true; });
  $("#setup-mode").addEventListener("change", () => { setup.touched = true; setupMode(); });
  $("#refresh").addEventListener("click", loadSetup);
  loadSetup(); setupJob.poll();
  setInterval(() => { if (!document.hidden) loadSetup(); }, 15000);
});
