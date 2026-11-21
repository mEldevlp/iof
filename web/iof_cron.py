"""Расписание и журнал cron управляющего сервера."""

import os
import re
import subprocess
import time
from pathlib import Path


ROOT_TAB = "/var/spool/cron/crontabs/root"
CRON_SPOOL = Path(ROOT_TAB).parent
CRON_DIR = Path("/etc/cron.d")
SYSTEM_CRON = Path("/etc/crontab")
ANACRON = Path("/etc/anacrontab")
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


def root_crontab():
    result = command(["crontab", "-u", "root", "-l"])
    if result.returncode == 0:
        return result.stdout.decode("utf-8", "surrogateescape")
    if result.stderr.strip() == b"no crontab for root":
        return ""
    raise ValueError(result.stderr.decode("utf-8", "replace").strip() or "Не удалось прочитать crontab root")


def tab_jobs(text, source, user, anacron=False):
    for number, raw in enumerate(text.split("\n")):
        line = raw.strip()
        if not line or line.startswith("#") or re.match(r"^[a-zA-Z_][a-zA-Z0-9_]*\s*=", line):
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
               "schedule": schedule, "command": cmd, "kind": kind, "title": title, "description": description}


def system_jobs():
    for path, user, anacron in [
        (SYSTEM_CRON, None, False), (ANACRON, "root", True),
        *((p, None, False) for p in sorted(CRON_DIR.glob("*")) if re.fullmatch(r"[\w-]+", p.name, re.ASCII)),
        *((p, p.name, False) for p in sorted(CRON_SPOOL.glob("*")) if not p.name.startswith(".") and p.name != "root"),
    ]:
        if path.is_file():
            yield from tab_jobs(path.read_text(encoding="utf-8", errors="replace"), str(path), user, anacron)
    for period in ("hourly", "daily", "weekly", "monthly"):
        for path in sorted(Path(f"/etc/cron.{period}").glob("*")):
            if re.fullmatch(r"[\w-]+", path.name, re.ASCII) and path.is_file() and os.access(path, os.X_OK):
                yield {"source": str(path.parent), "number": path.name, "user": "root",
                       "schedule": f"cron.{period}", "command": str(path), "kind": "",
                       "title": path.name, "description": "Выполняется через run-parts по расписанию каталога."}


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
    message = "Существующее расписание можно изменить в его источнике. Команда и источник указаны в «Задачах панели»."
    if len(daily) != 1 or any(j["source"] != ROOT_TAB for j in rows):
        return None, None, message
    job = daily[0]
    if kind == "nightly" and len(rows) == 1 and NIGHTLY_LINE.fullmatch(job["command"]):
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
    try:
        zone = str(Path("/etc/localtime").resolve()).split("/zoneinfo/", 1)[1]
    except (OSError, IndexError):
        zone = time.strftime("%Z")
    return {"jobs": jobs, "schedules": schedules, "zone": zone, "error": error}


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
    original = root.removesuffix("\n").split("\n") if root else []
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
        if root_crontab() != root:
            raise ValueError("Crontab root изменился. Обнови страницу и сохрани расписание ещё раз.")
        result = command(["crontab", "-u", "root", "-"], "\n".join(lines) + "\n")
        if result.returncode:
            raise ValueError(result.stderr.decode("utf-8", "replace").strip() or "Не удалось сохранить crontab root")


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
