"""Учётные данные и сеансы одного администратора панели."""

import argparse
from contextlib import contextmanager
import fcntl
import getpass
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile
import time
import warnings


LOGIN = re.compile(r"[A-Za-z0-9._-]{1,64}")
MAX_PASSWORD = 1024
ROUNDS = 600_000
SESSION_TTL = 12 * 3600


def password_ok(value):
    return isinstance(value, str) and 0 < len(value) <= MAX_PASSWORD and not any(
        char in "\x00\r\n" or 0xD800 <= ord(char) <= 0xDFFF for char in value)


def digest(password, salt, rounds):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), salt, rounds)


def atomic_write(path, text):
    # mkstemp создаёт файл с правами 600 в той же файловой системе.
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


# EnvironmentFile systemd: кавычки сразу после знака =, переносы и экранирование.
# Не выполняем содержимое файла как shell и сохраняем остальные строки без изменений.
ENV_LINE = re.compile(
    r"^[ \t]*(?P<key>[A-Za-z_][A-Za-z_0-9]*)[ \t]*=[ \t]*"
    r"(?P<value>'[^']*'|\"(?:\\[\s\S]|[^\"\\])*\"|(?![ \t\"'])(?:\\[\s\S]|[^\\\n])*)"
    r"[ \t\r]*(?:\n|$)", re.M)


def legacy_password(contents):
    matches = [m for m in ENV_LINE.finditer(contents) if m["key"] == "IOF_WEB_PASSWORD"]
    if not matches:
        return "", contents
    value = matches[-1]["value"]
    if value.startswith("'"):
        value = value[1:-1]
    elif value.startswith('"'):
        value = re.sub(r'\\(["\\$`\n])', lambda m: m[1].strip("\n"), value[1:-1])
    else:
        parts = re.findall(r"\\[\s\S]|[^\\]", value)
        while parts and parts[-1] in (" ", "\t", "\r"):
            parts.pop()
        value = "".join(part[1:].strip("\n") if part.startswith("\\") else part for part in parts)
    for match in reversed(matches):
        contents = contents[:match.start()] + contents[match.end():]
    return value, contents


class Credentials:
    def __init__(self, base):
        self.base = base
        self.path = base / "web-auth.json"

    @contextmanager
    def locked(self):
        self.base.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(self.base / "web-auth.lock", os.O_CREAT | os.O_RDWR, 0o600)
        with os.fdopen(fd, "rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def read(self):
        try:
            cfg = json.loads(self.path.read_text(encoding="utf-8"))
            if not (cfg["version"] == 1 and LOGIN.fullmatch(cfg["login"]) and type(cfg["rounds"]) is int
                    and 1 <= cfg["rounds"] <= ROUNDS
                    and len(bytes.fromhex(cfg["salt"])) == 16 and len(bytes.fromhex(cfg["hash"])) == 32
                    and len(bytes.fromhex(cfg["session_key"])) == 32):
                raise ValueError
        except (KeyError, TypeError, ValueError) as e:
            raise OSError("повреждён web-auth.json") from e
        return cfg

    @staticmethod
    def verify(cfg, password):
        if not isinstance(password, str):
            return False
        try:
            actual = digest(password, bytes.fromhex(cfg["salt"]), cfg["rounds"])
        except UnicodeError:
            return False
        return hmac.compare_digest(actual, bytes.fromhex(cfg["hash"]))

    def save(self, login, password):
        salt = secrets.token_bytes(16)
        cfg = {"version": 1, "login": login, "rounds": ROUNDS, "salt": salt.hex(),
               "hash": digest(password, salt, ROUNDS).hex(), "session_key": secrets.token_hex(32)}
        atomic_write(self.path, json.dumps(cfg) + "\n")

    @staticmethod
    def sign(cfg, scope, payload):
        return hmac.digest(bytes.fromhex(cfg["session_key"]), f"{scope}\n{payload}".encode(), "sha256").hex()

    def issue(self, cfg, scope):
        payload = f"{int(time.time()) + SESSION_TTL}.{secrets.token_hex(16)}"
        return f"{payload}.{self.sign(cfg, scope, payload)}"

    def valid(self, cfg, scope, token):
        if not re.fullmatch(r"[0-9]{1,12}\.[0-9a-f]{32}\.[0-9a-f]{64}", token):
            return False
        payload, mac = token.rsplit(".", 1)
        return int(payload.split(".", 1)[0]) > time.time() and hmac.compare_digest(self.sign(cfg, scope, payload), mac)

    def change(self, scope, token, current, new):
        with self.locked():
            cfg = self.read()
            if not self.valid(cfg, scope, token):
                return "Сеанс завершён. Войдите снова."
            if not self.verify(cfg, current):
                return "Неверный текущий пароль."
            self.save(cfg["login"], new)
        return None

    def initialize(self):
        with self.locked():
            env = self.base / "web.env"
            contents = env.read_text(encoding="utf-8") if env.exists() else ""
            old, cleaned = legacy_password(contents)
            if self.path.exists():
                self.read()
                message = "Учётные данные панели сохранены."
            elif old or os.environ.get("IOF_WEB_PASSWORD"):
                self.save("admin", old or os.environ["IOF_WEB_PASSWORD"])
                message = "Прежний пароль панели перенесён, логин: admin."
            else:
                login = input("Логин панели [admin]: ").strip() if sys.stdin.isatty() else ""
                login = login or "admin"
                if not LOGIN.fullmatch(login):
                    raise ValueError("логин: от 1 до 64 латинских букв, цифр или символов . _ -")
                self.save_prompted(login)
                message = f"Учётная запись панели создана, логин: {login}."
            # При сбое записи web.env готовый хеш сохраняется, повтор уберёт старую строку.
            if cleaned != contents:
                atomic_write(env, cleaned)
            print(message)

    def save_prompted(self, login, password_stdin=False):
        tty = None
        try:
            if password_stdin:
                password = sys.stdin.readline(MAX_PASSWORD + 2).removesuffix("\n")
                if not password:
                    raise ValueError("со stdin нужен непустой пароль")
            elif sys.stdin.isatty():
                tty = open("/dev/tty", "w", encoding="utf-8")
                password = getpass.getpass("Новый пароль панели (Enter — создать): ", stream=tty)
                if password and getpass.getpass("Подтверждение пароля: ", stream=tty) != password:
                    raise ValueError("пароли не совпадают")
            else:
                password = ""
            if password and not password_ok(password):
                raise ValueError(f"пароль: до {MAX_PASSWORD} символов, одной строкой")
            generated = not password
            password = password or secrets.token_hex(8)
            self.save(login, password)
            if generated:
                if tty:
                    print(f"Пароль панели: {password}", file=tty, flush=True)
                else:
                    print("Пароль создан. Чтобы задать известный пароль, выполни в терминале sudo iof web reset-password.")
        finally:
            if tty:
                tty.close()

    def reset(self, password_stdin):
        if not password_stdin and not sys.stdin.isatty():
            raise ValueError("запусти команду в терминале или передай пароль через --password-stdin")
        with self.locked():
            login = self.read()["login"]
            self.save_prompted(login, password_stdin)
        print(f"Пароль панели для {login} сброшен. Прежние сеансы отозваны.")


def main():
    ap = argparse.ArgumentParser(description="Учётные данные панели iof")
    ap.add_argument("action", choices=("init", "reset"))
    ap.add_argument("base", type=Path)
    ap.add_argument("--password-stdin", action="store_true")
    args = ap.parse_args()
    auth = Credentials(args.base)
    # При недоступном управлении эхом getpass завершится без чтения открытого пароля.
    warnings.filterwarnings("error", category=getpass.GetPassWarning)
    try:
        if args.action == "init":
            auth.initialize()
        else:
            auth.reset(args.password_stdin)
    except (OSError, ValueError, EOFError, getpass.GetPassWarning, KeyboardInterrupt) as e:
        sys.exit(f"Ошибка настройки входа в панель: {e}" if isinstance(e, ValueError) else
                 "Ошибка настройки входа в панель. Проверь файлы web-auth.json и web.env и доступ к терминалу.")


if __name__ == "__main__":
    main()
