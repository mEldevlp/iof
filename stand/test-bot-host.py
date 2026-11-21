"""Панель, CLI, два SSH-узла и один поддельный Telegram Bot API."""

import json
import hashlib
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from panel_client import panel_cookie


PANEL = "http://127.0.0.1:8088"
FAKE = "http://127.0.0.1:8089/fake/"
TOKEN = "12345:" + "A" * 32
NEW_TOKEN = "23456:" + "B" * 32
ADMIN = 12042
REGULAR = 12043
BASE = Path("/root/iof")
SESSION = panel_cookie(PANEL)


def request(url, body=None, panel=False):
    headers = {"Content-Type": "application/json"}
    if panel:
        headers.update({"Origin": PANEL, "X-IOF-Request": "1", "Cookie": SESSION})
    req = urllib.request.Request(url, headers=headers, data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(req, timeout=45) as response:
        return json.load(response)


def panel(body=None):
    data = request(PANEL + "/api/bot", body, panel=True)
    assert TOKEN not in json.dumps(data) and NEW_TOKEN not in json.dumps(data)
    return data


def fake(action, body=None):
    return request(FAKE + action, body)


def iof(*args):
    return subprocess.check_output(["iof", *args], text=True, stderr=subprocess.STDOUT)


def wait(check, description, timeout=100):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = check()
        if result:
            return result
        time.sleep(0.2)
    raise AssertionError(f"{description}: {panel()}")


def polling(sender):
    def check():
        status = fake("state")
        assert status["conflicts"] == 0, status
        return status["waiting"] == 1 and status["poller"] == sender and panel()["thread"]["state"] == "running"
    wait(check, f"бот опрашивает Telegram с {sender}")


def move(server, failure=""):
    assert panel({"action": "move", "server": server})["bot"]["move"]["running"]

    def done():
        view = panel()
        return view if not view["move"]["running"] else None

    view = wait(done, f"перенос на {server or 'управляющий сервер'}", 160)
    result = view["move"]
    if failure:
        assert result["error"] and failure in result["message"], result
    else:
        assert not result["error"] and view["server"]["name"] == server, view
    print(result["message"], flush=True)
    return view


def exchange(sender, user, command, expected):
    after = fake("state")["sent"]
    fake("message", {"from_id": user, "text": command})

    def check():
        return next((row for row in fake(f"sent?after={after}") if row["method"] in ("sendMessage", "editMessageText")
                     and row["params"]["chat_id"] == user and expected in row["params"].get("text", "")), None)

    row = wait(check, command)
    assert row["sender"] == sender, row
    return row


def config_bytes():
    return (BASE / "bot.json").read_bytes()


def block_controller(action, control):
    subprocess.run(["iptables", action, "OUTPUT", "-d", control, "-p", "tcp", "--dport", "8089", "-j", "REJECT"],
                   check=True)


def before_reboot(control, first, second):
    assert panel()["server"]["name"] == ""
    assert [s["name"] for s in panel()["servers"]] == ["", "first", "second"]
    panel({"action": "token", "token": TOKEN})
    panel({"action": "enable", "on": True})
    polling(control)
    main_invite = panel({"action": "invite", "role": "main"})["invite"]["code"]
    exchange(control, ADMIN, "/start " + main_invite, "ты админ")
    regular_invite = panel({"action": "invite", "role": "regular"})["invite"]["code"]
    panel({"action": "set", "key": "actions", "on": True})
    panel({"action": "set", "key": "links", "on": False})
    panel({"action": "set", "key": "quiet", "value": "22:40-04:50"})
    panel({"action": "admin_set", "id": ADMIN, "notify": ["nodes", "admins"]})
    panel({"action": "admin_set", "id": ADMIN, "sound": True})
    saved = config_bytes()
    block_controller("-I", control)
    try:
        urllib.request.urlopen(f"http://{control}:8089/bot{TOKEN}/getMe", timeout=3)
    except urllib.error.URLError as error:
        assert not isinstance(error, urllib.error.HTTPError), "управляющий сервер получил ответ Bot API"
    else:
        raise AssertionError("Bot API доступен с управляющего сервера")
    move("first")
    polling(first)
    assert config_bytes() == saved
    deletion = subprocess.run(["iof", "node", "del", "first"], capture_output=True, text=True)
    assert deletion.returncode and "сначала перенеси его" in deletion.stderr
    exchange(first, ADMIN, "/status", "Узлы")
    exchange(first, REGULAR, "/start " + regular_invite, "обычный")
    exchange(first, REGULAR, "/check", "только главному")
    pending = exchange(first, ADMIN, "/check", "Подтверди действие")
    markup = pending["params"]["reply_markup"]["inline_keyboard"]
    fake("update", {"callback_query": {
        "id": "run-check", "data": markup[0][0]["callback_data"], "from": {"id": ADMIN},
        "message": {"chat": {"id": ADMIN, "type": "private"}, "message_id": pending["message_id"]}}})
    wait(lambda: any(j["kind"] == "bot" and j["state"] != "running"
                     for j in request(PANEL + "/api/jobs", panel=True)["jobs"]), "задача /check в очереди панели")
    panel({"action": "invite", "role": "regular"})
    saved = config_bytes()
    after = fake("state")["sent"]
    assert "отправлено 1 из 1" in iof("notify", "nodes", "проверка уведомления на узле")
    assert any(row["sender"] == first and "проверка уведомления на узле" in row["params"].get("text", "")
               for row in fake(f"sent?after={after}"))
    fake("fail-poll", {"sender": second})
    assert move("second", "опрос с этого адреса отключён")["server"]["name"] == "first"
    polling(first)
    assert config_bytes() == saved
    fake("fail-poll", {"sender": None})
    move("second")
    polling(second)
    exchange(second, ADMIN, "/help", "Команды")
    assert config_bytes() == saved
    assert move("", "Нет связи с Telegram")["server"]["name"] == "second"
    polling(second)
    try:
        panel({"action": "token", "token": "0:" + "C" * 32})
    except urllib.error.HTTPError as error:
        assert error.code == 400 and "Telegram не принял токен" in json.load(error)["error"]
    else:
        raise AssertionError("Панель приняла недействительный токен")
    assert (BASE / "bot.token").read_text().strip() == TOKEN
    panel({"action": "token", "token": NEW_TOKEN})
    assert (BASE / "bot.token").read_text().strip() == NEW_TOKEN
    assert config_bytes() == saved
    reply = exchange(second, ADMIN, "/help", "Команды")
    assert reply["bot"] == 23456, reply
    subprocess.run(["systemctl", "restart", "iof-web"], check=True)
    polling(second)
    assert config_bytes() == saved
    exchange(second, ADMIN, "/help", "Команды")
    move("first")
    polling(first)
    assert config_bytes() == saved
    Path("/run/iof-bot-test-config.sha256").write_text(hashlib.sha256(saved).hexdigest())
    print("Проверены команды и роли, подписки, замена токена, откат запуска и перезапуск панели", flush=True)


def after_reboot(control, first):
    saved = config_bytes()
    assert hashlib.sha256(saved).hexdigest() == Path("/run/iof-bot-test-config.sha256").read_text()
    polling(first)
    exchange(first, ADMIN, "/help", "Команды")
    assert panel()["server"]["name"] == "first" and config_bytes() == saved
    block_controller("-D", control)
    move("")
    polling(control)
    exchange(control, REGULAR, "/help", "Команды")
    assert config_bytes() == saved
    logs = subprocess.check_output(["journalctl", "-u", "iof-web", "-u", "fake-tg", "--no-pager"], text=True)
    assert TOKEN not in logs and NEW_TOKEN not in logs
    assert fake("state")["conflicts"] == 0
    print("Проверены перезапуск узла, возврат, отсутствие конкурирующих опросов и токенов в журналах")


if __name__ == "__main__":
    phase, manager, node1, node2 = sys.argv[1:]
    if phase == "before-reboot":
        before_reboot(manager, node1, node2)
    else:
        after_reboot(manager, node1)
