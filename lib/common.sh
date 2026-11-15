#!/usr/bin/env bash

# Пути на управляющем сервере
BASE="/root/iof"
ENV_FILE="$BASE/iof.env"
NODES_FILE="$BASE/nodes.conf"
RELAYS_FILE="$BASE/relays.conf"
STATE_DIR="$BASE/state"
HY2_DIR="$BASE/hy2"
HY2_INDEX="$HY2_DIR/index.tsv"
AWG_LINKS="$BASE/awg"
AWG_INDEX="$AWG_LINKS/index.tsv"
MIGRATE_FILE="$BASE/migrate.conf"
MIGRATE_INBOX="/root/.iof-migrate"   # куда новый управляющий сервер принимает данные при переносе
CHECK_FILE="$BASE/check.last"        # итог последнего iof check для панели
AUDIT_DIR="$BASE/audit"              # результаты iof audit: <блок>.json и history.jsonl
PROBE_DIR="$AUDIT_DIR/probe"         # проверка с ПК: session.json, token, результаты <время>.json
PROBE_WHITE="$BASE/probe-white.txt"  # контрольные сайты для проверки с ПК: открываются из России всегда
PROBE_BLACK="$BASE/probe-black.txt"  # и давно заблокированные РКН
BOT_FILE="$BASE/bot.json"            # Telegram-бот: настройки, админы, хэши приглашений (iof bot)
BOT_TOKEN="$BASE/bot.token"          # токен бота от @BotFather
BOT_LOCK="$BASE/bot.lock"            # iof bot меняет bot.json по одному
DAILY_FILE="$BASE/check.daily"       # раз в сутки из iof check: обновления iof и доступ к российским серверам
RU_DIR="$BASE/ru"                    # доступ к российским серверам с узла: ok, cut или noinet в файле узла
# Типы уведомлений (iof notify, tg_send, notify у админа бота). Те же — NOTIFY в BOT_PY, BOT_NOTIFY
# в iof-web.py и NOTIFY в bot.js, их сверяет ci/lint.sh
NOTIFY_KINDS="nodes audit nightly updates ru admins"
SSH_KEY="/root/.ssh/iof_ed25519"
# Смене портов Hysteria2 нужна эта версия: раньше её правила заворачивали и исходящий UDP самого узла
HY2_HOP_MIN="2.12.3"
# Записи блок-листа шире этой маски не применяются: ошибка в списке не должна отрезать клиентов
BLOCK_MIN_PREFIX=16

# Коммит и дата этой версии, install.sh подставляет их при установке
IOF_VERSION="dev"

# Настройки по умолчанию, переопределяются в iof.env
TG_TOKEN=""
TG_CHAT=""
PARALLEL=20
IOF_SRC="/opt/iof"   # клон репозитория для iof update
AUDIT_KEEP=30        # сколько последних запусков iof audit хранить в истории
BLOCKLIST_URL=""     # список адресов сканеров для iof audit и iof block: текст, по IP или CIDR в строке, # — комментарий
BLOCK_ALLOW=""       # адреса и сети через пробел, которые блок-лист не блокирует никогда (например, свой домашний)
REGISTRY_URL=""      # выгрузка реестра блокировок в том же формате: есть ли в ней адреса узлов
PROBE_TTL=900        # сколько секунд живут мишени проверки с ПК (iof audit probe)
PROBE_PORTS=""       # порт мишеней: пусто — случайный свободный 20000–60000, a-b — из диапазона, N — этот
HY2_HOP="10000-19999" # диапазон смены портов Hysteria2 для iof hy2 hop on: ниже портов, которые iof сам
                     # выбирает для ретрансляторов и мишеней (20000–60000)
# Российские серверы, до которых раз в сутки iof check проверяет путь с каждого узла (TCP 443 и ping):
# имена или IPv4 через пробел, пусто — не проверять. Госуслуг нет: они режут заграницу всегда
RU_TARGETS="ya.ru vk.com mail.ru ozon.ru wildberries.ru rt.ru"
RU_CONTROL="1.1.1.1 8.8.8.8" # зарубежные: не отвечают и они — у узла нет интернета, а не закрыт путь к РФ
IOF_ONLY=""
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null # файл на сервере, в репозитории его нет
  source "$ENV_FILE"
fi

die()  { echo "Ошибка: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Связь с узлами

# Разбирает "user@host:port" в $T_HOST ("user@host") и $T_PORT
split_target() {
  T_HOST="$1"
  T_PORT=22
  if [[ "$1" =~ ^(.+):([0-9]+)$ ]]; then
    T_HOST="${BASH_REMATCH[1]}"
    T_PORT="${BASH_REMATCH[2]}"
  fi
}

ssh_cmd() {
  split_target "$1"
  shift
  ssh -i "$SSH_KEY" -p "$T_PORT" \
    -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 \
    -o StrictHostKeyChecking=accept-new "$T_HOST" "$@"
}

# Если на узел заходим не под root, команды идут через sudo -n (нужен NOPASSWD)
remote_sudo() {
  local user="${1%%@*}"
  if [[ "$1" == *@* && "$user" != "root" ]]; then printf 'sudo -n '; fi
}

# Выполняет функцию n_* на узле: run_on <local|user@host[:port]> <функция> [аргументы].
# Скрипт с функциями и аргументами уходит через stdin, поэтому пароли не видны в списке процессов узла.
# На самом управляющем сервере скрипт читается из канала, а не из аргумента: так его тоже не видно
# в списке процессов, stdin остаётся свободным, и нет предела в 128 КБ на аргумент (блок-лист больше)
run_on() {
  local target="$1" script
  shift
  script="set -euo pipefail; $(declare -f "${NODE_FUNCS[@]}"); $(printf '%q ' "$@")"
  if [[ "$target" == "local" ]]; then
    bash <(printf '%s' "$script")
  else
    ssh_cmd "$target" "$(remote_sudo "$target")bash -s" <<<"$script"
  fi
}


# Списки узлов и ретрансляторов

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

nodes_present() { [[ -f "$NODES_FILE" ]] && grep -qvE '^[[:space:]]*(#|$)' "$NODES_FILE"; }

# nodes.conf: имя | адрес для клиентов | ssh (local или user@host[:port]) | подпись в клиенте.
# Заполняет массивы N_NAME, N_ADDR, N_SSH, N_TITLE
read_nodes() {
  [[ -f "$NODES_FILE" ]] || die "нет $NODES_FILE, сначала: iof init или iof node import"
  N_NAME=(); N_ADDR=(); N_SSH=(); N_TITLE=()
  local name addr target title
  while IFS='|' read -r name addr target title || [[ -n "$name" ]]; do
    name="$(trim "$name")"
    if [[ -z "$name" || "$name" == \#* ]]; then continue; fi
    N_NAME+=("$name")
    N_ADDR+=("$(trim "${addr:-}")")
    N_SSH+=("$(trim "${target:-local}")")
    N_TITLE+=("$(trim "${title:-}")")
  done < "$NODES_FILE"
  (( ${#N_NAME[@]} > 0 )) || die "в $NODES_FILE нет узлов"
}

node_index() {
  local i
  for i in "${!N_NAME[@]}"; do
    if [[ "${N_NAME[$i]}" == "$1" ]]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

node_title() { printf '%s' "${N_TITLE[$1]:-${N_NAME[$1]}}"; }

node_name_ok() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# Проверки полей нового узла. Хост и пользователь попадают в аргументы ssh, поэтому
# никаких пробелов, "@" и ведущего "-". IPv6 не поддерживается: ":" занят под порт в nodes.conf
host_ok()  { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }
user_ok()  { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; }
port_ok()  { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
title_ok() { [[ "$1" != *"|"* && "$1" != *$'\n'* ]]; }

# Имя файла конфига узла для клиентов AWG, по подписи узла: France.conf
node_file_name() {
  local i="$1" t
  t="$(slugify "${N_TITLE[$i]}")"
  printf '%s.conf' "${t:-${N_NAME[$i]}}"
}

# relays.conf: узел | через узел | порт hy2 на ретрансляторе | порт hy2 на узле | порт awg на ретрансляторе | порт awg на узле.
# "-" вместо порта означает, что протокол не ретранслируется
read_relays() {
  R_NODE=(); R_VIA=(); R_HYL=(); R_HYD=(); R_AWL=(); R_AWD=()
  [[ -f "$RELAYS_FILE" ]] || return 0
  local node via hyl hyd awl awd
  while IFS='|' read -r node via hyl hyd awl awd || [[ -n "$node" ]]; do
    node="$(trim "$node")"
    if [[ -z "$node" || "$node" == \#* ]]; then continue; fi
    R_NODE+=("$node")
    R_VIA+=("$(trim "${via:-}")")
    R_HYL+=("$(trim "${hyl:--}")")
    R_HYD+=("$(trim "${hyd:--}")")
    R_AWL+=("$(trim "${awl:--}")")
    R_AWD+=("$(trim "${awd:--}")")
  done < "$RELAYS_FILE"
}

# Отбор узлов по именам или шаблонам через запятую или пробел (all = все). Без аргументов
# берётся значение -n из командной строки. Индексы выбранных узлов в SEL
select_nodes() {
  local spec="${*:-${IOF_ONLY:-all}}" p i
  local pats=()
  read -r -a pats <<<"${spec//,/ }"
  SEL=()
  for i in "${!N_NAME[@]}"; do
    for p in "${pats[@]}"; do
      # shellcheck disable=SC2053
      if [[ "$p" == "all" || "${N_NAME[$i]}" == $p ]]; then
        SEL+=("$i")
        break
      fi
    done
  done
  (( ${#SEL[@]} > 0 )) || die "под '$spec' не подходит ни один узел, см. iof node list"
}


# Вспомогательные функции

slugify() {
  local s
  s="$(LC_ALL=C sed -E 's/[^A-Za-z0-9]+/_/g; s/^_+//; s/_+$//' <<<"$1")"
  printf '%s' "${s:0:32}"
}

# Логин из подписи. Чистая латиница остаётся как есть, иначе добавляется стабильный хэш,
# чтобы "Мама iPhone" и "Папа iPhone" не слились в один логин, а повторный запуск давал тот же
name_for() {
  local n h
  n="$(slugify "$1")"
  if [[ "$1" =~ ^[A-Za-z0-9\ ._-]+$ && -n "$n" ]]; then
    printf '%s' "$n"
    return 0
  fi
  h="$(printf '%s' "$1" | sha1sum | cut -c1-8)"
  if [[ -n "$n" ]]; then printf '%s_%s' "$n" "$h"; else printf 'user_%s' "$h"; fi
}

gen_pass() {
  local p
  p="$(head -c 48 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9')"
  printf '%s' "${p:0:20}"
}

# Таблица из строк с колонками через TAB. Ширина считается по символам, а не байтам,
# поэтому кириллица не сдвигает колонки. Первая строка заголовок. Ячейки с меткой
# \001<R|G|Y> раскрашиваются, если вывод идёт в терминал
TABLE_PY=$(cat <<'EOF'
import os, sys
color = os.environ.get("IOF_COLOR") == "1"
codes = {"R": "31", "G": "32", "Y": "33"}
rows = [l.rstrip("\n").split("\t") for l in sys.stdin if l.strip("\n")]
if not rows:
    sys.exit(0)

def parse(c):
    if c.startswith("\x01") and len(c) > 1 and c[1] in codes:
        return c[1], c[2:]
    return "", c

cells = [[parse(c) for c in r] for r in rows]
n = max(len(r) for r in cells)
width = [0] * n
for r in cells:
    for i, (_, t) in enumerate(r):
        width[i] = max(width[i], len(t))
for ri, r in enumerate(cells):
    out = []
    for i, (k, t) in enumerate(r):
        text = t.ljust(width[i]) if i < len(r) - 1 else t
        if color and ri == 0:
            text = "\033[1m" + text + "\033[0m"
        elif color and k:
            text = "\033[" + codes[k] + "m" + text + "\033[0m"
        out.append(text)
    print("  ".join(out).rstrip())
EOF
)

table() {
  local color=0
  if [[ -t 1 ]]; then color=1; fi
  if have python3; then
    IOF_COLOR="$color" python3 -c "$TABLE_PY"
  elif have column; then
    sed 's/\x01[RGY]//g' | column -t -s $'\t'
  else
    sed 's/\x01[RGY]//g'
  fi
}
row()   { local IFS=$'\t'; printf '%s\n' "$*"; }

# Строка индекса (файл $1) с ключом $2: без $3 удаляется, с $3 добавляется в конец или
# обновляется на своём месте. Дата создания у существующей строки остаётся прежней: повторный
# hy2 add и refresh пересобирают группу, а не создают её заново.
# Значения идут через окружение: awk -v разбирал бы \ в подписи
index_set() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  IX_NAME="$2" IX_LABEL="${3:-}" IX_NOW="$(date '+%F %T')" awk -F'\t' -v OFS='\t' '
    $1 == ENVIRON["IX_NAME"] {
      if (ENVIRON["IX_LABEL"] != "" && !done) print $1, ENVIRON["IX_LABEL"], ($3 != "" ? $3 : ENVIRON["IX_NOW"])
      done = 1
      next
    }
    { print }
    END { if (ENVIRON["IX_LABEL"] != "" && !done) print ENVIRON["IX_NAME"], ENVIRON["IX_LABEL"], ENVIRON["IX_NOW"] }
  ' "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"
}


# Параллельный запуск: pmap <функция> <индекс>...
# Функция вызывается с индексом, её stdout, stderr и код сохраняются в $PM_DIR/<индекс>.out/.err/.rc.
# Одновременно работает не больше $PARALLEL задач. Задачи выполняются в подшеллах, поэтому
# изменения переменных в них не видны вызывающему коду, результат читается через pm_*.

PM_DIRS=()
pm_cleanup() { local d; for d in "${PM_DIRS[@]}"; do rm -rf "$d"; done; }
trap pm_cleanup EXIT

pmap() {
  local fn="$1" i running=0 total
  shift
  total=$#
  PM_DIR="$(mktemp -d)"
  PM_DIRS+=("$PM_DIR")
  for i in "$@"; do
    (
      if "$fn" "$i" > "$PM_DIR/$i.out" 2> "$PM_DIR/$i.err"; then
        echo 0 > "$PM_DIR/$i.rc"
      else
        echo $? > "$PM_DIR/$i.rc"
      fi
      if [[ -t 2 ]]; then
        printf '\r  выполнено %s из %s ' "$(find "$PM_DIR" -name '*.rc' | wc -l)" "$total" >&2
      fi
    ) &
    running=$((running + 1))
    if (( running >= PARALLEL )); then
      wait -n 2>/dev/null || true
      running=$((running - 1))
    fi
  done
  wait || true
  if [[ -t 2 ]]; then printf '\r\033[K' >&2; fi
}

pm_rc()  { cat "$PM_DIR/$1.rc" 2>/dev/null || echo 255; }
pm_out() { cat "$PM_DIR/$1.out" 2>/dev/null || true; }
pm_err() { cat "$PM_DIR/$1.err" 2>/dev/null || true; }
pm_ok()  { [[ "$(pm_rc "$1")" == "0" ]]; }

# Узлы с ошибкой и последняя строка их stderr. Код 255 без текста означает проблему SSH
report_failures() {
  local i msg
  for i in "$@"; do
    msg="$(pm_err "$i" | grep -v '^[[:space:]]*$' | tail -n 1 || true)"
    if [[ "$(pm_rc "$i")" == "255" && -z "$msg" ]]; then msg="нет связи по SSH"; fi
    printf '  %-20s %s\n' "${N_NAME[$i]}" "${msg:-код $(pm_rc "$i")}"
  done
}

# Оформление вывода

# Цветовые метки для table: первый символ \001 и буква цвета, в таблице метка убирается
c_red()    { printf '\001R%s' "$1"; }
c_green()  { printf '\001G%s' "$1"; }
c_yellow() { printf '\001Y%s' "$1"; }

# Цвет для текста вне таблицы, только если вывод идёт в терминал
paint() {
  local code="$1"
  shift
  if [[ -t 1 ]]; then printf '\033[%sm%s\033[0m' "$code" "$*"; else printf '%s' "$*"; fi
}

percent() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { if (b > 0) printf "%d", a * 100 / b + 0.5; else print 0 }'; }

# Объём в гигабайтах из килобайт или мегабайт: gb <число> <делитель до ГБ>
gb() { awk -v v="${1:-0}" -v d="$2" 'BEGIN { g = v / d; if (g >= 10) printf "%.0f", g; else printf "%.1f", g }'; }

fmt_ms() {
  local ms="${1:-0}"
  if (( ms < 1000 )); then printf '%d мс' "$ms"; else printf '%d.%d с' $((ms / 1000)) $(( ms % 1000 / 100 )); fi
}

fmt_uptime() {
  local s="${1:-0}" d h m
  d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
  if (( d > 0 )); then printf '%d д %d ч' "$d" "$h"
  elif (( h > 0 )); then printf '%d ч %d мин' "$h" "$m"
  else printf '%d мин' "$m"
  fi
}

# Значение ключа $2 из строк key=value в $1
kv_get() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' <<<"$1"; }

# Один и тот же адрес SSH: root@host и root@host:22
ssh_same() { [[ "${1%:22}" == "${2%:22}" ]]; }

# Задаёт KEY=значение в файле окружения (iof.env, web.env), прежние строки с этим ключом убирает
env_set() {
  local file="$1" key="$2" value="$3"
  touch "$file"
  { grep -v "^[[:space:]]*$key=" "$file" || true; printf '%s=%s\n' "$key" "$value"; } > "$file.tmp"
  chmod 600 "$file.tmp"
  mv "$file.tmp" "$file"
}
