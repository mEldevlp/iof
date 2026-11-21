"use strict";

const awg = { migrate: null, running: false, sending: false, request: null, selected: null, clients: null, links: null };

const job = watchJob({
  kind: "awg",
  demoJobs: () => demoJobs(),
  all: false,
  render(j) {
    const level = renderJobCard(j);
    awg.running = j?.state === "running";
    lock();
    if (!j) return;
    $("#job-hide").hidden = awg.running;
    const reason = failReason(j.log);
    jobResult(level, {
      ok: `${icon("good")}<div>Готово</div>`,
      warn: `${icon("warn")}<div>Часть операций завершилась с ошибками. Подробности в логе.</div>`,
      error: `${icon("crit")}<div>${esc(reason || "Не удалось выполнить операцию. Подробности в логе.")}</div>`,
    }[j.state]);
  },
  done(j) {
    const created = j.log.map((line) => /^Клиент: ([\w.-]+)$/.exec(line)).find(Boolean);
    if (created) history.replaceState(null, "", `#c=${encodeURIComponent(created[1])}`);
    pageApi.reload();
  },
});

function lock() {
  const migrating = awg.migrate?.role === "source";
  document.querySelectorAll("[data-lock]").forEach((button) => {
    button.disabled = awg.running || awg.sending || migrating;
    button.title = migrating ? "Идёт перенос управления" : "";
  });
}

async function run(body) {
  formError("", "#action-error");
  awg.sending = true;
  lock();
  try {
    const id = DEMO ? demoAwgJob(body) : (await postJson("api/awg", body)).job;
    awg.running = true;
    job.start(id);
    return true;
  } catch (e) {
    formError(e.message, "#action-error");
    return false;
  } finally {
    awg.sending = false;
    lock();
  }
}

function toggleForm(open) {
  $("#new-client").hidden = !open;
  $("#new-client-btn").setAttribute("aria-expanded", String(open));
  if (open) $("#f-label").focus();
}

async function createClient(e) {
  e.preventDefault();
  const input = $("#f-label");
  const label = input.value.trim();
  if (!label || label.includes("|")) {
    formError("Введи имя клиента без символа |", "#action-error");
    input.focus();
    return;
  }
  if (await run({ action: "add", label })) {
    input.value = "";
    toggleForm(false);
  }
}

function clientHref(name) {
  return `#c=${encodeURIComponent(name)}`;
}

async function loadKeys(client, replace) {
  awg.request?.abort();
  const request = awg.request = new AbortController();
  const panel = $("#client-keys");
  const finish = replace ? skeleton(panel, skeletonLinks(client.configs.length || 1)) : null;
  try {
    const { links } = DEMO ? demoAwgKeys(client.name)
      : await getJson(`api/awg/keys?name=${encodeURIComponent(client.name)}`, request.signal);
    if (request !== awg.request || !panel.isConnected) return;
    const value = JSON.stringify(links);
    if (value === awg.links) return;
    finish?.();
    awg.links = value;
    panel.innerHTML = links.length ? `<ol class="links">${links.map((link, i) => `<li class="link">
      <div class="link-main"><div class="link-title">${esc(link.title || `Подключение ${i + 1}`)}</div></div>
      <div class="link-actions"><button class="btn small" type="button" data-copy="${i}">Копировать vpn://</button></div>
    </li>`).join("")}</ol>` : emptyList("Ссылок пока нет. Добавь доступные узлы или пересобери ссылки.");
    panel.querySelectorAll("[data-copy]").forEach((button) => button.addEventListener("click", async () => {
      toast(await copyText(links[Number(button.dataset.copy)].url) ? "Ключ скопирован" : "Не удалось скопировать ключ");
    }));
  } catch (e) {
    if (request === awg.request && panel.isConnected && (replace || !awg.links)) {
      finish?.();
      awg.links = null;
      panel.innerHTML = `<p class="empty">${esc(`Не удалось получить ключи: ${e.message}`)}</p>`;
    }
  } finally {
    finish?.();
  }
}

function renderClients(clients, replace) {
  const selected = clients.find((client) => clientHref(client.name) === location.hash) || clients[0];
  const changed = awg.selected?.name !== selected?.name || awg.selected?.label !== selected?.label;
  const refreshed = awg.clients !== clients;
  awg.selected = selected;
  awg.clients = clients;
  $("#clients-count").textContent = clients.length || "";
  $("#clients").innerHTML = clients.length ? clients.map((client) => `
    <a class="group-item" href="${clientHref(client.name)}"${client === selected ? ' aria-current="true"' : ""}>
      <span class="item-head"><span class="item-title">${esc(client.label)}</span>
        <span class="item-meta">${fmtCreated(client.created)}</span></span>
      <span class="sub-line">${client.configs.length} ${plural(client.configs.length, ["профиль", "профиля", "профилей"])}</span>
    </a>`).join("") : emptyList("Клиентов пока нет");
  const panel = $("#client");
  if (!selected) {
    awg.request?.abort();
    awg.request = null;
    panel.innerHTML = emptyList("Добавь клиента, чтобы получить ключи для Amnezia VPN.");
    return;
  }
  if (!changed && $("#client-keys")) {
    if (replace || refreshed) loadKeys(selected, replace || !awg.links);
    return;
  }
  awg.links = null;
  panel.innerHTML = `<div class="card-head">
      <div><h2>${esc(selected.label)}</h2><span class="sub-line mono">${esc(selected.name)}</span></div>
      <div class="actions">
        <button id="client-add-nodes" class="btn" type="button" data-lock>Добавить недостающие узлы</button>
        <button id="client-del" class="btn danger" type="button" data-lock>Удалить</button>
      </div>
    </div>
    <div id="client-keys" class="pad" aria-live="polite"></div>
    <p class="hint">Скопируй один ключ. В Amnezia VPN нажми «+» → «Вставить ключ».</p>`;
  $("#client-add-nodes").addEventListener("click", () => run({ action: "add", label: selected.label }));
  $("#client-del").addEventListener("click", () => {
    if (confirm(`Удалить клиента «${selected.label}» с узлов? Его ключи перестанут работать.`)) {
      run({ action: "del", name: selected.name });
    }
  });
  loadKeys(selected, true);
}

function renderNodes(d) {
  $("#nodes-count").textContent = d.nodes.length || "";
  $("#nodes").innerHTML = d.nodes.map((n) => `<tr class="${nodeRowClass(n)}">
    <td class="cell-node"><a class="node-link" href="${nodeHref(n.name)}">${esc(n.title || n.name)}</a>${n.reachable ? nodeNotice(n) : ""}</td>
    <td data-label="Адрес" class="mono">${esc(n.addr)}</td>
    <td data-label="Состояние">${n.reachable ? awgCell(n) : badge("crit", "нет связи по SSH")}</td>
    <td data-label="Установка">${n.reachable && n.awg.state !== "running"
      ? `<a class="btn small" href="${nodeHref(n.name)}">Настроить на узле</a>` : "—"}</td>
  </tr>`).join("");
  $("table.nodes").hidden = !d.nodes.length;
  $("#nodes-empty").hidden = !!d.nodes.length;
  $("#nodes-empty").textContent = d.status_error ? `Не удалось опросить узлы: ${d.status_error}` : "Узлов нет";
}

const pageApi = startPage({
  url: "api/awg",
  demo: demoAwg,
  init(rerender) {
    window.addEventListener("hashchange", rerender);
    $("#new-client-btn").addEventListener("click", () => toggleForm($("#new-client").hidden));
    $("#new-client").addEventListener("submit", createClient);
    $("#refresh-all").addEventListener("click", () => run({ action: "refresh" }));
    $("#job-hide").addEventListener("click", () => job.hide());
    job.poll();
  },
  render(d, replace) {
    awg.migrate = d.migrate;
    renderClients(d.clients, replace);
    renderNodes(d);
    lock();
  },
});
