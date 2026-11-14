#!/usr/bin/env python3
"""iof-web: веб-панель для iof (Island of Freedom).

Работает на управляющем сервере от root. Состояние узлов берёт из `iof api status`,
списки ретрансляторов, групп Hysteria2 и клиентов AWG читает из /root/iof напрямую.
Ссылки Hysteria2 (в них пароль) отдаёт на странице hy2, ключи и конфиги AWG не отдаёт.
Меняет что-то только через команды iof (добавление сервера: iof node add, iof hy2 install;
группы ссылок: iof hy2 add | del | refresh; действия с узлом: iof hy2 restart | install, iof node del;
обновление: iof update; перенос управляющего сервера: iof migrate; проверка безопасности:
iof audit run, она узлы только читает; проверка с ПК: iof audit probe), по одной задаче за раз,
с логом выполнения. Исключения — терминал на узел со страницы узла (ssh с ключом iof через
WebSocket, включается отдельно, IOF_WEB_TERMINAL=1) и страница «Телеграм бот»: её команды iof bot
быстрые и узлы не трогают, поэтому идут сразу, а не задачей. Скрипт проверки с ПК и его отчёт ходят
по одноразовому билету вместо пароля панели. Telegram-бот (iof_bot.py рядом) работает потоком
внутри панели; включает его iof bot on, без модуля панель работает как раньше. Данные страниц
бот берёт у панели (BotViews): тот же разбор, ссылки Hysteria2 — отдельным методом и только админу.
Действия бота (BotActions) — задачи в той же очереди с теми же шагами, что у кнопок панели.

Без зависимостей, нужен только python3. По умолчанию слушает 127.0.0.1:8088,
снаружи заходить через SSH-туннель:  ssh -L 8088:127.0.0.1:8088 admin@сервер

Запуск:  python3 iof-web.py [--listen 127.0.0.1:8088] [--iof /usr/local/bin/iof]
Пароль:  переменная IOF_WEB_PASSWORD (HTTP Basic, имя пользователя любое).
Слушать не на loopback без пароля сервер откажется.
"""

import argparse
import base64
import fcntl
import hashlib
import hmac
import ipaddress
import json
import os
import pwd
import re
import secrets
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import termios
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

# Telegram-бот: модуль рядом с панелью. Если он не загрузился, панель работает без бота
try:
    import iof_bot
    BOT_IMPORT_ERROR = None
except Exception as e:  # ошибка в модуле бота не должна ронять панель
    iof_bot = None
    BOT_IMPORT_ERROR = f"{type(e).__name__}: {e}"

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
    "/security.html": ("security.html", "text/html; charset=utf-8"),
    "/security.js": ("security.js", "text/javascript; charset=utf-8"),
    "/bot.html": ("bot.html", "text/html; charset=utf-8"),
    "/bot.js": ("bot.js", "text/javascript; charset=utf-8"),
    "/term.js": ("term.js", "text/javascript; charset=utf-8"),
    "/xterm.js": ("xterm.js", "text/javascript; charset=utf-8"),
    "/xterm-fit.js": ("xterm-fit.js", "text/javascript; charset=utf-8"),
    "/xterm.css": ("xterm.css", "text/css; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
}

# Логи ночного обслуживания: запуск с управляющего сервера и сама работа на этом сервере как узле
NIGHTLY_RUN_LOG = Path("/var/log/iof-nightly-run.log")
NIGHTLY_LOG = Path("/var/log/iof-nightly.log")
# Вывод iof update, запущенного из панели: панель перезапускается раньше, чем покажет его целиком
UPDATE_LOG = Path("/var/log/iof-update.log")

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
            "range": r.get("hy2_range", ""),
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
            if self.usable(force):
                return dict(self.data, cached=True)
            self.data = self.probe()
            return dict(self.data, cached=False)

    def usable(self, force):
        age = time.time() - self.data["status_at"] if self.data else None
        # Принудительное обновление не чаще раза в 5 секунд
        return age is not None and (age < 5 or (not force and age < self.ttl))

    def fresh(self, force=False):
        """Ответит ли get(force) сразу, без опроса узлов. Не ждёт: если опрос уже идёт, ответ — нет.
        По нему бот решает, писать ли сначала «опрашиваю узлы…»."""
        if not self.lock.acquire(blocking=False):
            return False
        try:
            return self.usable(force)
        finally:
            self.lock.release()

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


HY2_PORTS = re.compile(r"^[0-9]+([,-][0-9]+)*$")


def parse_hy2_link(url):
    """hy2://пароль@хост:порт/?...#Подпись%20%7C%20Узел -> поля для страницы без пароля. У группы
    со сменой портов порт — список «443,10000-19999»: urlsplit его не разбирает, он берётся строкой."""
    u = urlsplit(url)
    title = unquote(u.fragment)
    node = title.split(" | ", 1)[1] if " | " in title else title
    hostport = u.netloc.rsplit("@", 1)[-1]
    host, _, ports = hostport.rpartition(":")
    if not host or not HY2_PORTS.match(ports):
        host, ports = hostport, ""
    return {"url": url, "title": title, "node": node, "host": host.strip("[]"),
            "port": ports or None, "hop": "," in ports or "-" in ports, "relay": " via " in node}


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
        # Метка iof hy2 add --hop: в ссылках группы список портов
        g["hop"] = (base / "hy2" / f"{g['name']}.hop").exists()
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


def qr_png(text, level="M"):
    """PNG с QR-кодом через qrencode, для Telegram-бота: SVG он в фото не принимает. None, если
    qrencode нет или текст не помещается. Текст (ссылка с паролем) идёт через stdin."""
    exe = shutil.which("qrencode")
    if not exe:
        return None
    try:
        p = subprocess.run([exe, "-t", "PNG", "-l", level, "-m", "2", "-s", "8", "-o", "-"],
                           input=text.encode("utf-8"), capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout if p.returncode == 0 and p.stdout.startswith(b"\x89PNG") else None


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


def read_update_log(path):
    """Последний iof update из панели: {at (unix), lines} или None."""
    lines = tail_lines(path, 32768)
    if lines is None:
        return None
    try:
        at = path.stat().st_mtime
    except OSError:
        return None
    return {"at": at, "lines": [ANSI.sub("", line) for line in lines][-120:]}


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


def iof_json(iof, args, timeout):
    """Вывод iof api ... в виде JSON (iof api audit) -> (объект, ошибка или None)."""
    env = dict(os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8")
    try:
        p = subprocess.run([iof, *args], capture_output=True, timeout=timeout, env=env, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        return {}, f"не найден {iof}"
    except subprocess.TimeoutExpired:
        return {}, f"iof {' '.join(args)} не уложился в {timeout} секунд"
    if p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace").strip().splitlines()
        return {}, (err[-1] if err else f"iof завершился с кодом {p.returncode}").removeprefix("Ошибка: ")
    try:
        data = json.loads(p.stdout.decode("utf-8", "replace"))
    except ValueError:
        data = None
    if not isinstance(data, dict):
        return {}, f"iof {' '.join(args)} вернул не JSON"
    return data, None


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
        """steps: [(подпись для лога, argv, stdin bytes или None[, коды выхода «выполнено с проблемами»])],
        kind: по нему страница находит свои задачи (node, migrate, hy2, service, audit, node:<имя>,
        bot — задачи Telegram-бота). None, если занято."""
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
            for label, argv, stdin, *extra in steps:
                # iof check выходит с кодом 1, если на узлах проблемы: это итог проверки, а не ошибка.
                # Но с «Ошибка: …» в выводе (die, n_err) тот же код — настоящая ошибка
                warn_rc, failed = (extra[0] if extra else ()), False
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
                        failed = failed or line.startswith("Ошибка")
                    rc = p.wait()
                finally:
                    timer.cancel()
                if rc != 0 and rc in warn_rc and not failed:
                    state = "warn"
                elif rc != 0:
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
        # Повтор с той же подписью пересобирает группу, как и в терминале. hop: true или false
        # включает или выключает список портов в ссылках группы, без него остаётся как было
        hop = body.get("hop")
        if hop is not None and not isinstance(hop, bool):
            raise ValueError("hop: true или false")
        extra = [] if hop is None else ["--hop" if hop else "--no-hop"]
        if hop is not None:
            verb = "Список портов в ссылках: " + ("включение" if hop else "выключение") + ", группа"
        else:
            verb = "Пересборка группы" if any(g["label"] == label for g in groups) else "Создание группы"
        return f"{verb} «{label}»", [step(iof, "hy2", "add", label, *extra)]
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
    даже когда панель перезапустится. Лог идёт в задачу, пока панель жива, и в UPDATE_LOG целиком:
    tee -p продолжает писать в файл, когда читать из трубы уже некому."""
    if body.get("action") != "update":
        raise ValueError("неизвестное действие")
    script = f"set -o pipefail; {shlex.quote(iof)} update 2>&1 | tee -p {shlex.quote(str(UPDATE_LOG))}"
    argv = ["systemd-run", "--unit=iof-update", "--collect", "--quiet", "--wait", "--pipe",
            "--setenv=LC_ALL=C.UTF-8", "/bin/bash", "-c", script]
    return "Обновление iof и панели", [("iof update", argv, None)]


# Блоки страницы «Безопасность», которые умеет проверять iof audit run
AUDIT_BLOCKS = {"server": "Аудит сервера", "dpi": "Защита от РКН"}

# Действия из проверок блока «Защита от РКН»: iof сам меняет узел. Всегда на одном узле,
# после действия узел проверяется заново, чтобы проверка показала новое состояние
AUDIT_ACTIONS = {
    "hop_on": ("Смена портов Hysteria2: включение", ("hy2", "hop", "on")),
    "hop_off": ("Смена портов Hysteria2: выключение", ("hy2", "hop", "off")),
    "hy2_upgrade": ("Обновление Hysteria2", ("hy2", "upgrade")),
    "block_on": ("Блок-лист сканеров: применение", ("block", "on")),
    "block_update": ("Блок-лист сканеров: обновление", ("block", "update")),
    "block_off": ("Блок-лист сканеров: снятие", ("block", "off")),
}


def audit_steps(iof, body, nodes, migrate):
    """Кнопки «Проверить» и действия в проверках на странице «Безопасность» -> (заголовок задачи,
    шаги). nodes — имена из nodes.conf. Проверка узлы не меняет и идёт во время переноса управления,
    действия меняют, поэтому при переносе запрещены и выполняются только на одном узле."""
    action = body.get("action")
    if action is not None:
        if action not in AUDIT_ACTIONS:
            raise ValueError("неизвестное действие")
        not_migrating(migrate)
        name = text_field(body, "node", 40)
        # iof принимает шаблоны узлов, а all значит «все»: из панели — только один узел по имени
        if not name or name not in nodes or name == "all":
            raise ValueError("выбери узел из nodes.conf")
        title, args = AUDIT_ACTIONS[action]
        return f"{title}, {name}", [step(iof, *args, name), step(iof, "-n", name, "audit", "run", "dpi")]
    block, name = body.get("block"), text_field(body, "node", 40)
    if block not in AUDIT_BLOCKS:
        raise ValueError("неизвестный блок проверок")
    if not name:
        return f"{AUDIT_BLOCKS[block]}: все узлы", [step(iof, "audit", "run", block)]
    # iof -n принимает шаблоны, а all значит «все»
    if name not in nodes or name == "all":
        raise ValueError(f"узла {name} нет в nodes.conf")
    return f"{AUDIT_BLOCKS[block]}: {name}", [step(iof, "-n", name, "audit", "run", block)]


def check_steps(iof):
    """Проверка всех узлов, как по cron (команда /check бота, в панели кнопки нет): состояние в state/,
    итог в check.last, изменения в Telegram. Узлы не меняет, поэтому идёт и во время переноса.
    Код 1 — на узлах проблемы: задача тогда warn, а не error."""
    return "Проверка всех узлов (iof check)", [(*step(iof, "check"), (1,))]


def action_steps(srv, kind, body):
    """Кнопки панели и действия Telegram-бота -> (вид задачи, заголовок, шаги). kind: hy2 (группы ссылок),
    node (действия с узлом), audit (проверка и действия «Безопасности»), check. body — тело запроса
    страницы. ValueError с текстом для страницы и бота, в том числе при переносе."""
    migrate = read_migrate(srv.base)
    if kind == "hy2":
        return ("hy2", *hy2_steps(srv.iof, body, read_index(srv.base / "hy2" / "index.tsv"), migrate))
    if kind == "node":
        name, title, steps = node_steps(srv.iof, body, read_conf(srv.base / "nodes.conf", 4),
                                        read_relays(srv.base), srv.hy2_template, migrate)
        return f"node:{name}", title, steps
    if kind == "audit":
        names = {r[0] for r in read_conf(srv.base / "nodes.conf", 4)}
        return ("audit", *audit_steps(srv.iof, body, names, migrate))
    if kind == "check":
        return ("check", *check_steps(srv.iof))
    raise ValueError("неизвестное действие")


# Проверка доступности узлов с ПК (iof audit probe). Страница запускает мишени задачей Jobs и
# получает одноразовый билет. По билету скрипт probe.ps1 забирается один раз (в него вписываются
# мишени, их отпечатки, токен и сам билет) и один раз сдаёт сырой отчёт. Пароль панели на этих
# двух адресах не спрашивается: PowerShell его не знает, вместо него билет. Отчёт уходит в
# iof audit probe import задачей Jobs после остановки мишеней, а если Jobs занят, ждёт в памяти

PROBE_SCRIPT = Path(__file__).resolve().parent / "probe.ps1"
PROBE_PLACEHOLDER = "__IOF_PROBE_CONFIG__"
PANEL_ORIGIN = re.compile(r"^https?://[A-Za-z0-9.:\[\]-]+$")


class Probes:
    MAX_REPORT = 262144  # байт в отчёте
    GRACE = 300          # секунд после конца мишеней, пока отчёт ещё принимается
    START_WAIT = 600     # секунд на запуск мишеней, пока сессии ещё нет

    def __init__(self, base):
        self.dir = base / "audit" / "probe"
        self.lock = threading.Lock()
        self.s = None  # проверка, начатая из панели: билет, адрес панели, что уже забрано

    def session(self):
        """session.json от iof audit probe start или None."""
        try:
            data = json.loads((self.dir / "session.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) and isinstance(data.get("nodes"), dict) else None

    def mine(self, s, sess):
        """Сессия iof создана этой проверкой панели, а не раньше неё или из терминала."""
        return bool(s and sess and sess.get("started", 0) >= s["created"] - 5)

    def active(self):
        sess, now = self.session(), time.time()
        with self.lock:
            s = self.s
            if not s or s["result_at"] or s["cancelled"]:
                return False
            if self.mine(s, sess):
                return not sess.get("stopped") and now < sess.get("expires", 0) + self.GRACE
            return now < s["created"] + self.START_WAIT

    def begin(self, origin, job):
        ticket = secrets.token_urlsafe(24)
        with self.lock:
            self.s = {"ticket": ticket, "origin": origin, "created": time.time(), "start_job": job,
                      "script_at": None, "result_at": None, "pending": None, "job": None, "cancelled": False}
        return ticket

    def cancel(self):
        with self.lock:
            if self.s:
                self.s["cancelled"] = True
                self.s["pending"] = None

    def check(self, ticket):
        """Билет текущей проверки -> (проверка, сессия) или текст отказа."""
        sess = self.session()
        s = self.s
        if not s or not ticket or not hmac.compare_digest(ticket.encode(), s["ticket"].encode()):
            return "билет проверки неверный или устарел"
        if s["cancelled"]:
            return "проверку остановили, начни новую на странице «Безопасность»"
        if not self.mine(s, sess):
            return None
        return s, sess

    def take_script(self, ticket):
        """Скрипт по билету один раз -> текст или (код, ошибка)."""
        try:
            template = PROBE_SCRIPT.read_text(encoding="utf-8")
            token = (self.dir / "token").read_text(encoding="utf-8").strip()
        except OSError:
            template, token = "", ""
        with self.lock:
            got = self.check(ticket)
            if isinstance(got, str):
                return HTTPStatus.FORBIDDEN, got
            if got is None:
                return HTTPStatus.CONFLICT, "мишени ещё запускаются: подожди окончания задачи и повтори"
            s, sess = got
            if s["script_at"]:
                return HTTPStatus.FORBIDDEN, "скрипт по этому билету уже выдан: начни новую проверку"
            if sess.get("stopped") or time.time() > sess.get("expires", 0):
                return HTTPStatus.FORBIDDEN, "мишени уже остановлены: начни новую проверку"
            if PROBE_PLACEHOLDER not in template or not token:
                return HTTPStatus.INTERNAL_SERVER_ERROR, f"нет {PROBE_SCRIPT} или токена мишеней, переустанови панель: sudo iof update"
            s["script_at"] = time.time()
        cfg = {
            "v": 1, "session": sess["id"], "expires": sess["expires"], "origin": s["origin"], "ticket": s["ticket"],
            "token": token, "lists": sess.get("lists", {}),
            "targets": [{"node": name, "addr": n.get("addr", ""), "ip": n.get("ip", ""), "port": n.get("port", 0),
                         "fp": n.get("fp", ""), "hy2": n.get("hy2_port") or 0}
                        for name, n in sess["nodes"].items() if n.get("state") == "started"],
        }
        # base64 из JSON только с ASCII: Windows PowerShell 5.1 читает скрипт без BOM не как UTF-8
        blob = base64.b64encode(json.dumps(cfg, ensure_ascii=True).encode("ascii")).decode("ascii")
        return template.replace(PROBE_PLACEHOLDER, blob, 1)

    def accept(self, ticket, report):
        """Отчёт по билету один раз. None или текст отказа."""
        with self.lock:
            got = self.check(ticket)
            if not isinstance(got, tuple):
                return got or "мишени ещё запускаются"
            s, sess = got
            if not s["script_at"]:
                return "по этому билету скрипт не выдавался"
            if s["result_at"]:
                return "отчёт по этому билету уже принят"
            if report.get("session") != sess.get("id"):
                return "отчёт от другой проверки"
            if time.time() > sess.get("expires", 0) + self.GRACE:
                return "проверка закончилась давно, отчёт больше не принимается: sudo iof audit probe import < файл"
            s["result_at"] = time.time()
            s["pending"] = json.dumps(report, ensure_ascii=False).encode("utf-8")
        return None

    def kick(self, jobs, iof):
        """Отчёт, ожидающий своей очереди, в задачу: остановить мишени, затем import. Так мишени
        не переживут проверку, даже если import откажет."""
        with self.lock:
            s = self.s
            if not s or not s["pending"]:
                return
            report = s["pending"]
            job = jobs.start("Проверка с ПК: результат", [step(iof, "audit", "probe", "stop"),
                             ("iof audit probe import < отчёт с ПК", [iof, "audit", "probe", "import"], report)], "probe")
            if job:
                s["pending"], s["job"] = None, job["id"]

    def state(self):
        """Состояние для страницы: сессия iof без токена и отпечатков, билет, пока скрипт не забран."""
        sess, now = self.session(), time.time()
        with self.lock:
            s = dict(self.s) if self.s else None
        mine = self.mine(s, sess)
        pub = None
        if sess:
            pub = {k: sess.get(k) for k in ("id", "started", "expires", "stopped")}
            pub["nodes"] = {name: {k: n.get(k) for k in ("addr", "state", "port", "fw", "error", "local", "check")}
                            for name, n in sess["nodes"].items()}
        out = {"session": pub, "now": now, "panel": None}
        if s and not s["cancelled"]:
            live = mine and not sess.get("stopped") and now < sess.get("expires", 0)
            out["panel"] = {
                "mine": mine, "origin": s["origin"], "start_job": s["start_job"], "job": s["job"],
                "ticket": s["ticket"] if (live or not mine) and not s["script_at"] else None,
                "script_at": s["script_at"], "result_at": s["result_at"], "pending": bool(s["pending"]),
            }
        return out


# Страница «Телеграм бот». bot.json панель читает сама, а меняет только iof bot, и не задачей Jobs:
# команды быстрые и узлы не трогают, а настройки не должны ждать, пока идёт hy2 install. Токен уходит
# в iof bot token через stdin, панель его не отдаёт и не пишет в журнал, от токена только «есть или нет».
# Код приглашения страница получает один раз, в ответе на POST; на сервере остаётся только его хэш

BOT_ROLES = ("main", "regular")
BOT_TOKEN = re.compile(r"^[0-9]{1,20}:[A-Za-z0-9_-]{20,100}$")
BOT_CLOCK = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
BOT_CODE = re.compile(r"^[0-9a-f]{64}$", re.M)
BOT_HASH = 12  # знаков хэша приглашения на странице, как в iof bot show: по ним приглашение и отзывают
# Типы уведомлений, как NOTIFY в BOT_PY iof.sh (сверяет ci/lint.sh); admins — только главным
BOT_NOTIFY = ("nodes", "audit", "nightly", "updates", "ru", "admins")
BOT_NOTIFY_MAIN = ("admins",)


def bot_kinds(role):
    return [k for k in BOT_NOTIFY if role == "main" or k not in BOT_NOTIFY_MAIN]


def bot_admin(a):
    username = a.get("username")
    role = a.get("role") if a.get("role") in BOT_ROLES else "regular"
    notify = a.get("notify")
    return {
        "id": a["id"],
        "name": a.get("name") if isinstance(a.get("name"), str) else "",
        "username": username if isinstance(username, str) and re.match(r"^[A-Za-z0-9_]{1,32}$", username) else "",
        "role": role,
        "sound": a.get("sound") is True,
        # null — по умолчанию, то есть ничего; типы, недоступные роли, не приходят и не показываются
        "notify": [k for k in bot_kinds(role) if k in notify] if isinstance(notify, list) else None,
        "added": a.get("added") if isinstance(a.get("added"), (int, float)) else None,
    }


def read_bot(base):
    """bot.json для страницы -> (настройки, ошибка или None). Поля по умолчанию как у iof bot,
    от приглашения только начало хэша, истёкшие не показываются (iof выбросит их при записи)."""
    path = base / "bot.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        data = {}
    except (OSError, ValueError) as e:
        return None, f"{path} не читается ({e}): исправь его или удали и настрой бота заново"
    if not isinstance(data, dict):
        return None, f"{path}: нужен JSON-объект, исправь его или удали"
    quiet = data.get("quiet")
    if not (isinstance(quiet, dict) and all(BOT_CLOCK.match(str(quiet.get(k, ""))) for k in ("from", "to"))):
        quiet = None
    now = time.time()
    admins = data.get("admins") if isinstance(data.get("admins"), list) else []
    invites = data.get("invites") if isinstance(data.get("invites"), list) else []
    return {
        "enabled": data.get("enabled") is True,
        "username": data.get("username") if isinstance(data.get("username"), str) else "",
        "actions": data.get("actions") is True,
        "hy2_links": data.get("hy2_links", True) is True,
        "quiet": {"from": quiet["from"], "to": quiet["to"]} if quiet else None,
        "admins": [bot_admin(a) for a in admins if isinstance(a, dict) and type(a.get("id")) is int],
        "invites": sorted(({"hash": str(i.get("hash", ""))[:BOT_HASH],
                            "role": i.get("role") if i.get("role") in BOT_ROLES else "regular",
                            "created": i.get("created"), "expires": i["expires"]}
                           for i in invites if isinstance(i, dict) and isinstance(i.get("expires"), (int, float))
                           and i["expires"] > now), key=lambda i: i["expires"]),
    }, None


def bot_flag(body, key):
    v = body.get(key)
    if not isinstance(v, bool):
        raise ValueError(f"{key}: true или false")
    return "on" if v else "off"


def bot_admin_id(body):
    uid = body.get("id")
    if type(uid) is not int or not 0 < uid < 10 ** 16:
        raise ValueError("ID админа: число")
    return str(uid)


def bot_args(body):
    """POST /api/bot -> (аргументы iof bot, stdin или None, токен для вычистки из ответа или "").
    ValueError с текстом для страницы. iof проверяет всё ещё раз сам."""
    action = body.get("action")
    if action == "token":
        if body.get("delete") is True:
            return ["token"], b"\n", ""
        token = body.get("token", "")
        if not isinstance(token, str) or len(token) > 200:
            raise ValueError("токен: строка")
        token = token.strip()
        if not BOT_TOKEN.match(token):
            raise ValueError("это не токен бота: он выглядит как 123456789:AAF… (@BotFather, /mybots → API Token)")
        return ["token"], (token + "\n").encode(), token
    if action == "enable":
        return [bot_flag(body, "on")], None, ""
    if action == "set":
        key = body.get("key")
        if key in ("actions", "links"):
            return ["set", key, bot_flag(body, "on")], None, ""
        if key == "quiet":
            value = body.get("value")
            if value != "off":
                parts = value.split("-") if isinstance(value, str) else []
                if len(parts) != 2 or not all(BOT_CLOCK.match(p) for p in parts):
                    raise ValueError("тихие часы: ЧЧ:ММ-ЧЧ:ММ, например 23:00-08:00, или off")
                if parts[0] == parts[1]:
                    raise ValueError("у тихих часов начало и конец совпадают")
            return ["set", "quiet", value], None, ""
        raise ValueError("неизвестная настройка")
    if action == "invite":
        role = body.get("role")
        if role not in BOT_ROLES:
            raise ValueError("роль: main или regular")
        return ["invite", role], None, ""
    if action == "invite_del":
        prefix = text_field(body, "hash", 64).lower()
        if not re.match(r"^[0-9a-f]{6,64}$", prefix):
            raise ValueError("хэш приглашения: хотя бы 6 знаков hex")
        return ["invite", "del", prefix], None, ""
    if action == "admin_set":
        uid = bot_admin_id(body)
        if "role" in body:
            if body["role"] not in BOT_ROLES:
                raise ValueError("роль: main или regular")
            return ["admin", "set", uid, "role", body["role"]], None, ""
        if "notify" in body:
            kinds = body["notify"]
            if not isinstance(kinds, list) or not all(k in BOT_NOTIFY for k in kinds):
                raise ValueError("уведомления: список типов из " + ", ".join(BOT_NOTIFY))
            return ["admin", "set", uid, "notify", ",".join(k for k in BOT_NOTIFY if k in kinds) or "off"], None, ""
        return ["admin", "set", uid, "sound", bot_flag(body, "sound")], None, ""
    if action == "admin_del":
        return ["admin", "del", bot_admin_id(body)], None, ""
    raise ValueError("неизвестное действие")


def bot_notify(base):
    """Куда идут уведомления iof для страниц «Сервис» и «Безопасность»: через бота (включён, есть токен,
    сервер не принимает управление при переносе) — {username, subs: {тип: сколько админов подписано}},
    иначе None, и iof шлёт узлы и аудит в TG_CHAT из iof.env, если он задан."""
    cfg, _ = read_bot(base)
    try:
        token = (base / "bot.token").stat().st_size > 0
    except OSError:
        token = False
    if not cfg or not cfg["enabled"] or not token or (read_migrate(base) or {}).get("role") == "target":
        return None
    return {"username": cfg["username"],
            "subs": {k: sum(1 for a in cfg["admins"] if k in (a["notify"] or [])) for k in BOT_NOTIFY}}


def read_daily(base):
    """check.daily (раз в сутки из iof check, key=value) -> {at, updates, ru} или None. updates — сколько
    коммитов принесёт iof update, None — не проверено; ru — доступ к российским серверам с узлов или None."""
    try:
        lines = (base / "check.daily").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    kv = dict(line.split("=", 1) for line in lines if "=" in line)
    if not kv.get("time", "").isdigit():
        return None
    ru = None
    if kv.get("ru_time", "").isdigit() and not kv.get("ru_off"):
        ru = {"at": int(kv["ru_time"]), "nodes": to_int(kv.get("ru_nodes")), "cut": kv.get("ru_cut", "").split(),
              "noinet": kv.get("ru_noinet", "").split(), "down": kv.get("ru_down", "").split()}
    return {"at": int(kv["time"]), "updates": to_int(kv["updates"]) if kv.get("updates", "").isdigit() else None,
            "ru": ru, "ru_off": bool(kv.get("ru_off"))}


def iof_bot_cmd(iof, args, stdin):
    """iof bot <args> -> (вывод, текст ошибки или None). Секреты только в stdin."""
    env = dict(os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8")
    io = {"input": stdin} if stdin is not None else {"stdin": subprocess.DEVNULL}
    try:
        p = subprocess.run([iof, "bot", *args], capture_output=True, timeout=40, env=env, **io)
    except FileNotFoundError:
        return "", f"не найден {iof}"
    except subprocess.TimeoutExpired:
        return "", f"iof bot {args[0]} не уложился в 40 секунд"
    out = p.stdout.decode("utf-8", "replace")
    if p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace").strip().splitlines()
        line = next((s for s in err if s.startswith("Ошибка: ")), err[-1] if err else f"iof завершился с кодом {p.returncode}")
        return out, line.removeprefix("Ошибка: ")
    return out, None


# Терминал на узел со страницы узла: xterm.js в браузере, WebSocket к панели, на сервере ssh на узел
# (для local — оболочка root) в псевдотерминале. Выключен, пока в web.env нет IOF_WEB_TERMINAL=1:
# это root-доступ ко всем узлам из браузера

# Адрес SSH из nodes.conf: [пользователь@]хост[:порт], как его разбирает split_target в iof
TERM_SSH = re.compile(r"^((?:[a-z_][a-z0-9_-]{0,31}@)?[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?)(?::([0-9]{1,5}))?$")
# Билет терминала в адресе WebSocket: в журнал панели он не попадает
TICKET_IN_URL = re.compile(r"([?&]t=)[^&\s\"]+")
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS_TEXT, WS_BINARY, WS_CLOSE, WS_PING, WS_PONG = 0x1, 0x2, 0x8, 0x9, 0xA


def ws_accept(key):
    """Sec-WebSocket-Accept для ключа из рукопожатия (RFC 6455, 4.2.2)."""
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


def ws_unmask(data, mask):
    # Кадры от браузера всегда под маской из 4 байт. XOR сразу всего кадра как одного большого числа:
    # цикл по байтам на вставке длинного текста заметно медленнее
    n = len(data)
    if not n:
        return data
    key = (mask * (n // 4 + 1))[:n]
    return (int.from_bytes(data, "little") ^ int.from_bytes(key, "little")).to_bytes(n, "little")


class WebSocket:
    """WebSocket поверх соединения обработчика после рукопожатия, ровно то, что нужно терминалу:
    сообщения целиком, ping и close. Отправлять можно из двух потоков сразу."""

    MAX_MESSAGE = 1 << 20

    def __init__(self, rfile, wfile):
        self.rfile, self.wfile = rfile, wfile
        self.lock = threading.Lock()
        self.closed = False

    def read(self, n):
        data = self.rfile.read(n)
        if len(data) < n:
            raise EOFError
        return data

    def recv(self):
        """Следующее сообщение (opcode, байты) или None: соединение закрыто, оборвалось или
        молчит дольше таймаута сокета."""
        opcode, parts, size = None, [], 0
        try:
            while True:
                b1, b2 = self.read(2)
                op, n = b1 & 0x0F, b2 & 0x7F
                if n == 126:
                    n = struct.unpack(">H", self.read(2))[0]
                elif n == 127:
                    n = struct.unpack(">Q", self.read(8))[0]
                size += n
                # Кадр без маски браузер не пришлёт (RFC 6455, 5.1)
                if not b2 & 0x80 or size > self.MAX_MESSAGE:
                    self.close(1002 if not b2 & 0x80 else 1009)
                    return None
                mask = self.read(4)
                payload = ws_unmask(self.read(n), mask)
                # Управляющие кадры могут прийти и между частями сообщения
                if op == WS_CLOSE:
                    self.close()
                    return None
                if op == WS_PING:
                    self.send(WS_PONG, payload)
                    continue
                if op == WS_PONG:
                    continue
                if op:
                    opcode = op
                parts.append(payload)
                if b1 & 0x80:
                    return opcode, b"".join(parts)
        except (EOFError, OSError, struct.error):
            return None

    def send(self, opcode, payload=b""):
        n = len(payload)
        if n < 126:
            head = struct.pack(">BB", 0x80 | opcode, n)
        elif n < 1 << 16:
            head = struct.pack(">BBH", 0x80 | opcode, 126, n)
        else:
            head = struct.pack(">BBQ", 0x80 | opcode, 127, n)
        with self.lock:
            if self.closed:
                return False
            try:
                self.wfile.write(head + payload)
            except OSError:
                self.closed = True
                return False
            if opcode == WS_CLOSE:
                self.closed = True
            return True

    def send_json(self, obj):
        return self.send(WS_TEXT, json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def close(self, code=1000):
        self.send(WS_CLOSE, struct.pack(">H", code))


def term_size_ok(cols, rows):
    return isinstance(cols, int) and isinstance(rows, int) and 2 <= cols <= 500 and 2 <= rows <= 200


def set_winsize(fd, cols, rows):
    # Ядро само пришлёт SIGWINCH процессам терминала: ssh передаст новый размер на узел
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def write_all(fd, data):
    while data:
        data = data[os.write(fd, data):]


class Terminals:
    """Терминалы со страницы узла. Браузер берёт одноразовый билет запросом POST /api/term (там
    обычная защита панели от CSRF, а на WebSocket браузер свой заголовок поставить не даёт) и с ним
    открывает WebSocket /api/term/ws. От браузера: двоичные сообщения — нажатия клавиш, текстовые —
    JSON resize или ping. К браузеру: двоичные — вывод терминала, текстовое exit — процесс завершился.
    Что набирают в терминале, панель не записывает: в журнал идут только открытие и закрытие."""

    MAX = 4          # терминалов одновременно, вместе с выданными билетами
    TICKET_TTL = 30  # секунд на то, чтобы открыть WebSocket по билету
    ALIVE = 90       # секунд без сообщений от браузера (ping он шлёт раз в 25 с): связь пропала

    def __init__(self, enabled, ssh_key):
        self.enabled = enabled
        self.ssh_key = ssh_key
        self.lock = threading.Lock()
        self.tickets = {}
        self.active = 0

    def issue(self, name, ssh, cols, rows):
        """Билет на терминал узла. ValueError с текстом для страницы."""
        if ssh != "local" and not TERM_SSH.match(ssh):
            raise ValueError(f"у узла {name} в nodes.conf непонятный адрес SSH: {ssh}")
        now = time.time()
        with self.lock:
            self.tickets = {t: s for t, s in self.tickets.items() if s["expires"] > now}
            if self.active + len(self.tickets) >= self.MAX:
                raise ValueError(f"открыто уже {self.MAX} терминала, закрой лишний")
            ticket = secrets.token_urlsafe(24)
            self.tickets[ticket] = {"name": name, "ssh": ssh, "cols": cols, "rows": rows,
                                    "expires": now + self.TICKET_TTL}
        return ticket

    def take(self, ticket):
        """Билет погашается сразу, повторно по нему не войти."""
        with self.lock:
            s = self.tickets.pop(ticket, None)
            if s is None or s["expires"] < time.time():
                return None
            self.active += 1
            return s

    def release(self):
        with self.lock:
            self.active -= 1

    def command(self, s, pw):
        """argv терминала: ssh с ключом iof и теми же настройками, что ssh_cmd в iof, или оболочка root."""
        if s["ssh"] == "local":
            cmd = [pw.pw_shell or "/bin/bash", "-l"]
        else:
            target, port = TERM_SSH.match(s["ssh"]).groups()
            cmd = ["ssh", "-t", "-i", self.ssh_key, "-p", port or "22",
                   "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15",
                   "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR", "--", target]
        # setsid -c: своя сессия, и псевдотерминал становится управляющим, иначе в оболочке
        # нет job control, а размер окна не доходит до программ
        cmd = ["setsid", "-c", *cmd]
        # Под systemd терминал уходит в свой scope: при перезапуске панели (iof update) запущенное
        # из терминала через nohup или tmux останется жить, как после закрытия окна PuTTY
        if os.environ.get("INVOCATION_ID") and shutil.which("systemd-run"):
            unit = re.sub(r"[^A-Za-z0-9_.-]", "_", s["name"])
            cmd = ["systemd-run", "--scope", "--quiet", "--collect",
                   f"--unit=iof-term-{unit}-{secrets.token_hex(3)}", *cmd]
        return cmd

    @staticmethod
    def environment(pw):
        # Окружение с нуля: в окружении панели лежит web.env, в том числе пароль панели
        return {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME": pw.pw_dir, "USER": pw.pw_name, "LOGNAME": pw.pw_name, "SHELL": pw.pw_shell or "/bin/bash",
                "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "C.UTF-8"}

    def run(self, s, ws, sock):
        """Терминал по билету s поверх WebSocket ws, пока его не закроет одна из сторон."""
        try:
            self.session(s, ws, sock)
        finally:
            self.release()

    def session(self, s, ws, sock):
        pw = pwd.getpwuid(os.getuid())
        master, slave = os.openpty()
        try:
            try:
                set_winsize(master, s["cols"], s["rows"])
                # IUTF8: стирание кириллицы символами, а не байтами; ssh передаст это и на узел
                attrs = termios.tcgetattr(slave)
                attrs[0] |= getattr(termios, "IUTF8", 0)
                termios.tcsetattr(slave, termios.TCSANOW, attrs)
                proc = subprocess.Popen(self.command(s, pw), stdin=slave, stdout=slave, stderr=slave,
                                        env=self.environment(pw), cwd=pw.pw_dir)
            finally:
                os.close(slave)
        except OSError as e:
            os.close(master)
            ws.send_json({"type": "exit", "error": f"не удалось запустить терминал: {e}"})
            ws.close(1011)
            return

        started = time.time()
        log(f"терминал {s['name']} ({s['ssh']}): открыт")
        stopped = threading.Event()
        reader = threading.Thread(target=self.pump, args=(master, proc, ws, sock, stopped), daemon=True)
        reader.start()
        sock.settimeout(self.ALIVE)
        try:
            while True:
                msg = ws.recv()
                if msg is None:
                    break
                op, data = msg
                if op == WS_BINARY:
                    write_all(master, data)
                elif op == WS_TEXT:
                    self.control(master, data)
        except OSError:
            pass
        finally:
            stopped.set()
            self.stop(proc)
            reader.join(5)
            os.close(master)
            log(f"терминал {s['name']}: закрыт через {int(time.time() - started)} с, код {proc.returncode}")

    @staticmethod
    def pump(master, proc, ws, sock, stopped):
        """Вывод терминала в браузер. Когда процесс закрыл терминал, сообщает код выхода и закрывает
        WebSocket; если браузер не ответил на close, будит чтение в обработчике."""
        while True:
            try:
                data = os.read(master, 65536)
            except OSError:  # EIO: терминал закрыли все процессы на той стороне
                break
            if not data or not ws.send(WS_BINARY, data):
                break
        if stopped.is_set():
            return
        try:
            code = proc.wait(5)
        except subprocess.TimeoutExpired:
            code = None
        ws.send_json({"type": "exit", "code": code})
        ws.close()
        if not stopped.wait(3):
            try:
                sock.shutdown(socket.SHUT_RD)
            except OSError:
                pass

    @staticmethod
    def control(master, data):
        # ping ничего не делает: любое сообщение и так продлевает ALIVE
        try:
            msg = json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return
        if isinstance(msg, dict) and msg.get("type") == "resize" and term_size_ok(msg.get("cols"), msg.get("rows")):
            set_winsize(master, msg["cols"], msg["rows"])

    @staticmethod
    def stop(proc):
        """Как закрытие окна PuTTY: SIGHUP процессам терминала, через 3 секунды SIGKILL."""
        for sig, wait in ((signal.SIGHUP, 3), (signal.SIGKILL, 2)):
            if proc.poll() is not None:
                return
            try:
                os.killpg(proc.pid, sig)
            except OSError:
                proc.send_signal(sig)
            try:
                proc.wait(wait)
                return
            except subprocess.TimeoutExpired:
                pass


# Данные страниц. Их же показывает Telegram-бот (BotViews): один разбор на панель и бота

def node_view(srv, name, force):
    """Страница узла: его состояние из общего опроса, строка nodes.conf, ретрансляторы с ним
    и есть ли в группах Hysteria2 ссылка на него. Ссылки (в них пароль) не отдаются."""
    base = srv.base
    data = srv.cache.get(force)
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
        "hy2_template": srv.hy2_template.is_file(),
        "busy": srv.jobs.busy(),
        "terminal": srv.terms.enabled,
        "migrate": read_migrate(base),
    })
    return data


def service_view(srv, fetch):
    """Страница «Сервис»: версия, клон, Telegram и cron от iof, итог iof check и логи ночного
    обслуживания из файлов. fetch: ещё и git fetch, чтобы узнать, есть ли обновления."""
    base = srv.base
    info, error = iof_api(srv.iof, ["api", "service"], 20)
    data = {
        "version": info.get("version", ""),
        "src": info.get("src", ""),
        "src_version": info.get("src_version", ""),
        "tg": info.get("tg") == "yes",
        "bot": bot_notify(base),
        "cron": info.get("cron", []),
        "error": error,
        "check": read_check(base),
        "daily": read_daily(base),
        "nightly": read_nightly_run(NIGHTLY_RUN_LOG),
        "nightly_local": read_nightly_local(NIGHTLY_LOG),
        "update_log": read_update_log(UPDATE_LOG),
        "busy": srv.jobs.busy(),
        "migrate": read_migrate(base),
    }
    if fetch:
        upd, err = iof_api(srv.iof, ["api", "updates"], 60)
        data["updates"] = {
            "error": err,
            "branch": upd.get("branch", ""),
            "commits": [dict(zip(("hash", "date", "subject"), c.split("\t", 2))) for c in upd.get("commit", [])],
        }
    return data


def security_view(srv):
    """Страница «Безопасность»: последние проверки iof audit по блокам и узлам, справочник проверок,
    история запусков. Узлы не опрашиваются: проверку запускает POST /api/security."""
    data, error = iof_json(srv.iof, ["api", "audit"], 20)
    data.update({
        "error": error,
        "busy": srv.jobs.busy(),
        "migrate": read_migrate(srv.base),
        "probe_state": srv.probes.state(),
        "bot": bot_notify(srv.base),
    })
    return data


class BotViews:
    """Данные страниц для Telegram-бота (iof_bot.Bot, параметр views): модуль бота не импортирует
    iof-web.py (дефис в имени), а читает всё через этот объект. Ссылки Hysteria2 (в них пароль)
    отдаёт только hy2_links: у групп из hy2() только число ссылок и узлы."""

    def __init__(self, srv):
        self.srv = srv

    def nodes(self):
        """Узлы из nodes.conf без опроса: [{name, addr, title}]."""
        return [{"name": n, "addr": a, "title": t or n} for n, a, _, t in read_conf(self.srv.base / "nodes.conf", 4)]

    def node(self, name, force=False):
        return node_view(self.srv, name, force)

    def service(self, fetch=False):
        return service_view(self.srv, fetch)

    def audit(self):
        return security_view(self.srv)

    def hy2(self):
        """Группы ссылок: {name, label, created, hop, links: [{node, relay, hop}]}, без самих ссылок."""
        return [dict({k: g[k] for k in ("name", "label", "created", "hop")},
                     links=[{k: link[k] for k in ("node", "relay", "hop")} for link in g["links"]])
                for g in read_hy2_groups(self.srv.base)]

    def hy2_links(self, name):
        """Ссылки группы с паролями — только для сообщений админу: {label, links: [{node, relay, url}]}
        или None, если группы нет."""
        g = next((g for g in read_hy2_groups(self.srv.base) if g["name"] == name), None)
        if g is None:
            return None
        return {"label": g["label"], "links": [{k: link[k] for k in ("node", "relay", "url")} for link in g["links"]]}

    @staticmethod
    def qr_png(text):
        return qr_png(text)

    def migrate(self):
        return read_migrate(self.srv.base)


class BotActions:
    """Действия Telegram-бота (параметр actions): шаги задач собирает action_steps, как для кнопок
    панели, с теми же проверками, в том числе запретом при переносе. Задачу в Jobs бот ставит сам,
    вид bot. Удаление узлов, перенос, iof update, блок-лист и смену портов бот не делает."""

    KINDS = ("hy2", "node", "audit", "check")

    def __init__(self, srv):
        self.srv = srv

    def plan(self, kind, body):
        """(kind из KINDS, тело запроса как у страницы) -> (заголовок задачи, шаги). ValueError — почему нельзя."""
        if kind not in self.KINDS:
            raise ValueError("неизвестное действие")
        if kind == "node" and body.get("action") != "restart_hy2":
            raise ValueError("из бота с узлом можно только перезапустить Hysteria2")
        if kind == "audit" and body.get("action") is not None:
            raise ValueError("смена портов и блок-лист — только в панели")
        _, title, steps = action_steps(self.srv, kind, body)
        return title, steps


def log(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


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
        if not self.host_allowed():
            return
        url = urlsplit(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        # Вместо пароля панели здесь одноразовый билет: его выдаёт POST /api/term, уже с паролем.
        # Заголовок Authorization на WebSocket браузеры отправляют не всегда
        if url.path == "/api/term/ws":
            return self.term_ws(query.get("t", ""))
        # Скрипт проверки с ПК тоже по одноразовому билету: его забирает PowerShell без пароля панели
        if url.path == "/api/probe/script":
            return self.probe_script(query.get("t", ""))
        if not self.authorized():
            return
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
        if url.path == "/api/security":
            return self.security_info()
        if url.path == "/api/probe":
            return self.send_json(self.server.probes.state())
        if url.path == "/api/bot":
            return self.send_json(self.bot_info())
        if url.path == "/api/jobs":
            return self.send_json({"jobs": self.server.jobs.list()})
        if url.path in STATIC_FILES:
            return self.static(*STATIC_FILES[url.path])
        self.send_json({"error": "не найдено"}, HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if not self.host_allowed():
            return
        url = urlsplit(self.path)
        path = url.path
        # Отчёт скрипта с ПК: вместо пароля панели одноразовый билет, остальная защита как у всех POST
        if path == "/api/probe/result":
            if self.same_origin():
                self.probe_result(parse_qs(url.query).get("t", [""])[0])
            return
        if not self.authorized() or not self.same_origin():
            return
        if path not in ("/api/nodes", "/api/migrate", "/api/hy2", "/api/node", "/api/service", "/api/security",
                        "/api/term", "/api/probe", "/api/bot"):
            return self.send_json({"error": "не найдено"}, HTTPStatus.NOT_FOUND)
        body = self.read_json()
        if body is None:
            return
        if path == "/api/term":
            return self.term_ticket(body)
        if path == "/api/probe":
            return self.probe_action(body)
        if path == "/api/bot":
            return self.bot_action(body)
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
        kind = {"/api/hy2": "hy2", "/api/node": "node", "/api/security": "audit"}.get(path)
        if kind:
            return action_steps(srv, kind, body)
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

    def node_info(self, name, force):
        self.send_json(node_view(self.server, name, force))

    # POST /api/term {name, cols, rows}: одноразовый билет на WebSocket терминала узла
    def term_ticket(self, body):
        terms = self.server.terms
        if not terms.enabled:
            return self.send_json({"error": "терминал выключен: добавь IOF_WEB_TERMINAL=1 в /root/iof/web.env "
                                            "и перезапусти панель: sudo systemctl restart iof-web"}, HTTPStatus.FORBIDDEN)
        try:
            name = text_field(body, "name", 40)
            row = next((r for r in read_conf(self.server.base / "nodes.conf", 4) if r[0] == name), None)
            if row is None:
                raise ValueError(f"узла {name} нет в nodes.conf")
            if not term_size_ok(body.get("cols"), body.get("rows")):
                raise ValueError("размер терминала: cols от 2 до 500, rows от 2 до 200")
            ticket = terms.issue(name, row[2] or "local", body["cols"], body["rows"])
        except ValueError as e:
            return self.send_json({"error": str(e)}, HTTPStatus.BAD_REQUEST)
        self.send_json({"ticket": ticket})

    # GET /api/term/ws?t=<билет>: рукопожатие WebSocket, затем терминал до закрытия. Origin браузер
    # ставит на WebSocket всегда, по нему отсекаются чужие сайты
    def term_ws(self, ticket):
        origin = self.headers.get("Origin")
        if not origin or host_only(origin) not in self.server.hosts:
            return self.send_json({"error": "запрос не со страницы панели"}, HTTPStatus.FORBIDDEN)
        key = self.headers.get("Sec-WebSocket-Key", "")
        if (self.headers.get("Upgrade", "").lower() != "websocket"
                or self.headers.get("Sec-WebSocket-Version") != "13" or len(key) != 24):
            return self.send_json({"error": "здесь только WebSocket"}, HTTPStatus.BAD_REQUEST)
        session = self.server.terms.take(ticket)
        if session is None:
            return self.send_json({"error": "билет терминала неверный или устарел"}, HTTPStatus.FORBIDDEN)
        self.close_connection = True
        try:
            self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                              f"Sec-WebSocket-Accept: {ws_accept(key)}\r\n\r\n").encode())
        except OSError:
            self.server.terms.release()
            return
        self.log_request(101)
        self.server.terms.run(session, WebSocket(self.rfile, self.wfile), self.connection)

    def service_info(self, fetch):
        self.send_json(service_view(self.server, fetch))

    def security_info(self):
        self.send_json(security_view(self.server))

    # Страница «Телеграм бот»: bot.json без хэшей приглашений (только начало), есть ли токен (сам токен
    # не отдаётся) и состояние потока бота. thread = None — модуль бота не загрузился, причина в thread_error
    def bot_info(self):
        srv = self.server
        cfg, error = read_bot(srv.base)
        try:
            token = (srv.base / "bot.token").stat().st_size > 0
        except OSError:
            token = False
        return {
            "config": cfg,
            "config_error": error,
            "token": token,
            "thread": srv.bot.state() if srv.bot else None,
            "thread_error": None if srv.bot else srv.bot_error,
            "tz": time.strftime("%z"),
            "now": time.time(),
            "migrate": read_migrate(srv.base),
        }

    # POST /api/bot {action, ...}: iof bot сразу, без очереди задач. Ответ — первая строка вывода iof
    # и свежее состояние страницы, на invite ещё код приглашения: единственный раз, больше его нигде нет
    def bot_action(self, body):
        srv = self.server
        try:
            not_migrating(read_migrate(srv.base))
            args, stdin, secret = bot_args(body)
        except ValueError as e:
            return self.send_json({"error": str(e)}, HTTPStatus.BAD_REQUEST)
        out, error = iof_bot_cmd(srv.iof, args, stdin)
        if secret:
            out, error = out.replace(secret, "***"), error and error.replace(secret, "***")
        # В журнал только команда: токен уходит в iof через stdin, код приглашения приходит в stdout
        what = "iof bot " + " ".join(args) + (" (удалить токен)" if args == ["token"] and not secret else "")
        log(f"бот: из панели {what}" + (f": {error}" if error else ""))
        if error:
            return self.send_json({"error": error, "bot": self.bot_info()}, HTTPStatus.BAD_REQUEST)
        data = {"message": next((s.strip() for s in out.splitlines() if s.strip()), "Готово"), "bot": self.bot_info()}
        if args[0] == "invite" and args[1] in BOT_ROLES:
            m = BOT_CODE.search(out)
            if not m:
                return self.send_json({"error": "iof bot invite не напечатал код: обнови iof, sudo iof update",
                                       "bot": data["bot"]}, HTTPStatus.INTERNAL_SERVER_ERROR)
            code, cfg = m.group(0), data["bot"]["config"] or {}
            prefix = hashlib.sha256(code.encode()).hexdigest()[:BOT_HASH]
            inv = next((i for i in cfg.get("invites", []) if i["hash"] == prefix), None)
            data["message"] = "Приглашение создано"
            data["invite"] = {"code": code, "role": args[1], "hash": prefix, "expires": inv["expires"] if inv else None,
                              "link": f"https://t.me/{cfg['username']}?start={code}" if cfg.get("username") else None}
        self.send_json(data)

    # POST /api/probe {action: start, nodes, origin} — мишени и билет для ПК; {action: cancel} — остановить.
    # origin — адрес панели в браузере: по нему скрипт с ПК сдаст отчёт
    def probe_action(self, body):
        srv = self.server
        action, ticket = body.get("action"), None
        try:
            not_migrating(read_migrate(srv.base))
            if action == "start":
                origin = text_field(body, "origin", 300).rstrip("/")
                if not PANEL_ORIGIN.match(origin) or host_only(origin) not in srv.hosts:
                    raise ValueError("адрес панели не из IOF_WEB_HOSTS: открой панель по имени из этого списка")
                names = body.get("nodes") or []
                if not isinstance(names, list) or len(names) > 500 or not all(isinstance(n, str) for n in names):
                    raise ValueError("узлы: список имён")
                known = self.node_names()
                bad = next((n for n in names if n not in known or n == "all"), None)
                if bad is not None:
                    raise ValueError(f"узла {bad} нет в nodes.conf")
                if srv.probes.active():
                    raise ValueError("проверка с ПК уже идёт: дождись отчёта или останови её")
                args = ["audit", "probe", "start"]
                if names:
                    args = ["-n", ",".join(names), *args]
                title, steps = "Проверка с ПК: запуск мишеней", [step(srv.iof, *args)]
            elif action == "cancel":
                title, steps = "Проверка с ПК: остановка мишеней", [step(srv.iof, "audit", "probe", "stop")]
            else:
                raise ValueError("неизвестное действие")
        except ValueError as e:
            return self.send_json({"error": str(e)}, HTTPStatus.BAD_REQUEST)
        job = srv.jobs.start(title, steps, "probe")
        if job is None:
            return self.send_json({"error": "уже идёт другая задача, дождись её окончания"}, HTTPStatus.CONFLICT)
        if action == "start":
            ticket = srv.probes.begin(origin, job["id"])
        else:
            srv.probes.cancel()
        self.send_json({"job": job["id"], "ticket": ticket}, HTTPStatus.ACCEPTED)

    # GET /api/probe/script?t=<билет>: probe.ps1 с данными этой проверки, один раз
    def probe_script(self, ticket):
        got = self.server.probes.take_script(ticket)
        if isinstance(got, tuple):
            return self.send_json({"error": got[1]}, got[0])
        self.send_body(got.encode("utf-8"), "text/plain; charset=utf-8", "no-store",
                       extra={"Content-Disposition": 'attachment; filename="iof-probe.ps1"'})

    # POST /api/probe/result?t=<билет>: сырой отчёт probe.ps1, один раз, до MAX_REPORT байт
    def probe_result(self, ticket):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if not 0 < length <= Probes.MAX_REPORT:
            return self.send_json({"error": "пустой или слишком большой отчёт"}, HTTPStatus.BAD_REQUEST)
        try:
            report = json.loads(self.rfile.read(length).decode("utf-8-sig"))
        except (ValueError, UnicodeDecodeError):
            report = None
        if not isinstance(report, dict):
            return self.send_json({"error": "нужен JSON-объект"}, HTTPStatus.BAD_REQUEST)
        error = self.server.probes.accept(ticket, report)
        if error:
            return self.send_json({"error": error}, HTTPStatus.FORBIDDEN)
        self.server.probes.kick(self.server.jobs, self.server.iof)
        self.send_json({"ok": True}, HTTPStatus.ACCEPTED)

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

    def send_body(self, body, ctype, cache, status=HTTPStatus.OK, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        for k, v in {**SECURITY_HEADERS, **(extra or {})}.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), TICKET_IN_URL.sub(r"\1***", fmt % args)))


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
    ssh_key = os.environ.get("IOF_SSH_KEY", "/root/.ssh/iof_ed25519")
    srv.ssh_pub = Path(ssh_key + ".pub")
    srv.hy2_template = Path(os.environ.get("HY2_TEMPLATE", "/etc/hysteria/config.yaml"))
    srv.cache = StatusCache(args.iof, args.ttl)
    srv.probes = Probes(srv.base)

    # После каждой задачи: свежий статус узлов и отчёт с ПК, если он ждал своей очереди
    def on_done():
        srv.cache.invalidate()
        srv.probes.kick(srv.jobs, srv.iof)

    srv.jobs = Jobs(on_done=on_done)
    srv.terms = Terminals(os.environ.get("IOF_WEB_TERMINAL", "").strip() == "1", ssh_key)

    # Telegram-бот: поток внутри панели с общей очередью задач и опросом узлов. Работает, когда
    # включён (iof bot on) и есть токен; адрес Bot API меняет только IOF_TG_API (стенд, CI)
    # Без бота страница «Телеграм бот» показывает причину из bot_error
    srv.bot, srv.bot_error = None, None
    if iof_bot is None:
        srv.bot_error = f"модуль iof_bot не загрузился: {BOT_IMPORT_ERROR}"
        log(f"бот: {srv.bot_error}, панель работает без бота")
    else:
        try:
            srv.bot = iof_bot.Bot(srv.base, args.iof, jobs=srv.jobs, cache=srv.cache, views=BotViews(srv),
                                  actions=BotActions(srv), api=os.environ.get("IOF_TG_API"), log=log)
            srv.bot.start()
        except Exception as e:
            srv.bot, srv.bot_error = None, f"бот не запустился: {type(e).__name__}: {e}"
            log(f"бот: {srv.bot_error}, панель работает без бота")
    print(f"iof-web: http://{args.listen}/" + ("  (терминал включён)" if srv.terms.enabled else ""), file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
