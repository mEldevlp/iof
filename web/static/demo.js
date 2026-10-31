"use strict";

// Демо-данные по примерам из гайда, для страниц с параметром ?demo. Ключи и пароли выдуманы

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
  return nodes;
}

function demoStatus() {
  const now = Date.now() / 1000;
  return { status_at: now, generated_at: now, probe_s: 1.6 + Math.random(), cached: false, status_error: null, nodes: demoNodes() };
}

function demoDelay(data) {
  return new Promise((resolve) => setTimeout(() => resolve(data), 450));
}

function demoDashboard() {
  return demoDelay({
    ...demoStatus(),
    relays: [{
      node: "main", via: "node-2", label: "Main via Node 2",
      hy2: "203.0.113.30:45001", hy2_target: "192.0.2.10:443",
      awg: "203.0.113.30:45002", awg_target: "192.0.2.10:41234",
    }],
    hy2_groups: [
      { name: "Hysteria", label: "Hysteria", created: "2026-09-14 18:22:05" },
      { name: "Family", label: "Family", created: "2026-10-02 09:41:37" },
    ],
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
  const group = (name, label, created, nodes) => ({
    name, label, created, file: `/root/iof/hy2/${name}.txt`,
    links: nodes.map((n) => link(label, ...n)),
  });
  return demoDelay({
    ...demoStatus(),
    qr: true,
    groups: [
      group("Hysteria", "Hysteria", "2026-09-14 18:22:05", [
        ["192.0.2.10", 443, "Main"], ["198.51.100.20", 443, "Node 1"], ["203.0.113.30", 443, "Node 2"],
        ["203.0.113.41", 443, "Node 3"], ["203.0.113.42", 443, "Node 4"], ["203.0.113.30", 45001, "Main via Node 2", true],
      ]),
      group("Family", "Family", "2026-10-02 09:41:37", [
        ["192.0.2.10", 443, "Main"], ["198.51.100.20", 443, "Node 1"], ["203.0.113.30", 443, "Node 2"],
      ]),
    ],
  });
}
