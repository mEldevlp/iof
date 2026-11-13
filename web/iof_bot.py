"""iof_bot: Telegram-бот iof, работает потоком внутри панели iof-web.

Long polling (getUpdates), без webhook: на сервере не открывается порт. Отвечает только админам
и только в личном чате, групповые чаты и каналы не читает, остальным молчит. Исключение —
сообщение, похожее на код приглашения (64 знака hex, или /start <код> по ссылке t.me/бот?start=код):
код проверяет iof bot redeem, и бот отвечает, подошёл ли он.

Настройки и админы в /root/iof/bot.json, токен в /root/iof/bot.token. Поток их только читает
(заново, когда файл изменился), меняет их только iof bot. Повтор апдейта после перезапуска
безопасен: offset в памяти, сообщения старше STALE секунд от запуска не обрабатываются.

Команды просмотра (/status, /node, /audit, /service, /hy2) ничего не меняют и доступны обеим ролям.
Данные они берут у панели: опрос узлов — общий StatusCache (cache), остальное — объект views
(BotViews в iof-web.py) с тем же разбором, что у страниц. Опрос узлов идёт секундами, поэтому эти
команды выполняются в отдельных потоках (не больше WORKERS сразу), а цикл опроса Telegram не ждёт.
Кнопки inline: callback_data не длиннее 64 байт, у слишком длинного имени узла вместо него хэш.

Только stdlib. Адрес Bot API — IOF_TG_API из web.env (для стенда и CI с поддельным API),
по умолчанию https://api.telegram.org. Прокси нет и не будет. Токен не пишется в журнал:
текст любой ошибки проходит через scrub.
"""

import hashlib
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
    ("status", "Узлы: в порядке или с проблемами"),
    ("node", "Узел подробно: /node имя"),
    ("audit", "Итог последней проверки безопасности"),
    ("service", "Версия iof, обновления, проверка узлов, ночное обслуживание"),
    ("hy2", "Группы ссылок Hysteria2"),
    ("start", "Приветствие и твоя роль"),
    ("help", "Что умеет бот"),
]
# Команды просмотра: метод Bot.view_<команда>, выполняются в отдельном потоке
VIEWS = ("status", "node", "audit", "service", "hy2")
DEFAULTS = {"enabled": False, "username": "", "actions": False, "hy2_links": True, "quiet": None,
            "admins": [], "invites": []}
MAX_TEXT = 4096  # знаков в одном сообщении Telegram
CALLBACK_MAX = 64  # байт в callback_data кнопки
# Кнопки узла: n — открыть карточку новым сообщением, nr — обновить карточку. После «:» имя узла,
# после «#» начало sha256 имени, если с именем не укладывается в CALLBACK_MAX. В имени узла iof
# только латиница, цифры и «._-», поэтому разбор однозначный
NODE_BUTTON = re.compile(r"^(n|nr)([:#])(.+)$")
MAX_BUTTONS = 90  # кнопок узлов в одном сообщении: у Telegram предел 100 на клавиатуру
MAX_LINES = 40    # строк о проблемных узлах в /status, дальше «и ещё N»
REFRESH = "🔄 Обновить"
BUSY = "Я ещё выполняю прошлые команды, повтори через минуту."
MARK = {"good": "✅", "warn": "⚠️", "crit": "❌", "none": "⚪"}
RANK = {"none": 0, "good": 1, "warn": 2, "crit": 3}
SSH_KEY = "/root/.ssh/iof_ed25519"


def esc(text):
    return html.escape(str(text), quote=False)


def clean(text, limit):
    """Имя из Telegram в одну строку без управляющих знаков: оно идёт в iof bot redeem строкой stdin."""
    return re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or "")).strip()[:limit]


# Оформление ответов. Те же слова и пороги, что у страниц панели (common.js, node.js, service.js,
# security.js). Каждая строка ответа с закрытыми тегами: длинный ответ режется по строкам

def plural(n, forms):
    a = abs(n) % 100
    b = a % 10
    if 10 < a < 20:
        return forms[2]
    if b == 1:
        return forms[0]
    if 2 <= b <= 4:
        return forms[1]
    return forms[2]


def fmt_uptime(s):
    d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    if d > 0:
        return f"{d} д {h} ч"
    if h > 0:
        return f"{h} ч {m} мин"
    return f"{m} мин"


def fmt_ms(ms):
    return f"{ms} мс" if ms < 1000 else f"{ms // 1000}.{ms % 1000 // 100} с"


def gb(v, div):
    g = v / div
    return f"{g:.0f}" if g >= 10 else f"{g:.1f}"


def clock(ts):
    """Время сервера с поясом: 12:03:15 UTC. По нему видно, что «Обновить» сработало."""
    return time.strftime("%H:%M:%S %Z", time.localtime(ts))


def stamp(ts, now=None):
    """Когда это было: «13.11 04:00 UTC, 5 ч назад». Пояс — сервера, «назад» от пояса не зависит."""
    s = max(0, int((now or time.time()) - ts))
    rel = ("только что" if s < 60 else f"{s // 60} мин назад" if s < 3600
           else f"{s // 3600} ч назад" if s < 86400 else f"{s // 86400} д назад")
    return time.strftime("%d.%m %H:%M %Z", time.localtime(ts)) + ", " + rel


def name_hash(name):
    return hashlib.sha256(name.encode("utf-8")).hexdigest()[:24]


def node_button(kind, name):
    """callback_data кнопки узла: имя, а если не укладывается в 64 байта — начало его sha256."""
    data = f"{kind}:{name}"
    return data if len(data.encode("utf-8")) <= CALLBACK_MAX else f"{kind}#{name_hash(name)}"


def keyboard(buttons, per_row=2, tail=None):
    rows = [buttons[i:i + per_row] for i in range(0, len(buttons), per_row)]
    return {"inline_keyboard": rows + ([tail] if tail else [])}


def label(name, limit=40):
    """Текст кнопки: длинное имя узла Telegram всё равно обрежет, а так видно начало."""
    return name if len(name) <= limit else name[:limit - 1] + "…"


def node_warnings(n):
    """Нагрузка, о которой стоит знать: пороги как у warnings() в common.js и в iof status."""
    if not n.get("reachable"):
        return []
    w = []
    if n["cpu"]["pct"] >= 90:
        w.append(f"ЦП {n['cpu']['pct']}%")
    if n["mem"]["pct"] >= 90:
        w.append(f"память {n['mem']['pct']}%")
    if 80 <= n["disk"]["pct"] < 90:
        w.append(f"диск {n['disk']['pct']}%")
    return w


def node_level(n):
    if not n.get("reachable") or n.get("issues"):
        return "crit"
    return "warn" if node_warnings(n) else "good"


def gauge(pct, warn, crit=None):
    return f" {MARK['crit']}" if crit and pct >= crit else f" {MARK['warn']}" if pct >= warn else ""


def hy2_line(h):
    """Hysteria2 узла одной строкой, как hy2Cell в common.js."""
    if not h["installed"]:
        return "не установлена"
    if h["state"] != "active":
        main = f"{MARK['crit']} не работает ({esc(h['state'] or '?')})"
    elif not h["udp"]:
        main = f"{MARK['crit']} не слушает :{esc(h['port'])}"
    else:
        main = f"{MARK['good']} работает :{esc(h['port'])}"
    access = ("общий пароль" if h["auth"] == "password"
              else f"{h['users']} польз." if h["auth"] == "userpass" else "")
    extra = [esc(x) for x in (h["version"], access) if x]
    if h["range"]:
        extra.append(f"смена портов UDP {esc(h['range'])}")
    return main + (", " + ", ".join(extra) if extra else "")


def awg_line(a):
    if a["state"] == "none":
        return "не установлен"
    if a["state"] != "running":
        return f"{MARK['crit']} контейнер остановлен"
    return (f"{MARK['good']} работает :{esc(a['port'])}, {a['peers']} "
            f"{plural(a['peers'], ('клиент', 'клиента', 'клиентов'))}, онлайн {a['online']} за 3 мин")


def status_text(data):
    """/status: сколько узлов в порядке и с проблемами, проблемные — с причиной."""
    nodes = data.get("nodes") or []
    if data.get("status_error"):
        return f"{MARK['crit']} Узлы не опрошены: {esc(data['status_error'])}"
    if not nodes:
        return ("Узлов нет. Добавить: в панели, страница «Добавить сервер», "
                "или <code>sudo iof node add</code>")
    levels = [node_level(n) for n in nodes]
    count = {lvl: levels.count(lvl) for lvl in ("good", "warn", "crit")}
    parts = [f"{MARK['good']} в порядке {count['good']}"]
    if count["warn"]:
        parts.append(f"{MARK['warn']} внимание {count['warn']}")
    if count["crit"]:
        parts.append(f"{MARK['crit']} проблемы {count['crit']}")
    lines = [f"<b>Узлы: {len(nodes)}</b>", " · ".join(parts)]
    bad = sorted(((n, lvl) for n, lvl in zip(nodes, levels) if lvl != "good"), key=lambda x: -RANK[x[1]])
    if bad:
        lines.append("")
    for n, lvl in bad[:MAX_LINES]:
        why = "; ".join(n.get("issues", []) + node_warnings(n))
        lines.append(f"{MARK[lvl]} <b>{esc(n['name'])}</b> — {esc(why)}")
    if len(bad) > MAX_LINES:
        lines.append(f"…и ещё {len(bad) - MAX_LINES}")
    lines += ["", "Узел подробно — кнопкой ниже или <code>/node имя</code>",
              f"<i>Данные на {clock(data['status_at'])}</i>"]
    return "\n".join(lines)


def status_keyboard(data):
    nodes = (data.get("nodes") or [])[:MAX_BUTTONS]
    buttons = [{"text": f"{MARK[node_level(n)]} {label(n['name'])}", "callback_data": node_button("n", n["name"])}
               for n in nodes]
    return keyboard(buttons, tail=[{"text": REFRESH, "callback_data": "st"}])


def parse_ssh(ssh):
    """root@203.0.113.5:2222 -> ("root@203.0.113.5", "2222")."""
    m = re.match(r"^(.+?)(?::(\d+))?$", ssh or "")
    return (m.group(1), m.group(2) or "22") if m else (ssh, "22")


def node_text(d):
    """/node и кнопка узла: то же, что страница узла, без действий."""
    name, conf, n, error = d["name"], d.get("conf"), d.get("node"), d.get("status_error")
    if not conf:
        return f"Узла <b>{esc(name)}</b> больше нет в nodes.conf."
    lvl = "crit" if error or not n else node_level(n)
    title = f" · {esc(conf['title'])}" if conf["title"] != name else ""
    ssh = "этот сервер (local)" if conf["ssh"] == "local" else f"<code>{esc(conf['ssh'])}</code>"
    lines = [f"{MARK[lvl]} <b>{esc(name)}</b>{title}", f"Адрес для клиентов: <code>{esc(conf['addr'])}</code>",
             f"SSH: {ssh}"]
    if error or not n:
        lines += ["", f"{MARK['crit']} Нет данных об узле: {esc(error or 'он не попал в опрос, нажми «Обновить»')}"]
    elif not n["reachable"]:
        target, port = parse_ssh(conf["ssh"])
        lines += ["", f"{MARK['crit']} <b>Нет связи по SSH</b>",
                  "iof не смог зайти на узел своим ключом. Проверить с управляющего сервера:",
                  f"<code>ssh -i {SSH_KEY}{f' -p {esc(port)}' if port != '22' else ''} {esc(target)}</code>"]
    else:
        cpu, mem, disk = n["cpu"], n["mem"], n["disk"]
        lines += [f"Работает {fmt_uptime(n['uptime_s'])}, отклик {fmt_ms(n['ms'])}", "", "<b>Нагрузка</b>",
                  f"ЦП {cpu['pct']}%{gauge(cpu['pct'], 90)} · LA {cpu['load1']:g} · {cpu['cpus']} "
                  f"{plural(cpu['cpus'], ('ядро', 'ядра', 'ядер'))}",
                  f"Память {mem['pct']}%{gauge(mem['pct'], 90)} из {gb(mem['total_mb'], 1024)} ГБ",
                  f"Диск {disk['pct']}%{gauge(disk['pct'], 80, 90)} из {gb(disk['total_kb'], 1048576)} ГБ",
                  "", f"<b>Hysteria2</b>: {hy2_line(n['hy2'])}", f"<b>AmneziaWG</b>: {awg_line(n['awg'])}", ""]
        problems = [("crit", t) for t in n["issues"]] + [("warn", t) for t in node_warnings(n)]
        if problems:
            lines += ["<b>Проблемы</b>"] + [f"{MARK[lvl]} {esc(t)}" for lvl, t in problems]
        else:
            lines.append(f"{MARK['good']} Проблем нет")
    relays = d.get("relays") or []
    if relays:
        lines += ["", "<b>Ретрансляторы</b>"]
        for r in relays:
            role = "узел за ретранслятором" if r["node"] == name else "ретранслятор"
            lines.append(f"{esc(r['label'])} — {role}")
            for proto, src, dst in (("HY2", r.get("hy2"), r.get("hy2_target")), ("AWG", r.get("awg"), r.get("awg_target"))):
                if src:
                    lines.append(f"{proto} <code>{esc(src)}</code> → <code>{esc(dst or '?')}</code>")
    lines += ["", f"<i>Данные на {clock(d['status_at'])}</i>"]
    return "\n".join(lines)


def audit_text(d):
    """/audit: итог последней проверки по блокам и проблемные проверки (crit, warn) по узлам."""
    if d.get("error"):
        return f"{MARK['crit']} iof не ответил: {esc(d['error'])}"
    nodes = d.get("nodes") or []
    if not nodes:
        return "Узлов нет, проверять нечего."
    catalog = d.get("catalog") or []
    titles = {k["id"]: k["title"] for k in catalog}
    order = {k["id"]: i for i, k in enumerate(catalog)}
    lines = []
    for block in dict.fromkeys(g["block"] for g in d.get("groups") or []):
        ids = {k["id"] for k in catalog if k["block"] == block}
        saved = ((d.get("blocks") or {}).get(block) or {}).get("nodes") or {}
        res = [(n["name"], saved.get(n["name"])) for n in nodes]
        if lines:
            lines.append("")
        lines.append(f"<b>{esc((d.get('titles') or {}).get(block, block))}</b>")
        times = [r["at"] for _, r in res if r]
        if not times:
            lines.append(f"Проверки ещё не было: <code>sudo iof audit run {esc(block)}</code>")
            continue
        count = dict.fromkeys(RANK, 0)
        for _, r in res:
            for c in r["checks"] if r and r["reachable"] else []:
                if c["id"] in ids:
                    count[c["status"] if c["status"] in RANK else "none"] += 1
        lines.append(f"Проверка: {stamp(max(times))}")
        lines.append(f"{MARK['crit']} проблем {count['crit']} · {MARK['warn']} внимание {count['warn']} · "
                     f"{MARK['good']} в порядке {count['good']}")
        clean_nodes = True
        for name, r in res:
            if not r:
                continue
            if not r["reachable"]:
                clean_nodes = False
                lines.append(f"{MARK['crit']} <b>{esc(name)}</b>: нет связи при проверке"
                             + (f" ({esc(r['error'])})" if r.get("error") else ""))
                continue
            bad = sorted((c for c in r["checks"] if c["id"] in ids and c["status"] in ("crit", "warn")),
                         key=lambda c: (-RANK[c["status"]], order.get(c["id"], 0)))
            if bad:
                clean_nodes = False
                lines.append(f"<b>{esc(name)}</b>")
                lines += [f"{MARK[c['status']]} {esc(titles.get(c['id'], c['id']))}"
                          + (f": {esc(c['value'])}" if c.get("value") else "") for c in bad]
        if clean_nodes:
            lines.append("Проблемных проверок нет")
        never = [name for name, r in res if not r]
        if never:
            lines.append(f"Ещё не проверялись: {esc(', '.join(never))}")
    lines += ["", "Почему это важно и как исправить — в панели, страница «Безопасность», "
                  "или <code>sudo iof audit show</code>"]
    return "\n".join(lines)


def server_time(text):
    """«2026-11-13 04:00:01» (время сервера из лога) -> unix или None."""
    try:
        return time.mktime(time.strptime(text, "%Y-%m-%d %H:%M:%S"))
    except (TypeError, ValueError, OverflowError):
        return None


def service_text(d, pending=False, now=None):
    """/service: версия и обновления, последняя проверка узлов, последнее ночное обслуживание.
    pending — обновления ещё проверяются (git fetch)."""
    now = now or time.time()
    lines = []
    mig = d.get("migrate") or {}
    if mig.get("role") == "source":
        lines += [f"{MARK['warn']} Идёт перенос управления на другой сервер: <code>sudo iof migrate status</code>", ""]
    lines.append("<b>iof</b>")
    if d.get("error"):
        lines.append(f"{MARK['crit']} iof не ответил: {esc(d['error'])}")
    version, src, src_version = d.get("version") or "", d.get("src") or "", d.get("src_version") or ""
    lines.append(f"Установлена: <code>{esc(version or '?')}</code>")
    if src_version:
        lines.append(f"Клон {esc(src)}: <code>{esc(src_version)}</code>")
        if version and src_version.split()[0] != version.split()[0]:
            lines.append(f"{MARK['warn']} В клоне не та версия, что установлена: <code>sudo bash {esc(src)}/install.sh</code>")
    elif not d.get("error"):
        lines.append(f"Git-клона в {esc(src)} нет, обновления не проверить")
    u = d.get("updates")
    if pending:
        lines.append("⏳ Проверяю обновления (git fetch)…")
    elif u and u.get("error"):
        lines.append(f"{MARK['warn']} Обновления не проверены: {esc(u['error'])}")
    elif u and not u.get("commits"):
        lines.append(f"{MARK['good']} Обновлений нет, ветка <code>{esc(u.get('branch', ''))}</code>")
    elif u:
        k = len(u["commits"])
        lines.append(f"{MARK['warn']} <b>Доступно обновление</b>: {k} {plural(k, ('коммит', 'коммита', 'коммитов'))} "
                     f"в <code>{esc(u.get('branch', ''))}</code>")
        lines += [f"• <code>{esc(c.get('hash', ''))}</code> {esc(c.get('subject', ''))}" for c in u["commits"][:5]]
        if k > 5:
            lines.append(f"…и ещё {k - 5}")
        lines.append("Обновить: в панели, страница «Сервис», или <code>sudo iof update</code>")

    cron = d.get("cron") or []
    lines += ["", "<b>Проверка узлов</b> (iof check)"]
    c = d.get("check")
    check_cron = any(re.search(r"\biof check\b", line) for line in cron)
    if c:
        lines.append(f"Последняя: {stamp(c['at'], now)}")
        lines.append(f"{MARK['crit']} проблемы на {c['bad']} из {c['total']}: {esc(', '.join(c['problems']))}"
                     if c["bad"] else f"{MARK['good']} все {c['total']} в порядке")
        if check_cron and now - c["at"] > 3600:
            lines.append(f"{MARK['warn']} Давно не было: проверь cron")
    else:
        lines.append("Ещё не было")
    if not check_cron:
        lines.append(f"{MARK['warn']} Не запланирована: <code>sudo crontab -e</code>, строка "
                     f"<code>{esc('*/5 * * * * /usr/local/bin/iof check >/dev/null 2>&1')}</code>")

    lines += ["", "<b>Ночное обслуживание</b>"]
    n, local = d.get("nightly"), d.get("nightly_local")
    if n:
        started = server_time(n.get("started"))
        m = re.search(r"с ошибкой: (\d+)", n.get("summary") or "")
        ok = bool(n.get("summary")) and not (m and int(m.group(1)))
        summary = n["summary"].replace("Выполнено", "запущено") if n.get("summary") else "итога в логе нет"
        lines.append(f"Последний запуск: {stamp(started, now) if started else esc(n.get('started', ''))}")
        lines.append(f"{MARK['good' if ok else 'warn']} {esc(summary)}")
    else:
        lines.append("Ещё не было")
    if local and local.get("steps"):
        steps = [re.sub(r"^\S+ (\d\d:\d\d):\d\d ", r"\1 ", s) for s in local["steps"]]
        lines.append(f"Этот сервер: {esc('; '.join(steps))}")
        lines += [f"{MARK['crit']} {esc(e)}" for e in local.get("errors") or []]
    if not any("iof-nightly" in line for line in cron):
        lines.append(f"{MARK['warn']} Не запланировано: <code>sudo crontab -e</code>, строка "
                     f"<code>0 4 * * * /usr/local/sbin/iof-nightly</code>")
    return "\n".join(lines)


def hy2_text(groups):
    """/hy2: группы ссылок без самих ссылок (в них пароль), они появятся в боте на этапе 4."""
    if not groups:
        return ("Групп ссылок Hysteria2 пока нет. Создать: в панели, страница «Hysteria2», или "
                "<code>sudo iof hy2 add \"Подпись\"</code>")
    lines = [f"<b>Группы ссылок Hysteria2: {len(groups)}</b>", ""]
    for g in groups:
        k = len(g["links"])
        relays = sum(1 for link in g["links"] if link["relay"])
        parts = [f"{k} {plural(k, ('ссылка', 'ссылки', 'ссылок'))}"]
        if relays:
            parts.append(f"из них через ретранслятор {relays}")
        if g["hop"]:
            parts.append("список портов")
        lines.append(f"• <b>{esc(g['label'])}</b> — {', '.join(parts)}")
    lines += ["", "Сами ссылки и QR — в панели, страница «Hysteria2», или <code>sudo iof hy2 show \"Подпись\"</code>"]
    return "\n".join(lines)


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
    WORKERS = 4        # команд просмотра одновременно, остальным «повтори через минуту»

    def __init__(self, base, iof, jobs=None, cache=None, views=None, api=None, log=None):
        self.base = Path(base)
        self.iof = iof
        # Очередь задач (этап 4), опрос узлов и данные страниц панели (BotViews в iof-web.py)
        self.jobs, self.cache, self.views = jobs, cache, views
        self.slots = threading.BoundedSemaphore(self.WORKERS)
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

    def admin(self, uid):
        return next((a for a in self.cfg["admins"] if a["id"] == uid), None)

    def handle(self, api, upd):
        if "callback_query" in upd:
            return self.press(api, upd["callback_query"])
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
        admin = self.admin(user["id"])
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
        elif cmd in VIEWS:
            if self.views is None or self.cache is None:
                return self.send(api, chat["id"], "Бот работает без панели, данных нет.")
            if not self.slots.acquire(blocking=False):
                return self.send(api, chat["id"], BUSY)
            self.worker(api, chat["id"], getattr(self, f"view_{cmd}"), text[m.end():].strip())
        else:
            self.send(api, chat["id"], "Не понял. Что я умею: /help")

    def press(self, api, q):
        """Нажатие inline-кнопки. Как и на сообщения: чужим и в группах бот молчит, и даже не отвечает
        на нажатие (answerCallbackQuery); админу отвечает на каждое."""
        if not isinstance(q, dict) or not isinstance(q.get("id"), str):
            return
        user, msg = q.get("from"), q.get("message")
        if not isinstance(user, dict) or type(user.get("id")) is not int or user.get("is_bot"):
            return
        chat = msg.get("chat") if isinstance(msg, dict) else None
        if not isinstance(chat, dict) or chat.get("type") != "private" or type(msg.get("message_id")) is not int:
            return
        if self.admin(user["id"]) is None:
            return self.stranger(user, "нажатие кнопки")
        data = q.get("data") if isinstance(q.get("data"), str) else ""
        chat_id, msg_id = chat["id"], msg["message_id"]
        if self.views is None or self.cache is None:
            return self.answer(api, q["id"], "Бот работает без панели, данных нет", True)
        if data == "st":
            job, toast = (self.view_status, "", msg_id, True), "" if self.cache.fresh(True) else "Опрашиваю узлы…"
        elif NODE_BUTTON.match(data):
            kind, name = self.button_node(data)
            if name is None:
                return self.answer(api, q["id"], kind, True)
            if kind == "n":
                job, toast = (self.view_node, name), ""
            else:
                job, toast = (self.view_node, name, msg_id, True), "" if self.cache.fresh(True) else "Опрашиваю узел…"
        else:
            return self.answer(api, q["id"], "Кнопка устарела: повтори команду", True)
        if not self.slots.acquire(blocking=False):
            return self.answer(api, q["id"], BUSY, True)
        try:
            fresh = self.answer(api, q["id"], toast)
        except BaseException:
            self.slots.release()
            raise
        if not fresh:
            self.slots.release()
            return
        self.worker(api, chat_id, *job)

    def button_node(self, data):
        """callback_data кнопки узла -> (n или nr, имя узла) или (текст для админа, None), если узла уже нет."""
        kind, sep, ref = NODE_BUTTON.match(data).groups()
        names = [n["name"] for n in self.views.nodes()]
        if sep == ":":
            if ref in names:
                return kind, ref
            return f"Узла {ref} больше нет в nodes.conf", None
        name = next((n for n in names if name_hash(n) == ref), None)
        return (kind, name) if name else ("Этого узла больше нет в nodes.conf", None)

    def answer(self, api, query_id, text="", alert=False):
        """answerCallbackQuery: убирает часики с кнопки, text — всплывающая подсказка. False — нажатие
        старое (Telegram уже не принимает ответ, например, бот не работал): его никто не ждёт."""
        params = {"callback_query_id": query_id}
        if text:
            params.update(text=text[:200], show_alert=alert)
        try:
            self.call(api, "answerCallbackQuery", params)
        except ApiError as e:
            if e.code == 400:
                return False
            raise
        return True

    def worker(self, api, chat_id, fn, *args):
        """Команда просмотра в отдельном потоке: опрос узлов идёт секундами, а цикл опроса Telegram
        тем временем отвечает на другое. Слот self.slots вызывающий уже занял, здесь он освобождается."""
        def job():
            try:
                fn(api, chat_id, *args)
            except (ApiError, NetError) as e:
                self.log(f"бот: не удалось ответить: {e}")
            except Exception:  # ошибка в коде команды не должна ронять бота
                self.log(self.scrub(traceback.format_exc()).rstrip())
                try:
                    self.send(api, chat_id, "Ошибка в боте, подробности в журнале панели: "
                                            "<code>journalctl -u iof-web</code>")
                except (ApiError, NetError):
                    pass
            finally:
                self.slots.release()
        try:
            threading.Thread(target=job, name="iof-bot-view", daemon=True).start()
        except RuntimeError:
            self.slots.release()
            raise

    # Команды просмотра. msg_id — обновить это сообщение (кнопка «Обновить»), иначе новое

    def placeholder(self, api, chat_id, msg_id, force):
        """Пока StatusCache опрашивает узлы (секунды), в чате «Опрашиваю узлы…», потом оно заменяется
        ответом. Свежие данные в кэше — ответ сразу, без этого сообщения."""
        if msg_id is None and not self.cache.fresh(force):
            msg = self.send(api, chat_id, "⏳ Опрашиваю узлы…")
            return msg.get("message_id") if isinstance(msg, dict) else None
        return msg_id

    def view_status(self, api, chat_id, arg="", msg_id=None, force=False):
        msg_id = self.placeholder(api, chat_id, msg_id, force)
        data = self.cache.get(force)
        self.reply(api, chat_id, msg_id, status_text(data), status_keyboard(data))

    def view_node(self, api, chat_id, arg="", msg_id=None, force=False):
        nodes = self.views.nodes()
        names = [n["name"] for n in nodes]
        ref = arg.split()[0] if arg.split() else ""
        name = ref if ref in names else None
        if name is None and ref:
            same = [n for n in names if n.lower() == ref.lower()]
            name = same[0] if len(same) == 1 else None
        if name is None:
            if not nodes:
                return self.reply(api, chat_id, msg_id, "Узлов нет. Добавить: <code>sudo iof node add</code>")
            text = (f"Узла <b>{esc(ref[:64])}</b> нет в nodes.conf. Выбери узел:" if ref
                    else "Какой узел? Напиши <code>/node имя</code> или выбери:")
            buttons = [{"text": label(n), "callback_data": node_button("n", n)} for n in names[:MAX_BUTTONS]]
            return self.reply(api, chat_id, msg_id, text, keyboard(buttons))
        msg_id = self.placeholder(api, chat_id, msg_id, force)
        d = self.views.node(name, force)
        markup = keyboard([], tail=[{"text": REFRESH, "callback_data": node_button("nr", name)}]) if d.get("conf") else None
        self.reply(api, chat_id, msg_id, node_text(d), markup)

    def view_audit(self, api, chat_id, arg=""):
        self.send(api, chat_id, audit_text(self.views.audit()))

    def view_service(self, api, chat_id, arg=""):
        """Сразу — версия, проверка узлов и ночное обслуживание, потом то же сообщение с обновлениями:
        git fetch идёт до минуты."""
        d = self.views.service(False)
        fetch = bool(d.get("src_version")) and not d.get("error")
        msg = self.send(api, chat_id, service_text(d, pending=fetch))
        if fetch:
            d = self.views.service(True)
            self.reply(api, chat_id, msg.get("message_id") if isinstance(msg, dict) else None, service_text(d))

    def view_hy2(self, api, chat_id, arg=""):
        self.send(api, chat_id, hy2_text(self.views.hy2()))

    def greeting(self, admin, user):
        name = clean(user.get("first_name") or admin.get("name"), 64) or "админ"
        return (f"Привет, {esc(name)}! Это бот iof на сервере <b>{esc(self.host)}</b>.\n"
                f"Ты админ, роль: <b>{esc(ROLES.get(admin.get('role'), admin.get('role')))}</b>.\n\n"
                "Что я умею: /help")

    def help_text(self):
        lines = ["<b>Команды</b>"] + [f"/{c} — {esc(d[0].lower() + d[1:])}" for c, d in COMMANDS]
        lines += ["", "Команды только показывают состояние, ничего не меняют. Под ответом /status кнопки "
                      "узлов, под карточкой узла — «Обновить».",
                  "", "Админов добавляют приглашением, а удаляют и меняют им роль только на сервере: "
                      "в панели iof-web или командой sudo iof bot."]
        return "\n".join(lines)

    def stranger(self, user, what="сообщение"):
        """Чужим бот не отвечает, а в журнал пишет ID и username, не чаще раза в минуту на ID."""
        uid, now = user["id"], time.time()
        if now - self.strangers.get(uid, 0) < self.STRANGER_LOG:
            return
        if len(self.strangers) > 1000:
            self.strangers = {k: t for k, t in self.strangers.items() if now - t < self.STRANGER_LOG}
        self.strangers[uid] = now
        self.log(f"бот: {what} от чужого, без ответа: {self.who(user)}")

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

    @staticmethod
    def call(api, method, params):
        """Вызов Bot API, на 429 одна повторная попытка (если ждать не дольше 30 с)."""
        try:
            return api.call(method, params)
        except ApiError as e:
            if e.code != 429 or not e.retry_after or e.retry_after > 30:
                raise
            time.sleep(e.retry_after)
            return api.call(method, params)

    def send(self, api, chat_id, text, markup=None):
        """Сообщение в HTML, длинное — частями по строкам, не длиннее MAX_TEXT; кнопки у последней части.
        -> отправленное сообщение (последняя часть)."""
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
        sent = None
        for i, part in enumerate(parts):
            params = {"chat_id": chat_id, "text": part, "parse_mode": "HTML",
                      "link_preview_options": {"is_disabled": True}}
            if markup and i == len(parts) - 1:
                params["reply_markup"] = markup
            sent = self.call(api, "sendMessage", params)
        return sent

    def reply(self, api, chat_id, msg_id, text, markup=None):
        """Ответ на месте сообщения msg_id (editMessageText), без него — новым сообщением. В одно
        сообщение длиннее MAX_TEXT не влезает: хвост обрезается по строкам. Тот же текст — не ошибка,
        а сообщение, которое уже не изменить (удалено), заменяет новое."""
        if msg_id is None:
            return self.send(api, chat_id, text, markup)
        if len(text) > MAX_TEXT:
            lines, size = [], 2
            for line in text.split("\n"):
                if size + len(line) + 1 > MAX_TEXT:
                    break
                lines.append(line)
                size += len(line) + 1
            text = "\n".join(lines + ["…"])
        params = {"chat_id": chat_id, "message_id": msg_id, "text": text, "parse_mode": "HTML",
                  "link_preview_options": {"is_disabled": True}}
        if markup:
            params["reply_markup"] = markup
        try:
            return self.call(api, "editMessageText", params)
        except ApiError as e:
            if e.code != 400:
                raise
            if "not modified" in str(e):
                return None
            return self.send(api, chat_id, text, markup)
