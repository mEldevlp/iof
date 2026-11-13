#!/usr/bin/env python3
"""Поддельный Bot API Telegram для стенда и CI. Бот iof (web/iof_bot.py) и iof bot token ходят сюда,
когда в web.env задан IOF_TG_API=http://127.0.0.1:8089 (так делает stand.sh setup на old).

Методы бота: getMe, getUpdates (long polling; новый опрос обрывает ждущий ответом 409, как Telegram),
sendMessage, sendPhoto, editMessageText, answerCallbackQuery, setMyCommands, getMyCommands,
deleteWebhook. Параметры — JSON, форма или multipart, как у Telegram. Любой токен вида <номер>:<секрет>
верный, кроме номера 0: на него 401, как на отозванный токен. Ожидание getUpdates не дольше --max-wait
секунд, чтобы тесты не ждали по 50 с, пока бот заметит, что его выключили.

Служебный вход для тестов, JSON:
  POST /fake/message  {from_id, text, username?, first_name?, chat_type?, chat_id?, date?} → {update_id}
                      username: null — без username; chat_type: private (по умолчанию), group, supergroup
  POST /fake/update   готовый апдейт без update_id → {update_id}
  GET  /fake/sent?after=N   вызовы методов бота с номером больше N: [{n, method, bot, params}]
  GET  /fake/state    {offset, polls, waiting, queued, commands, sent}: offset — с какого номера бот
                      подтвердил апдейты, polls — сколько было getUpdates, waiting — сколько ждут сейчас
  POST /fake/reset    очистить очередь апдейтов и журнал вызовов
Токен в журнал не пишется, в журнале вызовов вместо него номер бота.

Запуск:  python3 fake-tg.py [--listen 127.0.0.1:8089] [--max-wait 5]
"""

import argparse
import json
import re
import sys
import threading
import time
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

BOT_PATH = re.compile(r"^/bot([0-9]{1,20}):([A-Za-z0-9_-]+)/([A-Za-z]+)$")
TOKEN_IN_PATH = re.compile(r"(/bot[0-9]+:)[A-Za-z0-9_-]+")
USERNAME = "iof_stand_bot"


class Fake:
    def __init__(self, max_wait):
        self.max_wait = max_wait
        self.cond = threading.Condition()
        self.updates = []     # неподтверждённые апдейты
        self.next_id = 1000
        self.offset = 0       # бот подтвердил всё ниже этого номера
        self.sent = []        # вызовы методов бота
        self.polls = 0
        self.waiting = 0
        self.gen = 0          # номер последнего getUpdates: по нему ждущий опрос узнаёт, что его оборвали
        self.commands = []
        self.message_id = 1

    def add(self, update):
        with self.cond:
            update["update_id"] = self.next_id
            self.next_id += 1
            self.updates.append(update)
            self.cond.notify_all()
            return update["update_id"]

    def message(self, body):
        uid = int(body["from_id"])
        chat_type = body.get("chat_type") or "private"
        user = {"id": uid, "is_bot": False, "first_name": body.get("first_name") or f"User{uid}",
                "language_code": "ru"}
        username = body.get("username", f"user{uid}")
        if username:
            user["username"] = username
        if chat_type == "private":
            chat = {"id": body.get("chat_id", uid), "type": "private", "first_name": user["first_name"]}
            if username:
                chat["username"] = username
        else:
            chat = {"id": body.get("chat_id", -1000000000000 - uid), "type": chat_type, "title": "Stand group"}
        text = str(body.get("text", ""))
        with self.cond:
            mid = self.message_id
            self.message_id += 1
        msg = {"message_id": mid, "from": user, "chat": chat, "date": int(body.get("date") or time.time()),
               "text": text}
        cmd = re.match(r"^/[A-Za-z0-9_@]+", text)
        if cmd:
            msg["entities"] = [{"type": "bot_command", "offset": 0, "length": len(cmd.group(0))}]
        return self.add({"message": msg})

    def record(self, bot, method, params):
        with self.cond:
            n = len(self.sent) + 1
            self.sent.append({"n": n, "method": method, "bot": bot, "params": params})
            mid = self.message_id
            self.message_id += 1
        return mid

    def get_updates(self, params):
        """(код, ответ). Новый опрос обрывает ждущий ответом 409, как Telegram."""
        try:
            offset = int(params.get("offset") or 0)
            timeout = max(0.0, min(float(params.get("timeout") or 0), self.max_wait))
        except (TypeError, ValueError):
            return 400, "Bad Request: wrong parameter"
        with self.cond:
            self.polls += 1
            self.gen += 1
            gen = self.gen
            if offset > 0:
                self.offset = max(self.offset, offset)
                self.updates = [u for u in self.updates if u["update_id"] >= offset]
            self.cond.notify_all()
            deadline = time.time() + timeout
            self.waiting += 1
            try:
                while True:
                    if self.gen != gen:
                        return 409, ("Conflict: terminated by other getUpdates request; "
                                     "make sure that only one bot instance is running")
                    ready = [u for u in self.updates if u["update_id"] >= offset][:100]
                    left = deadline - time.time()
                    if ready or left <= 0:
                        return 200, ready
                    self.cond.wait(left)
            finally:
                self.waiting -= 1

    def state(self):
        with self.cond:
            return {"offset": self.offset, "polls": self.polls, "waiting": self.waiting,
                    "queued": len(self.updates), "commands": self.commands, "sent": len(self.sent)}

    def reset(self):
        with self.cond:
            self.updates, self.sent = [], []


def form_params(ctype, body):
    """Параметры из формы или multipart. Файл — {filename, size}: в тестах важно, что он пришёл."""
    if ctype.startswith("application/x-www-form-urlencoded"):
        return {k: v[0] for k, v in parse_qs(body.decode("utf-8", "replace")).items()}
    if ctype.startswith("multipart/form-data"):
        msg = BytesParser(policy=policy.default).parsebytes(
            b"Content-Type: " + ctype.encode() + b"\r\nMIME-Version: 1.0\r\n\r\n" + body)
        out = {}
        for part in msg.iter_parts():
            name = part.get_param("name", header="content-disposition")
            if not name:
                continue
            data = part.get_payload(decode=True) or b""
            filename = part.get_filename()
            out[name] = {"filename": filename, "size": len(data)} if filename else data.decode("utf-8", "replace")
        return out
    return {}


class Handler(BaseHTTPRequestHandler):
    server_version = "fake-tg"
    sys_version = ""

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.route()

    def route(self):
        url = urlsplit(self.path)
        params = {k: v[0] for k, v in parse_qs(url.query).items()}
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length > 0 else b""
        ctype = self.headers.get("Content-Type", "")
        if ctype.startswith("application/json") and body:
            try:
                data = json.loads(body.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                return self.reply(400, {"ok": False, "error_code": 400, "description": "Bad Request: can't parse JSON"})
            if isinstance(data, dict):
                params.update(data)
        else:
            params.update(form_params(ctype, body))
        if url.path.startswith("/fake/"):
            return self.service(url.path, params)
        m = BOT_PATH.match(url.path)
        if not m:
            return self.reply(404, {"ok": False, "error_code": 404, "description": "Not Found"})
        bot, method = int(m.group(1)), m.group(3)
        if bot == 0:
            return self.reply(401, {"ok": False, "error_code": 401, "description": "Unauthorized"})
        self.method(bot, method, params)

    def method(self, bot, method, params):
        fake = self.server.fake
        me = {"id": bot, "is_bot": True, "first_name": "iof stand", "username": USERNAME}
        if method == "getMe":
            return self.ok({**me, "can_join_groups": True, "can_read_all_group_messages": False,
                            "supports_inline_queries": False})
        if method == "getUpdates":
            code, result = fake.get_updates(params)
            if code != 200:
                return self.reply(code, {"ok": False, "error_code": code, "description": result})
            return self.ok(result)
        if method == "setMyCommands":
            commands = params.get("commands")
            if isinstance(commands, str):
                commands = json.loads(commands)
            fake.commands = commands if isinstance(commands, list) else []
            fake.record(bot, method, params)
            return self.ok(True)
        if method == "getMyCommands":
            return self.ok(fake.commands)
        if method in ("answerCallbackQuery", "deleteWebhook"):
            fake.record(bot, method, params)
            return self.ok(True)
        if method in ("sendMessage", "sendPhoto", "editMessageText"):
            chat_id = params.get("chat_id")
            if chat_id in (None, ""):
                return self.reply(400, {"ok": False, "error_code": 400, "description": "Bad Request: chat_id is empty"})
            if method != "sendPhoto" and not str(params.get("text", "")).strip():
                return self.reply(400, {"ok": False, "error_code": 400, "description": "Bad Request: message text is empty"})
            if len(str(params.get("text", ""))) > 4096:
                return self.reply(400, {"ok": False, "error_code": 400, "description": "Bad Request: message is too long"})
            mid = fake.record(bot, method, params)
            msg = {"message_id": int(params.get("message_id") or mid), "from": me, "date": int(time.time()),
                   "chat": {"id": int(chat_id) if re.fullmatch(r"-?[0-9]+", str(chat_id)) else chat_id, "type": "private"}}
            if method == "sendPhoto":
                msg["photo"] = [{"file_id": f"photo{mid}", "width": 300, "height": 300}]
                if params.get("caption"):
                    msg["caption"] = params["caption"]
            else:
                msg["text"] = params.get("text", "")
            return self.ok(msg)
        self.reply(404, {"ok": False, "error_code": 404, "description": "Not Found: method not found"})

    def service(self, path, params):
        fake = self.server.fake
        if path == "/fake/message" and self.command == "POST":
            try:
                return self.reply(200, {"update_id": fake.message(params)})
            except (KeyError, TypeError, ValueError) as e:
                return self.reply(400, {"error": f"нужны from_id и text: {e}"})
        if path == "/fake/update" and self.command == "POST":
            return self.reply(200, {"update_id": fake.add(dict(params))})
        if path == "/fake/sent":
            after = int(params.get("after") or 0)
            with fake.cond:
                return self.reply(200, [s for s in fake.sent if s["n"] > after])
        if path == "/fake/state":
            return self.reply(200, fake.state())
        if path == "/fake/reset" and self.command == "POST":
            fake.reset()
            return self.reply(200, {"ok": True})
        self.reply(404, {"error": "нет такого служебного адреса"})

    def ok(self, result):
        self.reply(200, {"ok": True, "result": result})

    def reply(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % TOKEN_IN_PATH.sub(r"\1***", fmt % args))


def main():
    ap = argparse.ArgumentParser(description="Поддельный Bot API для стенда iof")
    ap.add_argument("--listen", default="127.0.0.1:8089")
    ap.add_argument("--max-wait", type=float, default=5.0, help="дольше этого getUpdates не ждёт, секунд")
    args = ap.parse_args()
    host, _, port = args.listen.rpartition(":")
    srv = ThreadingHTTPServer((host or "127.0.0.1", int(port)), Handler)
    srv.daemon_threads = True
    srv.fake = Fake(args.max_wait)
    print(f"fake-tg: http://{args.listen}/", file=sys.stderr, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
