"""Расписание и журнал cron управляющего сервера."""

import hashlib
import os
import pwd
import re
import stat
import subprocess
import tempfile
import time
from pathlib import Path


ROOT_TAB = "/var/spool/cron/crontabs/root"
CRON_SPOOL = Path(ROOT_TAB).parent
CRON_DIR = Path("/etc/cron.d")
SYSTEM_CRON = Path("/etc/crontab")
ANACRON = Path("/etc/anacrontab")
PERIODIC = [Path(f"/etc/cron.{period}") for period in ("hourly", "daily", "weekly", "monthly")]
CRON_FILENAME = re.compile(r"[\w-]+", re.ASCII)
TIME = r"(?:[01][0-9]|2[0-3]):[0-5][0-9]"
REACH_CMD = "umask 077; /usr/local/bin/iof check-from-ru --scheduled"
REACH_LOG = "/var/log/iof-check-from-ru.log"
REACH_LINE = re.compile(rf"{re.escape(REACH_CMD)} ({TIME}) ([0-9]+) >>{REACH_LOG} 2>&1")
NIGHTLY_CMD = "/usr/local/sbin/iof-nightly"
NIGHTLY_LINE = re.compile(r"(?:/usr/local/sbin/)?iof-nightly(?:[ \t]*[12]?>>?[ \t]*(?:&[12]|/[^\s;&|<>%]+))*")
TASKS = {
    "nightly": ("Ночное обслуживание", "Обновляет пакеты и перезагружает зарегистрированные узлы."),
    "reach": ("Доступность из РФ", "С управляющего сервера проверяет DNS и ping клиентских адресов, "
              "а также TCP-подключение к SSH-адресам и портам узлов."),
    "check": ("Проверка состояния узлов", "Опрашивает службы и ресурсы узлов. При изменениях уведомляет в Telegram."),
    "audit": ("Аудит безопасности", "Проверяет оба блока аудита и сообщает об ухудшениях."),
    "block": ("Обновление блок-листа", "Скачивает список и обновляет его на узлах, где включена блокировка."),
}
IOF_TASK = re.compile(
    r"(?:^|[\s/;&|])(?:iof-(nightly)|iof[ \t]+(check-from-ru|check|audit[ \t]+cron|block[ \t]+update))(?![\w-])"
)


def task_kind(command):
    match = IOF_TASK.search(command)
    if not match:
        return ""
    return "nightly" if match[1] else {"check-from-ru": "reach", "check": "check",
                                       "audit cron": "audit", "block update": "block"}[" ".join(match[2].split())]


def command(args, stdin=None):
    data = stdin.encode("utf-8", "surrogateescape") if stdin is not None else None
    return subprocess.run(args, input=data, capture_output=True, timeout=5, env={**os.environ, "LC_ALL": "C"})


class CronChanged(ValueError):
    """Запись изменилась после открытия страницы."""


def crontab(user):
    result = command(["crontab", "-u", user, "-l"])
    if result.returncode == 0:
        return result.stdout.decode("utf-8", "surrogateescape")
    if result.stderr.strip() == f"no crontab for {user}".encode():
        return ""
    raise ValueError(result.stderr.decode("utf-8", "replace").strip() or f"Не удалось прочитать crontab {user}")


def root_crontab():
    return crontab("root")


def revision(text):
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()


def tab_jobs(text, source, user, anacron=False, writable=True):
    rev = revision(text) if writable else ""
    for number, raw in enumerate(text.split("\n")):
        line = raw.lstrip(" \t")
        if not line.strip() or line.startswith("#") or re.match(r"^[a-zA-Z_][a-zA-Z0-9_]*\s*=", line):
            continue
        fields = 3 if anacron else (1 if line.startswith("@") else 5)
        parts = line.split(None, fields + (user is None))
        if len(parts) != fields + 1 + (user is None):
            continue
        schedule = " ".join(parts[:fields])
        cmd = parts[-1].encode("utf-8", "surrogateescape").decode("utf-8", "replace")
        kind = task_kind(cmd)
        title, description = TASKS.get(kind, (parts[2] if anacron else cmd, ""))
        if kind == "reach" and schedule == "@reboot" and REACH_LINE.fullmatch(cmd):
            description = "После загрузки проверяет, пропущен ли ежедневный запуск, и выполняет пропущенную проверку."
        yield {"source": source, "number": number, "user": user if user is not None else parts[fields],
               "schedule": schedule, "command": cmd, "kind": kind, "title": title, "description": description,
               "revision": rev, "type": "anacron" if anacron else "system" if user is None else "user"}


def system_tabs():
    return [SYSTEM_CRON, ANACRON, *(p for p in sorted(CRON_DIR.glob("*")) if CRON_FILENAME.fullmatch(p.name))]


def read_tab(path):
    return path.read_bytes().decode("utf-8", "surrogateescape")


def file_revision(info):
    return revision(f"{info.st_dev}:{info.st_ino}:{info.st_ctime_ns}:{info.st_mode}")


def system_jobs():
    for path in system_tabs():
        if path.is_file():
            is_anacron = path == ANACRON
            yield from tab_jobs(read_tab(path), str(path), "root" if is_anacron else None, is_anacron,
                                writable=not path.is_symlink())
    for path in sorted(CRON_SPOOL.glob("*")):
        if path.name.startswith(".") or path.name == "root" or not path.is_file():
            continue
        try:
            yield from tab_jobs(crontab(path.name), str(path), path.name, writable=not path.is_symlink())
        except (OSError, ValueError, subprocess.SubprocessError):
            yield from tab_jobs(read_tab(path), str(path), path.name, writable=False)
    for folder in PERIODIC:
        for path in sorted(folder.glob("*")):
            if not CRON_FILENAME.fullmatch(path.name) or not path.is_file() or not os.access(path, os.X_OK):
                continue
            info = path.lstat()
            yield {"source": str(folder), "number": path.name, "user": "root", "schedule": folder.name,
                   "command": str(path), "kind": "", "title": path.name, "type": "script",
                   "description": "Выполняется через run-parts по расписанию каталога.",
                   "revision": file_revision(info) if stat.S_ISREG(info.st_mode) else ""}


def daily_time(schedule):
    if schedule in ("@daily", "@midnight"):
        return "00:00"
    fields = schedule.split()
    if len(fields) == 5 and fields[2:] == ["*", "*", "*"] and all(re.fullmatch(r"[0-9]{1,2}", s) for s in fields[:2]):
        minute, hour = map(int, fields[:2])
        if hour < 24 and minute < 60:
            return f"{hour:02d}:{minute:02d}"
    return ""


def editable(jobs, kind):
    rows = [j for j in jobs if j["kind"] == kind]
    if not rows:
        return None, None, ""
    daily = [j for j in rows if daily_time(j["schedule"])]
    message = "Это задание можно изменить в разделе «Задачи панели»."
    if len(daily) != 1 or any(j["source"] != ROOT_TAB for j in rows):
        return None, None, message
    job = daily[0]
    if kind == "nightly" and len(rows) == 1 and NIGHTLY_LINE.fullmatch(job["command"].rstrip(" \t")):
        return job, None, ""
    if kind == "reach":
        managed = REACH_LINE.fullmatch(job["command"])
        boot = [j for j in rows if j["schedule"] == "@reboot" and j["command"] == job["command"]]
        if managed and managed[1] == daily_time(job["schedule"]) and len(rows) == 1 + len(boot) and len(boot) <= 1:
            return job, next(iter(boot), None), ""
    return None, None, message


def load_jobs():
    error = ""
    try:
        root = root_crontab()
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        root, error = "", f"Не удалось прочитать crontab root: {e}"
    jobs = list(tab_jobs(root, ROOT_TAB, "root"))
    try:
        jobs.extend(system_jobs())
    except OSError as e:
        error = f"Не удалось прочитать все задания cron: {e}"
    return root, jobs, error


def view():
    _, jobs, error = load_jobs()
    schedules = {}
    for kind in ("nightly", "reach"):
        job, _, reason = editable(jobs, kind)
        schedules[kind] = {"time": daily_time(job["schedule"]) if job else "",
                           "installed": any(j["kind"] == kind for j in jobs), "error": error or reason}
    daily, boot, _ = editable(jobs, "reach")
    for row in (daily, boot):
        if row:
            row["managed"] = "reach"
    try:
        zone = str(Path("/etc/localtime").resolve()).split("/zoneinfo/", 1)[1]
    except (OSError, IndexError):
        zone = time.strftime("%Z")
    sources = [{"path": str(p), "type": "anacron" if p == ANACRON else "system"}
               for p in system_tabs() if p.is_file() and not p.is_symlink()]
    users = sorted({account.pw_name for account in pwd.getpwall()} | {"root"})
    return {"jobs": jobs, "schedules": schedules, "zone": zone, "error": error, "sources": sources, "users": users}


def tab_lines(text):
    return text.removesuffix("\n").split("\n") if text else []


def install_crontab(user, original, lines):
    if crontab(user) != original:
        raise CronChanged("Crontab изменился. Обнови список заданий и повтори действие.")
    result = command(["crontab", "-u", user, "-"], "".join(f"{line}\n" for line in lines))
    if result.returncode:
        raise ValueError(result.stderr.decode("utf-8", "replace").strip() or f"Не удалось сохранить crontab {user}")


def save(body):
    kind, at = body.get("task"), body.get("time")
    if kind not in ("nightly", "reach") or not isinstance(at, str) or not re.fullmatch(TIME, at):
        raise ValueError("Укажи задачу и время в формате ЧЧ:ММ")
    root, jobs, error = load_jobs()
    if error:
        raise ValueError(error)
    job, boot, reason = editable(jobs, kind)
    if reason:
        raise ValueError(reason)
    hour, minute = map(int, at.split(":"))
    original = tab_lines(root)
    lines = original.copy()
    if kind == "nightly":
        cmd = job["command"] if job else NIGHTLY_CMD
    elif job and daily_time(job["schedule"]) == at:
        cmd = job["command"]
    else:
        cmd = f"{REACH_CMD} {at} {int(time.time())} >>{REACH_LOG} 2>&1"
    line = f"{minute} {hour} * * * {cmd}"
    if job:
        lines[job["number"]] = line
    else:
        lines.append(line)
    if kind == "reach":
        if boot:
            lines[boot["number"]] = f"@reboot {cmd}"
        else:
            lines.append(f"@reboot {cmd}")
    if lines != original:
        install_crontab("root", root, lines)


def cron_user(user):
    if not isinstance(user, str) or not user or "\x00" in user or "/" in user:
        raise ValueError("Выбери пользователя сервера")
    try:
        return pwd.getpwnam(user).pw_name
    except KeyError:
        raise ValueError("Такого пользователя на сервере нет") from None


def job_line(body, kind):
    schedule, cmd = body.get("schedule"), body.get("command")
    if not all(isinstance(value, str) and value.strip() and not any(c in value for c in "\r\n\x00")
               for value in (schedule, cmd)):
        raise ValueError("Введи расписание и команду, каждое в одну строку")
    schedule = " ".join(schedule.split())
    if kind == "anacron":
        if not re.fullmatch(r"(?:[0-9]+|@monthly) [0-9]+ [^\s/]+", schedule):
            raise ValueError("Для anacron укажи период в днях (или @monthly), задержку в минутах и имя задания")
        return f"{schedule} {cmd}"
    fields = schedule.split()
    if not (re.fullmatch(r"@[a-z]+", schedule) or
            len(fields) == 5 and all(re.fullmatch(r"[0-9a-zA-Z*,/\-]+", field) for field in fields)):
        raise ValueError("Укажи пять полей cron или сокращение, например @reboot")
    if kind == "system":
        user = cron_user(body.get("user"))
        check = command(["crontab", "-n", "-"], f"{schedule} {cmd}\n")
        if check.returncode:
            raise ValueError(check.stderr.decode("utf-8", "replace").strip() or "Некорректное расписание cron")
        return f"{schedule} {user} {cmd}"
    return f"{schedule} {cmd}"


def replace_system_tab(path, info, original, lines):
    tmp = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".iof-cron-", delete=False) as f:
            tmp = Path(f.name)
            os.fchown(f.fileno(), info.st_uid, info.st_gid)
            os.fchmod(f.fileno(), stat.S_IMODE(info.st_mode))
            f.write("".join(f"{line}\n" for line in lines).encode("utf-8", "surrogateescape"))
            f.flush()
            os.fsync(f.fileno())
        if file_revision(path.lstat()) != file_revision(info) or read_tab(path) != original:
            raise CronChanged("Файл cron изменился. Обнови список заданий и повтори действие.")
        os.replace(tmp, path)
    finally:
        if tmp is not None:
            tmp.unlink(missing_ok=True)


def remove_periodic(folder, number, rev):
    if not isinstance(number, str) or not CRON_FILENAME.fullmatch(number):
        raise ValueError("Неизвестный скрипт cron")
    try:
        fd = os.open(folder / number, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise CronChanged("Список скриптов cron изменился. Обнови страницу.") from None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or file_revision(info) != rev:
            raise CronChanged("Скрипт cron изменился. Обнови страницу.")
        os.fchmod(fd, stat.S_IMODE(info.st_mode) & ~0o111)
    finally:
        os.close(fd)


def change(body):
    action, source = body.get("action"), body.get("source")
    if action not in ("add", "edit", "delete") or not isinstance(source, str) or not source or "\x00" in source:
        raise ValueError("Неизвестное действие с заданием cron")
    number, rev = body.get("number"), body.get("revision")
    path = Path(source)
    if path in PERIODIC and action == "delete":
        remove_periodic(path, number, rev)
        return

    info = None
    if action == "add" and source == "user":
        user = cron_user(body.get("user"))
        kind, original = "user", crontab(user)
    elif action != "add" and path.parent == CRON_SPOOL:
        user = cron_user(path.name)
        kind, original = "user", crontab(user)
    elif path in (SYSTEM_CRON, ANACRON) or (path.parent == CRON_DIR and CRON_FILENAME.fullmatch(path.name)):
        try:
            info = path.lstat()
        except FileNotFoundError:
            raise CronChanged("Файл cron больше не существует. Обнови страницу.") from None
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("Для изменения выбери обычный файл cron")
        kind = "anacron" if path == ANACRON else "system"
        user = "root" if kind == "anacron" else None
        original = read_tab(path)
    else:
        raise ValueError("Неизвестный источник задания cron")

    original_lines = tab_lines(original)
    lines = original_lines.copy()
    if action == "add":
        lines.append(job_line(body, kind))
    else:
        jobs = list(tab_jobs(original, str(path), user, kind == "anacron"))
        row = next((j for j in jobs if type(number) is int and j["number"] == number and j["revision"] == rev), None)
        if row is None:
            raise CronChanged("Задание cron изменилось. Обнови список заданий и повтори действие.")
        daily, boot, _ = editable(jobs, "reach")
        if action == "edit":
            if row in (daily, boot):
                raise ValueError("Время проверки из РФ меняется в разделе «Расписание обслуживания»")
            lines[number] = job_line(body, kind)
        else:
            remove = {number}
            if row in (daily, boot):
                remove.update(j["number"] for j in (daily, boot) if j)
            lines = [line for i, line in enumerate(lines) if i not in remove]
    if lines == original_lines:
        return
    if info is None:
        install_crontab(user, original, lines)
    else:
        replace_system_tab(path, info, original, lines)


def journal(tail_lines):
    try:
        result = command(["journalctl", "--no-pager", "-n", "120", "-o", "short-iso",
                          "SYSLOG_IDENTIFIER=CRON", "SYSLOG_IDENTIFIER=cron"])
        if not result.returncode and result.stdout.strip() not in (b"", b"-- No entries --"):
            return {"source": "systemd journal", "lines": result.stdout.decode("utf-8", "replace").splitlines(), "error": ""}
    except (OSError, subprocess.SubprocessError):
        pass
    for path in ("/var/log/cron.log", "/var/log/syslog"):
        lines = [line for line in tail_lines(path, 262144) or [] if re.search(r"\bcron\[\d+\]:", line, re.I)]
        if lines:
            return {"source": path, "lines": lines[-120:], "error": ""}
    return {"source": "", "lines": [], "error": "Записей cron в журнале и файлах логов пока нет."}
