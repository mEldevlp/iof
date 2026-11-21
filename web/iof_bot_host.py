"""Размещение Telegram-бота и обмен с его процессом через stdin/stdout SSH."""

import base64
import contextlib
import fcntl
import json
import os
import queue
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import iof_bot


NODE_DATA = Path("/var/lib/iof-bot")
NODE_RUN = Path("/run/iof-bot")
SSH = re.compile(r"(?:(?P<user>[a-z_][a-z0-9_-]*)@)?(?P<host>[A-Za-z0-9][A-Za-z0-9.-]*)(?::(?P<port>[0-9]{1,5}))?")
TOKEN_TEXT = re.compile(r"[0-9]{1,20}:[A-Za-z0-9_-]{20,100}")
STOP_TIMEOUT = iof_bot.Bot.POLL + 40
BOOTSTRAP = """
import json, sys, types
bot_source, host_source, args = json.loads(sys.stdin.readline())
bot = types.ModuleType("iof_bot")
sys.modules["iof_bot"] = bot
exec(compile(bot_source, "iof_bot.py", "exec"), bot.__dict__)
host = {}
exec(compile(host_source, "iof_bot_host.py", "exec"), host)
host["remote_main"](*args)
"""


def route_for(target):
    if not target or target == "local":
        return ""
    match = SSH.fullmatch(target)
    if not match or not 1 <= int(match["port"] or 22) <= 65535:
        raise ValueError("Некорректный адрес SSH узла")
    port = int(match["port"] or 22)
    return f"{match['user'] or 'root'}@{match['host'].lower()}" + (f":{port}" if port != 22 else "")


def ssh_command(route, key):
    match = SSH.fullmatch(route)
    target = f"{match['user']}@{match['host']}"
    command = ["python3", "-u", "-c", BOOTSTRAP]
    if match["user"] != "root":
        command[:0] = ["sudo", "-n"]
    return ["ssh", "-T", "-i", key, "-p", match["port"] or "22",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2", "-o", "StrictHostKeyChecking=accept-new",
            "-o", "LogLevel=ERROR", "--", target, shlex.join(command)]


def frame(value):
    return (json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n").encode("ascii")


def safe_text(message):
    return iof_bot.LINK_SECRET.sub(r"\1***@", TOKEN_TEXT.sub("***", str(message)))


def atomic_write(path, value):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        tmp = Path(stream.name)
        try:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(tmp, path)
        finally:
            tmp.unlink(missing_ok=True)
    sync_dir(path.parent)


def sync_dir(directory):
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


@contextlib.contextmanager
def locked(path, wait=0):
    with os.fdopen(os.open(path, os.O_CREAT | os.O_RDWR, 0o600)) as lock:
        until = time.monotonic() + wait
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= until:
                    raise ValueError("Предыдущий процесс бота ещё работает")
                time.sleep(0.25)
        yield


class Poll:
    """Блокировка процесса и отметка запроса, переживающая его аварийное завершение."""

    def __init__(self, base):
        self.lock = base / "bot.poll.lock"
        self.pending = base / "bot.poll"

    def drain(self, stop=None):
        if self.pending.exists():
            # При обрыве Telegram ещё может держать прежний long poll. Ждём полный
            # интервал с запасом, даже после перезагрузки узла и смены его часов.
            delay = iof_bot.Bot.POLL + 15
            if stop is None:
                time.sleep(delay)
            elif stop.wait(delay):
                return
            self.pending.unlink()

    def request(self, api, params):
        atomic_write(self.pending, b"")
        try:
            updates = api.call("getUpdates", params, timeout=params["timeout"] + 15)
        except iof_bot.ApiError:
            self.pending.unlink()
            raise
        self.pending.unlink()
        return updates


class HostedBot(iof_bot.Bot):
    def __init__(self, base, iof, poll, **kwargs):
        super().__init__(base, iof, **kwargs)
        self.poll_fence = poll
        self.activated = threading.Event()

    def poll(self, api, params):
        self.poll_fence.drain(self.stopped)
        if not self.poll_allowed():
            return []
        return self.poll_fence.request(api, params)

    def poll_allowed(self):
        return not self.stopped.is_set()

    def accept_updates(self):
        while not self.stopped.is_set():
            if self.activated.wait(0.2):
                return True
        return False


class Channel:
    """Один запрос за раз от потоков бота. Обрыв SSH останавливает цикл опроса."""

    def __init__(self):
        self.lock = threading.Lock()

    def call(self, name, *args):
        with self.lock:
            try:
                sys.stdout.buffer.write(frame([name, args]))
                sys.stdout.buffer.flush()
                raw = sys.stdin.buffer.readline()
            except OSError:
                raise SystemExit from None
        if not raw:
            raise SystemExit
        reply = json.loads(raw)
        if reply.get("stop"):
            raise SystemExit
        if "error" in reply:
            raise ValueError(reply["error"])
        return reply["result"]


class RemoteViews:
    def __init__(self, channel, prefix):
        self.channel, self.prefix = channel, prefix

    def __getattr__(self, name):
        return lambda *args: self.channel.call(f"{self.prefix}.{name}", *args)

    def qr_png(self, links):
        result = self.channel.call("views.qr_png", links)
        return None if result is None else base64.b64decode(result)


class RemoteBot(HostedBot):
    def __init__(self, channel, api, poll):
        self.channel = channel
        self.snapshot = {}
        super().__init__(NODE_RUN, None, poll, api=api, views=RemoteViews(channel, "views"),
                         cache=RemoteViews(channel, "cache"), jobs=RemoteViews(channel, "jobs"),
                         actions=RemoteViews(channel, "actions"))
        self.host = channel.call("controller")

    def load(self):
        self.snapshot = self.channel.call("config")
        token = self.snapshot.pop("token")
        if token != self.token:
            path = self.files()[1]
            if token:
                atomic_write(path, (token + "\n").encode("ascii"))
            else:
                path.unlink(missing_ok=True)
            self.token, self.offset, self.ready, self.since = token, None, False, time.time()
            self.verified = False
        self.cfg = iof_bot.normalize(self.snapshot["config"])

    def idle(self):
        if self.snapshot.get("role") == "target":
            return "migrate", "не работает, пока сервер принимает управление при переносе"
        return super().idle()

    def wait(self, seconds):
        token, config = self.token, self.cfg
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            time.sleep(min(1.0, max(0, end - time.monotonic())))
            self.load()
            if (self.token, self.cfg) != (token, config):
                return

    def set_state(self, state, error=None):
        old = self.status
        super().set_state(state, error)
        if old is not self.status:
            # Причина с Telegram уже очищена клиентом, на панели она фильтруется ещё раз.
            self.channel.call("state", self.state())

    def iof_cmd(self, args, stdin):
        if args != ["bot", "redeem"]:
            return {}, "Команда недоступна из бота"
        return self.channel.call("redeem", stdin)

    def start_job(self, title, steps, pending):
        return self.channel.call("jobs.start", pending["uid"], pending["kind"], pending["body"])

    def accept_updates(self):
        return self.channel.call("activate")

    def poll_allowed(self):
        return self.channel.call("poll")

    def links_for(self, name, chat_id):
        return self.channel.call("views.hy2_links", name, chat_id)


def probe(api, token):
    api = api.rstrip("/")
    if not iof_bot.API_URL.fullmatch(api):
        raise ValueError("Некорректный адрес Bot API")
    try:
        data = iof_bot.Api(api, token or "0:" + "A" * 20).call("getMe", timeout=12)
    except iof_bot.NetError:
        raise ValueError("Нет связи с Telegram с выбранного сервера") from None
    except iof_bot.ApiError as error:
        if error.code in (401, 404):
            if not token:
                return
            raise ValueError("Telegram не принял сохранённый токен") from None
        raise ValueError(f"Telegram отклонил проверку (код {error.code})") from None
    if not isinstance(data, dict) or not iof_bot.USERNAME.fullmatch(str(data.get("username", ""))):
        raise ValueError("Telegram не вернул имя бота")


def remote_main(mode, api, token=""):
    os.umask(0o077)
    try:
        if mode == "probe":
            probe(api, token)
        else:
            NODE_DATA.mkdir(exist_ok=True, mode=0o700)
            poll = Poll(NODE_DATA)
            with locked(poll.lock, wait=12):
                if mode == "fence":
                    poll.drain()
                    (NODE_RUN / "bot.token").unlink(missing_ok=True)
                else:
                    NODE_RUN.mkdir(exist_ok=True, mode=0o700)
                    path = NODE_RUN / "bot.token"
                    path.unlink(missing_ok=True)
                    try:
                        RemoteBot(Channel(), api, poll).run()
                    finally:
                        path.unlink(missing_ok=True)
        if mode != "run":
            print("{}")
    except (OSError, ValueError) as error:
        print(json.dumps({"error": safe_text(error)}, ensure_ascii=True))


class Worker:
    def __init__(self, host, route, staged=False):
        self.host, self.route = host, route
        self.bot = None
        self.stop = threading.Event()
        self.activated = threading.Event()
        if not staged:
            self.activated.set()
        self.ended = None
        self.status = {"state": "starting", "error": None, "since": time.time(), "username": "",
                       "api": None if host.api == iof_bot.DEFAULT_API else host.api}
        self.thread = threading.Thread(target=self.run, name="iof-bot-worker", daemon=True)
        self.thread.start()

    def state(self):
        return self.bot.state() if self.bot else self.status

    def run(self):
        try:
            if self.route:
                self.remote()
            else:
                poll = Poll(self.host.base)
                with locked(poll.lock):
                    self.bot = HostedBot(self.host.base, self.host.iof, poll, **self.host.options)
                    self.bot.stopped = self.stop
                    self.bot.activated = self.activated
                    self.bot.run()
        except (OSError, ValueError) as error:
            self.status = dict(self.status, state="error", error=safe_text(error))
        finally:
            self.ended = time.monotonic()

    def remote(self):
        with subprocess.Popen(ssh_command(self.route, self.host.key), stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as proc:
            try:
                proc.stdin.write(self.host.wire("run"))
                proc.stdin.flush()
                for line in proc.stdout:
                    try:
                        request = json.loads(line)
                    except ValueError:
                        raise ValueError("Неверный ответ процесса бота по SSH") from None
                    if isinstance(request, dict):
                        raise ValueError(request.get("error", "Не удалось запустить процесс бота на узле"))
                    if not isinstance(request, list) or len(request) != 2:
                        raise ValueError("Неверный запрос процесса бота по SSH")
                    if self.stop.is_set():
                        reply = {"stop": True}
                    else:
                        reply = self.dispatch(*request)
                    proc.stdin.write(frame(reply))
                    proc.stdin.flush()
                if not self.stop.is_set():
                    raise ValueError("Потеряна связь с процессом бота по SSH")
            finally:
                proc.stdin.close()
                try:
                    proc.wait(timeout=STOP_TIMEOUT)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

    def dispatch(self, name, args):
        try:
            if name == "poll":
                return {"result": True}
            if name == "activate":
                while not self.stop.is_set():
                    if self.activated.wait(0.2):
                        return {"result": True}
                return {"stop": True}
            if name == "state":
                state, = args
                status = {**self.status, **{k: state[k] for k in ("state", "since", "username", "error")}}
                for k in ("username", "error"):
                    if status[k]:
                        status[k] = safe_text(status[k])
                self.status = status
                return {"result": None}
            return {"result": self.host.call(name, args)}
        except ValueError as error:
            return {"error": safe_text(error)}
        except Exception:
            return {"error": "Ошибка служебного запроса к панели"}


class BotHost:
    def __init__(self, base, iof, key, *, views, cache, actions, jobs, api, log):
        self.base, self.iof, self.key = base, iof, key
        self.api = (api or iof_bot.DEFAULT_API).strip().rstrip("/")
        self.log = log
        self.options = dict(views=views, cache=cache, actions=actions, jobs=jobs, api=self.api, log=log)
        self.views, self.actions, self.jobs = views, actions, jobs
        self.calls = {"views." + name: getattr(views, name)
                      for name in ("nodes", "node", "service", "audit", "hy2", "migrate")}
        self.calls.update({"cache.fresh": cache.fresh, "cache.get": cache.get, "jobs.list": jobs.list})
        self.redeemer = iof_bot.Bot(base, iof)
        self.place = base / "bot.server"
        self.journal = base / "bot.move.json"
        self.guard = base / "bot.server.lock"
        self.route = ""
        self.worker = None
        self.progress = None
        self.error = None
        self.requests = queue.Queue()
        self.mutex = threading.Lock()
        self.closing = threading.Event()
        self.thread = threading.Thread(target=self.run, name="iof-bot-host", daemon=True)

    def start(self):
        self.thread.start()

    def close(self):
        self.closing.set()
        if self.worker:
            self.worker.stop.set()
        self.thread.join(STOP_TIMEOUT)

    def state(self):
        if self.error:
            return {"state": "error", "error": self.error, "since": None}
        if self.worker:
            return self.worker.state()
        return {"state": "starting", "since": None}

    def token(self):
        try:
            token = (self.base / "bot.token").read_text(encoding="ascii").strip()
        except (FileNotFoundError, UnicodeError):
            return ""
        return token if iof_bot.TOKEN.fullmatch(token) else ""

    def config(self):
        try:
            data = json.loads((self.base / "bot.json").read_text(encoding="utf-8"))
        except (FileNotFoundError, ValueError):
            data = None
        cfg = iof_bot.normalize(data)
        cfg.pop("invites", None)
        return cfg

    def call(self, name, args):
        if name in self.calls:
            return self.calls[name](*args)
        if name == "controller":
            return socket.gethostname()
        if name == "config":
            return {"config": self.config(), "token": self.token(), "role": iof_bot.migrate_role(self.base)}
        if name == "redeem":
            return self.redeemer.iof_cmd(["bot", "redeem"], *args)
        if name == "views.qr_png":
            png = self.views.qr_png(*args)
            return None if png is None else base64.b64encode(png).decode("ascii")
        cfg = self.config()
        if name == "views.hy2_links":
            group, uid = args
            if cfg["enabled"] and cfg["hy2_links"] and any(a["id"] == uid for a in cfg["admins"]):
                return self.views.hy2_links(group)
            raise ValueError("Выдача ссылок недоступна")
        if name == "actions.plan":
            title, steps = self.actions.plan(*args)
            return title, [[s[0]] for s in steps]
        if name == "jobs.start":
            uid, kind, body = args
            if not (cfg["enabled"] and cfg["actions"] and
                    any(a["id"] == uid and a.get("role") == "main" for a in cfg["admins"])):
                raise ValueError("Действие доступно только главному админу при включённых действиях")
            title, steps = self.actions.plan(kind, body)
            return self.jobs.start(title, steps, "bot")
        raise ValueError("Неизвестный служебный запрос бота")

    def wire(self, mode, *args):
        return frame([Path(iof_bot.__file__).read_text(encoding="utf-8"),
                      Path(__file__).read_text(encoding="utf-8"), [mode, self.api, *args]])

    def remote_command(self, route, mode, *args, timeout):
        try:
            p = subprocess.run(ssh_command(route, self.key), input=self.wire(mode, *args),
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)
        except (subprocess.TimeoutExpired, OSError):
            raise ValueError("Узел не ответил по SSH вовремя") from None
        if p.returncode == 255:
            raise ValueError("Не удалось подключиться к узлу по SSH, проверь доступ ключом iof")
        if p.returncode == 127:
            raise ValueError("На узле нужен python3")
        try:
            result = json.loads(p.stdout) if not p.returncode else None
        except ValueError:
            result = None
        if not isinstance(result, dict):
            raise ValueError("Не удалось выполнить команду на узле, проверь python3 и права SSH")
        if result.get("error"):
            raise ValueError(safe_text(result["error"]))

    def current(self):
        try:
            return route_for(self.place.read_text(encoding="ascii").strip())
        except FileNotFoundError:
            return ""

    def submit(self, route, label, available):
        with self.mutex:
            if self.progress and self.progress["running"]:
                raise ValueError("Перенос бота уже идёт")
            if route == self.current():
                raise ValueError("Этот сервер уже выбран для бота")
            self.update("Проверяем выбранный сервер", True, label)
            self.requests.put((route, label, available))

    def update(self, message, running, label, error=False):
        self.progress = {"target": label, "message": message, "running": running, "error": error}

    def fence(self, route):
        if route:
            self.remote_command(route, "fence", timeout=STOP_TIMEOUT)
        else:
            poll = Poll(self.base)
            with locked(poll.lock):
                poll.drain()

    def stop_worker(self):
        if self.worker:
            self.worker.stop.set()
            self.worker.thread.join(STOP_TIMEOUT)
            if self.worker.thread.is_alive():
                raise ValueError("Предыдущий процесс бота не завершил работу вовремя")
            self.worker = None

    def recover(self):
        if not self.journal.exists():
            return False
        data = json.loads(self.journal.read_text(encoding="ascii"))
        if not isinstance(data, dict) or not isinstance(data.get("target"), str):
            raise ValueError("Повреждена запись прерванного переноса бота")
        target = route_for(data["target"])
        rollback = self.current() != target
        if rollback:
            self.fence(target)
        self.journal.unlink()
        sync_dir(self.base)
        return rollback

    def move(self, route, label, available):
        with locked(self.guard):
            self.recover()
            if iof_bot.migrate_role(self.base):
                raise ValueError("Дождись окончания переноса управления")
            if route and not available():
                raise ValueError("Выбранного узла больше нет в списке")
            old = self.current()
            token = self.token()
            if route:
                self.update("Проверяем SSH и доступ к Telegram", True, label)
                self.remote_command(route, "probe", token, timeout=30)
            else:
                self.update("Проверяем доступ к Telegram с управляющего сервера", True, label)
                probe(self.api, token)
            self.update("Ждём завершения опроса на прежнем сервере", True, label)
            self.stop_worker()
            self.fence(old)
            atomic_write(self.journal, frame({"target": route}))
            try:
                self.update("Запускаем бота на выбранном сервере", True, label)
                self.worker = Worker(self, route, staged=True)
                self.await_ready()
                atomic_write(self.place, (route + "\n").encode("ascii"))
            except (ValueError, OSError) as error:
                self.update("Восстанавливаем работу на прежнем сервере", True, label)
                try:
                    self.stop_worker()
                    self.recover()
                    if not self.closing.is_set():
                        self.worker = Worker(self, old)
                except (ValueError, OSError) as recovery:
                    raise ValueError(f"{error}. Восстановление ещё не завершено: {recovery}") from None
                raise ValueError(f"{error}. Сохранён прежний сервер бота") from None
            self.route = route
            self.worker.activated.set()
            self.recover()
            self.update(f"Сервер бота изменён на «{label}»", False, label)

    def await_ready(self):
        until = time.monotonic() + STOP_TIMEOUT
        while time.monotonic() < until and not self.closing.is_set():
            state = self.worker.state()
            if state["state"] in ("running", "off", "no_token"):
                return
            if not self.worker.thread.is_alive() or state["state"] in ("error", "conflict"):
                raise ValueError(state.get("error") or "Процесс бота завершился при запуске")
            self.closing.wait(0.2)
        raise ValueError("Бот не запустился вовремя")

    def run(self):
        try:
            with locked(self.base / "bot.host.lock"):
                self.supervise()
        except (ValueError, OSError) as error:
            self.error = safe_text(error)

    def supervise(self):
        while not self.closing.is_set():
            try:
                request = self.requests.get(timeout=0.5)
            except queue.Empty:
                request = None
            try:
                if request:
                    self.move(*request)
                else:
                    self.route = self.current()
                    if self.journal.exists():
                        self.stop_worker()
                        if self.recover():
                            self.update("Прерванный перенос отменён. Сохранён прежний сервер бота",
                                        False, "", error=True)
                    if not self.worker or (self.worker.ended and time.monotonic() - self.worker.ended >= 3):
                        self.worker = Worker(self, self.route)
                self.error = None
            except (ValueError, OSError) as error:
                message = safe_text(error)
                if request:
                    self.update(message, False, request[1], error=True)
                    self.log(f"бот: перенос не выполнен. {message}")
                else:
                    self.error = message
                    self.closing.wait(3)
        self.stop_worker()
