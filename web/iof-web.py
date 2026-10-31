#!/usr/bin/env python3
"""iof-web: веб-панель для iof (Island of Freedom).

Работает на управляющем сервере от root, только читает: состояние узлов берёт из
`iof api status`, списки ретрансляторов, групп Hysteria2 и клиентов AWG читает из
/root/iof напрямую. Ссылки Hysteria2 (в них пароль) отдаёт на странице hy2,
ключи и конфиги AWG не отдаёт.

Без зависимостей, нужен только python3. По умолчанию слушает 127.0.0.1:8088,
снаружи заходить через SSH-туннель:  ssh -L 8088:127.0.0.1:8088 admin@сервер

Запуск:  python3 iof-web.py [--listen 127.0.0.1:8088] [--iof /usr/local/bin/iof]
Пароль:  переменная IOF_WEB_PASSWORD (HTTP Basic, имя пользователя любое).
Слушать не на loopback без пароля сервер откажется.
"""

import argparse
import base64
import hmac
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

STATIC_DIR = Path(__file__).resolve().parent / "static"

# Только эти файлы раздаются как статика, остальное 404
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/hy2.html": ("hy2.html", "text/html; charset=utf-8"),
    "/common.js": ("common.js", "text/javascript; charset=utf-8"),
    "/demo.js": ("demo.js", "text/javascript; charset=utf-8"),
    "/dashboard.js": ("dashboard.js", "text/javascript; charset=utf-8"),
    "/hy2.js": ("hy2.js", "text/javascript; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
}

SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'self'; img-src 'self' data:; frame-ancestors 'none'",
}


# Состояние узлов

def to_int(v, default=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def to_float(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def percent(a, b):
    # Так же, как percent() в iof: округление до целого
    return int(a * 100 / b + 0.5) if b > 0 else 0


def parse_status(text):
    """Блоки "== имя" + key=value из `iof api status` в список словарей."""
    raw, cur = [], None
    for line in text.splitlines():
        if line.startswith("== "):
            cur = {"name": line[3:].strip()}
            raw.append(cur)
        elif cur is not None and "=" in line:
            k, v = line.split("=", 1)
            cur[k.strip()] = v.strip()
    return [shape_node(r) for r in raw]


def shape_node(r):
    issues = [s.strip() for s in r.get("issues", "").split(";") if s.strip()]
    node = {
        "name": r["name"],
        "addr": r.get("addr", ""),
        "title": r.get("title") or r["name"],
        "reachable": r.get("reachable") == "yes",
        "issues": issues,
        "ok": not issues,
    }
    if not node["reachable"]:
        return node

    cpus = max(to_int(r.get("cpus"), 1), 1)
    load1 = to_float(r.get("load1"))
    mem_used, mem_total = to_int(r.get("mem_used_mb")), to_int(r.get("mem_total_mb"))
    disk_used, disk_total = to_int(r.get("disk_used_kb")), to_int(r.get("disk_total_kb"))
    node.update({
        "ms": to_int(r.get("ms")),
        "uptime_s": to_int(r.get("uptime_s")),
        "hy2": {
            "installed": r.get("hy2_installed") == "yes",
            "state": r.get("hy2_state", ""),
            "udp": r.get("hy2_udp") == "yes",
            "port": r.get("hy2_port", ""),
            "auth": r.get("hy2_auth", ""),
            "users": to_int(r.get("hy2_users")),
            "version": r.get("hy2_ver", ""),
        },
        "awg": {
            "state": r.get("awg_state", "none"),
            "port": r.get("awg_port", ""),
            "peers": to_int(r.get("awg_peers")),
            "online": to_int(r.get("awg_online")),
        },
        "cpu": {"pct": int(load1 * 100 / cpus + 0.5), "load1": load1, "cpus": cpus},
        "mem": {"pct": percent(mem_used, mem_total), "used_mb": mem_used, "total_mb": mem_total},
        "disk": {"pct": percent(disk_used, disk_total), "used_kb": disk_used, "total_kb": disk_total},
    })
    return node


class StatusCache:
    """Опрос узлов идёт по SSH и занимает секунды, поэтому результат кэшируется,
    а одновременные запросы ждут один общий опрос, а не запускают свои."""

    def __init__(self, iof, ttl):
        self.iof = iof
        self.ttl = ttl
        self.lock = threading.Lock()
        self.data = None

    def get(self, force=False):
        with self.lock:
            age = time.time() - self.data["status_at"] if self.data else None
            # Принудительное обновление не чаще раза в 5 секунд
            fresh = age is not None and (age < 5 or (not force and age < self.ttl))
            if fresh:
                return dict(self.data, cached=True)
            self.data = self.probe()
            return dict(self.data, cached=False)

    def probe(self):
        t0 = time.time()
        env = dict(os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8")
        try:
            p = subprocess.run([self.iof, "api", "status"], capture_output=True,
                               timeout=180, env=env, stdin=subprocess.DEVNULL)
        except FileNotFoundError:
            return self.failed(t0, f"не найден {self.iof}")
        except subprocess.TimeoutExpired:
            return self.failed(t0, "опрос узлов не уложился в 180 секунд")
        out = p.stdout.decode("utf-8", "replace")
        if p.returncode != 0:
            err = p.stderr.decode("utf-8", "replace").strip().splitlines()
            return self.failed(t0, err[-1] if err else f"iof завершился с кодом {p.returncode}")
        # Старый iof не знает api и печатает справку
        if out.strip() and not out.startswith("== "):
            return self.failed(t0, "iof не поддерживает «iof api status», обнови скрипт на сервере")
        return {"status_at": time.time(), "probe_s": round(time.time() - t0, 2),
                "status_error": None, "nodes": parse_status(out)}

    @staticmethod
    def failed(t0, msg):
        return {"status_at": time.time(), "probe_s": round(time.time() - t0, 2),
                "status_error": msg, "nodes": []}


# Файлы iof

def read_conf(path, fields):
    """Строки "a | b | c" без комментариев, как read_nodes / read_relays в iof."""
    rows = []
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return rows
    for line in lines:
        parts = [p.strip() for p in line.split("|")]
        if not parts[0] or parts[0].startswith("#"):
            continue
        parts += [""] * (fields - len(parts))
        rows.append(parts[:fields])
    return rows


def read_index(path):
    """index.tsv: логин<TAB>подпись<TAB>создан. Пароли и ключи лежат в других файлах."""
    out = []
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return out
    for line in lines:
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0]:
            out.append({"name": parts[0], "label": parts[1], "created": parts[2] if len(parts) > 2 else ""})
    return out


def read_relays(base):
    addr = {name: a for name, a, _, _ in read_conf(base / "nodes.conf", 4)}
    titles = {name: t or name for name, _, _, t in read_conf(base / "nodes.conf", 4)}
    relays = []
    for node, via, hyl, hyd, awl, awd in read_conf(base / "relays.conf", 6):
        via_addr = addr.get(via, "")

        def endpoint(port):
            return f"{via_addr}:{port}" if port and port != "-" else None

        relays.append({
            "node": node, "via": via,
            "label": f"{titles.get(node, node)} via {titles.get(via, via)}",
            "hy2": endpoint(hyl), "hy2_target": f"{addr.get(node, '')}:{hyd}" if hyd not in ("", "-") else None,
            "awg": endpoint(awl), "awg_target": f"{addr.get(node, '')}:{awd}" if awd not in ("", "-") else None,
        })
    return relays


# Логины групп Hysteria2 iof делает из латиницы, цифр и "_" (slugify), путь собирается только из таких
SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]+$")


def parse_hy2_link(url):
    """hy2://пароль@хост:порт/?...#Подпись%20%7C%20Узел -> поля для страницы без пароля."""
    u = urlsplit(url)
    title = unquote(u.fragment)
    node = title.split(" | ", 1)[1] if " | " in title else title
    try:
        port = u.port
    except ValueError:
        port = None
    return {"url": url, "title": title, "node": node, "host": u.hostname or "",
            "port": port, "relay": " via " in node}


def hy2_group_file(base, name):
    return base / "hy2" / f"{name}.txt" if SAFE_NAME.match(name) else None


def read_hy2_links(path):
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    return [line.strip() for line in lines if line.strip().startswith("hy2://")]


def read_hy2_groups(base):
    groups = []
    for g in read_index(base / "hy2" / "index.tsv"):
        path = hy2_group_file(base, g["name"])
        if path is None:
            continue
        g["file"] = str(path)
        g["links"] = [parse_hy2_link(url) for url in read_hy2_links(path)]
        groups.append(g)
    return groups


def qr_svg(text, level):
    """SVG с QR-кодом через qrencode. None, если qrencode нет или текст не помещается."""
    exe = shutil.which("qrencode")
    if not exe:
        return None
    # --svg-path рисует код одним контуром, файл в разы меньше. Старые qrencode его не знают
    for extra in (["--svg-path"], []):
        try:
            p = subprocess.run([exe, "-t", "SVG", *extra, "-l", level, "-m", "2", "-s", "6", "-o", "-"],
                               input=text.encode("utf-8"), capture_output=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if p.returncode == 0 and p.stdout:
            return p.stdout
    return None


def read_awg_clients(base):
    clients = read_index(base / "awg" / "index.tsv")
    for c in clients:
        d = base / "awg" / c["name"]
        try:
            c["configs"] = sorted(p.stem for p in d.glob("*.conf"))
        except OSError:
            c["configs"] = []
    return clients


# HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "iof-web"
    sys_version = ""

    def do_GET(self):
        if not self.authorized():
            return
        url = urlsplit(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        force = query.get("force") == "1"
        if url.path == "/api/dashboard":
            return self.dashboard(force)
        if url.path == "/api/hy2":
            return self.hy2(force)
        if url.path == "/api/hy2/qr":
            return self.hy2_qr(query.get("g", ""), query.get("i", ""))
        if url.path in STATIC_FILES:
            return self.static(*STATIC_FILES[url.path])
        self.send_json({"error": "не найдено"}, HTTPStatus.NOT_FOUND)

    def authorized(self):
        password = self.server.password
        if not password:
            return True
        header = self.headers.get("Authorization", "")
        if header.startswith("Basic "):
            try:
                given = base64.b64decode(header[6:]).decode("utf-8").split(":", 1)[1]
            except (ValueError, IndexError, UnicodeDecodeError):
                given = ""
            if hmac.compare_digest(given.encode(), password.encode()):
                return True
        self.send_response(HTTPStatus.UNAUTHORIZED)
        self.send_header("WWW-Authenticate", 'Basic realm="iof", charset="UTF-8"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def dashboard(self, force):
        base = self.server.base
        data = self.server.cache.get(force)
        data.update({
            "generated_at": time.time(),
            "relays": read_relays(base),
            "hy2_groups": [g for g in read_index(base / "hy2" / "index.tsv") if SAFE_NAME.match(g["name"])],
            "awg_clients": read_awg_clients(base),
        })
        self.send_json(data)

    def hy2(self, force):
        data = self.server.cache.get(force)
        data.update({
            "generated_at": time.time(),
            "groups": read_hy2_groups(self.server.base),
            "qr": shutil.which("qrencode") is not None,
        })
        self.send_json(data)

    # QR одной ссылки (i = номер строки) или всей группы (i = all), как iof hy2 show
    def hy2_qr(self, name, index):
        base = self.server.base
        known = {g["name"] for g in read_index(base / "hy2" / "index.tsv")}
        path = hy2_group_file(base, name) if name in known else None
        links = read_hy2_links(path) if path else []
        if index == "all" and links:
            text, level = "\n".join(links), "L"
        elif index.isdigit() and int(index) < len(links):
            text, level = links[int(index)], "M"
        else:
            return self.send_json({"error": "нет такой группы или ссылки"}, HTTPStatus.NOT_FOUND)
        svg = qr_svg(text, level)
        if svg is None:
            return self.send_json({"error": "qrencode не установлен или текст слишком длинный"},
                                  HTTPStatus.UNPROCESSABLE_ENTITY)
        # В QR пароль Hysteria2, поэтому без кэширования
        self.send_body(svg, "image/svg+xml", "no-store")

    def static(self, name, ctype):
        try:
            body = (STATIC_DIR / name).read_bytes()
        except OSError:
            return self.send_json({"error": "не найдено"}, HTTPStatus.NOT_FOUND)
        self.send_body(body, ctype, "no-cache")

    def send_json(self, obj, status=HTTPStatus.OK):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_body(body, "application/json; charset=utf-8", "no-store", status)

    def send_body(self, body, ctype, cache, status=HTTPStatus.OK):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main():
    ap = argparse.ArgumentParser(description="Веб-панель iof")
    ap.add_argument("--listen", default=os.environ.get("IOF_WEB_LISTEN", "127.0.0.1:8088"),
                    help="адрес:порт, по умолчанию 127.0.0.1:8088")
    ap.add_argument("--iof", default=os.environ.get("IOF_BIN", "/usr/local/bin/iof"))
    ap.add_argument("--base", default=os.environ.get("IOF_BASE", "/root/iof"))
    ap.add_argument("--ttl", type=int, default=int(os.environ.get("IOF_WEB_TTL", "20")),
                    help="сколько секунд держать результат опроса узлов")
    args = ap.parse_args()

    host, _, port = args.listen.rpartition(":")
    host = host.strip("[]") or "127.0.0.1"
    password = os.environ.get("IOF_WEB_PASSWORD", "")
    try:
        loopback = ipaddress.ip_address(host).is_loopback
    except ValueError:
        loopback = host == "localhost"
    if not loopback and not password:
        sys.exit(f"Отказываюсь слушать {host} без пароля: задай IOF_WEB_PASSWORD "
                 "или оставь 127.0.0.1 и заходи через SSH-туннель")

    srv = ThreadingHTTPServer((host, int(port)), Handler)
    srv.daemon_threads = True
    srv.base = Path(args.base)
    srv.password = password
    srv.cache = StatusCache(args.iof, args.ttl)
    print(f"iof-web: http://{args.listen}/", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
