#!/usr/bin/env bash

# Уведомление в Telegram: tg_send <тип> <текст>. Если бот включён и есть токен, оно уходит через него
# каждому админу, у которого тип отмечен в notify и доступен роли (BOT_PY notify: тихие часы, звук,
# HTML). Иначе, как раньше, в TG_CHAT из iof.env, но только узлы и аудит. Ошибка отправки печатается
# в stderr и ничего не роняет: iof check и cron доработают. Токен не попадает в аргументы процессов.
# NOTIFY_VERBOSE=1 (iof notify) — ещё и итог отправки в stdout
NOTIFY_VERBOSE=0
tg_send() {
  local kind="$1" text="$2" rc=0 out
  if [[ -s "$BOT_TOKEN" && -f "$BOT_FILE" ]] && have python3 && [[ "$(migrate_get role)" != "target" ]]; then
    out="$(printf '%s' "$text" | bot_py notify "$BOT_FILE" "$BOT_TOKEN" "$(bot_api)" "$kind")" || rc=$?
    # 3 — бот выключен: тогда старый путь
    if (( rc != 3 )); then
      if (( NOTIFY_VERBOSE )) && [[ -n "$out" ]]; then printf '%s\n' "$out"; fi
      return 0
    fi
  fi
  tg_chat_send "$kind" "$text"
}

# Старый путь без бота: TG_TOKEN и TG_CHAT из iof.env, простым текстом. Остальные типы — только через бота
tg_chat_send() {
  local kind="$1" text="$2" api
  case "$kind" in
    nodes) ;;
    audit) text="Аудит безопасности, стало хуже:"$'\n'"$text" ;;
    *) if (( NOTIFY_VERBOSE )); then echo "Бот выключен, а без него в TG_CHAT уходят только узлы и аудит"; fi
       return 0 ;;
  esac
  if [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]]; then
    if (( NOTIFY_VERBOSE )); then echo "Telegram не настроен: ни бота (sudo iof bot), ни TG_TOKEN и TG_CHAT в $ENV_FILE"; fi
    return 0
  fi
  api="$(bot_api)"
  # Адрес с токеном curl читает из конфига на stdin (-K -): printf встроен в bash, в аргументах токена нет
  if printf 'url = "%s/bot%s/sendMessage"\n' "${api%/}" "$TG_TOKEN" \
      | curl -fsS --max-time 10 -K - --data-urlencode "chat_id=${TG_CHAT}" --data-urlencode "text=$text" >/dev/null 2>&1; then
    if (( NOTIFY_VERBOSE )); then echo "Отправлено в TG_CHAT из $ENV_FILE"; fi
  else
    echo "Уведомление в TG_CHAT не отправлено: Telegram не ответил или не принял TG_TOKEN" >&2
  fi
}

notify_kind_ok() { [[ " $NOTIFY_KINDS " == *" $1 "* && -n "$1" ]]; }

# iof notify <тип> [текст]: уведомление вручную или из iof-nightly, без текста — со stdin
cmd_notify() {
  local kind="${1:-}" text
  notify_kind_ok "$kind" || die "используй: iof notify ${NOTIFY_KINDS// /|} [текст] (без текста — со stdin)"
  shift
  if [[ $# -gt 0 ]]; then
    text="$*"
  else
    [[ ! -t 0 ]] || die "текст уведомления: аргументом или через stdin"
    text="$(head -c 30000)"
  fi
  [[ -n "${text//[[:space:]]/}" ]] || die "пустой текст уведомления"
  NOTIFY_VERBOSE=1
  tg_send "$kind" "$text"
}

# Telegram-бот: iof bot. Сам бот — поток внутри панели iof-web (web/iof_bot.py): он только читает
# bot.json и bot.token, а меняет их эта команда, и из консоли, и из панели, и из бота (redeem).
# Секреты (токен, код приглашения) идут через stdin. В bot.json от кода приглашения только sha256

BOT_PY=$(cat <<'EOF'
import hashlib, hmac, html, http.client, json, os, re, secrets, sys, time, urllib.error, urllib.request

ROLES = {"main": "главный", "regular": "обычный"}
INVITE_TTL = 86400   # секунд живёт приглашение
INVITE_MAX = 20      # неиспользованных приглашений сразу
CODE = re.compile(r"^[0-9a-f]{64}$")
USERNAME = re.compile(r"^[A-Za-z0-9_]{1,32}$")
CLOCK = re.compile(r"^([01]?[0-9]|2[0-3]):([0-5][0-9])$")
API = re.compile(r"^https?://[A-Za-z0-9.:\[\]-]+(/[A-Za-z0-9._~/-]*)?$")
MAX_TEXT = 4096      # знаков в одном сообщении Telegram
# Типы уведомлений: коротко, заголовок сообщения, откуда. Те же — NOTIFY_KINDS в lib/common.sh, BOT_NOTIFY
# в iof-web.py и NOTIFY в bot.js (их сверяет ci/lint.sh). NOTIFY_MAIN — только главным админам
NOTIFY = {
    "nodes": ("узлы", "Узлы", "проблемы и восстановление узлов, iof check"),
    "audit": ("аудит", "Аудит безопасности: стало хуже", "ухудшения аудита, iof audit cron"),
    "nightly": ("ночное обслуживание", "Ночное обслуживание", "запуск обновления и перезагрузки, iof-nightly"),
    "updates": ("обновления iof", "Вышла новая версия iof", "новая версия на GitHub, iof check раз в сутки"),
    "ru": ("доступ к РФ", "Доступ к российским серверам", "РФ недоступна с узла, iof check раз в сутки"),
    "admins": ("новые админы", "Новый админ", "по приглашению добавился админ, только главным"),
}
NOTIFY_MAIN = {"admins"}
# Строки уведомлений iof с меткой в начале: в боте вместо метки значок, как у страниц
MARKS = {"[OK] ": "✅ ", "[ПРОБЛЕМА] ": "❌ ", "[РФ НЕДОСТУПНА] ": "❌ ", "[НЕТ ИНТЕРНЕТА] ": "⚠️ "}


def die(text):
    print("Ошибка: " + text, file=sys.stderr)
    sys.exit(1)


def when(ts):
    return time.strftime("%d.%m.%Y %H:%M", time.localtime(ts))


def defaults():
    # notify у админа: список типов из NOTIFY, null — по умолчанию, то есть ничего
    return {"enabled": False, "username": "", "actions": False, "hy2_links": True, "quiet": None,
            "admins": [], "invites": []}


def kinds_for(role):
    """Типы уведомлений, доступные роли, в порядке NOTIFY."""
    return [k for k in NOTIFY if role == "main" or k not in NOTIFY_MAIN]


def subscribed(admin, kind):
    """Админ получает уведомление kind: тип отмечен у него и доступен его роли."""
    kinds = admin.get("notify")
    return isinstance(kinds, list) and kind in kinds and kind in kinds_for(admin.get("role"))


def notify_parse(value, role):
    """notify для iof bot admin set: типы через запятую, all — все доступные роли, off — ничего."""
    if value == "off":
        return []
    if value == "all":
        return kinds_for(role)
    want = [k.strip() for k in value.split(",") if k.strip()]
    bad = [k for k in want if k not in NOTIFY]
    if not want or bad:
        die(f"типы уведомлений: {', '.join(NOTIFY)} через запятую, all или off" + (f", а не «{', '.join(bad)}»" if bad else ""))
    deny = [k for k in want if k not in kinds_for(role)]
    if deny:
        die(f"{', '.join(deny)} — только главным админам")
    return [k for k in NOTIFY if k in want]


def notify_names(kinds):
    return ", ".join(NOTIFY[k][0] for k in kinds) if kinds else "нет"


class ApiError(Exception):
    """Bot API ответил ошибкой: code — HTTP-код, 0 — нет связи."""

    def __init__(self, code, text):
        super().__init__(text)
        self.code = code


def api_call(api, token, method, params, timeout=10):
    """Вызов Bot API без прокси -> result. Текст ошибки без токена."""
    if not API.match(api):
        raise ApiError(-1, f"IOF_TG_API в web.env: нужен адрес вида https://api.telegram.org, а не «{api}»")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(f"{api.rstrip('/')}/bot{token}/{method}", data=json.dumps(params).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with opener.open(req, timeout=timeout) as r:
            data = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            desc = json.loads(e.read().decode("utf-8", "replace")).get("description") or ""
        except (ValueError, OSError, AttributeError, http.client.HTTPException):
            desc = ""
        raise ApiError(e.code, f"{e.code} {desc}".strip().replace(token, "***"))
    except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException) as e:
        raise ApiError(0, f"нет связи с {api}: {getattr(e, 'reason', None) or e}".replace(token, "***"))
    if not isinstance(data, dict) or data.get("ok") is not True:
        raise ApiError(0, "Bot API вернул некорректный ответ или отказ")
    return data.get("result")


def load(path):
    """bot.json с полями по умолчанию, без истёкших приглашений."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        data = {}
    except (OSError, ValueError) as e:
        die(f"{path} не читается ({e}): исправь его или удали, и настрой бота заново")
    if not isinstance(data, dict):
        die(f"{path}: нужен JSON-объект, исправь его или удали")
    cfg = defaults()
    cfg.update(data)
    for k in ("admins", "invites"):
        cfg[k] = [x for x in cfg[k] if isinstance(x, dict)] if isinstance(cfg[k], list) else []
    now = time.time()
    cfg["invites"] = [i for i in cfg["invites"] if isinstance(i.get("expires"), (int, float)) and i["expires"] > now]
    return cfg


def save(path, cfg):
    # Новым файлом и переименованием: поток бота видит смену inode и не прочтёт файл наполовину
    tmp = f"{path}.tmp{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def admin_by(cfg, value):
    if not re.fullmatch(r"[0-9]{1,16}", value or ""):
        die(f"ID пользователя Telegram — число, а не «{value}»: sudo iof bot show")
    a = next((a for a in cfg["admins"] if a.get("id") == int(value)), None)
    if a is None:
        die(f"админа с ID {value} нет: sudo iof bot show")
    return a


def onoff(value, usage):
    if value not in ("on", "off"):
        die("используй: " + usage)
    return value == "on"


def bot_name(cfg):
    return "@" + cfg["username"] if cfg.get("username") else "бот"


def getme(api):
    """Проверка токена со stdin: getMe. Печатает имя бота. Текст ошибки без токена."""
    token = sys.stdin.readline().strip()
    try:
        me = api_call(api, token, "getMe", {}, timeout=15)
    except ApiError as e:
        if e.code in (401, 404):
            die(f"Telegram не принял токен ({e}): проверь его у @BotFather, /mybots → API Token")
        die(f"Bot API ответил ошибкой {e}" if e.code > 0 else str(e))
    if not isinstance(me, dict) or not USERNAME.match(str(me.get("username", ""))):
        die("Bot API не вернул имя бота")
    print(me["username"])


def in_quiet(quiet, now):
    """Сейчас (time.struct_time, время сервера) тихие часы: {"from": "23:00", "to": "08:00"}, через полночь тоже."""
    if not isinstance(quiet, dict):
        return False
    a, b = (CLOCK.match(str(quiet.get(k, ""))) for k in ("from", "to"))
    if not a or not b:
        return False
    frm, to = (int(x.group(1)) * 60 + int(x.group(2)) for x in (a, b))
    m = now.tm_hour * 60 + now.tm_min
    return frm <= m < to if frm < to else (m >= frm or m < to)


def parts(text):
    """Экранированные части текста: сущность HTML и символ Unicode никогда не режутся.
    Запас под заголовок; считаем и HTML, и UTF-16 (emoji занимают две позиции)."""
    out, cur, size = [], [], 0
    for char in text:
        escaped = html.escape(char)
        width = len(escaped.encode("utf-16-le")) // 2
        if size + width > MAX_TEXT - 256:
            out.append("".join(cur))
            cur, size = [], 0
        cur.append(escaped)
        size += width
    if cur:
        out.append("".join(cur))
    return out


def notify(path, token_path, api, kind):
    """Уведомление kind со stdin каждому подписанному админу (tg_send в iof.sh). Код 3 — бот выключен или
    нет токена: тогда iof шлёт старым путём. В тихие часы без звука, кроме админов с sound. Нет связи —
    дальше не пробует: адрес API у всех один."""
    text = sys.stdin.read().strip()
    if kind not in NOTIFY:
        die(f"неизвестный тип уведомления {kind}")
    cfg = load(path)
    try:
        with open(token_path, encoding="utf-8") as f:
            token = f.read().strip()
    except OSError:
        token = ""
    if not cfg["enabled"] or not token:
        sys.exit(3)
    title = NOTIFY[kind][1]
    lines = []
    for line in text.split("\n"):
        mark = next((m for m in MARKS if line.startswith(m)), None)
        lines.append(MARKS[mark] + line[len(mark):] if mark else line)
    body = [f"<b>{html.escape(title)}</b>\n{part}" for part in parts("\n".join(lines))]
    to = [a for a in cfg["admins"] if type(a.get("id")) is int and subscribed(a, kind)]
    if not to:
        print(f"Уведомление «{title}»: на этот тип никто из админов не подписан")
        return
    quiet = in_quiet(cfg["quiet"], time.localtime())
    sent, errors = 0, []
    for a in to:
        params = {"chat_id": a["id"], "parse_mode": "HTML", "disable_web_page_preview": True}
        if quiet and not a.get("sound"):
            params["disable_notification"] = True
        try:
            for part in body:
                api_call(api, token, "sendMessage", dict(params, text=part))
            sent += 1
        except ApiError as e:
            errors.append(f"админу {a['id']}: {e}")
            if e.code <= 0:
                break
    note = ", тихие часы" if quiet else ""
    print(f"Уведомление «{title}»: отправлено {sent} из {len(to)}{note}")
    if errors:
        print(f"Уведомление «{title}» не отправлено " + "; ".join(errors), file=sys.stderr)
        sys.exit(1)


def redeem(cfg):
    """Код приглашения от бота. stdin: код, ID, имя, username по строке. Печатает result=added|already|bad
    и role. Приглашение одноразовое: верный код удаляется вместе с хэшем."""
    lines = sys.stdin.read().split("\n") + ["", "", "", ""]
    code, uid, name, username = (s.strip() for s in lines[:4])
    if not re.fullmatch(r"[0-9]{1,16}", uid):
        die("redeem: со stdin нужны код, ID, имя и username по строке")
    uid = int(uid)
    old = next((a for a in cfg["admins"] if a.get("id") == uid), None)
    if old is not None:
        return "already", old.get("role", "")
    digest = hashlib.sha256(code.lower().encode()).hexdigest() if CODE.match(code.lower()) else ""
    inv = next((i for i in cfg["invites"] if digest and hmac.compare_digest(str(i.get("hash", "")), digest)), None)
    if inv is None:
        return "bad", ""
    cfg["invites"].remove(inv)
    role = inv.get("role") if inv.get("role") in ROLES else "regular"
    cfg["admins"].append({"id": uid, "name": re.sub(r"[\x00-\x1f\x7f]", " ", name)[:64],
                          "username": username if USERNAME.match(username) else "", "role": role,
                          "sound": False, "notify": None, "added": int(time.time())})
    return "added", role


def edit(path, op, args):
    cfg = load(path)
    args += [""] * 3
    if op == "token":
        cfg["username"] = args[0]
    elif op == "untoken":
        cfg["enabled"], cfg["username"] = False, ""
    elif op == "enable":
        cfg["enabled"] = onoff(args[0], "iof bot on | off")
        if cfg["enabled"]:
            print(f"Бот включён: {bot_name(cfg)}, работает внутри панели iof-web")
            if not cfg["admins"]:
                print(f"Админов пока нет. Пригласить: sudo iof bot invite main, код отправь боту {bot_name(cfg)}")
        else:
            print("Бот выключен")
    elif op == "set":
        key = {"actions": "actions", "links": "hy2_links"}.get(args[0])
        if key is None:
            die("используй: iof bot set actions|links on|off | set quiet ЧЧ:ММ-ЧЧ:ММ|off")
        cfg[key] = onoff(args[1], f"iof bot set {args[0]} on|off")
        if key == "actions":
            print("Действия из бота: " + ("разрешены главным админам" if cfg[key] else "выключены"))
        else:
            print("Ссылки Hysteria2 в боте: " + ("выдаются" if cfg[key] else "не выдаются"))
    elif op == "quiet":
        if args[0] == "off":
            cfg["quiet"] = None
            print("Тихие часы выключены")
        else:
            m = re.fullmatch(r"([0-9:]+)-([0-9:]+)", args[0])
            a, b = (CLOCK.match(m.group(1)), CLOCK.match(m.group(2))) if m else (None, None)
            if not a or not b:
                die("тихие часы: ЧЧ:ММ-ЧЧ:ММ, например 23:00-08:00, или off")
            frm, to = (f"{int(x.group(1)):02d}:{x.group(2)}" for x in (a, b))
            if frm == to:
                die("у тихих часов начало и конец совпадают")
            cfg["quiet"] = {"from": frm, "to": to}
            print(f"Тихие часы: {frm}–{to}, время сервера")
    elif op == "invite":
        if args[0] not in ROLES:
            die("используй: iof bot invite main|regular")
        if len(cfg["invites"]) >= INVITE_MAX:
            die(f"неиспользованных приглашений уже {INVITE_MAX}, отзови лишние: sudo iof bot invite del <хэш>")
        code = hashlib.sha256(secrets.token_bytes(32)).hexdigest()
        now = int(time.time())
        cfg["invites"].append({"hash": hashlib.sha256(code.encode()).hexdigest(), "role": args[0],
                               "created": now, "expires": now + INVITE_TTL})
        save(path, cfg)
        name = bot_name(cfg)
        print(f"Приглашение: роль {ROLES[args[0]]}, действует до {when(now + INVITE_TTL)}, один раз.")
        print("Код показывается только сейчас, на сервере хранится его хэш:")
        print()
        print(code)
        print()
        print(f"Будущий админ отправляет код боту {name} в личном чате.")
        if cfg.get("username"):
            print(f"Или открывает ссылку: https://t.me/{cfg['username']}?start={code}")
        if not cfg["enabled"]:
            print("Бот выключен, код примет только работающий бот: sudo iof bot on")
        return
    elif op == "invite-del":
        prefix = args[0].lower()
        if not re.fullmatch(r"[0-9a-f]{6,64}", prefix):
            die("используй: iof bot invite del <начало хэша, хотя бы 6 знаков, из iof bot show>")
        found = [i for i in cfg["invites"] if str(i.get("hash", "")).startswith(prefix)]
        if not found:
            die(f"нет приглашения с хэшем {prefix}…: sudo iof bot show")
        if len(found) > 1:
            die(f"под {prefix}… подходит {len(found)} приглашения, дай больше знаков хэша")
        cfg["invites"].remove(found[0])
        print(f"Приглашение {prefix}… отозвано")
    elif op == "redeem":
        result, role = redeem(cfg)
        print(f"result={result}")
        print(f"role={role}")
        if result != "added":
            return
        # Для уведомления главным админам (iof.sh): кто добавился
        a = cfg["admins"][-1]
        print(f"who={a['name'] or 'без имени'}" + (f" @{a['username']}" if a["username"] else "") + f", ID {a['id']}")
    elif op == "admin-set":
        a = admin_by(cfg, args[0])
        if args[1] == "role":
            if args[2] not in ROLES:
                die("используй: iof bot admin set <ID> role main|regular")
            a["role"] = args[2]
            print(f"Админ {a['id']}: роль {ROLES[args[2]]}")
            # Типы, недоступные новой роли, снимаются: обратно их отмечают заново
            if isinstance(a.get("notify"), list):
                a["notify"] = [k for k in a["notify"] if k in kinds_for(args[2])]
        elif args[1] == "sound":
            a["sound"] = onoff(args[2], "iof bot admin set <ID> sound on|off")
            print(f"Админ {a['id']}: уведомления в тихие часы " + ("со звуком" if a["sound"] else "без звука"))
        elif args[1] == "notify":
            a["notify"] = notify_parse(args[2], a.get("role"))
            print(f"Админ {a['id']}: уведомления — {notify_names(a['notify'])}")
        else:
            die("используй: iof bot admin set <ID> role main|regular | sound on|off | notify <типы>|all|off")
    elif op == "admin-del":
        a = admin_by(cfg, args[0])
        cfg["admins"].remove(a)
        print(f"Админ {a['id']} удалён: бот больше ему не отвечает")
    else:
        die(f"неизвестная операция {op}")
    save(path, cfg)


def cols(rows):
    """Строки таблицы с колонками по ширине, первая — заголовок."""
    width = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    return ["  ".join(c.ljust(width[i]) for i, c in enumerate(r)).rstrip() for r in rows]


def show(path, token, api, panel, migrate):
    cfg = load(path)
    state = "включён" if cfg["enabled"] else "выключен"
    print(f"Бот: {state}, {bot_name(cfg) if token == 'yes' else 'токена нет: sudo iof bot token'}")
    quiet = cfg["quiet"]
    quiet = f"{quiet.get('from')}–{quiet.get('to')}" if isinstance(quiet, dict) else "нет"
    print("Действия из бота: " + ("разрешены главным" if cfg["actions"] else "выключены")
          + ". Ссылки Hysteria2: " + ("выдаются" if cfg["hy2_links"] else "не выдаются")
          + f". Тихие часы: {quiet}")
    panels = {"active": "работает", "none": "не установлена, бота без неё нет: sudo bash /opt/iof/install.sh"}
    print("Панель iof-web, в ней работает бот: " + panels.get(panel, f"не работает ({panel}): sudo systemctl start iof-web"))
    if api.rstrip("/") != "https://api.telegram.org":
        print(f"Bot API: {api} (IOF_TG_API в web.env)")
    if migrate == "target":
        print("Перенос: сервер принимает управление, бот запустится после sudo iof migrate finish")
    elif migrate == "source":
        print("Перенос: идёт отсюда, изменения бота заблокированы")
    print()
    if cfg["admins"]:
        print(f"Админы: {len(cfg['admins'])}")
        rows = [["ID", "Имя", "Username", "Роль", "Звук в тихие часы", "Добавлен", "Уведомления"]]
        for a in cfg["admins"]:
            kinds = [k for k in NOTIFY if subscribed(a, k)]
            rows.append([str(a.get("id")), str(a.get("name") or "-"), "@" + a["username"] if a.get("username") else "-",
                         ROLES.get(a.get("role"), str(a.get("role"))), "да" if a.get("sound") else "нет",
                         when(a["added"]) if isinstance(a.get("added"), (int, float)) else "-",
                         ",".join(kinds) or "нет"])
        print("\n".join("  " + line for line in cols(rows)))
        print()
        print("  Типы уведомлений (sudo iof bot admin set <ID> notify nodes,audit | all | off):")
        for k, (_, _, about) in NOTIFY.items():
            print(f"    {k:<8} {about}")
    else:
        print("Админов нет. Пригласить: sudo iof bot invite main")
    if cfg["invites"]:
        print()
        print(f"Приглашения: {len(cfg['invites'])} (кодов на сервере нет, только хэши)")
        rows = [["Хэш", "Роль", "Действует до"]]
        for i in cfg["invites"]:
            rows.append([str(i.get("hash", ""))[:12], ROLES.get(i.get("role"), "?"), when(i["expires"])])
        print("\n".join("  " + line for line in cols(rows)))
        print("  Отозвать: sudo iof bot invite del <хэш>")


mode = sys.argv[1]
if mode == "getme":
    getme(sys.argv[2])
elif mode == "notify":
    notify(*sys.argv[2:6])
elif mode == "edit":
    edit(sys.argv[2], sys.argv[3], sys.argv[4:])
elif mode == "show":
    show(*sys.argv[2:7])
EOF
)

bot_py() { python3 -c "$BOT_PY" "$@"; }

# Адрес Bot API: IOF_TG_API из окружения (так его передаёт панель) или из web.env, иначе Telegram.
# Другой адрес нужен только стенду и CI с поддельным API
bot_api() {
  local api="${IOF_TG_API:-}"
  if [[ -z "$api" && -f "$BASE/web.env" ]]; then
    api="$(sed -n 's/^[[:space:]]*IOF_TG_API=//p' "$BASE/web.env" | tail -n 1 | tr -d "\"' ")"
  fi
  printf '%s' "${api:-https://api.telegram.org}"
}

# Изменения bot.json по одному: iof bot из консоли, из панели и из потока бота не затрут друг друга
bot_lock() {
  mkdir -p "$BASE"
  (umask 077; : >> "$BOT_LOCK")
  exec 9>>"$BOT_LOCK"
  flock -w 15 9 || die "bot.json занят другой командой iof bot, повтори"
}

# Токен со stdin (в консоли спрашивает, не показывая): проверка getMe, затем bot.token и имя бота
# в bot.json. Пустой ввод удаляет токен и выключает бота
bot_token() {
  local token="" username
  if [[ -t 0 ]]; then
    read -rsp "Токен бота от @BotFather (пусто — удалить токен и выключить бота): " token || true
    echo >&2
  else
    IFS= read -r token || true
  fi
  token="${token//[[:space:]]/}"
  if [[ -z "$token" ]]; then
    bot_lock
    rm -f "$BOT_TOKEN"
    bot_py edit "$BOT_FILE" untoken
    echo "Токен удалён, бот выключен"
    return 0
  fi
  [[ "$token" =~ ^[0-9]{1,20}:[A-Za-z0-9_-]{20,100}$ ]] \
    || die "это не токен бота: он выглядит как 123456789:AAF... (@BotFather, /mybots → API Token)"
  # printf встроен в bash: токена нет в аргументах процессов
  username="$(printf '%s\n' "$token" | bot_py getme "$(bot_api)")" || exit 1
  bot_lock
  (umask 077; printf '%s\n' "$token" > "$BOT_TOKEN.tmp")
  mv -f "$BOT_TOKEN.tmp" "$BOT_TOKEN"
  bot_py edit "$BOT_FILE" token "$username"
  echo "Токен сохранён: бот @$username"
}

bot_switch() {
  if [[ "$1" == "on" && ! -s "$BOT_TOKEN" ]]; then
    die "сначала токен бота: sudo iof bot token (токен даёт @BotFather)"
  fi
  bot_py edit "$BOT_FILE" enable "$1"
  if [[ "$1" == "on" ]] && ! systemctl is-active --quiet iof-web 2>/dev/null; then
    echo "Внимание: панель iof-web не работает, а бот работает внутри неё: sudo systemctl start iof-web"
  fi
}

# Код приглашения (вызывает поток бота). Добавился админ — главным админам, подписанным на «новые админы»,
# уведомление: утёкший код видно сразу. bot.json к этому времени уже отпущен
bot_redeem() {
  local out who role
  bot_lock
  out="$(bot_py edit "$BOT_FILE" redeem)"
  printf '%s\n' "$out"
  exec 9>&-
  [[ "$(kv_get "$out" result)" == "added" ]] || return 0
  who="$(kv_get "$out" who)"
  role="$(kv_get "$out" role)"
  if [[ "$role" == "main" ]]; then role="главный"; else role="обычный"; fi
  tg_send admins "По приглашению добавился админ: $who, роль $role."$'\n'"Если это не тот, кого ты приглашал, удали его на странице «Телеграм бот» панели или: sudo iof bot admin del ${who##*ID }"
}

bot_show() {
  local token=no panel
  if [[ -s "$BOT_TOKEN" ]]; then token=yes; fi
  panel="$(systemctl is-active iof-web 2>/dev/null || true)"
  if [[ ! -f /opt/iof-web/iof-web.py ]]; then panel=none; fi
  bot_py show "$BOT_FILE" "$token" "$(bot_api)" "${panel:-unknown}" "$(migrate_get role)"
}

cmd_bot() {
  local action="${1:-show}"
  if [[ $# -gt 0 ]]; then shift; fi
  have python3 || die "боту нужен python3: apt install python3"
  case "$action" in
    show)   bot_show ;;
    token)  bot_token ;;
    on|off) bot_lock; bot_switch "$action" ;;
    set)
      bot_lock
      if [[ "${1:-}" == "quiet" ]]; then bot_py edit "$BOT_FILE" quiet "${2:-}"; else bot_py edit "$BOT_FILE" set "${1:-}" "${2:-}"; fi ;;
    invite)
      bot_lock
      if [[ "${1:-}" == "del" ]]; then bot_py edit "$BOT_FILE" invite-del "${2:-}"; else bot_py edit "$BOT_FILE" invite "${1:-}"; fi ;;
    # Вызывает поток бота: со stdin код приглашения, ID, имя и username
    redeem) bot_redeem ;;
    admin)
      bot_lock
      case "${1:-}" in
        set) bot_py edit "$BOT_FILE" admin-set "${2:-}" "${3:-}" "${4:-}" ;;
        del) bot_py edit "$BOT_FILE" admin-del "${2:-}" ;;
        *)   die "используй: iof bot admin set <ID> role main|regular | sound on|off | notify <типы>|all|off | admin del <ID>" ;;
      esac ;;
    *) die "используй: iof bot show | token | on | off | set ... | invite main|regular | invite del <хэш> | admin ..." ;;
  esac
}
