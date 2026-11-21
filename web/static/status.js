"use strict";

const statuses = {
  operational: ["good", "Службы работают"],
  outage: ["crit", "Сбой VPN-служб"],
  unknown: ["none", "Нет данных"],
};
const network = {
  operational: ["good", "Всё работает", "По последним наблюдениям VPN-службы работают на всех серверах."],
  outage: ["warn", "Часть серверов недоступна", "На отдельных серверах обнаружен сбой VPN-служб."],
  all_outage: ["crit", "Сбои на всех серверах", "На каждом наблюдаемом сервере обнаружен сбой VPN-служб."],
  unknown: ["none", "Нет свежих данных", "Для одного или нескольких серверов нет свежих наблюдений."],
};
const eventLabels = {
  outage: ["crit", "Зафиксирован сбой VPN-служб"],
  recovery: ["good", "Работа VPN-служб восстановлена"],
  maintenance: ["warn", "Зафиксированы техработы"],
};
const dayLabel = new Intl.DateTimeFormat("ru-RU", { dateStyle: "long", timeZone: "UTC" });
const shortDay = new Intl.DateTimeFormat("ru-RU", { day: "numeric", month: "short", timeZone: "UTC" });
const timestamp = new Intl.DateTimeFormat("ru-RU", {
  day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", timeZone: "UTC",
});
const percentage = new Intl.NumberFormat("ru-RU", { style: "percent", maximumFractionDigits: 2 });
const selectedDays = new Map();

function statusTime(at) {
  const date = new Date(at * 1000);
  return `<time datetime="${date.toISOString()}">${esc(timestamp.format(date))} UTC</time>`;
}

function measuredTime(seconds) {
  const minutes = Math.floor(seconds / 60);
  if (seconds && !minutes) return "меньше минуты";
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (!hours) return `${minutes} мин`;
  return rest ? `${hours} ч ${rest} мин` : `${hours} ч`;
}

function dayDetails(day) {
  const date = dayLabel.format(day.date * 1000);
  const elapsed = Math.min(86400, Math.floor(Date.now() / 1000) - day.date);
  const missing = Math.max(0, elapsed - day.up_seconds - day.down_seconds);
  return `<div class="status-date"><strong>${esc(date)}</strong>${badge(...statuses[day.state])}</div>
    <p>${day.up} успешных проверок · ${day.down} со сбоем · ${day.unknown} без данных</p>
    <p>${measuredTime(day.up_seconds)} работы · ${measuredTime(day.down_seconds)} сбоя${missing ? ` · Нет данных (${measuredTime(missing)})` : ""}</p>`;
}

function renderNode(node, index) {
  const days = node.days;
  const selected = days.find((day) => day.date === selectedDays.get(node.name)) || days.at(-1);
  const grid = days.map((day) => {
    const [level, label] = statuses[day.state];
    const active = day === selected;
    const accessibleLabel = esc(`${dayLabel.format(day.date * 1000)} · ${label}`);
    return `<button class="status-day ${level}" type="button" data-date="${day.date}" tabindex="${active ? 0 : -1}"
      aria-label="${accessibleLabel}" title="${accessibleLabel}" aria-pressed="${active}" aria-controls="status-day-${index}"></button>`;
  }).join("");
  const availability = node.availability === null ? "Мало данных" : percentage.format(node.availability / 100);
  return `<article class="status-node" data-node="${esc(node.name)}">
    <div class="status-node-head"><h3>${esc(node.name)}</h3>${badge(...statuses[node.state])}
      ${node.maintenance ? badge("warn", "Техработы") : ""}</div>
    <div class="status-days" role="group" aria-label="Дневная история · ${esc(node.name)}">${grid}</div>
    <div class="status-scale">
      <span>${esc(shortDay.format(days[0].date * 1000))}</span>
      <span>Доступность <strong>${esc(availability)}</strong></span>
      <span>${esc(shortDay.format(days.at(-1).date * 1000))}</span>
    </div>
    <div class="status-day-details" id="status-day-${index}" aria-live="polite" aria-atomic="true">${dayDetails(selected)}</div>
  </article>`;
}

function setDayFocus(grid, button) {
  grid.querySelector('[tabindex="0"]').tabIndex = -1;
  button.tabIndex = 0;
}

function renderStatus(data, failed = false) {
  const [level, title, detail] = network[data.state];
  const summary = $("#status-summary");
  summary.className = `health ${level}`;
  const description = failed ? "Не удалось загрузить свежий статус." :
    data.nodes.length ? detail : "Наблюдения появятся после первого опроса VPN-серверов.";
  summary.innerHTML = `${icon(level, "ico big-ico")}<div><h2>${esc(title)}</h2><p class="sub">${esc(description)}</p></div>`;
  $("#status-updated").innerHTML = data.updated_at === null ? "Обновлений пока нет" : `Обновлено ${statusTime(data.updated_at)}`;

  const maintenance = $("#status-maintenance");
  const names = data.nodes.filter((node) => node.maintenance).map((node) => node.name);
  maintenance.hidden = !names.length;
  if (names.length) {
    maintenance.innerHTML = `${icon("warn", "ico big-ico")}<div><h2>Идут техработы</h2><p class="sub">${esc(names.join(", "))}</p></div>`;
  }

  const focused = document.activeElement.closest(".status-day");
  const focusName = focused?.closest(".status-node").dataset.node;
  $("#status-nodes").innerHTML = data.nodes.map(renderNode).join("") || '<p class="status-empty">История пока пуста.</p>';
  if (focusName) {
    const row = [...document.querySelectorAll(".status-node")].find((node) => node.dataset.node === focusName);
    const target = row?.querySelector(`[data-date="${focused.dataset.date}"]`) || row?.querySelector('[tabindex="0"]');
    if (target) {
      setDayFocus(target.parentElement, target);
      target.focus({ preventScroll: true });
    }
  }

  $("#status-events").innerHTML = data.events.length ? `<ul class="status-events">${data.events.map((event) =>
    `<li>${badge(...eventLabels[event.kind])}<span class="status-event-meta">${esc(event.name)} · ${statusTime(event.at)}</span></li>`
  ).join("")}</ul>` : '<p class="status-empty">Событий пока нет.</p>';
}

let snapshot;
let loading = false;
let loadFailed = false;

async function refreshStatus() {
  if (loading) return;
  loading = true;
  try {
    const response = await fetch("/status/data.json", { credentials: "omit", cache: "no-store" });
    if (!response.ok) throw new Error("Статус недоступен");
    const data = await response.json();
    if (loadFailed || JSON.stringify(data) !== JSON.stringify(snapshot)) {
      snapshot = data;
      renderStatus(data);
    }
    loadFailed = false;
  } catch {
    const data = snapshot || { updated_at: null, nodes: [], events: [] };
    const nodes = data.nodes.map((node) => ({ ...node, state: "unknown", maintenance: false }));
    if (!loadFailed) renderStatus({ ...data, state: "unknown", nodes }, true);
    loadFailed = true;
  } finally {
    loading = false;
  }
}

$("#status-nodes").addEventListener("click", (event) => {
  const button = event.target.closest(".status-day");
  if (!button) return;
  const grid = button.parentElement;
  const name = button.closest(".status-node").dataset.node;
  const date = Number(button.dataset.date);
  const day = snapshot.nodes.find((node) => node.name === name).days.find((entry) => entry.date === date);
  selectedDays.set(name, date);
  setDayFocus(grid, button);
  grid.querySelector('[aria-pressed="true"]').setAttribute("aria-pressed", "false");
  button.setAttribute("aria-pressed", "true");
  document.getElementById(button.getAttribute("aria-controls")).innerHTML = dayDetails(day);
});

$("#status-nodes").addEventListener("keydown", (event) => {
  const button = event.target.closest(".status-day");
  if (!button) return;
  const grid = button.parentElement;
  const next = { ArrowLeft: button.previousElementSibling, ArrowRight: button.nextElementSibling,
    Home: grid.firstElementChild, End: grid.lastElementChild }[event.key];
  if (next) {
    event.preventDefault();
    setDayFocus(grid, next);
    next.focus();
  }
});

refreshStatus();
setInterval(() => { if (!document.hidden) refreshStatus(); }, 60000);
document.addEventListener("visibilitychange", () => { if (!document.hidden) refreshStatus(); });
