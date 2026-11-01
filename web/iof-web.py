#!/usr/bin/env python3
"""iof-web: веб-панель для iof (Island of Freedom).

Работает на управляющем сервере от root. Состояние узлов берёт из `iof api status`,
списки ретрансляторов, групп Hysteria2 и клиентов AWG читает из /root/iof напрямую.
Ссылки Hysteria2 (в них пароль) отдаёт на странице hy2, ключи и конфиги AWG не отдаёт.
Меняет что-то только через команды iof (добавление сервера: iof node add, iof hy2 install;
группы ссылок: iof hy2 add | del | refresh; действия с узлом: iof hy2 restart | install, iof node del;
обновление: iof update; перенос управляющего сервера: iof migrate), по одной задаче за раз,
с логом выполнения.

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
import secrets
import shlex
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
    "/add.html": ("add.html", "text/html; charset=utf-8"),
    "/add.js": ("add.js", "text/javascript; charset=utf-8"),
    "/migrate.html": ("migrate.html", "text/html; charset=utf-8"),
    "/migrate.js": ("migrate.js", "text/javascript; charset=utf-8"),
    "/node.html": ("node.html", "text/html; charset=utf-8"),
    "/node.js": ("node.js", "text/javascript; charset=utf-8"),
    "/service.html": ("service.html", "text/html; charset=utf-8"),
    "/service.js": ("service.js", "text/javascript; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
}

# Логи ночного обслуживания: запуск с управляющего сервера и сама работа на этом сервере как узле
NIGHTLY_RUN_LOG = Path("/var/log/iof-nightly-run.log")
NIGHTLY_LOG = Path("/var/log/iof-nightly.log")

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

    def invalidate(self):
        with self.lock:
            self.data = None

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


def read_migrate(base):
    """migrate.conf (key=value, ведёт iof migrate) -> {role, peer, self, started} или None, если
    переноса нет. role: source на старом управляющем сервере, target на новом; self (только на старом):
    как новый сервер заходит на старый. Номер переноса не отдаётся."""
    try:
        lines = (base / "migrate.conf").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    kv = dict(line.split("=", 1) for line in lines if "=" in line)
    if kv.get("role") not in ("source", "target"):
        return None
    return {"role": kv["role"], "peer": kv.get("peer", ""), "self": kv.get("self", ""),
            "started": kv.get("started", "")}


def read_check(base):
    """check.last (итог последнего iof check, key=value) -> {at, total, bad, problems, changes} или None.
    at — время проверки (unix), по времени изменения файла: так браузеру не важен часовой пояс сервера."""
    path = base / "check.last"
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        at = path.stat().st_mtime
    except OSError:
        return None
    kv = dict(line.split("=", 1) for line in lines if "=" in line)
    return {"at": at, "total": to_int(kv.get("total")), "bad": to_int(kv.get("bad")),
            "problems": kv.get("problems", "").split(), "changes": to_int(kv.get("changes"))}


def tail_lines(path, limit=65536):
    """Последние строки файла (не больше limit байт), None, если файла нет."""
    try:
        with open(path, "rb") as f:
            size = f.seek(0, os.SEEK_END)
            f.seek(max(0, size - limit))
            data = f.read()
    except OSError:
        return None
    lines = data.decode("utf-8", "replace").splitlines()
    # Первая строка могла попасть не целиком
    return lines[1:] if size > limit else lines


RUN_HEAD = re.compile(r"^== (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)$")


def read_nightly_run(path):
    """Последний запуск iof-nightly: блок от строки "== дата" до конца. Внутри вывод iof exec:
    "== узел" и итог "Выполнено на N узлах, с ошибкой: M"."""
    lines = tail_lines(path)
    starts = [i for i, line in enumerate(lines or []) if RUN_HEAD.match(line)]
    if not starts:
        return None
    block = lines[starts[-1]:]
    summary = next((line for line in reversed(block) if line.startswith("Выполнено на ")), "")
    return {"started": RUN_HEAD.match(block[0]).group(1), "summary": summary, "log": block[1:][-80:]}


def read_nightly_local(path):
    """Последнее обслуживание этого сервера как узла: строки "== дата шаг" и ошибки apt (E:)."""
    lines = tail_lines(path) or []
    heads = [i for i, line in enumerate(lines) if line.startswith("== ")]
    updates = [k for k, i in enumerate(heads) if "обновление" in lines[i]]
    if not updates:
        return None
    k = updates[-1]
    # У управляющего сервера перед обновлением ещё строка «жду 5 минут»
    if k > 0 and "жду" in lines[heads[k - 1]]:
        k -= 1
    block = lines[heads[k]:]
    return {"steps": [line[3:] for line in block if line.startswith("== ")],
            "errors": [line for line in block if line.startswith("E: ")][-5:]}


def iof_api(iof, args, timeout):
    """Вывод iof api ... (key=value по строке) -> (словарь, ошибка или None). Повторяющиеся ключи
    cron и commit собираются в списки."""
    env = dict(os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8", GIT_TERMINAL_PROMPT="0")
    try:
        p = subprocess.run([iof, *args], capture_output=True, timeout=timeout, env=env, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        return {}, f"не найден {iof}"
    except subprocess.TimeoutExpired:
        return {}, f"iof {' '.join(args)} не уложился в {timeout} секунд"
    if p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace").strip().splitlines()
        return {}, (err[-1] if err else f"iof завершился с кодом {p.returncode}").removeprefix("Ошибка: ")
    out = {"cron": [], "commit": []}
    for line in p.stdout.decode("utf-8", "replace").splitlines():
        k, sep, v = line.partition("=")
        if not sep:
            continue
        if k in ("cron", "commit"):
            out[k].append(v)
        else:
            out[k] = v
    return out, None


# Задачи: команды iof, которые что-то меняют. Одна за раз, лог хранится в памяти

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
# hy2 add печатает ссылки группы с паролем, в лог задачи они идут без него
HY2_SECRET = re.compile(r"(hy2://)[^@\s]+@")
# Строки, после которых задача считается выполненной с ошибками, хотя код 0: hy2 install и hy2 del,
# если на части узлов не получилось, migrate start, если новый сервер видит не все узлы,
# hy2 add и hy2 refresh, если ссылку выдали не все узлы
WARN_LINES = ("Ошибки (", "Не выдали ссылку (", "Не удалось обновить: ")


class Jobs:
    KEEP = 10      # сколько последних задач помнить
    MAX_LOG = 600  # строк лога на задачу
    TIMEOUT = 900  # секунд на один шаг

    def __init__(self, on_done):
        self.on_done = on_done
        self.lock = threading.Lock()
        self.items = []
        self.running = False

    def busy(self):
        with self.lock:
            return self.running

    def list(self):
        with self.lock:
            return [dict(j, log=list(j["log"])) for j in reversed(self.items)]

    def start(self, title, steps, kind):
        """steps: [(подпись для лога, argv, stdin bytes или None)], kind: по нему страница находит
        свои задачи (node, migrate, hy2, service, node:<имя>). None, если занято."""
        with self.lock:
            if self.running:
                return None
            self.running = True
            job = {"id": secrets.token_hex(6), "kind": kind, "title": title, "state": "running",
                   "started": time.time(), "finished": None, "log": []}
            self.items = (self.items + [job])[-self.KEEP:]
        threading.Thread(target=self.run, args=(job, steps), daemon=True).start()
        return job

    def say(self, job, line):
        with self.lock:
            job["log"].append(line)
            del job["log"][:-self.MAX_LOG]

    def run(self, job, steps):
        env = dict(os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8")
        state = "ok"
        try:
            for label, argv, stdin in steps:
                self.say(job, f"$ {label}")
                p = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL)
                timer = threading.Timer(self.TIMEOUT, p.kill)
                timer.start()
                try:
                    if stdin is not None:
                        try:
                            p.stdin.write(stdin)
                            p.stdin.close()
                        except BrokenPipeError:
                            pass
                    for raw in p.stdout:
                        line = ANSI.sub("", raw.decode("utf-8", "replace")).rstrip("\n").split("\r")[-1]
                        line = HY2_SECRET.sub(r"\1••••••••@", line)
                        if line.strip():
                            self.say(job, line)
                        if line.startswith(WARN_LINES):
                            state = "warn"
                    rc = p.wait()
                finally:
                    timer.cancel()
                if rc != 0:
                    self.say(job, f"Команда завершилась с кодом {rc}")
                    state = "error"
                    break
        except OSError as e:
            self.say(job, f"Не удалось запустить: {e}")
            state = "error"
        finally:
            with self.lock:
                job["state"] = state
                job["finished"] = time.time()
                self.running = False
            self.on_done()


# Проверки полей формы, те же, что делает iof (node add, migrate start), чтобы ошибки было видно
# сразу в форме. iof всё равно проверяет их ещё раз сам
NODE_NAME = re.compile(r"^[A-Za-z0-9._-]{1,40}$")
NODE_HOST = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")
NODE_USER = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
SSH_TARGET = re.compile(r"^[a-z_][a-z0-9_-]{0,31}@[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(:[0-9]{1,5})?$")


def text_field(body, key, limit):
    v = body.get(key, "")
    if not isinstance(v, str):
        raise ValueError(f"поле {key}: нужна строка")
    v = v.strip()
    if len(v) > limit:
        raise ValueError(f"поле {key}: слишком длинное")
    return v


def login_fields(body):
    """Хост, SSH-порт, пользователь и способ входа из формы -> (host, port, user, аргументы iof
    для способа входа, stdin). Пароль и ключ уходят в iof через stdin, в аргументах их нет."""
    host, user, auth = text_field(body, "host", 253), text_field(body, "user", 32) or "root", text_field(body, "auth", 16)
    if not NODE_HOST.match(host):
        raise ValueError("хост: IPv4 или имя хоста (латиница, цифры, точка, дефис)")
    if not NODE_USER.match(user):
        raise ValueError("пользователь: строчная латиница, цифры, _ и -")
    try:
        port = int(body.get("port") or 22)
    except (TypeError, ValueError):
        port = 0
    if not 1 <= port <= 65535:
        raise ValueError("SSH-порт: число от 1 до 65535")

    if auth == "password":
        password = body.get("password", "")
        if not isinstance(password, str) or not password or len(password) > 1024 or "\n" in password:
            raise ValueError("пароль: обязателен, одной строкой")
        return host, port, user, ["--password-stdin"], (password + "\n").encode("utf-8")
    if auth == "key":
        key = body.get("key", "")
        if (not isinstance(key, str) or len(key) > 16384
                or ("PRIVATE KEY" not in key and "PuTTY" not in key)):
            raise ValueError("ключ: вставь приватный ключ OpenSSH целиком (-----BEGIN ... PRIVATE KEY-----)")
        return host, port, user, ["--key-stdin"], key.encode("utf-8")
    if auth == "installed":
        return host, port, user, ["--key-installed"], None
    raise ValueError("способ входа: пароль, ключ или ключ iof уже добавлен")


def node_add_steps(iof, body, existing):
    """Поля формы -> (заголовок задачи, шаги для Jobs). ValueError с текстом для формы."""
    name, addr, title = text_field(body, "name", 40), text_field(body, "addr", 253), text_field(body, "title", 64)
    if not NODE_NAME.match(name):
        raise ValueError("имя узла: латиница, цифры, точка, дефис, подчёркивание")
    if name in existing:
        raise ValueError(f"узел {name} уже есть в nodes.conf")
    host, port, user, auth_args, stdin = login_fields(body)
    if addr and not NODE_HOST.match(addr):
        raise ValueError("адрес для клиентов: IPv4 или имя хоста")
    if "|" in title:
        raise ValueError("подпись не может содержать |")

    argv = [iof, "node", "add", name, host, title, str(port), "--user", user, "--addr", addr or host, *auth_args]
    # В лог идёт команда без пароля и ключа: они уходят в iof через stdin
    steps = [(shlex.join(["iof", *argv[1:]]), argv, stdin)]
    if body.get("install_hy2"):
        steps.append((f"iof hy2 install {name}", [iof, "hy2", "install", name], None))
    return f"Добавление сервера {name} ({host})", steps


def migrate_steps(iof, body, migrate):
    """Кнопка на странице «Перенос» -> (заголовок задачи, шаги для Jobs). migrate — состояние
    из read_migrate. ValueError с текстом для формы."""
    action = body.get("action")
    role = migrate["role"] if migrate else ""
    if action == "start":
        if role == "target":
            raise ValueError("этот сервер сам принимает управление, сначала заверши тот перенос")
        host, port, user, auth_args, stdin = login_fields(body)
        self_target = text_field(body, "self", 300)
        if self_target and not SSH_TARGET.match(self_target):
            raise ValueError("адрес этого сервера: вид root@адрес или root@адрес:порт")
        argv = [iof, "migrate", "start", host, str(port), "--user", user, *auth_args]
        if self_target:
            argv += ["--self", self_target]
        return f"Перенос управления на {host}", [(shlex.join(["iof", *argv[1:]]), argv, stdin)]
    if action == "finish":
        if role != "target":
            raise ValueError("этот сервер не принимает управление")
        argv = [iof, "migrate", "finish", *(["--skip-old"] if body.get("skip_old") else [])]
        return "Завершение переноса", [(shlex.join(["iof", *argv[1:]]), argv, None)]
    if action == "cancel":
        if role != "source":
            raise ValueError("отсюда перенос не начат")
        argv = [iof, "migrate", "cancel"]
        return "Отмена переноса", [(shlex.join(["iof", *argv[1:]]), argv, None)]
    raise ValueError("неизвестное действие")


def step(iof, *args):
    """Шаг задачи без stdin: команда iof с аргументами и она же для лога."""
    return shlex.join(["iof", *args]), [iof, *args], None


# iof и так откажет, пока отсюда идёт перенос, но так ошибка видна сразу
def not_migrating(migrate):
    if migrate and migrate["role"] == "source":
        raise ValueError("идёт перенос управления на другой сервер, изменения здесь заблокированы")


def hy2_steps(iof, body, groups, migrate):
    """Кнопки групп на странице «Hysteria2» -> (заголовок задачи, шаги). groups — из read_index."""
    not_migrating(migrate)
    action = body.get("action")
    if action == "add":
        label = text_field(body, "label", 64)
        if not label:
            raise ValueError("подпись: обязательна")
        if any(c in label for c in "|\t\r\n"):
            raise ValueError("подпись не может содержать |")
        # Повтор с той же подписью пересобирает группу, как и в терминале
        verb = "Пересборка" if any(g["label"] == label for g in groups) else "Создание"
        return f"{verb} группы «{label}»", [step(iof, "hy2", "add", label)]
    if action == "del":
        name = text_field(body, "name", 100)
        group = next((g for g in groups if g["name"] == name), None)
        if not group or not SAFE_NAME.match(name):
            raise ValueError("нет такой группы")
        return f"Удаление группы «{group['label']}»", [step(iof, "hy2", "del", name)]
    if action == "refresh":
        return "Пересборка всех групп Hysteria2", [step(iof, "hy2", "refresh")]
    raise ValueError("неизвестное действие")


def node_steps(iof, body, conf, relays, hy2_template, migrate):
    """Кнопки на странице узла -> (имя узла, заголовок задачи, шаги). conf — строки nodes.conf."""
    name = text_field(body, "name", 40)
    if name not in {row[0] for row in conf}:
        raise ValueError(f"узла {name} нет в nodes.conf")
    action = body.get("action")
    # iof hy2 install и restart принимают шаблоны узлов, а all значит «все»
    if name == "all" and action != "delete":
        raise ValueError("узел с именем all так не выбрать, используй терминал")
    if action == "restart_hy2":
        return name, f"Перезапуск Hysteria2 на {name}", [step(iof, "hy2", "restart", name)]
    not_migrating(migrate)
    if action == "install_hy2":
        if not hy2_template.is_file():
            raise ValueError(f"нет шаблона {hy2_template} для установки Hysteria2")
        force = bool(body.get("force"))
        verb = "Переустановка" if force else "Установка"
        return name, f"{verb} Hysteria2 на {name}", [step(iof, "hy2", "install", name, *(["--force"] if force else []))]
    if action == "delete":
        used = next((r for r in relays if name in (r["node"], r["via"])), None)
        if used:
            raise ValueError(f"узел участвует в ретрансляторе {used['node']} через {used['via']}, "
                             f"сначала убери его: sudo iof relay del {used['node']} {used['via']}")
        # После удаления из nodes.conf ссылки и ключи AWG пересобираются уже без узла
        return name, f"Удаление узла {name}", [step(iof, "node", "del", name), step(iof, "refresh")]
    raise ValueError("неизвестное действие")


def service_steps(iof, body):
    """Кнопка «Обновить» на странице «Сервис». install.sh в конце перезапускает панель, а с ней
    и всё, что она запустила, поэтому iof update идёт отдельным юнитом systemd: он доработает,
    даже когда панель перезапустится. Лог идёт в задачу, пока панель жива."""
    if body.get("action") != "update":
        raise ValueError("неизвестное действие")
    argv = ["systemd-run", "--unit=iof-update", "--collect", "--quiet", "--wait", "--pipe",
            "--setenv=LC_ALL=C.UTF-8", iof, "update"]
    return "Обновление iof и панели", [("iof update", argv, None)]


# HTTP

def host_only(value):
    """Имя хоста из заголовка Host или Origin без схемы и порта, в нижнем регистре."""
    h = (value or "").strip().lower()
    if "://" in h:
        h = urlsplit(h).netloc
    if h.startswith("["):
        return h[1:h.find("]")] if "]" in h else ""
    return h.rsplit(":", 1)[0] if ":" in h else h


class Handler(BaseHTTPRequestHandler):
    server_version = "iof-web"
    sys_version = ""

    def do_GET(self):
        if not self.host_allowed() or not self.authorized():
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
        if url.path == "/api/nodes/add-info":
            return self.add_info()
        if url.path == "/api/migrate":
            return self.migrate_info()
        if url.path == "/api/node":
            return self.node_info(query.get("n", ""), force)
        if url.path == "/api/service":
            return self.service_info(query.get("fetch") == "1")
        if url.path == "/api/jobs":
            return self.send_json({"jobs": self.server.jobs.list()})
        if url.path in STATIC_FILES:
            return self.static(*STATIC_FILES[url.path])
        self.send_json({"error": "не найдено"}, HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if not self.host_allowed() or not self.authorized() or not self.same_origin():
            return
        path = urlsplit(self.path).path
        if path not in ("/api/nodes", "/api/migrate", "/api/hy2", "/api/node", "/api/service"):
            return self.send_json({"error": "не найдено"}, HTTPStatus.NOT_FOUND)
        body = self.read_json()
        if body is None:
            return
        try:
            kind, title, steps = self.job_for(path, body)
        except ValueError as e:
            return self.send_json({"error": str(e)}, HTTPStatus.BAD_REQUEST)
        job = self.server.jobs.start(title, steps, kind)
        if job is None:
            return self.send_json({"error": "уже идёт другая задача, дождись её окончания"}, HTTPStatus.CONFLICT)
        self.send_json({"job": job["id"]}, HTTPStatus.ACCEPTED)

    def job_for(self, path, body):
        """POST -> (вид задачи, заголовок, шаги). ValueError с текстом для страницы."""
        srv = self.server
        migrate = read_migrate(srv.base)
        if path == "/api/nodes":
            not_migrating(migrate)
            title, steps = node_add_steps(srv.iof, body, self.node_names())
            if body.get("install_hy2") and not srv.hy2_template.is_file():
                raise ValueError(f"нет шаблона {srv.hy2_template} для установки Hysteria2")
            return "node", title, steps
        if path == "/api/migrate":
            return ("migrate", *migrate_steps(srv.iof, body, migrate))
        if path == "/api/hy2":
            return ("hy2", *hy2_steps(srv.iof, body, read_index(srv.base / "hy2" / "index.tsv"), migrate))
        if path == "/api/node":
            name, title, steps = node_steps(srv.iof, body, read_conf(srv.base / "nodes.conf", 4),
                                            read_relays(srv.base), srv.hy2_template, migrate)
            return f"node:{name}", title, steps
        return ("service", *service_steps(srv.iof, body))

    # Защита от DNS rebinding: чужой домен, указывающий на 127.0.0.1, не получит ответ панели
    def host_allowed(self):
        if host_only(self.headers.get("Host")) in self.server.hosts:
            return True
        self.send_json({"error": "неизвестный Host, см. IOF_WEB_HOSTS"}, HTTPStatus.FORBIDDEN)
        return False

    # Защита от CSRF: менять что-то можно только со страниц самой панели. Свой заголовок
    # браузер не даст отправить с чужого сайта без preflight, а на него сервер не отвечает
    def same_origin(self):
        origin = self.headers.get("Origin")
        ok = (self.headers.get("X-IOF-Request") == "1"
              and self.headers.get("Content-Type", "").startswith("application/json")
              and (origin is None or host_only(origin) in self.server.hosts))
        if not ok:
            self.send_json({"error": "запрос не со страницы панели"}, HTTPStatus.FORBIDDEN)
        return ok

    def read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if not 0 < length <= 65536:
            self.send_json({"error": "пустой или слишком большой запрос"}, HTTPStatus.BAD_REQUEST)
            return None
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            body = None
        if not isinstance(body, dict):
            self.send_json({"error": "нужен JSON-объект"}, HTTPStatus.BAD_REQUEST)
            return None
        return body

    def node_names(self):
        return {r[0] for r in read_conf(self.server.base / "nodes.conf", 4)}

    def pubkey(self):
        try:
            return self.server.ssh_pub.read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    def add_info(self):
        self.send_json({
            "nodes": sorted(self.node_names()),
            "pubkey": self.pubkey(),
            "hy2_template": self.server.hy2_template.is_file(),
            "busy": self.server.jobs.busy(),
            "migrate": read_migrate(self.server.base),
        })

    # Справка для страницы «Перенос»: состояние переноса и адрес этого сервера как узла,
    # по нему новый сервер будет заходить сюда, если в форме не указано другое
    def migrate_info(self):
        nodes = read_conf(self.server.base / "nodes.conf", 4)
        local = [addr for _, addr, ssh, _ in nodes if (ssh or "local") == "local"]
        self.send_json({
            "migrate": read_migrate(self.server.base),
            "self_addr": local[0] if local else "",
            "nodes": len(nodes),
            "pubkey": self.pubkey(),
            "busy": self.server.jobs.busy(),
        })

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
            "migrate": read_migrate(base),
        })
        self.send_json(data)

    def hy2(self, force):
        data = self.server.cache.get(force)
        data.update({
            "generated_at": time.time(),
            "groups": read_hy2_groups(self.server.base),
            "qr": shutil.which("qrencode") is not None,
            "migrate": read_migrate(self.server.base),
        })
        self.send_json(data)

    # Страница узла: его состояние из общего опроса, строка nodes.conf, ретрансляторы с ним
    # и есть ли в группах Hysteria2 ссылка на него. Ссылки (в них пароль) не отдаются
    def node_info(self, name, force):
        base = self.server.base
        data = self.server.cache.get(force)
        nodes = data.pop("nodes")
        conf = next(({"name": n, "addr": a, "ssh": s or "local", "title": t or n}
                     for n, a, s, t in read_conf(base / "nodes.conf", 4) if n == name), None)
        title = conf["title"] if conf else name
        groups = [{"name": g["name"], "label": g["label"], "created": g["created"],
                   "has_link": any(not link["relay"] and link["node"] == title for link in g["links"])}
                  for g in read_hy2_groups(base)]
        data.update({
            "generated_at": time.time(),
            "name": name,
            "conf": conf,
            "node": next((n for n in nodes if n["name"] == name), None),
            "relays": [r for r in read_relays(base) if name in (r["node"], r["via"])],
            "hy2_groups": groups,
            "hy2_template": self.server.hy2_template.is_file(),
            "busy": self.server.jobs.busy(),
            "migrate": read_migrate(base),
        })
        self.send_json(data)

    # Страница «Сервис»: версия, клон, Telegram и cron от iof, итог iof check и логи ночного
    # обслуживания из файлов. fetch: ещё и git fetch, чтобы узнать, есть ли обновления
    def service_info(self, fetch):
        base = self.server.base
        info, error = iof_api(self.server.iof, ["api", "service"], 20)
        data = {
            "version": info.get("version", ""),
            "src": info.get("src", ""),
            "src_version": info.get("src_version", ""),
            "tg": info.get("tg") == "yes",
            "cron": info.get("cron", []),
            "error": error,
            "check": read_check(base),
            "nightly": read_nightly_run(NIGHTLY_RUN_LOG),
            "nightly_local": read_nightly_local(NIGHTLY_LOG),
            "busy": self.server.jobs.busy(),
            "migrate": read_migrate(base),
        }
        if fetch:
            upd, err = iof_api(self.server.iof, ["api", "updates"], 60)
            data["updates"] = {
                "error": err,
                "branch": upd.get("branch", ""),
                "commits": [dict(zip(("hash", "date", "subject"), c.split("\t", 2))) for c in upd.get("commit", [])],
            }
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

    # Имена, по которым панель открывают в браузере. Через SSH-туннель это 127.0.0.1 или
    # localhost; за nginx с доменом добавь домен в IOF_WEB_HOSTS (через запятую)
    hosts = {"127.0.0.1", "localhost", "::1", host.lower()}
    hosts |= {host_only(h) for h in os.environ.get("IOF_WEB_HOSTS", "").split(",") if h.strip()}

    srv = ThreadingHTTPServer((host, int(port)), Handler)
    srv.daemon_threads = True
    srv.base = Path(args.base)
    srv.iof = args.iof
    srv.password = password
    srv.hosts = hosts
    srv.ssh_pub = Path(os.environ.get("IOF_SSH_KEY", "/root/.ssh/iof_ed25519") + ".pub")
    srv.hy2_template = Path(os.environ.get("HY2_TEMPLATE", "/etc/hysteria/config.yaml"))
    srv.cache = StatusCache(args.iof, args.ttl)
    srv.jobs = Jobs(on_done=srv.cache.invalidate)
    print(f"iof-web: http://{args.listen}/", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
