"""Сквозная проверка установленной панели через nginx и настоящий SSH-туннель."""

import base64
import http.client
import json
import os
from pathlib import Path
import pty
import re
import select
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit


ip = sys.argv[1]
domain = "https://panel.test"
address = f"https://{ip}"
tunnel = "http://127.0.0.1:18088"
trust = ssl.create_default_context(cafile="/run/iof-test.crt")
trust.load_verify_locations(cafile="/run/iof-test-ip.crt")
old, new, reset = "Прежний пароль iof", "Новый пароль iof", "Сброшенный пароль iof"
base = Path("/root/iof")
auth = base / "web-auth.json"


def connect(origin):
    url = urlsplit(origin)
    if url.scheme == "https":
        return http.client.HTTPSConnection(url.netloc, context=trust, timeout=10)
    return http.client.HTTPConnection(url.netloc, timeout=10)


def request(origin, path, status=200, *, body=None, cookie=None, headers=None):
    outgoing = {}
    if body is not None:
        outgoing.update({"Content-Type": "application/json", "X-IOF-Request": "1", "Origin": origin})
    if cookie:
        outgoing["Cookie"] = cookie
    for key, value in (headers or {}).items():
        if value is None:
            outgoing.pop(key, None)
        else:
            outgoing[key] = value
    conn = connect(origin)
    try:
        conn.request("POST" if body is not None else "GET", path,
                     None if body is None else json.dumps(body).encode(), headers=outgoing)
        resp = conn.getresponse()
        data = resp.read()
        assert resp.status == status, (origin, path.split("?")[0], resp.status, status)
        return resp.headers, data
    finally:
        conn.close()


def login(origin, password, status=200, prefix="/admin", username="admin"):
    headers, _ = request(origin, prefix + "/api/login", status, body={"login": username, "password": password})
    if status != 200:
        assert "Set-Cookie" not in headers
        assert "WWW-Authenticate" not in headers
        return None
    cookie = headers["Set-Cookie"]
    assert "HttpOnly" in cookie and "SameSite=Strict" in cookie
    assert ("; Secure" in cookie) == origin.startswith("https:")
    assert ("Path=/admin/" in cookie) == origin.startswith("https:")
    return cookie.split(";", 1)[0]


def websocket(origin, ticket, cookie, status, *, ws_origin=None):
    conn = connect(origin)
    conn.connect()
    sock = conn.sock
    key = base64.b64encode(os.urandom(16)).decode()
    host = urlsplit(origin).netloc
    sock.sendall((f"GET /admin/api/term/ws?t={ticket} HTTP/1.1\r\nHost: {host}\r\n"
                  f"Origin: {ws_origin or origin}\r\nCookie: {cookie}\r\nUpgrade: websocket\r\n"
                  f"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n").encode())
    head = b""
    while not head.endswith(b"\r\n\r\n"):
        chunk = sock.recv(1)
        assert chunk
        head += chunk
    assert int(head.split()[1]) == status, head
    return sock


def ticket_for(cookie, name="panel", status=200):
    _, data = request(domain, "/admin/api/term", status, cookie=cookie, body={"name": name, "cols": 80, "rows": 24})
    return json.loads(data).get("ticket")


def terminal_output(ws, command, expected):
    mask = os.urandom(4)
    ws.sendall(bytes([0x82, 0x80 | len(command)]) + mask
               + bytes(c ^ mask[i % 4] for i, c in enumerate(command)))
    with ws.makefile("rb") as frames:
        output = b""
        while expected not in output:
            opcode, size = frames.read(2)
            if size >= 126:
                size = int.from_bytes(frames.read(2 if size == 126 else 8), "big")
            payload = frames.read(size)
            assert opcode != 0x88, (payload, output)
            if opcode == 0x82:
                output += payload


def restart_panel():
    subprocess.run(["systemctl", "restart", "iof-web"], check=True)
    for _ in range(50):
        try:
            request(tunnel, "/api/setup", 401)
            return
        except OSError:
            time.sleep(0.1)
    raise AssertionError("панель не отвечает после перезапуска")


def wait_job(cookie, match):
    for _ in range(100):
        _, data = request(domain, "/admin/api/jobs", cookie=cookie)
        job = next((j for j in json.loads(data)["jobs"] if match(j)), None)
        if job and job["state"] != "running":
            assert job["state"] == "ok", job
            return
        time.sleep(0.25)
    raise AssertionError("таймаут задачи проверки с ПК")


def initial_credentials(path, login_name, password=None):
    # Настоящий терминал нужен для проверки getpass и разового вывода сгенерированного пароля.
    pid, tty = pty.fork()
    if pid == 0:
        os.execv(sys.executable, [sys.executable, "/opt/iof/web/iof_auth.py", "init", str(path)])
    output = bytearray()

    def wait_for(text):
        while text.encode() not in output:
            assert select.select([tty], [], [], 10)[0], "установщик не показал приглашение"
            output.extend(os.read(tty, 4096))

    try:
        wait_for("Логин панели")
        os.write(tty, (login_name + "\n").encode())
        wait_for("Новый пароль панели")
        os.write(tty, ((password or "") + "\n").encode())
        if password:
            wait_for("Подтверждение пароля")
            os.write(tty, (password + "\n").encode())
        wait_for("Учётная запись панели создана")
        _, status = os.waitpid(pid, 0)
        assert status == 0
    finally:
        os.close(tty)
    return bytes(output)


with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp)
    sys.path.insert(0, "/opt/iof-web")
    from iof_auth import Credentials

    for name, password, expected in (("operator", "Пароль для первого входа", "operator"), ("", None, "admin")):
        path = folder / expected
        output = initial_credentials(path, name, password)
        if password:
            assert password.encode() not in output
        else:
            password = re.search("Пароль панели: ".encode() + rb"([0-9a-f]{16})\r\n", output)[1].decode()
        cfg = Credentials(path).read()
        assert cfg["login"] == expected and Credentials.verify(cfg, password)
    print("ok: первичная установка с выбранным логином и паролем и генерация 16 hex-символов")


before = auth.read_bytes()
assert auth.stat().st_mode & 0o777 == 0o600
assert b"IOF_WEB_PASSWORD" not in (base / "web.env").read_bytes()
assert old.encode() not in before
with socket.socket() as check:
    assert check.connect_ex((ip, 8088)) != 0
for origin in (domain, address):
    host = urlsplit(origin).hostname
    hdr, _ = request(f"http://{host}", "/admin", 308)
    assert hdr["Location"] == origin + "/admin"
    hdr, _ = request(origin, "/admin", 308)
    assert hdr["Location"] == "/admin/"
    hdr, _ = request(origin, "/admin/", 303)
    assert hdr["Location"] == "/admin/login.html"
    _, page = request(origin, "/admin/login.html")
    assert all(f">{label}<".encode() in page for label in ("Логин", "Пароль"))
    request(origin, "/admin/api/jobs", 401)
    request(origin, "/api/jobs", 404)

login(domain, "неверный пароль", 401)
login(domain, old, 401, username="другой логин")
cookies = {domain: login(domain, old), address: login(address, old), tunnel: login(tunnel, old, prefix="")}
for origin, cookie in cookies.items():
    for path in ("", "settings.html", "node.html", "security.html", "app.css", "common.js", "api/setup", "api/jobs"):
        request(origin, "/admin/" + path, cookie=cookie)
request(tunnel, "/api/setup", cookie=cookies[tunnel])
request(tunnel, "/api/setup", 403, headers={"Host": "panel.test"})
request(domain, "/admin/api/setup", 403, headers={"Host": "example.invalid"})
request(domain, "/admin/api/setup", 403, headers={"Host": "127.0.0.1"})
request(address, "/admin/api/setup", 401, cookie=cookies[domain])
for headers in ({"X-IOF-Request": None}, {"Origin": None}, {"Origin": address},
                {"Origin": "http://panel.test"}, {"Origin": domain + ":444"}):
    request(domain, "/admin/api/login", 403, body={"login": "admin", "password": old}, headers=headers)
print("ok: домен и IP по HTTPS, туннель, страницы и API, Host, Origin, CSRF, неверные данные входа")

version = subprocess.check_output(["iof", "version"])
subprocess.run(["iof", "update"], check=True, stdout=subprocess.DEVNULL)
assert subprocess.check_output(["iof", "version"]) != version
assert auth.read_bytes() == before
request(domain, "/admin/api/setup", cookie=cookies[domain])
print("ok: миграция IOF_WEB_PASSWORD и сохранение учётных данных после iof update")

cookie = cookies[domain]
nodes_file = base / "nodes.conf"
registered = nodes_file.read_bytes()
web_env = base / "web.env"
enabled_env = web_env.read_bytes()
try:
    for name in ("panel", "@controller"):
        if name == "@controller":
            nodes_file.write_bytes(b"")
            restart_panel()
        else:
            assert ticket_for(cookie, "@controller", 400) is None
        _, data = request(domain, "/admin/api/dashboard?force=1", cookie=cookie)
        nodes = json.loads(data)["nodes"]
        assert len(nodes) == 1 and nodes[0]["controller"] and nodes[0]["name"] == name
        _, data = request(domain, f"/admin/api/node?n={name}", cookie=cookie)
        view = json.loads(data)
        assert view["controller"] and view["terminal"] and view["node"]["reachable"]
        assert bool(view["conf"]) == (name == "panel")
        ticket = ticket_for(cookie, name)
        with websocket(domain, ticket, cookie, 101) as ws:
            terminal_output(ws, b"hostname\r", b"panel\r\n")
        with websocket(domain, ticket, cookie, 403):
            pass
    assert not view["node"]["hy2"]["installed"] and view["node"]["awg"]["state"] == "none"
    for path in ("hy2", "awg"):
        _, data = request(domain, "/admin/api/" + path, cookie=cookie)
        assert json.loads(data)["nodes"] == []
    web_env.write_bytes(enabled_env.replace(b"IOF_WEB_TERMINAL=1", b"IOF_WEB_TERMINAL=0"))
    restart_panel()
    _, data = request(domain, "/admin/api/node?n=@controller", cookie=cookie)
    assert not json.loads(data)["terminal"]
    assert ticket_for(cookie, "@controller", 403) is None
finally:
    nodes_file.write_bytes(registered)
    web_env.write_bytes(enabled_env)
    restart_panel()
print("ok: одна строка управляющего сервера, локальный hostname, терминал выключен, списки VPN без служебной строки")

ticket = ticket_for(cookie)
with websocket(domain, ticket, cookie, 403, ws_origin=address):
    pass
with websocket(domain, ticket, "", 403):
    pass
with websocket(domain, ticket, cookie, 101) as ws:
    with websocket(domain, ticket, cookie, 403):
        pass
    # Двоичный кадр со вводом и ответ настоящей оболочки.
    terminal_output(ws, b"printf 'IOF%sTERMINAL\\n' -TEST-\r", b"IOF-TEST-TERMINAL")

    pending = ticket_for(cookie)
    change = {"current": old, "password": new, "confirmation": new}
    request(domain, "/admin/api/password", 400, cookie=cookie, body=dict(change, current="неверно"))
    request(domain, "/admin/api/password", 400, cookie=cookie, body=dict(change, confirmation="не совпадает"))
    request(domain, "/admin/api/password", 403, cookie=cookie, body=change, headers={"Origin": address})
    request(domain, "/admin/api/password", cookie=cookie, body=change)
    while ws.recv(4096):
        pass
with websocket(domain, pending, cookie, 403):
    pass
for origin, cookie in cookies.items():
    request(origin, "/admin/api/setup", 401, cookie=cookie)
login(domain, old, 401)
cookie = login(domain, new)
print("ok: WebSocket, одноразовый билет терминала, смена пароля и закрытие сеансов на всех адресах")

_, data = request(domain, "/admin/api/probe", 202, cookie=cookie, body={"action": "start", "nodes": ["panel"]})
probe = json.loads(data)
wait_job(cookie, lambda j: j["id"] == probe["job"])
ticket = probe["ticket"]
script = f"/admin/api/probe/script?t={ticket}"
_, data = request(domain, script)
blob = re.search(rb"\$IofProbeConfig = '([^']+)'", data)[1]
config = json.loads(base64.b64decode(blob))
assert config["origin"] == domain + "/admin" and config["ticket"] == ticket and config["targets"]
request(domain, script, 403)
result = f"/admin/api/probe/result?t={ticket}"
report = {"v": 1, "session": config["session"], "remap": True, "targets": [{"node": "panel"}]}
request(domain, result, 403, body=report, headers={"X-IOF-Request": None})
request(domain, result, 202, body=report, headers={"Origin": None})
request(domain, result, 403, body=report, headers={"Origin": None})
wait_job(cookie, lambda j: j["kind"] == "probe" and "результат" in j["title"])
print("ok: одноразовые скачивание скрипта и приём отчёта по /admin")

with websocket(domain, ticket_for(cookie), cookie, 101) as ws:
    p = subprocess.run(["iof", "web", "reset-password", "--password-stdin"], input=reset + "\n", text=True,
                       check=True, capture_output=True)
    assert reset not in p.stdout + p.stderr
    while ws.recv(4096):
        pass
request(domain, "/admin/api/setup", 401, cookie=cookie)
login(domain, new, 401)
cookie = login(domain, reset)
request(domain, "/admin/api/setup", cookie=cookie)
journal = subprocess.check_output(["journalctl", "-u", "iof-web", "-o", "cat", "--no-pager"], text=True)
assert all(password not in journal and password.encode() not in auth.read_bytes() for password in (old, new, reset))
assert ticket not in journal
print("ok: локальный сброс без старого пароля, отзыв сеансов, пароли и билеты отсутствуют в журнале")
