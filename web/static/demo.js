"use strict";

// Демо-данные по примерам из гайда, для страниц с параметром ?demo. Ключи и пароли выдуманы.
// Задачи из демо меняют demoState, поэтому созданная группа или удалённый узел видны до перезагрузки

const DEMO_LINK_NODES = [
  ["192.0.2.10", 443, "Main"], ["198.51.100.20", 443, "Node 1"], ["203.0.113.30", 443, "Node 2"],
  ["203.0.113.41", 443, "Node 3"], ["203.0.113.42", 443, "Node 4"], ["203.0.113.30", 45001, "Main via Node 2", true],
];

const DEMO_RELAYS = [{
  node: "main", via: "node-2", label: "Main via Node 2",
  hy2: "203.0.113.30:45001", hy2_target: "192.0.2.10:443",
  awg: "203.0.113.30:45002", awg_target: "192.0.2.10:41234",
}];

const demoState = {
  groups: [
    { name: "Hysteria", label: "Hysteria", created: "2026-09-14 18:22:05", nodes: null },
    { name: "Family", label: "Family", created: "2026-10-02 09:41:37", nodes: ["Main", "Node 1", "Node 2"] },
  ],
  deleted: [],
  version: "e741874 2026-11-01",
  updateLog: null,
  jobs: [
    {
      id: "demo-1", kind: "node", title: "Добавление сервера node-4 (203.0.113.42)", state: "ok",
      started: Date.now() / 1000 - 5400, finished: Date.now() / 1000 - 5340,
      log: ["$ iof node add node-4 203.0.113.42 'Node 4' 22 --user root --addr 203.0.113.42 --password-stdin",
        "Раздаю SSH-ключ на узлы: 1, одновременно до 20", "Добавлено в nodes.conf: 1", "Дальше: sudo iof hy2 install node-4",
        "$ iof hy2 install node-4", "Установлено: 1", "  node-4 (v2.13.0)", "Готово. Ссылки: sudo iof hy2 list"],
    },
    {
      id: "demo-2", kind: "hy2", title: "Создание группы «Family»", state: "warn",
      started: Date.now() / 1000 - 3600, finished: Date.now() / 1000 - 3590,
      log: ["$ iof hy2 add Family", "Создаю на узлах: 6", "Подпись: Family", "Файл:    /root/iof/hy2/Family.txt",
        "Не выдали ссылку (3):", "  node-3               нет связи по SSH", "  node-4               нет связи по SSH",
        "  node-5               нет связи по SSH", "Когда починишь, просто повтори команду, дублей не будет."],
    },
  ],
};

function demoNodes() {
  const jitter = (v, d) => Math.max(0, Math.round(v + (Math.random() - 0.5) * d));
  const node = (name, addr, title, o) => ({
    name, addr, title, reachable: true, issues: [], ok: true,
    ms: jitter(o.ms, 200), uptime_s: o.up,
    hy2: { installed: true, state: "active", udp: true, port: "443", auth: "password", users: 0, version: "v2.13.0", ...o.hy2 },
    awg: { state: "running", port: o.awgPort, peers: o.peers, online: jitter(o.online, 2), ...o.awg },
    cpu: { pct: o.cpu, load1: (o.cpu / 100 * o.cpus).toFixed(2), cpus: o.cpus },
    mem: { pct: Math.round(o.mem[0] / o.mem[1] * 100), used_mb: o.mem[0], total_mb: o.mem[1] },
    disk: { pct: Math.round(o.disk[0] / o.disk[1] * 100), used_kb: o.disk[0] * 1048576, total_kb: o.disk[1] * 1048576 },
  });
  const nodes = [
    node("main", "192.0.2.10", "Main", { ms: 40, up: 11400, awgPort: "41234", peers: 5, online: 1, cpus: 2, cpu: 12, mem: [742, 1967], disk: [9.1, 24] }),
    node("node-1", "198.51.100.20", "Node 1", { ms: 1100, up: 181020, awgPort: "42345", peers: 3, online: 0, cpus: 1, cpu: 7, mem: [403, 963], disk: [5.2, 15] }),
    node("node-2", "203.0.113.30", "Node 2", { ms: 1350, up: 46800, awgPort: "43456", peers: 4, online: 2, cpus: 2, cpu: 31, mem: [1210, 1967], disk: [12.6, 24] }),
    node("node-3", "203.0.113.41", "Node 3", { ms: 1600, up: 604800, awgPort: "", peers: 0, online: 0, cpus: 1, cpu: 4, mem: [388, 963], disk: [8.4, 10], awg: { state: "none" } }),
    node("node-4", "203.0.113.42", "Node 4", { ms: 1900, up: 93000, awgPort: "", peers: 0, online: 0, cpus: 1, cpu: 96, mem: [902, 963], disk: [6.1, 15], awg: { state: "stopped" } }),
    { name: "node-5", addr: "203.0.113.43", title: "Node 5", reachable: false, issues: ["нет связи по SSH"], ok: false },
  ];
  nodes[4].issues = ["контейнер AmneziaWG остановлен"];
  nodes[4].ok = false;
  return nodes.filter((n) => !demoState.deleted.includes(n.name));
}

function demoStatus() {
  const now = Date.now() / 1000;
  return { status_at: now, generated_at: now, probe_s: 1.6 + Math.random(), cached: false, status_error: null, nodes: demoNodes() };
}

function demoDelay(data) {
  return new Promise((resolve) => setTimeout(() => resolve(data), 450));
}

// Узлы, на которые в группе есть ссылка: null значит все (с ретранслятором)
function demoGroupNodes(g) {
  const titles = demoNodes().map((n) => n.title);
  return DEMO_LINK_NODES.filter(([, , node, relay]) =>
    (g.nodes ? g.nodes.includes(node) : true) && (relay || titles.includes(node)));
}

function demoDashboard() {
  return demoDelay({
    ...demoStatus(),
    relays: DEMO_RELAYS,
    hy2_groups: demoState.groups.map(({ name, label, created }) => ({ name, label, created })),
    awg_clients: [
      { name: "Ivan_iPhone_5f56f27b", label: "Иван iPhone", created: "2026-10-12 21:05:11", configs: ["Main", "Main_via_Node_2", "Node_1", "Node_2"] },
      { name: "Admin_Laptop", label: "Admin Laptop", created: "2026-09-14 18:30:44", configs: ["Main", "Main_via_Node_2", "Node_1", "Node_2"] },
      { name: "Mama_Android_0c1a9e44", label: "Мама Android", created: "2026-10-28 11:17:52", configs: ["Main", "Node_1", "Node_2"] },
    ],
  });
}

function demoHy2() {
  const pass = "Zk3pQ9vLx2mR7tYwB4nD";
  const pin = "3F:A1:9C:07:5E:D2:B8:44:61:0A:CE:72:19:F3:8B:55:2D:E6:90:4C:13:7A:B5:08:6F:C1:2E:94:D7:3B:A0:58";
  const link = (label, host, port, node, relay = false) => ({
    url: `hy2://${pass}@${host}:${port}/?sni=bing.com&insecure=1&pinSHA256=${encodeURIComponent(pin)}#${encodeURIComponent(`${label} | ${node}`)}`,
    title: `${label} | ${node}`, node, host, port, relay,
  });
  return demoDelay({
    ...demoStatus(),
    qr: true,
    groups: demoState.groups.map((g) => ({
      name: g.name, label: g.label, created: g.created, file: `/root/iof/hy2/${g.name}.txt`,
      links: demoGroupNodes(g).map((n) => link(g.label, ...n)),
    })),
  });
}

function demoNode(name) {
  const { nodes, ...status } = demoStatus();
  const node = nodes.find((n) => n.name === name) || null;
  return demoDelay({
    ...status,
    name,
    conf: node && { name, addr: node.addr, ssh: name === "main" ? "local" : `root@${node.addr}`, title: node.title },
    node,
    relays: DEMO_RELAYS.filter((r) => r.node === name || r.via === name),
    hy2_groups: demoState.groups.map((g) => ({
      name: g.name, label: g.label, created: g.created,
      has_link: !!node && demoGroupNodes(g).some(([, , n, relay]) => !relay && n === node.title),
    })),
    hy2_template: true,
    busy: false,
    migrate: null,
  });
}

function demoService(fetch) {
  const data = {
    version: demoState.version,
    src: "/opt/iof",
    src_version: demoState.version,
    tg: true,
    cron: ["0 4 * * * /usr/local/sbin/iof-nightly", "*/5 * * * * /usr/local/bin/iof check >/dev/null 2>&1"],
    error: null,
    check: { at: Date.now() / 1000 - 180, total: 6, bad: 2, problems: ["node-4", "node-5"], changes: 0 },
    nightly: {
      started: "2026-11-01 04:00:01", summary: "Выполнено на 6 узлах, с ошибкой: 1",
      log: ["== main", "Running as unit: iof-nightly.service", "== node-1", "Running as unit: iof-nightly.service",
        "== node-2", "Running as unit: iof-nightly.service", "== node-3", "Running as unit: iof-nightly.service",
        "== node-4", "Running as unit: iof-nightly.service", "== node-5", "   код выхода 255", "",
        "Выполнено на 6 узлах, с ошибкой: 1"],
    },
    update_log: demoState.updateLog,
    nightly_local: {
      steps: ["2026-11-01 04:00:02 управляющий сервер, жду 5 минут", "2026-11-01 04:05:02 обновление", "2026-11-01 04:07:41 перезагрузка"],
      errors: [],
    },
    busy: false,
    migrate: null,
  };
  if (fetch) {
    data.updates = demoState.version.startsWith("e741874") ? {
      error: null, branch: "origin/master",
      commits: [
        { hash: "9c41d2e", date: "2026-11-02", subject: "iof: hy2 restart проверяет, что сервис поднялся" },
        { hash: "51ab0f7", date: "2026-11-02", subject: "iof-web: страница узла" },
      ],
    } : { error: null, branch: "origin/master", commits: [] };
  }
  return demoDelay(data);
}


// Задачи в демо: строки лога появляются по таймеру, затем состояние state и after() меняет demoState

function demoJobs() {
  return demoState.jobs.slice().reverse();
}

function demoRunJob(kind, title, lines, state = "ok", after = null) {
  const job = { id: `demo-${Date.now()}`, kind, title, state: "running", started: Date.now() / 1000, finished: null, log: [] };
  demoState.jobs = [...demoState.jobs, job].slice(-10);
  let i = 0;
  const tick = () => {
    if (i < lines.length) { if (lines[i]) job.log.push(lines[i]); i++; setTimeout(tick, 280); return; }
    job.state = state;
    job.finished = Date.now() / 1000;
    if (after) after(job);
  };
  tick();
  return job.id;
}

const DEMO_DOWN = ["Не выдали ссылку (1):", "  node-5               нет связи по SSH", "Когда починишь, просто повтори команду, дублей не будет."];

function demoHy2Job(body) {
  if (body.action === "add") {
    const name = body.label.replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 32) || "user_3f2a9c1b";
    const old = demoState.groups.find((g) => g.name === name);
    return demoRunJob("hy2", `${old ? "Пересборка" : "Создание"} группы «${body.label}»`, [
      `$ iof hy2 add ${body.label}`, "Создаю на узлах: 6", "", `Подпись: ${body.label}`, `Файл:    /root/iof/hy2/${name}.txt`, "",
      ...DEMO_LINK_NODES.slice(0, 5).map(([h, p, n]) => `hy2://••••••••@${h}:${p}/?sni=bing.com&insecure=1#${encodeURIComponent(`${body.label} | ${n}`)}`),
      "", "Скопируй строки выше и добавь в Hiddify из буфера обмена.", "", ...DEMO_DOWN,
    ], "warn", () => {
      if (old) old.nodes = null;
      else demoState.groups.push({ name, label: body.label, created: new Date().toISOString().slice(0, 19).replace("T", " "), nodes: null });
    });
  }
  if (body.action === "del") {
    const g = demoState.groups.find((x) => x.name === body.name);
    return demoRunJob("hy2", `Удаление группы «${g.label}»`, [
      `$ iof hy2 del ${body.name}`, "Удалено на узлах: 5 из 6", "Ошибки (1):", "  node-5               нет связи по SSH",
    ], "warn", () => { demoState.groups = demoState.groups.filter((x) => x !== g); });
  }
  return demoRunJob("hy2", "Пересборка всех групп Hysteria2", [
    "$ iof hy2 refresh",
    ...demoState.groups.flatMap((g) => [`Hysteria2: пересобираю '${g.label}'`, "Создаю на узлах: 6", `Файл:    /root/iof/hy2/${g.name}.txt`, ...DEMO_DOWN]),
  ], "warn", () => { demoState.groups.forEach((g) => { g.nodes = null; }); });
}

function demoNodeJob(body) {
  const name = body.name;
  const kind = `node:${name}`;
  const down = name === "node-5";
  if (body.action === "restart_hy2") {
    return down
      ? demoRunJob(kind, `Перезапуск Hysteria2 на ${name}`, [`$ iof hy2 restart ${name}`, "Перезапущено: 0", "Ошибки (1):",
        `  ${name}               нет связи по SSH`, "Команда завершилась с кодом 1"], "error")
      : demoRunJob(kind, `Перезапуск Hysteria2 на ${name}`, [`$ iof hy2 restart ${name}`, `Перезапущено: 1 (${name})`]);
  }
  if (body.action === "install_hy2") {
    return demoRunJob(kind, `${body.force ? "Переустановка" : "Установка"} Hysteria2 на ${name}`, [
      `$ iof hy2 install ${name}${body.force ? " --force" : ""}`,
      "Шаблон конфига: /etc/hysteria/config.yaml (пароль, порт и маскировка будут как на этом сервере)",
      "Сертификат: свой на каждом узле, CN=bing.com", "Устанавливаю Hysteria2 на узлах: 1, одновременно до 20", "",
      "Установлено: 1", `  ${name} (v2.13.0)`, "", "Добавляю новые узлы в группы ссылок...", "Готово. Ссылки: sudo iof hy2 list, затем sudo iof hy2 show \"Подпись\"",
    ]);
  }
  const relay = DEMO_RELAYS.find((r) => r.node === name || r.via === name);
  if (relay) throw new Error(`узел участвует в ретрансляторе ${relay.node} через ${relay.via}, сначала убери его: sudo iof relay del ${relay.node} ${relay.via}`);
  return demoRunJob(kind, `Удаление узла ${name}`, [
    `$ iof node del ${name}`, `Узел ${name} убран из nodes.conf. Сам сервер не трогал.`, "Чтобы убрать его из ссылок и ключей: sudo iof refresh",
    "$ iof refresh", ...demoState.groups.map((g) => `Hysteria2: пересобираю '${g.label}'`), "",
    "AWG: ключи для 'Иван iPhone' пересобраны (sudo iof awg keys \"Иван iPhone\")",
  ], "ok", () => { demoState.deleted.push(name); });
}

// Обновление в демо: после задачи «панель перезапускается», и задача пропадает, как на сервере
function demoUpdateJob() {
  const out = ["Изменения e741874..9c41d2e:", "  9c41d2e iof: hy2 restart проверяет, что сервис поднялся", "  51ab0f7 iof-web: страница узла",
    "iof: /usr/local/bin/iof (9c41d2e 2026-11-02)", "iof-nightly: /usr/local/sbin/iof-nightly"];
  // Как на сервере: задача успевает показать только начало, полный вывод остаётся в файле
  return demoRunJob("service", "Обновление iof и панели", ["$ iof update", ...out.slice(0, 2)], "ok", (job) => {
    demoState.updateLog = { at: Date.now() / 1000, lines: [...out, "iof-web: работает, http://127.0.0.1:8088/ (с компьютера через SSH-туннель)"] };
    demoState.version = "9c41d2e 2026-11-02";
    demoState.jobs = demoState.jobs.filter((j) => j !== job);
  });
}
