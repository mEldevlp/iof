"""iof_bot: Telegram-бот iof, работает потоком внутри панели iof-web.

Long polling (getUpdates), без webhook: на сервере не открывается порт. Отвечает только админам
и только в личном чате, групповые чаты и каналы не читает, остальным молчит. Исключение —
сообщение, похожее на код приглашения (64 знака hex, или /start <код> по ссылке t.me/бот?start=код):
код проверяет iof bot redeem, и бот отвечает, подошёл ли он.

Настройки и админы в /root/iof/bot.json, токен в /root/iof/bot.token. Поток их только читает
(заново, когда файл изменился), меняет их только iof bot. Повтор апдейта после перезапуска
безопасен: offset в памяти, сообщения старше STALE секунд от запуска не обрабатываются.

Только stdlib. Адрес Bot API — IOF_TG_API из web.env (для стенда и CI с поддельным API),
по умолчанию https://api.telegram.org. Прокси нет и не будет. Токен не пишется в журнал:
текст любой ошибки проходит через scrub.
"""

import html
import http.client
import json
import os
import re
import socket
import subprocess
import threading
import time
import traceback
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_API = "https://api.telegram.org"
API_URL = re.compile(r"^https?://[A-Za-z0-9.:\[\]-]+(/[A-Za-z0-9._~/-]*)?$")
# Токен от @BotFather: номер бота и секрет. Строгая проверка: токен входит в адрес запроса
TOKEN = re.compile(r"^[0-9]{1,20}:[A-Za-z0-9_-]{20,100}$")
# Код приглашения сам по себе или из ссылки t.me/<бот>?start=<код>: Telegram присылает /start <код>
INVITE = re.compile(r"^(?:/start(?:@[A-Za-z0-9_]+)?\s+)?([0-9A-Fa-f]{64})$")
COMMAND = re.compile(r"^/([A-Za-z0-9_]{1,32})(?:@([A-Za-z0-9_]{1,64}))?(?:\s|$)")
USERNAME = re.compile(r"^[A-Za-z0-9_]{1,32}$")
ROLES = {"main": "главный", "regular": "обычный"}
# Меню команд в Telegram (setMyCommands) и /help
COMMANDS = [
    ("start", "Приветствие и твоя роль"),
    ("help", "Что умеет бот"),
]
DEFAULTS = {"enabled": False, "username": "", "actions": False, "hy2_links": True, "quiet": None,
            "admins": [], "invites": []}
MAX_TEXT = 4096  # знаков в одном сообщении Telegram


def esc(text):
    return html.escape(str(text), quote=False)


def clean(text, limit):
    """Имя из Telegram в одну строку без управляющих знаков: оно идёт в iof bot redeem строкой stdin."""
    return re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or "")).strip()[:limit]


class ApiError(Exception):
    """Bot API ответил ошибкой: code — HTTP-код или error_code, retry_after — пауза для 429."""

    def __init__(self, code, text, retry_after=None):
        super().__init__(text)
        self.code = code
        ok = isinstance(retry_after, (int, float)) and not isinstance(retry_after, bool) and 0 < retry_after <= 3600
        self.retry_after = retry_after if ok else None


class NetError(Exception):
    """Bot API недоступен: нет связи, таймаут, оборванный или не тот ответ."""


class Api:
    """Клиент Bot API на urllib. Без прокси, даже если он задан в окружении."""

    def __init__(self, base, token):
        self.base = base
        self.token = token
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def scrub(self, text):
        return str(text).replace(self.token, "***") if self.token else str(text)

    def call(self, method, params=None, timeout=20):
        req = urllib.request.Request(f"{self.base}/bot{self.token}/{method}",
                                     data=json.dumps(params or {}, ensure_ascii=False).encode("utf-8"),
                                     headers={"Content-Type": "application/json"})
        try:
            with self.opener.open(req, timeout=timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            try:
                body = json.loads(e.read().decode("utf-8", "replace"))
            except (ValueError, OSError, http.client.HTTPException):
                body = {}
            if not isinstance(body, dict):
                body = {}
            extra = body.get("parameters") if isinstance(body.get("parameters"), dict) else {}
            raise ApiError(e.code, self.scrub(body.get("description") or f"HTTP {e.code}"),
                           extra.get("retry_after")) from None
        except (urllib.error.URLError, OSError, http.client.HTTPException) as e:
            reason = getattr(e, "reason", None) or e
            raise NetError(self.scrub(str(reason) or type(reason).__name__)) from None
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise NetError("ответ Bot API не JSON") from None
        if not isinstance(data, dict) or not data.get("ok"):
            data = data if isinstance(data, dict) else {}
            raise ApiError(data.get("error_code") or 0, self.scrub(data.get("description") or "ответ без ok"))
        return data.get("result")


def normalize(data):
    """bot.json -> настройки с полями по умолчанию. Админы без числового id отбрасываются."""
    cfg = dict(DEFAULTS)
    if isinstance(data, dict):
        cfg.update({k: data[k] for k in DEFAULTS if k in data})
    cfg["enabled"] = cfg["enabled"] is True
    admins = cfg["admins"] if isinstance(cfg["admins"], list) else []
    cfg["admins"] = [a for a in admins if isinstance(a, dict) and type(a.get("id")) is int]
    cfg["username"] = cfg["username"] if isinstance(cfg["username"], str) else ""
    return cfg


def migrate_role(base):
    """role из migrate.conf: source, target или пусто, если переноса нет."""
    try:
        lines = (base / "migrate.conf").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return next((line[5:].strip() for line in lines if line.startswith("role=")), "")


class Bot:
    POLL = 50          # секунд ждёт getUpdates
    MAX_PAUSE = 60     # пауза между попытками при ошибках растёт до этой
    IDLE = 3           # секунд между проверками настроек, пока бот не работает
    STALE = 300        # сообщения, отправленные раньше запуска на столько секунд, пропускаются
    STRANGER_LOG = 60  # сообщения одного чужого пишутся в журнал не чаще раза в столько секунд
    CODE_TRIES = 5     # кодов приглашения в минуту от одного чужого, дальше бот молчит

    def __init__(self, base, iof, jobs=None, cache=None, api=None, log=None):
        self.base = Path(base)
        self.iof = iof
        # Очередь задач и опрос узлов панели: ими пользуются команды бота следующих этапов
        self.jobs, self.cache = jobs, cache
        self.api_base = (api or DEFAULT_API).strip().rstrip("/")
        self.log = log or (lambda text: None)
        self.host = socket.gethostname()
        self.lock = threading.Lock()
        self.keys = {}            # путь -> (mtime, размер, inode) при последнем чтении
        self.cfg = normalize(None)
        self.token = ""
        self.username = ""
        self.offset = None
        self.since = time.time()
        self.ready = False        # getMe и setMyCommands для текущего токена сделаны
        self.status = {"state": "starting", "error": None, "since": time.time()}
        self.strangers = {}       # чужой id -> когда его сообщение последний раз записано в журнал
        self.tries = {}           # чужой id -> времена попыток кода за последнюю минуту

    def start(self):
        threading.Thread(target=self.run, name="iof-bot", daemon=True).start()

    def state(self):
        """Состояние для панели: off, no_token, migrate, running, error, conflict."""
        with self.lock:
            return dict(self.status, username=self.username,
                        api=None if self.api_base == DEFAULT_API else self.api_base)

    def scrub(self, text):
        return str(text).replace(self.token, "***") if self.token else str(text)

    def set_state(self, state, error=None):
        with self.lock:
            old = self.status
            if old["state"] == state and old["error"] == error:
                return
            self.status = {"state": state, "error": error, "since": time.time()}
        if state == "running":
            self.log(f"бот: работает, @{self.username}")
        elif old["state"] != "starting" or state != "off":
            self.log(f"бот: {error or state}")

    # Файлы iof

    @staticmethod
    def stat(path):
        """Отметка версии файла: iof пишет bot.json и bot.token новым файлом, inode меняется всегда."""
        try:
            st = path.stat()
        except OSError:
            return None
        return st.st_mtime_ns, st.st_size, st.st_ino

    def files(self):
        return self.base / "bot.json", self.base / "bot.token"

    def wait(self, seconds):
        """Пауза, которая кончается раньше, если iof bot поменял настройки или токен."""
        end = time.time() + seconds
        marks = [self.stat(p) for p in self.files()]
        while time.time() < end:
            time.sleep(min(1.0, max(0.0, end - time.time())))
            if [self.stat(p) for p in self.files()] != marks:
                return

    def changed(self, path):
        """Текст файла, если он изменился с прошлого чтения ("" — файла нет), иначе None."""
        key = self.stat(path)
        if path in self.keys and self.keys[path] == key:
            return None
        self.keys[path] = key
        if key is None:
            return ""
        try:
            return path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return ""

    def load(self):
        """Перечитывает bot.json и bot.token, если они изменились. С новым токеном всё с начала:
        offset, getMe и команды бота, отсчёт старых сообщений."""
        cfg_path, token_path = self.files()
        text = self.changed(cfg_path)
        if text is not None:
            try:
                data = json.loads(text) if text else None
            except ValueError:
                self.log("бот: bot.json не читается, бот считается выключенным")
                data = None
            self.cfg = normalize(data)
        text = self.changed(token_path)
        if text is not None:
            token = text.strip()
            if token and not TOKEN.match(token):
                self.log("бот: в bot.token не токен, задай его заново: sudo iof bot token")
                token = ""
            if token != self.token:
                self.token, self.offset, self.ready, self.since = token, None, False, time.time()

    def idle(self):
        """Почему бот сейчас не опрашивает Telegram: (состояние, текст) или None."""
        if not API_URL.match(self.api_base):
            return "error", "IOF_TG_API в web.env: нужен адрес вида https://api.telegram.org"
        if not self.cfg["enabled"]:
            return "off", "выключен"
        if not self.token:
            return "no_token", "нет токена: sudo iof bot token"
        # Иначе один токен опрашивали бы оба сервера. Бот запустится сам после iof migrate finish
        if migrate_role(self.base) == "target":
            return "migrate", "не работает, пока сервер принимает управление при переносе"
        return None

    # Цикл опроса

    def run(self):
        pause = 0
        while True:
            try:
                self.cycle()
                pause = 0
                continue
            except ApiError as e:
                pause = e.retry_after if e.code == 429 and e.retry_after else min(self.MAX_PAUSE, max(1, pause * 2))
                if e.code in (401, 404):
                    pause = self.MAX_PAUSE
                    self.set_state("error", f"Telegram не принял токен ({e.code}): задай новый: sudo iof bot token")
                elif e.code == 409:
                    self.set_state("conflict", f"этот токен опрашивает кто-то ещё (409): {e}. Останови другую "
                                               "программу с этим токеном или выпусти новый у @BotFather")
                else:
                    self.set_state("error", f"Bot API ответил ошибкой {e.code}: {e}")
            except NetError as e:
                pause = min(self.MAX_PAUSE, max(1, pause * 2))
                self.set_state("error", f"нет связи с {self.api_base}: {e}")
            except Exception as e:  # ошибка в коде бота не должна останавливать поток
                pause = min(self.MAX_PAUSE, max(1, pause * 2))
                self.set_state("error", f"ошибка бота: {self.scrub(repr(e))}")
                self.log(self.scrub(traceback.format_exc()).rstrip())
            self.wait(pause)

    def cycle(self):
        self.load()
        why = self.idle()
        if why:
            self.set_state(*why)
            self.wait(self.IDLE)
            return
        token = self.token
        api = Api(self.api_base, token)
        if not self.ready:
            self.prepare(api)
        elif self.status["state"] in ("starting", "off", "no_token", "migrate"):
            # Токен уже проверен, бот снова опрашивает Telegram: «работает» сразу, а не после ответа
            # на опрос (до POLL секунд). После ошибки — только когда опрос пройдёт
            self.set_state("running")
        params = {"timeout": self.POLL, "allowed_updates": ["message", "callback_query"]}
        if self.offset is not None:
            params["offset"] = self.offset
        updates = api.call("getUpdates", params, timeout=self.POLL + 15)
        self.set_state("running")
        # Пока шёл опрос, бота могли выключить или сменить токен: тогда апдейты не обрабатываются
        # и не подтверждаются
        self.load()
        if self.token != token or self.idle():
            return
        for upd in updates if isinstance(updates, list) else []:
            if not isinstance(upd, dict) or type(upd.get("update_id")) is not int:
                continue
            self.offset = upd["update_id"] + 1
            try:
                self.handle(api, upd)
            except (ApiError, NetError) as e:
                self.log(f"бот: не удалось ответить: {e}")

    def prepare(self, api):
        """getMe (токен рабочий, имя бота) и меню команд, при запуске и с новым токеном."""
        me = api.call("getMe")
        self.username = me.get("username", "") if isinstance(me, dict) else ""
        try:
            api.call("setMyCommands", {"commands": [{"command": c, "description": d} for c, d in COMMANDS]})
        except ApiError as e:
            if e.code in (401, 404):
                raise
            self.log(f"бот: меню команд не установлено: {e}")
        self.ready = True
        self.set_state("running")

    # Сообщения

    def handle(self, api, upd):
        msg = upd.get("message")
        if not isinstance(msg, dict):
            return
        chat, user = msg.get("chat"), msg.get("from")
        if not isinstance(chat, dict) or not isinstance(user, dict):
            return
        # Группы, супергруппы и каналы бот не читает и не отвечает в них даже админам
        if chat.get("type") != "private" or type(user.get("id")) is not int or user.get("is_bot"):
            return
        date = msg.get("date")
        if not isinstance(date, int) or date < self.since - self.STALE:
            return
        text = msg.get("text").strip() if isinstance(msg.get("text"), str) else ""
        invite = INVITE.match(text)
        admin = next((a for a in self.cfg["admins"] if a["id"] == user["id"]), None)
        if admin is None:
            if invite:
                self.redeem(api, chat["id"], user, invite.group(1).lower())
            else:
                self.stranger(user)
            return
        if invite:
            return self.send(api, chat["id"], "Ты уже админ, код не нужен. Неиспользованное приглашение "
                                              "лучше отозвать: sudo iof bot invite del &lt;начало хэша&gt;")
        m = COMMAND.match(text)
        cmd = m.group(1).lower() if m and (not m.group(2) or m.group(2).lower() == self.username.lower()) else ""
        if cmd == "start":
            self.send(api, chat["id"], self.greeting(admin, user))
        elif cmd == "help":
            self.send(api, chat["id"], self.help_text())
        else:
            self.send(api, chat["id"], "Не понял. Что я умею: /help")

    def greeting(self, admin, user):
        name = clean(user.get("first_name") or admin.get("name"), 64) or "админ"
        return (f"Привет, {esc(name)}! Это бот iof на сервере <b>{esc(self.host)}</b>.\n"
                f"Ты админ, роль: <b>{esc(ROLES.get(admin.get('role'), admin.get('role')))}</b>.\n\n"
                "Что я умею: /help")

    def help_text(self):
        lines = ["<b>Команды</b>"] + [f"/{c} — {esc(d.lower())}" for c, d in COMMANDS]
        lines += ["", "Админов добавляют приглашением, а удаляют и меняют им роль только на сервере: "
                      "в панели iof-web или командой sudo iof bot."]
        return "\n".join(lines)

    def stranger(self, user):
        """Чужим бот не отвечает, а в журнал пишет ID и username, не чаще раза в минуту на ID."""
        uid, now = user["id"], time.time()
        if now - self.strangers.get(uid, 0) < self.STRANGER_LOG:
            return
        if len(self.strangers) > 1000:
            self.strangers = {k: t for k, t in self.strangers.items() if now - t < self.STRANGER_LOG}
        self.strangers[uid] = now
        self.log(f"бот: сообщение от чужого, без ответа: {self.who(user)}")

    @staticmethod
    def who(user):
        username = user.get("username")
        return f"id {user['id']}" + (f" @{username}" if isinstance(username, str) and USERNAME.match(username) else "")

    def redeem(self, api, chat_id, user, code):
        """Код приглашения проверяет и тратит iof bot redeem: в bot.json только хэши кодов."""
        uid, now = user["id"], time.time()
        tries = [t for t in self.tries.get(uid, ()) if now - t < 60]
        if len(tries) >= self.CODE_TRIES:
            self.tries[uid] = tries
            return
        if len(self.tries) > 1000:
            self.tries = {k: v for k, v in self.tries.items() if v and now - v[-1] < 60}
        self.tries[uid] = tries + [now]
        name = clean(" ".join(str(user.get(k) or "") for k in ("first_name", "last_name")), 64)
        username = user.get("username") if isinstance(user.get("username"), str) and USERNAME.match(user["username"]) else ""
        out, error = self.iof_cmd(["bot", "redeem"], f"{code}\n{uid}\n{name}\n{username}\n")
        result, role = out.get("result"), ROLES.get(out.get("role"), out.get("role", ""))
        if error:
            self.log(f"бот: код приглашения от {self.who(user)} не проверен: {error}")
            if "перенос" in error:
                return self.send(api, chat_id, "Сейчас приглашения не принимаются: идёт перенос управления "
                                                "на другой сервер. Попробуй позже.")
            return self.send(api, chat_id, "Не получилось проверить код, попробуй позже.")
        if result == "added":
            self.log(f"бот: новый админ {self.who(user)}, роль {role}")
            self.load()
            return self.send(api, chat_id, f"Готово, ты админ iof на сервере <b>{esc(self.host)}</b>.\n"
                                           f"Роль: <b>{esc(role)}</b>.\n\nЧто я умею: /help")
        if result == "already":
            return self.send(api, chat_id, "Ты уже админ, код не нужен.")
        self.log(f"бот: код приглашения не подошёл: {self.who(user)}")
        self.send(api, chat_id, "Код не подошёл: он неверный, уже использован или истёк. Попроси новый.")

    def iof_cmd(self, args, stdin):
        """iof с данными через stdin -> (key=value из вывода, текст ошибки или None)."""
        env = dict(os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8")
        try:
            p = subprocess.run([self.iof, *args], input=stdin.encode("utf-8"), capture_output=True,
                               timeout=30, env=env)
        except (OSError, subprocess.TimeoutExpired) as e:
            return {}, f"iof не запустился: {e}"
        out = dict(line.split("=", 1) for line in p.stdout.decode("utf-8", "replace").splitlines() if "=" in line)
        if p.returncode != 0:
            err = p.stderr.decode("utf-8", "replace").strip().splitlines()
            line = next((s for s in err if s.startswith("Ошибка: ")), err[-1] if err else f"код {p.returncode}")
            return out, line.removeprefix("Ошибка: ")
        return out, None

    def send(self, api, chat_id, text):
        """Сообщение в HTML, длинное — частями по строкам, не длиннее MAX_TEXT. На 429 одна повторная попытка."""
        parts, cur = [], ""
        for line in text.split("\n"):
            while len(line) > MAX_TEXT:
                parts.append(line[:MAX_TEXT])
                line = line[MAX_TEXT:]
            if cur and len(cur) + 1 + len(line) > MAX_TEXT:
                parts.append(cur)
                cur = line
            else:
                cur = f"{cur}\n{line}" if cur else line
        parts.append(cur)
        for part in parts:
            params = {"chat_id": chat_id, "text": part, "parse_mode": "HTML",
                      "link_preview_options": {"is_disabled": True}}
            try:
                api.call("sendMessage", params)
            except ApiError as e:
                if e.code != 429 or not e.retry_after or e.retry_after > 30:
                    raise
                time.sleep(e.retry_after)
                api.call("sendMessage", params)
