"use strict";

// Страница «Обзор». Данные: GET api/dashboard (см. iof-web.py)

// Оценка состояния узла. Пороги те же, что в iof status

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
      `<li>${icon(i.lvl)}<span><b>${esc(i.n.name)}</b> <span class="muted">${esc(i.n.addr)}</span> — ${esc(i.text)}</span></li>`).join("")}</ul>` : ""}
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
      <div class="node-name">${esc(n.name)}</div>
      ${n.title && n.title !== n.name ? `<span class="sub-line">${esc(n.title)}</span>` : ""}
    </div></div></td>
    <td data-label="Адрес"><span class="mono">${esc(n.addr)}</span></td>`;
  if (!n.reachable) {
    return `<tr class="is-crit">${head}<td class="cell-wide offline" colspan="7">${badge("crit", "нет связи по SSH")}</td></tr>`;
  }
  return `<tr class="${level === "good" ? "" : "is-" + level}">${head}
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
  // Ширина через CSSOM: inline style= запрещён политикой CSP сервера
  document.querySelectorAll("#nodes .track i[data-w]").forEach((i) => { i.style.width = i.dataset.w + "%"; });
  const empty = $("#nodes-empty");
  empty.hidden = list.length > 0;
  $("table.nodes").hidden = !list.length;
  if (!list.length) {
    empty.innerHTML = d.nodes.length ? "Под фильтр не подходит ни один узел." :
      d.status_error ? "Данных об узлах нет, см. ошибку выше." : "Узлов нет.";
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
    </a>`).join("") : emptyList("Групп ссылок пока нет.", 'sudo iof hy2 add "Подпись"');
}

function renderAwg(d) {
  $("#awg-count").textContent = d.awg_clients.length || "";
  $("#awg").innerHTML = d.awg_clients.length ? d.awg_clients.map((c) => `<div class="item">
      <div class="item-head"><span class="item-title">${esc(c.label)}</span><span class="item-meta">${fmtCreated(c.created)}</span></div>
      ${c.configs.length ? `<div class="chips">${c.configs.map((f) => `<span class="chip">${esc(f.replace(/_/g, " "))}</span>`).join("")}</div>` : ""}
    </div>`).join("") : emptyList("Клиентов, созданных через iof, пока нет.", 'sudo iof awg add "Имя"');
}

startPage({
  url: "api/dashboard",
  demo: demoDashboard,
  init(rerender) {
    $("#onlybad").checked = prefs.get("onlybad", "0") === "1";
    $("#onlybad").addEventListener("change", () => { prefs.set("onlybad", $("#onlybad").checked ? "1" : "0"); rerender(); });
    $("#q").addEventListener("input", rerender);
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
