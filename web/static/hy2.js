"use strict";

// Страница «Hysteria2»: группы ссылок, ссылки с копированием и QR, состояние на узлах.
// Данные: GET api/hy2, QR: GET api/hy2/qr?g=<логин>&i=<номер|all> (см. iof-web.py),
// создание, пересборка и удаление групп: POST api/hy2 (задачи iof hy2 add | del | refresh)

// Ёмкость QR на уровне коррекции L около 2950 байт, длинную группу одним кодом не показать
const QR_MAX_BYTES = 2900;
const page = { data: null, reveal: false, running: false };

const job = watchJob({
  kind: "hy2",
  demoJobs: () => demoJobs(),
  all: false,
  render: renderJob,
  done(j) {
    // Новую группу сразу открыть: логин iof печатает в строке «Файл: …/hy2/<логин>.txt»
    const cmd = j.log[0] || "";
    const file = j.log.map((l) => /^Файл:\s+\S*\/hy2\/([^/\s]+)\.txt$/.exec(l)).filter(Boolean).pop();
    if (cmd.startsWith("$ iof hy2 add") && file) location.hash = `#g=${encodeURIComponent(file[1])}`;
    if (cmd.startsWith("$ iof hy2 del")) history.replaceState(null, "", location.pathname + location.search);
    pageApi.reload();
  },
});

function selectedName(d) {
  const m = /^#g=(.+)$/.exec(location.hash);
  const name = m ? decodeURIComponent(m[1]) : "";
  if (d.groups.some((g) => g.name === name)) return name;
  return d.groups.length ? d.groups[0].name : "";
}

// Ссылки на узлы, где Hysteria2 есть, но ссылки в группе нет, и ссылки на узлы, которых уже нет
function groupDrift(g, d) {
  if (d.status_error) return { missing: [], extra: [] };
  const have = new Set(g.links.filter((l) => !l.relay).map((l) => l.node));
  const titles = new Set(d.nodes.map((n) => n.title || n.name));
  return {
    missing: d.nodes.filter((n) => n.reachable && n.hy2.installed && !have.has(n.title || n.name)),
    extra: g.links.filter((l) => !l.relay && !titles.has(l.node)),
  };
}

// Пароль в ссылке скрыт, пока не включено «показать пароль»
function displayUrl(url) {
  return page.reveal ? url : url.replace(/^(hy2:\/\/)[^@]*@/, "$1••••••••@");
}

function qrUrl(g, i) {
  return `api/hy2/qr?g=${encodeURIComponent(g.name)}&i=${i}`;
}

function qrImage(d, g, i, alt) {
  if (DEMO) return `<div class="qr-placeholder">QR-код рисует сервер через qrencode, в демо его нет</div>`;
  if (!d.qr) return `<div class="qr-placeholder">Для QR-кодов установи qrencode:<br><code>sudo apt install qrencode</code></div>`;
  return `<img class="qr" src="${qrUrl(g, i)}" alt="${esc(alt)}" width="240" height="240">`;
}

function utf8Len(s) {
  return new TextEncoder().encode(s).length;
}

// Режим доступа на узлах: password (общий пароль), userpass или пусто, если разный или неизвестен
function authMode(d) {
  const modes = new Set(d.nodes.filter((n) => n.reachable && n.hy2.installed).map((n) => n.hy2.auth));
  return modes.size === 1 ? [...modes][0] : "";
}


// Действия с группами: задача iof, ход в карточке #job

async function run(body) {
  formError("", "#action-error");
  try {
    const id = DEMO ? demoHy2Job(body) : (await postJson("api/hy2", body)).job;
    job.start(id);
    $("#job").scrollIntoView({ behavior: "smooth", block: "nearest" });
    return true;
  } catch (e) {
    formError(e.message, "#action-error");
    return false;
  }
}

function renderJob(j) {
  const lvl = renderJobCard(j);
  page.running = !!j && j.state === "running";
  lock();
  if (!j) return;
  $("#job-hide").hidden = page.running;
  const why = failReason(j.log);
  jobResult(lvl, {
    ok: `${icon("good")}<div>Готово.</div>`,
    warn: `${icon("warn")}<div>Готово, но не на всех узлах, список в логе. Когда они будут на связи, повтори: дублей не будет.</div>`,
    error: `${icon("crit")}<div>Не получилось${why ? `: <b>${esc(why)}</b>` : ", причина в логе"}</div>`,
  }[j.state]);
}

// Кнопки с data-lock недоступны, пока идёт задача или перенос управления отсюда
function lock() {
  const m = page.data && page.data.migrate;
  const blocked = !!m && m.role === "source";
  document.querySelectorAll("[data-lock]").forEach((b) => {
    b.disabled = page.running || blocked;
    b.title = blocked ? "Идёт перенос управления, изменения здесь заблокированы" : "";
  });
}

async function createGroup(e) {
  e.preventDefault();
  const input = $("#f-label");
  const label = input.value.trim();
  const err = !label ? "введи подпись" : label.includes("|") ? "без символа |" : "";
  if (err) {
    input.setAttribute("aria-invalid", "true");
    formError(`Подпись группы: ${err}`, "#action-error");
    input.focus();
    return;
  }
  input.removeAttribute("aria-invalid");
  if (await run({ action: "add", label })) {
    input.value = "";
    toggleForm(false);
  }
}

function toggleForm(open) {
  $("#new-group").hidden = !open;
  $("#new-group-btn").setAttribute("aria-expanded", String(open));
  if (open) $("#f-label").focus();
}


// Отрисовка

function renderGroups(d, current) {
  $("#groups-count").textContent = d.groups.length || "";
  $("#groups").innerHTML = d.groups.length ? d.groups.map((g) => {
    const drift = groupDrift(g, d);
    const stale = drift.missing.length || drift.extra.length;
    return `<a class="group-item" href="#g=${encodeURIComponent(g.name)}"${g.name === current ? ' aria-current="true"' : ""}>
      <span class="item-head">
        <span class="item-title">${stale ? `<span title="группу нужно пересобрать">${icon("warn")}</span> ` : ""}${esc(g.label)}</span>
        <span class="item-meta">${fmtCreated(g.created)}</span>
      </span>
      <span class="sub-line">${g.links.length} ${plural(g.links.length, ["ссылка", "ссылки", "ссылок"])} · логин <span class="mono">${esc(g.name)}</span></span>
    </a>`;
  }).join("") : emptyList("Групп ссылок пока нет.", 'sudo iof hy2 add "Подпись"');
}

function renderGroup(d, name) {
  const el = $("#group");
  const g = d.groups.find((x) => x.name === name);
  if (!g) {
    el.innerHTML = `<div class="card-head"><h2>Группа не выбрана</h2></div>
      ${emptyList("Создай группу на сервере, и она появится здесь.", 'sudo iof hy2 add "Подпись"')}`;
    return;
  }

  const drift = groupDrift(g, d);
  const notes = [];
  if (drift.missing.length) {
    notes.push(`Нет ссылок на узлы: <b>${drift.missing.map((n) => esc(n.name)).join(", ")}</b>.`);
  }
  if (drift.extra.length) {
    notes.push(`Есть ссылки на узлы, которых нет в nodes.conf: <b>${drift.extra.map((l) => esc(l.node)).join(", ")}</b>.`);
  }
  const all = g.links.map((l) => l.url).join("\n");
  const allFits = utf8Len(all) <= QR_MAX_BYTES;

  el.innerHTML = `<div class="card-head">
      <div>
        <h2>${esc(g.label)}</h2>
        <span class="sub-line">логин <span class="mono">${esc(g.name)}</span> · создана ${fmtCreated(g.created)} · <span class="mono">${esc(g.file)}</span></span>
      </div>
      <div class="actions">
        <label class="check"><input id="reveal" type="checkbox"${page.reveal ? " checked" : ""}> показать пароль</label>
        <button id="copy-all" class="btn primary" type="button"${g.links.length ? "" : " disabled"}>Скопировать все (${g.links.length})</button>
        <button class="btn" type="button" data-hy2="rebuild" data-lock>Пересобрать</button>
        <button class="btn danger" type="button" data-hy2="del" data-lock>Удалить</button>
      </div>
    </div>
    ${notes.length ? `<div class="note warn">${icon("warn")}<div>${notes.join(" ")} Нажми «Пересобрать», чтобы ссылки в группе совпали с узлами.</div></div>` : ""}
    <div class="group-body">
      <ol class="links">
        ${g.links.map((l, i) => `<li class="link">
          <div class="link-main">
            <div class="link-title">${esc(l.node || l.title)}${l.relay ? ' <span class="tag">ретранслятор</span>' : ""}
              <span class="mono muted">${esc(l.host)}:${esc(l.port)}</span></div>
            <code class="link-url"${page.reveal ? ` title="${esc(l.url)}"` : ""}>${esc(displayUrl(l.url))}</code>
          </div>
          <div class="link-actions">
            <button class="btn small" type="button" data-copy="${i}">Копировать</button>
            <button class="btn small" type="button" data-qr="${i}">QR</button>
          </div>
        </li>`).join("")}
      </ol>
      <figure class="qr-all">
        ${allFits ? qrImage(d, g, "all", `QR всей группы ${g.label}`)
          : `<div class="qr-placeholder">Группа слишком длинная для одного QR-кода. Используй «Скопировать все» или QR отдельных ссылок</div>`}
        <figcaption>QR всей группы</figcaption>
      </figure>
    </div>
    <p class="hint">В Hiddify: «Скопировать все», затем в приложении «Добавить из буфера обмена». Получится группа подключений.</p>`;

  $("#reveal").addEventListener("change", (e) => { page.reveal = e.target.checked; renderGroup(d, name); });
  $("#copy-all").addEventListener("click", async () => {
    toast(await copyText(all) ? `Скопировано ссылок: ${g.links.length}` : "Не удалось скопировать");
  });
  el.querySelector('[data-hy2="rebuild"]').addEventListener("click", () => run({ action: "add", label: g.label }));
  el.querySelector('[data-hy2="del"]').addEventListener("click", () => {
    const keep = authMode(d) === "password"
      ? "В режиме общего пароля выданные ссылки продолжат работать: отключить их можно только сменой пароля на всех узлах."
      : "Пользователь группы удалится с узлов, и её ссылки перестанут работать.";
    if (confirm(`Удалить группу «${g.label}»? ${keep}`)) run({ action: "del", name: g.name });
  });
  el.querySelectorAll("[data-copy]").forEach((b) => b.addEventListener("click", async () => {
    const l = g.links[Number(b.dataset.copy)];
    toast(await copyText(l.url) ? `Скопирована ссылка: ${l.node || l.title}` : "Не удалось скопировать");
  }));
  el.querySelectorAll("[data-qr]").forEach((b) => b.addEventListener("click", () => {
    const i = Number(b.dataset.qr), l = g.links[i];
    $("#qr-title").textContent = l.title;
    $("#qr-body").innerHTML = qrImage(d, g, i, `QR ${l.title}`) +
      `<p class="hint">Hiddify: «+», затем «Сканировать QR-код».</p>`;
    $("#qr-dialog").showModal();
  }));
}

function renderNodes(d) {
  const nodes = d.nodes;
  $("#nodes-count").textContent = nodes.length || "";
  $("#nodes").innerHTML = nodes.map((n) => {
    const head = `<td class="cell-node"><div class="node-cell"><div>
        <div class="node-name"><a class="node-link" href="${nodeHref(n.name)}">${esc(n.name)}</a></div>
        ${n.title && n.title !== n.name ? `<span class="sub-line">${esc(n.title)}</span>` : ""}
      </div></div></td>
      <td data-label="Адрес"><span class="mono">${esc(n.addr)}</span></td>`;
    if (!n.reachable) return `<tr class="is-crit">${head}<td class="cell-wide" colspan="3">${badge("crit", "нет связи по SSH")}</td></tr>`;
    const bad = n.hy2.installed && !(n.hy2.state === "active" && n.hy2.udp);
    return `<tr class="${bad ? "is-crit" : ""}">${head}
      <td data-label="Состояние">${hy2Cell(n, false)}</td>
      <td data-label="Доступ">${esc(hy2Access(n.hy2)) || '<span class="muted">—</span>'}</td>
      <td data-label="Версия">${esc(n.hy2.version) || '<span class="muted">—</span>'}</td>
    </tr>`;
  }).join("");
  const empty = $("#nodes-empty");
  empty.hidden = nodes.length > 0;
  $("table.nodes").hidden = !nodes.length;
  if (!nodes.length) empty.textContent = d.status_error ? `Не удалось опросить узлы: ${d.status_error}` : "Узлов нет.";

  const mode = authMode(d);
  $("#auth-mode").textContent = mode === "password"
    ? "Режим общего пароля: у всех групп один пароль, отключить одного человека нельзя"
    : mode === "userpass" ? "Режим userpass: каждая группа — отдельный пользователь" : "";
}

const pageApi = startPage({
  url: "api/hy2",
  demo: demoHy2,
  init(rerender) {
    window.addEventListener("hashchange", rerender);
    $("#new-group-btn").addEventListener("click", () => toggleForm($("#new-group").hidden));
    $("#new-group").addEventListener("submit", createGroup);
    $("#refresh-all").addEventListener("click", () => run({ action: "refresh" }));
    $("#job-hide").addEventListener("click", () => job.hide());
    job.poll();
    $("#qr-close").addEventListener("click", () => $("#qr-dialog").close());
    // Клик по фону закрывает окно с QR
    $("#qr-dialog").addEventListener("click", (e) => { if (e.target === e.currentTarget) e.currentTarget.close(); });
  },
  render(d) {
    page.data = d;
    const name = selectedName(d);
    renderGroups(d, name);
    renderGroup(d, name);
    renderNodes(d);
    lock();
  },
});
