"use strict";

// Страница «Безопасность». Блоки «Аудит сервера» (server) и «Защита от РКН» (dpi): последние проверки
// iof audit по узлам, что проверка показала, почему это важно и как исправить. Данные: GET api/security
// (iof api audit, узлы при этом не опрашиваются), проверка: POST api/security {block, node} — задача
// iof audit run <блок>. Оценки и тексты приходят готовыми из iof, здесь только отрисовка.
// Карточка «Доступность из РФ» — проверка с ПК (iof audit probe), см. ниже «Проверка с ПК»

// kind — вид задачи, которую показывает карточка задачи: audit или probe
const sec = { data: null, running: false, kind: "audit", poll: null, tick: null };
// Блоки страницы: у каждого в html есть #<блок>-node, -run, -stamp, -health, -checks
const BLOCKS = ["server", "dpi"];
// Что проверял запуск из истории (поле block)
const RUN_WORDS = { server: "аудит сервера", dpi: "защита от РКН", all: "оба блока" };
const WORDS = { good: "в порядке", warn: "внимание", crit: "проблема", none: "нет данных" };
const RANK = { none: 0, good: 1, warn: 2, crit: 3 };

const job = watchJob({
  kind: () => sec.kind,
  demoJobs,
  all: false,
  render: renderJob,
  done: () => load(),
});

function fmtWhen(ts) {
  return new Date(ts * 1000).toLocaleString("ru-RU", { dateStyle: "short", timeStyle: "short" });
}

// Выбранный узел блока, пусто — все узлы
function picked(block) {
  return $(`#${block}-node`).value;
}

// Узлы блока с результатом последней проверки в res (нет, если узел ещё не проверялся)
function blockNodes(block) {
  const saved = (sec.data.blocks[block] || {}).nodes || {};
  const pick = picked(block);
  return sec.data.nodes.filter((n) => !pick || n.name === pick).map((n) => ({ ...n, res: saved[n.name] }));
}

// Оценка проверки на узле: результат iof или «нет данных» с причиной. act — действия панели на этом узле
function checkOf(res, id) {
  const none = (value) => ({ status: "none", value, detail: [], hint: "", cmd: "", act: [] });
  if (!res) return none("узел ещё не проверялся");
  if (!res.reachable) return none("нет связи с узлом");
  return res.checks.find((c) => c.id === id) || none("нет данных");
}

function worst(per) {
  return per.reduce((a, p) => (RANK[p.c.status] > RANK[a] ? p.c.status : a), "none");
}


// Отрисовка блока

function renderNodeSelect(block) {
  const el = $(`#${block}-node`);
  const names = sec.data.nodes.map((n) => n.name);
  if (el.dataset.names === names.join(" ")) return;
  const pick = el.value;
  el.dataset.names = names.join(" ");
  el.innerHTML = `<option value="">Все узлы</option>` + names.map((n) => `<option>${esc(n)}</option>`).join("");
  el.value = names.includes(pick) ? pick : "";
}

function renderStamp(block, nodes) {
  const times = nodes.filter((n) => n.res).map((n) => n.res.at);
  const from = Math.min(...times), to = Math.max(...times);
  $(`#${block}-stamp`).textContent = !times.length ? ""
    : to - from < 120 ? `проверено ${fmtWhen(to)}` : `проверено с ${fmtWhen(from)} по ${fmtWhen(to)}`;
}

function renderHealth(block, nodes, rows) {
  const el = $(`#${block}-health`);
  const single = nodes.length === 1;
  const checked = nodes.filter((n) => n.res && n.res.reachable);
  const down = nodes.filter((n) => n.res && !n.res.reachable);
  const fresh = nodes.filter((n) => !n.res);

  if (!nodes.length) {
    el.className = "health";
    el.innerHTML = `${icon("none", "ico big-ico")}<div><h2>Узлов нет</h2>
      <p class="sub">Добавь серверы на странице «Добавить сервер» или командой <code>sudo iof node add</code></p></div>`;
    return;
  }
  if (!checked.length && !down.length) {
    el.className = "health";
    el.innerHTML = `${icon("none", "ico big-ico")}<div><h2>Проверка ещё не запускалась</h2>
      <p class="sub">«Проверить» опросит ${single ? "узел" : "все узлы"} и покажет результат здесь.
      То же в терминале: <code>sudo iof audit run ${block}</code></p></div>`;
    return;
  }

  const count = { crit: 0, warn: 0, good: 0, none: 0 };
  const critNodes = new Set();
  for (const r of rows) {
    for (const p of r.per) {
      if (!p.n.res || !p.n.res.reachable) continue;
      count[p.c.status]++;
      if (p.c.status === "crit") critNodes.add(p.n.name);
    }
  }
  const level = count.crit ? "crit" : count.warn || down.length || fresh.length ? "warn" : "good";
  let title;
  if (count.crit && single) {
    title = `Проверка показала ${count.crit} ${plural(count.crit, ["проблему", "проблемы", "проблем"])}`;
  } else if (count.crit) {
    title = `Проверка показала проблемы на ${critNodes.size} из ${nodes.length} ${plural(nodes.length, ["узла", "узлов", "узлов"])}`;
  } else if (count.warn) {
    title = `Проблем проверка не показала, есть ${count.warn} ${plural(count.warn, ["замечание", "замечания", "замечаний"])}`;
  } else if (down.length || fresh.length) {
    title = "Проверены не все узлы";
  } else {
    title = "Замечаний нет";
  }

  const items = rows.filter((r) => r.per.some((p) => p.c.status === "crit")).map((r) => {
    const bad = r.per.filter((p) => p.c.status === "crit");
    const text = single ? bad[0].c.value : bad.map((p) => p.n.name).join(", ");
    return `<li>${icon("crit")}<span><b>${esc(r.k.title)}</b> — ${esc(text)}</span></li>`;
  });
  for (const n of down) {
    items.push(`<li>${icon("warn")}<span><a class="node-link" href="${nodeHref(n.name)}"><b>${esc(n.name)}</b></a> —
      проверить не удалось: ${esc(n.res.error || "нет связи по SSH")}</span></li>`);
  }
  if (fresh.length) {
    items.push(`<li>${icon("none")}<span>Ещё не проверялись: ${esc(fresh.map((n) => n.name).join(", "))}</span></li>`);
  }
  el.className = `health ${level}`;
  el.innerHTML = `${icon(level, "ico big-ico")}<div>
    <h2>${esc(title)}</h2>
    <p class="sub">Проблем: ${count.crit} · внимание: ${count.warn} · в порядке: ${count.good} · нет данных: ${count.none}${
      single ? "" : ` · узлов проверено: ${checked.length} из ${nodes.length}`}</p>
    ${items.length ? `<ul class="issues">${items.join("")}</ul>` : ""}
  </div>`;
}

// Значение в строке проверки, когда узлов несколько: на скольких узлах худшая оценка и на каких
function spread(per, lvl) {
  const names = (st) => per.filter((p) => p.c.status === st).map((p) => p.n.name);
  const top = names(lvl);
  if (top.length === per.length) {
    const same = new Set(per.map((p) => p.c.value)).size === 1;
    return same ? `${esc(per[0].c.value)} · все узлы` : "на всех узлах";
  }
  let s = `на ${top.length} из ${per.length}: ${esc(top.join(", "))}`;
  if (lvl === "crit" && names("warn").length) s += ` · внимание: ${esc(names("warn").join(", "))}`;
  return s;
}

function detailLines(c) {
  return c.detail.map((line) => `<span class="check-detail">${esc(line)}</span>`).join("");
}

// «Как исправить»: одинаковые советы для нескольких узлов показываются один раз, со списком узлов
function fixes(per, single) {
  const groups = new Map();
  for (const p of per) {
    if (RANK[p.c.status] < RANK.warn || !(p.c.hint || p.c.cmd)) continue;
    const key = `${p.c.hint}\n${p.c.cmd}`;
    if (!groups.has(key)) groups.set(key, { c: p.c, names: [] });
    groups.get(key).names.push(p.n.name);
  }
  return [...groups.values()].map((g) => `<div class="fix">
    <h4>Как исправить${single ? "" : ` <span class="muted">${esc(g.names.join(", "))}</span>`}</h4>
    ${g.c.hint ? `<p>${esc(g.c.hint)}</p>` : ""}
    ${g.c.cmd ? `<div class="cmd"><pre class="code">${esc(g.c.cmd)}</pre><button class="btn small" type="button" data-copy>Копировать</button></div>` : ""}
  </div>`).join("");
}

function checkRow(r, single, open) {
  const lvl = worst(r.per);
  const value = single ? esc(r.per[0].c.value) : spread(r.per, lvl);
  // Сначала узлы с проблемой, потом остальные
  const byLevel = r.per.slice().sort((a, b) => RANK[b.c.status] - RANK[a.c.status]);
  const body = single
    ? (r.per[0].c.detail.length ? `<p class="check-facts">${detailLines(r.per[0].c)}</p>` : "")
    : `<dl class="check-nodes">${byLevel.map((p) => `<dt><a class="node-link" href="${nodeHref(p.n.name)}">${esc(p.n.name)}</a></dt>
        <dd><span class="check-status">${icon(p.c.status)}<span>${esc(p.c.value)}</span></span>${detailLines(p.c)}</dd>`).join("")}</dl>`;
  return `<li><details data-id="${esc(r.k.id)}"${open.has(r.k.id) ? " open" : ""}>
    <summary>${badge(lvl, WORDS[lvl])}<span class="item-title">${esc(r.k.title)}</span><span class="check-value">${value}</span></summary>
    <div class="check-body">
      <p class="check-why">${esc(r.k.why)}</p>
      ${body}
      ${fixes(r.per, single)}
      ${checkActions(r)}
    </div>
  </details></li>`;
}

// Действия из проверок: iof сам меняет узел. Кнопка в строке проверки открывает диалог, в нём
// выбирается один узел и действие. Что умеет каждый узел, говорит поле act проверки от iof
const ACT_CHECKS = {
  hy2_hop: { title: "Смена портов Hysteria2", button: "Включить или выключить…" },
  blocklist: { title: "Блок-лист сканеров", button: "Применить или снять…" },
};
const ACTS = {
  hop_on: { label: "Включить смену портов", cls: "primary",
    text: (s) => `В listen Hysteria2 добавится диапазон ${s.hop || "HY2_HOP"} (HY2_HOP в /root/iof/iof.env). Основной порт останется, выданные ссылки продолжат работать как раньше. Служба перезапустится, клиенты переподключатся за несколько секунд. Если она не поднимется или не поставит правила, конфиг вернётся как был. Список портов попадёт только в ссылки групп с «Список портов в ссылках» на странице Hysteria2.` },
  hop_off: { label: "Выключить смену портов", cls: "danger",
    text: () => "В listen останется основной порт, служба перезапустится. Группы со списком портов в ссылках пересоберутся: их клиентам нужны новые ссылки, со старыми они будут попадать на закрытые порты." },
  hy2_upgrade: { label: "Обновить Hysteria2", cls: "primary",
    text: () => "Официальный установщик поставит последнюю версию, конфиг он не трогает. Служба перезапустится. Бинарник и юнит сохраняются на узле в /var/backups/iof-hy2: если служба не поднимется, они вернутся. После обновления можно включить смену портов." },
  block_on: { label: "Применить блок-лист", cls: "primary",
    text: () => "Пакеты с адресов из списка BLOCKLIST_URL узел будет отбрасывать раньше NAT, ufw и Docker. Не блокируются: узлы из nodes.conf, управляющий сервер, BLOCK_ALLOW и текущие сессии SSH на узле; записи шире /16 и IPv6 пропускаются. Список переживает перезагрузку. Если на узле нет ipset, он установится." },
  block_update: { label: "Обновить список", cls: "",
    text: () => "Список скачается заново (не чаще раза в сутки) и подменится на узле целиком: старый действует, пока не готов новый. Каждый день это делает строка cron с iof block update." },
  block_off: { label: "Снять блок-лист", cls: "danger",
    text: () => "С узла уйдут правило, цепочка IOF-BLOCK, наборы iof-block и iof-allow и служба iof-block. Пакеты со всех адресов узел снова будет принимать." },
};

function checkActions(r) {
  const a = ACT_CHECKS[r.k.id];
  if (!a) return "";
  return `<div class="check-actions">
    <button class="btn small" type="button" data-act-open="${esc(r.k.id)}">${esc(a.button)}</button>
    <span class="hint">На одном узле, задачей iof. После неё узел проверяется заново.</span>
  </div>`;
}

// Задачи действий (заголовки из AUDIT_ACTIONS в iof-web.py): у них свой итог в карточке задачи
const ACT_JOB = /^(Смена портов Hysteria2|Обновление Hysteria2|Блок-лист сканеров)/;

// Проверка, для которой открыт диалог действий (hy2_hop или blocklist)
const actDlg = { id: "" };

function actBlocked() {
  return sec.running || !!(sec.data && sec.data.migrate && sec.data.migrate.role === "source");
}

function openActions(id) {
  actDlg.id = id;
  $("#act-title").textContent = ACT_CHECKS[id].title;
  const all = sec.data.nodes.map((n) => n.name);
  const saved = (sec.data.blocks.dpi || {}).nodes || {};
  // Узел из списка блока, если выбран один; иначе первый, для которого есть действие
  const pick = picked("dpi") || all.find((n) => checkOf(saved[n], id).act.length) || all[0] || "";
  $("#act-node").innerHTML = all.map((n) => {
    const c = checkOf(saved[n], id);
    return `<option value="${esc(n)}">${esc(n)} — ${esc(WORDS[c.status])}</option>`;
  }).join("");
  $("#act-node").value = pick;
  renderActDialog();
  $("#act-dialog").showModal();
}

function renderActDialog() {
  const name = $("#act-node").value;
  const res = ((sec.data.blocks.dpi || {}).nodes || {})[name];
  const c = checkOf(res, actDlg.id);
  $("#act-state").innerHTML = `<span class="check-status">${icon(c.status)}<span>${esc(c.value)}</span></span>${detailLines(c)}`;
  const blocked = actBlocked();
  $("#act-list").innerHTML = c.act.length ? c.act.filter((a) => ACTS[a]).map((a) => `<div class="act-item">
      <p>${esc(ACTS[a].text(sec.data.settings || {}))}</p>
      <button class="btn${ACTS[a].cls ? ` ${ACTS[a].cls}` : ""}" type="button" data-act="${a}"${blocked ? " disabled" : ""}>${esc(ACTS[a].label)}</button>
    </div>`).join("")
    : `<p class="hint">${res && res.reachable
      ? "Для этого узла действий нет: смотри «Как исправить» в проверке."
      : "Узел не проверен или без связи: сначала «Проверить» в блоке «Защита от РКН»."}</p>`;
  $("#act-note").hidden = !blocked;
  $("#act-note").textContent = sec.running ? "Идёт другая задача, дождись её окончания."
    : "Идёт перенос управления: здесь изменения заблокированы.";
}

async function runAction(action) {
  const node = $("#act-node").value;
  formError("", "#action-error");
  $("#act-dialog").close();
  try {
    const id = DEMO ? demoActionJob({ action, node }) : (await postJson("api/security", { action, node })).job;
    sec.kind = "audit";
    job.start(id);
    $("#job").scrollIntoView({ behavior: "smooth", block: "nearest" });
  } catch (e) {
    formError(e.message, "#action-error");
  }
}

// Список перерисовывается целиком, раскрытые проверки остаются раскрытыми
function renderChecks(block, rows, single) {
  const box = $(`#${block}-checks`);
  const open = new Set([...box.querySelectorAll("details[open]")].map((d) => d.dataset.id));
  box.innerHTML = sec.data.groups.filter((g) => g.block === block).map((g) => {
    const items = rows.filter((r) => r.k.group === g.id);
    return items.length ? `<h3 class="check-group">${esc(g.title)}</h3>
      <ul class="checks">${items.map((r) => checkRow(r, single, open)).join("")}</ul>` : "";
  }).join("");
}

function renderBlock(block) {
  renderNodeSelect(block);
  const nodes = blockNodes(block);
  const rows = sec.data.catalog.filter((k) => k.block === block)
    .map((k) => ({ k, per: nodes.map((n) => ({ n, c: checkOf(n.res, k.id) })) }));
  renderStamp(block, nodes);
  renderHealth(block, nodes, rows);
  renderChecks(block, rows, nodes.length === 1);
}


// Расписание и последние запуски

function renderSchedule() {
  const d = sec.data, s = d.settings;
  const when = s.cron.trim().split(/\s+/).slice(0, 5).join(" ");
  const bwhen = (s.block_cron || "").trim().split(/\s+/).slice(0, 5).join(" ");
  $("#sched").innerHTML =
    `<dt>Расписание</dt><dd>${s.cron ? `<code>${esc(when)}</code> · iof audit cron` : badge("warn", "не запланирована")}</dd>
     <dt>Telegram</dt><dd>${s.tg ? badge("good", "настроен") : badge("none", "не настроен")}</dd>
     <dt>Блок-лист</dt><dd>${!s.blocklist ? badge("none", "BLOCKLIST_URL не задан")
       : s.block_cron ? `<code>${esc(bwhen)}</code> · iof block update` : badge("warn", "обновление не запланировано")}</dd>`;
  const hints = [];
  if (!s.cron) hints.push("Раз в сутки, после ночного обслуживания: <code>sudo crontab -e</code>, строка <code>30 5 * * * /usr/local/bin/iof audit cron >/dev/null 2>&1</code>");
  if (s.blocklist && !s.block_cron) hints.push("Список сканеров на узлах обновляется раз в сутки строкой <code>15 5 * * * /usr/local/bin/iof block update >/dev/null 2>&1</code> в <code>sudo crontab -e</code>");
  if (!s.tg) hints.push("Сообщения о том, что стало хуже: <code>TG_TOKEN</code> и <code>TG_CHAT</code> в <code>/root/iof/iof.env</code>");
  else hints.push("В Telegram уходит сообщение, только когда проверка из cron оказалась хуже прошлой.");
  $("#sched-hint").hidden = !hints.length;
  $("#sched-hint").innerHTML = hints.join("<br>");

  const titles = Object.fromEntries(d.catalog.map((k) => [k.id, k.title]));
  const runs = d.history.slice(-6).reverse();
  $("#history").innerHTML = runs.length ? runs.map((h) => {
    const notes = [];
    if (h.down.length) notes.push(`${icon("warn")} нет связи: ${esc(h.down.join(", "))}`);
    if (h.worse.length) notes.push(`${icon("warn")} стало хуже: ${esc(h.worse.map((w) => `${w.node} — ${titles[w.id] || w.id}`).join("; "))}`);
    return `<div class="item">
      <div class="item-head"><span class="item-title">${fmtWhen(h.at)}</span>
        <span class="item-meta">${esc(RUN_WORDS[h.block] || h.block)} · узлов: ${h.nodes} · проблем: ${h.counts.crit} · внимание: ${h.counts.warn}</span></div>
      ${notes.map((n) => `<p class="hint check-note">${n}</p>`).join("")}
    </div>`;
  }).join("") : `<p class="empty">Проверок ещё не было.</p>`;
}

function syncButtons() {
  const off = sec.running || !sec.data || !!sec.data.error;
  document.querySelectorAll("[data-run]").forEach((b) => { b.disabled = off; });
  document.querySelectorAll("[data-act-open]").forEach((b) => { b.disabled = !sec.data || !!sec.data.error; });
  if ($("#act-dialog").open) renderActDialog();
  // Мишени меняют узлы: во время переноса управления их не запустить
  $("#probe-start").disabled = off || !!(sec.data && sec.data.migrate && sec.data.migrate.role === "source");
  $("#probe-cancel").disabled = sec.running;
}

function render() {
  const d = sec.data;
  renderMigrate(d.migrate);
  $("#alert").hidden = !d.error;
  if (d.error) {
    $("#alert").innerHTML = `${icon("crit")} iof не ответил: ${esc(d.error)}`;
    syncButtons();
    return;
  }
  BLOCKS.forEach(renderBlock);
  renderProbe();
  renderSchedule();
  syncButtons();
}

async function load() {
  $("#refresh").setAttribute("aria-busy", "true");
  try {
    sec.data = DEMO ? await demoAudit() : await getJson("api/security");
    render();
  } catch (e) {
    $("#alert").hidden = false;
    $("#alert").innerHTML = `${icon("crit")} Нет связи с панелью: ${esc(e.message)}`;
  } finally {
    $("#refresh").removeAttribute("aria-busy");
  }
}


// Проверка: задача iof audit run, по окончании данные загружаются заново

async function run(block) {
  formError("", "#action-error");
  const body = { block, node: picked(block) };
  try {
    const id = DEMO ? demoAuditJob(body) : (await postJson("api/security", body)).job;
    sec.kind = "audit";
    job.start(id);
    $("#job").scrollIntoView({ behavior: "smooth", block: "nearest" });
  } catch (e) {
    formError(e.message, "#action-error");
  }
}

// Итог задачи проверки с ПК: запуск мишеней, остановка или приём отчёта
function probeJobResult(j, lvl) {
  const reason = failReason(j.log);
  const start = j.title.includes("запуск"), result = j.title.includes("результат");
  if (j.state === "ok" || j.state === "warn") {
    const text = start ? "Мишени запущены: команда для ПК — в карточке «Доступность из РФ»"
      : result ? "Отчёт с ПК принят, результат в карточке «Доступность из РФ»" : "Мишени остановлены";
    jobResult(lvl, `${icon(j.state === "ok" ? "good" : "warn")}<div>${text}${j.state === "warn" && reason
      ? `. Не на всех узлах: <b>${esc(reason)}</b>` : ""}</div>`);
  } else if (j.state === "error") {
    jobResult(lvl, `${icon("crit")}<div>${start ? "Мишени не запустились" : result ? "Отчёт не принят" : "Мишени не остановились"}${
      reason ? `: <b>${esc(reason)}</b>` : ", причина в логе"}</div>`);
  } else {
    jobResult(lvl, "");
  }
}

function renderJob(j) {
  const lvl = renderJobCard(j);
  const was = sec.running;
  sec.running = !!j && j.state === "running";
  syncButtons();
  if (!j) return;
  $("#job-hide").hidden = sec.running;
  if (j.kind === "probe") {
    // Этап карточки зависит от того, идёт ли задача
    if (was !== sec.running && sec.data && !sec.data.error) renderProbe();
    probeJobResult(j, lvl);
  } else if (ACT_JOB.test(j.title)) {
    const reason = failReason(j.log);
    if (j.state === "ok") jobResult(lvl, `${icon("good")}<div>Готово, узел проверен заново: результат в проверке ниже</div>`);
    else if (j.state === "warn") jobResult(lvl, `${icon("warn")}<div>Сделано не всё${reason ? `: <b>${esc(reason)}</b>` : ", подробности в логе"}</div>`);
    else if (j.state === "error") jobResult(lvl, `${icon("crit")}<div>Не получилось${reason ? `: <b>${esc(reason)}</b>` : ", причина в логе"}</div>`);
    else jobResult(lvl, "");
  } else if (j.state === "ok") {
    jobResult(lvl, `${icon("good")}<div>Проверка завершена, результат ниже</div>`);
  } else if (j.state === "warn") {
    jobResult(lvl, `${icon("warn")}<div>Проверены не все узлы${failReason(j.log) ? `: <b>${esc(failReason(j.log))}</b>` : ""}</div>`);
  } else if (j.state === "error") {
    const reason = failReason(j.log);
    jobResult(lvl, `${icon("crit")}<div>Проверка не прошла${reason ? `: <b>${esc(reason)}</b>` : ", причина в логе"}</div>`);
  } else {
    jobResult(lvl, "");
  }
}



// Проверка с ПК (iof audit probe). Состояние: probe из iof api audit (сессия, последний результат,
// история) и probe_state от панели (сессия и билет). Этапы карточки: idle — проверки нет, starting —
// мишени запускаются, wait — ждём отчёт с ПК, import — отчёт принят, считается результат, expired —
// мишени остановлены без отчёта, foreign — мишени запущены не из этой панели или до её перезапуска

const PROBE_VERDICT = {
  ok: "проходит", blocked: "не проходит", stall: "встаёт", partial: "частично", mitm: "подмена",
  fail: "не поднялся", down: "нет контроля", unknown: "не с чем сравнить", skipped: "не проверялся",
};
const PROBE_CONF = { high: "высокая", medium: "средняя", low: "низкая" };
const PROBE_STATE = {
  nopython: "нет python3", noopenssl: "нет openssl", nosystemd: "нет systemd-run", nft: "входящие режет nftables",
  busy: "нет свободного порта", error: "мишень не запустилась", down: "узел не ответил по SSH",
};

function nowSec() {
  return Date.now() / 1000;
}

function probeStage() {
  const st = sec.data.probe_state || {}, p = st.panel, s = st.session;
  const live = s && !s.stopped && s.expires > nowSec();
  if (!p) return live ? "foreign" : "idle";
  if (p.result_at) {
    const last = (sec.data.probe || {}).last;
    return p.pending || sec.running || !last || !s || last.session !== s.id ? "import" : "idle";
  }
  if (!p.mine) return sec.running ? "starting" : "idle";
  return live ? "wait" : "expired";
}

function fmtLeft(left) {
  const s = Math.max(0, Math.floor(left));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

// Команда для окна PowerShell на ПК: сохранить скрипт в файл и запустить его. Сразу из сети
// (iex (iwr …)) не запускаем: так выглядит загрузчик вредоносного кода, и антивирусы это блокируют
function probeCommand(p) {
  return `iwr -UseBasicParsing '${p.origin}/api/probe/script?t=${p.ticket}' -OutFile iof-probe.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File .\\iof-probe.ps1`;
}

// Мишени по узлам: порт и итог контроля или почему мишени нет
function probeTargets(s) {
  return `<dl class="check-nodes">${Object.entries(s.nodes).map(([name, n]) => `<dt>${esc(name)}</dt><dd>${
    n.state === "started"
      ? `<span class="check-status">${icon(n.check.includes(" 0/") ? "warn" : "good")}<span>порт ${n.port}${
        n.fw === "opened" ? ", открыт в файрволе на время проверки" : ""}</span></span><span class="check-detail">контроль: ${esc(n.check)}</span>`
      : `<span class="check-status">${icon("none")}<span>не проверяется: ${esc(PROBE_STATE[n.state] || n.state)}${
        n.state === "nopython" ? " (на узле: apt install python3)" : ""}</span></span>`}</dd>`).join("")}</dl>`;
}

function renderProbeWait(stage) {
  const el = $("#probe-wait"), st = sec.data.probe_state || {}, p = st.panel, s = st.session;
  el.hidden = !["starting", "wait", "import", "expired", "foreign"].includes(stage);
  if (el.hidden) return;
  let html;
  if (stage === "starting") {
    html = `<p class="probe-line"><span class="spinner" aria-hidden="true"></span>Запускаю мишени на узлах и проверяю их с управляющего сервера…</p>`;
  } else if (stage === "import") {
    html = `<p class="probe-line"><span class="spinner" aria-hidden="true"></span>Отчёт с ПК принят${p.pending
      ? ", ждёт, пока закончится другая задача" : ""}: останавливаю мишени и считаю результат…</p>`;
  } else if (stage === "expired") {
    html = `<div class="note warn">${icon("warn")}<div>Мишени проверки ${esc(s.id)} ${s.stopped ? "остановлены" : "отработали срок"}, отчёт с ПК не пришёл.
      Если скрипт сохранил его в <code>iof-probe-report.json</code>, на управляющем сервере:
      <code>sudo iof audit probe import &lt; iof-probe-report.json</code>. Или начни проверку заново.</div></div>`;
  } else if (stage === "foreign") {
    html = `<div class="note warn">${icon("warn")}<div>Идёт проверка ${esc(s.id)}, начатая из терминала или до перезапуска панели:
      билета для ПК у панели нет. Останови её и начни заново отсюда.</div></div>${probeTargets(s)}`;
  } else {
    const steps = [
      "Выключи на ПК VPN и прокси: проверка должна идти через твоего провайдера.",
      `Необязательно, для настоящего туннеля Hysteria2: скопируй ссылки группы на странице <a href="hy2.html${DEMO ? "?demo" : ""}">Hysteria2</a>
        и положи <code>hysteria.exe</code> в папку, где запускаешь скрипт. Он спросит согласие, пароли из ссылок с ПК не уходят.`,
    ];
    if (p.ticket) {
      steps.push(`Выполни в окне PowerShell на ПК, пока открыт SSH-туннель к панели. Команда сохранит скрипт
        в <code>iof-probe.ps1</code> в текущей папке и запустит его:
        <div class="cmd"><pre class="code">${esc(probeCommand(p))}</pre><button class="btn small" type="button" data-copy>Копировать</button></div>
        <span class="check-detail">Или <a href="${DEMO ? "#" : esc(`api/probe/script?t=${p.ticket}`)}" download="iof-probe.ps1" data-script>скачай скрипт</a>
        и запусти <code>powershell -ExecutionPolicy Bypass -File .\\iof-probe.ps1</code>. Скрипт выдаётся один раз: по команде или по ссылке.
        Его можно прочитать перед запуском, а после проверки удалить: билет и токен в нём одноразовые.</span>`);
    } else {
      steps.push(`Скрипт получен${p.script_at ? ` в ${fmtTime(p.script_at)}` : ""}, жду отчёт. Если отправить его не удастся,
        скрипт сохранит <code>iof-probe-report.json</code>: на управляющем сервере <code>sudo iof audit probe import &lt; iof-probe-report.json</code>.`);
    }
    html = `<p class="probe-line">Проверка ${esc(s.id)}: мишени работают ещё <b class="countdown" data-until="${s.expires}">${fmtLeft(s.expires - nowSec())}</b></p>
      <ol class="probe-steps">${steps.map((x) => `<li>${x}</li>`).join("")}</ol>${probeTargets(s)}`;
  }
  el.innerHTML = html;
}

function renderProbeResult(r) {
  const el = $("#probe-health"), box = $("#probe-nodes");
  const open = new Set([...box.querySelectorAll("details[open]")].map((d) => d.dataset.id));
  $("#probe-stamp").textContent = r ? `проверено ${fmtWhen(r.at)}` : "";
  if (!r) {
    el.className = "health";
    el.innerHTML = `${icon("none", "ico big-ico")}<div><h2>Проверки с ПК ещё не было</h2>
      <p class="sub">«Начать проверку» поднимет мишени на узлах и даст команду для ПК. То же в терминале: <code>sudo iof audit probe start</code></p></div>`;
    box.innerHTML = "";
    return;
  }
  const nodes = Object.entries(r.nodes);
  const pick = $("#probe-node").value;
  const shown = nodes.filter(([name]) => !pick || name === pick);
  const count = (st) => nodes.filter(([, n]) => n.status === st).length;
  const level = count("crit") ? "crit" : count("warn") ? "warn" : count("good") ? "good" : "none";
  const total = nodes.length, of = `из ${total} ${plural(total, ["узла", "узлов", "узлов"])}`;
  const title = r.confidence === "low" ? "Результат не о провайдере"
    : count("crit") ? `С ПК не доходит до ${count("crit")} ${of}`
    : count("warn") ? `Есть замечания по ${count("warn")} ${of}`
    : count("good") ? "Все проверенные узлы доступны с ПК" : "Сравнить не с чем";
  const items = r.reasons.map((why) => `<li>${icon(r.confidence === "low" ? "warn" : "none")}<span>${esc(why)}</span></li>`);
  el.className = `health ${r.confidence === "low" ? "warn" : level}`;
  el.innerHTML = `${icon(r.confidence === "low" ? "warn" : level, "ico big-ico")}<div>
    <h2>${esc(title)}</h2>
    <p class="sub">Сеть ПК: ${esc(r.net.label)}${r.net.ip ? ` (${esc(r.net.ip)})` : ""} · уверенность: ${PROBE_CONF[r.confidence]} ·
      проблем: ${count("crit")} · внимание: ${count("warn")} · в порядке: ${count("good")} · нет данных: ${count("none")}</p>
    ${items.length ? `<ul class="issues">${items.join("")}</ul>` : ""}
  </div>`;
  box.innerHTML = `<ul class="checks">${shown.map(([name, n]) => `<li><details data-id="${esc(name)}"${open.has(name) ? " open" : ""}>
    <summary>${badge(n.status, WORDS[n.status])}<span class="item-title">${esc(name)}</span><span class="check-value">${esc(n.value)}</span></summary>
    <div class="check-body">
      ${n.layers.length ? `<p class="check-why">Уверенность: ${PROBE_CONF[n.confidence]}. «С ПК» — что прошло от твоего провайдера,
        «Контроль» — что прошло с управляющего сервера до той же мишени.</p>` : ""}
      ${n.detail.length ? `<p class="check-facts">${n.detail.map((x) => `<span class="check-detail">${esc(x)}</span>`).join("")}</p>` : ""}
      ${n.layers.length ? `<div class="table-wrap"><table class="trace">
        <thead><tr><th>Слой</th><th>С ПК</th><th>Контроль</th><th>Итог</th></tr></thead>
        <tbody>${n.layers.map((x) => `<tr><td>${esc(x.title)}</td><td data-label="С ПК">${esc(x.pc)}</td>
          <td data-label="Контроль">${esc(x.control)}</td><td>${badge(x.status, PROBE_VERDICT[x.verdict] || x.verdict)}</td></tr>`).join("")}</tbody>
      </table></div>` : ""}
      ${n.hint || n.cmd ? `<div class="fix"><h4>Что делать</h4>${n.hint ? `<p>${esc(n.hint)}</p>` : ""}${n.cmd
        ? `<div class="cmd"><pre class="code">${esc(n.cmd)}</pre><button class="btn small" type="button" data-copy>Копировать</button></div>` : ""}</div>` : ""}
    </div>
  </details></li>`).join("")}</ul>`;
}

function renderProbeHistory(hist) {
  const runs = hist.slice(0, -1).slice(-5).reverse();
  $("#probe-history").innerHTML = runs.map((h) => `<div class="item">
    <div class="item-head"><span class="item-title">${fmtWhen(h.at)}</span>
      <span class="item-meta">${esc(h.net)} · уверенность: ${PROBE_CONF[h.confidence]} · проблем: ${h.counts.crit} · внимание: ${h.counts.warn}</span></div>
  </div>`).join("");
}

function renderProbe() {
  const d = sec.data, p = d.probe || { session: null, last: null, history: [] };
  const stage = probeStage();
  const el = $("#probe-node"), names = d.nodes.map((n) => n.name);
  if (el.dataset.names !== names.join(" ")) {
    const pick = el.value;
    el.dataset.names = names.join(" ");
    el.innerHTML = `<option value="">Все узлы</option>` + names.map((n) => `<option>${esc(n)}</option>`).join("");
    el.value = names.includes(pick) ? pick : "";
  }
  const busy = ["starting", "wait", "import", "foreign"].includes(stage);
  $("#probe-start").hidden = busy;
  el.hidden = busy;
  $("#probe-cancel").hidden = !["wait", "foreign"].includes(stage);
  renderProbeWait(stage);
  renderProbeResult(p.last);
  renderProbeHistory(p.history);
  if (busy || stage === "expired") sec.kind = "probe";
  // Пока проверка идёт: обратный отсчёт раз в секунду и состояние раз в 2 секунды
  clearInterval(sec.tick);
  if (stage === "wait") {
    sec.tick = setInterval(() => document.querySelectorAll(".countdown").forEach((c) => {
      c.textContent = fmtLeft(Number(c.dataset.until) - nowSec());
    }), 1000);
  }
  clearTimeout(sec.poll);
  if (busy) sec.poll = setTimeout(() => pollProbe(stage), stage === "import" ? 3000 : 2000);
}

// Опрос во время проверки: этап меняется — данные загружаются целиком
async function pollProbe(was) {
  try {
    if (DEMO) {
      sec.data = await demoAudit();
    } else if (was === "import") {
      sec.data = await getJson("api/security");
    } else {
      sec.data.probe_state = await getJson("api/probe");
    }
  } catch {
    // нет связи: попробуем в следующий раз
  }
  if (probeStage() !== was) {
    // Отчёт с ПК принят: задачу с ним запустила панель, карточка задачи её подхватит
    job.poll();
    if (was !== "import") return load();
  }
  render();
}

async function probeStart() {
  formError("", "#action-error");
  const node = $("#probe-node").value;
  const body = { action: "start", nodes: node ? [node] : [], origin: location.origin };
  try {
    const id = DEMO ? demoProbeJob(body) : (await postJson("api/probe", body)).job;
    sec.kind = "probe";
    sec.data.probe_state = DEMO ? demoProbeState() : await getJson("api/probe");
    job.start(id);
  } catch (e) {
    formError(e.message, "#action-error");
  }
}

async function probeCancel() {
  formError("", "#action-error");
  try {
    const id = DEMO ? demoProbeJob({ action: "cancel" }) : (await postJson("api/probe", { action: "cancel" })).job;
    sec.kind = "probe";
    job.start(id);
  } catch (e) {
    formError(e.message, "#action-error");
  }
}

document.addEventListener("DOMContentLoaded", async () => {
  $("#refresh").addEventListener("click", load);
  $("#job-hide").addEventListener("click", () => job.hide());
  for (const block of BLOCKS) {
    $(`#${block}-run`).addEventListener("click", () => run(block));
    $(`#${block}-node`).addEventListener("change", () => sec.data && !sec.data.error && renderBlock(block));
  }
  $("#probe-start").addEventListener("click", probeStart);
  $("#probe-cancel").addEventListener("click", probeCancel);
  $("#probe-node").addEventListener("change", () => sec.data && !sec.data.error && renderProbeResult((sec.data.probe || {}).last));
  $("#act-node").addEventListener("change", renderActDialog);
  $("#act-close").addEventListener("click", () => $("#act-dialog").close());
  $("#act-dialog").addEventListener("click", (e) => {
    if (e.target === e.currentTarget) e.currentTarget.close();
    const b = e.target.closest("[data-act]");
    if (b && !b.disabled) runAction(b.dataset.act);
  });
  document.querySelector("main").addEventListener("click", async (e) => {
    const open = e.target.closest("[data-act-open]");
    if (open && !open.disabled) openActions(open.dataset.actOpen);
    const btn = e.target.closest("[data-copy]");
    if (btn) toast(await copyText(btn.previousElementSibling.textContent) ? "Скопировано" : "Не удалось скопировать");
    // Скрипт по ссылке забирается один раз: дальше страница покажет, что ждёт отчёт
    if (e.target.closest("[data-script]")) {
      if (DEMO) {
        e.preventDefault();
        demoProbeScript();
      }
      setTimeout(() => pollProbe("wait"), 1500);
    }
  });
  await load();
  job.poll();
});


// Демо: шесть узлов из demo.js со всеми видами оценок в каждом блоке, node-5 без связи.
// Тексты как у iof audit

const demoAuditState = {
  at: { server: Math.floor(Date.now() / 1000) - 5 * 3600, dpi: Math.floor(Date.now() / 1000) - 5 * 3600 },
  runs: [{ ago: 86400, block: "all" }, { ago: 0, block: "all" }],
};

const DEMO_AUDIT_GROUPS = [["ssh", "SSH"], ["net", "Сеть и защита от подбора"], ["upd", "Обновления"], ["sys", "Система"]];
const DEMO_AUDIT_CATALOG = [
  ["ssh_root", "ssh", "Вход root по SSH", "Имя root известно заранее, поэтому пароль подбирают в первую очередь к нему. Вход только по ключу подбором не взять. iof заходит на узлы по ключу, пароль root ему не нужен."],
  ["ssh_password", "ssh", "Вход по паролю", "Пароль можно подобрать или подсмотреть, ключ нельзя. Боты перебирают пароли SSH на любом сервере круглые сутки."],
  ["ssh_port", "ssh", "Порт SSH", "На порт 22 приходит основной поток автоматического подбора. При входе только по ключу это шум в журнале, при входе по паролю — риск."],
  ["ssh_keys", "ssh", "Вход по ключу", "По ключу iof выполняет команды на узле. Если authorized_keys доступен на запись другим пользователям, в него можно дописать чужой ключ."],
  ["firewall", "net", "Файрвол", "Без запрета по умолчанию снаружи доступно всё, что слушает порт, в том числе службы, поставленные случайно. Файрвол хостера (security group) с узла не виден: если он есть, это предупреждение можно оставить."],
  ["ban", "net", "Блокировка подбора", "fail2ban или CrowdSec блокируют адрес после нескольких неудачных входов. При входе по паролю это основная защита от подбора, при входе только по ключу — чистый журнал."],
  ["ban_port", "net", "Порт sshd в fail2ban", "Если jail sshd следит не за тем портом, на котором слушает SSH, блокировка адреса не закрывает ему SSH."],
  ["auth_fail", "net", "Неудачные входы за сутки", "Много попыток значит, что сервер перебирают. При входе только по ключу они безвредны."],
  ["ports", "net", "Слушающие порты", "Каждый открытый порт — это служба, которую можно атаковать и по которой узел можно опознать. Ожидаемые: SSH, Hysteria2, контейнер AmneziaWG, порты ретранслятора. То, что слушает только 127.0.0.1, снаружи недоступно."],
  ["updates", "upd", "Ожидающие обновления", "Обновления безопасности закрывают известные уязвимости. iof-nightly ставит их каждую ночь, если он запланирован в cron."],
  ["reboot", "upd", "Перезагрузка", "Новое ядро и системные библиотеки начинают работать только после перезагрузки. iof-nightly перезагружает узел после обновления."],
  ["nightly", "upd", "Ночное обслуживание", "iof-nightly обновляет пакеты и перезагружает узел. Если он давно не отрабатывал, узел остаётся без обновлений."],
  ["sudo_log", "sys", "Журнал sudo", "По журналу sudo видно, кто и какие команды выполнял от root. Без него не разобраться, что происходило на сервере."],
  ["pwquality", "sys", "Требования к паролям", "pam_pwquality не даёт задать короткий или простой пароль. Важно там, где по паролю входят в SSH или вызывают sudo."],
  ["suid", "sys", "SUID-файлы", "SUID-файл выполняется с правами владельца, обычно root. Лишний такой файл — способ повысить права, его же оставляют после взлома."],
];

// Проверки узла: всё в порядке, поверх — отличия over {id: [статус, значение, подробности, совет, команды]}
function demoAuditChecks(awgPort, over) {
  const night = `отработало ${fmtWhen(new Date().setHours(4, 5, 0, 0) / 1000)}`;
  const reload = "sshd -t && systemctl reload ssh";
  const base = {
    ssh_root: ["good", "только по ключу (prohibit-password)"],
    ssh_password: ["good", "выключен"],
    ssh_port: ["good", "22, вход только по ключу"],
    ssh_keys: ["good", "включён, ключей у root: 2"],
    firewall: ["good", "ufw: входящие по умолчанию запрещены"],
    ban: ["good", "fail2ban работает, jail: sshd"],
    ban_port: ["good", "совпадает: ssh"],
    auth_fail: ["good", "214, вход только по ключу"],
    ports: ["good", `только ожидаемые: 22/tcp SSH, 443/udp Hysteria2${awgPort ? `, ${awgPort}/udp amnezia-awg2` : ""}`,
      ["Только локально (loopback): 53/tcp systemd-resolve, 53/udp systemd-resolve"]],
    updates: ["good", "нет", [`Списки пакетов обновлялись ${fmtWhen(new Date().setHours(4, 5, 0, 0) / 1000)}`]],
    reboot: ["good", "не нужна"],
    nightly: ["good", night],
    sudo_log: ["good", "в журнале systemd и /var/log/auth.log"],
    pwquality: ["warn", "не настроено", ["Вход по паролю в SSH выключен: это касается только локальных паролей и sudo"], "На узле от root:",
      "apt-get install -y libpam-pwquality && sed -i -E 's/^#? ?minlen.*/minlen = 12/' /etc/security/pwquality.conf"],
    suid: ["good", "13, все из стандартного набора Ubuntu 24.04"],
  };
  const all = { ...base, ...over(reload) };
  return Object.entries(all).map(([id, [status, value, detail = [], hint = "", cmd = ""]]) => ({ id, status, value, detail, hint, cmd }));
}

function demoAuditNodes() {
  const fw = (ports) => ["apt-get install -y ufw", "ufw allow 22/tcp", ...ports.map((p) => `ufw allow ${p}`), "ufw default deny incoming", "ufw --force enable"].join("\n");
  const fwHint = "Команды сначала открывают порты SSH, Hysteria2, AmneziaWG и ретранслятора этого узла, потом включают запрет остального. Сверь список со своими службами. На узле от root:";
  const cron = ["На управляющем сервере: sudo crontab -e, строка ниже. Каждую ночь в 4:00 обновятся и перезагрузятся все узлы.", "0 4 * * * /usr/local/sbin/iof-nightly"];
  const checks = {
    main: demoAuditChecks("41234", () => ({
      ports: ["good", "только ожидаемые: 22/tcp SSH, 443/udp Hysteria2, 41234/udp amnezia-awg2",
        ["Только локально (loopback): 53/tcp systemd-resolve, 53/udp systemd-resolve, 8088/tcp python3"]],
    })),
    "node-1": demoAuditChecks("42345", (reload) => ({
      ssh_root: ["crit", "разрешён, в том числе по паролю", [],
        "iof заходит на этот узел под root по ключу, поэтому совсем запрещать root нельзя: оставь ему вход только по ключу. На узле от root:",
        `echo 'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/00-iof-root.conf && ${reload}`],
      ssh_password: ["crit", "включён, root тоже", [],
        "Сначала убедись, что сам входишь на сервер по ключу: iof уже ходит по ключу, ему пароль не нужен. На узле от root:",
        `printf 'PasswordAuthentication no\\nKbdInteractiveAuthentication no\\n' > /etc/ssh/sshd_config.d/00-iof-password.conf && ${reload}`],
      ssh_port: ["warn", "22, вход по паролю включён", [],
        "Надёжнее выключить вход по паролю (проверка «Вход по паролю»): тогда порт не важен. Если пароли нужны, порт можно сменить, например на 2222: открой его в файрволе, затем выполни команду ниже. После неё на управляющем сервере в /root/iof/nodes.conf поставь узлу node-1 адрес SSH root@198.51.100.20:2222. На узле от root:",
        "echo 'Port 2222' > /etc/ssh/sshd_config.d/00-iof-port.conf && sshd -t && systemctl daemon-reload && { systemctl restart ssh.socket 2>/dev/null; systemctl restart ssh; }"],
      firewall: ["crit", "нет, снаружи доступно всё, что слушает порт, есть лишние порты", [], fwHint, fw(["42345/udp", "443/udp"])],
      ban: ["crit", "нет, а вход по паролю включён", [], "В Ubuntu jail sshd включён сразу после установки. На узле от root:",
        "apt-get install -y fail2ban && systemctl enable --now fail2ban"],
      ban_port: ["none", "fail2ban не работает"],
      auth_fail: ["crit", "1840, вход по паролю включён", [], "Выключи вход по паролю и поставь fail2ban: проверки «Вход по паролю» и «Блокировка подбора»."],
      ports: ["crit", "лишние: 3306/tcp mysqld, 8080/tcp python3, файрвола нет",
        ["Ожидаемые: 22/tcp SSH, 443/udp Hysteria2, 42345/udp amnezia-awg2", "Только локально (loopback): 53/tcp systemd-resolve, 53/udp systemd-resolve"],
        "Узнай, что это за служба. Если она не нужна, останови её, иначе закрой порт файрволом. На узле от root:",
        "ss -tulnp | grep -E ':(3306|8080) '\nsystemctl disable --now <служба>"],
      pwquality: ["warn", "не настроено", [], "На узле от root:",
        "apt-get install -y libpam-pwquality && sed -i -E 's/^#? ?minlen.*/minlen = 12/' /etc/security/pwquality.conf"],
    })),
    "node-2": demoAuditChecks("43456", () => ({
      ports: ["good", "только ожидаемые: 22/tcp SSH, 443/udp Hysteria2, 43456/udp amnezia-awg2",
        ["Ретранслятор (DNAT, без сокета): 45001/udp → 192.0.2.10:443, 45002/udp → 192.0.2.10:41234", "Только локально (loopback): 53/tcp systemd-resolve, 53/udp systemd-resolve"]],
      updates: ["warn", "12, из них безопасности: 4", [`Списки пакетов обновлялись ${fmtWhen(Date.now() / 1000 - 9000)}`],
        "Чтобы обновления ставились сами каждую ночь, запланируй iof-nightly (проверка «Ночное обслуживание»). Поставить сейчас. На узле от root:",
        "apt-get update && apt-get -y upgrade"],
      reboot: ["warn", "нужна (linux-image-6.8.0-48-generic)", [], "Клиенты узла отключатся на минуту. iof-nightly перезагружает узлы сам. На узле от root:", "reboot"],
      nightly: ["warn", `давно: последний раз ${fmtWhen(Date.now() / 1000 - 6 * 86400)}`, [], ...cron],
    })),
    "node-3": demoAuditChecks("", () => ({
      firewall: ["warn", "нет, снаружи доступно всё, что слушает порт", [], fwHint, fw(["443/udp"])],
      ban: ["warn", "нет, вход только по ключу", [], "В Ubuntu jail sshd включён сразу после установки. На узле от root:",
        "apt-get install -y fail2ban && systemctl enable --now fail2ban"],
      ban_port: ["none", "fail2ban не работает"],
      suid: ["warn", "вне стандартного набора Ubuntu 24.04: 1 из 14", ["/usr/local/bin/backup-helper"],
        "Узнай, из какого пакета файл. Если он не нужен, сними с него SUID. На узле от root:", "dpkg -S /usr/local/bin/backup-helper\nchmod u-s <путь>"],
    })),
    "node-4": demoAuditChecks("", () => ({
      ssh_keys: ["warn", "ключей у root: 2, но authorized_keys доступен на запись не только владельцу (права 664)", [], "На узле от root:", "chmod 600 ~root/.ssh/authorized_keys"],
      ban_port: ["warn", "jail следит за ssh, а SSH слушает 2222", [], "На узле от root:",
        "printf '[sshd]\\nenabled = true\\nport = 2222\\n' > /etc/fail2ban/jail.d/iof-sshd.local && systemctl restart fail2ban"],
      ssh_port: ["good", "2222, вход только по ключу"],
      ports: ["good", "только ожидаемые: 2222/tcp SSH, 443/udp Hysteria2",
        ["Только локально (loopback): 53/tcp systemd-resolve, 53/udp systemd-resolve"]],
      sudo_log: ["crit", "выключен (Defaults !syslog в sudoers)", [], "Найди эту строку и убери её через visudo. На узле от root:",
        "grep -rn '!syslog' /etc/sudoers /etc/sudoers.d"],
    })),
  };
  return demoBlockNodes(checks, demoAuditState.at.server);
}

// Результат блока по узлам из demo.js: checks {узел: проверки}, недоступный узел без оценок
function demoBlockNodes(checks, at) {
  const out = {};
  for (const n of demoNodes()) {
    out[n.name] = n.reachable
      ? { addr: n.addr, reachable: true, at, checked: at, error: "", checks: checks[n.name] || [] }
      : { addr: n.addr, reachable: false, at, checked: 0, error: "нет связи по SSH", checks: [] };
  }
  return out;
}

const DEMO_DPI_GROUPS = [["hy2", "Hysteria2"], ["awg", "AmneziaWG"], ["probe", "Что видно снаружи"], ["scan", "Сканеры"],
  ["rep", "Репутация адреса"], ["hyg", "Гигиена"]];
const DEMO_DPI_CATALOG = [
  ["hy2_mode", "hy2", "Режим маскировки", "Без маскировки Hysteria2 — это QUIC, который на запрос по HTTP/3 отвечает ошибкой 404: такой сервер легко отличить от сайта. Salamander делает трафик похожим на случайный шум, но на QUIC он уже не похож. Без Salamander с masquerade сервер выглядит как сайт с HTTP/3, но QUIC к зарубежным адресам фильтры режут. Это выбор, а не ошибка."],
  ["hy2_masq", "hy2", "Masquerade", "Тому, кто пришёл на порт Hysteria2 без пароля, сервер показывает сайт из masquerade. Если цель не отвечает, зонд увидит ошибку вместо сайта. Под Salamander masquerade снаружи не виден."],
  ["hy2_quic", "hy2", "Ответ на зонд QUIC", "Управляющий сервер отправляет на порт Hysteria2 пакет QUIC с несуществующей версией. Обычный сервер QUIC отвечает согласованием версий, под Salamander порт так не отвечает. Так видно, что получит тот, кто зондирует порт, и доходит ли до узла UDP."],
  ["hy2_port", "hy2", "Порт", "HTTP/3 работает на 443/udp, QUIC на другом порту встречается редко и заметнее. Под Salamander трафик не похож на QUIC на любом порту."],
  ["hy2_hop", "hy2", "Смена портов (port hopping)", "Клиент раз в полминуты меняет порт, поэтому блокировка одного порта или долгого потока UDP не обрывает связь. Для этого нужен диапазон портов на сервере и он же в ссылке клиента. iof включает диапазон на узле (iof hy2 hop), а список портов попадает только в ссылки групп с --hop: старые клиенты такую ссылку не импортируют."],
  ["hy2_template", "hy2", "Конфиг и шаблон", "iof hy2 install ставит на узлы конфиг по шаблону с управляющего сервера. Если конфиг узла потом правили вручную, маскировка на нём отличается от остальных, а повторная установка затрёт правки."],
  ["awg_params", "awg", "Параметры обфускации", "AmneziaWG отличается от WireGuard мусорными пакетами (Jc, Jmin, Jmax), добавками к пакетам (S1–S4) и своими заголовками (H1–H4). С нулями и заголовками 1, 2, 3, 4 это обычный WireGuard, который фильтры узнают по первому пакету."],
  ["awg_same", "awg", "Одинаковые параметры на узлах", "С одинаковыми параметрами трафик узлов выглядит одинаково: признак, найденный для одного узла, подойдёт ко всем. Сравнение идёт по хэшу, сами значения в панель и в файлы не попадают."],
  ["tcp_web", "probe", "Порты 80 и 443/tcp", "Сайт с HTTP/3 отвечает и по обычному HTTPS на 443/tcp. Если на 443/udp есть QUIC, а 443/tcp закрыт, сервер на сайт не похож. Посторонняя служба на этих портах показывает зонду свои заголовки и сертификат."],
  ["tls_cert", "probe", "Сертификат", "Сертификат видит любой, кто подключится к порту. Самоподписанный сертификат на имя известного сайта на адресе, который этому сайту не принадлежит, — заметный признак."],
  ["icmp", "probe", "Ответ на ping", "Обычный сервер чаще отвечает на ping. Молчание само ничего не выдаёт: так настроено у многих хостеров."],
  ["names", "probe", "Имя сервера и PTR", "Обратную запись DNS (PTR) видит любой по адресу узла, имя сервера попадает в приветствия служб. Слова vpn, proxy, wg в них говорят о назначении сервера."],
  ["banners", "probe", "Лишние порты снаружи", "Служба на лишнем порту отвечает приветствием с названием и версией программы. По нему сканер понимает, что стоит на сервере."],
  ["panel", "probe", "Панель iof-web", "Панель управляет всеми узлами от root. Она должна слушать только 127.0.0.1 и открываться через SSH-туннель: на внешнем адресе её найдёт любой сканер."],
  ["blocklist", "scan", "Блок-лист сканеров", "Список адресов, с которых узлы сканируют и зондируют. Если пакеты от них отбрасывать, сканер с этих адресов видит закрытый сервер. Это снижает заметность, но не прячет узел: сканеры меняют адреса. Применяет и обновляет список iof block."],
  ["asn", "rep", "Сеть и хостер", "Сети крупных хостеров VPS фильтры знают и относятся к ним строже, чем к домашним. Это справка: изменить её можно только переездом к другому хостеру."],
  ["registry", "rep", "Адрес в реестре", "Если адрес узла есть в выгрузке реестра блокировок, у части провайдеров он уже недоступен и клиенты до него не дойдут."],
  ["journald", "hyg", "Срок хранения журнала", "В журнале остаются адреса клиентов и время подключений. Если сервер изымут или взломают, журнал покажет, кто им пользовался. Чем короче срок хранения, тем меньше можно узнать."],
  ["hy2_log", "hyg", "Журнал Hysteria2", "На уровне info Hysteria2 пишет в журнал адрес каждого подключившегося клиента, на debug ещё и адреса, куда он ходит."],
  ["awg_log", "hyg", "Лог контейнера AmneziaWG", "Docker по умолчанию пишет вывод контейнера в файл без ограничения размера. Со временем он занимает диск и хранит историю дольше, чем нужно."],
  ["time", "hyg", "Время", "При сбитых часах не проходит проверка сертификатов, а время в журналах узлов не сходится между собой."],
];

// Проверки блока dpi для узла: частый случай, поверх — отличия over {id: [статус, значение, подробности, совет, команды]}
function demoDpiChecks(addr, over) {
  const listDay = fmtWhen(new Date().setHours(5, 30, 0, 0) / 1000);
  const restart = "systemctl restart hysteria-server";
  const base = {
    hy2_mode: ["good", "без Salamander, с masquerade: сервер выглядит как сайт с HTTP/3",
      ["QUIC к зарубежным адресам фильтры могут резать. Salamander прячет QUIC, но делает трафик непохожим ни на что: это иной компромисс, а не улучшение"]],
    hy2_masq: ["good", "proxy на https://example.org/, цель с узла отвечает (200)"],
    hy2_quic: ["good", "порт 443/udp отвечает как сервер QUIC (согласование версий)"],
    hy2_port: ["good", "443/udp, как у HTTP/3"],
    hy2_template: ["good", "совпадает с шаблоном", ["Шаблон: /etc/hysteria/config.yaml. Пользователи auth.userpass не сравниваются: на узлах они свои"]],
    awg_params: ["none", "AmneziaWG на узле не установлен"],
    awg_same: ["none", "AmneziaWG на узле не установлен"],
    tcp_web: ["good", "отвечает 80/tcp masquerade Hysteria2 (ответ 301), 443/tcp masquerade Hysteria2 (ответ 200)"],
    tls_cert: ["warn", "443/tcp: самоподписанный на чужое имя bing.com", ["На 443/tcp отвечает masquerade Hysteria2 со своим сертификатом"],
      "Сертификат на имя чужого сайта снаружи выглядит подделкой. Варианты: свой домен и блок acme в конфиге Hysteria2 (сертификат выдаст Let's Encrypt, в ссылках клиентов пропадёт insecure) или Salamander, под которым рукопожатие снаружи не видно."],
    icmp: ["good", "отвечает"],
    names: ["good", "имя сервера: srv-12, PTR: нет"],
    banners: ["good", "лишних портов нет"],
    panel: ["good", "панели на узле нет"],
    asn: ["good", "AS64500, Example Hosting B.V. (NL)", [`Адрес ${addr}, данные whois регионального реестра`]],
    registry: ["good", `адреса ${addr} в выгрузке нет`, [`В выгрузке записей: 412560, скачана ${listDay}`]],
    journald: ["good", "хранится не дольше 7day", ["Журнал занимает 48.0M"]],
    hy2_log: ["warn", "уровень info: в журнал пишется адрес каждого клиента", [],
      "С уровнем warn в журнале остаются предупреждения и ошибки. Служба перезапустится, клиенты переподключатся сами. На узле от root:",
      `mkdir -p /etc/systemd/system/hysteria-server.service.d && printf '[Service]\\nEnvironment=HYSTERIA_LOG_LEVEL=warn\\n' > /etc/systemd/system/hysteria-server.service.d/iof-log.conf && systemctl daemon-reload && ${restart}`],
    awg_log: ["none", "AmneziaWG на узле не установлен"],
    time: ["good", "синхронизировано"],
  };
  const all = { ...base, ...over(restart) };
  return Object.entries(all).map(([id, [status, value, detail = [], hint = "", cmd = "", act = []]]) => ({ id, status, value, detail, hint, cmd, act }));
}

// Что меняют действия в демо. hop — диапазон в listen (rules: правила стоят), ver — версия Hysteria2,
// block — блок-лист на узле. Остальное как у узла в demoDpiNodes
const demoAct = {
  hop: { "node-2": { range: "10000-19999", rules: true }, "node-3": { range: "10000-19999", rules: false } },
  ver: { "node-1": "2.11.0" },
  block: {
    "node-2": { entries: 1840, at: new Date().setHours(5, 30, 0, 0) / 1000 },
    "node-3": { entries: 1795, at: Date.now() / 1000 - 12 * 86400 },
  },
};

function demoVerGe(v, min) {
  const a = v.split(".").map(Number), b = min.split(".").map(Number);
  for (let i = 0; i < 3; i++) if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) > (b[i] || 0);
  return true;
}

// Проверка «Смена портов» узла name с основным портом port, тексты как у iof audit
function demoHopCheck(name, port) {
  const h = demoAct.hop[name], ver = demoAct.ver[name] || "2.13.0";
  const groups = `Групп ссылок со списком портов: ${demoState.groups.filter((g) => g.hop).length} из ${demoState.groups.length} (sudo iof hy2 add "Подпись" --hop)`;
  if (h) {
    const d = [groups, `Если у хостера свой файрвол в панели, в нём должен быть открыт UDP ${h.range}`];
    if (h.rules) return ["good", `диапазон ${h.range} на порт ${port}, правила ставит сама Hysteria2`, d, "", "", ["hop_off"]];
    return ["warn", `диапазон ${h.range} в конфиге, а правил перенаправления нет`, d,
      "Клиенты со списком портов в ссылке попадают на закрытые порты. Служба не перезапущена после правки конфига, Hysteria2 старше 2.12.3 или у службы нет прав на правила (CAP_NET_ADMIN в юните). Включить заново с проверкой и откатом при неудаче — на управляющем сервере:",
      `sudo iof hy2 hop on ${name} --ports ${h.range}`, ["hop_on", "hop_off"]];
  }
  if (!demoVerGe(ver, "2.12.3")) {
    return ["warn", `нет: клиенты всегда ходят на порт ${port}`, [`Hysteria2 на узле: ${ver}`],
      "Смене портов нужна Hysteria2 от 2.12.3: в старых версиях её правила заворачивали и исходящий UDP самого узла. Сначала обнови её (бинарник и юнит сохраняются на узле и возвращаются, если служба не поднимется), потом включи. На управляющем сервере:",
      `sudo iof hy2 upgrade ${name}\nsudo iof hy2 hop on ${name}`, ["hy2_upgrade"]];
  }
  return ["warn", `нет: клиенты всегда ходят на порт ${port}`, [],
    `Включить: в listen добавится диапазон 10000-19999 (HY2_HOP в /root/iof/iof.env), основной порт ${port} останется, выданные ссылки продолжат работать как раньше. Список портов в ссылках получат только группы с --hop: такие ссылки импортируют Hiddify с 5.5.5 и официальный клиент, v2rayN и Hiddify старше — нет. На управляющем сервере:`,
    `sudo iof hy2 hop on ${name}\nsudo iof hy2 add "Подпись" --hop`, ["hop_on"]];
}

// Проверка «Блок-лист сканеров» узла name
function demoBlockCheck(name) {
  const b = demoAct.block[name];
  const list = `В исходном списке строк с адресами: 1840, скачан ${fmtWhen(new Date().setHours(5, 30, 0, 0) / 1000)}`;
  const cron = "Обновлять раз в сутки: на управляющем сервере sudo crontab -e, строка 15 5 * * * /usr/local/bin/iof block update >/dev/null 2>&1";
  if (!b) {
    return ["warn", "на узле не применён", [list],
      `Применить: пакеты с адресов из списка узел будет отбрасывать раньше NAT, ufw и Docker, в том числе на портах контейнеров и ретранслятора. Узлы из nodes.conf, этот сервер, BLOCK_ALLOW и текущие сессии SSH на узле не блокируются, записи шире /16 и IPv6 пропускаются. ${cron}. На управляющем сервере:`,
      `sudo iof block on ${name}`, ["block_on"]];
  }
  const val = `применён: записей ${b.entries}, список скачан ${fmtWhen(b.at)}`;
  const d = [list, "Не блокируются: узлы из nodes.conf, этот сервер, BLOCK_ALLOW, сессии SSH на узле во время применения"];
  if (Date.now() / 1000 - b.at > 7 * 86400) {
    return ["warn", val, d, `Список на узле старше недели, а адреса сканеров меняются. Обновить сейчас: на управляющем сервере sudo iof block update ${name}. ${cron}`,
      `sudo iof block update ${name}`, ["block_update", "block_off"]];
  }
  return ["good", val, d, "", "", ["block_update", "block_off"]];
}

function demoDpiNodes() {
  const awgFix = "Параметры должны совпадать на сервере и у всех клиентов, поэтому вручную их не правят. Переустанови AmneziaWG на сервере из приложения Amnezia (оно подберёт значения в границах) и выдай ключи заново. На управляющем сервере:";
  const sameFix = "Так бывает, если серверы ставили копированием настроек. Свои параметры узел получит, если переустановить на нём AmneziaWG из приложения Amnezia. После этого на управляющем сервере:";
  const logFix = (c) => ["Ограничение задаётся при создании контейнера, приложение Amnezia его не ставит. Для новых контейнеров его можно задать в /etc/docker/daemon.json (log-opts max-size), а текущий лог обрезать командой ниже. На узле от root:",
    `truncate -s 0 "$(docker inspect -f '{{.LogPath}}' ${c})"`];
  const jdFix = ["Ограничь срок, например неделей: старые записи journald удалит сам. Совсем короткий журнал мешает разбираться в сбоях, неделя — середина. На узле от root:",
    "mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\\nMaxRetentionSec=7day\\n' > /etc/systemd/journald.conf.d/iof.conf && systemctl restart systemd-journald"];
  const local = "Проверено с самого управляющего сервера, а не снаружи: файрвол на пути не участвует";
  const awg = ["Контейнер amnezia-awg2, интерфейс awg0", "Пакеты-подписи I1–I5: заданы I1"];
  const checks = {
    main: demoDpiChecks("192.0.2.10", () => ({
      hy2_quic: ["good", "порт 443/udp отвечает как сервер QUIC (согласование версий)", [local]],
      awg_params: ["good", "заданы и в допустимых границах", awg],
      awg_same: ["warn", "такие же параметры на: node-2", [], sameFix, "sudo iof awg refresh"],
      tcp_web: ["good", "отвечает 80/tcp masquerade Hysteria2 (ответ 301), 443/tcp masquerade Hysteria2 (ответ 200)", [local]],
      icmp: ["good", "отвечает", [local]],
      panel: ["good", "слушает только 127.0.0.1:8088"],
      awg_log: ["warn", "json-file без ограничения размера, сейчас 212 МБ", [], ...logFix("amnezia-awg2")],
    })),
    "node-1": demoDpiChecks("198.51.100.20", (restart) => ({
      hy2_mode: ["warn", "ни Salamander, ни masquerade: на запрос по HTTP/3 сервер отвечает 404", [],
        "Выбери одно. Masquerade: сервер показывает зонду чужой сайт, ссылки клиентов не меняются (команда ниже, адрес сайта замени на тот, что открывается с узла). Salamander: блок obfs в конфиге и новые ссылки клиентам. Чтобы новые узлы ставились так же, внеси блок и в шаблон на управляющем сервере. На узле от root:",
        `printf '\\nmasquerade:\\n  type: proxy\\n  proxy:\\n    url: https://example.org/\\n    rewriteHost: true\\n' >> /etc/hysteria/config.yaml\n${restart}`],
      hy2_masq: ["warn", "не настроен: на запрос по HTTP/3 сервер отвечает 404", [], "Как добавить, написано в проверке «Режим маскировки»."],
      hy2_quic: ["warn", "порт 8443/udp на зонд QUIC не ответил", [],
        "UDP от управляющего сервера до узла не дошёл: порт закрыт файрволом узла или хостера, либо QUIC режется по пути. Клиенты могут видеть то же самое. На узле от root:",
        "systemctl is-active hysteria-server\nss -uln | grep ':8443 '\nufw status | grep -w 8443"],
      hy2_port: ["warn", "8443/udp, а HTTP/3 обычно на 443", [],
        "QUIC на нестандартном порту заметнее. Зато 443/udp фильтруют чаще: если так задумано, оставь. Сменить порт: команда на узле, затем на управляющем сервере sudo iof hy2 refresh (ссылки клиентов изменятся). На узле от root:",
        `sed -i -E 's/^listen:.*/listen: :443/' /etc/hysteria/config.yaml && ${restart}`],
      hy2_template: ["warn", "отличается от шаблона, блоки: listen, masquerade (на узле нет)", ["Шаблон: /etc/hysteria/config.yaml"],
        "Если правки на узле нужны, внеси их и в шаблон. Вернуть узлу конфиг по шаблону — команда ниже. При auth userpass пользователи узла создадутся заново с новыми паролями: ссылки на этот узел изменятся, раздай их снова (sudo iof hy2 show). На управляющем сервере:",
        "sudo iof hy2 install node-1 --force"],
      awg_params: ["crit", "как у обычного WireGuard: параметры обфускации не заданы", ["Контейнер amnezia-awg, интерфейс wg0"],
        "Такой трафик фильтры узнают по первому пакету. Параметры задаёт приложение Amnezia при установке: поставь на сервер из приложения протокол AmneziaWG вместо WireGuard и выдай ключи заново. На управляющем сервере:",
        "sudo iof awg refresh"],
      awg_same: ["none", "параметров обфускации в конфиге нет, сравнивать нечего"],
      tcp_web: ["none", "отвечает 80/tcp nginx/1.24.0 (Ubuntu) (ответ 301), 443/tcp nginx/1.24.0 (Ubuntu) (ответ 200)",
        ["Это не Hysteria2: что увидит зонд, зависит от этой службы. Оценки здесь нет, смотри проверку «Сертификат»"]],
      tls_cert: ["good", "443/tcp: выдан Let's Encrypt на shop.example.net"],
      icmp: ["none", "не отвечает: ICMP закрыт на узле, у хостера или режется по пути"],
      names: ["warn", "имя сервера: vpn-nl-1, PTR: vpn-nl-1.example.net", ["В имени сервера есть «vpn»", "В PTR есть «vpn»"],
        "PTR (reverse DNS) меняется в панели хостера. Имя сервера меняется командой ниже. На узле от root:", "hostnamectl set-hostname srv-node-1"],
      banners: ["warn", "снаружи открыты: 3306/tcp (5.7.44-log MySQL), 8080/tcp (HTTP, Server: SimpleHTTP/0.6 Python/3.12.3)", [],
        "Останови службу или закрой порт файрволом: что это за порты, показывает проверка «Слушающие порты» в аудите сервера. На узле от root:",
        "ss -tulnp | grep -E ':(3306|8080) '\nsystemctl disable --now <служба>"],
      journald: ["warn", `срок не ограничен: самая старая запись от ${fmtWhen(Date.now() / 1000 - 74 * 86400)} (74 дн.)`, ["Журнал занимает 1.2G"], ...jdFix],
      hy2_log: ["warn", "уровень debug: в журнал пишется адрес каждого клиента и адреса, куда он ходит", [],
        "С уровнем warn в журнале остаются предупреждения и ошибки. Служба перезапустится, клиенты переподключатся сами. На узле от root:",
        `mkdir -p /etc/systemd/system/hysteria-server.service.d && printf '[Service]\\nEnvironment=HYSTERIA_LOG_LEVEL=warn\\n' > /etc/systemd/system/hysteria-server.service.d/iof-log.conf && systemctl daemon-reload && ${restart}`],
      awg_log: ["warn", "json-file без ограничения размера, сейчас 38 МБ", [], ...logFix("amnezia-awg")],
    })),
    "node-2": demoDpiChecks("203.0.113.30", () => ({
      hy2_mode: ["good", "Salamander: трафик похож на случайный шум",
        ["Другой вариант — без Salamander с masquerade: сервер выглядит как сайт с HTTP/3. Это иной компромисс, а не улучшение"]],
      hy2_masq: ["none", "под Salamander masquerade снаружи не виден"],
      hy2_quic: ["good", "порт 443/udp на зонд QUIC не отвечает: так и выглядит Salamander", ["Доходит ли до узла UDP, под Salamander этот зонд не показывает"]],
      hy2_port: ["none", "443/udp: под Salamander трафик не похож на QUIC на любом порту"],
      hy2_template: ["warn", "отличается от шаблона, блоки: masquerade (на узле нет), obfs (в шаблоне нет)", ["Шаблон: /etc/hysteria/config.yaml"],
        "Если правки на узле нужны, внеси их и в шаблон. Вернуть узлу конфиг по шаблону — команда ниже. При auth userpass пользователи узла создадутся заново с новыми паролями: ссылки на этот узел изменятся, раздай их снова (sudo iof hy2 show). На управляющем сервере:",
        "sudo iof hy2 install node-2 --force"],
      awg_params: ["warn", "вне допустимых границ: Jc, S1 и S2", [...awg, "Jc: нужно от 1 до 128, иначе мусорные пакеты перед рукопожатием не идут",
        "S1 + 56 = S2: пакеты начала и ответа рукопожатия выходят одной длины"], awgFix, "sudo iof awg refresh"],
      awg_same: ["warn", "такие же параметры на: main", [], sameFix, "sudo iof awg refresh"],
      tcp_web: ["good", "закрыты: 80/tcp закрыт, 443/tcp не отвечает"],
      tls_cert: ["none", "снаружи не виден: 443/tcp закрыт, рукопожатие QUIC скрыто под Salamander"],
      asn: ["none", "не определён", ["Реестр не отдал номер AS для 203.0.113.30. Сеть: Example Cloud LLC (US)"]],
      registry: ["crit", "адрес 203.0.113.30 есть в выгрузке (запись 203.0.113.0/27)", [`В выгрузке записей: 412560, скачана ${fmtWhen(new Date().setHours(5, 30, 0, 0) / 1000)}`],
        "У провайдеров, которые блокируют по реестру, узел недоступен. Помогает только другой адрес: новый IP у хостера или новый сервер (страница «Добавить сервер»). Старый узел убирается так, на управляющем сервере:",
        "sudo iof node del node-2\nsudo iof refresh"],
      hy2_log: ["good", "уровень warn: адреса клиентов в журнал не пишутся"],
      awg_log: ["good", "ограничен: max-size 10m, сейчас 3.2 МБ"],
      time: ["warn", "не синхронизировано, служба времени выключена", ["С управляющим сервером часы сейчас сходятся"],
        "Без синхронизации часы со временем уходят. В контейнере без своих часов это предупреждение можно оставить. На узле от root:",
        "timedatectl set-ntp true && sleep 5 && timedatectl show -p NTPSynchronized"],
    })),
    "node-3": demoDpiChecks("203.0.113.41", () => ({
      hy2_masq: ["warn", "proxy на https://old-site.example/, цель с узла не отвечает (код нет ответа)", [],
        "Зонд вместо сайта получит ошибку. Проверь адрес в masquerade.proxy.url или выбери другой сайт. На узле от root:",
        "curl -sI -m 8 'https://old-site.example/' | head -n 1"],
      hy2_template: ["warn", "отличается от шаблона, блоки: masquerade", ["Шаблон: /etc/hysteria/config.yaml"],
        "Если правки на узле нужны, внеси их и в шаблон. Вернуть узлу конфиг по шаблону — команда ниже. При auth userpass пользователи узла создадутся заново с новыми паролями: ссылки на этот узел изменятся, раздай их снова (sudo iof hy2 show). На управляющем сервере:",
        "sudo iof hy2 install node-3 --force"],
      tcp_web: ["warn", "закрыты, а на 443/udp сервер изображает сайт с HTTP/3", [],
        "Настоящий сайт с HTTP/3 отвечает и по TCP. В Hysteria2 для этого есть masquerade.listenHTTPS и listenHTTP: команда добавляет их в блок masquerade. Если включён файрвол, открой 80/tcp и 443/tcp. На узле от root:",
        "sed -i '/^masquerade:/a\\  listenHTTP: :80\\n  listenHTTPS: :443\\n  forceHTTPS: true' /etc/hysteria/config.yaml && systemctl restart hysteria-server"],
      tls_cert: ["warn", "Hysteria2: самоподписанный на чужое имя bing.com", ["Сертификат Hysteria2 виден при рукопожатии QUIC на 443/udp"],
        "Сертификат на имя чужого сайта снаружи выглядит подделкой. Варианты: свой домен и блок acme в конфиге Hysteria2 (сертификат выдаст Let's Encrypt, в ссылках клиентов пропадёт insecure) или Salamander, под которым рукопожатие снаружи не видно."],
      names: ["good", "имя сервера: srv-41, PTR: static.41.113.0.203.example-host.net"],
    })),
    "node-4": demoDpiChecks("203.0.113.42", () => ({
      awg_params: ["none", "контейнер amnezia-awg2 остановлен"],
      awg_same: ["none", "контейнер amnezia-awg2 остановлен"],
      icmp: ["none", "не отвечает: ICMP закрыт на узле, у хостера или режется по пути"],
      journald: ["warn", `срок не ограничен: самая старая запись от ${fmtWhen(Date.now() / 1000 - 31 * 86400)} (31 дн.)`, ["Журнал занимает 412.0M"], ...jdFix],
      awg_log: ["good", "драйвер local: размер ограничен, старое удаляется само, сейчас 1.4 МБ"],
    })),
  };
  // Смена портов и блок-лист зависят от действий в демо. Порядок проверок в списке не важен:
  // страница берёт их по справочнику
  const ports = { "node-1": 8443 };
  for (const [name, list] of Object.entries(checks)) {
    for (const [id, [status, value, detail, hint, cmd, act]] of [["hy2_hop", demoHopCheck(name, ports[name] || 443)], ["blocklist", demoBlockCheck(name)]]) {
      list.push({ id, status, value, detail, hint, cmd, act });
    }
  }
  return demoBlockNodes(checks, demoAuditState.at.dpi);
}

// Действие из проверки в демо: задача как у iof, затем узел «проверяется заново»
function demoActionJob(body) {
  const n = body.node, now = Math.floor(Date.now() / 1000);
  const titles = { hop_on: "Смена портов Hysteria2: включение", hop_off: "Смена портов Hysteria2: выключение",
    hy2_upgrade: "Обновление Hysteria2", block_on: "Блок-лист сканеров: применение",
    block_update: "Блок-лист сканеров: обновление", block_off: "Блок-лист сканеров: снятие" };
  const range = (demoAct.hop[n] || {}).range || "10000-19999", port = n === "node-1" ? 8443 : 443;
  const hopGroups = demoState.groups.filter((g) => g.hop).map((g) => `Пересобираю группу со сменой портов в ссылках: ${g.label}`);
  const audit = [`$ iof -n ${n} audit run dpi`, "Проверяю узлы: 1, одновременно до 20", `== ${n}: проверен`];
  const list = ["Список: записей 1840, скачан " + fmtWhen(new Date().setHours(5, 30, 0, 0) / 1000), "  пропущено: IPv6 12, шире /16 1, частных и служебных 3, нечитаемых 0"];
  const steps = {
    hop_on: [`$ iof hy2 hop on ${n}`, `Включаю смену портов ${range} на узлах: 1`, "", `Включено  ${n}: порты ${range} -> ${port}`, "", ...hopGroups,
      "", `Если у хостера свой файрвол в панели, открой там UDP ${range}. Файрвол самого узла трогать не нужно:`,
      "Hysteria2 перенаправляет диапазон на основной порт раньше, чем пакет до него дойдёт.", ...audit],
    hop_off: [`$ iof hy2 hop off ${n}`, "Выключаю смену портов на узлах: 1", "", `Выключено ${n}: остался порт ${port}`, "", ...hopGroups,
      ...(hopGroups.length ? ["Клиентам этих групп нужны новые ссылки: в старых диапазон, а его порты на этих узлах закрыты."] : []), ...audit],
    hy2_upgrade: [`$ iof hy2 upgrade ${n}`, "Обновляю Hysteria2 на узлах: 1, одновременно до 20", "", "Обновлено: 1",
      `  ${n}: ${demoAct.ver[n] || "2.13.0"} -> 2.13.0`, ...audit],
    block_on: [`$ iof block on ${n}`, ...list, "Применяю на узлах: 1", "", `  ${n}: записей 1840, не блокируются 9`, ...audit],
    block_update: [`$ iof block update ${n}`, ...list, "Обновляю на узлах, где список включён: 1 проверю", "", `  ${n}: записей 1840, не блокируются 9`, ...audit],
    block_off: [`$ iof block off ${n}`, "Снимаю на узлах: 1", "", `  ${n}: снят`, ...audit],
  };
  if (n === "node-5") {
    return demoRunJob("audit", `${titles[body.action]}, ${n}`, [steps[body.action][0], "Ошибки (1):", `  ${n}               нет связи по SSH`,
      "Команда завершилась с кодом 1"], "error");
  }
  return demoRunJob("audit", `${titles[body.action]}, ${n}`, steps[body.action], "ok", () => {
    if (body.action === "hop_on") demoAct.hop[n] = { range, rules: true };
    if (body.action === "hop_off") delete demoAct.hop[n];
    if (body.action === "hy2_upgrade") demoAct.ver[n] = "2.13.0";
    if (body.action === "block_on" || body.action === "block_update") demoAct.block[n] = { entries: 1840, at: new Date().setHours(5, 30, 0, 0) / 1000 };
    if (body.action === "block_off") delete demoAct.block[n];
    demoAuditState.at.dpi = now;
    demoAuditState.runs.push({ at: now, block: "dpi", nodes: 1 });
  });
}

function demoAudit() {
  const blocks = { server: { nodes: demoAuditNodes() }, dpi: { nodes: demoDpiNodes() } };
  const count = (list) => {
    const counts = { none: 0, good: 0, warn: 0, crit: 0 };
    list.forEach((b) => Object.values(blocks[b].nodes).forEach((n) => n.checks.forEach((c) => { counts[c.status]++; })));
    return counts;
  };
  const now = Math.floor(Date.now() / 1000) - 5 * 3600;
  const history = demoAuditState.runs.map((r, i) => ({
    at: r.at || now - r.ago, block: r.block, nodes: r.nodes || demoNodes().length,
    counts: count(r.block === "all" ? BLOCKS : [r.block]), down: r.nodes === 1 ? [] : ["node-5"],
    worse: i === 0 ? [{ node: "node-2", id: "reboot", from: "good", to: "warn" }, { node: "node-3", id: "hy2_masq", from: "good", to: "warn" }] : [],
  }));
  const catalog = (block, list) => list.map(([id, group, title, why]) => ({ id, block, group, title, why }));
  return demoDelay({
    blocks,
    titles: { server: "Аудит сервера", dpi: "Защита от РКН (ТСПУ)" },
    groups: [...DEMO_AUDIT_GROUPS.map(([id, title]) => ({ block: "server", id, title })),
      ...DEMO_DPI_GROUPS.map(([id, title]) => ({ block: "dpi", id, title }))],
    catalog: [...catalog("server", DEMO_AUDIT_CATALOG), ...catalog("dpi", DEMO_DPI_CATALOG)],
    nodes: demoNodes().map(({ name, addr, title }) => ({ name, addr, title })),
    history,
    settings: { cron: "30 5 * * * /usr/local/bin/iof audit cron >/dev/null 2>&1", tg: true, hop: "10000-19999",
      block_cron: "15 5 * * * /usr/local/bin/iof block update >/dev/null 2>&1", blocklist: true },
    probe: demoProbeData(),
    probe_state: demoProbeState(),
    error: null,
    busy: false,
    migrate: null,
  });
}

function demoAuditJob(body) {
  const names = demoNodes().map((n) => n.name).filter((n) => !body.node || n === body.node);
  const down = names.includes("node-5");
  const lines = [`$ iof ${body.node ? `-n ${body.node} ` : ""}audit run ${body.block}`, `Проверяю узлы: ${names.length}, одновременно до 20`,
    ...names.filter((n) => n !== "node-5").map((n) => `== ${n}: проверен`)];
  if (down) lines.push("Ошибки (1):", "  node-5               нет связи по SSH");
  lines.push("Подробно и как исправить: sudo iof audit show [узел], в панели — страница «Безопасность»");
  const title = body.block === "dpi" ? "Защита от РКН" : "Аудит сервера";
  return demoRunJob("audit", `${title}: ${body.node || "все узлы"}`, lines, down ? "warn" : "ok", () => {
    demoAuditState.at[body.block] = Math.floor(Date.now() / 1000);
    demoAuditState.runs.push({ at: demoAuditState.at[body.block], block: body.block, nodes: names.length });
  });
}


// Демо проверки с ПК. ?demo — результат со всеми вердиктами, ?demo=wait — мишени ждут отчёт,
// ?demo=vpn — проверка шла через VPN (уверенность низкая), ?demo=open — провайдер ничего не фильтрует
// (сайты из чёрного списка открываются, уверенность средняя). Тексты как у iof audit probe

const DEMO_PROBE = new URLSearchParams(location.search).get("demo") || "";
const demoProbe = {
  stage: DEMO_PROBE === "wait" ? "wait" : "idle",
  started: Math.floor(Date.now() / 1000) - 140,
  script_at: null,
  result_at: null,
  extra: [],
};

const DEMO_LAYER_TITLES = { icmp: "Ping", tcp: "TCP", tls: "TLS", data: "Данные 256 КБ", udp: "UDP",
  quic: "UDP, похожий на QUIC", hy2: "Порт Hysteria2", tunnel: "Туннель Hysteria2" };
const DEMO_LAYERS = {
  icmp: ["ok", "3 из 3, 41 мс", "3 из 3, 2 мс"],
  tcp: ["ok", "3 из 3, 44 мс", "3 из 3, 1 мс"],
  tls: ["ok", "3 из 3, 92 мс", "3 из 3, 3 мс"],
  data: ["ok", "3 из 3, 1240 мс", "3 из 3"],
  udp: ["ok", "5 из 5", "5 из 5"],
  quic: ["ok", "5 из 5", "5 из 5"],
  hy2: ["ok", "отвечает как QUIC", "отвечает как QUIC"],
  tunnel: ["ok", "работает, 1630 мс", "—"],
};

// Как layer_status в iof: crit только при высокой уверенности, ping — только справка
function demoLayerStatus(id, v, conf) {
  if (conf === "low" || ["down", "unknown", "skipped"].includes(v)) return "none";
  if (v === "ok") return "good";
  if (id === "icmp") return "none";
  return ["blocked", "stall"].includes(v) && conf === "high" ? "crit" : "warn";
}

function demoProbeNode(addr, conf, over, extra) {
  const layers = Object.keys(DEMO_LAYERS).map((id) => {
    const [verdict, pc, control, note = ""] = over[id] || DEMO_LAYERS[id];
    return { id, title: DEMO_LAYER_TITLES[id], verdict, status: demoLayerStatus(id, verdict, conf), pc, control, note };
  });
  const status = layers.reduce((a, x) => (RANK[x.status] > RANK[a] ? x.status : a), "none");
  return { addr, status, confidence: conf, value: extra.value || "с ПК проходят все проверенные слои",
    detail: extra.detail || [], hint: ["warn", "crit"].includes(status) ? extra.hint || "" : "", cmd: "", layers };
}

function demoProbeResult(kind, at, session) {
  const conf = kind === "vpn" ? "low" : kind === "open" ? "medium" : "high";
  const local = "Контроль шёл с самого управляющего сервера: это не взгляд снаружи";
  const tspu = "Похоже на ограничение ТСПУ: соединения с зарубежными хостингами встают после 15–20 КБ";
  const stall = {
    data: ["stall", "0 из 3; встаёт на 16 КБ (3 из 3)", "3 из 3", tspu],
    hy2: ["down", "молчит", "молчит", "Управляющему серверу порт тоже не ответил согласованием версий. Так выглядит Salamander: тогда Hysteria2 проверяет только туннель"],
  };
  const stallText = { value: "данные встают на 16 КБ", detail: [tspu],
    hint: "TLS-соединение с адресом встаёт после первых килобайт: так ТСПУ ограничивает соединения с зарубежными хостингами. Hysteria2 и AmneziaWG работают по UDP, их это не задевает: смотри строки UDP и Hysteria2." };
  const none = (addr, value, cmd = "") => ({ addr, status: "none", confidence: conf, value, detail: [], hint: "", cmd, layers: [] });
  const nodes = {
    main: demoProbeNode("192.0.2.10", conf, {}, { detail: [local] }),
    "node-1": demoProbeNode("198.51.100.20", conf, kind !== "full" ? {} : {
      icmp: ["blocked", "0 из 3", "3 из 3, 38 мс", "ICMP по дороге режут часто, на VPN это не влияет"],
      tcp: ["blocked", "0 из 3 (tcp: timeout)", "3 из 3, 36 мс"],
      tls: ["skipped", "не дошло до TLS", "3 из 3, 74 мс"],
      data: ["skipped", "не дошло до данных", "3 из 3"],
      udp: ["blocked", "0 из 5", "5 из 5"],
      quic: ["blocked", "0 из 5", "5 из 5"],
      hy2: ["blocked", "молчит", "отвечает как QUIC"],
      tunnel: ["fail", "не поднялся: client: timeout: no recent network activity", "—"],
    }, kind !== "full" ? {} : {
      value: "с ПК не проходят: TCP, UDP, UDP, похожий на QUIC, Порт Hysteria2; туннель Hysteria2 не поднялся",
      hint: "Клиент Hysteria2 на ПК не поднял туннель по ссылке группы: проверь, что ссылка свежая (sudo iof hy2 show) и hysteria.exe новой версии. С ПК не доходит ничего: похоже, адрес узла заблокирован целиком. Проверь из другой сети (мобильный интернет): если так везде, помогает только новый адрес у хостера или другой узел.",
    }),
    "node-2": demoProbeNode("203.0.113.30", conf, kind === "vpn" ? {} : stall, kind === "vpn" ? {} : stallText),
    "node-3": demoProbeNode("203.0.113.41", conf, kind !== "full" ? {} : {
      udp: ["partial", "3 из 5", "5 из 5"],
      tunnel: ["skipped", "не проверялся: в буфере обмена нет ссылки на этот узел", "—"],
    }, kind !== "full" ? {} : { value: "с ПК проходят не все попытки: UDP",
      hint: "Часть пакетов UDP теряется по дороге. Повтори проверку: если потери держатся, клиентам Hysteria2 на этом узле будет хуже, чем на остальных." }),
    "node-4": none("203.0.113.42", "не проверялся: нет python3, он нужен мишени", "apt install python3"),
    "node-5": none("203.0.113.43", "не проверялся: узел не ответил по SSH"),
  };
  const nets = {
    full: { label: "AS12389 PJSC Rostelecom (RU)", ip: "95.24.17.0/24", vpn: "no", remap: false },
    open: { label: "AS8359 MTS PJSC (RU)", ip: "37.110.4.0/24", vpn: "no", remap: false },
    vpn: { label: "AS64500 Example Cloud LLC (US)", ip: "203.0.113.0/24", vpn: "yes", remap: false },
  };
  const black = "Сайты из probe-black.txt открываются: провайдер их не блокирует или трафик идёт в обход (VPN, прокси)";
  const reasons = {
    full: [],
    open: [black],
    vpn: ["IP источника — адрес узла node-2: проверка шла через VPN на этот узел. Выключи VPN на ПК и повтори",
      "По whois сеть ПК не российская (US): провайдер другой страны или VPN",
      "На ПК включён адаптер WireGuard Tunnel: если это VPN в режиме TUN, трафик шёл через него", black],
  };
  const counts = { none: 0, good: 0, warn: 0, crit: 0 };
  Object.values(nodes).forEach((n) => { counts[n.status]++; });
  return { at, session, started: at - 120, confidence: conf, reasons: reasons[kind], net: nets[kind],
    internet: "ok", filtering: kind === "full" ? "yes" : "no", client: { os: "Windows 10.0.26100", proxy: "none" },
    lists: [], nodes, counts };
}

function demoProbeData() {
  const now = Math.floor(Date.now() / 1000);
  const last = DEMO_PROBE === "vpn" ? "vpn" : DEMO_PROBE === "open" ? "open" : "full";
  const results = [demoProbeResult("full", now - 6 * 86400, "a07c33d1"), demoProbeResult("open", now - 2 * 86400, "b18e2f40"),
    demoProbeResult(last, now - 3 * 3600, "c29f4a51"), ...demoProbe.extra];
  return {
    session: null,
    last: results[results.length - 1],
    history: results.map((r) => ({ at: r.at, session: r.session, confidence: r.confidence, net: r.net.label, counts: r.counts })),
  };
}

function demoProbeTargets() {
  const check = (hy2) => `ping 3/3 · TCP 3/3 · TLS 3/3 · данные 3/3 · UDP 5/5 · QUIC 5/5 · Hysteria2 ${hy2 || "отвечает как QUIC"}`;
  const t = (addr, port, fw, hy2) => ({ addr, state: "started", port, fw, error: "", local: false, check: check(hy2) });
  return {
    main: { ...t("192.0.2.10", 41873, "open"), local: true },
    "node-1": t("198.51.100.20", 52210, "opened"),
    "node-2": t("203.0.113.30", 33417, "open", "молчит"),
    "node-3": t("203.0.113.41", 47702, "opened"),
    "node-4": { addr: "203.0.113.42", state: "nopython", port: 0, fw: "", error: "", local: false, check: "" },
    "node-5": { addr: "203.0.113.43", state: "down", port: 0, fw: "", error: "нет связи по SSH", local: false, check: "" },
  };
}

function demoProbeState() {
  const s = demoProbe, now = Date.now() / 1000;
  if (s.stage === "idle") return { session: null, now, panel: null };
  const panel = { mine: s.stage !== "starting", origin: location.origin, start_job: null, job: null,
    ticket: s.script_at ? null : "demo-Rz3kq0sX9tLmN2pW7yVbC4fHq8Jd", script_at: s.script_at, result_at: s.result_at, pending: false };
  if (s.stage === "starting") return { session: null, now, panel };
  return { session: { id: "d3a0b5e6", started: s.started, expires: s.started + 900, stopped: 0, nodes: demoProbeTargets() }, now, panel };
}

// «Скрипт скачан»: через несколько секунд как будто приходит отчёт, ещё через несколько — результат
function demoProbeScript() {
  if (demoProbe.script_at) return;
  demoProbe.script_at = Date.now() / 1000;
  toast("Демо: скрипт не скачивается, отчёт придёт сам");
  setTimeout(() => {
    demoProbe.stage = "import";
    demoProbe.result_at = Date.now() / 1000;
    setTimeout(() => {
      demoProbe.extra.push(demoProbeResult("full", Math.floor(Date.now() / 1000), "d3a0b5e6"));
      demoProbe.stage = "idle";
      demoProbe.script_at = demoProbe.result_at = null;
    }, 4000);
  }, 5000);
}

function demoProbeJob(body) {
  if (body.action === "cancel") {
    return demoRunJob("probe", "Проверка с ПК: остановка мишеней", ["$ iof audit probe stop",
      "Останавливаю мишени проверки d3a0b5e6 на узлах: 6", "  main                 остановлено мишеней: 1",
      "  node-1               остановлено мишеней: 1", "  node-4               мишеней не было"], "ok", () => {
      demoProbe.stage = "idle";
      demoProbe.script_at = null;
    });
  }
  demoProbe.stage = "starting";
  const n = body.nodes.length ? ` -n ${body.nodes[0]}` : "";
  return demoRunJob("probe", "Проверка с ПК: запуск мишеней", [`$ iof${n} audit probe start`,
    "Проверка с ПК d3a0b5e6: запускаю мишени на узлах (6) на 15 мин и проверяю их отсюда",
    "  main                 порт 41873  контроль: ping 3/3 · TCP 3/3 · TLS 3/3 · данные 3/3 · UDP 5/5 · QUIC 5/5",
    "  node-4               не проверяется: нет python3, он нужен мишени. Исправить на узле: apt install python3",
    "Ошибки (1):", "  node-5               нет связи по SSH",
    "Мишени работают до 15:12. Дальше страница «Безопасность» панели,"], "warn", () => {
    demoProbe.stage = "wait";
    demoProbe.started = Math.floor(Date.now() / 1000);
  });
}
