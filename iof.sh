#!/usr/bin/env bash

# iof (Island of Freedom): управление группой VPN-серверов с одного управляющего сервера
# Запускается только на управляющем сервере
# Протоколы: Hysteria2 (iof hy2), AmneziaWG 2.0 (iof awg)
set -euo pipefail

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
SSH_KEY="/root/.ssh/iof_ed25519"

# Коммит и дата этой версии, install.sh подставляет их при установке
IOF_VERSION="dev"

# Настройки по умолчанию, переопределяются в iof.env
TG_TOKEN=""
TG_CHAT=""
PARALLEL=20
IOF_SRC="/opt/iof"   # клон репозитория для iof update
AUDIT_KEEP=30        # сколько последних запусков iof audit хранить в истории
BLOCKLIST_URL=""     # список адресов сканеров для iof audit: текст, по IP или CIDR в строке, # — комментарий
REGISTRY_URL=""      # выгрузка реестра блокировок в том же формате: есть ли в ней адреса узлов
PROBE_TTL=900        # сколько секунд живут мишени проверки с ПК (iof audit probe)
PROBE_PORTS=""       # порт мишеней: пусто — случайный свободный 20000–60000, a-b — из диапазона, N — этот
IOF_ONLY=""
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null # файл на сервере, в репозитории его нет
  source "$ENV_FILE"
fi

die()  { echo "Ошибка: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }


# Функции с префиксом n_ выполняются на узлах. run_on передаёт их на узел целиком
# вместе с аргументами, поэтому они не должны зависеть от остального кода скрипта.

# Общие параметры узла. Пути Hysteria2 и AmneziaWG здесь же, чтобы их было легко поменять
n_defaults() {
  CONFIG="/etc/hysteria/config.yaml"
  SERVICE="hysteria-server.service"
  SNI="bing.com"
  INSECURE=""
  ADD_PIN=1
  AWG_DIR="/opt/amnezia/awg"
  AWG_DNS="1.1.1.1, 1.0.0.1"
  AWG_BACKUP="/var/backups/iof-awg"
  IOF_HOME="/root/iof"   # то же, что BASE на управляющем сервере, для переноса управления
}

n_err() { echo "Ошибка [$(hostname)]: $*" >&2; exit 1; }

# Значение ключа внутри блока YAML первого уровня: n_yaml_value <блок> <ключ>, файл в $CONFIG
n_yaml_value() {
  awk -v b="$1" -v k="$2" '
    $0 ~ "^[[:space:]]*" b ":[[:space:]]*$" { f=1; next }
    f && /^[^[:space:]#]/ { exit }
    f && $0 ~ "^[[:space:]]*" k ":" {
      sub("^[[:space:]]*" k ":[[:space:]]*", "")
      sub(/[[:space:]]+#.*$/, "")
      print
      exit
    }
  ' "$CONFIG" | sed -E "s/^[\"']//; s/[\"']\$//"
}

n_urlencode() {
  local s="$1" out="" c i hex
  local LC_ALL=C
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}


# Hysteria2 на узле

# UDP-порт Hysteria2 из listen
n_hy2_port() {
  local p
  p="$(grep -oE '^[[:space:]]*listen:[[:space:]]*:?[0-9]+' "$CONFIG" | grep -oE '[0-9]+$' | head -1 || true)"
  printf '%s' "${p:-443}"
}

# Пользователи из блока auth.userpass, по строке "имя<TAB>пароль"
n_hy2_userpass() {
  awk '
    function ind(s) { match(s, /^[ \t]*/); return RLENGTH }
    /^[ \t]*(#.*)?$/ { next }
    !f && /^[ \t]*userpass:[ \t]*$/ { f=1; base=ind($0); next }
    f {
      if (ind($0) <= base) exit
      line=$0
      sub(/^[ \t]+/, "", line)
      name=line; sub(/:.*/, "", name); gsub(/["\047]/, "", name)
      pass=line; sub(/^[^:]*:[ \t]*/, "", pass); sub(/[ \t]+#.*$/, "", pass)
      gsub(/^["\047]|["\047]$/, "", pass)
      print name "\t" pass
    }
  ' "$CONFIG"
}

# Дописывает пользователя в userpass с тем же отступом, что у соседей. Перед записью делает бэкап
n_hy2_user_add() {
  local name="$1" pass="$2" tmp
  tmp="$(mktemp)"
  awk -v u="$name" -v p="$pass" '
    function ind(s) { match(s, /^[ \t]*/); return RLENGTH }
    { lines[NR]=$0 }
    END {
      for (i=1; i<=NR; i++) {
        print lines[i]
        if (!done && lines[i] ~ /^[ \t]*userpass:[ \t]*$/) {
          w = ind(lines[i]) + 2
          for (j=i+1; j<=NR; j++) {
            if (lines[j] ~ /^[ \t]*(#.*)?$/) continue
            if (ind(lines[j]) > ind(lines[i])) w = ind(lines[j])
            break
          }
          printf "%" w "s%s: %s\n", "", u, p
          done=1
        }
      }
    }
  ' "$CONFIG" > "$tmp"
  cp -p "$CONFIG" "${CONFIG}.bak.$(date +%s)"
  cat "$tmp" > "$CONFIG"
  rm -f "$tmp"
}

# Убирает пользователя из userpass. Перед записью делает бэкап
n_hy2_user_del() {
  local name="$1" tmp
  tmp="$(mktemp)"
  awk -v u="$name" '
    function ind(s) { match(s, /^[ \t]*/); return RLENGTH }
    f && !/^[ \t]*(#.*)?$/ && ind($0) <= base { f=0 }
    f {
      l=$0; sub(/^[ \t]+/, "", l)
      n=l; sub(/:.*/, "", n); gsub(/["\047]/, "", n)
      if (n == u) next
    }
    !f && /^[ \t]*userpass:[ \t]*$/ { f=1; base=ind($0) }
    { print }
  ' "$CONFIG" > "$tmp"
  cp -p "$CONFIG" "${CONFIG}.bak.$(date +%s)"
  cat "$tmp" > "$CONFIG"
  rm -f "$tmp"
}

n_hy2_restart() {
  if systemctl restart "$SERVICE"; then
    echo "[$(hostname)] сервис перезапущен" >&2
  else
    echo "[$(hostname)] не удалось перезапустить $SERVICE, сделай это вручную" >&2
  fi
}

# Перезапуск по команде iof hy2 restart: в отличие от n_hy2_restart это ошибка, если сервис не поднялся
n_hy2_service_restart() {
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  systemctl cat "$SERVICE" >/dev/null 2>&1 || n_err "Hysteria2 не установлена"
  systemctl restart "$SERVICE" || n_err "сервис не перезапустился: journalctl -u $SERVICE -n 30"
  sleep 2
  if ! systemctl is-active --quiet "$SERVICE"; then
    n_err "сервис не работает: $(journalctl -u "$SERVICE" -n 3 --no-pager 2>/dev/null | tail -n 1)"
  fi
  echo "ok"
}

# Готовит доступ и печатает ссылку hy2:// в stdout.
# userpass: создаёт пользователя, если его нет (повторный вызов вернёт ту же ссылку).
# password: пользователей нет, в ссылку идёт общий пароль из конфига.
n_hy2_add() {
  local name="$1" pass="$2" label="$3" host="$4"
  local port acme auth_type auth_str existing sni
  local obfs="" pin="" obfs_type obfs_pass cert fp
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  [[ -f "$CONFIG" ]] || n_err "не найден $CONFIG"

  port="$(n_hy2_port)"
  acme="$(awk '/^[[:space:]]*acme:/{f=1} f&&/^[[:space:]]*-[[:space:]]/{sub(/^[[:space:]]*-[[:space:]]*/,""); sub(/[[:space:]]+#.*$/,""); print; exit}' "$CONFIG" || true)"

  # С ACME сертификат настоящий и проверка не нужна, иначе insecure=1 и пин сертификата
  if [[ -z "$INSECURE" ]]; then
    if [[ -n "$acme" ]]; then INSECURE=0; else INSECURE=1; fi
  fi
  if [[ -z "$host" ]]; then host="$acme"; fi
  if [[ -z "$host" ]]; then host="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"; fi
  [[ -n "$host" ]] || n_err "не удалось определить адрес сервера"
  sni="${SNI:-$host}"

  auth_type="$(n_yaml_value auth type || true)"
  case "$auth_type" in
    userpass)
      existing="$(n_hy2_userpass | awk -F'\t' -v u="$name" '$1==u{print $2; exit}' || true)"
      if [[ -n "$existing" ]]; then
        pass="$existing"
        echo "[$(hostname)] пользователь $name уже есть, беру его пароль" >&2
      else
        n_hy2_user_add "$name" "$pass"
        echo "[$(hostname)] добавлен пользователь $name (бэкап конфига сохранён)" >&2
        n_hy2_restart
      fi
      auth_str="$(n_urlencode "$name"):$(n_urlencode "$pass")"
      ;;
    password)
      auth_str="$(n_yaml_value auth password || true)"
      [[ -n "$auth_str" ]] || n_err "не найден auth.password"
      auth_str="$(n_urlencode "$auth_str")"
      ;;
    *)
      n_err "неизвестный auth.type: ${auth_type:-пусто}"
      ;;
  esac

  obfs_type="$(n_yaml_value obfs type || true)"
  if [[ "$obfs_type" == "salamander" ]]; then
    obfs_pass="$(n_yaml_value salamander password || true)"
    [[ -n "$obfs_pass" ]] || n_err "obfs включён, но нет salamander.password"
    obfs="&obfs=salamander&obfs-password=$(n_urlencode "$obfs_pass")"
  fi

  if [[ "$INSECURE" == "1" && "$ADD_PIN" == "1" ]]; then
    cert="$(n_yaml_value tls cert || true)"
    if [[ -n "$cert" && -f "$cert" ]] && command -v openssl >/dev/null 2>&1; then
      fp="$(openssl x509 -noout -fingerprint -sha256 -in "$cert" | cut -d= -f2)"
      if [[ -n "$fp" ]]; then pin="&pinSHA256=$(n_urlencode "$fp")"; fi
    fi
  fi

  printf 'hy2://%s@%s:%s/?sni=%s&insecure=%s%s%s#%s\n' \
    "$auth_str" "$host" "$port" "$(n_urlencode "$sni")" "$INSECURE" "$obfs" "$pin" "$(n_urlencode "$label")"
}

# Удаляет пользователя userpass. В режиме общего пароля на сервере менять нечего
n_hy2_del() {
  local name="$1"
  n_defaults
  [[ -f "$CONFIG" ]] || n_err "не найден $CONFIG"
  if [[ "$(n_yaml_value auth type || true)" != "userpass" ]]; then
    echo "[$(hostname)] общий пароль, на сервере менять нечего" >&2
    return 0
  fi
  if n_hy2_userpass | awk -F'\t' -v u="$name" '$1==u{f=1} END{exit !f}'; then
    n_hy2_user_del "$name"
    echo "[$(hostname)] удалён пользователь $name" >&2
    n_hy2_restart
  else
    echo "[$(hostname)] пользователя $name нет" >&2
  fi
}

# Установка Hysteria2 официальным установщиком и конфиг по шаблону (base64).
# Сертификат создаётся на каждом узле свой (CN = $2), существующий не перезаписывается.
# Печатает "skip", если Hysteria2 уже работает и не передан force=1, иначе "installed <версия>".
n_hy2_install() {
  local tpl="$1" cn="$2" force="$3" cert key port p ver
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"

  if [[ "$force" != "1" && -f "$CONFIG" ]] && command -v hysteria >/dev/null 2>&1 \
     && systemctl is-active --quiet "$SERVICE"; then
    echo "skip"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  if ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq curl openssl >/dev/null 2>&1 || n_err "не удалось установить curl и openssl"
  fi

  if ! command -v hysteria >/dev/null 2>&1; then
    bash <(curl -fsSL https://get.hy2.sh/) > /var/log/iof-hy2-install.log 2>&1 \
      || n_err "установщик Hysteria2 завершился с ошибкой, см. /var/log/iof-hy2-install.log"
  fi
  command -v hysteria >/dev/null 2>&1 || n_err "hysteria не установилась"

  # Шаблон сначала пишется во временный файл: пути сертификата и порт берём из него
  mkdir -p /etc/hysteria
  printf '%s' "$tpl" | base64 -d > "$CONFIG.new" || n_err "шаблон конфига повреждён"
  if grep -qE '^[[:space:]]*acme:' "$CONFIG.new"; then
    rm -f "$CONFIG.new"
    n_err "шаблон использует ACME, массовая установка поддерживает только самоподписанный сертификат"
  fi
  CONFIG="$CONFIG.new"
  cert="$(n_yaml_value tls cert || true)"
  key="$(n_yaml_value tls key || true)"
  port="$(n_hy2_port)"
  CONFIG="/etc/hysteria/config.yaml"
  [[ -n "$cert" && -n "$key" ]] || { rm -f "$CONFIG.new"; n_err "в шаблоне нет tls.cert или tls.key"; }

  if [[ ! -s "$cert" || ! -s "$key" ]]; then
    mkdir -p "$(dirname "$cert")" "$(dirname "$key")"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$key" -out "$cert" -subj "/CN=$cn" -days 3650 >/dev/null 2>&1 \
      || n_err "не удалось создать сертификат"
  fi
  chmod 600 "$key"
  chmod 644 "$cert"
  # Официальный установщик запускает сервис от пользователя hysteria
  if id hysteria >/dev/null 2>&1; then chown hysteria:hysteria "$cert" "$key"; fi

  if [[ -f "$CONFIG" ]]; then cp -p "$CONFIG" "$CONFIG.bak.$(date +%s)"; fi
  mv -f "$CONFIG.new" "$CONFIG"
  if id hysteria >/dev/null 2>&1; then chown root:hysteria "$CONFIG"; chmod 640 "$CONFIG"; fi

  # Буферы UDP, рекомендованные для Hysteria2
  printf 'net.core.rmem_max = 16777216\nnet.core.wmem_max = 16777216\n' > /etc/sysctl.d/99-hysteria.conf
  sysctl -q -p /etc/sysctl.d/99-hysteria.conf >/dev/null 2>&1 || true

  # Порты открываются, только если ufw уже включён
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$port"/udp >/dev/null
    for p in $(grep -oE '^[[:space:]]*listenHTTPS?:[[:space:]]*:?[0-9]+' "$CONFIG" | grep -oE '[0-9]+$' | sort -u || true); do
      ufw allow "$p"/tcp >/dev/null
    done
  fi

  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE" || n_err "сервис не перезапустился: journalctl -u $SERVICE -n 30"
  sleep 2
  if ! systemctl is-active --quiet "$SERVICE"; then
    n_err "сервис не работает: $(journalctl -u "$SERVICE" -n 3 --no-pager 2>/dev/null | tail -n 1)"
  fi
  ver="$(hysteria version 2>/dev/null | awk -F':[[:space:]]*' '/^Version/{print $2; exit}' || true)"
  echo "installed ${ver:-?}"
}


# AmneziaWG на узле. Работает с контейнером, который ставит приложение Amnezia VPN
# (amnezia-awg2 для AWG 2.0 или amnezia-awg), и ведёт clientsTable так же, как приложение,
# чтобы созданные здесь клиенты были видны и удалялись в Amnezia VPN.

# Находит контейнер AWG, имя в $AWG_C
n_awg_find() {
  local names c
  AWG_C=""
  command -v docker >/dev/null 2>&1 || return 1
  names="$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
  for c in amnezia-awg2 amnezia-awg; do
    if grep -qx "$c" <<<"$names"; then AWG_C="$c"; return 0; fi
  done
  return 1
}

n_awg_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$AWG_C" 2>/dev/null || true)" == "true" ]]
}

# Интерфейс и путь к конфигу внутри контейнера: $AWG_IF и $AWG_CONF
n_awg_iface() {
  local i
  for i in awg0 wg0; do
    if docker exec "$AWG_C" test -f "$AWG_DIR/$i.conf" 2>/dev/null; then
      AWG_IF="$i"
      AWG_CONF="$AWG_DIR/$i.conf"
      return 0
    fi
  done
  return 1
}

# Публичные ключи клиентов с именем $1 из clientsTable (JSON на stdin). Код 2, если JSON битый
n_awg_table_pubs() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    t = json.loads(raw) if raw else []
except ValueError:
    sys.exit(2)
for e in t:
    if e.get("userData", {}).get("clientName") == sys.argv[1]:
        print(e.get("clientId", ""))
' "$1"
}

# clientsTable (stdin) с добавленным клиентом: ключ $1, имя $2, дата $3
n_awg_table_add() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    t = json.loads(raw) if raw else []
except ValueError:
    sys.exit(2)
t.append({"clientId": sys.argv[1], "userData": {"clientName": sys.argv[2], "creationDate": sys.argv[3]}})
print(json.dumps(t, indent=4, ensure_ascii=False))
' "$1" "$2" "$3"
}

# clientsTable (stdin) без клиентов с именем $1 и без ключа $2 (если передан)
n_awg_table_del() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    t = json.loads(raw) if raw else []
except ValueError:
    sys.exit(2)
pub = sys.argv[2] if len(sys.argv) > 2 else ""
t = [e for e in t if e.get("userData", {}).get("clientName") != sys.argv[1] and not (pub and e.get("clientId") == pub)]
print(json.dumps(t, indent=4, ensure_ascii=False))
' "$1" "${2:-}"
}

# Публичный ключ по приватному $1, печатает "ключ контейнер"
n_awg_pubkey() {
  local pub
  n_defaults
  n_awg_find || n_err "не найден контейнер AmneziaWG"
  n_awg_running || n_err "контейнер $AWG_C не запущен"
  pub="$(printf '%s\n' "$1" | docker exec -i "$AWG_C" awg pubkey | tr -d '[:space:]')"
  [[ -n "$pub" ]] || n_err "не удалось вычислить публичный ключ"
  printf '%s %s\n' "$pub" "$AWG_C"
}

# Таблица клиентов сервера: адрес, имя, последнее подключение, ключ, проблемы.
# Проблемы: дубль адреса, пир есть в файле, но не в работающем awg, нет записи в clientsTable
n_awg_clients() {
  n_defaults
  command -v python3 >/dev/null 2>&1 || n_err "нужен python3"
  n_awg_find || n_err "не найден контейнер AmneziaWG"
  n_awg_running || n_err "контейнер $AWG_C не запущен"
  n_awg_iface || n_err "не найден конфиг в $AWG_DIR"
  IOF_CONF="$(docker exec "$AWG_C" cat "$AWG_CONF")" \
  IOF_TABLE="$(docker exec "$AWG_C" cat "$AWG_DIR/clientsTable" 2>/dev/null || true)" \
  IOF_HS="$(docker exec "$AWG_C" awg show "$AWG_IF" latest-handshakes 2>/dev/null || true)" \
  IOF_LIVE="$(docker exec "$AWG_C" awg show "$AWG_IF" allowed-ips 2>/dev/null || true)" \
  python3 -c '
import json, os, time
peers, cur = [], None
for line in os.environ.get("IOF_CONF", "").splitlines():
    s = line.strip()
    if s.startswith("["):
        cur = {} if s == "[Peer]" else None
        if cur is not None:
            peers.append(cur)
        continue
    if cur is None or s.startswith("#") or "=" not in s:
        continue
    k, v = s.split("=", 1)
    cur[k.strip()] = v.strip()
try:
    table = json.loads(os.environ.get("IOF_TABLE", "").strip() or "[]")
except ValueError:
    table = []
names = {e.get("clientId"): e.get("userData", {}).get("clientName", "") for e in table}
hs = {}
for l in os.environ.get("IOF_HS", "").splitlines():
    p = l.split()
    if len(p) == 2 and p[1].isdigit():
        hs[p[0]] = int(p[1])
live = {}
for l in os.environ.get("IOF_LIVE", "").splitlines():
    p = l.split()
    if p:
        live[p[0]] = [x for x in p[1:] if x != "(none)"]
count = {}
for p in peers:
    ip = p.get("AllowedIPs", "").split(",")[0].strip()
    count[ip] = count.get(ip, 0) + 1
now = time.time()
for p in peers:
    pub = p.get("PublicKey", "")
    ip = p.get("AllowedIPs", "").split(",")[0].strip()
    t = hs.get(pub, 0)
    if t == 0:
        ago = "никогда"
    elif now - t < 3600:
        ago = f"{int((now - t) // 60)} мин назад"
    elif now - t < 86400:
        ago = f"{int((now - t) // 3600)} ч назад"
    else:
        ago = f"{int((now - t) // 86400)} дн назад"
    flags = []
    if count.get(ip, 0) > 1:
        flags.append("ДУБЛЬ АДРЕСА")
    if pub not in live:
        flags.append("нет в работающем awg")
    elif ip not in live[pub]:
        flags.append("адрес отдан другому")
    if pub not in names:
        flags.append("нет в clientsTable")
    print("\t".join([ip.split("/")[0], names.get(pub, "-") or "-", ago, pub[:12] + "...", ", ".join(flags) or "ok"]))
'
}

# Бэкап конфига ($1) и clientsTable ($2) перед изменением, на хосте в $AWG_BACKUP
n_awg_backup() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$AWG_BACKUP"
  chmod 700 "$AWG_BACKUP"
  printf '%s\n' "$1" > "$AWG_BACKUP/$AWG_IF.conf.$ts"
  printf '%s\n' "$2" > "$AWG_BACKUP/clientsTable.$ts"
  chmod 600 "$AWG_BACKUP/$AWG_IF.conf.$ts" "$AWG_BACKUP/clientsTable.$ts"
}

# Создаёт клиента $1 на сервере, адрес в конфиге клиента $2.
# Вывод: первая строка "IOF <публичный ключ> <контейнер>", дальше конфиг клиента.
# Адрес выбирается как у приложения Amnezia (следующий за последним), но с учётом адресов
# работающего интерфейса, чтобы не выдать занятый.
n_awg_add() {
  local label="$1" host="$2"
  local conf table pubs priv pub psk srvpub port prefix n newtable created last lead live
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  command -v python3 >/dev/null 2>&1 || n_err "нужен python3"
  n_awg_find || n_err "не найден контейнер AmneziaWG"
  n_awg_running || n_err "контейнер $AWG_C не запущен"
  n_awg_iface || n_err "не найден конфиг в $AWG_DIR"

  conf="$(docker exec "$AWG_C" cat "$AWG_CONF")"
  table="$(docker exec "$AWG_C" cat "$AWG_DIR/clientsTable" 2>/dev/null || true)"

  pubs="$(n_awg_table_pubs "$label" <<<"$table")" || n_err "clientsTable не читается, ничего не менял"
  if [[ -n "$pubs" ]]; then
    n_err "клиент '$label' уже есть на этом сервере, а его конфига нет на главном. Удали его (iof awg del) или выбери другое имя"
  fi

  port="$(awk -F'=' '/^[[:space:]]*ListenPort[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' <<<"$conf")"
  prefix="$(awk -F'=' '/^[[:space:]]*Address[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' <<<"$conf")"
  prefix="${prefix%%/*}"
  prefix="${prefix%.*}"
  [[ -n "$port" && -n "$prefix" ]] || n_err "не удалось прочитать ListenPort или Address"

  live="$(docker exec "$AWG_C" awg show "$AWG_IF" allowed-ips 2>/dev/null \
    | awk '{ for (i = 2; i <= NF; i++) if ($i != "(none)") print "AllowedIPs = " $i }' || true)"

  n="$(awk -v p="$prefix." '
    /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
      s = $0
      sub(/^[^=]*=/, "", s)
      m = split(s, a, ",")
      for (i = 1; i <= m; i++) {
        ip = a[i]
        gsub(/[[:space:]]/, "", ip)
        sub(/\/.*/, "", ip)
        if (index(ip, p) == 1) {
          x = substr(ip, length(p) + 1) + 0
          used[x] = 1
          if (x > max) max = x
        }
      }
    }
    END {
      n = max + 1
      if (n > 254) {
        n = 0
        for (i = 2; i <= 254; i++) if (!(i in used)) { n = i; break }
      }
      print n
    }' <<<"$conf"$'\n'"$live")"
  (( n > 0 )) || n_err "в подсети $prefix.0/24 нет свободных адресов"

  priv="$(docker exec "$AWG_C" awg genkey | tr -d '[:space:]')"
  pub="$(printf '%s\n' "$priv" | docker exec -i "$AWG_C" awg pubkey | tr -d '[:space:]')"
  psk="$(docker exec "$AWG_C" cat "$AWG_DIR/wireguard_psk.key" | tr -d '[:space:]')"
  srvpub="$(docker exec "$AWG_C" cat "$AWG_DIR/wireguard_server_public_key.key" | tr -d '[:space:]')"
  [[ -n "$priv" && -n "$pub" && -n "$psk" && -n "$srvpub" ]] || n_err "не удалось получить ключи"

  created="$(LC_ALL=C date '+%a %b %-d %H:%M:%S %Y')"
  newtable="$(n_awg_table_add "$pub" "$label" "$created" <<<"$table")" || n_err "clientsTable не читается, ничего не менял"

  n_awg_backup "$conf" "$table"

  # Пир дописывается в файл и сразу применяется к работающему интерфейсу без перезапуска
  last="$(docker exec "$AWG_C" tail -n 1 "$AWG_CONF")"
  lead=""
  if [[ -n "${last//[[:space:]]/}" ]]; then lead=$'\n'; fi
  printf '%s[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n\n' "$lead" "$pub" "$psk" "$prefix.$n" \
    | docker exec -i "$AWG_C" sh -c "cat >> '$AWG_CONF'"
  docker exec "$AWG_C" awg set "$AWG_IF" peer "$pub" preshared-key "$AWG_DIR/wireguard_psk.key" allowed-ips "$prefix.$n/32"
  printf '%s\n' "$newtable" | docker exec -i "$AWG_C" sh -c "cat > '$AWG_DIR/clientsTable'"
  echo "[$(hostname)] добавлен клиент AWG '$label' ($prefix.$n)" >&2

  # Параметры обфускации берутся из [Interface] сервера, I1-I5 там закомментированы
  printf 'IOF %s %s\n' "$pub" "$AWG_C"
  printf '[Interface]\nAddress = %s/32\nDNS = %s\nPrivateKey = %s\n' "$prefix.$n" "$AWG_DNS" "$priv"
  awk '
    /^\[/ { inif = ($0 ~ /^\[Interface\]/); next }
    !inif { next }
    /^[[:space:]]*(Jc|Jmin|Jmax|S[1-4]|H[1-4])[[:space:]]*=/ {
      k = $0; sub(/[[:space:]]*=.*/, "", k); gsub(/[[:space:]]/, "", k)
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      print k " = " v
      next
    }
    /^[[:space:]]*#?[[:space:]]*I[1-5][[:space:]]*=/ {
      l = $0; sub(/^[[:space:]]*#?[[:space:]]*/, "", l)
      k = l; sub(/[[:space:]]*=.*/, "", k)
      v = l; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      if (v == "") print k " ="; else print k " = " v
    }
  ' <<<"$conf"
  printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = %s:%s\nPersistentKeepalive = 25\n' \
    "$srvpub" "$psk" "$host" "$port"
}

# Удаляет клиента $1. Ключ $2 (с управляющего сервера) позволяет найти клиента,
# даже если приложение Amnezia перезаписало clientsTable без него.
n_awg_del() {
  local label="$1" known="${2:-}" conf table pubs newtable newconf p
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  n_awg_find || n_err "не найден контейнер AmneziaWG"
  n_awg_running || n_err "контейнер $AWG_C не запущен"
  n_awg_iface || n_err "не найден конфиг в $AWG_DIR"

  conf="$(docker exec "$AWG_C" cat "$AWG_CONF")"
  table="$(docker exec "$AWG_C" cat "$AWG_DIR/clientsTable" 2>/dev/null || true)"
  pubs="$(n_awg_table_pubs "$label" <<<"$table")" || n_err "clientsTable не читается, ничего не менял"
  if [[ -n "$known" ]] && grep -qF "$known" <<<"$conf" && ! grep -qxF "$known" <<<"$pubs"; then
    pubs="${pubs:+$pubs$'\n'}$known"
  fi
  if [[ -z "$pubs" ]]; then
    echo "[$(hostname)] клиента AWG '$label' нет" >&2
    return 0
  fi
  newtable="$(n_awg_table_del "$label" "$known" <<<"$table")" || n_err "clientsTable не читается, ничего не менял"
  newconf="$(awk -v keys="$(tr '\n' ' ' <<<"$pubs")" '
    BEGIN { m = split(keys, a, " "); for (i = 1; i <= m; i++) del[a[i]] = 1 }
    function flush() { if (buf != "" && !skip) printf "%s", buf; buf = ""; skip = 0 }
    /^\[/ { flush(); inpeer = ($0 ~ /^\[Peer\]/) }
    {
      buf = buf $0 "\n"
      if (inpeer && $0 ~ /^[[:space:]]*PublicKey[[:space:]]*=/) {
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
        if (v in del) skip = 1
      }
    }
    END { flush() }
  ' <<<"$conf")"

  n_awg_backup "$conf" "$table"
  printf '%s\n' "$newconf" | docker exec -i "$AWG_C" sh -c "cat > '$AWG_CONF'"
  for p in $pubs; do
    docker exec "$AWG_C" awg set "$AWG_IF" peer "$p" remove || true
  done
  printf '%s\n' "$newtable" | docker exec -i "$AWG_C" sh -c "cat > '$AWG_DIR/clientsTable'"
  echo "[$(hostname)] удалён клиент AWG '$label'" >&2
}


# Состояние узла для iof status, iof check, iof hy2 status, iof awg status, iof relay add.
# Печатает строки "ключ=значение":
#  hy2_installed yes/no, hy2_state (вывод systemctl is-active), hy2_udp yes/no, hy2_port,
#  hy2_auth password/userpass, hy2_users, hy2_ver,
#  awg_state running/stopped/none, awg_port, awg_peers, awg_online (рукопожатие за 3 минуты),
#  cpus, load1, mem_used_mb, mem_total_mb, disk_used_kb, disk_total_kb, uptime_s
n_status() {
  local installed="no" state="" udp="no" port="" auth="" users=0 ver=""
  local awg_state="none" awg_port="" awg_peers="" awg_online="" aconf
  n_defaults

  if command -v hysteria >/dev/null 2>&1 || [[ -f "$CONFIG" ]]; then installed="yes"; fi
  if [[ -f "$CONFIG" ]]; then
    port="$(n_hy2_port)"
    auth="$(n_yaml_value auth type || true)"
    users="$(n_hy2_userpass | wc -l)"
  fi
  state="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  if [[ -n "$port" && -n "$(ss -Huln "sport = :$port" 2>/dev/null)" ]]; then udp="yes"; fi
  ver="$(hysteria version 2>/dev/null | awk -F':[[:space:]]*' '/^Version/{print $2; exit}' || true)"

  if n_awg_find; then
    if n_awg_running && n_awg_iface; then
      awg_state="running"
      aconf="$(docker exec "$AWG_C" cat "$AWG_CONF" 2>/dev/null || true)"
      awg_port="$(awk -F'=' '/^[[:space:]]*ListenPort[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' <<<"$aconf")"
      awg_peers="$(grep -c '^\[Peer\]' <<<"$aconf" || true)"
      awg_online="$(docker exec "$AWG_C" awg show "$AWG_IF" latest-handshakes 2>/dev/null \
        | awk -v now="$(date +%s)" '$2 > now - 180 { c++ } END { print c + 0 }' || true)"
    else
      awg_state="stopped"
    fi
  fi

  printf '%s\n' \
    "hy2_installed=$installed" \
    "hy2_state=${state:-unknown}" \
    "hy2_udp=$udp" \
    "hy2_port=$port" \
    "hy2_auth=$auth" \
    "hy2_users=$users" \
    "hy2_ver=$ver" \
    "awg_state=$awg_state" \
    "awg_port=$awg_port" \
    "awg_peers=$awg_peers" \
    "awg_online=$awg_online" \
    "cpus=$(nproc 2>/dev/null || echo 1)" \
    "load1=$(cut -d' ' -f1 /proc/loadavg)" \
    "$(free -m | awk '/^Mem:/{printf "mem_used_mb=%d\nmem_total_mb=%d", $3, $2}')" \
    "$(df -Pk / | awk 'NR==2{printf "disk_used_kb=%d\ndisk_total_kb=%d", $3, $2}')" \
    "uptime_s=$(cut -d. -f1 /proc/uptime)"
}

# Ретранслятор на узле: принимает UDP на своих портах и пересылает на другой узел
# (DNAT + MASQUERADE). Пакеты не расшифровываются, работает ядро, без отдельного процесса.
# Правила хранятся в /etc/iof/relay.rules, применяются сервисом iof-relay при загрузке.

# $1 свободных портов из диапазона 20000-60000, по одному в строке
n_free_ports() {
  local need="$1" got=() p tries=0
  while (( ${#got[@]} < need && tries < 200 )); do
    tries=$((tries + 1))
    p="$(shuf -i 20000-60000 -n 1)"
    if [[ -n "$(ss -Htuln "sport = :$p" 2>/dev/null)" ]]; then continue; fi
    if [[ -f /etc/iof/relay.rules ]] && awk -v p="$p" '$2 == p { f = 1 } END { exit !f }' /etc/iof/relay.rules; then continue; fi
    if [[ " ${got[*]} " == *" $p "* ]]; then continue; fi
    got+=("$p")
  done
  (( ${#got[@]} == need )) || n_err "не удалось подобрать свободные порты"
  printf '%s\n' "${got[@]}"
}

# Записывает правила (аргументы вида "udp <порт здесь> <ip узла> <порт узла>") и применяет их.
# Без аргументов полностью убирает ретранслятор с узла.
n_relay_apply() {
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  command -v iptables >/dev/null 2>&1 || n_err "нет iptables"

  if (( $# == 0 )); then
    systemctl disable --now iof-relay.service >/dev/null 2>&1 || true
    if [[ -x /usr/local/sbin/iof-relay ]]; then /usr/local/sbin/iof-relay stop || true; fi
    rm -f /etc/systemd/system/iof-relay.service /usr/local/sbin/iof-relay /etc/iof/relay.rules /etc/sysctl.d/99-iof-relay.conf
    systemctl daemon-reload
    echo "[$(hostname)] ретранслятор выключен" >&2
    return 0
  fi

  mkdir -p /etc/iof
  printf '%s\n' "$@" > /etc/iof/relay.rules
  chmod 600 /etc/iof/relay.rules

  # Скрипт сервиса. Правила в своих цепочках IOF-*, переходы ставятся первыми в PREROUTING,
  # POSTROUTING и FORWARD, а при наличии Docker ещё и в DOCKER-USER, чтобы не мешали
  # политика DROP от Docker и ufw. ctstate DNAT пропускает только перенаправленный трафик.
  cat > /usr/local/sbin/iof-relay <<'EOS'
#!/bin/bash
set -u
RULES=/etc/iof/relay.rules
ipt() { iptables -w "$@"; }
unhook() { while ipt -t "$1" -D "$2" -j "$3" 2>/dev/null; do :; done; }
has_docker_user() { ipt -t filter -n -L DOCKER-USER >/dev/null 2>&1; }

stop() {
  unhook nat PREROUTING IOF-PRE
  unhook nat POSTROUTING IOF-POST
  unhook filter FORWARD IOF-FWD
  if has_docker_user; then unhook filter DOCKER-USER IOF-FWD; fi
  ipt -t nat -F IOF-PRE 2>/dev/null; ipt -t nat -X IOF-PRE 2>/dev/null
  ipt -t nat -F IOF-POST 2>/dev/null; ipt -t nat -X IOF-POST 2>/dev/null
  ipt -t filter -F IOF-FWD 2>/dev/null; ipt -t filter -X IOF-FWD 2>/dev/null
  return 0
}

start() {
  stop
  [[ -s "$RULES" ]] || return 0
  sysctl -qw net.ipv4.ip_forward=1
  ipt -t nat -N IOF-PRE
  ipt -t nat -N IOF-POST
  ipt -t filter -N IOF-FWD
  while read -r proto lport dst dport _; do
    [[ -n "${proto:-}" && "$proto" != \#* ]] || continue
    ipt -t nat -A IOF-PRE -p "$proto" --dport "$lport" -m addrtype --dst-type LOCAL -j DNAT --to-destination "$dst:$dport"
    ipt -t nat -A IOF-POST -p "$proto" -d "$dst" --dport "$dport" -m conntrack --ctstate DNAT -j MASQUERADE
    ipt -t filter -A IOF-FWD -p "$proto" -d "$dst" --dport "$dport" -m conntrack --ctstate DNAT -j ACCEPT
    ipt -t filter -A IOF-FWD -p "$proto" -s "$dst" --sport "$dport" -m conntrack --ctstate DNAT -j ACCEPT
  done < "$RULES"
  ipt -t nat -I PREROUTING 1 -j IOF-PRE
  ipt -t nat -I POSTROUTING 1 -j IOF-POST
  ipt -t filter -I FORWARD 1 -j IOF-FWD
  if has_docker_user; then ipt -t filter -I DOCKER-USER 1 -j IOF-FWD; fi
}

case "${1:-start}" in
  start) start ;;
  stop)  stop ;;
  *)     echo "usage: iof-relay start|stop" >&2; exit 2 ;;
esac
EOS
  chmod 755 /usr/local/sbin/iof-relay

  cat > /etc/systemd/system/iof-relay.service <<'EOS'
[Unit]
Description=iof relay (UDP forwarding to other nodes)
After=network-online.target docker.service ufw.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/iof-relay start
ExecStop=/usr/local/sbin/iof-relay stop

[Install]
WantedBy=multi-user.target
EOS
  printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/99-iof-relay.conf

  systemctl daemon-reload
  systemctl enable iof-relay.service >/dev/null 2>&1
  systemctl restart iof-relay.service || n_err "ретранслятор не запустился: journalctl -u iof-relay -n 30"
  echo "[$(hostname)] ретранслятор: правил $(iptables -w -t nat -S IOF-PRE 2>/dev/null | grep -c DNAT || true)" >&2
}

# Печатает "<состояние сервиса> <число правил DNAT>"
n_relay_status() {
  local active rules
  active="$(systemctl is-active iof-relay.service 2>/dev/null || true)"
  rules="$(iptables -w -t nat -S IOF-PRE 2>/dev/null | grep -c DNAT || true)"
  printf '%s %s\n' "${active:-inactive}" "${rules:-0}"
}


# Аудит безопасности (iof audit). Узел только собирает факты и печатает их строками "ключ=значение",
# оценку (хорошо, внимание, проблема) ставит управляющий сервер: audit_eval_server. Ничего на узле
# не меняется. Набор проверок по мотивам https://github.com/nuver-labs/vps-audit (MIT)

# Слушающие сокеты из ss, по строке "listen=tcp|22|any|sshd": протокол, порт, any или loopback, процесс.
# IPv4 и IPv6 одного порта дают одну строку
n_audit_listen() {
  ss -Htulnp 2>/dev/null | awk '
    {
      proc = ""
      if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
      port = $5; sub(/^.*:/, "", port)
      addr = $5; sub(/:[^:]*$/, "", addr); sub(/%.*$/, "", addr); gsub(/[][]/, "", addr)
      bind = (addr ~ /^127\./ || addr == "::1") ? "loopback" : "any"
      print "listen=" $1 "|" port "|" bind "|" proc
    }' | sort -u
}

# То, что на узле слушает ожидаемо: порты контейнеров Amnezia (expect=udp|порт|контейнер) и правила
# ретранслятора (relay=udp|порт|куда): у него сокета нет, работает DNAT
n_audit_expect() {
  local c
  if command -v docker >/dev/null 2>&1; then
    for c in $(timeout 10 docker ps --format '{{.Names}}' 2>/dev/null | grep '^amnezia-' || true); do
      timeout 10 docker port "$c" 2>/dev/null \
        | awk -v c="$c" '{ split($1, a, "/"); p = $NF; sub(/^.*:/, "", p); print "expect=" a[2] "|" p "|" c }' | sort -u || true
    done
  fi
  if [[ -f /etc/iof/relay.rules ]]; then
    awk '$1 !~ /^#/ && NF >= 4 { print "relay=" $1 "|" $2 "|" $3 ":" $4 }' /etc/iof/relay.rules
  fi
}

# Факты для блока «Аудит сервера»: n_audit_server <пользователь, под которым iof заходит на узел>.
#  now, ssh_conf yes/no, ssh_ports (через запятую), ssh_permitrootlogin, ssh_passwordauthentication,
#  ssh_kbdinteractiveauthentication, ssh_pubkeyauthentication, ssh_keys (ключей в authorized_keys),
#  ssh_keys_mode, fw none/ufw/iptables/nftables, fw_policy deny/allow, fw_rules,
#  f2b и crowdsec (systemctl is-active), f2b_jails, f2b_port, auth_fail (за 24 часа),
#  upd_total, upd_security, apt_updated, reboot yes/no, reboot_pkgs, nightly_at, nightly_err,
#  sudo_log syslog/file/off/nosudo, authlog yes/no, pwq_pam yes/no, pwq_minlen,
#  suid_total, suid_done yes/no,
#  и повторяющиеся: listen (см. n_audit_listen), expect и relay (см. n_audit_expect),
#  suid=путь (вне стандартного набора Ubuntu 24.04).
# Долгие команды ограничены timeout, вместе укладываются в две минуты
n_audit_server() {
  local user="${1:-root}" home sshd s v rc=0 fw="none" policy="allow" rules=0 f2b cs sl="nosudo"
  # SUID-файлы свежей Ubuntu 24.04 и её обычных пакетов (sudo, openssh, polkit, snapd, uidmap, at)
  local std='/usr/bin/(chfn|chsh|gpasswd|newgrp|passwd|su|sudo|mount|umount|fusermount3?|pkexec|at|newuidmap|newgidmap|ntfs-3g)'
  std+='|/usr/lib/openssh/ssh-keysign|/usr/lib/dbus-1\.0/dbus-daemon-launch-helper'
  std+='|/usr/lib/polkit-1/polkit-agent-helper-1|/usr/libexec/polkit-agent-helper-1|/usr/lib/snapd/snap-confine'
  std+='|/usr/sbin/(pppd|mount\.nfs)'
  echo "now=$(date +%s)"

  # SSH: действующие настройки (sshd -T), а не текст конфига, в котором ещё Include и Match
  sshd="$(command -v sshd || echo /usr/sbin/sshd)"
  s="$("$sshd" -T 2>/dev/null || true)"
  if [[ -n "$s" ]]; then
    echo "ssh_conf=yes"
    echo "ssh_ports=$(awk '$1 == "port" { printf "%s%s", sep, $2; sep = "," }' <<<"$s")"
    for v in permitrootlogin passwordauthentication kbdinteractiveauthentication pubkeyauthentication; do
      echo "ssh_$v=$(awk -v k="$v" '$1 == k { print $2; exit }' <<<"$s")"
    done
  else
    echo "ssh_conf=no"
  fi
  home="$(getent passwd "$user" | cut -d: -f6 || true)"
  if [[ -n "$home" && -f "$home/.ssh/authorized_keys" ]]; then
    echo "ssh_keys=$(grep -cE '(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+) AAAA' "$home/.ssh/authorized_keys" || true)"
    echo "ssh_keys_mode=$(stat -c %a "$home/.ssh/authorized_keys")"
  else
    echo "ssh_keys=0"
  fi

  # Файрвол: ufw, иначе iptables (политика DROP или запрет последним правилом), иначе nftables.
  # Переходы в цепочки ретранслятора iof, Docker, ufw и fail2ban своими правилами не считаются
  if command -v ufw >/dev/null 2>&1; then
    s="$(timeout 10 ufw status verbose 2>/dev/null || true)"
    if grep -q '^Status: active' <<<"$s"; then
      fw="ufw"
      policy="$(sed -n 's/^Default: \([a-z]*\) (incoming).*/\1/p' <<<"$s")"
      if [[ "$policy" != "allow" ]]; then policy="deny"; fi
    fi
  fi
  if [[ "$fw" == "none" ]] && command -v iptables >/dev/null 2>&1; then
    s="$(timeout 10 iptables -w 5 -S INPUT 2>/dev/null || true)"
    rules="$(grep '^-A INPUT' <<<"$s" | grep -cvE -- '-j (IOF-|DOCKER|ufw-|f2b-)' || true)"
    if grep -q '^-P INPUT DROP' <<<"$s" || tail -n 1 <<<"$s" | grep -qE '^-A INPUT -j (DROP|REJECT)'; then
      fw="iptables"
      policy="deny"
    fi
  fi
  if [[ "$fw" == "none" ]] && command -v nft >/dev/null 2>&1; then
    if timeout 10 nft list ruleset 2>/dev/null | grep -qE 'hook input .*policy drop'; then
      fw="nftables"
      policy="deny"
    fi
  fi
  if [[ "$fw" == "none" ]] && (( rules > 0 )); then fw="iptables"; fi
  printf '%s\n' "fw=$fw" "fw_policy=$policy" "fw_rules=$rules"

  # Защита от подбора паролей. Порт jail sshd берётся из разобранного конфига fail2ban
  f2b="$(systemctl is-active fail2ban 2>/dev/null || true)"
  cs="$(systemctl is-active crowdsec 2>/dev/null || true)"
  printf '%s\n' "f2b=${f2b:-inactive}" "crowdsec=${cs:-inactive}"
  if [[ "$f2b" == "active" ]]; then
    echo "f2b_jails=$(timeout 10 fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ' \t' || true)"
    echo "f2b_port=$(timeout 10 fail2ban-client -d 2>/dev/null | grep -F "'sshd'" | grep -oE "'port', '[^']*'" | head -n 1 | sed -E "s/^'port', '//; s/'\$//" || true)"
  fi
  if command -v journalctl >/dev/null 2>&1; then
    echo "auth_fail=$(timeout 20 journalctl -q --no-pager -o cat -u ssh -u sshd --since '24 hours ago' 2>/dev/null \
      | grep -cE 'Failed password for|(Connection closed by|Disconnected from) (invalid|authenticating) user' || true)"
  fi

  # Обновления: то, что поставил бы apt-get upgrade, как в iof-nightly. Когда обновлялись списки пакетов
  if command -v apt-get >/dev/null 2>&1; then
    s="$(timeout 60 apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep '^Inst ' || true)"
    echo "upd_total=$(grep -c . <<<"$s" || true)"
    echo "upd_security=$(grep -ci 'security' <<<"$s" || true)"
    for v in /var/lib/apt/periodic/update-success-stamp /var/lib/apt/lists; do
      if [[ -e "$v" ]]; then echo "apt_updated=$(stat -c %Y "$v")"; break; fi
    done
  fi
  if [[ -f /var/run/reboot-required ]]; then
    echo "reboot=yes"
    echo "reboot_pkgs=$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | head -n 3 | tr '\n' ' ' || true)"
  else
    echo "reboot=no"
  fi
  # Ночное обслуживание iof-nightly: когда началось последнее обновление и были ли в нём ошибки apt
  if [[ -f /var/log/iof-nightly.log ]]; then
    s="$(grep -E '^== [0-9-]+ [0-9:]+ обновление' /var/log/iof-nightly.log | tail -n 1 | cut -c4-22 || true)"
    if [[ -n "$s" ]]; then echo "nightly_at=$(date -d "$s" +%s 2>/dev/null || true)"; fi
    echo "nightly_err=$(awk '/^== .* обновление/ { n = 0 } /^E: / { n++ } END { print n + 0 }' /var/log/iof-nightly.log)"
  fi

  # Слушающие порты и то, что на узле ожидаемо
  n_audit_listen
  n_audit_expect

  # sudo пишет в syslog (на Ubuntu это журнал systemd), если это не выключено в sudoers
  if command -v sudo >/dev/null 2>&1; then
    sl="syslog"
    s="$(cat /etc/sudoers /etc/sudoers.d/* 2>/dev/null | grep -E '^[[:space:]]*Defaults' || true)"
    if grep -qE '(^|[[:space:],])!syslog' <<<"$s"; then sl="off"; fi
    if grep -qE 'logfile[[:space:]]*=' <<<"$s"; then sl="file"; fi
  fi
  echo "sudo_log=$sl"
  if [[ -s /var/log/auth.log ]]; then echo "authlog=yes"; else echo "authlog=no"; fi

  if grep -qsE '^[^#]*pam_pwquality' /etc/pam.d/common-password; then echo "pwq_pam=yes"; else echo "pwq_pam=no"; fi
  echo "pwq_minlen=$(cat /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null \
    | sed -n 's/^[[:space:]]*minlen[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' | tail -n 1 || true)"

  # SUID-файлы на корневом разделе, без слоёв контейнеров и snap. Код 124 — find не уложился в срок
  s="$(timeout 45 find / -xdev \( -path /proc -o -path /sys -o -path /var/lib/docker -o -path /var/lib/containerd \
    -o -path /snap -o -path /var/lib/snapd \) -prune -o -type f -perm -4000 -print 2>/dev/null)" || rc=$?
  echo "suid_total=$(grep -c . <<<"$s" || true)"
  if (( rc == 124 )); then echo "suid_done=no"; else echo "suid_done=yes"; fi
  grep -vxE "$std" <<<"$s" | grep . | head -n 20 | sed 's/^/suid=/' || true
}

# Блоки верхнего уровня конфига Hysteria2 $1 строками "hy2_block=имя|хэш". Хэш короткий, с солью
# запуска $2: по нему видно только, совпадает ли блок с таким же блоком шаблона (управляющий сервер
# считает его этой же функцией). Комментарии и пустые строки не учитываются, пользователи
# auth.userpass тоже: на каждом узле они свои
n_audit_hy2_blocks() {
  local file="$1" salt="${2:-}" text name
  text="$(awk '
    function ind(s) { match(s, /^[ \t]*/); return RLENGTH }
    { sub(/\r$/, "") }
    /^[ \t]*(#.*)?$/ { next }
    { sub(/[ \t]+#.*$/, ""); sub(/[ \t]+$/, "") }
    /^[^ \t]/ { name = $0; sub(/:.*$/, "", name); skip = -1 }
    skip >= 0 { if (ind($0) > skip) next; skip = -1 }
    name == "auth" && /^[ \t]+userpass:$/ { skip = ind($0) }
    name ~ /^[A-Za-z][A-Za-z0-9_]*$/ { print name "\t" $0 }
  ' "$file")"
  for name in $(cut -f1 <<<"$text" | sort -u); do
    printf 'hy2_block=%s|%s\n' "$name" \
      "$({ printf '%s\n' "$salt"; awk -F'\t' -v n="$name" '$1 == n' <<<"$text"; } | sha256sum | cut -c1-12)"
  done
}

# Параметры обфускации AmneziaWG из секции [Interface] конфига на stdin, соль запуска в $1:
#  awg_p=поле|значение для Jc, Jmin, Jmax, S1–S4, H1–H4 (у H значение — диапазон начало-конец),
#  awg_i=номер|set или empty для I1–I5: в конфиге они закомментированы, читаются и такие строки,
#  awg_hash — короткий хэш всех параметров вместе с I1–I5 и солью: у узлов с одинаковыми
#  параметрами он одинаковый. Сами I1–I5 узел не отдаёт
n_audit_awg_params() {
  local salt="${1:-}" p
  p="$(awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*\[/ { inif = ($0 ~ /^[[:space:]]*\[Interface\]/); next }
    !inif { next }
    /^[[:space:]]*(Jc|Jmin|Jmax|S[1-4]|H[1-4])[[:space:]]*=/ || /^[[:space:]]*#?[[:space:]]*I[1-5][[:space:]]*=/ {
      l = $0; sub(/^[[:space:]]*#?[[:space:]]*/, "", l)
      k = l; sub(/[[:space:]]*=.*/, "", k)
      v = l; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      print k "|" v
    }' | sort -u)"
  if [[ -z "$p" ]]; then return 0; fi
  grep -E '^(Jc|Jmin|Jmax|S[1-4]|H[1-4])\|' <<<"$p" | tr -d ' \t' | sed 's/^/awg_p=/' || true
  awk -F'|' '
    /^I[1-5]\|/ { n = substr($1, 2); v = $0; sub(/^[^|]*\|/, "", v); seen[n] = 1; if (v != "") set[n] = 1 }
    END { for (n = 1; n <= 5; n++) if (n in seen) print "awg_i=" n "|" ((n in set) ? "set" : "empty") }' <<<"$p"
  echo "awg_hash=$(printf '%s\n%s\n' "$salt" "$p" | sha256sum | cut -c1-12)"
}

# Факты для блока «Защита от РКН»: n_audit_dpi <соль запуска>. Секретов в выводе нет: пароль
# Salamander попадает только в хэш блока obfs, пакеты I1–I5 AmneziaWG — только в awg_hash.
#  now, hostname,
#  hy2 yes/no, hy2_state, hy2_port, hy2_range (диапазон портов в listen), hy2_obfs none/salamander,
#  hy2_obfs_pass set/empty, hy2_masq none/proxy/file/string, hy2_masq_url, hy2_masq_code (ответ цели
#  proxy с узла), hy2_masq_dir yes/no, hy2_http и hy2_https (порты listenHTTP и listenHTTPS),
#  hy2_acme yes/no, hy2_cert_cn, hy2_cert_self yes/no, hy2_log (уровень журнала), hy2_hop (диапазоны
#  портов, перенаправленные на порт Hysteria2, через запятую),
#  awg none/stopped/noconf/running, awg_c, awg_if, awg_hash, awg_log_driver, awg_log_max, awg_log_size,
#  web none/loopback/any/unknown, web_addr (на чём слушает iof-web),
#  block_set yes/no, block_entries, block_chain yes/no, block_hook yes/no, block_at (блок-лист
#  сканеров: ipset iof-block, цепочка IOF-BLOCK, время /etc/iof/block.list),
#  jd_retention, jd_maxuse, jd_usage, jd_oldest, time_sync yes/no, time_ntp, now_end,
#  и повторяющиеся: hy2_block (см. n_audit_hy2_blocks), awg_p и awg_i (см. n_audit_awg_params),
#  listen (см. n_audit_listen), expect и relay (см. n_audit_expect)
n_audit_dpi() {
  local salt="${1:-}" s v port cert pid
  n_defaults
  echo "now=$(date +%s)"
  echo "hostname=$(timeout 5 hostname -f 2>/dev/null || hostname)"

  if [[ -f "$CONFIG" ]]; then
    echo "hy2=yes"
    echo "hy2_state=$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    port="$(n_hy2_port)"
    echo "hy2_port=$port"
    # Hysteria2 слушает первый порт диапазона, остальные перенаправляет на него сама
    s="$(sed -n 's/^listen:[[:space:]]*//p' "$CONFIG" | sed -E "s/[[:space:]]+#.*\$//; s/[\"']//g" | head -n 1 || true)"
    if [[ "$s" =~ :([0-9]+-[0-9]+)$ ]]; then echo "hy2_range=${BASH_REMATCH[1]}"; fi
    v="$(n_yaml_value obfs type || true)"
    echo "hy2_obfs=${v:-none}"
    if [[ -n "$(n_yaml_value salamander password || true)" ]]; then echo "hy2_obfs_pass=set"; else echo "hy2_obfs_pass=empty"; fi

    # Masquerade: что сервер показывает тому, кто пришёл без пароля. Цель proxy проверяется отсюда
    v="$(n_yaml_value masquerade type || true)"
    echo "hy2_masq=${v:-none}"
    case "$v" in
      proxy)
        s="$(n_yaml_value masquerade url || true)"
        echo "hy2_masq_url=$s"
        if [[ -n "$s" ]] && command -v curl >/dev/null 2>&1; then
          echo "hy2_masq_code=$(timeout 12 curl -s -o /dev/null -m 8 -w '%{http_code}' -- "$s" 2>/dev/null || true)"
        fi ;;
      file)
        s="$(n_yaml_value masquerade dir || true)"
        if [[ -n "$s" && -d "$s" ]]; then echo "hy2_masq_dir=yes"; else echo "hy2_masq_dir=no"; fi ;;
    esac
    echo "hy2_http=$(n_yaml_value masquerade listenHTTP | grep -oE '[0-9]+$' || true)"
    echo "hy2_https=$(n_yaml_value masquerade listenHTTPS | grep -oE '[0-9]+$' || true)"
    if grep -qE '^acme:' "$CONFIG"; then echo "hy2_acme=yes"; else echo "hy2_acme=no"; fi

    cert="$(n_yaml_value tls cert || true)"
    if [[ -n "$cert" && -f "$cert" ]] && command -v openssl >/dev/null 2>&1; then
      s="$(openssl x509 -noout -subject -issuer -nameopt RFC2253 -in "$cert" 2>/dev/null || true)"
      echo "hy2_cert_cn=$(sed -n 's/^subject=.*CN=\([^,]*\).*/\1/p' <<<"$s" | head -n 1)"
      if [[ "$(sed -n 's/^subject=//p' <<<"$s")" == "$(sed -n 's/^issuer=//p' <<<"$s")" ]]; then
        echo "hy2_cert_self=yes"
      else
        echo "hy2_cert_self=no"
      fi
    fi

    # Уровень журнала: переменная окружения службы или ключ запуска, по умолчанию info
    v="$(systemctl show "$SERVICE" -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^HYSTERIA_LOG_LEVEL=//p' | tail -n 1 || true)"
    if [[ -z "$v" ]]; then
      v="$(systemctl show "$SERVICE" -p ExecStart --value 2>/dev/null \
        | grep -oE '[[:space:]](--log-level|-l)[= ][a-z]+' | head -n 1 | grep -oE '[a-z]+$' || true)"
    fi
    echo "hy2_log=${v:-info}"

    # Port hopping своими правилами: диапазон UDP, перенаправленный на порт Hysteria2. Цепочки
    # ретранслятора IOF-* сюда не относятся: там DNAT одного порта на другой узел
    s=""
    if command -v iptables >/dev/null 2>&1; then
      s+="$(timeout 10 iptables -w 5 -t nat -S 2>/dev/null | grep -v -- '^-[AN] IOF-' | awk -v p="$port" '
        / -p udp / && ($0 ~ " -j REDIRECT --to-ports " p "$" || $0 ~ " -j DNAT --to-destination [0-9.]*:" p "$") {
          for (i = 1; i < NF; i++) if ($i == "--dport" || $i == "--dports") print $(i + 1)
        }' || true)"$'\n'
    fi
    if command -v nft >/dev/null 2>&1; then
      s+="$(timeout 10 nft list ruleset 2>/dev/null | awk -v p="$port" '
        /udp dport/ && ($0 ~ "redirect to :" p "([^0-9]|$)" || $0 ~ "dnat to [0-9.]*:" p "([^0-9]|$)") {
          for (i = 1; i < NF; i++) if ($i == "dport") print $(i + 1)
        }' || true)"
    fi
    echo "hy2_hop=$(tr ':' '-' <<<"$s" | grep -xE '[0-9]+-[0-9]+' | sort -u | paste -sd, || true)"

    n_audit_hy2_blocks "$CONFIG" "$salt"
  else
    echo "hy2=no"
  fi

  # AmneziaWG: параметры обфускации из конфига в контейнере и его лог на хосте
  if ! n_awg_find; then
    echo "awg=none"
  else
    echo "awg_c=$AWG_C"
    if ! n_awg_running; then
      echo "awg=stopped"
    elif ! n_awg_iface; then
      echo "awg=noconf"
    else
      echo "awg=running"
      echo "awg_if=$AWG_IF"
      timeout 10 docker exec "$AWG_C" cat "$AWG_CONF" 2>/dev/null | n_audit_awg_params "$salt" || true
    fi
    s="$(timeout 10 docker inspect -f '{{.HostConfig.LogConfig.Type}}|{{index .HostConfig.LogConfig.Config "max-size"}}|{{.LogPath}}' "$AWG_C" 2>/dev/null || true)"
    echo "awg_log_driver=$(cut -d'|' -f1 <<<"$s")"
    echo "awg_log_max=$(cut -d'|' -f2 <<<"$s")"
    v="$(cut -d'|' -f3 <<<"$s")"
    if [[ -n "$v" && -f "$v" ]]; then echo "awg_log_size=$(stat -c %s "$v")"; fi
  fi

  # Панель iof-web: на каком адресе слушает её процесс
  pid="$(systemctl show iof-web -p MainPID --value 2>/dev/null || true)"
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "web=none"
  else
    s="$(ss -Htlnp 2>/dev/null | grep -F "pid=$pid," | awk '{ print $4 }' | sort -u || true)"
    echo "web_addr=$(paste -sd, <<<"$s")"
    if [[ -z "$s" ]]; then echo "web=unknown"
    elif grep -qvE '^(127\.|\[::1\])' <<<"$s"; then echo "web=any"
    else echo "web=loopback"; fi
  fi

  # Блок-лист сканеров: только смотрим, применён ли он. Набор iof-block и цепочка IOF-BLOCK
  s=""
  if command -v ipset >/dev/null 2>&1; then s="$(timeout 10 ipset list -t iof-block 2>/dev/null || true)"; fi
  if [[ -n "$s" ]]; then
    echo "block_set=yes"
    echo "block_entries=$(sed -n 's/^Number of entries:[[:space:]]*//p' <<<"$s")"
  else
    echo "block_set=no"
  fi
  s=""; v=""
  if command -v iptables >/dev/null 2>&1; then
    s="$(timeout 10 iptables -w 5 -S IOF-BLOCK 2>/dev/null || true)"
    v="$(timeout 10 iptables -w 5 -S INPUT 2>/dev/null || true)"
  fi
  if [[ -n "$s" ]]; then echo "block_chain=yes"; else echo "block_chain=no"; fi
  if grep -q -- '-j IOF-BLOCK' <<<"$v"; then echo "block_hook=yes"; else echo "block_hook=no"; fi
  if [[ -f /etc/iof/block.list ]]; then echo "block_at=$(stat -c %Y /etc/iof/block.list)"; fi

  # Журнал systemd: действующие настройки, сколько занимает и с какого времени хранит записи
  if command -v journalctl >/dev/null 2>&1; then
    s="$(timeout 10 systemd-analyze cat-config systemd/journald.conf 2>/dev/null || cat /etc/systemd/journald.conf 2>/dev/null || true)"
    echo "jd_retention=$(sed -n 's/^[[:space:]]*MaxRetentionSec[[:space:]]*=[[:space:]]*//p' <<<"$s" | tail -n 1)"
    echo "jd_maxuse=$(sed -n 's/^[[:space:]]*SystemMaxUse[[:space:]]*=[[:space:]]*//p' <<<"$s" | tail -n 1)"
    echo "jd_usage=$(timeout 10 journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[BKMGT]' | head -n 1 || true)"
    echo "jd_oldest=$(timeout 10 journalctl -q --no-pager -o short-unix 2>/dev/null | head -n 1 | grep -oE '^[0-9]+' || true)"
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    echo "time_sync=$(timeout 5 timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    echo "time_ntp=$(timeout 5 timedatectl show -p NTP --value 2>/dev/null || true)"
  fi

  n_audit_listen
  n_audit_expect
  # Время в конце опроса: управляющий сервер сравнивает его со своим сразу после ответа
  echo "now_end=$(date +%s)"
}


# Проверка доступности узлов с ПК (iof audit probe). На время проверки на узле работает мишень:
# юнит iof-probe-<номер> из systemd-run с RuntimeMaxSec, по сроку systemd останавливает его сам.
# Внутри python3: TLS с самоподписанным сертификатом на TCP-порту и эхо на UDP-порту с тем же
# номером. Отвечает мишень только тому, кто знает токен, он лежит в файле 600 в /run/iof-probe-<номер>.
# Если входящие режет файрвол (ufw или iptables), ExecStartPre открывает порт правилом с комментарием
# iof-probe-<номер>, ExecStopPost снимает его и удаляет файлы. Цепочки IOF-* не трогаются

# Мишень: n_probe_start <номер> <сколько секунд жить> <порты: пусто, a-b или N> <токен>.
# Печатает now, hy2_port (порт Hysteria2, если она есть), probe — started или почему нет: nopython,
# noopenssl, nosystemd, nft (входящие режет своя таблица nftables), busy (нет свободного порта),
# error; для started ещё port, fp (sha256 сертификата), fw (opened — правило поставлено, open —
# входящие и так открыты), until; при ошибке error
n_probe_start() {
  local id="$1" ttl="$2" spec="$3" token="$4" unit dir lo=20000 hi=60000 port="" p s ipt="" filt=0
  local tries=0 max fp fw="open" py pre=() post=()
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  [[ "$id" =~ ^[0-9a-f]{8}$ && "$ttl" =~ ^[0-9]{2,4}$ && "$token" =~ ^[0-9a-f]{32}$ ]] || n_err "неверные параметры мишени"
  unit="iof-probe-$id"
  dir="/run/$unit"
  echo "now=$(date +%s)"
  if [[ -f "$CONFIG" ]]; then echo "hy2_port=$(n_hy2_port)"; fi
  py="$(command -v python3 || true)"
  if [[ -z "$py" ]]; then echo "probe=nopython"; return 0; fi
  if ! command -v openssl >/dev/null 2>&1; then echo "probe=noopenssl"; return 0; fi
  if ! command -v systemd-run >/dev/null 2>&1; then echo "probe=nosystemd"; return 0; fi

  # Режут ли входящие: ufw с запретом, политика DROP или запрет последним правилом в INPUT.
  # Своя таблица nftables с политикой drop правилом iptables не открывается, такой узел не проверяем
  ipt="$(command -v iptables || true)"
  if [[ -n "$ipt" ]]; then
    s="$(timeout 10 "$ipt" -w 5 -S INPUT 2>/dev/null || true)"
    if grep -q '^-P INPUT DROP' <<<"$s" || tail -n 1 <<<"$s" | grep -qE '^-A INPUT -j (DROP|REJECT)'; then filt=1; fi
    if command -v ufw >/dev/null 2>&1; then
      s="$(timeout 10 ufw status verbose 2>/dev/null || true)"
      if grep -qE '^Default: (deny|reject) \(incoming\)' <<<"$s"; then filt=1; fi
    fi
  fi
  if command -v nft >/dev/null 2>&1; then
    s="$(timeout 10 nft list ruleset 2>/dev/null | awk '
      /^table / { t = $2 " " $3 }
      /hook input/ && /policy drop/ && t != "ip filter" && t != "ip6 filter" { print t; exit }' || true)"
    if [[ -n "$s" ]]; then printf 'probe=nft\nerror=таблица %s\n' "$s"; return 0; fi
  fi

  # Порт свободен по TCP и UDP и не попадает под перенаправления: правила ретранслятора, nat
  # (port hopping) и диапазон в listen Hysteria2. Такие пакеты до мишени не дошли бы
  if [[ "$spec" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
  elif [[ "$spec" =~ ^[0-9]{1,5}$ ]]; then lo="$spec"; hi="$spec"
  elif [[ -n "$spec" ]]; then n_err "PROBE_PORTS: нужен порт или диапазон a-b"; fi
  lo=$((10#$lo)); hi=$((10#$hi))
  (( lo >= 1 && lo <= hi && hi <= 65535 )) || n_err "PROBE_PORTS: порты от 1 до 65535, начало не больше конца"
  s="$( {
    if [[ -n "$ipt" ]]; then timeout 10 "$ipt" -w 5 -t nat -S 2>/dev/null | grep -oE -- '--dports? [0-9:,]+' | cut -d' ' -f2 | tr ',' '\n'; fi
    if [[ -f /etc/iof/relay.rules ]]; then awk '$1 !~ /^#/ && NF >= 4 { print $2 }' /etc/iof/relay.rules; fi
    if [[ -f "$CONFIG" ]]; then sed -n 's/^listen:[[:space:]]*//p' "$CONFIG" | grep -oE '[0-9]+-[0-9]+$' | head -n 1; fi
  } | tr ':' '-' || true)"
  max=$(( hi - lo + 1 ))
  if (( max > 100 )); then max=100; fi
  while (( tries < max )); do
    tries=$((tries + 1))
    p="$(shuf -i "$lo-$hi" -n 1)"
    if [[ -n "$(ss -Htuln "sport = :$p" 2>/dev/null)" ]]; then continue; fi
    if awk -F- -v p="$p" 'NF { b = (NF > 1 ? $2 : $1); if (p >= $1 && p <= b) f = 1 } END { exit !f }' <<<"$s"; then continue; fi
    port="$p"
    break
  done
  if [[ -z "$port" ]]; then printf 'probe=busy\nerror=свободного порта в %s-%s нет\n' "$lo" "$hi"; return 0; fi

  # Сертификат на один запуск, имя в нём случайное. Отпечаток сверяют контроль и скрипт на ПК
  rm -rf "$dir"
  mkdir -m 700 "$dir"
  if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
       -subj "/CN=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
       -keyout "$dir/key.pem" -out "$dir/cert.pem" >/dev/null 2>&1; then
    rm -rf "$dir"
    printf 'probe=error\nerror=openssl не создал сертификат\n'
    return 0
  fi
  fp="$(openssl x509 -in "$dir/cert.pem" -noout -fingerprint -sha256 | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')"
  printf '%s\n' "$token" > "$dir/token"
  cat > "$dir/target.py" <<'EOF'
# Мишень проверки с ПК (iof audit probe). По TLS первой строкой ждёт «IOF-PROBE <токен>», тогда
# отвечает «OK <IP источника>» и отдаёт 256 КБ. По UDP отвечает только на пакет с «IOFP<токен>»
# внутри: возвращает его же с затёртым токеном, той же длины. Остальным не шлёт ничего
import hmac, os, socket, ssl, sys, threading

d, port = sys.argv[1], int(sys.argv[2])
with open(os.path.join(d, "token"), "rb") as f:
    token = f.read().strip()
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(d, "cert.pem"), os.path.join(d, "key.pem"))
blob = os.urandom(16384) * 16
slots = threading.BoundedSemaphore(32)


def serve(conn, addr):
    s = conn
    try:
        conn.settimeout(8)
        s = ctx.wrap_socket(conn, server_side=True)
        line = b""
        while b"\n" not in line and len(line) < 128:
            chunk = s.recv(128)
            if not chunk:
                return
            line += chunk
        if not hmac.compare_digest(line.split(b"\n", 1)[0].strip(), b"IOF-PROBE " + token):
            return
        s.sendall(b"OK " + addr[0].encode() + b"\n" + blob)
        # Ждём, пока клиент закроет соединение сам: иначе хвост данных может потеряться
        s.settimeout(5)
        while s.recv(4096):
            pass
    except (OSError, ValueError):
        pass
    finally:
        s.close()
        slots.release()


def udp():
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind(("0.0.0.0", port))
    mark = b"IOFP" + token
    while True:
        data, addr = u.recvfrom(2048)
        i = data.find(mark)
        if i >= 0:
            u.sendto(data[:i + 4] + b"\0" * len(token) + data[i + len(mark):], addr)


srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", port))
srv.listen(64)
threading.Thread(target=udp, daemon=True).start()
while True:
    c, a = srv.accept()
    if slots.acquire(blocking=False):
        threading.Thread(target=serve, args=(c, a), daemon=True).start()
    else:
        c.close()
EOF
  chmod 600 "$dir"/*

  # Правила только там, где входящие режутся. Команды без $ и %: systemd-run раскрыл бы их сам
  if (( filt )); then
    fw="opened"
    for p in tcp udp; do
      pre+=(-p "ExecStartPre=$ipt -w 5 -I INPUT 1 -p $p --dport $port -m comment --comment $unit -j ACCEPT")
      post+=(-p "ExecStopPost=-$ipt -w 5 -D INPUT -p $p --dport $port -m comment --comment $unit -j ACCEPT")
    done
  fi
  if ! s="$(systemd-run --quiet --collect --unit="$unit" -p RuntimeMaxSec="$ttl" "${pre[@]}" "${post[@]}" \
         -p "ExecStopPost=/bin/rm -rf $dir" "$py" "$dir/target.py" "$dir" "$port" 2>&1)"; then
    rm -rf "$dir"
    printf 'probe=error\nerror=%s\n' "$(tail -n 1 <<<"$s")"
    return 0
  fi
  for (( tries = 0; tries < 40; tries++ )); do
    if [[ -n "$(ss -Htln "sport = :$port" 2>/dev/null)" && -n "$(ss -Huln "sport = :$port" 2>/dev/null)" ]]; then
      printf '%s\n' "probe=started" "port=$port" "fp=$fp" "fw=$fw" "until=$(( $(date +%s) + ttl ))"
      return 0
    fi
    if ! systemctl is-active --quiet "$unit"; then break; fi
    sleep 0.25
  done
  s="$(journalctl -q -u "$unit" -n 3 -o cat --no-pager 2>/dev/null | tail -n 1 || true)"
  systemctl stop "$unit" >/dev/null 2>&1 || true
  printf 'probe=error\nerror=мишень не поднялась%s\n' "${s:+: $s}"
}

# Останавливает мишени: n_probe_stop [номер], без номера — все iof-probe-* на узле. Добирает то, что
# могло остаться без ExecStopPost: правила с комментарием iof-probe-* и папки в /run.
# Печатает stopped (сколько юнитов остановлено) и left (сколько остатков пришлось убрать)
n_probe_stop() {
  local id="${1:-}" pat re u d n=0 left=0 ipt line rule=()
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  if [[ -n "$id" && ! "$id" =~ ^[0-9a-f]{8}$ ]]; then n_err "неверный номер проверки"; fi
  pat="iof-probe-${id:-*}"
  re="iof-probe-$id"
  if [[ -z "$id" ]]; then re="iof-probe-[0-9a-f]{8}"; fi
  for u in $(systemctl list-units --all --plain --no-legend "$pat.service" 2>/dev/null | awk '{ print $1 }'); do
    systemctl stop "$u" >/dev/null 2>&1 || true
    n=$((n + 1))
  done
  systemctl reset-failed "$pat.service" >/dev/null 2>&1 || true
  ipt="$(command -v iptables || true)"
  if [[ -n "$ipt" ]]; then
    while IFS= read -r line; do
      read -ra rule <<<"${line/#-A/-D}"
      if "$ipt" -w 5 "${rule[@]}" 2>/dev/null; then left=$((left + 1)); fi
    done < <("$ipt" -w 5 -S INPUT 2>/dev/null | grep -E -- "--comment \"?$re\"?( |$)" || true)
  fi
  # shellcheck disable=SC2231 # шаблон имени нужен без кавычек
  for d in /run/$pat; do
    if [[ -d "$d" ]]; then rm -rf "$d"; left=$((left + 1)); fi
  done
  printf 'stopped=%s\nleft=%s\n' "$n" "$left"
}


# Перенос управляющего сервера (iof migrate). Эти функции выполняются на новом
# или на старом управляющем сервере, когда тот уже стал обычным узлом.

# Сведения о будущем управляющем сервере для iof migrate start, строки key=value.
# probe — метка из $IOF_HOME/.migrate-probe: если она совпала с меткой, которую только что
# записал старый сервер, это он сам. machine-id для этого не годится: у VPS из одного образа
# он бывает одинаковым
n_migrate_check() {
  local nodes=0 role="" id=""
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  if [[ -f "$IOF_HOME/nodes.conf" ]]; then
    nodes="$(grep -cvE '^[[:space:]]*(#|$)' "$IOF_HOME/nodes.conf" || true)"
  fi
  if [[ -f "$IOF_HOME/migrate.conf" ]]; then
    role="$(awk -F= '$1 == "role" { print $2; exit }' "$IOF_HOME/migrate.conf")"
    id="$(awk -F= '$1 == "id" { print $2; exit }' "$IOF_HOME/migrate.conf")"
  fi
  printf 'probe=%s\nos=%s\napt=%s\nnodes=%s\nrole=%s\nid=%s\n' \
    "$(cat "$IOF_HOME/.migrate-probe" 2>/dev/null || true)" \
    "$(. /etc/os-release 2>/dev/null; printf '%s %s' "${ID:-?}" "${VERSION_ID:-}")" \
    "$(command -v apt-get >/dev/null 2>&1 && echo yes || echo no)" \
    "${nodes:-0}" "$role" "$id"
}

# Принимает управление из папки $2, куда iof migrate start прислал data (будущий $IOF_HOME),
# ssh (ключ iof и known_hosts) и src (клон репозитория). Ставит iof той же версии, что на старом
# сервере. Копия данных с прошлой попытки этого же переноса ($1) заменяется, другие сохраняются рядом
n_migrate_receive() {
  local id="$1" inbox="$2" ts f
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  [[ -d "$inbox/data" && -d "$inbox/src" && -s "$inbox/ssh/iof_ed25519" ]] || n_err "нет присланных данных в $inbox"
  ts="$(date +%Y%m%d-%H%M%S)"

  export DEBIAN_FRONTEND=noninteractive
  if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || ! command -v qrencode >/dev/null 2>&1; then
    echo "[$(hostname)] ставлю git, python3 и qrencode" >&2
    # На только что созданном сервере apt часто занят автообновлением, поэтому ждём блокировку
    apt-get -o DPkg::Lock::Timeout=300 update -qq >/dev/null 2>&1 || true
    apt-get -o DPkg::Lock::Timeout=300 install -y -qq git python3 qrencode >/dev/null 2>&1 \
      || n_err "не удалось установить git, python3 и qrencode"
  fi

  rm -rf /opt/iof.migrate-new
  mv "$inbox/src" /opt/iof.migrate-new
  rm -rf /opt/iof
  mv /opt/iof.migrate-new /opt/iof
  chown -R root:root /opt/iof
  echo "[$(hostname)] ставлю iof и панель" >&2
  # stdin пустой: сам этот скрипт пришёл через stdin (run_on), install.sh не должен его читать
  bash /opt/iof/install.sh </dev/null >&2 || n_err "install.sh завершился с ошибкой"

  if [[ -d "$IOF_HOME" ]]; then
    if [[ -f "$IOF_HOME/migrate.conf" ]] && grep -qxF "id=$id" "$IOF_HOME/migrate.conf"; then
      rm -rf "$IOF_HOME"
    else
      mv "$IOF_HOME" "$IOF_HOME.before-migrate-$ts"
      echo "[$(hostname)] прежняя папка iof сохранена в $IOF_HOME.before-migrate-$ts" >&2
    fi
  fi
  mv "$inbox/data" "$IOF_HOME"
  chown -R root:root "$IOF_HOME"
  chmod 700 "$IOF_HOME"

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  for f in iof_ed25519 iof_ed25519.pub; do
    if [[ -f "/root/.ssh/$f" ]] && ! cmp -s "/root/.ssh/$f" "$inbox/ssh/$f"; then
      mv "/root/.ssh/$f" "/root/.ssh/$f.before-migrate-$ts"
    fi
  done
  install -m 600 "$inbox/ssh/iof_ed25519" /root/.ssh/iof_ed25519
  install -m 644 "$inbox/ssh/iof_ed25519.pub" /root/.ssh/iof_ed25519.pub
  # Ключи узлов, которым доверял старый сервер: иначе первый вход на каждый узел был бы вслепую
  if [[ -s "$inbox/ssh/known_hosts" ]]; then
    touch /root/.ssh/known_hosts
    chmod 600 /root/.ssh/known_hosts
    grep -vxF -f /root/.ssh/known_hosts "$inbox/ssh/known_hosts" >> /root/.ssh/known_hosts || true
  fi
  rm -rf "$inbox"

  # Панель запущена install.sh до того, как появился web.env
  systemctl restart iof-web || echo "[$(hostname)] iof-web не перезапустился: journalctl -u iof-web -n 30" >&2
  echo "received $(git -C /opt/iof log -1 --format=%h 2>/dev/null || echo '?')"
}

# Снимает с сервера роль управляющего: задания cron по шаблону $1, панель и команды iof.
# Данные в $IOF_HOME и клон в /opt/iof не трогает
n_migrate_uninstall() {
  local re="$1" cron
  cron="$(crontab -l -u root 2>/dev/null || true)"
  if grep -qE "$re" <<<"$cron"; then
    { grep -vE "$re" <<<"$cron" || true; } | crontab -u root -
    echo "[$(hostname)] из cron убраны задания iof" >&2
  fi
  systemctl disable --now iof-web >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/iof-web.service /usr/local/bin/iof /usr/local/sbin/iof-nightly
  rm -rf /opt/iof-web
  systemctl daemon-reload
}

# Старый управляющий сервер в конце переноса: остаётся узлом, данные iof и ключ уходят в папку
# $IOF_HOME.moved-<время>, её путь печатается. Номер переноса $1 защищает от ошибки: снимается
# только сервер, с которого начат именно этот перенос
n_migrate_demote() {
  local id="$1" re="$2" dest
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  if [[ ! -f "$IOF_HOME/migrate.conf" ]] || ! grep -qxF "role=source" "$IOF_HOME/migrate.conf" \
     || ! grep -qxF "id=$id" "$IOF_HOME/migrate.conf"; then
    n_err "отсюда не начат этот перенос (нет $IOF_HOME/migrate.conf с id=$id), ничего не менял"
  fi
  n_migrate_uninstall "$re"
  dest="$IOF_HOME.moved-$(date +%Y%m%d-%H%M%S)"
  mv "$IOF_HOME" "$dest"
  mv /root/.ssh/iof_ed25519 /root/.ssh/iof_ed25519.pub "$dest"/ 2>/dev/null || true
  chmod 700 "$dest"
  echo "[$(hostname)] управление снято, сервер остался узлом" >&2
  printf '%s\n' "$dest"
}

# Отмена переноса на новом сервере: убирает iof, копию данных и ключ iof. Ключ iof в authorized_keys
# остаётся при $2 = 1: значит, сервер ещё и узел старого и тот заходит на него этим ключом
n_migrate_abort() {
  local id="$1" keep="$2" inbox="$3" re="$4" pub user home
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  rm -rf "$inbox"
  if [[ ! -f "$IOF_HOME/migrate.conf" ]] || ! grep -qxF "id=$id" "$IOF_HOME/migrate.conf"; then
    echo "[$(hostname)] копии этого переноса здесь нет" >&2
    return 0
  fi
  n_migrate_uninstall "$re"
  pub="$(cat /root/.ssh/iof_ed25519.pub 2>/dev/null || true)"
  rm -rf "$IOF_HOME"
  rm -f /root/.ssh/iof_ed25519 /root/.ssh/iof_ed25519.pub
  user="${SUDO_USER:-root}"
  home="$(getent passwd "$user" | cut -d: -f6 || true)"
  if [[ "$keep" != "1" && -n "$pub" && -f "$home/.ssh/authorized_keys" ]]; then
    grep -vxF "$pub" "$home/.ssh/authorized_keys" > "$home/.ssh/authorized_keys.iof-tmp" || true
    cat "$home/.ssh/authorized_keys.iof-tmp" > "$home/.ssh/authorized_keys"
    rm -f "$home/.ssh/authorized_keys.iof-tmp"
  fi
  echo "[$(hostname)] iof и копия данных удалены" >&2
}

# Всё, что run_on передаёт на узел
NODE_FUNCS=(
  n_defaults n_err n_yaml_value n_urlencode
  n_hy2_port n_hy2_userpass n_hy2_user_add n_hy2_user_del n_hy2_restart n_hy2_service_restart
  n_hy2_add n_hy2_del n_hy2_install
  n_awg_find n_awg_running n_awg_iface n_awg_table_pubs n_awg_table_add n_awg_table_del n_awg_pubkey
  n_awg_clients n_awg_backup n_awg_add n_awg_del
  n_status
  n_free_ports n_relay_apply n_relay_status
  n_audit_listen n_audit_expect n_audit_server n_audit_hy2_blocks n_audit_awg_params n_audit_dpi
  n_probe_start n_probe_stop
  n_migrate_check n_migrate_receive n_migrate_uninstall n_migrate_demote n_migrate_abort
)


# Дальше код только для управляющего сервера.

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
run_on() {
  local target="$1" script
  shift
  script="set -euo pipefail; $(declare -f "${NODE_FUNCS[@]}"); $(printf '%q ' "$@")"
  if [[ "$target" == "local" ]]; then
    bash -c "$script"
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

tg_send() {
  if [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]]; then return 0; fi
  curl -fsS --max-time 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT}" --data-urlencode "text=$1" >/dev/null 2>&1 || true
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


# Опрос состояния узлов (n_status). Поля узла попадают в ассоциативный массив P,
# время ответа в миллисекундах в P_MS.

declare -A P=()
P_MS=0

probe_job() {
  local i="$1" t0 t1 out
  t0="$(date +%s%N)"
  out="$(run_on "${N_SSH[$i]}" n_status 2>/dev/null)" || return 1
  t1="$(date +%s%N)"
  printf '%s\n%s\n' "$(( (t1 - t0) / 1000000 ))" "$out"
}

probe_parse() {
  local line first=1
  P=()
  while IFS= read -r line; do
    if (( first )); then P_MS="$line"; first=0; continue; fi
    [[ "$line" == *=* ]] || continue
    P["${line%%=*}"]="${line#*=}"
  done <<<"$1"
  [[ -n "${P[hy2_state]:-}" ]]
}

# Опрос одного узла сразу в P
probe() {
  local out
  out="$(probe_job "$1")" || return 1
  probe_parse "$out"
}

probe_all()  { pmap probe_job "$@"; }
probe_load() { pm_ok "$1" || return 1; probe_parse "$(pm_out "$1")"; }

# Проблемы узла по данным из P, через "; ". Пусто, если всё в порядке.
# Hysteria2 проверяется только там, где она установлена, AWG только там, где есть контейнер
node_issues() {
  local out=() disk
  if [[ "${P[hy2_installed]}" == "yes" ]]; then
    if [[ "${P[hy2_state]}" != "active" ]]; then
      out+=("Hysteria2 не работает (${P[hy2_state]})")
    elif [[ "${P[hy2_udp]}" != "yes" ]]; then
      out+=("Hysteria2 не слушает UDP ${P[hy2_port]}")
    fi
  fi
  if [[ "${P[awg_state]}" == "stopped" ]]; then out+=("контейнер AmneziaWG остановлен"); fi
  disk="$(percent "${P[disk_used_kb]}" "${P[disk_total_kb]}")"
  if (( disk >= 90 )); then out+=("диск заполнен на $disk%"); fi
  local IFS=$'\x1f'
  printf '%s' "${out[*]}" | sed 's/\x1f/; /g'
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

# Ячейки для таблиц по данным из P

cell_hy2() {
  if [[ "${P[hy2_installed]}" != "yes" ]]; then printf -- '-'; return; fi
  if [[ "${P[hy2_state]}" != "active" ]]; then c_red "не работает"; return; fi
  if [[ "${P[hy2_udp]}" != "yes" ]]; then c_red "не слушает :${P[hy2_port]}"; return; fi
  c_green "работает :${P[hy2_port]}"
}

cell_hy2_access() {
  case "${P[hy2_auth]}" in
    password) printf 'общий пароль' ;;
    userpass) printf '%s польз.' "${P[hy2_users]}" ;;
    *)        printf -- '-' ;;
  esac
}

cell_awg() {
  case "${P[awg_state]}" in
    running) c_green "работает :${P[awg_port]}" ;;
    stopped) c_red "остановлен" ;;
    *)       printf -- '-' ;;
  esac
}

cell_awg_clients() {
  if [[ "${P[awg_state]}" != "running" ]]; then printf -- '-'; return; fi
  printf '%s, онлайн %s' "${P[awg_peers]}" "${P[awg_online]}"
}

cell_cpu() {
  local v
  v="$(awk -v l="${P[load1]:-0}" -v c="${P[cpus]:-1}" 'BEGIN { printf "%d", l * 100 / c + 0.5 }')"
  if (( v >= 90 )); then c_yellow "$v%"; else printf '%s%%' "$v"; fi
}

cell_mem() {
  local v text
  v="$(percent "${P[mem_used_mb]}" "${P[mem_total_mb]}")"
  text="$v% из $(gb "${P[mem_total_mb]}" 1024) ГБ"
  if (( v >= 90 )); then c_yellow "$text"; else printf '%s' "$text"; fi
}

cell_disk() {
  local v text
  v="$(percent "${P[disk_used_kb]}" "${P[disk_total_kb]}")"
  text="$v% из $(gb "${P[disk_total_kb]}" 1048576) ГБ"
  if (( v >= 90 )); then c_red "$text"; elif (( v >= 80 )); then c_yellow "$text"; else printf '%s' "$text"; fi
}

# Общие команды: init, status, check, exec, refresh

cmd_init() {
  mkdir -p "$BASE" "$HY2_DIR" "$STATE_DIR"
  chmod 700 "$BASE"

  if [[ ! -f "$NODES_FILE" ]]; then
    cat > "$NODES_FILE" <<'EOF'
# имя | адрес для клиентов | ssh (local или user@host[:port]) | подпись в клиенте
main   | 192.0.2.10    | local                 | Main
node-1 | 198.51.100.20 | root@198.51.100.20    | Node 1
node-2 | 203.0.113.30  | admin@203.0.113.30:22 | Node 2
EOF
    echo "Создан $NODES_FILE"
  fi

  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<'EOF'
# Уведомления в Telegram для iof check (пусто = не отправлять)
TG_TOKEN=""
TG_CHAT=""

# Сколько узлов обрабатывать одновременно
PARALLEL=20
EOF
    chmod 600 "$ENV_FILE"
    echo "Создан $ENV_FILE"
  fi

  if [[ ! -f "$SSH_KEY" ]]; then
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "iof@$(hostname)" >/dev/null
    echo "Создан SSH-ключ $SSH_KEY"
  fi

  # Раздача ключа по одному узлу с вводом пароля. Для многих серверов удобнее iof node import
  read_nodes
  local i
  for i in "${!N_NAME[@]}"; do
    if [[ "${N_SSH[$i]}" == "local" ]]; then continue; fi
    echo "== ${N_NAME[$i]} (${N_SSH[$i]})"
    if ssh_cmd "${N_SSH[$i]}" true 2>/dev/null; then
      echo "   ключ уже работает"
      continue
    fi
    split_target "${N_SSH[$i]}"
    echo "   копирую ключ, введи пароль этого сервера"
    if ssh-copy-id -i "${SSH_KEY}.pub" -p "$T_PORT" -o StrictHostKeyChecking=accept-new "$T_HOST"; then
      echo "   готово"
    else
      echo "   не получилось, добавь содержимое ${SSH_KEY}.pub в authorized_keys на узле вручную"
    fi
  done
  echo
  echo "Проверка: iof status"
}

# Сводная таблица по узлам: Hysteria2, AWG, ресурсы. Под таблицей список проблем
cmd_status() {
  read_nodes
  select_nodes
  local i issues rows=() bad=() problems=()
  probe_all "${SEL[@]}"
  rows+=("$(row "" "УЗЕЛ" "АДРЕС" "HYSTERIA2" "AMNEZIAWG" "КЛИЕНТЫ AWG" "ЦП" "ПАМЯТЬ" "ДИСК" "РАБОТАЕТ" "ОТКЛИК")")
  for i in "${SEL[@]}"; do
    if probe_load "$i"; then
      issues="$(node_issues)"
      rows+=("$(row "$( [[ -z "$issues" ]] && c_green "ok" || c_red "!!" )" "${N_NAME[$i]}" "${N_ADDR[$i]}" \
        "$(cell_hy2)${P[hy2_ver]:+, ${P[hy2_ver]}}" "$(cell_awg)" "$(cell_awg_clients)" \
        "$(cell_cpu)" "$(cell_mem)" "$(cell_disk)" "$(fmt_uptime "${P[uptime_s]}")" "$(fmt_ms "$P_MS")")")
    else
      issues="нет связи по SSH"
      rows+=("$(row "$(c_red "!!")" "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(c_red "НЕТ СВЯЗИ")" "-" "-" "-" "-" "-" "-" "-")")
    fi
    if [[ -n "$issues" ]]; then
      bad+=("${N_NAME[$i]}")
      problems+=("${N_NAME[$i]}: $issues")
    fi
  done
  printf '%s\n' "${rows[@]}" | table
  echo
  echo "Всего узлов: ${#SEL[@]}, в порядке: $(( ${#SEL[@]} - ${#bad[@]} )), с проблемами: ${#bad[@]}"
  if (( ${#problems[@]} > 0 )); then
    echo
    paint 31 "Проблемы:"
    echo
    printf '  %s\n' "${problems[@]}"
  fi
}

# Проверка для cron. Состояние каждого узла хранится в $STATE_DIR, в Telegram уходит
# одно сообщение со всеми изменениями. Код выхода 1, если есть проблемные узлы
cmd_check() {
  read_nodes
  select_nodes
  mkdir -p "$STATE_DIR"
  local i state prev bad=0 changes=() bad_names=()
  probe_all "${SEL[@]}"
  for i in "${SEL[@]}"; do
    if probe_load "$i"; then
      state="$(node_issues)"
      state="${state:-ok}"
    else
      state="нет связи по SSH"
    fi
    prev="$(cat "$STATE_DIR/${N_NAME[$i]}" 2>/dev/null || echo ok)"
    if [[ "$state" != "$prev" ]]; then
      if [[ "$state" == "ok" ]]; then
        changes+=("[OK] ${N_NAME[$i]} (${N_ADDR[$i]}) снова работает")
      else
        changes+=("[ПРОБЛЕМА] ${N_NAME[$i]} (${N_ADDR[$i]}): $state")
      fi
      printf '%s\n' "$state" > "$STATE_DIR/${N_NAME[$i]}"
    fi
    if [[ "$state" != "ok" ]]; then
      bad=$((bad + 1))
      bad_names+=("${N_NAME[$i]}")
    fi
    echo "${N_NAME[$i]}: $state"
  done
  if (( ${#changes[@]} > 0 )); then
    tg_send "$(printf '%s\n' "${changes[@]}")"
  fi
  # Итог для страницы «Сервис» панели: когда была проверка и что нашла
  printf 'time=%s\ntotal=%s\nbad=%s\nproblems=%s\nchanges=%s\n' \
    "$(date '+%F %T')" "${#SEL[@]}" "$bad" "${bad_names[*]}" "${#changes[@]}" > "$CHECK_FILE"
  (( bad == 0 ))
}

# Данные для веб-панели (iof-web): блок на узел, первая строка "== имя", дальше key=value.
# Поля те же, что отдаёт n_status, плюс адрес, подпись, отклик и проблемы через "; "
cmd_api() {
  case "${1:-}" in
    status)  api_status ;;
    service) api_service ;;
    updates) api_updates ;;
    audit)   api_audit ;;
    *)       die "используй: iof api status | service | updates | audit" ;;
  esac
}

# Для страницы «Сервис»: версия, клон репозитория, настроен ли Telegram, задания cron iof
api_service() {
  printf 'version=%s\nsrc=%s\n' "$IOF_VERSION" "$IOF_SRC"
  if [[ -d "$IOF_SRC/.git" ]] && have git; then
    printf 'src_version=%s\n' "$(git -C "$IOF_SRC" log -1 --format='%h %cd' --date=short 2>/dev/null || true)"
  fi
  if [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then echo "tg=yes"; else echo "tg=no"; fi
  crontab -l -u root 2>/dev/null | grep -v '^[[:space:]]*#' | grep -F 'iof' | sed 's/^/cron=/' || true
}

# Для страницы «Сервис»: git fetch в клоне, затем коммиты, которые принесёт iof update
api_updates() {
  local err
  [[ -d "$IOF_SRC/.git" ]] || die "нет клона репозитория в $IOF_SRC"
  have git || die "нет git: apt install git"
  err="$(GIT_TERMINAL_PROMPT=0 git -C "$IOF_SRC" fetch --quiet 2>&1)" || die "git fetch не прошёл: $(tail -n 1 <<<"$err")"
  git -C "$IOF_SRC" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 \
    || die "у ветки в $IOF_SRC нет вышестоящей (upstream), iof update не сможет сделать git pull"
  printf 'branch=%s\n' "$(git -C "$IOF_SRC" rev-parse --abbrev-ref '@{u}')"
  git -C "$IOF_SRC" log --format='commit=%h%x09%cd%x09%s' --date=short 'HEAD..@{u}'
}

api_status() {
  read_nodes
  select_nodes
  local i k
  probe_all "${SEL[@]}"
  for i in "${SEL[@]}"; do
    echo "== ${N_NAME[$i]}"
    printf 'addr=%s\ntitle=%s\n' "${N_ADDR[$i]}" "$(node_title "$i")"
    if probe_load "$i"; then
      printf 'reachable=yes\nms=%s\nissues=%s\n' "$P_MS" "$(node_issues)"
      for k in "${!P[@]}"; do printf '%s=%s\n' "$k" "${P[$k]}"; done
    else
      printf 'reachable=no\nissues=нет связи по SSH\n'
    fi
  done
}

# Обновление из клона репозитория GitHub в $IOF_SRC: git pull, затем install.sh
# ставит новый iof и веб-панель
cmd_update() {
  local old new
  [[ -d "$IOF_SRC/.git" ]] || die "нет клона репозитория в $IOF_SRC, сначала: git clone https://github.com/mEldevlp/iof $IOF_SRC"
  have git || die "нет git: apt install git"
  old="$(git -C "$IOF_SRC" rev-parse --short HEAD)"
  git -C "$IOF_SRC" pull --ff-only --quiet || die "git pull не прошёл, проверь $IOF_SRC (git -C $IOF_SRC status)"
  new="$(git -C "$IOF_SRC" rev-parse --short HEAD)"
  if [[ "$old" == "$new" ]]; then
    echo "Новых изменений нет ($new), переустанавливаю текущую версию"
  else
    echo "Изменения $old..$new:"
    git -C "$IOF_SRC" log --format='  %h %s' "$old..$new"
  fi
  exec bash "$IOF_SRC/install.sh" "$@"
}

exec_job() {
  local i="$1"
  if [[ "${N_SSH[$i]}" == "local" ]]; then
    bash -c "$EXEC_CMD" 2>&1
  else
    ssh_cmd "${N_SSH[$i]}" "$(remote_sudo "${N_SSH[$i]}")bash -c $(printf '%q' "$EXEC_CMD")" 2>&1
  fi
}

# Произвольная команда на узлах, вывод по узлам в порядке nodes.conf
cmd_exec() {
  [[ $# -gt 0 ]] || die "укажи команду: iof exec \"apt update\""
  read_nodes
  select_nodes
  local i rc failed=0
  EXEC_CMD="$*"
  pmap exec_job "${SEL[@]}"
  for i in "${SEL[@]}"; do
    rc="$(pm_rc "$i")"
    echo "== ${N_NAME[$i]}"
    pm_out "$i"
    if [[ "$rc" != "0" ]]; then
      echo "   код выхода $rc"
      failed=$((failed + 1))
    fi
  done
  echo
  echo "Выполнено на ${#SEL[@]} узлах, с ошибкой: $failed"
}

# Пересборка всех ссылок Hysteria2 и ключей AWG (после смены узлов, пароля или ретранслятора)
cmd_refresh() {
  hy2_refresh
  echo
  awg_refresh
}


# Узлы: iof node add | import | del | list

# Раздача ключа iof на узел с индексом $1 в массивах IM_*: вход по паролю (sshpass) или ключом
push_key_job() {
  local j="$1" host="${IM_HOST[$1]}" port="${IM_PORT[$1]}" user="${IM_USER[$1]}" pub cmd err="" rc=0
  pub="$(cat "$SSH_KEY.pub")"
  [[ -n "$pub" ]] || { echo "нет публичного ключа" >&2; return 1; }
  cmd="umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys"
  # Не root: iof выполняет команды через sudo -n, без него ключ класть незачем
  if [[ "$user" != "root" ]]; then cmd="sudo -n true 2>/dev/null || exit 42; $cmd"; fi
  # stderr ssh нужен, чтобы отличить неверный пароль от недоступного сервера
  case "${IM_MODE[$j]}" in
    installed) ;;  # ключ iof положен вручную, остаётся проверка ниже
    key)
      err="$(ssh -i "${IM_KEY[$j]}" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$user@$host" "$cmd" \
        2>&1 >/dev/null)" || rc=$? ;;
    *)
      err="$(SSHPASS="${IM_PASS[$j]}" sshpass -e ssh -p "$port" \
        -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout=10 "$user@$host" "$cmd" \
        2>&1 >/dev/null)" || rc=$? ;;
  esac
  case "$rc" in
    0) ;;
    42) echo "у $user нет sudo без пароля (NOPASSWD), iof с ним работать не сможет" >&2; return 1 ;;
    5) echo "неверный пароль $user" >&2; return 1 ;;
    6) echo "ключ хоста изменился, удали старую запись: ssh-keygen -R $host" >&2; return 1 ;;
    255)
      if [[ "$err" == *"Permission denied"* && "${IM_MODE[$j]}" == "key" ]]; then
        echo "ключ не подходит для $user" >&2
      elif [[ "$err" == *"Permission denied"* ]]; then
        echo "неверный пароль $user или вход по паролю запрещён" >&2
      else
        err="$(grep -v '^Warning: Permanently added' <<<"$err" | tail -n 1 | tr -d '\r')"
        echo "нет связи по SSH${err:+: $err}" >&2
      fi
      return 1 ;;
    *) echo "ошибка входа (код $rc)" >&2; return 1 ;;
  esac
  if ! ssh_cmd "$user@$host:$port" "$(remote_sudo "$user@$host")true" </dev/null >/dev/null 2>&1; then
    if [[ "${IM_MODE[$j]}" != "installed" ]]; then
      echo "вход удался, но ключ iof не работает" >&2
    elif [[ "$user" != "root" ]]; then
      echo "ключ iof не подошёл или у $user нет sudo без пароля (NOPASSWD)" >&2
    else
      echo "нет связи по SSH или ключ iof не добавлен в ~/.ssh/authorized_keys у $user" >&2
    fi
    return 1
  fi
}

ensure_ssh_key() {
  if [[ ! -f "$SSH_KEY" ]]; then
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "iof@$(hostname)" >/dev/null || die "не удалось создать SSH-ключ"
  fi
  [[ -s "$SSH_KEY.pub" ]] || die "нет публичного ключа $SSH_KEY.pub"
}

# sshpass нужен только для входа по паролю
ensure_sshpass() {
  if have sshpass; then return 0; fi
  echo "Ставлю sshpass..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null 2>&1 \
    || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null 2>&1; } \
    || die "не удалось установить sshpass"
}

# Пароль или ключ для первого входа на сервер (iof node add, iof migrate start):
# read_auth <ask|password-stdin|key-file|key-stdin|installed> <файл ключа> <пользователь> <хост>.
# Результат: AUTH_MODE (password, key или installed), AUTH_PASS, AUTH_KEY (временная копия ключа,
# после входа её надо удалить). Варианты со stdin нужны веб-панели: так пароль и ключ не видны
# в списке процессов
read_auth() {
  local auth="$1" keyfile="$2" user="$3" host="$4" tmp
  AUTH_PASS=""
  AUTH_KEY=""
  case "$auth" in
    installed) ;;
    ask)
      read -rsp "Пароль $user для $host: " AUTH_PASS
      echo ;;
    password-stdin)
      IFS= read -r AUTH_PASS || true ;;
    key-file|key-stdin)
      mkdir -p "$BASE"
      tmp="$(mktemp -d "$BASE/.key.XXXXXX")"
      PM_DIRS+=("$tmp")
      AUTH_KEY="$tmp/key"
      # Переводы строк Windows и отсутствие последнего перевода строки ssh не принимает
      if [[ "$auth" == "key-file" ]]; then
        [[ -r "$keyfile" ]] || die "нет файла ключа $keyfile"
        (umask 077; printf '%s\n' "$(tr -d '\r' < "$keyfile")" > "$AUTH_KEY")
      else
        (umask 077; printf '%s\n' "$(tr -d '\r')" > "$AUTH_KEY")
      fi
      if grep -q 'PuTTY-User-Key-File' "$AUTH_KEY"; then
        die "это ключ PuTTY (.ppk). Сконвертируй в PuTTYgen: Conversions -> Export OpenSSH key"
      fi
      grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$AUTH_KEY" || die "нужен приватный ключ OpenSSH (-----BEGIN ... PRIVATE KEY-----), а не .pub"
      ssh-keygen -y -P "" -f "$AUTH_KEY" >/dev/null 2>&1 \
        || die "ключ не читается: защищён паролем или повреждён. Снять пароль: ssh-keygen -p -f <ключ>" ;;
  esac
  # Дальше stdin не нужен: ssh в фоновых задачах не должен его читать
  exec </dev/null
  AUTH_MODE="password"
  if [[ -n "$AUTH_KEY" ]]; then AUTH_MODE="key"; elif [[ "$auth" == "installed" ]]; then AUTH_MODE="installed"; fi
  if [[ "$AUTH_MODE" == "password" && -z "$AUTH_PASS" ]]; then die "пароль пустой"; fi
}

# Раздаёт ключ на узлы из массивов IM_NAME IM_HOST IM_ADDR IM_USER IM_PORT IM_TITLE, способ
# входа в IM_MODE: password (IM_PASS), key (файл ключа в IM_KEY) или installed (ключ iof уже
# положен вручную). Удачные узлы дописывает в nodes.conf.
# Код 0, если добавлен хотя бы один узел
onboard_nodes() {
  local j target ok=0
  local failed=()
  mkdir -p "$BASE"
  chmod 700 "$BASE"
  ensure_ssh_key
  if [[ " ${IM_MODE[*]} " == *" password "* ]]; then ensure_sshpass; fi
  touch "$NODES_FILE"

  echo "Раздаю SSH-ключ на узлы: ${#IM_NAME[@]}, одновременно до $PARALLEL"
  pmap push_key_job "${!IM_NAME[@]}"
  for j in "${!IM_NAME[@]}"; do
    if pm_ok "$j"; then
      target="${IM_USER[$j]}@${IM_HOST[$j]}"
      if [[ "${IM_PORT[$j]}" != "22" ]]; then target="$target:${IM_PORT[$j]}"; fi
      printf '%s | %s | %s | %s\n' "${IM_NAME[$j]}" "${IM_ADDR[$j]}" "$target" "${IM_TITLE[$j]}" >> "$NODES_FILE"
      ok=$((ok + 1))
    else
      failed+=("$j")
    fi
  done
  echo "Добавлено в nodes.conf: $ok"
  if (( ${#failed[@]} > 0 )); then
    echo "Не удалось (${#failed[@]}), в nodes.conf не попали:"
    for j in "${failed[@]}"; do
      printf '  %-20s %-16s %s\n' "${IM_NAME[$j]}" "${IM_HOST[$j]}" "$(pm_err "$j" | tail -n 1)"
    done
  fi
  (( ok > 0 ))
}

# Файл: по строке на сервер "имя | ip | пароль root | подпись | ssh-порт", последние два необязательны
cmd_node_import() {
  local file="${1:-}" name ip pw title port seen=" " n=0
  [[ -n "$file" && -f "$file" ]] || die "укажи файл: iof node import servers.txt"
  N_NAME=()
  if nodes_present; then read_nodes; fi
  IM_NAME=(); IM_HOST=(); IM_ADDR=(); IM_USER=(); IM_MODE=(); IM_PASS=(); IM_KEY=(); IM_TITLE=(); IM_PORT=()
  while IFS='|' read -r name ip pw title port || [[ -n "$name" ]]; do
    name="$(trim "$name")"
    if [[ -z "$name" || "$name" == \#* ]]; then continue; fi
    ip="$(trim "${ip:-}")"
    pw="$(trim "${pw:-}")"
    title="$(trim "${title:-}")"
    port="$(trim "${port:-}")"
    n=$((n + 1))
    node_name_ok "$name" || die "строка $n: имя '$name' — только латиница, цифры, точка, дефис, подчёркивание"
    [[ -n "$ip" && -n "$pw" ]] || die "строка $n ($name): нужны IP и пароль"
    host_ok "$ip" || die "строка $n ($name): '$ip' не похож на IPv4 или имя хоста"
    port_ok "${port:-22}" || die "строка $n ($name): порт '$port' вне 1-65535"
    [[ "$seen" != *" $name "* ]] || die "имя '$name' встречается в файле дважды"
    seen+="$name "
    if node_index "$name" >/dev/null 2>&1; then
      echo "Пропускаю $name: уже есть в nodes.conf"
      continue
    fi
    IM_NAME+=("$name"); IM_HOST+=("$ip"); IM_ADDR+=("$ip"); IM_USER+=("root"); IM_MODE+=("password")
    IM_PASS+=("$pw"); IM_KEY+=(""); IM_TITLE+=("${title:-$name}"); IM_PORT+=("${port:-22}")
  done < "$file"
  (( ${#IM_NAME[@]} > 0 )) || die "в файле нет новых узлов"

  onboard_nodes || true
  echo
  echo "Пароли больше не нужны, удали файл: shred -u $file"
  echo "Дальше: sudo iof hy2 install all"
}

# iof node add <имя> <хост> [подпись] [ssh_порт] [--user имя] [--addr адрес_для_клиентов]
#   [--key файл | --key-stdin | --password-stdin | --key-installed]
# Без них пароль спрашивается в терминале. --key-installed: ключ iof уже добавлен на сервер вручную
cmd_node_add() {
  local pos=() user="root" addr="" auth="ask" keyfile="" name host title port
  while (( $# > 0 )); do
    case "$1" in
      --user|--addr|--key)
        [[ $# -ge 2 ]] || die "после $1 нужно значение"
        case "$1" in
          --user) user="$2" ;;
          --addr) addr="$2" ;;
          --key)  auth="key-file"; keyfile="$2" ;;
        esac
        shift 2 ;;
      --key-stdin)      auth="key-stdin"; shift ;;
      --password-stdin) auth="password-stdin"; shift ;;
      --key-installed)  auth="installed"; shift ;;
      -*) die "неизвестный параметр $1" ;;
      *)  pos+=("$1"); shift ;;
    esac
  done
  name="${pos[0]:-}"; host="${pos[1]:-}"; title="${pos[2]:-}"; port="${pos[3]:-22}"
  addr="${addr:-$host}"
  [[ -n "$name" && -n "$host" ]] || die "используй: iof node add <имя> <хост> [подпись] [ssh_порт] [--user имя] [--key файл]"
  node_name_ok "$name" || die "имя: только латиница, цифры, точка, дефис, подчёркивание"
  host_ok "$host" || die "хост '$host': нужен IPv4 или имя хоста (латиница, цифры, точка, дефис)"
  host_ok "$addr" || die "адрес для клиентов '$addr': нужен IPv4 или имя хоста"
  user_ok "$user" || die "пользователь '$user': строчная латиница, цифры, _ и -"
  port_ok "$port" || die "ssh-порт '$port' вне 1-65535"
  title_ok "$title" || die "подпись не может содержать | и перевод строки"
  N_NAME=()
  if nodes_present; then
    read_nodes
    if node_index "$name" >/dev/null; then die "узел '$name' уже есть"; fi
  fi

  read_auth "$auth" "$keyfile" "$user" "$host"
  IM_NAME=("$name"); IM_HOST=("$host"); IM_ADDR=("$addr"); IM_USER=("$user"); IM_MODE=("$AUTH_MODE")
  IM_PASS=("$AUTH_PASS"); IM_KEY=("$AUTH_KEY"); IM_TITLE=("${title:-$name}"); IM_PORT=("$((10#$port))")
  local rc=0
  onboard_nodes || rc=1
  if [[ -n "$AUTH_KEY" ]] && have shred; then shred -u "$AUTH_KEY" 2>/dev/null || true; fi
  (( rc == 0 )) || exit 1
  echo "Дальше: sudo iof hy2 install $name"
}

# Убирает узел из nodes.conf, сам сервер не трогает
cmd_node_del() {
  local name="${1:-}" r
  [[ -n "$name" ]] || die "используй: iof node del <имя>"
  read_nodes
  node_index "$name" >/dev/null || die "узла '$name' нет"
  read_relays
  for r in "${!R_NODE[@]}"; do
    if [[ "${R_NODE[$r]}" == "$name" || "${R_VIA[$r]}" == "$name" ]]; then
      die "узел участвует в ретрансляторе ${R_NODE[$r]} через ${R_VIA[$r]}, сначала: iof relay del ${R_NODE[$r]} ${R_VIA[$r]}"
    fi
  done
  awk -F'|' -v n="$name" '{ k = $1; gsub(/[[:space:]]/, "", k) } k != n' "$NODES_FILE" > "${NODES_FILE}.tmp"
  mv "${NODES_FILE}.tmp" "$NODES_FILE"
  rm -f "$STATE_DIR/$name"
  echo "Узел $name убран из nodes.conf. Сам сервер не трогал."
  echo "Чтобы убрать его из ссылок и ключей: sudo iof refresh"
}

cmd_node_list() {
  read_nodes
  local i
  {
    row "ИМЯ" "АДРЕС" "SSH" "ПОДПИСЬ"
    for i in "${!N_NAME[@]}"; do
      row "${N_NAME[$i]}" "${N_ADDR[$i]}" "${N_SSH[$i]}" "${N_TITLE[$i]}"
    done
  } | table
  echo
  echo "Всего узлов: ${#N_NAME[@]}"
}

cmd_node() {
  local action="${1:-list}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    add)    cmd_node_add "$@" ;;
    import) cmd_node_import "$@" ;;
    del)    cmd_node_del "$@" ;;
    list)   cmd_node_list ;;
    *)      die "используй: iof node add | import | del | list" ;;
  esac
}


# Hysteria2: iof hy2 ...
# Группа ссылок = один файл $HY2_DIR/<логин>.txt со ссылками на все узлы и ретрансляторы.

hy2_add_job() {
  local i="$1" remark="$HY2_ADD_LABEL"
  if [[ -n "${N_TITLE[$i]}" ]]; then remark="$HY2_ADD_LABEL | ${N_TITLE[$i]}"; fi
  run_on "${N_SSH[$i]}" n_hy2_add "$HY2_ADD_NAME" "$HY2_ADD_PASS" "$remark" "${N_ADDR[$i]}"
}

hy2_del_job() { run_on "${N_SSH[$1]}" n_hy2_del "$HY2_DEL_NAME"; }

# Создаёт или пересобирает группу ссылок. Повторный запуск с той же подписью безопасен
hy2_add() {
  local label="${1:-}"
  [[ -n "$label" ]] || die "укажи подпись: iof hy2 add \"Подпись\""
  # | разделяет подпись и узел в названии ссылки, табуляция — поля index.tsv
  title_ok "$label" && [[ "$label" != *$'\t'* ]] || die "подпись не может содержать |, табуляцию и перевод строки"
  read_nodes
  mkdir -p "$HY2_DIR"
  chmod 700 "$HY2_DIR"

  local name out tmp i link ok=0 r ni vi rl
  local node_link=() failed=()
  name="$(name_for "$label")"
  HY2_ADD_NAME="$name"
  HY2_ADD_PASS="$(gen_pass)"
  HY2_ADD_LABEL="$label"
  out="$HY2_DIR/$name.txt"
  tmp="$(mktemp)"

  echo "Создаю на узлах: ${#N_NAME[@]}" >&2
  pmap hy2_add_job "${!N_NAME[@]}"
  for i in "${!N_NAME[@]}"; do
    link="$(pm_out "$i")"
    if pm_ok "$i" && [[ "$link" == hy2://* ]]; then
      printf '%s\n' "$link" >> "$tmp"
      node_link[$i]="$link"
      ok=$((ok + 1))
    else
      failed+=("$i")
    fi
  done

  # Ссылка через ретранслятор: та же ссылка узла с адресом и портом ретранслятора
  read_relays
  for r in "${!R_NODE[@]}"; do
    ni="$(node_index "${R_NODE[$r]}")" || continue
    vi="$(node_index "${R_VIA[$r]}")" || continue
    [[ -n "${node_link[$ni]:-}" && "${R_HYL[$r]}" != "-" ]] || continue
    rl="$(sed -E "s#@[^/?]*/#@${N_ADDR[$vi]}:${R_HYL[$r]}/#; s/#.*$//" <<<"${node_link[$ni]}")"
    printf '%s#%s\n' "$rl" "$(n_urlencode "$label | $(node_title "$ni") via $(node_title "$vi")")" >> "$tmp"
  done

  if (( ok == 0 )); then
    rm -f "$tmp"
    if (( ${#failed[@]} > 0 )); then report_failures "${failed[@]}"; fi
    die "ни один узел не выдал ссылку"
  fi

  mv "$tmp" "$out"
  chmod 600 "$out"
  index_set "$HY2_INDEX" "$name" "$label"

  echo
  echo "Подпись: $label"
  echo "Файл:    $out"
  echo
  cat "$out"
  echo
  echo "Скопируй строки выше и добавь в Hiddify из буфера обмена."
  if (( ${#failed[@]} > 0 )); then
    echo
    echo "Не выдали ссылку (${#failed[@]}):"
    report_failures "${failed[@]}"
    echo "Когда починишь, просто повтори команду, дублей не будет."
  fi
}

hy2_del() {
  local label="${1:-}"
  [[ -n "$label" ]] || die "укажи подпись или логин: iof hy2 del \"Подпись\""
  read_nodes
  local name i failed=()
  if [[ -f "$HY2_DIR/$label.txt" ]]; then name="$label"; else name="$(name_for "$label")"; fi
  HY2_DEL_NAME="$name"
  pmap hy2_del_job "${!N_NAME[@]}"
  for i in "${!N_NAME[@]}"; do
    if ! pm_ok "$i"; then failed+=("$i"); fi
  done
  echo "Удалено на узлах: $(( ${#N_NAME[@]} - ${#failed[@]} )) из ${#N_NAME[@]}"
  if (( ${#failed[@]} > 0 )); then
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
  fi
  rm -f "$HY2_DIR/$name.txt"
  if [[ -f "$HY2_INDEX" ]]; then index_set "$HY2_INDEX" "$name"; fi
}

hy2_list() {
  if [[ ! -s "$HY2_INDEX" ]]; then
    echo "Групп ссылок Hysteria2 пока нет"
    return 0
  fi
  {
    row "ЛОГИН" "ПОДПИСЬ" "СОЗДАН" "ФАЙЛ"
    local name label created
    while IFS=$'\t' read -r name label created; do
      row "$name" "$label" "$created" "$HY2_DIR/$name.txt"
    done < "$HY2_INDEX"
  } | table
}

hy2_show() {
  local label="${1:-}" name
  [[ -n "$label" ]] || die "укажи подпись: iof hy2 show \"Hysteria\""
  if [[ -f "$HY2_DIR/$label.txt" ]]; then name="$label"; else name="$(name_for "$label")"; fi
  [[ -f "$HY2_DIR/$name.txt" ]] || die "группа '$label' не найдена, см. iof hy2 list"
  cat "$HY2_DIR/$name.txt"
  if have qrencode; then
    echo
    qrencode -t ANSIUTF8 < "$HY2_DIR/$name.txt"
  fi
}

# Пересобирает все группы ссылок
hy2_refresh() {
  if [[ ! -s "$HY2_INDEX" ]]; then
    echo "Hysteria2: групп ссылок нет"
    return 0
  fi
  local labels=() name label created l
  while IFS=$'\t' read -r name label created; do
    labels+=("$label")
  done < "$HY2_INDEX"
  # hy2_add в подшелле: его die завершил бы всю пересборку на первой неудачной группе
  for l in "${labels[@]}"; do
    echo "Hysteria2: пересобираю '$l'"
    ( trap pm_cleanup EXIT; hy2_add "$l" ) || echo "Не удалось обновить: $l"
  done
}

hy2_restart_job() { run_on "${N_SSH[$1]}" n_hy2_service_restart; }

# Перезапуск Hysteria2 на выбранных узлах. Код 1, если где-то сервис не поднялся
hy2_restart() {
  local i ok=() failed=()
  (( $# > 0 )) || die "укажи узлы: iof hy2 restart node-1   или   iof hy2 restart all"
  read_nodes
  select_nodes "$@"
  pmap hy2_restart_job "${SEL[@]}"
  for i in "${SEL[@]}"; do
    if pm_ok "$i"; then ok+=("${N_NAME[$i]}"); else failed+=("$i"); fi
  done
  echo "Перезапущено: ${#ok[@]}${ok[*]:+ (${ok[*]})}"
  if (( ${#failed[@]} > 0 )); then
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
    return 1
  fi
}

# Только Hysteria2
hy2_status() {
  read_nodes
  select_nodes
  local i rows=()
  probe_all "${SEL[@]}"
  rows+=("$(row "УЗЕЛ" "АДРЕС" "СОСТОЯНИЕ" "ДОСТУП" "ВЕРСИЯ")")
  for i in "${SEL[@]}"; do
    if probe_load "$i"; then
      rows+=("$(row "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(cell_hy2)" "$(cell_hy2_access)" "${P[hy2_ver]:--}")")
    else
      rows+=("$(row "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(c_red "НЕТ СВЯЗИ")" "-" "-")")
    fi
  done
  printf '%s\n' "${rows[@]}" | table
}

hy2_install_job() { run_on "${N_SSH[$1]}" n_hy2_install "$HY2_INST_TPL" "$HY2_INST_CN" "$HY2_INST_FORCE"; }

# CN сертификата, на который ссылается шаблон Hysteria2 $1. Пусто, если сертификата нет
hy2_template_cn() {
  local cert
  cert="$(awk '/^[[:space:]]*cert:/{print $2; exit}' "$1" | tr -d "\"'")"
  if [[ -n "$cert" && -f "$cert" ]]; then
    openssl x509 -noout -subject -in "$cert" 2>/dev/null | sed -nE 's/.*CN[[:space:]]*=[[:space:]]*([^,/]+).*/\1/p' || true
  fi
}

# Установка на узлы. Шаблон: конфиг Hysteria2 управляющего сервера (или $HY2_TEMPLATE),
# CN сертификата берётся из его сертификата (или $HY2_CN, если сертификата здесь нет)
hy2_install() {
  local force=0 a i out tplsrc
  local args=() installed=() skipped=() failed=()
  for a in "$@"; do
    if [[ "$a" == "--force" ]]; then force=1; else args+=("$a"); fi
  done
  (( ${#args[@]} > 0 )) || die "укажи узлы: iof hy2 install all   или   iof hy2 install de-1 'nl-*'"
  read_nodes
  select_nodes "${args[@]}"

  tplsrc="${HY2_TEMPLATE:-/etc/hysteria/config.yaml}"
  [[ -f "$tplsrc" ]] || die "нет шаблона $tplsrc (конфиг Hysteria2 на управляющем сервере)"
  HY2_INST_TPL="$(base64 -w0 "$tplsrc")"
  HY2_INST_FORCE="$force"
  HY2_INST_CN="${HY2_CN:-}"
  if [[ -z "$HY2_INST_CN" ]]; then HY2_INST_CN="$(hy2_template_cn "$tplsrc")"; fi
  HY2_INST_CN="${HY2_INST_CN:-bing.com}"

  echo "Шаблон конфига: $tplsrc (пароль, порт и маскировка будут как на этом сервере)"
  echo "Сертификат: свой на каждом узле, CN=$HY2_INST_CN"
  echo "Устанавливаю Hysteria2 на узлах: ${#SEL[@]}, одновременно до $PARALLEL"
  pmap hy2_install_job "${SEL[@]}"

  for i in "${SEL[@]}"; do
    out="$(pm_out "$i" | tail -n 1)"
    if pm_ok "$i" && [[ "$out" == installed* ]]; then
      installed+=("${N_NAME[$i]} (${out#installed })")
    elif pm_ok "$i" && [[ "$out" == "skip" ]]; then
      skipped+=("${N_NAME[$i]}")
    else
      failed+=("$i")
    fi
  done

  echo
  echo "Установлено: ${#installed[@]}"
  for a in "${installed[@]}"; do echo "  $a"; done
  if (( ${#skipped[@]} > 0 )); then
    echo "Уже стояли и работали, не трогал (${#skipped[@]}): ${skipped[*]}"
    echo "  Перезаписать конфиг по шаблону: iof hy2 install <узлы> --force"
  fi
  if (( ${#failed[@]} > 0 )); then
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
  fi

  # Новые узлы сразу попадают во все существующие группы ссылок
  if (( ${#installed[@]} > 0 )) && [[ -s "$HY2_INDEX" ]]; then
    echo
    echo "Добавляю новые узлы в группы ссылок..."
    hy2_refresh >/dev/null 2>&1 || true
    echo "Готово. Ссылки: sudo iof hy2 list, затем sudo iof hy2 show \"Подпись\""
  fi
}

cmd_hy2() {
  local action="${1:-}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    add)     hy2_add "$@" ;;
    del)     hy2_del "$@" ;;
    list)    hy2_list ;;
    show)    hy2_show "$@" ;;
    refresh) hy2_refresh ;;
    status)  hy2_status ;;
    install) hy2_install "$@" ;;
    restart) hy2_restart "$@" ;;
    *)       die "используй: iof hy2 add | del | list | show | refresh | status | install | restart" ;;
  esac
}


# AmneziaWG 2.0: iof awg ...
# Клиент = папка $AWG_LINKS/<логин> с конфигами по узлам (France.conf), публичными ключами
# (France.pub: "ключ контейнер") и ключами vpn:// в keys.txt.

awg_dir_for() {
  local label="$1"
  if [[ -d "$AWG_LINKS/$label" ]]; then printf '%s' "$AWG_LINKS/$label"; else printf '%s' "$AWG_LINKS/$(name_for "$label")"; fi
}

awg_label_for() {
  local dir="$1" name l
  name="$(basename "$dir")"
  l="$(awk -F'\t' -v n="$name" '$1==n{print $2; exit}' "$AWG_INDEX" 2>/dev/null || true)"
  printf '%s' "${l:-$name}"
}

# Создаёт клиента на узле, если для этого узла ещё нет конфига. Печатает skip или created
awg_add_job() {
  local i="$1" f cfg
  f="$AWG_ADD_DIR/$(node_file_name "$i")"
  if [[ -s "$f" ]]; then
    echo "skip"
    return 0
  fi
  cfg="$(run_on "${N_SSH[$i]}" n_awg_add "$AWG_ADD_LABEL" "${N_ADDR[$i]}")" || return $?
  [[ "$cfg" == IOF\ * && "$cfg" == *"[Interface]"* ]] || { echo "сервер вернул неожиданный ответ" >&2; return 1; }
  printf '%s\n' "${cfg%%$'\n'*}" | cut -d' ' -f2- > "${f%.conf}.pub"
  printf '%s\n' "${cfg#*$'\n'}" > "$f"
  chmod 600 "$f" "${f%.conf}.pub"
  echo "created"
}

awg_add() {
  local label="${1:-}"
  [[ -n "$label" ]] || die "укажи имя клиента: iof awg add \"Мама iPhone\""
  read_nodes
  local name dir i ok=0 skipped=0 failed=() noawg=()
  name="$(name_for "$label")"
  dir="$AWG_LINKS/$name"
  mkdir -p "$dir"
  chmod 700 "$AWG_LINKS" "$dir"
  AWG_ADD_DIR="$dir"
  AWG_ADD_LABEL="$label"

  echo "Создаю клиента на узлах: ${#N_NAME[@]}" >&2
  pmap awg_add_job "${!N_NAME[@]}"
  for i in "${!N_NAME[@]}"; do
    if pm_ok "$i"; then
      ok=$((ok + 1))
      if [[ "$(pm_out "$i")" == "skip" ]]; then skipped=$((skipped + 1)); fi
    elif pm_err "$i" | grep -q 'не найден контейнер AmneziaWG'; then
      noawg+=("${N_NAME[$i]}")
    else
      failed+=("$i")
    fi
  done

  if (( ok == 0 )); then
    rmdir "$dir" 2>/dev/null || true
    if (( ${#failed[@]} > 0 )); then report_failures "${failed[@]}"; fi
    die "ни один сервер не создал клиента"
  fi
  index_set "$AWG_INDEX" "$name" "$label"

  echo
  awg_build_keys "$dir"
  echo
  echo "Клиент AWG: $label (готов на $ok узлах, из них раньше созданных: $skipped)"
  echo "Каждый ключ выше вставь в Amnezia VPN: + , затем Вставить ключ."
  echo "Снова показать ключи:         sudo iof awg keys \"$label\""
  echo "Файлы .conf для WinSCP:       sudo iof awg export \"$label\""
  if (( ${#noawg[@]} > 0 )); then
    echo "Без AmneziaWG, пропущены (${#noawg[@]}): ${noawg[*]}"
  fi
  if (( ${#failed[@]} > 0 )); then
    echo
    echo "Не получилось (${#failed[@]}):"
    report_failures "${failed[@]}"
    echo "Когда починишь, повтори команду, готовые конфиги не пересоздадутся."
  fi
}

# Ключ vpn:// в формате приложения Amnezia VPN из готового .conf: <файл> <публичный ключ> <контейнер> <название>.
# Формат: 4 байта длины JSON (big-endian) + zlib(JSON), всё в base64url без "="
awg_make_key() {
  python3 -c '
import base64, json, struct, sys, zlib

path, pub, container, title = sys.argv[1:5]
iface, peer, sec = {}, {}, None
for line in open(path, encoding="utf-8"):
    s = line.strip()
    if s.startswith("["):
        sec = s
        continue
    if not s or s.startswith("#") or "=" not in s:
        continue
    k, v = s.split("=", 1)
    (iface if sec == "[Interface]" else peer)[k.strip()] = v.strip()

ip = iface["Address"].split("/")[0]
dns = [d.strip() for d in iface.get("DNS", "1.1.1.1, 1.0.0.1").split(",") if d.strip()]
host, port = peer["Endpoint"].rsplit(":", 1)
names = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5"]
params = {k: iface[k] for k in names if k in iface}

priv = iface["PrivateKey"]
srv = peer["PublicKey"]
psk = peer["PresharedKey"]
lines = ["[Interface]", f"Address = {ip}/32", "DNS = $PRIMARY_DNS, $SECONDARY_DNS", f"PrivateKey = {priv}"]
lines += [f"{k} = {params[k]}" for k in names if k in params]
lines += ["", "[Peer]", f"PublicKey = {srv}", f"PresharedKey = {psk}",
          "AllowedIPs = 0.0.0.0/0, ::/0", f"Endpoint = {host}:{port}", "PersistentKeepalive = 25", ""]

last = dict(params)
last.update({
    "allowed_ips": ["0.0.0.0/0", "::/0"],
    "clientId": pub,
    "client_ip": ip,
    "client_priv_key": priv,
    "client_pub_key": pub,
    "config": "\n".join(lines),
    "hostName": host,
    "mtu": "1376",
    "persistent_keep_alive": "25",
    "port": int(port),
    "psk_key": psk,
    "server_pub_key": srv,
})
awg = dict(params)
awg.update({
    "last_config": json.dumps(last, indent=4, ensure_ascii=False, sort_keys=True),
    "port": port,
    "subnet_address": ip.rsplit(".", 1)[0] + ".0",
    "transport_proto": "udp",
})
if container == "amnezia-awg2":
    awg["protocol_version"] = "2"
root = {
    "containers": [{"awg": awg, "container": container}],
    "defaultContainer": container,
    "description": title,
    "dns1": dns[0] if dns else "1.1.1.1",
    "dns2": dns[1] if len(dns) > 1 else (dns[0] if dns else "1.0.0.1"),
    "hostName": host,
    "nameOverriddenByUser": True,
}
data = json.dumps(root, indent=4, ensure_ascii=False, sort_keys=True).encode()
blob = struct.pack(">I", len(data)) + zlib.compress(data)
print("vpn://" + base64.urlsafe_b64encode(blob).decode().rstrip("="))
' "$1" "$2" "$3" "$4"
}

# Печатает ключи vpn:// для всех конфигов клиента (узлы и ретрансляторы) и сохраняет в keys.txt
awg_build_keys() {
  local dir="$1" i f meta pub container title priv out key
  have python3 || die "нужен python3"
  read_nodes
  out="$dir/keys.txt"
  : > "$out"
  chmod 600 "$out"
  for i in "${!N_NAME[@]}"; do
    f="$dir/$(node_file_name "$i")"
    [[ -s "$f" ]] || continue
    title="${N_TITLE[$i]:-${N_NAME[$i]}}"
    # Для клиентов, созданных до появления .pub, ключ вычисляется на узле
    if [[ ! -s "${f%.conf}.pub" ]]; then
      priv="$(awk -F'=' '/^[[:space:]]*PrivateKey[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$f")"
      if meta="$(run_on "${N_SSH[$i]}" n_awg_pubkey "$priv" 2>/dev/null)" && [[ -n "$meta" ]]; then
        printf '%s\n' "$meta" > "${f%.conf}.pub"
        chmod 600 "${f%.conf}.pub"
      else
        echo "== $title: не удалось получить публичный ключ, сервер недоступен" >&2
        continue
      fi
    fi
    read -r pub container < "${f%.conf}.pub"
    if key="$(awg_make_key "$f" "$pub" "${container:-amnezia-awg2}" "$title")"; then
      printf '%s\n%s\n\n' "== $title" "$key" | tee -a "$out"
    else
      echo "== $title: не удалось собрать ключ" >&2
    fi
  done

  # Конфиги через ретрансляторы: конфиг узла с Endpoint ретранслятора, пересоздаются каждый раз
  local r ni vi base rf
  rm -f "$dir"/*_via_*.conf
  read_relays
  for r in "${!R_NODE[@]}"; do
    ni="$(node_index "${R_NODE[$r]}")" || continue
    vi="$(node_index "${R_VIA[$r]}")" || continue
    [[ "${R_AWL[$r]}" != "-" ]] || continue
    f="$dir/$(node_file_name "$ni")"
    [[ -s "$f" && -s "${f%.conf}.pub" ]] || continue
    base="$(node_file_name "$vi")"
    rf="${f%.conf}_via_${base%.conf}.conf"
    sed -E "s#^[[:space:]]*Endpoint[[:space:]]*=.*#Endpoint = ${N_ADDR[$vi]}:${R_AWL[$r]}#" "$f" > "$rf"
    chmod 600 "$rf"
    title="$(node_title "$ni") via $(node_title "$vi")"
    read -r pub container < "${f%.conf}.pub"
    if key="$(awg_make_key "$rf" "$pub" "${container:-amnezia-awg2}" "$title")"; then
      printf '%s\n%s\n\n' "== $title" "$key" | tee -a "$out"
    else
      echo "== $title: не удалось собрать ключ" >&2
    fi
  done
}

awg_keys() {
  local label="${1:-}" dir
  [[ -n "$label" ]] || die "укажи имя клиента: iof awg keys \"Мама iPhone\""
  dir="$(awg_dir_for "$label")"
  [[ -d "$dir" ]] || die "клиент '$label' не найден, см. iof awg list"
  awg_build_keys "$dir"
  echo "Каждый ключ вставь в Amnezia VPN: + , затем Вставить ключ."
}

# Пересобирает ключи всех клиентов (после смены узлов или ретрансляторов)
awg_refresh() {
  local name label created
  if [[ ! -s "$AWG_INDEX" ]]; then
    echo "AWG: клиентов нет"
    return 0
  fi
  while IFS=$'\t' read -r name label created; do
    if [[ -d "$AWG_LINKS/$name" ]]; then
      awg_build_keys "$AWG_LINKS/$name" >/dev/null
      echo "AWG: ключи для '$label' пересобраны (sudo iof awg keys \"$label\")"
    fi
  done < "$AWG_INDEX"
}

awg_del_job() {
  local i="$1" f pub=""
  f="$AWG_DEL_DIR/$(node_file_name "$i")"
  if [[ -s "${f%.conf}.pub" ]]; then read -r pub _ < "${f%.conf}.pub"; fi
  run_on "${N_SSH[$i]}" n_awg_del "$AWG_DEL_LABEL" "$pub"
}

awg_del() {
  local label="${1:-}"
  [[ -n "$label" ]] || die "укажи имя клиента: iof awg del \"Мама iPhone\""
  read_nodes
  local dir i failed=()
  dir="$(awg_dir_for "$label")"
  AWG_DEL_DIR="$dir"
  AWG_DEL_LABEL="$label"
  if [[ -d "$dir" ]]; then AWG_DEL_LABEL="$(awg_label_for "$dir")"; fi
  pmap awg_del_job "${!N_NAME[@]}"
  for i in "${!N_NAME[@]}"; do
    if ! pm_ok "$i" && ! pm_err "$i" | grep -q 'не найден контейнер AmneziaWG'; then failed+=("$i"); fi
  done
  rm -rf "$dir"
  index_set "$AWG_INDEX" "$(basename "$dir")"
  echo "Клиент '$AWG_DEL_LABEL' удалён. Ошибок: ${#failed[@]}"
  if (( ${#failed[@]} > 0 )); then report_failures "${failed[@]}"; fi
}

# Конфиги клиента и QR-коды, второй аргумент оставляет один узел: iof awg show "Имя" France
awg_show() {
  local label="${1:-}" only="${2:-}" dir f
  [[ -n "$label" ]] || die "укажи имя клиента: iof awg show \"Мама iPhone\" [France]"
  dir="$(awg_dir_for "$label")"
  [[ -d "$dir" ]] || die "клиент '$label' не найден, см. iof awg list"
  for f in "$dir"/*.conf; do
    [[ -f "$f" ]] || continue
    if [[ -n "$only" && "$(basename "$f" .conf)" != "$only" ]]; then continue; fi
    echo "== $(basename "$f" .conf)"
    cat "$f"
    echo
    if have qrencode; then
      qrencode -t ANSIUTF8 < "$f"
    fi
  done
  if ! have qrencode; then echo "Для QR-кодов установи qrencode: sudo apt install -y qrencode"; fi
}

# Копия конфигов и keys.txt в домашнюю папку пользователя, вызвавшего sudo
awg_export() {
  local label="${1:-}" dir user home dest
  [[ -n "$label" ]] || die "укажи имя клиента: iof awg export \"Мама iPhone\""
  dir="$(awg_dir_for "$label")"
  [[ -d "$dir" ]] || die "клиент '$label' не найден, см. iof awg list"
  user="${SUDO_USER:-}"
  [[ -n "$user" && "$user" != "root" ]] || die "запусти через sudo от своего пользователя"
  home="$(getent passwd "$user" | cut -d: -f6)"
  dest="$home/iof-export/$(basename "$dir")"
  mkdir -p "$dest"
  cp "$dir"/*.conf "$dest"/
  if [[ -s "$dir/keys.txt" ]]; then cp "$dir/keys.txt" "$dest"/; fi
  chown -R "$user:" "$home/iof-export"
  chmod 700 "$home/iof-export" "$dest"
  chmod 600 "$dest"/*
  echo "Скопировано в $dest"
  ls -1 "$dest"
  echo "Забери файлы через WinSCP и удали папку: rm -rf ~/iof-export"
}

awg_list() {
  if [[ ! -s "$AWG_INDEX" ]]; then
    echo "Клиентов AWG, созданных через iof, пока нет"
    return 0
  fi
  {
    row "ИМЯ" "СОЗДАН" "КОНФИГИ" "ПАПКА"
    local name label created files
    while IFS=$'\t' read -r name label created; do
      files="$(cd "$AWG_LINKS/$name" 2>/dev/null && ls -1 *.conf 2>/dev/null | sed 's/\.conf$//' | paste -sd, - || true)"
      row "$label" "$created" "${files:--}" "$AWG_LINKS/$name"
    done < "$AWG_INDEX"
  } | table
}

awg_clients_job() { run_on "${N_SSH[$1]}" n_awg_clients; }

# Все клиенты каждого сервера, включая созданные в приложении Amnezia
awg_clients() {
  read_nodes
  select_nodes
  local i
  pmap awg_clients_job "${SEL[@]}"
  for i in "${SEL[@]}"; do
    echo "== ${N_NAME[$i]} (${N_ADDR[$i]})"
    if pm_ok "$i"; then
      { row "АДРЕС" "ИМЯ" "ПОДКЛЮЧАЛСЯ" "КЛЮЧ" "СОСТОЯНИЕ"; pm_out "$i"; } | table
    else
      echo "   не удалось получить список: $(pm_err "$i" | tail -n 1)"
    fi
    echo
  done
}

awg_status() {
  read_nodes
  select_nodes
  local i rows=()
  probe_all "${SEL[@]}"
  rows+=("$(row "УЗЕЛ" "АДРЕС" "СОСТОЯНИЕ" "КЛИЕНТОВ" "ОНЛАЙН (3 мин)")")
  for i in "${SEL[@]}"; do
    if probe_load "$i"; then
      rows+=("$(row "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(cell_awg)" "${P[awg_peers]:--}" "${P[awg_online]:--}")")
    else
      rows+=("$(row "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(c_red "НЕТ СВЯЗИ")" "-" "-")")
    fi
  done
  printf '%s\n' "${rows[@]}" | table
}

cmd_awg() {
  local action="${1:-}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    add)     awg_add "$@" ;;
    del)     awg_del "$@" ;;
    keys)    awg_keys "$@" ;;
    show)    awg_show "$@" ;;
    export)  awg_export "$@" ;;
    list)    awg_list ;;
    clients) awg_clients ;;
    refresh) awg_refresh ;;
    status)  awg_status ;;
    *)       die "используй: iof awg add | del | keys | show | export | list | clients | refresh | status" ;;
  esac
}


# VLESS: iof vless ... (WIP, команд пока нет)

cmd_vless() {
  echo "VLESS: в разработке (WIP), команд пока нет."
  return 2
}


# Ретрансляторы: iof relay add | del | list | apply
# Общие для протоколов: на ретрансляторе пересылаются порты Hysteria2 и AWG выбранного узла.

# Строки правил для ретранслятора $1 из relays.conf
relay_rules_for() {
  local via="$1" r ni
  read_relays
  for r in "${!R_NODE[@]}"; do
    [[ "${R_VIA[$r]}" == "$via" ]] || continue
    ni="$(node_index "${R_NODE[$r]}")" || continue
    if [[ "${R_HYL[$r]}" != "-" ]]; then printf 'udp %s %s %s\n' "${R_HYL[$r]}" "${N_ADDR[$ni]}" "${R_HYD[$r]}"; fi
    if [[ "${R_AWL[$r]}" != "-" ]]; then printf 'udp %s %s %s\n' "${R_AWL[$r]}" "${N_ADDR[$ni]}" "${R_AWD[$r]}"; fi
  done
}

relay_apply_via() {
  local via="$1" vi rules=()
  vi="$(node_index "$via")" || die "узел '$via' не найден в nodes.conf"
  mapfile -t rules < <(relay_rules_for "$via")
  run_on "${N_SSH[$vi]}" n_relay_apply "${rules[@]}"
}

relay_line_del() {
  grep -v -E "^[[:space:]]*${1}[[:space:]]*\|[[:space:]]*${2}[[:space:]]*\|" "$RELAYS_FILE" > "${RELAYS_FILE}.tmp" || true
  mv "${RELAYS_FILE}.tmp" "$RELAYS_FILE"
}

# Порты узла берутся из n_status, на ретрансляторе подбираются свободные
relay_add() {
  local node="${1:-}" via="${2:-}" ni vi r hyd awd ports=() need=0 hyl="-" awl="-"
  [[ -n "$node" && -n "$via" ]] || die "используй: iof relay add <узел> <через_узел>, например: iof relay add france netherlands"
  read_nodes
  ni="$(node_index "$node")" || die "узла '$node' нет в nodes.conf"
  vi="$(node_index "$via")" || die "узла '$via' нет в nodes.conf"
  [[ "$ni" != "$vi" ]] || die "узел не может ретранслировать сам себя"
  read_relays
  for r in "${!R_NODE[@]}"; do
    if [[ "${R_NODE[$r]}" == "$node" && "${R_VIA[$r]}" == "$via" ]]; then
      die "ретранслятор $node через $via уже есть, см. iof relay list"
    fi
  done

  echo "Узнаю порты на $node..."
  probe "$ni" || die "узел $node не отвечает"
  hyd="${P[hy2_port]:-}"
  [[ -n "$hyd" ]] || die "на $node не найден конфиг Hysteria2"
  awd="-"
  if [[ "${P[awg_state]}" == "running" && "${P[awg_port]}" =~ ^[0-9]+$ ]]; then awd="${P[awg_port]}"; fi
  need=1
  if [[ "$awd" != "-" ]]; then need=2; fi

  echo "Подбираю свободные порты на $via..."
  mapfile -t ports < <(run_on "${N_SSH[$vi]}" n_free_ports "$need")
  (( ${#ports[@]} == need )) || die "не удалось подобрать порты на $via"
  hyl="${ports[0]}"
  if [[ "$awd" != "-" ]]; then awl="${ports[1]}"; fi

  if [[ ! -f "$RELAYS_FILE" ]]; then
    printf '# узел | через узел | hy2: порт ретранслятора | порт узла | awg: порт ретранслятора | порт узла\n' > "$RELAYS_FILE"
  fi
  printf '%s | %s | %s | %s | %s | %s\n' "$node" "$via" "$hyl" "$hyd" "$awl" "$awd" >> "$RELAYS_FILE"

  echo "Настраиваю пересылку на $via..."
  if ! relay_apply_via "$via"; then
    relay_line_del "$node" "$via"
    die "не удалось настроить ретранслятор на $via, запись удалена"
  fi

  echo
  echo "Готово: $(node_title "$ni") via $(node_title "$vi")"
  echo "  Hysteria2: ${N_ADDR[$vi]}:$hyl -> ${N_ADDR[$ni]}:$hyd"
  if [[ "$awl" != "-" ]]; then echo "  AWG:       ${N_ADDR[$vi]}:$awl -> ${N_ADDR[$ni]}:$awd"; fi
  echo
  echo "Пересобираю ссылки и ключи..."
  cmd_refresh
  echo
  echo "Новые ссылки Hysteria2: sudo iof hy2 show \"Подпись\""
  echo "Новые ключи AWG:        sudo iof awg keys \"Имя\""
  echo "Если у хостера $via есть файрвол в панели, открой там UDP $hyl${awl:+ и $awl}."
}

relay_del() {
  local node="${1:-}" via="${2:-}"
  [[ -n "$node" && -n "$via" ]] || die "используй: iof relay del <узел> <через_узел>"
  read_nodes
  [[ -f "$RELAYS_FILE" ]] || die "ретрансляторов нет"
  if ! grep -qE "^[[:space:]]*${node}[[:space:]]*\|[[:space:]]*${via}[[:space:]]*\|" "$RELAYS_FILE"; then
    die "ретранслятора $node через $via нет, см. iof relay list"
  fi
  relay_line_del "$node" "$via"
  relay_apply_via "$via" || echo "Внимание: на $via не удалось обновить правила, выполни потом iof relay apply"
  echo "Ретранслятор $node через $via удалён. Пересобираю ссылки и ключи..."
  cmd_refresh
}

relay_list() {
  read_nodes
  read_relays
  if (( ${#R_NODE[@]} == 0 )); then
    echo "Ретрансляторов нет. Добавить: iof relay add france netherlands"
    return 0
  fi
  local r ni vi st awg
  {
    row "УЗЕЛ" "ЧЕРЕЗ" "HY2 ДЛЯ КЛИЕНТОВ" "AWG ДЛЯ КЛИЕНТОВ" "СОСТОЯНИЕ НА РЕТРАНСЛЯТОРЕ"
    for r in "${!R_NODE[@]}"; do
      ni="$(node_index "${R_NODE[$r]}")" || continue
      vi="$(node_index "${R_VIA[$r]}")" || continue
      if st="$(run_on "${N_SSH[$vi]}" n_relay_status 2>/dev/null)"; then
        st="служба ${st% *}, правил ${st#* }"
      else
        st="нет связи"
      fi
      awg="-"
      if [[ "${R_AWL[$r]}" != "-" ]]; then awg="${N_ADDR[$vi]}:${R_AWL[$r]}"; fi
      row "${R_NODE[$r]}" "${R_VIA[$r]}" "${N_ADDR[$vi]}:${R_HYL[$r]}" "$awg" "$st"
    done
  } | table
}

# Заново записывает правила на всех ретрансляторах (после смены IP узла или переустановки)
cmd_relay_apply() {
  read_nodes
  read_relays
  local vias=() v r
  for r in "${!R_VIA[@]}"; do
    if [[ " ${vias[*]} " != *" ${R_VIA[$r]} "* ]]; then vias+=("${R_VIA[$r]}"); fi
  done
  (( ${#vias[@]} > 0 )) || { echo "Ретрансляторов нет"; return 0; }
  for v in "${vias[@]}"; do
    echo "== $v"
    relay_apply_via "$v" || echo "   ошибка"
  done
}

cmd_relay() {
  local action="${1:-list}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    add)   relay_add "$@" ;;
    del)   relay_del "$@" ;;
    list)  relay_list ;;
    apply) cmd_relay_apply ;;
    *)     die "используй: iof relay add | del | list | apply" ;;
  esac
}


# Аудит безопасности: iof audit run | show | cron, для панели iof api audit.
# Блоки: server («Аудит сервера») и dpi («Защита от РКН»: насколько узел заметен для фильтров
# и зондов). Узлы отдают факты (n_audit_server, n_audit_dpi), оценку каждой проверки ставят
# audit_eval_server и audit_eval_dpi здесь: так консоль, Telegram и панель видят одно и то же.
# Блок dpi ещё смотрит на узел снаружи, с управляющего сервера (audit_outside). Результат лежит
# в $AUDIT_DIR/<блок>.json, история запусков в history.jsonl, оба файла ведёт python3 (AUDIT_PY).
# Узлы аудит не меняет, поэтому во время переноса управления он разрешён, как check

# Справочник проверок для панели и iof audit show, строки через TAB:
#  B блок заголовок;  G блок группа заголовок;  K id блок группа название «почему это важно»
audit_catalog() {
  local b="server"
  g() { printf 'G\t%s\t%s\t%s\n' "$b" "$1" "$2"; }
  k() { printf 'K\t%s\t%s\t%s\t%s\t%s\n' "$1" "$b" "$2" "$3" "$4"; }
  printf 'B\tserver\tАудит сервера\n'
  g ssh "SSH"
  g net "Сеть и защита от подбора"
  g upd "Обновления"
  g sys "Система"
  k ssh_root ssh "Вход root по SSH" \
    "Имя root известно заранее, поэтому пароль подбирают в первую очередь к нему. Вход только по ключу подбором не взять. iof заходит на узлы по ключу, пароль root ему не нужен."
  k ssh_password ssh "Вход по паролю" \
    "Пароль можно подобрать или подсмотреть, ключ нельзя. Боты перебирают пароли SSH на любом сервере круглые сутки."
  k ssh_port ssh "Порт SSH" \
    "На порт 22 приходит основной поток автоматического подбора. При входе только по ключу это шум в журнале, при входе по паролю — риск."
  k ssh_keys ssh "Вход по ключу" \
    "По ключу iof выполняет команды на узле. Если authorized_keys доступен на запись другим пользователям, в него можно дописать чужой ключ."
  k firewall net "Файрвол" \
    "Без запрета по умолчанию снаружи доступно всё, что слушает порт, в том числе службы, поставленные случайно. Файрвол хостера (security group) с узла не виден: если он есть, это предупреждение можно оставить."
  k ban net "Блокировка подбора" \
    "fail2ban или CrowdSec блокируют адрес после нескольких неудачных входов. При входе по паролю это основная защита от подбора, при входе только по ключу — чистый журнал."
  k ban_port net "Порт sshd в fail2ban" \
    "Если jail sshd следит не за тем портом, на котором слушает SSH, блокировка адреса не закрывает ему SSH."
  k auth_fail net "Неудачные входы за сутки" \
    "Много попыток значит, что сервер перебирают. При входе только по ключу они безвредны."
  k ports net "Слушающие порты" \
    "Каждый открытый порт — это служба, которую можно атаковать и по которой узел можно опознать. Ожидаемые: SSH, Hysteria2, контейнер AmneziaWG, порты ретранслятора. То, что слушает только 127.0.0.1, снаружи недоступно."
  k updates upd "Ожидающие обновления" \
    "Обновления безопасности закрывают известные уязвимости. iof-nightly ставит их каждую ночь, если он запланирован в cron."
  k reboot upd "Перезагрузка" \
    "Новое ядро и системные библиотеки начинают работать только после перезагрузки. iof-nightly перезагружает узел после обновления."
  k nightly upd "Ночное обслуживание" \
    "iof-nightly обновляет пакеты и перезагружает узел. Если он давно не отрабатывал, узел остаётся без обновлений."
  k sudo_log sys "Журнал sudo" \
    "По журналу sudo видно, кто и какие команды выполнял от root. Без него не разобраться, что происходило на сервере."
  k pwquality sys "Требования к паролям" \
    "pam_pwquality не даёт задать короткий или простой пароль. Важно там, где по паролю входят в SSH или вызывают sudo."
  k suid sys "SUID-файлы" \
    "SUID-файл выполняется с правами владельца, обычно root. Лишний такой файл — способ повысить права, его же оставляют после взлома."

  # Блок dpi. Тексты не обещают, что узел не найдут: проверка показывает, чем он заметен
  b="dpi"
  printf 'B\tdpi\tЗащита от РКН (ТСПУ)\n'
  g hy2 "Hysteria2"
  g awg "AmneziaWG"
  g probe "Что видно снаружи"
  g scan "Сканеры"
  g rep "Репутация адреса"
  g hyg "Гигиена"
  k hy2_mode hy2 "Режим маскировки" \
    "Без маскировки Hysteria2 — это QUIC, который на запрос по HTTP/3 отвечает ошибкой 404: такой сервер легко отличить от сайта. Salamander делает трафик похожим на случайный шум, но на QUIC он уже не похож. Без Salamander с masquerade сервер выглядит как сайт с HTTP/3, но QUIC к зарубежным адресам фильтры режут. Это выбор, а не ошибка."
  k hy2_masq hy2 "Masquerade" \
    "Тому, кто пришёл на порт Hysteria2 без пароля, сервер показывает сайт из masquerade. Если цель не отвечает, зонд увидит ошибку вместо сайта. Под Salamander masquerade снаружи не виден."
  k hy2_quic hy2 "Ответ на зонд QUIC" \
    "Управляющий сервер отправляет на порт Hysteria2 пакет QUIC с несуществующей версией. Обычный сервер QUIC отвечает согласованием версий, под Salamander порт так не отвечает. Так видно, что получит тот, кто зондирует порт, и доходит ли до узла UDP."
  k hy2_port hy2 "Порт" \
    "HTTP/3 работает на 443/udp, QUIC на другом порту встречается редко и заметнее. Под Salamander трафик не похож на QUIC на любом порту."
  k hy2_hop hy2 "Смена портов (port hopping)" \
    "Клиент раз в полминуты меняет порт, поэтому блокировка одного порта или долгого потока UDP не обрывает связь. Для этого нужен диапазон портов на сервере и он же в ссылке клиента."
  k hy2_template hy2 "Конфиг и шаблон" \
    "iof hy2 install ставит на узлы конфиг по шаблону с управляющего сервера. Если конфиг узла потом правили вручную, маскировка на нём отличается от остальных, а повторная установка затрёт правки."
  k awg_params awg "Параметры обфускации" \
    "AmneziaWG отличается от WireGuard мусорными пакетами (Jc, Jmin, Jmax), добавками к пакетам (S1–S4) и своими заголовками (H1–H4). С нулями и заголовками 1, 2, 3, 4 это обычный WireGuard, который фильтры узнают по первому пакету."
  k awg_same awg "Одинаковые параметры на узлах" \
    "С одинаковыми параметрами трафик узлов выглядит одинаково: признак, найденный для одного узла, подойдёт ко всем. Сравнение идёт по хэшу, сами значения в панель и в файлы не попадают."
  k tcp_web probe "Порты 80 и 443/tcp" \
    "Сайт с HTTP/3 отвечает и по обычному HTTPS на 443/tcp. Если на 443/udp есть QUIC, а 443/tcp закрыт, сервер на сайт не похож. Посторонняя служба на этих портах показывает зонду свои заголовки и сертификат."
  k tls_cert probe "Сертификат" \
    "Сертификат видит любой, кто подключится к порту. Самоподписанный сертификат на имя известного сайта на адресе, который этому сайту не принадлежит, — заметный признак."
  k icmp probe "Ответ на ping" \
    "Обычный сервер чаще отвечает на ping. Молчание само ничего не выдаёт: так настроено у многих хостеров."
  k names probe "Имя сервера и PTR" \
    "Обратную запись DNS (PTR) видит любой по адресу узла, имя сервера попадает в приветствия служб. Слова vpn, proxy, wg в них говорят о назначении сервера."
  k banners probe "Лишние порты снаружи" \
    "Служба на лишнем порту отвечает приветствием с названием и версией программы. По нему сканер понимает, что стоит на сервере."
  k panel probe "Панель iof-web" \
    "Панель управляет всеми узлами от root. Она должна слушать только 127.0.0.1 и открываться через SSH-туннель: на внешнем адресе её найдёт любой сканер."
  k blocklist scan "Блок-лист сканеров" \
    "Список адресов, с которых узлы сканируют и зондируют. Если пакеты от них отбрасывать, сканер видит закрытый сервер. iof пока только проверяет, применён ли список на узле."
  k asn rep "Сеть и хостер" \
    "Сети крупных хостеров VPS фильтры знают и относятся к ним строже, чем к домашним. Это справка: изменить её можно только переездом к другому хостеру."
  k registry rep "Адрес в реестре" \
    "Если адрес узла есть в выгрузке реестра блокировок, у части провайдеров он уже недоступен и клиенты до него не дойдут."
  k journald hyg "Срок хранения журнала" \
    "В журнале остаются адреса клиентов и время подключений. Если сервер изымут или взломают, журнал покажет, кто им пользовался. Чем короче срок хранения, тем меньше можно узнать."
  k hy2_log hyg "Журнал Hysteria2" \
    "На уровне info Hysteria2 пишет в журнал адрес каждого подключившегося клиента, на debug ещё и адреса, куда он ходит."
  k awg_log hyg "Лог контейнера AmneziaWG" \
    "Docker по умолчанию пишет вывод контейнера в файл без ограничения размера. Со временем он занимает диск и хранит историю дольше, чем нужно."
  k time hyg "Время" \
    "При сбитых часах не проходит проверка сертификатов, а время в журналах узлов не сходится между собой."
  unset -f g k
}

# Ответ n_audit_* в A, повторяющиеся ключи в массивы A_*
declare -A A=()
A_LISTEN=(); A_EXPECT=(); A_RELAY=(); A_SUID=(); A_BLOCK=(); A_AWGP=(); A_AWGI=(); A_BANNER=()

audit_parse() {
  local line k v
  A=(); A_LISTEN=(); A_EXPECT=(); A_RELAY=(); A_SUID=(); A_BLOCK=(); A_AWGP=(); A_AWGI=(); A_BANNER=()
  while IFS= read -r line; do
    [[ "$line" == ?*=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    v="${v//$'\t'/ }"
    case "$k" in
      listen)    A_LISTEN+=("$v") ;;
      expect)    A_EXPECT+=("$v") ;;
      relay)     A_RELAY+=("$v") ;;
      suid)      A_SUID+=("$v") ;;
      hy2_block) A_BLOCK+=("$v") ;;
      awg_p)     A_AWGP+=("$v") ;;
      awg_i)     A_AWGI+=("$v") ;;
      x_banner)  A_BANNER+=("$v") ;;
      *)         A["$k"]="$v" ;;
    esac
  done <<<"$1"
}

# Слушающие порты узла по фактам в A_LISTEN, A_EXPECT и A_RELAY, аргументы — порты SSH узла.
# AP_EXP — ожидаемые, AP_EXTRA — лишние (их номера в AP_XP), AP_LOC — слушают только loopback,
# AP_REL — правила ретранслятора (их порты в AP_GOT), AP_OPEN — что должен пропускать файрвол, кроме SSH
AP_EXP=(); AP_EXTRA=(); AP_XP=(); AP_LOC=(); AP_REL=(); AP_GOT=(); AP_OPEN=()
audit_ports() {
  local l e proto port bind proc found
  AP_EXP=(); AP_EXTRA=(); AP_XP=(); AP_LOC=(); AP_REL=(); AP_GOT=(); AP_OPEN=()
  for l in "${A_LISTEN[@]}"; do
    IFS='|' read -r proto port bind proc <<<"$l"
    if [[ "$bind" == "loopback" ]]; then AP_LOC+=("$port/$proto ${proc:-?}"); continue; fi
    if [[ "$proc" == "sshd" || ( "$proto" == "tcp" && " $* " == *" $port "* ) ]]; then AP_EXP+=("$port/$proto SSH"); continue; fi
    if [[ "$proc" == "hysteria" ]]; then AP_EXP+=("$port/$proto Hysteria2"); AP_OPEN+=("$port/$proto"); continue; fi
    found=""
    for e in "${A_EXPECT[@]}"; do
      if [[ "$e" == "$proto|$port|"* ]]; then found="${e##*|}"; break; fi
    done
    if [[ -n "$found" ]]; then AP_EXP+=("$port/$proto $found"); continue; fi
    if [[ "$proto" == "udp" && ( "$port" == "68" || "$port" == "546" ) ]]; then AP_EXP+=("$port/udp DHCP-клиент"); continue; fi
    AP_EXTRA+=("$port/$proto ${proc:-?}")
    AP_XP+=("$port")
  done
  for e in "${A_EXPECT[@]}"; do
    IFS='|' read -r proto port found <<<"$e"
    AP_OPEN+=("$port/$proto")
  done
  for l in "${A_RELAY[@]}"; do
    IFS='|' read -r proto port found <<<"$l"
    AP_REL+=("$port/$proto → $found")
    AP_GOT+=("$port")
    AP_OPEN+=("$port/$proto")
  done
}

# Строка проверки для AUDIT_PY: id, статус (good, warn, crit, none), значение, подробности,
# как исправить (текст) и команды. В подробностях и командах строки разделяет \x1f
audit_chk() { printf 'C\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-}"; }
audit_lines() { local IFS=$'\x1f'; printf '%s' "$*"; }
# Аргументы через ", "
audit_list() { local s; s="$(audit_lines "$@")"; printf '%s' "${s//$'\x1f'/, }"; }
# Число от узла: всё, что не число, становится нулём, ведущие нули не превращают его в восьмеричное
audit_num() { if [[ "${1:-}" =~ ^[0-9]{1,15}$ ]]; then printf '%s' "$((10#$1))"; else printf '0'; fi; }
audit_when() { date -d "@$1" '+%d.%m.%Y %H:%M' 2>/dev/null || printf '%s' "$1"; }

# Оценка блока «Аудит сервера» для узла с индексом $1 по фактам $2 (вывод n_audit_server).
# Команды в «как исправить» не должны отрезать iof: он заходит на узел по ключу, иногда не под root
audit_eval_server() {
  local i="$1" name="${N_NAME[$1]}" target="${N_SSH[$1]}" user="root" where="На узле от root:"
  local now pw=0 fwd=0 prl keys mode ports=() jp=() exp=() extra=() xp=() loc=() open=() rel=() got=() want=() d=() c=()
  local e p r found st val hint cmd n sec na jails
  local reload="sshd -t && systemctl reload ssh"
  audit_parse "$2"
  now="$(audit_num "${A[now]:-}")"
  if [[ "$target" == *@* ]]; then user="${target%%@*}"; fi
  if [[ "$target" == "local" ]]; then where="На этом сервере от root:"; fi
  val="${A[ssh_ports]:-}"
  # shellcheck disable=SC2086 # порты через запятую в слова
  for p in ${val//,/ }; do
    if port_ok "$p"; then ports+=("$p"); fi
  done
  if [[ "${A[ssh_passwordauthentication]:-}" == "yes" || "${A[ssh_kbdinteractiveauthentication]:-}" == "yes" ]]; then pw=1; fi
  if [[ "${A[fw_policy]:-}" == "deny" ]]; then fwd=1; fi
  prl="${A[ssh_permitrootlogin]:-}"
  keys="$(audit_num "${A[ssh_keys]:-}")"

  # SSH
  if [[ "${A[ssh_conf]:-}" != "yes" ]]; then
    for p in ssh_root ssh_password ssh_port; do
      audit_chk "$p" none "sshd -T не ответил, настройки SSH не прочитать"
    done
  else
    case "$prl" in
      yes)
        if (( pw )); then st="crit"; val="разрешён, в том числе по паролю"; else st="warn"; val="разрешён, пароли выключены"; fi
        if [[ "$target" == "local" ]]; then
          hint="Это управляющий сервер, iof работает на нём без SSH. Если сам заходишь под root, оставь ему вход только по ключу. $where"
          cmd="echo 'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/00-iof-root.conf && $reload"
        elif [[ "$user" == "root" ]]; then
          hint="iof заходит на этот узел под root по ключу, поэтому совсем запрещать root нельзя: оставь ему вход только по ключу. $where"
          cmd="echo 'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/00-iof-root.conf && $reload"
        else
          hint="iof заходит на этот узел под $user, root по SSH ему не нужен. $where"
          cmd="echo 'PermitRootLogin no' > /etc/ssh/sshd_config.d/00-iof-root.conf && $reload"
        fi
        audit_chk ssh_root "$st" "$val" "" "$hint" "$cmd" ;;
      no) audit_chk ssh_root good "запрещён" ;;
      "") audit_chk ssh_root none "нет данных" ;;
      *)  audit_chk ssh_root good "только по ключу ($prl)" ;;
    esac

    if (( ! pw )); then
      audit_chk ssh_password good "выключен"
    else
      val="включён"
      if [[ "${A[ssh_passwordauthentication]:-}" != "yes" ]]; then val="включён через keyboard-interactive"; fi
      if [[ "$prl" == "yes" ]]; then st="crit"; val+=", root тоже"; else st="warn"; val+=", root по паролю нельзя"; fi
      d=()
      if (( keys == 0 )); then
        d+=("В authorized_keys пользователя $user ключей нет: сначала добавь свой ключ, иначе потеряешь доступ к серверу")
      fi
      audit_chk ssh_password "$st" "$val" "$(audit_lines "${d[@]}")" \
        "Сначала убедись, что сам входишь на сервер по ключу: iof уже ходит по ключу, ему пароль не нужен. $where" \
        "printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/00-iof-password.conf && $reload"
    fi

    val="$(audit_list "${ports[@]}")"
    if (( pw )) && [[ " ${ports[*]} " == *" 22 "* ]]; then
      hint="Надёжнее выключить вход по паролю (проверка «Вход по паролю»): тогда порт не важен. Если пароли нужны, порт можно сменить, например на 2222: открой его в файрволе, затем выполни команду ниже."
      if [[ "$target" != "local" ]]; then
        split_target "$target"
        hint+=" После неё на управляющем сервере в /root/iof/nodes.conf поставь узлу $name адрес SSH $T_HOST:2222. $where"
      else
        hint+=" $where"
      fi
      audit_chk ssh_port warn "$val, вход по паролю включён" "" "$hint" \
        "echo 'Port 2222' > /etc/ssh/sshd_config.d/00-iof-port.conf && sshd -t && systemctl daemon-reload && { systemctl restart ssh.socket 2>/dev/null; systemctl restart ssh; }"
    elif (( pw )); then
      audit_chk ssh_port good "$val"
    else
      audit_chk ssh_port good "$val, вход только по ключу"
    fi
  fi

  mode="${A[ssh_keys_mode]:-600}"
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then mode=600; fi
  if [[ "${A[ssh_conf]:-}" == "yes" && "${A[ssh_pubkeyauthentication]:-yes}" != "yes" ]]; then
    audit_chk ssh_keys crit "выключен (PubkeyAuthentication no)" "" "$where" \
      "echo 'PubkeyAuthentication yes' > /etc/ssh/sshd_config.d/00-iof-pubkey.conf && $reload"
  elif (( keys == 0 )); then
    audit_chk ssh_keys warn "у $user нет ключей в authorized_keys" "" \
      "Добавь свой публичный ключ. Со своего компьютера:" "ssh-copy-id $user@${N_ADDR[$i]}"
  elif (( 8#$mode & 8#022 )); then
    audit_chk ssh_keys warn "ключей у $user: $keys, но authorized_keys доступен на запись не только владельцу (права $mode)" "" \
      "$where" "chmod 600 ~$user/.ssh/authorized_keys"
  else
    audit_chk ssh_keys good "включён, ключей у $user: $keys"
  fi

  # Слушающие порты: что ожидаемо, что лишнее, что слушает только loopback. open — порты,
  # которые должен пропускать файрвол, кроме SSH
  if (( ${#ports[@]} == 0 )); then
    ports=(22)
    if [[ "$target" != "local" ]]; then split_target "$target"; ports=("$T_PORT"); fi
  fi
  audit_ports "${ports[@]}"
  exp=("${AP_EXP[@]}"); extra=("${AP_EXTRA[@]}"); xp=("${AP_XP[@]}"); loc=("${AP_LOC[@]}")
  open=("${AP_OPEN[@]}"); rel=("${AP_REL[@]}"); got=("${AP_GOT[@]}")
  for r in "${!R_VIA[@]}"; do
    [[ "${R_VIA[$r]}" == "$name" ]] || continue
    for p in "${R_HYL[$r]}" "${R_AWL[$r]}"; do
      if [[ "$p" != "-" ]]; then want+=("$p"); fi
    done
  done

  # Файрвол. Команды сначала открывают то, что нужно iof и клиентам, и только потом включают запрет
  if [[ -z "${A[fw]:-}" ]]; then
    audit_chk firewall none "нет данных"
  elif (( fwd )); then
    audit_chk firewall good "${A[fw]}: входящие по умолчанию запрещены"
  else
    if [[ "${A[fw]}" == "none" ]]; then
      val="нет, снаружи доступно всё, что слушает порт"
    else
      val="${A[fw]}: правила есть, но входящие по умолчанию разрешены"
    fi
    if (( ${#extra[@]} > 0 )); then st="crit"; val+=", есть лишние порты"; else st="warn"; fi
    c=("apt-get install -y ufw")
    for p in "${ports[@]}"; do c+=("ufw allow $p/tcp"); done
    while IFS= read -r p; do
      if [[ -n "$p" ]]; then c+=("ufw allow $p"); fi
    done < <(printf '%s\n' "${open[@]}" | sort -u)
    c+=("ufw default deny incoming" "ufw --force enable")
    if (( ${#rel[@]} > 0 )); then c+=("systemctl restart iof-relay"); fi
    audit_chk firewall "$st" "$val" "" \
      "Команды сначала открывают порты SSH, Hysteria2, AmneziaWG и ретранслятора этого узла, потом включают запрет остального. Сверь список со своими службами. $where" \
      "$(audit_lines "${c[@]}")"
  fi

  # fail2ban или CrowdSec и порт jail sshd
  jails="${A[f2b_jails]:-}"
  if [[ "${A[f2b]:-}" == "active" ]]; then
    if [[ ",$jails," == *",sshd,"* ]]; then
      audit_chk ban good "fail2ban работает, jail: ${jails//,/, }"
      IFS=',' read -r -a jp <<<"${A[f2b_port]:-}"
      found=""
      for p in "${ports[@]}"; do
        st=""
        for e in "${jp[@]}"; do
          e="${e// /}"
          case "$e" in
            ssh)  e=22 ;;
            *:*)  if [[ "$e" =~ ^([0-9]+):([0-9]+)$ ]] && (( 10#$p >= 10#${BASH_REMATCH[1]} && 10#$p <= 10#${BASH_REMATCH[2]} )); then e="$p"; fi ;;
          esac
          if [[ "$e" == "$p" ]]; then st="ok"; fi
        done
        if [[ -z "$st" ]]; then found+="${found:+,}$p"; fi
      done
      if [[ -z "${A[f2b_port]:-}" ]]; then
        audit_chk ban_port none "порт jail sshd определить не удалось"
      elif [[ -z "$found" ]]; then
        audit_chk ban_port good "совпадает: ${A[f2b_port]}"
      else
        audit_chk ban_port warn "jail следит за ${A[f2b_port]}, а SSH слушает $(audit_list "${ports[@]}")" "" "$where" \
          "printf '[sshd]\nenabled = true\nport = $(audit_lines "${ports[@]}" | tr '\037' ',')\n' > /etc/fail2ban/jail.d/iof-sshd.local && systemctl restart fail2ban"
      fi
    else
      audit_chk ban warn "fail2ban работает, но jail sshd не включён" "" "$where" \
        "printf '[sshd]\nenabled = true\n' > /etc/fail2ban/jail.d/iof-sshd.local && systemctl restart fail2ban"
      audit_chk ban_port none "jail sshd не включён"
    fi
  elif [[ "${A[crowdsec]:-}" == "active" ]]; then
    audit_chk ban good "CrowdSec работает"
    audit_chk ban_port none "у CrowdSec порт не задаётся"
  elif [[ -z "${A[f2b]:-}" ]]; then
    audit_chk ban none "нет данных"
    audit_chk ban_port none "нет данных"
  else
    if (( pw )); then st="crit"; val="нет, а вход по паролю включён"; else st="warn"; val="нет, вход только по ключу"; fi
    audit_chk ban "$st" "$val" "" "В Ubuntu jail sshd включён сразу после установки. $where" \
      "apt-get install -y fail2ban && systemctl enable --now fail2ban"
    audit_chk ban_port none "fail2ban не работает"
  fi

  n="${A[auth_fail]:-}"
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    audit_chk auth_fail none "нет данных (нет journalctl)"
  elif (( ! pw )); then
    audit_chk auth_fail good "$n, вход только по ключу"
  elif (( n < 10 )); then
    audit_chk auth_fail good "$n"
  else
    if (( n > 50 )); then st="crit"; else st="warn"; fi
    audit_chk auth_fail "$st" "$n, вход по паролю включён" "" \
      "Выключи вход по паролю и поставь fail2ban: проверки «Вход по паролю» и «Блокировка подбора»."
  fi

  # Ожидаемые порты идут в подробности, когда значение занято лишними
  d=()
  e=""
  if (( ${#exp[@]} > 0 )); then e="Ожидаемые: $(audit_list "${exp[@]}")"; fi
  if (( ${#rel[@]} > 0 )); then d+=("Ретранслятор (DNAT, без сокета): $(audit_list "${rel[@]}")"); fi
  if (( ${#loc[@]} > 0 )); then d+=("Только локально (loopback): $(audit_list "${loc[@]}")"); fi
  if (( ${#extra[@]} > 0 )); then
    if (( fwd )); then st="warn"; val="лишние: $(audit_list "${extra[@]}") (файрвол закрывает их, если они не разрешены явно)"
    else st="crit"; val="лишние: $(audit_list "${extra[@]}"), файрвола нет"; fi
    audit_chk ports "$st" "$val" "$(audit_lines "$e" "${d[@]}")" \
      "Узнай, что это за служба. Если она не нужна, останови её, иначе закрой порт файрволом. $where" \
      "$(audit_lines "ss -tulnp | grep -E ':($(audit_lines "${xp[@]}" | tr '\037' '|')) '" "systemctl disable --now <служба>")"
  elif [[ "$(printf '%s\n' "${got[@]}" | sort -u)" != "$(printf '%s\n' "${want[@]}" | sort -u)" ]]; then
    audit_chk ports warn "правила ретранслятора на узле не совпадают с relays.conf" "$(audit_lines "$e" "${d[@]}")" \
      "На управляющем сервере:" "sudo iof relay apply"
  elif (( ${#A_LISTEN[@]} == 0 )); then
    audit_chk ports none "нет данных (нет ss)"
  else
    audit_chk ports good "только ожидаемые: $(audit_list "${exp[@]}")" "$(audit_lines "${d[@]}")"
  fi

  # Обновления, перезагрузка, ночное обслуживание
  na="$(audit_num "${A[nightly_at]:-}")"
  if [[ -z "${A[upd_total]:-}" ]]; then
    audit_chk updates none "нет данных (нет apt)"
  else
    n="$(audit_num "${A[upd_total]}")"
    sec="$(audit_num "${A[upd_security]:-}")"
    p="$(audit_num "${A[apt_updated]:-}")"
    d=()
    if (( p > 0 )); then d+=("Списки пакетов обновлялись $(audit_when "$p")"); fi
    if (( n == 0 && p > 0 && now - p > 7 * 86400 )); then
      audit_chk updates warn "неизвестно: списки пакетов не обновлялись больше недели" "$(audit_lines "${d[@]}")" "$where" \
        "apt-get update && apt-get -y upgrade"
    elif (( n == 0 )); then
      audit_chk updates good "нет" "$(audit_lines "${d[@]}")"
    else
      st="warn"
      val="$n, из них безопасности: $sec"
      if (( sec > 0 && now - na > 7 * 86400 )); then st="crit"; val+=", iof-nightly на узле не работал больше недели"; fi
      audit_chk updates "$st" "$val" "$(audit_lines "${d[@]}")" \
        "Чтобы обновления ставились сами каждую ночь, запланируй iof-nightly (проверка «Ночное обслуживание»). Поставить сейчас. $where" \
        "apt-get update && apt-get -y upgrade"
    fi
  fi

  case "${A[reboot]:-}" in
    yes) audit_chk reboot warn "нужна${A[reboot_pkgs]:+ (${A[reboot_pkgs]% })}" "" \
           "Клиенты узла отключатся на минуту. iof-nightly перезагружает узлы сам. $where" "reboot" ;;
    no)  audit_chk reboot good "не нужна" ;;
    *)   audit_chk reboot none "нет данных" ;;
  esac

  hint="На управляющем сервере: sudo crontab -e, строка ниже. Каждую ночь в 4:00 обновятся и перезагрузятся все узлы."
  cmd="0 4 * * * /usr/local/sbin/iof-nightly"
  if (( na == 0 )); then
    audit_chk nightly warn "на этом узле ещё не запускалось" "" "$hint" "$cmd"
  elif (( now - na > 48 * 3600 )); then
    audit_chk nightly warn "давно: последний раз $(audit_when "$na")" "" "$hint" "$cmd"
  elif (( $(audit_num "${A[nightly_err]:-}") > 0 )); then
    audit_chk nightly warn "отработало $(audit_when "$na"), ошибок apt: ${A[nightly_err]}" "" \
      "Что пошло не так, видно в логе. $where" "grep -n '^E: ' /var/log/iof-nightly.log | tail"
  else
    audit_chk nightly good "отработало $(audit_when "$na")"
  fi

  # Система: журнал sudo, требования к паролям, SUID-файлы
  case "${A[sudo_log]:-}" in
    syslog) if [[ "${A[authlog]:-}" == "yes" ]]; then audit_chk sudo_log good "в журнале systemd и /var/log/auth.log"
            else audit_chk sudo_log good "в журнале systemd"; fi ;;
    file)   audit_chk sudo_log good "в отдельном файле (logfile в sudoers)" ;;
    off)    audit_chk sudo_log crit "выключен (Defaults !syslog в sudoers)" "" \
              "Найди эту строку и убери её через visudo. $where" "grep -rn '!syslog' /etc/sudoers /etc/sudoers.d" ;;
    nosudo) audit_chk sudo_log none "sudo не установлен" ;;
    *)      audit_chk sudo_log none "нет данных" ;;
  esac

  n="$(audit_num "${A[pwq_minlen]:-}")"
  d=()
  if (( ! pw )); then d+=("Вход по паролю в SSH выключен: это касается только локальных паролей и sudo"); fi
  if [[ -z "${A[pwq_pam]:-}" ]]; then
    audit_chk pwquality none "нет данных"
  elif [[ "${A[pwq_pam]}" == "yes" ]] && (( n >= 12 )); then
    audit_chk pwquality good "pam_pwquality, минимальная длина $n"
  else
    if [[ "${A[pwq_pam]}" != "yes" ]]; then val="не настроено"
    elif (( n > 0 )); then val="pam_pwquality включён, минимальная длина $n"
    else val="pam_pwquality включён, минимальная длина по умолчанию (8)"; fi
    audit_chk pwquality warn "$val" "$(audit_lines "${d[@]}")" "$where" \
      "apt-get install -y libpam-pwquality && sed -i -E 's/^#? ?minlen.*/minlen = 12/' /etc/security/pwquality.conf"
  fi

  n="$(audit_num "${A[suid_total]:-}")"
  if (( ${#A_SUID[@]} > 0 )); then
    audit_chk suid warn "вне стандартного набора Ubuntu 24.04: ${#A_SUID[@]} из $n" "$(audit_lines "${A_SUID[@]}")" \
      "Узнай, из какого пакета файл. Если он не нужен, сними с него SUID. $where" \
      "$(audit_lines "dpkg -S ${A_SUID[*]:0:5}" "chmod u-s <путь>")"
  elif [[ "${A[suid_done]:-}" == "no" ]]; then
    audit_chk suid none "поиск не уложился в 45 секунд, найдено $n"
  elif [[ -z "${A[suid_total]:-}" ]]; then
    audit_chk suid none "нет данных"
  else
    audit_chk suid good "$n, все из стандартного набора Ubuntu 24.04"
  fi
}

# Блок «Защита от РКН» (dpi): чем узел заметен для фильтров и зондов. Узел отдаёт факты
# (n_audit_dpi), управляющий сервер смотрит на него снаружи (audit_outside) и ставит оценки
# (audit_eval_dpi). Соль запуска AUDIT_SALT живёт только в памяти: хэши с ней годятся для сравнения
# внутри одной проверки, в файлы не пишутся

AUDIT_RUN="server"   # блоки этого запуска через пробел
AUDIT_SALT=""
AUDIT_TPL_SRC=""     # шаблон Hysteria2 на управляющем сервере и хэши его блоков
AUDIT_TPL=""
declare -A AUDIT_AWG=()   # узел -> хэш параметров AmneziaWG в этом запуске

# Проверки снаружи и работа со списками, всё под timeout в вызывающем коде. Режимы:
#  quic <адрес> <порт>     пакет QUIC с несуществующей версией: vn — сервер ответил согласованием
#                          версий, reply — ответил чем-то другим, silent — молчит, closed — порт закрыт
#  banner <адрес> <порт>   open|приветствие службы, closed или filtered
#  whois <адрес> <папка кэша>   состояние|AS|организация|страна; состояние: ok, private, fail.
#                          Запрос идёт на whois.iana.org, оттуда к региональному реестру. Пустая
#                          папка — без кэша (так спрашивается адрес ПК при проверке с ПК)
#  inlist <файл> <адрес>   hit|запись, если адрес есть в списке IP и CIDR, иначе miss
#  trace <адрес> <порт> <отпечаток> <порт Hysteria2 или 0>   токен на stdin. Контроль проверки с ПК:
#                          те же слои до мишени, что проходит probe.ps1 на ПК, JSON в одну строку
AUDIT_NET_PY=$(cat <<'EOF'
import hashlib, ipaddress, json, os, re, socket, ssl, subprocess, sys, time


def quic(host, port):
    # Длинный заголовок, версия из зарезервированных под согласование (RFC 9000, 6.3), пакет
    # дополнен до 1200 байт: сервер QUIC обязан ответить Version Negotiation с версией 0
    # и нашими идентификаторами соединения, поменянными местами
    seen = "silent"
    for _ in range(3):
        dcid, scid = os.urandom(8), os.urandom(8)
        pkt = bytes([0xC0 | (os.urandom(1)[0] & 0x0F)]) + bytes.fromhex("1a2a3a4a") + b"\x08" + dcid + b"\x08" + scid
        pkt += os.urandom(1200 - len(pkt))
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        try:
            s.connect((host, port))
            s.send(pkt)
            data = s.recv(2048)
        except socket.timeout:
            continue
        except ConnectionRefusedError:
            seen = "closed"
            continue
        except OSError:
            continue
        finally:
            s.close()
        if len(data) >= 14 and data[0] & 0x80 and data[1:5] == b"\0\0\0\0" and data[5] == 8 and data[6:14] == scid:
            return "vn"
        seen = "reply"
    return seen


def banner(host, port):
    try:
        s = socket.create_connection((host, port), timeout=3)
    except socket.timeout:
        return "filtered"
    except OSError:
        return "closed"
    data = b""
    try:
        s.settimeout(2)
        try:
            data = s.recv(256)
        except socket.timeout:
            # Служба ждёт запроса первой: спросим как браузер
            s.sendall(b"HEAD / HTTP/1.0\r\n\r\n")
            s.settimeout(3)
            data = s.recv(1024)
    except OSError:
        pass
    finally:
        s.close()
    text = data.decode("latin-1")
    server = re.search(r"^Server:[ \t]*(.+)$", text, re.M | re.I)
    lines = text.strip().splitlines()
    line = "HTTP, Server: " + server.group(1) if server else lines[0] if lines else ""
    clean = "".join(ch if 32 <= ord(ch) < 127 and ch != "|" else "." for ch in line.strip())
    return "open|" + clean[:80]


def ask(server, query):
    with socket.create_connection((server, 43), timeout=8) as s:
        s.settimeout(8)
        s.sendall((query + "\r\n").encode())
        data = b""
        while len(data) < 300000:
            chunk = s.recv(8192)
            if not chunk:
                break
            data += chunk
    # LACNIC и часть старых записей отвечают в latin-1
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")


def field(text, names):
    for name in names:
        m = re.search(r"^%s:[ \t]*(\S.*)$" % name, text, re.M | re.I)
        if m:
            return m.group(1).strip()
    return ""


def whois(ip, cache):
    if not ipaddress.ip_address(ip).is_global:
        return "private|||"
    path = os.path.join(cache, "whois-%s.txt" % ip) if cache else ""
    try:
        if path and time.time() - os.path.getmtime(path) < 86400:
            with open(path, encoding="utf-8") as f:
                return f.read().strip()
    except OSError:
        pass
    try:
        refer = field(ask("whois.iana.org", ip), ["refer", "whois"])
        if not refer:
            return "fail|||"
        # ARIN без «n +» отвечает списком сетей, а не записью
        text = ask(refer, "n + " + ip if "arin" in refer else ip)
        more = re.search(r"^ReferralServer:\s*r?whois://([A-Za-z0-9.-]+)", text, re.M)
        if more:
            text = ask(more.group(1), ip)
    except OSError:
        return "fail|||"
    asn = re.search(r"^(?:origin|OriginAS|aut-num):[ \t]*(AS\d+)", text, re.M | re.I)
    org = field(text, ["org-name", "OrgName", "owner", "descr", "netname", "NetName"])
    out = "ok|%s|%s|%s" % (asn.group(1).upper() if asn else "", org.replace("|", " ")[:60],
                            field(text, ["country"])[:2].upper())
    if not path:
        return out
    try:
        tmp = path + ".%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(out + "\n")
        os.replace(tmp, path)
    except OSError:
        pass
    return out


def inlist(path, ip):
    target = int(ipaddress.IPv4Address(ip))
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            words = raw.split("#", 1)[0].split()
            if not words or ":" in words[0]:
                continue
            addr, _, bits = words[0].partition("/")
            try:
                a, b, c, d = (int(x) for x in addr.split("."))
                n = int(bits) if bits else 32
            except ValueError:
                continue
            if not 0 <= n <= 32 or max(a, b, c, d) > 255:
                continue
            mask = (0xFFFFFFFF << (32 - n)) & 0xFFFFFFFF
            if target & mask == ((a << 24) | (b << 16) | (c << 8) | d) & mask:
                return "hit|" + words[0][:40]
    return "miss"


# Слои до мишени проверки с ПК. Пакеты и порядок те же, что у probe.ps1, иначе контроль
# и ПК сравнивались бы по разным проверкам
FULL = 262144


def ms(t0):
    return int((time.monotonic() - t0) * 1000)


def ping(ip):
    try:
        p = subprocess.run(["ping", "-n", "-c", "3", "-W", "2", ip], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return {"sent": 0, "got": 0, "ms": 0}
    got = re.search(r"(\d+) (?:packets )?received", p.stdout)
    avg = re.search(r"= [\d.]+/([\d.]+)/", p.stdout)
    return {"sent": 3, "got": int(got.group(1)) if got else 0, "ms": int(float(avg.group(1))) if avg else 0}


# Одна попытка: TCP, TLS со сверкой отпечатка, строка с токеном, ответ «OK <IP источника>» и 256 КБ
def conn(ip, port, token, fp):
    r = {"tcp": None, "tls": None, "fp": "", "bytes": 0, "ms": 0, "src": "", "err": ""}
    stage, t0 = "tcp", time.monotonic()
    s = None
    try:
        s = socket.create_connection((ip, port), timeout=5)
        r["tcp"] = ms(t0)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        stage, t0 = "tls", time.monotonic()
        s = ctx.wrap_socket(s)
        r["tls"] = ms(t0)
        r["fp"] = "match" if hashlib.sha256(s.getpeercert(True)).hexdigest() == fp else "mismatch"
        stage, t0 = "data", time.monotonic()
        s.sendall(b"IOF-PROBE " + token + b"\n")
        s.settimeout(6)
        buf, head, n = b"", None, 0
        while (head is None or n < FULL) and time.monotonic() - t0 < 20:
            chunk = s.recv(65536)
            if not chunk:
                r["err"] = "data: closed"
                break
            if head is not None:
                n += len(chunk)
                continue
            buf += chunk
            if b"\n" in buf:
                head, rest = buf.split(b"\n", 1)
                n = len(rest)
            elif len(buf) > 128:
                break
        if head is None or not head.startswith(b"OK "):
            r["err"] = r["err"] or "data: no answer"
        else:
            r["src"] = head[3:].decode("ascii", "replace")[:45]
            if n < FULL and not r["err"]:
                r["err"] = "data: timeout"
        r["bytes"], r["ms"] = min(n, FULL), ms(t0)
    except socket.timeout:
        r["err"] = stage + ": timeout"
    except ssl.SSLError as e:
        r["err"] = stage + ": " + (e.reason or "ssl").lower()
    except OSError as e:
        r["err"] = stage + ": " + (e.strerror or e.__class__.__name__).lower()
    finally:
        if s is not None:
            s.close()
    if r["err"].startswith("data") and not r["ms"]:
        r["ms"] = ms(t0)
    return r


# Пакет UDP с меткой: маленький или 1200 байт с заголовком как у QUIC v1 Initial
def packet(shaped, mark, nonce):
    body = mark + nonce
    if not shaped:
        return body + os.urandom(24)
    pkt = b"\xc3\x00\x00\x00\x01\x08" + os.urandom(8) + b"\x08" + os.urandom(8) + b"\x00\x44\xb0" + body
    return pkt + os.urandom(1200 - len(pkt))


def udp(ip, port, token, shaped):
    mark, zero = b"IOFP" + token, b"IOFP" + b"\0" * len(token)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((ip, port))
    sent, got, closed = [], set(), False
    for _ in range(5):
        nonce = os.urandom(8)
        sent.append(nonce)
        try:
            s.send(packet(shaped, mark, nonce))
        except OSError:
            closed = True
        time.sleep(0.05)
    s.settimeout(0.3)
    end = time.monotonic() + 2
    while time.monotonic() < end and len(got) < len(sent):
        try:
            data = s.recv(2048)
        except socket.timeout:
            continue
        except ConnectionRefusedError:
            closed = True
            continue
        except OSError:
            continue
        i = data.find(zero)
        if i >= 0:
            got.add(data[i + len(zero):i + len(zero) + 8])
    s.close()
    return {"sent": len(sent), "got": len(got & set(sent)), "closed": closed}


def trace(ip, port, fp, hy2):
    token = sys.stdin.readline().strip().encode()
    out = {"icmp": ping(ip), "conn": [conn(ip, port, token, fp) for _ in range(3)],
           "udp": udp(ip, port, token, False), "quic": udp(ip, port, token, True),
           "hy2": quic(ip, hy2) if hy2 else ""}
    return json.dumps(out, separators=(",", ":"))


mode = sys.argv[1]
if mode == "trace":
    print(trace(sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5])))
elif mode == "quic":
    print(quic(sys.argv[2], int(sys.argv[3])))
elif mode == "banner":
    print(banner(sys.argv[2], int(sys.argv[3])))
elif mode == "whois":
    print(whois(sys.argv[2], sys.argv[3]))
elif mode == "inlist":
    print(inlist(sys.argv[2], sys.argv[3]))
EOF
)

# Список $1 (blocklist или registry) по адресу $2 в кэше $AUDIT_DIR/cache: скачивается заново не чаще
# раза в сутки и когда адрес поменяли. Неудачная загрузка оставляет прошлую копию и пометку .err
audit_fetch() {
  local f="$AUDIT_DIR/cache/$1.txt" url="$2" age=999999
  if [[ -z "$url" ]]; then return 0; fi
  if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then echo "адрес должен начинаться с http:// или https://" > "$f.err"; return 0; fi
  if [[ -s "$f" ]]; then age=$(( $(date +%s) - $(stat -c %Y "$f") )); fi
  if (( age < 86400 )) && [[ ! -f "$f.err" && "$(cat "$f.url" 2>/dev/null || true)" == "$url" ]]; then return 0; fi
  if timeout 120 curl -fsSL --max-time 100 --max-filesize 200000000 -o "$f.new" -- "$url" 2>/dev/null \
     && grep -qE '^[[:space:]]*[0-9]{1,3}(\.[0-9]{1,3}){3}' "$f.new"; then
    mv -f "$f.new" "$f"
    printf '%s\n' "$url" > "$f.url"
    rm -f "$f.err"
  else
    rm -f "$f.new"
    echo "не скачался или в нём нет адресов" > "$f.err"
  fi
}

# Состояние списка $1 для оценки: "<записей> <когда скачан>" или пусто, если копии нет
audit_list_info() {
  local f="$AUDIT_DIR/cache/$1.txt"
  if [[ -s "$f" ]]; then
    printf '%s %s' "$(grep -cE '^[[:space:]]*[0-9]{1,3}(\.[0-9]{1,3}){3}' "$f" || true)" "$(stat -c %Y "$f")"
  fi
}

# Перед опросом блока dpi: соль запуска, хэши блоков шаблона Hysteria2, списки в кэше
audit_dpi_prepare() {
  local tpl="${HY2_TEMPLATE:-/etc/hysteria/config.yaml}"
  AUDIT_SALT="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  AUDIT_TPL_SRC=""
  AUDIT_TPL=""
  if [[ -f "$tpl" ]]; then
    AUDIT_TPL_SRC="$tpl"
    AUDIT_TPL="$(n_audit_hy2_blocks "$tpl" "$AUDIT_SALT")"
  fi
  mkdir -p "$AUDIT_DIR/cache"
  chmod 700 "$AUDIT_DIR" "$AUDIT_DIR/cache"
  audit_fetch blocklist "$BLOCKLIST_URL"
  audit_fetch registry "$REGISTRY_URL"
}

# Порт $2 на адресе $1 по TCP: open, closed (отказ) или filtered (нет ответа)
audit_tcp() {
  local rc=0
  timeout 4 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null || rc=$?
  case "$rc" in
    0)   echo open ;;
    124) echo filtered ;;
    *)   echo closed ;;
  esac
}

# Ответ веб-сервера по адресу $1: "код|заголовок Server"
audit_http() {
  timeout 10 curl -sk -m 6 -o /dev/null -D - -- "$1" 2>/dev/null \
    | awk '{ sub(/\r$/, "") } NR == 1 { code = $2 } tolower($1) == "server:" { sub(/^[^:]*:[ \t]*/, ""); srv = $0 }
           END { gsub(/[|]/, " ", srv); print code "|" substr(srv, 1, 60) }' || true
}

# Ведёт ли имя $1 на адрес $2: yes, no или unknown (не имя, шаблон *.домен, DNS не ответил)
audit_points_here() {
  local got
  if ! host_ok "$1" || [[ "$1" != *.* || "$1" =~ ^[0-9.]+$ ]]; then echo unknown; return 0; fi
  got="$(timeout 5 getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1 }' | sort -u || true)"
  if [[ -z "$got" ]]; then echo no
  elif grep -qxF "$2" <<<"$got"; then echo yes
  else echo no; fi
}

# Взгляд на узел снаружи, с управляющего сервера: audit_outside <индекс узла> <факты n_audit_dpi>.
# Печатает строки x_ключ=значение:
#  x_ip (адрес узла IPv4), x_tcp80 и x_tcp443 (см. audit_tcp), x_http80 и x_http443 (см. audit_http),
#  x_cert_cn, x_cert_issuer, x_cert_self yes/no, x_cert_here (см. audit_points_here) — сертификат
#  на 443/tcp, x_hy2cert_here — ведёт ли сюда имя из сертификата Hysteria2, x_icmp yes/no/noping,
#  x_ptr, x_quic (см. AUDIT_NET_PY), x_h3 (ответ на GET по HTTP/3, если curl его умеет),
#  x_whois, x_registry и повторяющиеся x_banner=порт|состояние|приветствие для лишних портов TCP
audit_outside() {
  local i="$1" addr="${N_ADDR[$1]}" ip p s cn n st80 st443 sport=22 sni=() sans=()
  audit_parse "$2"
  ip="$addr"
  if [[ ! "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    ip="$(timeout 5 getent ahostsv4 "$addr" 2>/dev/null | awk '{ print $1; exit }' || true)"
  fi
  echo "x_ip=$ip"
  if [[ -z "$ip" ]]; then return 0; fi

  st80="$(audit_tcp "$ip" 80)"
  st443="$(audit_tcp "$ip" 443)"
  printf '%s\n' "x_tcp80=$st80" "x_tcp443=$st443"
  if have curl; then
    if [[ "$st80" == "open" ]]; then echo "x_http80=$(audit_http "http://$ip/")"; fi
    if [[ "$st443" == "open" ]]; then echo "x_http443=$(audit_http "https://$ip/")"; fi
  fi
  # Сертификат на 443/tcp. SNI — адрес узла, если это имя
  if [[ "$st443" == "open" ]] && have openssl; then
    if [[ "$addr" != "$ip" ]]; then sni=(-servername "$addr"); fi
    s="$(timeout 10 openssl s_client -connect "$ip:443" "${sni[@]}" </dev/null 2>/dev/null \
      | openssl x509 -noout -subject -issuer -ext subjectAltName -nameopt RFC2253 2>/dev/null || true)"
    cn="$(sed -n 's/^subject=.*CN=\([^,]*\).*/\1/p' <<<"$s" | head -n 1)"
    echo "x_cert_cn=$cn"
    echo "x_cert_issuer=$(sed -n 's/^issuer=//p' <<<"$s" | sed -E 's/.*(^|,)O=([^,]*).*/\2/; s/.*(^|,)CN=([^,]*).*/\2/' | head -n 1)"
    if [[ -n "$s" && "$(sed -n 's/^subject=//p' <<<"$s")" == "$(sed -n 's/^issuer=//p' <<<"$s")" ]]; then
      echo "x_cert_self=yes"
    else
      echo "x_cert_self=no"
    fi
    # Имя из сертификата ведёт сюда, если так у CN или у одного из первых имён SAN
    p="unknown"
    mapfile -t sans < <(grep -oE 'DNS:[^, ]+' <<<"$s" | cut -d: -f2 | head -n 5 || true)
    for n in "$cn" "${sans[@]}"; do
      if [[ "$n" == "$addr" && "$addr" != "$ip" ]]; then p="yes"; break; fi
      case "$(audit_points_here "$n" "$ip")" in
        yes) p="yes"; break ;;
        no)  p="no" ;;
      esac
    done
    echo "x_cert_here=$p"
  fi
  if [[ -n "${A[hy2_cert_cn]:-}" ]]; then echo "x_hy2cert_here=$(audit_points_here "${A[hy2_cert_cn]}" "$ip")"; fi

  if have ping; then
    if timeout 8 ping -n -c 2 -W 2 "$ip" >/dev/null 2>&1; then echo "x_icmp=yes"; else echo "x_icmp=no"; fi
  else
    echo "x_icmp=noping"
  fi
  echo "x_ptr=$(timeout 5 getent hosts "$ip" 2>/dev/null | awk '{ print $2; exit }' || true)"

  # Hysteria2 снаружи: зонд согласования версий QUIC. Настоящий GET по HTTP/3 — только если curl
  # на этом сервере собран с HTTP/3 (в Ubuntu 24.04 нет) и узел без Salamander
  p="${A[hy2_port]:-}"
  if [[ "${A[hy2]:-}" == "yes" ]] && port_ok "$p"; then
    echo "x_quic=$(timeout 12 python3 -c "$AUDIT_NET_PY" quic "$ip" "$p" 2>/dev/null || echo error)"
    if [[ "${A[hy2_obfs]:-none}" != "salamander" && "$(curl --version 2>/dev/null || true)" == *HTTP3* ]]; then
      cn="${A[hy2_cert_cn]:-}"
      if host_ok "$cn" && [[ "$cn" == *.* ]]; then
        echo "x_h3=$(timeout 12 curl -sk --http3-only -m 8 -o /dev/null -w '%{http_code}' --resolve "$cn:$p:$ip" "https://$cn:$p/" 2>/dev/null || true)"
      else
        echo "x_h3=$(timeout 12 curl -sk --http3-only -m 8 -o /dev/null -w '%{http_code}' "https://$ip:$p/" 2>/dev/null || true)"
      fi
    fi
  fi

  # Приветствия лишних портов TCP, не больше шести
  if [[ "${N_SSH[$i]}" != "local" ]]; then split_target "${N_SSH[$i]}"; sport="$T_PORT"; fi
  audit_ports "$sport"
  n=0
  for s in "${AP_EXTRA[@]}"; do
    p="${s%%/*}"
    if [[ "$s" != "$p/tcp "* ]] || (( n >= 6 )); then continue; fi
    n=$((n + 1))
    echo "x_banner=$p|$(timeout 10 python3 -c "$AUDIT_NET_PY" banner "$ip" "$p" 2>/dev/null || echo error)"
  done

  echo "x_whois=$(timeout 25 python3 -c "$AUDIT_NET_PY" whois "$ip" "$AUDIT_DIR/cache" 2>/dev/null || echo 'fail|||')"
  if [[ -n "$REGISTRY_URL" && -s "$AUDIT_DIR/cache/registry.txt" ]]; then
    echo "x_registry=$(timeout 60 python3 -c "$AUDIT_NET_PY" inlist "$AUDIT_DIR/cache/registry.txt" "$ip" 2>/dev/null || echo error)"
  fi
}

# Слово в имени сервера или PTR, которое выдаёт назначение: печатает его, код 1 — такого нет
audit_vpn_word() {
  local s="${1,,}"
  if [[ "$s" =~ (vpn|proxy|hysteria|wireguard|amnezia|vless|xray|v2ray|shadowsocks|trojan) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$s" =~ (^|[^a-z])(wg|awg|hy2|socks|tunnel)([^a-z]|$) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
  else
    return 1
  fi
}

audit_int() { [[ "${1:-}" =~ ^[0-9]{1,10}$ ]]; }

# Параметры обфускации AmneziaWG из A_AWGP. AWG_PLAIN=1 — это обычный WireGuard: полей нет или
# Jc = 0, S1–S4 = 0 и H1–H4 = 1, 2, 3, 4. Иначе в AWG_BAD то, что вне границ (в AWG_BADK названия
# полей), сами значения в текст не попадают. Границы: Jc 1–128, 0 ≤ Jmin < Jmax < 1280, S1 до 1132,
# S2 до 1188, S3 до 1216, S4 до 32, S1 + 56 ≠ S2, H1–H4 — числа или диапазоны начало-конец в
# 5–2147483647 без пересечений. Числа взяты из документации GL.iNet, запрет пересечений H1–H4 —
# из документации Amnezia (ссылки в security-plan.md)
AWG_PLAIN=0; AWG_BAD=(); AWG_BADK=()
audit_awg_check() {
  local l n j v lo hi max std=1 hstd=1 cross=0
  local -A p=() hlo=() hhi=()
  AWG_PLAIN=0; AWG_BAD=(); AWG_BADK=()
  for l in "${A_AWGP[@]}"; do p["${l%%|*}"]="${l#*|}"; done
  if [[ "${p[Jc]:-0}" != "0" ]]; then std=0; fi
  for n in 1 2 3 4; do
    if [[ "${p[S$n]:-0}" != "0" ]]; then std=0; fi
    v="${p[H$n]:-$n}"
    if [[ "$v" != "$n" && "$v" != "$n-$n" ]]; then hstd=0; fi
  done
  if (( std && hstd )); then AWG_PLAIN=1; return 0; fi

  v="${p[Jc]:-}"
  if ! audit_int "$v" || (( 10#$v < 1 || 10#$v > 128 )); then
    AWG_BADK+=("Jc"); AWG_BAD+=("Jc: нужно от 1 до 128, иначе мусорные пакеты перед рукопожатием не идут")
  fi
  lo="${p[Jmin]:-}"; hi="${p[Jmax]:-}"
  if ! audit_int "$lo" || ! audit_int "$hi" || (( 10#$lo >= 10#$hi || 10#$hi >= 1280 )); then
    AWG_BADK+=("Jmin и Jmax"); AWG_BAD+=("Jmin и Jmax: нужно 0 ≤ Jmin < Jmax < 1280")
  fi
  for n in 1 2 3 4; do
    case "$n" in 1) max=1132 ;; 2) max=1188 ;; 3) max=1216 ;; *) max=32 ;; esac
    v="${p[S$n]:-}"
    # S3 и S4 появились в AmneziaWG 2.0, у контейнера 1.x их нет
    if [[ -z "$v" ]] && (( n > 2 )); then continue; fi
    if ! audit_int "$v" || (( 10#$v > max )); then
      AWG_BADK+=("S$n"); AWG_BAD+=("S$n: нужно от 0 до $max")
    elif (( n <= 2 && 10#$v == 0 )); then
      AWG_BADK+=("S$n"); AWG_BAD+=("S$n выключен: пакет рукопожатия той же длины, что у WireGuard")
    fi
  done
  if audit_int "${p[S1]:-}" && audit_int "${p[S2]:-}" && (( 10#${p[S1]} + 56 == 10#${p[S2]} )); then
    AWG_BADK+=("S1 и S2"); AWG_BAD+=("S1 + 56 = S2: пакеты начала и ответа рукопожатия выходят одной длины")
  fi
  if (( hstd )); then
    AWG_BADK+=("H1–H4"); AWG_BAD+=("H1–H4 как у WireGuard (1, 2, 3, 4): заголовки пакетов не меняются")
    return 0
  fi
  for n in 1 2 3 4; do
    v="${p[H$n]:-}"
    if [[ "$v" =~ ^([0-9]{1,10})(-([0-9]{1,10}))?$ ]]; then
      lo=$((10#${BASH_REMATCH[1]}))
      hi="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
      hi=$((10#$hi))
      hlo[$n]=$lo; hhi[$n]=$hi
      if (( lo > hi || lo < 5 || hi > 2147483647 )); then
        AWG_BADK+=("H$n"); AWG_BAD+=("H$n: нужно число или диапазон начало-конец в пределах 5–2147483647")
      fi
    else
      AWG_BADK+=("H$n"); AWG_BAD+=("H$n не задан или записан не числом и не диапазоном начало-конец")
    fi
  done
  for n in 1 2 3; do
    for (( j = n + 1; j <= 4; j++ )); do
      if [[ -n "${hlo[$n]:-}" && -n "${hlo[$j]:-}" ]] && (( hlo[$n] <= hhi[$j] && hlo[$j] <= hhi[$n] )); then cross=1; fi
    done
  done
  if (( cross )); then AWG_BADK+=("H1–H4"); AWG_BAD+=("H1–H4: диапазоны пересекаются, а должны быть раздельными"); fi
}

# Оценка блока «Защита от РКН» для узла с индексом $1 по фактам $2 (вывод n_audit_dpi и
# audit_outside). Там, где правильного ответа нет, ставится «внимание» или «нет данных» с
# объяснением компромисса. Секретов в тексте нет: только «задано» и совпадения
audit_eval_dpi() {
  local i="$1" name="${N_NAME[$1]}" target="${N_SSH[$1]}" addr="${N_ADDR[$1]}" where="На узле от root:" me=""
  local now ip port="" hy2=0 obfs=0 masq="none" k v s st val hint cmd n w at diff d=() same=() open=() shut=()
  local conf="/etc/hysteria/config.yaml" restart="systemctl restart hysteria-server"
  local -A tpl=() mine=()
  audit_parse "$2"
  now="$(audit_num "${A[now]:-}")"
  ip="${A[x_ip]:-}"
  if [[ "$target" == "local" ]]; then
    where="На этом сервере от root:"
    me="Проверено с самого управляющего сервера, а не снаружи: файрвол на пути не участвует"
  fi

  # Hysteria2
  if [[ "${A[hy2]:-}" != "yes" ]]; then
    for k in hy2_mode hy2_masq hy2_quic hy2_port hy2_hop hy2_template; do
      audit_chk "$k" none "Hysteria2 на узле не установлена"
    done
  else
    hy2=1
    port="${A[hy2_port]:-443}"
    masq="${A[hy2_masq]:-none}"
    if [[ "${A[hy2_obfs]:-none}" == "salamander" ]]; then obfs=1; fi

    if (( obfs )) && [[ "${A[hy2_obfs_pass]:-}" != "set" ]]; then
      audit_chk hy2_mode warn "Salamander включён, но пароль не задан" "" \
        "Задай obfs.salamander.password в $conf и перезапусти службу. Тот же пароль должен быть в ссылках клиентов: после правки на управляющем сервере sudo iof hy2 refresh. $where" \
        "nano $conf && $restart"
    elif (( obfs )); then
      audit_chk hy2_mode good "Salamander: трафик похож на случайный шум" \
        "Другой вариант — без Salamander с masquerade: сервер выглядит как сайт с HTTP/3. Это иной компромисс, а не улучшение"
    elif [[ "$masq" != "none" ]]; then
      audit_chk hy2_mode good "без Salamander, с masquerade: сервер выглядит как сайт с HTTP/3" \
        "QUIC к зарубежным адресам фильтры могут резать. Salamander прячет QUIC, но делает трафик непохожим ни на что: это иной компромисс, а не улучшение"
    else
      audit_chk hy2_mode warn "ни Salamander, ни masquerade: на запрос по HTTP/3 сервер отвечает 404" "" \
        "Выбери одно. Masquerade: сервер показывает зонду чужой сайт, ссылки клиентов не меняются (команда ниже, адрес сайта замени на тот, что открывается с узла). Salamander: блок obfs в конфиге и новые ссылки клиентам. Чтобы новые узлы ставились так же, внеси блок и в шаблон на управляющем сервере. $where" \
        "$(audit_lines "printf '\nmasquerade:\n  type: proxy\n  proxy:\n    url: https://example.org/\n    rewriteHost: true\n' >> $conf" "$restart")"
    fi

    d=()
    if [[ -n "${A[x_h3]:-}" ]]; then d+=("GET по HTTP/3 с управляющего сервера: ответ ${A[x_h3]}"); fi
    if (( obfs )); then
      val="под Salamander masquerade снаружи не виден"
      if [[ "$masq" != "none" ]]; then val+=" (в конфиге: $masq)"; fi
      audit_chk hy2_masq none "$val"
    else
      case "$masq" in
        proxy)
          s="${A[hy2_masq_url]:-}"
          v="${A[hy2_masq_code]:-}"
          if [[ "$v" =~ ^[23] ]]; then
            audit_chk hy2_masq good "proxy на $s, цель с узла отвечает ($v)" "$(audit_lines "${d[@]}")"
          elif [[ -z "$v" ]]; then
            audit_chk hy2_masq none "proxy на $s, цель проверить нечем: на узле нет curl" "$(audit_lines "${d[@]}")"
          else
            audit_chk hy2_masq warn "proxy на $s, цель с узла не отвечает (код ${v/#000/нет ответа})" "$(audit_lines "${d[@]}")" \
              "Зонд вместо сайта получит ошибку. Проверь адрес в masquerade.proxy.url или выбери другой сайт. $where" \
              "curl -sI -m 8 '$s' | head -n 1"
          fi ;;
        file)
          if [[ "${A[hy2_masq_dir]:-}" == "yes" ]]; then
            audit_chk hy2_masq good "file: сервер отдаёт файлы из каталога" "$(audit_lines "${d[@]}")"
          else
            audit_chk hy2_masq warn "file: каталога из masquerade.file.dir на узле нет" "$(audit_lines "${d[@]}")" \
              "Зонд вместо сайта получит ошибку. Создай каталог с файлами сайта или поправь путь в $conf."
          fi ;;
        string)
          audit_chk hy2_masq good "string: сервер отдаёт заданный текст" "$(audit_lines "${d[@]}")" ;;
        none)
          audit_chk hy2_masq warn "не настроен: на запрос по HTTP/3 сервер отвечает 404" "$(audit_lines "${d[@]}")" \
            "Как добавить, написано в проверке «Режим маскировки»." ;;
        *)
          audit_chk hy2_masq none "тип $masq, оценки для него нет" "$(audit_lines "${d[@]}")" ;;
      esac
    fi

    d=("$me")
    if [[ "${A[hy2_state]:-}" != "active" ]]; then d+=("Служба hysteria-server не работает (${A[hy2_state]:-нет данных})"); fi
    v="${A[x_quic]:-}"
    if [[ -z "$ip" ]]; then
      audit_chk hy2_quic none "адрес узла $addr не определился как IPv4"
    elif [[ -z "$v" || "$v" == "error" ]]; then
      audit_chk hy2_quic none "зонд не выполнился"
    elif (( obfs )) && [[ "$v" == "vn" ]]; then
      audit_chk hy2_quic warn "Salamander в конфиге, а порт $port/udp отвечает как обычный сервер QUIC" "$(audit_lines "${d[@]}")" \
        "Похоже, служба не перезапущена после правки конфига и работает без Salamander. $where" "$restart"
    elif (( obfs )) && [[ "$v" == "reply" ]]; then
      audit_chk hy2_quic good "порт $port/udp ответил не как QUIC: так и выглядит Salamander" "$(audit_lines "${d[@]}")"
    elif (( obfs )); then
      audit_chk hy2_quic good "порт $port/udp на зонд QUIC не отвечает: так и выглядит Salamander" \
        "$(audit_lines "${d[@]}" "Доходит ли до узла UDP, под Salamander этот зонд не показывает")"
    elif [[ "$v" == "vn" ]]; then
      audit_chk hy2_quic good "порт $port/udp отвечает как сервер QUIC (согласование версий)" "$(audit_lines "${d[@]}")"
    else
      case "$v" in
        closed) val="порт $port/udp закрыт: на нём никто не слушает или файрвол отвечает отказом" ;;
        reply)  val="порт $port/udp ответил не как QUIC" ;;
        *)      val="порт $port/udp на зонд QUIC не ответил" ;;
      esac
      audit_chk hy2_quic warn "$val" "$(audit_lines "${d[@]}")" \
        "UDP от управляющего сервера до узла не дошёл: порт закрыт файрволом узла или хостера, либо QUIC режется по пути. Клиенты могут видеть то же самое. $where" \
        "$(audit_lines "systemctl is-active hysteria-server" "ss -uln | grep ':$port '" "ufw status | grep -w $port")"
    fi

    if [[ -n "${A[hy2_range]:-}" ]]; then
      audit_chk hy2_port none "диапазон портов ${A[hy2_range]}/udp (смена портов), один порт оценивать нечего"
    elif (( obfs )); then
      audit_chk hy2_port none "$port/udp: под Salamander трафик не похож на QUIC на любом порту"
    elif [[ "$port" == "443" ]]; then
      audit_chk hy2_port good "443/udp, как у HTTP/3"
    else
      audit_chk hy2_port warn "$port/udp, а HTTP/3 обычно на 443" "" \
        "QUIC на нестандартном порту заметнее. Зато 443/udp фильтруют чаще: если так задумано, оставь. Сменить порт: команда на узле, затем на управляющем сервере sudo iof hy2 refresh (ссылки клиентов изменятся). $where" \
        "sed -i -E 's/^listen:.*/listen: :443/' $conf && $restart"
    fi

    if [[ -n "${A[hy2_range]:-}" ]]; then
      audit_chk hy2_hop good "диапазон ${A[hy2_range]} в listen, Hysteria2 перенаправляет его сама"
    elif [[ -n "${A[hy2_hop]:-}" ]]; then
      audit_chk hy2_hop good "диапазон ${A[hy2_hop]//,/, } перенаправлен на порт $port"
    else
      audit_chk hy2_hop warn "нет: клиенты всегда ходят на порт $port" "" \
        "Из iof смена портов пока не включается: в ссылки групп попадает один порт, и после sudo iof hy2 refresh диапазон из ссылки пропадёт. Вручную: перенаправь диапазон на порт Hysteria2 командой ниже (после перезагрузки правило надо вернуть, файрвол должен пропускать этот диапазон UDP) и замени в ссылке клиента порт на диапазон, например :20000-50000. $where" \
        "iptables -t nat -A PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports $port"
    fi

    # Блоки конфига узла против блоков шаблона, по хэшам этого запуска
    if [[ -z "$AUDIT_TPL_SRC" ]]; then
      audit_chk hy2_template none "шаблона на управляющем сервере нет" \
        "Шаблон — /etc/hysteria/config.yaml управляющего сервера или файл из HY2_TEMPLATE в /root/iof/iof.env"
    else
      while IFS= read -r s; do
        s="${s#hy2_block=}"
        if [[ "$s" == *"|"* ]]; then tpl["${s%%|*}"]="${s#*|}"; fi
      done <<<"$AUDIT_TPL"
      for s in "${A_BLOCK[@]}"; do mine["${s%%|*}"]="${s#*|}"; done
      d=()
      for k in "${!mine[@]}"; do
        if [[ -z "${tpl[$k]:-}" ]]; then d+=("$k (в шаблоне нет)")
        elif [[ "${tpl[$k]}" != "${mine[$k]}" ]]; then d+=("$k"); fi
      done
      for k in "${!tpl[@]}"; do
        if [[ -z "${mine[$k]:-}" ]]; then d+=("$k (на узле нет)"); fi
      done
      if (( ${#d[@]} == 0 )); then
        audit_chk hy2_template good "совпадает с шаблоном" "Шаблон: $AUDIT_TPL_SRC. Пользователи auth.userpass не сравниваются: на узлах они свои"
      else
        val="$(printf '%s\n' "${d[@]}" | sort | paste -sd, | sed 's/,/, /g')"
        audit_chk hy2_template warn "отличается от шаблона, блоки: $val" "Шаблон: $AUDIT_TPL_SRC" \
          "Если правки на узле нужны, внеси их и в шаблон. Вернуть узлу конфиг по шаблону — команда ниже. При auth userpass пользователи узла создадутся заново с новыми паролями: ссылки на этот узел изменятся, раздай их снова (sudo iof hy2 show). На управляющем сервере:" \
          "sudo iof hy2 install $name --force"
      fi
    fi
  fi

  # AmneziaWG
  s="${A[awg_c]:-}"
  case "${A[awg]:-}" in
    running)
      audit_awg_check
      d=("Контейнер $s, интерфейс ${A[awg_if]:-?}")
      v=""
      for k in "${A_AWGI[@]}"; do
        if [[ "$k" == *"|set" ]]; then v+="${v:+, }I${k%%|*}"; fi
      done
      if (( ${#A_AWGI[@]} > 0 )); then d+=("Пакеты-подписи I1–I5: ${v:+заданы }${v:-не заданы}"); fi
      if (( AWG_PLAIN )); then
        audit_chk awg_params crit "как у обычного WireGuard: параметры обфускации не заданы" "$(audit_lines "${d[@]}")" \
          "Такой трафик фильтры узнают по первому пакету. Параметры задаёт приложение Amnezia при установке: поставь на сервер из приложения протокол AmneziaWG вместо WireGuard и выдай ключи заново. На управляющем сервере:" \
          "sudo iof awg refresh"
      elif (( ${#AWG_BAD[@]} > 0 )); then
        val="$(printf '%s\n' "${AWG_BADK[@]}" | awk '!seen[$0]++' | paste -sd, | sed 's/,/, /g')"
        audit_chk awg_params warn "вне допустимых границ: $val" "$(audit_lines "${d[@]}" "${AWG_BAD[@]}")" \
          "Параметры должны совпадать на сервере и у всех клиентов, поэтому вручную их не правят. Переустанови AmneziaWG на сервере из приложения Amnezia (оно подберёт значения в границах) и выдай ключи заново. На управляющем сервере:" \
          "sudo iof awg refresh"
      else
        audit_chk awg_params good "заданы и в допустимых границах" "$(audit_lines "${d[@]}")"
      fi

      v="${A[awg_hash]:-}"
      same=()
      for k in "${!AUDIT_AWG[@]}"; do
        if [[ "$k" != "$name" && "${AUDIT_AWG[$k]}" == "$v" ]]; then same+=("$k"); fi
      done
      if [[ -z "$v" ]]; then
        audit_chk awg_same none "параметров обфускации в конфиге нет, сравнивать нечего"
      elif (( ${#AUDIT_AWG[@]} < 2 )); then
        audit_chk awg_same none "сравнивать не с чем: в этой проверке AmneziaWG только на этом узле" \
          "Сравнение идёт внутри одной проверки. Проверить все узлы: sudo iof audit run dpi"
      elif (( ${#same[@]} > 0 )); then
        val="$(printf '%s\n' "${same[@]}" | sort | paste -sd, | sed 's/,/, /g')"
        audit_chk awg_same warn "такие же параметры на: $val" "" \
          "Так бывает, если серверы ставили копированием настроек. Свои параметры узел получит, если переустановить на нём AmneziaWG из приложения Amnezia. После этого на управляющем сервере:" \
          "sudo iof awg refresh"
      else
        audit_chk awg_same good "отличаются от остальных узлов (сравнено узлов: ${#AUDIT_AWG[@]})"
      fi ;;
    stopped)
      audit_chk awg_params none "контейнер $s остановлен"
      audit_chk awg_same none "контейнер $s остановлен" ;;
    noconf)
      audit_chk awg_params none "в контейнере $s нет конфига awg0.conf или wg0.conf"
      audit_chk awg_same none "в контейнере $s нет конфига" ;;
    none)
      audit_chk awg_params none "AmneziaWG на узле не установлен"
      audit_chk awg_same none "AmneziaWG на узле не установлен" ;;
    *)
      audit_chk awg_params none "нет данных"
      audit_chk awg_same none "нет данных" ;;
  esac

  # Что видно снаружи
  if [[ -z "$ip" ]]; then
    for k in tcp_web tls_cert icmp banners; do
      audit_chk "$k" none "адрес узла $addr не определился как IPv4"
    done
  else
    # Порты 80 и 443/tcp: кто на них отвечает
    open=(); shut=()
    w=1
    for n in 80 443; do
      case "${A[x_tcp$n]:-}" in
        open)
          s="${A[x_http$n]:-}"
          v="$n/tcp"
          if [[ "${A[hy2_http]:-}" == "$n" || "${A[hy2_https]:-}" == "$n" ]]; then
            v+=" masquerade Hysteria2"
          else
            w=0
            if [[ -n "${s#*|}" ]]; then v+=" ${s#*|}"; else v+=" служба без заголовка Server"; fi
          fi
          if [[ -n "${s%%|*}" ]]; then v+=" (ответ ${s%%|*})"; fi
          open+=("$v") ;;
        filtered) shut+=("$n/tcp не отвечает") ;;
        *)        shut+=("$n/tcp закрыт") ;;
      esac
    done
    d=("$me")
    if (( ${#open[@]} == 0 )); then
      if (( hy2 && ! obfs )) && [[ "$masq" != "none" ]]; then
        audit_chk tcp_web warn "закрыты, а на $port/udp сервер изображает сайт с HTTP/3" "$(audit_lines "${d[@]}")" \
          "Настоящий сайт с HTTP/3 отвечает и по TCP. В Hysteria2 для этого есть masquerade.listenHTTPS и listenHTTP: команда добавляет их в блок masquerade. Если включён файрвол, открой 80/tcp и 443/tcp. $where" \
          "sed -i '/^masquerade:/a\\  listenHTTP: :80\\n  listenHTTPS: :443\\n  forceHTTPS: true' $conf && $restart"
      else
        audit_chk tcp_web good "закрыты: $(audit_list "${shut[@]}")" "$(audit_lines "${d[@]}")"
      fi
    elif (( w )); then
      audit_chk tcp_web good "отвечает $(audit_list "${open[@]}")" "$(audit_lines "${d[@]}" "${shut[@]}")"
    else
      audit_chk tcp_web none "отвечает $(audit_list "${open[@]}")" \
        "$(audit_lines "${d[@]}" "${shut[@]}" "Это не Hysteria2: что увидит зонд, зависит от этой службы. Оценки здесь нет, смотри проверку «Сертификат»")"
    fi

    # Сертификат: тот, что на 443/tcp, иначе тот, что Hysteria2 показывает при рукопожатии QUIC
    hint="Сертификат на имя чужого сайта снаружи выглядит подделкой. Варианты: свой домен и блок acme в конфиге Hysteria2 (сертификат выдаст Let's Encrypt, в ссылках клиентов пропадёт insecure) или Salamander, под которым рукопожатие снаружи не видно."
    if [[ "${A[x_tcp443]:-}" == "open" && -n "${A[x_cert_cn]:-}${A[x_cert_issuer]:-}" ]]; then
      s="${A[x_cert_cn]:-без имени}"
      d=("$me")
      if [[ "${A[hy2_https]:-}" == "443" ]]; then d+=("На 443/tcp отвечает masquerade Hysteria2 со своим сертификатом"); fi
      if [[ "${A[x_cert_self]:-}" != "yes" ]]; then
        if [[ "${A[x_cert_here]:-}" == "no" ]]; then
          audit_chk tls_cert warn "443/tcp: выдан ${A[x_cert_issuer]:-УЦ} на $s, но это имя ведёт не на адрес узла" "$(audit_lines "${d[@]}")" \
            "Проверь запись DNS для $s: она должна указывать на $ip."
        else
          audit_chk tls_cert good "443/tcp: выдан ${A[x_cert_issuer]:-УЦ} на $s" "$(audit_lines "${d[@]}")"
        fi
      elif [[ "${A[x_cert_here]:-}" == "yes" ]]; then
        audit_chk tls_cert none "443/tcp: самоподписанный на $s, имя ведёт на этот адрес" \
          "$(audit_lines "${d[@]}" "Браузер такому сертификату не доверяет, но и чужим сайтом сервер не притворяется")"
      elif [[ "$s" == *.* ]]; then
        audit_chk tls_cert warn "443/tcp: самоподписанный на чужое имя $s" "$(audit_lines "${d[@]}")" "$hint"
      else
        audit_chk tls_cert none "443/tcp: самоподписанный, без имени сайта ($s)" "$(audit_lines "${d[@]}")"
      fi
    elif [[ "${A[x_tcp443]:-}" == "open" ]]; then
      audit_chk tls_cert none "443/tcp открыт, но сертификат с него получить не удалось" "$me"
    elif (( hy2 && obfs )); then
      audit_chk tls_cert none "снаружи не виден: 443/tcp закрыт, рукопожатие QUIC скрыто под Salamander"
    elif (( hy2 )) && [[ "${A[hy2_acme]:-}" == "yes" ]]; then
      audit_chk tls_cert good "Hysteria2 получает сертификат по ACME на своё имя"
    elif (( hy2 )) && [[ -n "${A[hy2_cert_cn]:-}" ]]; then
      s="${A[hy2_cert_cn]}"
      d=("Сертификат Hysteria2 виден при рукопожатии QUIC на $port/udp")
      if [[ "${A[hy2_cert_self]:-}" != "yes" ]]; then
        audit_chk tls_cert good "Hysteria2: выдан удостоверяющим центром на $s" "$(audit_lines "${d[@]}")"
      elif [[ "${A[x_hy2cert_here]:-}" == "yes" ]]; then
        audit_chk tls_cert none "Hysteria2: самоподписанный на $s, имя ведёт на этот адрес" "$(audit_lines "${d[@]}")"
      elif [[ "$s" == *.* ]]; then
        audit_chk tls_cert warn "Hysteria2: самоподписанный на чужое имя $s" "$(audit_lines "${d[@]}")" "$hint"
      else
        audit_chk tls_cert none "Hysteria2: самоподписанный, без имени сайта ($s)" "$(audit_lines "${d[@]}")"
      fi
    else
      audit_chk tls_cert none "снаружи не виден: 443/tcp закрыт"
    fi

    case "${A[x_icmp]:-}" in
      yes)    audit_chk icmp good "отвечает" "$me" ;;
      no)     audit_chk icmp none "не отвечает: ICMP закрыт на узле, у хостера или режется по пути" ;;
      noping) audit_chk icmp none "на управляющем сервере нет ping: apt install iputils-ping" ;;
      *)      audit_chk icmp none "нет данных" ;;
    esac

    # Лишние порты TCP: открыты ли снаружи и чем отвечают
    s=22
    if [[ "$target" != "local" ]]; then split_target "$target"; s="$T_PORT"; fi
    audit_ports "$s"
    open=(); shut=()
    for s in "${A_BANNER[@]}"; do
      IFS='|' read -r n st v <<<"$s"
      if [[ "$st" == "open" ]]; then open+=("$n/tcp${v:+ ($v)}"); else shut+=("$n/tcp"); fi
    done
    d=("$me")
    for s in "${AP_EXTRA[@]}"; do
      if [[ "$s" == *"/udp "* ]]; then d+=("Слушает UDP, приветствия у него нет: $s"); fi
    done
    if (( ${#AP_EXTRA[@]} == 0 )); then
      if (( ${#A_LISTEN[@]} == 0 )); then audit_chk banners none "нет данных (нет ss)"
      else audit_chk banners good "лишних портов нет"; fi
    elif (( ${#open[@]} > 0 )); then
      audit_chk banners warn "снаружи открыты: $(audit_list "${open[@]}")" "$(audit_lines "${d[@]}")" \
        "Останови службу или закрой порт файрволом: что это за порты, показывает проверка «Слушающие порты» в аудите сервера. $where" \
        "$(audit_lines "ss -tulnp | grep -E ':($(audit_lines "${AP_XP[@]}" | tr '\037' '|')) '" "systemctl disable --now <служба>")"
    elif (( ${#shut[@]} > 0 )); then
      audit_chk banners good "лишние порты снаружи закрыты: $(audit_list "${shut[@]}")" "$(audit_lines "${d[@]}")"
    else
      audit_chk banners none "лишние порты только UDP, приветствий у них нет" "$(audit_lines "${d[@]}")"
    fi
  fi

  # Имя сервера и PTR
  s="${A[hostname]:-}"
  v="${A[x_ptr]:-}"
  if [[ -z "$s" && -z "$v" ]]; then
    audit_chk names none "нет данных"
  else
    val="имя сервера: ${s:-нет данных}, PTR: ${v:-нет}"
    d=(); hint=""; cmd=""
    if w="$(audit_vpn_word "$s")"; then
      d+=("В имени сервера есть «$w»")
      hint="Имя сервера меняется командой ниже. $where"
      cmd="hostnamectl set-hostname srv-${name//[^A-Za-z0-9]/-}"
      if audit_vpn_word "$cmd" >/dev/null; then cmd="hostnamectl set-hostname server1"; fi
    fi
    if w="$(audit_vpn_word "$v")"; then
      d+=("В PTR есть «$w»")
      hint="PTR (reverse DNS) меняется в панели хостера. ${hint}"
    fi
    if (( ${#d[@]} > 0 )); then audit_chk names warn "$val" "$(audit_lines "${d[@]}")" "$hint" "$cmd"
    else audit_chk names good "$val"; fi
  fi

  case "${A[web]:-}" in
    none)     audit_chk panel good "панели на узле нет" ;;
    loopback) audit_chk panel good "слушает только ${A[web_addr]:-127.0.0.1}" ;;
    any)
      audit_chk panel crit "слушает внешний адрес: ${A[web_addr]:-?}" "" \
        "Верни панель на 127.0.0.1 и открывай её через SSH-туннель со своего компьютера: ssh -L 8088:127.0.0.1:8088 root@$addr. $where" \
        "sed -i -E 's/--listen [^ ]+/--listen 127.0.0.1:8088/' /etc/systemd/system/iof-web.service && systemctl daemon-reload && systemctl restart iof-web" ;;
    unknown)  audit_chk panel none "служба iof-web запущена, но её порт не найден" ;;
    *)        audit_chk panel none "нет данных" ;;
  esac

  # Блок-лист сканеров: iof его пока не применяет, только смотрит
  s="$(audit_list_info blocklist)"
  if [[ -z "$BLOCKLIST_URL" ]]; then
    audit_chk blocklist none "список не задан: BLOCKLIST_URL в /root/iof/iof.env пуст" \
      "Формат списка: текст, по одному IP или CIDR в строке, # — комментарий. Пример: BLOCKLIST_URL=\"https://example.org/scanners.txt\""
  elif [[ -z "$s" ]]; then
    audit_chk blocklist none "список не скачался: проверь BLOCKLIST_URL в /root/iof/iof.env" \
      "Проверить вручную на управляющем сервере: curl -fsSL \"\$BLOCKLIST_URL\" | head"
  else
    d=("В списке записей: ${s%% *}, скачан $(audit_when "${s##* }")")
    if [[ -f "$AUDIT_DIR/cache/blocklist.txt.err" ]]; then d+=("Последняя загрузка не удалась, это прошлая копия"); fi
    at="$(audit_num "${A[block_at]:-}")"
    if [[ "${A[block_set]:-}" == "yes" && "${A[block_chain]:-}" == "yes" && "${A[block_hook]:-}" == "yes" ]]; then
      val="применён: записей $(audit_num "${A[block_entries]:-}")"
      if (( at > 0 && now - at > 7 * 86400 )); then
        audit_chk blocklist warn "$val, но не обновлялся с $(audit_when "$at")" "$(audit_lines "${d[@]}")" \
          "Список на узле старше недели: адреса сканеров меняются. Обновление списка из iof появится вместе с его применением."
      elif (( at > 0 )); then
        audit_chk blocklist good "$val, обновлён $(audit_when "$at")" "$(audit_lines "${d[@]}")"
      else
        audit_chk blocklist good "$val" "$(audit_lines "${d[@]}" "Когда список обновлялся, неизвестно: на узле нет /etc/iof/block.list")"
      fi
    elif [[ "${A[block_set]:-}" == "yes" || "${A[block_chain]:-}" == "yes" ]]; then
      audit_chk blocklist warn "применён не полностью: набор iof-block ${A[block_set]:-no}, цепочка IOF-BLOCK ${A[block_chain]:-no}, правило в INPUT ${A[block_hook]:-no}" \
        "$(audit_lines "${d[@]}")" "Пакеты от адресов из списка отбрасываются, только когда есть и набор, и цепочка, и переход в неё из INPUT. $where" \
        "$(audit_lines "ipset list -t iof-block" "iptables -S INPUT | grep IOF-BLOCK")"
    else
      audit_chk blocklist warn "на узле не применён" "$(audit_lines "${d[@]}")" \
        "Применять список iof пока не умеет, это появится отдельной командой. Сейчас проверка только показывает, что пакеты от адресов из списка узел принимает."
    fi
  fi

  # Репутация адреса: сеть и хостер по whois, адрес в выгрузке реестра
  IFS='|' read -r st v s k <<<"${A[x_whois]:-}"
  if [[ -z "$ip" ]]; then
    audit_chk asn none "не определён: адрес узла $addr не IPv4"
  elif [[ "$st" == "private" ]]; then
    audit_chk asn none "не определён: $ip — частный адрес, в whois его нет"
  elif [[ "$st" == "ok" && -n "$v" ]]; then
    audit_chk asn good "$v${s:+, $s}${k:+ ($k)}" "Адрес $ip, данные whois регионального реестра"
  elif [[ "$st" == "ok" ]]; then
    audit_chk asn none "не определён" "Реестр не отдал номер AS для $ip${s:+. Сеть: $s}${k:+ ($k)}"
  else
    audit_chk asn none "не определён" "whois не ответил: с управляющего сервера должен быть доступен порт 43 (whois.iana.org и региональный реестр)"
  fi

  s="$(audit_list_info registry)"
  v="${A[x_registry]:-}"
  if [[ -z "$REGISTRY_URL" ]]; then
    audit_chk registry none "выгрузка не задана: REGISTRY_URL в /root/iof/iof.env пуст" \
      "Формат: текст, по одному IP или CIDR в строке, # — комментарий. Пример: REGISTRY_URL=\"https://example.org/registry-ips.txt\""
  elif [[ -z "$s" ]]; then
    audit_chk registry none "выгрузка не скачалась: проверь REGISTRY_URL в /root/iof/iof.env" \
      "Проверить вручную на управляющем сервере: curl -fsSL \"\$REGISTRY_URL\" | head"
  elif [[ -z "$ip" ]]; then
    audit_chk registry none "адрес узла $addr не IPv4, а выгрузка проверяется только по IPv4"
  else
    d=("В выгрузке записей: ${s%% *}, скачана $(audit_when "${s##* }")")
    if [[ -f "$AUDIT_DIR/cache/registry.txt.err" ]]; then d+=("Последняя загрузка не удалась, это прошлая копия"); fi
    case "$v" in
      hit\|*)
        audit_chk registry crit "адрес $ip есть в выгрузке (запись ${v#hit|})" "$(audit_lines "${d[@]}")" \
          "У провайдеров, которые блокируют по реестру, узел недоступен. Помогает только другой адрес: новый IP у хостера или новый сервер (страница «Добавить сервер»). Старый узел убирается так, на управляющем сервере:" \
          "$(audit_lines "sudo iof node del $name" "sudo iof refresh")" ;;
      miss) audit_chk registry good "адреса $ip в выгрузке нет" "$(audit_lines "${d[@]}")" ;;
      *)    audit_chk registry none "проверка по выгрузке не выполнилась" "$(audit_lines "${d[@]}")" ;;
    esac
  fi

  # Гигиена: что остаётся в журналах и время
  if [[ -z "${A[jd_usage]:-}${A[jd_oldest]:-}${A[jd_retention]:-}" ]]; then
    audit_chk journald none "нет данных (нет journalctl)"
  else
    d=()
    if [[ -n "${A[jd_usage]:-}" ]]; then d+=("Журнал занимает ${A[jd_usage]}${A[jd_maxuse]:+, ограничение по размеру ${A[jd_maxuse]}}"); fi
    at="$(audit_num "${A[jd_oldest]:-}")"
    v="${A[jd_retention]:-}"
    if [[ -n "$v" && "$v" != "0" ]]; then
      audit_chk journald good "хранится не дольше $v" "$(audit_lines "${d[@]}")"
    else
      val="срок не ограничен"
      if (( at > 0 && now >= at )); then val+=": самая старая запись от $(audit_when "$at") ($(( (now - at) / 86400 )) дн.)"; fi
      audit_chk journald warn "$val" "$(audit_lines "${d[@]}")" \
        "Ограничь срок, например неделей: старые записи journald удалит сам. Совсем короткий журнал мешает разбираться в сбоях, неделя — середина. $where" \
        "mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\nMaxRetentionSec=7day\n' > /etc/systemd/journald.conf.d/iof.conf && systemctl restart systemd-journald"
    fi
  fi

  if (( ! hy2 )); then
    audit_chk hy2_log none "Hysteria2 на узле не установлена"
  else
    v="${A[hy2_log]:-info}"
    case "$v" in
      warn|error|fatal|panic|dpanic)
        audit_chk hy2_log good "уровень $v: адреса клиентов в журнал не пишутся" ;;
      *)
        val="уровень $v: в журнал пишется адрес каждого клиента"
        if [[ "$v" == "debug" ]]; then val+=" и адреса, куда он ходит"; fi
        audit_chk hy2_log warn "$val" "" \
          "С уровнем warn в журнале остаются предупреждения и ошибки. Служба перезапустится, клиенты переподключатся сами. $where" \
          "mkdir -p /etc/systemd/system/hysteria-server.service.d && printf '[Service]\nEnvironment=HYSTERIA_LOG_LEVEL=warn\n' > /etc/systemd/system/hysteria-server.service.d/iof-log.conf && systemctl daemon-reload && $restart" ;;
    esac
  fi

  s="${A[awg_c]:-}"
  if [[ -z "$s" ]]; then
    audit_chk awg_log none "AmneziaWG на узле не установлен"
  else
    val=""
    n="$(audit_num "${A[awg_log_size]:-}")"
    if (( n > 0 )); then val=", сейчас $(gb "$n" 1048576) МБ"; fi
    case "${A[awg_log_driver]:-}" in
      json-file)
        if [[ -n "${A[awg_log_max]:-}" ]]; then
          audit_chk awg_log good "ограничен: max-size ${A[awg_log_max]}$val"
        else
          audit_chk awg_log warn "json-file без ограничения размера$val" "" \
            "Ограничение задаётся при создании контейнера, приложение Amnezia его не ставит. Для новых контейнеров его можно задать в /etc/docker/daemon.json (log-opts max-size), а текущий лог обрезать командой ниже. $where" \
            "truncate -s 0 \"\$(docker inspect -f '{{.LogPath}}' $s)\""
        fi ;;
      local)    audit_chk awg_log good "драйвер local: размер ограничен, старое удаляется само$val" ;;
      none)     audit_chk awg_log good "лог контейнера выключен" ;;
      journald) audit_chk awg_log good "пишется в журнал systemd: срок хранения — в проверке «Срок хранения журнала»" ;;
      "")       audit_chk awg_log none "нет данных" ;;
      *)        audit_chk awg_log none "драйвер ${A[awg_log_driver]}, оценки для него нет" ;;
    esac
  fi

  # Время: синхронизация и расхождение с часами управляющего сервера сразу после ответа узла
  diff=0
  if [[ -n "${A[now_end]:-}" && -n "${A[x_now]:-}" ]]; then
    diff=$(( $(audit_num "${A[now_end]}") - $(audit_num "${A[x_now]}") ))
    if (( diff < 0 )); then diff=$(( -diff )); fi
  fi
  cmd="timedatectl set-ntp true && sleep 5 && timedatectl show -p NTPSynchronized"
  if (( diff > 60 )); then
    audit_chk time warn "часы узла расходятся с управляющим сервером на $diff с" "" \
      "Включи синхронизацию времени. Если она включена и здесь, и там, сверь часы обоих серверов. $where" "$cmd"
  elif [[ "${A[time_sync]:-}" == "yes" ]]; then
    audit_chk time good "синхронизировано"
  elif [[ "${A[time_sync]:-}" == "no" ]]; then
    val="не синхронизировано"
    if [[ "${A[time_ntp]:-}" == "no" ]]; then val+=", служба времени выключена"; fi
    audit_chk time warn "$val" "С управляющим сервером часы сейчас сходятся" \
      "Без синхронизации часы со временем уходят. В контейнере без своих часов это предупреждение можно оставить. $where" "$cmd"
  else
    audit_chk time none "нет данных (timedatectl не ответил)"
  fi
}

# Сбор фактов с узла для pmap по блокам из AUDIT_RUN. Вывод: строка "@<блок>", за ней факты блока.
# Для dpi к фактам узла добавляются проверки снаружи. Пользователь — тот, под которым iof заходит на узел
audit_job() {
  local out b user="root" target="${N_SSH[$1]}"
  if [[ "$target" == *@* ]]; then user="${target%%@*}"; fi
  for b in $AUDIT_RUN; do
    if [[ "$b" == "dpi" ]]; then
      out="$(run_on "$target" n_audit_dpi "$AUDIT_SALT")" || return $?
    else
      out="$(run_on "$target" n_audit_server "$user")" || return $?
    fi
    if ! grep -q '^now=' <<<"$out"; then
      echo "узел не ответил на аудит" >&2
      return 1
    fi
    printf '@%s\n%s\n' "$b" "$out"
    if [[ "$b" == "dpi" ]]; then
      echo "x_now=$(date +%s)"
      audit_outside "$1" "$out"
    fi
  done
}

# Факты блока $2 из вывода audit_job узла $1
audit_facts() { pm_out "$1" | awk -v b="@$2" '/^@/ { f = ($0 == b); next } f'; }

# Для AUDIT_PY после pmap audit_job: по каждому блоку строка R, затем на узел строка N (имя, адрес,
# 1 — ответил, время, ошибка) и строки C с его проверками
audit_results() {
  local i b now msg h
  now="$(date +%s)"
  for b in $AUDIT_RUN; do
    printf 'R\t%s\n' "$b"
    # Параметры AmneziaWG сравниваются между узлами этого запуска
    AUDIT_AWG=()
    if [[ "$b" == "dpi" ]]; then
      for i in "${SEL[@]}"; do
        pm_ok "$i" || continue
        h="$(audit_facts "$i" dpi | sed -n 's/^awg_hash=//p' | head -n 1)"
        if [[ -n "$h" ]]; then AUDIT_AWG["${N_NAME[$i]}"]="$h"; fi
      done
    fi
    for i in "${SEL[@]}"; do
      if pm_ok "$i"; then
        printf 'N\t%s\t%s\t1\t%s\t\n' "${N_NAME[$i]}" "${N_ADDR[$i]}" "$now"
        "audit_eval_$b" "$i" "$(audit_facts "$i" "$b")"
      else
        msg="$(pm_err "$i" | grep -v '^[[:space:]]*$' | tail -n 1 || true)"
        printf 'N\t%s\t%s\t0\t%s\t%s\n' "${N_NAME[$i]}" "${N_ADDR[$i]}" "$now" "${msg//$'\t'/ }"
      fi
    done
  done
}

# Для AUDIT_PY: все узлы из nodes.conf. По этому списку из результатов убираются удалённые узлы
audit_nodes() {
  local i
  for i in "${!N_NAME[@]}"; do
    printf 'L\t%s\t%s\t%s\n' "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(node_title "$i")"
  done
}

# Хранение и вывод результатов аудита. Режимы:
#  save <что проверяли: server, dpi или all> <папка> <сколько запусков хранить>  stdin: справочник,
#       узлы, результаты по блокам. Пишет <блок>.json каждого блока и одну строку в history.jsonl,
#       печатает проверки, которые стали хуже прошлого раза
#  api <папка>             stdin: справочник, узлы, настройки (строки S). Печатает JSON для панели
#  show <папка> <brief|full> <блоки через запятую> <узел>...  stdin: справочник. Печатает
#       последнюю проверку узлов
AUDIT_PY=$(cat <<'EOF'
import ipaddress, json, os, re, sys, time

RANK = {"none": 0, "good": 1, "warn": 2, "crit": 3}
WORD = {"none": "нет данных", "good": "в порядке", "warn": "внимание", "crit": "проблема"}
MARK = {"none": "--", "good": "ok", "warn": " !", "crit": "!!"}
COLOR = {"good": "32", "warn": "33", "crit": "31"}
for stream in (sys.stdin, sys.stdout):
    stream.reconfigure(encoding="utf-8", errors="replace")


def load(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write(path, text):
    tmp = path + ".tmp"
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def history(base):
    out = []
    try:
        with open(os.path.join(base, "history.jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def split(s):
    return [x for x in s.split("\x1f") if x]


def read_input():
    d = {"titles": {}, "groups": [], "catalog": [], "nodes": [], "settings": {}, "results": {}}
    cur, res = None, {}
    for raw in sys.stdin:
        f = raw.rstrip("\n").split("\t") + [""] * 7
        if f[0] == "B":
            d["titles"][f[1]] = f[2]
        elif f[0] == "R":
            cur, res = None, d["results"].setdefault(f[1], {})
        elif f[0] == "G":
            d["groups"].append({"block": f[1], "id": f[2], "title": f[3]})
        elif f[0] == "K":
            d["catalog"].append({"id": f[1], "block": f[2], "group": f[3], "title": f[4], "why": f[5]})
        elif f[0] == "L":
            d["nodes"].append({"name": f[1], "addr": f[2], "title": f[3]})
        elif f[0] == "S":
            d["settings"][f[1]] = f[2]
        elif f[0] == "N":
            cur = {"addr": f[2], "reachable": f[3] == "1", "at": int(f[4]), "error": f[5], "checks": []}
            res[f[1]] = cur
        elif f[0] == "C" and cur is not None:
            cur["checks"].append({"id": f[1], "status": f[2] if f[2] in RANK else "none", "value": f[3],
                                  "detail": split(f[4]), "hint": f[5], "cmd": "\n".join(split(f[6]))})
    return d


def blocks(d):
    return list(dict.fromkeys(g["block"] for g in d["groups"]))


def save(label, base, keep):
    d = read_input()
    titles = {k["id"]: k["title"] for k in d["catalog"]}
    known = {n["name"] for n in d["nodes"]}
    counts, down, worse, seen = dict.fromkeys(RANK, 0), [], [], set()
    for block, results in d["results"].items():
        path = os.path.join(base, block + ".json")
        old = load(path, {}).get("nodes", {})
        nodes = {k: v for k, v in old.items() if k in known}
        for name, new in results.items():
            prev = old.get(name, {})
            seen.add(name)
            if not new["reachable"]:
                # Прошлые оценки остаются: с ними сравнится следующая удачная проверка
                new["checks"] = prev.get("checks", [])
                new["checked"] = prev.get("checked", 0)
                if name not in down:
                    down.append(name)
            else:
                new["checked"] = new["at"]
                was = {c["id"]: c["status"] for c in prev.get("checks", [])}
                for c in new["checks"]:
                    counts[c["status"]] += 1
                    # Первая проверка задаёт базу. Хуже — это внимание или проблема там, где было лучше
                    if c["id"] in was and RANK[c["status"]] > max(RANK.get(was[c["id"]], 0), 1):
                        worse.append({"node": name, "id": c["id"], "from": was[c["id"]], "to": c["status"]})
                        print(f'{name}: {titles.get(c["id"], c["id"])} — {c["value"]} '
                              f'(было: {WORD.get(was[c["id"]], was[c["id"]])})')
            nodes[name] = new
        write(path, json.dumps({"nodes": nodes}, ensure_ascii=False))
    # Одна строка на запуск, даже когда проверялись оба блока
    lines = [json.dumps(h, ensure_ascii=False) for h in history(base)]
    lines.append(json.dumps({"at": int(time.time()), "block": label, "nodes": len(seen),
                             "counts": counts, "down": down, "worse": worse}, ensure_ascii=False))
    write(os.path.join(base, "history.jsonl"), "\n".join(lines[-max(keep, 1):]) + "\n")


def api(base):
    d = read_input()
    known = [n["name"] for n in d["nodes"]]
    out = {"blocks": {}, "titles": d["titles"], "groups": d["groups"], "catalog": d["catalog"],
           "nodes": d["nodes"], "history": history(base),
           "settings": {"cron": d["settings"].get("cron", ""), "tg": d["settings"].get("tg") == "yes"}}
    for b in blocks(d):
        saved = load(os.path.join(base, b + ".json"), {}).get("nodes", {})
        out["blocks"][b] = {"nodes": {k: saved[k] for k in known if k in saved}}
    out["probe"] = probe_api(os.path.join(base, "probe"))
    json.dump(out, sys.stdout, ensure_ascii=False)
    print()


def show(base, mode, want, names):
    d = read_input()
    color = os.environ.get("IOF_COLOR") == "1"
    brief = mode == "brief"

    def paint(st, text):
        return f"\033[{COLOR[st]}m{text}\033[0m" if color and st in COLOR else text

    for b in blocks(d):
        if b not in want:
            continue
        saved = load(os.path.join(base, b + ".json"), {}).get("nodes", {})
        title = d["titles"].get(b, b)
        for name in names:
            node = saved.get(name)
            if node is None:
                print(f"== {name} · {title}: проверки ещё не было")
                continue
            when = time.strftime("%d.%m.%Y %H:%M", time.localtime(node["at"]))
            head = f"== {name} ({node['addr']}) · {title}, {when}: "
            if not node["reachable"]:
                print(head + paint("crit", f"нет связи ({node['error'] or 'нет связи по SSH'})"))
                continue
            by = {c["id"]: c for c in node["checks"]}
            n = {st: sum(1 for c in node["checks"] if c["status"] == st) for st in RANK}
            print(head + f"проблем {n['crit']}, внимание {n['warn']}, в порядке {n['good']}, нет данных {n['none']}")
            for g in d["groups"]:
                if g["block"] != b:
                    continue
                rows = [(k, by[k["id"]]) for k in d["catalog"]
                        if k["block"] == b and k["group"] == g["id"] and k["id"] in by]
                if brief:
                    rows = [r for r in rows if r[1]["status"] in ("warn", "crit")]
                if rows and not brief:
                    print(f"  {g['title']}")
                for k, c in rows:
                    print(f"  {paint(c['status'], MARK[c['status']])} {k['title']}: {c['value']}")
                    if brief:
                        continue
                    for line in c["detail"]:
                        print(f"       {line}")
                    if c["status"] in ("warn", "crit") and (c["hint"] or c["cmd"]):
                        print(f"       Как исправить: {c['hint']}")
                        for line in c["cmd"].splitlines():
                            print(f"         {line}")


# Проверка с ПК (iof audit probe). Сессия: session.json, токен мишеней отдельно в token. Отчёт
# probe.ps1 приходит сырым, вердикт по слоям считается здесь: ПК сравнивается с контролем,
# который управляющий сервер прошёл до тех же мишеней сразу после запуска. crit только при
# высокой уверенности: контроль прошёл, у ПК есть интернет, VPN не видно, попытки сходятся

FULL = 262144
LAYERS = [("icmp", "Ping"), ("tcp", "TCP"), ("tls", "TLS"), ("data", "Данные 256 КБ"), ("udp", "UDP"),
          ("quic", "UDP, похожий на QUIC"), ("hy2", "Порт Hysteria2"), ("tunnel", "Туннель Hysteria2")]
CONF = {"low": 0, "medium": 1, "high": 2}
CONF_WORD = {"high": "высокая", "medium": "средняя", "low": "низкая"}
# Почему мишень на узле не запущена: текст и команда
NOT_STARTED = {
    "nopython": ("нет python3, он нужен мишени", "apt install python3"),
    "noopenssl": ("нет openssl для сертификата мишени", "apt install openssl"),
    "nosystemd": ("нет systemd-run, мишень не запустить", ""),
    "nft": ("входящие режет своя таблица nftables, а правило для мишени iof ставит только через iptables", ""),
    "busy": ("нет свободного порта для мишени", ""),
    "error": ("мишень не запустилась", ""),
    "down": ("узел не ответил по SSH", ""),
}
TUNNEL_SKIP = {"nohysteria": "нет hysteria.exe", "nolinks": "в буфере обмена нет ссылок hy2://",
               "nolink": "в буфере обмена нет ссылки на этот узел", "declined": "отказ на ПК"}
HY2_WORD = {"vn": "отвечает как QUIC", "silent": "молчит", "closed": "порт закрыт", "reply": "ответ не как у QUIC",
            "error": "ошибка проверки"}


def fail(text):
    print("Ошибка: " + text, file=sys.stderr)
    sys.exit(2)


def num(v, hi):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return 0
    return int(v) if 0 <= v <= hi else 0


def txt(v, n):
    return "".join(ch for ch in v if ch.isprintable())[:n] if isinstance(v, str) else ""


def obj(v):
    return v if isinstance(v, dict) else {}


def mid(values):
    values = sorted(values)
    return values[len(values) // 2] if values else 0


def private(ip):
    try:
        return not ipaddress.ip_address(ip).is_global
    except ValueError:
        return False


def side(t):
    """Сырые слои одной стороны, ПК или контроля -> счётчики по слоям."""
    t = obj(t)
    conn = [c for c in t.get("conn") if isinstance(c, dict)][:5] if isinstance(t.get("conn"), list) else []
    tcp = [c for c in conn if c.get("tcp") is not None]
    tls = [c for c in tcp if c.get("tls") is not None]
    size = [num(c.get("bytes"), FULL) for c in tls]
    icmp, u, q = obj(t.get("icmp")), obj(t.get("udp")), obj(t.get("quic"))
    return {
        "n": len(conn),
        "icmp": (num(icmp.get("got"), 10), num(icmp.get("sent"), 10), num(icmp.get("ms"), 60000)),
        "tcp": (len(tcp), mid([num(c.get("tcp"), 60000) for c in tcp])),
        "tls": (len(tls), mid([num(c.get("tls"), 60000) for c in tls])),
        "mitm": any(c.get("fp") == "mismatch" for c in tls),
        "full": size.count(FULL),
        "stall": [b for b in size if 0 < b < FULL],
        "data_ms": mid([num(c.get("ms"), 120000) for c, b in zip(tls, size) if b == FULL]),
        "errs": [txt(c.get("err"), 60) for c in conn if c.get("err")],
        "src": [txt(c.get("src"), 45) for c in conn if c.get("src")],
        "udp": (num(u.get("got"), 50), num(u.get("sent"), 50)),
        "quic": (num(q.get("got"), 50), num(q.get("sent"), 50)),
        "hy2": txt(t.get("hy2"), 10),
        "tunnel": obj(t.get("tunnel")),
    }


def tries(ok, n, ms=0, errs=()):
    if not n:
        return "не проверялся"
    s = f"{ok} из {n}" + (f", {ms} мс" if ok and ms else "")
    if ok < n and errs:
        s += f" ({errs[0]})"
    return s


def check_line(s):
    """Короткий итог одной стороны для сессии и консоли."""
    parts = []
    if s["icmp"][1]:
        parts.append(f"ping {s['icmp'][0]}/{s['icmp'][1]}")
    if s["n"]:
        parts += [f"TCP {s['tcp'][0]}/{s['n']}", f"TLS {s['tls'][0]}/{s['n']}", f"данные {s['full']}/{s['n']}"]
    for k, title in (("udp", "UDP"), ("quic", "QUIC")):
        if s[k][1]:
            parts.append(f"{title} {s[k][0]}/{s[k][1]}")
    if s["hy2"]:
        parts.append("Hysteria2 " + HY2_WORD.get(s["hy2"], s["hy2"]))
    return " · ".join(parts) or "нет данных"


def verdicts(pc, ctl, hy2_port):
    """Слои узла: [(id, вердикт, с ПК, контроль, пояснение)]. Вердикты: ok, blocked, stall, partial,
    mitm, fail, down (контроль тоже не прошёл), unknown (не с чем сравнить), skipped."""
    rows = []
    got, sent, m = pc["icmp"]
    cg, cs, cm = ctl["icmp"]
    v = ("skipped" if not sent else "unknown" if not cs and not got else "down" if cs and not cg
         else "ok" if got == sent else "partial" if got else "blocked")
    rows.append(("icmp", v, tries(got, sent, m), tries(cg, cs, cm) if cs else "нет ping на управляющем сервере",
                 "ICMP по дороге режут часто, на VPN это не влияет" if v in ("blocked", "partial") else ""))

    n, cn = pc["n"], ctl["n"]
    ok, cok = pc["tcp"][0], ctl["tcp"][0]
    v = "skipped" if not n else "down" if not cok else "blocked" if not ok else "partial" if ok < n else "ok"
    rows.append(("tcp", v, tries(ok, n, pc["tcp"][1], pc["errs"]), tries(cok, cn, ctl["tcp"][1], ctl["errs"]), ""))

    t, ct = pc["tls"][0], ctl["tls"][0]
    pct = tries(t, ok, pc["tls"][1], [e for e in pc["errs"] if e.startswith("tls")])
    if pc["mitm"]:
        pct += ", сертификат подменён"
    v = ("skipped" if not ok else "down" if not ct else "mitm" if pc["mitm"] else "blocked" if not t
         else "partial" if t < ok else "ok")
    rows.append(("tls", v, pct if ok else "не дошло до TLS", tries(ct, cok, ctl["tls"][1]), ""))

    full, stall = pc["full"], pc["stall"]
    note, pct = "", f"{full} из {t}" + (f", {pc['data_ms']} мс" if full else "")
    if stall:
        kb = mid(stall) // 1024
        pct += f"; встаёт на {kb} КБ ({len(stall)} из {t})"
        if 8 <= kb <= 40 and not full:
            note = "Похоже на ограничение ТСПУ: соединения с зарубежными хостингами встают после 15–20 КБ"
    v = ("skipped" if not t else "down" if not ctl["full"] else "ok" if full == t
         else "stall" if not full and stall else "blocked" if not full else "partial")
    rows.append(("data", v, pct if t else "не дошло до данных", f"{ctl['full']} из {ct}", note))

    for k in ("udp", "quic"):
        (g, s), (cg, cs) = pc[k], ctl[k]
        v = "skipped" if not s else "down" if not cg else "blocked" if not g else "partial" if g < s - 1 else "ok"
        note = ""
        if k == "quic" and v == "blocked" and rows[-1][1] == "ok":
            note = "Обычный UDP проходит, а пакеты, похожие на QUIC, — нет"
        rows.append((k, v, tries(g, s), tries(cg, cs), note))

    p, c = pc["hy2"], ctl["hy2"]
    if not hy2_port:
        rows.append(("hy2", "skipped", "Hysteria2 на узле нет", "—", ""))
    elif not p:
        rows.append(("hy2", "skipped", "не проверялся", HY2_WORD.get(c, c or "—"), ""))
    elif c != "vn":
        rows.append(("hy2", "down", HY2_WORD.get(p, p), HY2_WORD.get(c, c or "—"),
                     "Управляющему серверу порт тоже не ответил согласованием версий. Так выглядит Salamander: тогда "
                     "Hysteria2 проверяет только туннель"))
    else:
        rows.append(("hy2", "ok" if p == "vn" else "blocked", HY2_WORD.get(p, p), HY2_WORD["vn"], ""))

    tn = pc["tunnel"]
    if tn.get("tested") is not True:
        why = txt(tn.get("reason"), 20)
        rows.append(("tunnel", "skipped", "не проверялся: " + TUNNEL_SKIP.get(why, why or "нет данных"), "—", ""))
    elif tn.get("ok") is True:
        rows.append(("tunnel", "ok", "работает" + (f", {num(tn.get('ms'), 120000)} мс" if tn.get("ms") else ""), "—", ""))
    else:
        rows.append(("tunnel", "fail", "не поднялся: " + (txt(tn.get("err"), 120) or "нет ответа"), "—", ""))
    return rows


def layer_status(lid, v, conf):
    if conf == "low" or v in ("down", "unknown", "skipped"):
        return "none"
    if v == "ok":
        return "good"
    if lid == "icmp":
        return "none"
    return "crit" if v in ("blocked", "stall") and conf == "high" else "warn"


def node_result(name, n, rep_t, conf):
    """Итог узла: статус, уверенность, значение, совет и слои."""
    state = n.get("state", "")
    if state != "started":
        text, cmd = NOT_STARTED.get(state, ("мишень не запустилась", ""))
        err = txt(n.get("error"), 120)
        return {"addr": n.get("addr", ""), "status": "none", "confidence": conf, "value": "не проверялся: " + text,
                "detail": [err] if err and state not in ("nopython", "noopenssl") else [], "hint": "", "cmd": cmd, "layers": []}
    if rep_t is None:
        return {"addr": n.get("addr", ""), "status": "none", "confidence": conf, "value": "скрипт на ПК этот узел не проверил",
                "detail": [], "hint": "", "cmd": "", "layers": []}
    pc, ctl = side(rep_t), side(n.get("control"))
    lc = conf if pc["n"] >= 3 or conf == "low" else "medium"
    rows = []
    for lid, v, pct, ctt, note in verdicts(pc, ctl, n.get("hy2_port")):
        rows.append({"id": lid, "title": dict(LAYERS)[lid], "verdict": v, "status": layer_status(lid, v, lc),
                     "pc": pct, "control": ctt, "note": note})
    by = {r["id"]: r for r in rows}
    st = max((r["status"] for r in rows), key=lambda s: RANK[s])
    core = [r for r in rows if r["id"] not in ("icmp", "tunnel")]
    parts, hint, detail = [], [], []
    if n.get("local"):
        detail.append("Контроль шёл с самого управляющего сервера: это не взгляд снаружи")
    if all(r["verdict"] in ("down", "skipped") for r in core):
        parts.append("мишень не ответила и управляющему серверу")
        hint.append("Порт мишени закрыт у хостера (security group) или файрволом по пути. Задай в /root/iof/iof.env "
                    "PROBE_PORTS диапазоном, открытым у хостера, и повтори.")
    blocked = [r["title"] for r in rows if r["verdict"] == "blocked" and r["id"] != "icmp"]
    if blocked:
        parts.append("с ПК не проходят: " + ", ".join(blocked))
    if by["data"]["verdict"] == "stall":
        parts.append("данные встают на " + by["data"]["pc"].rsplit("встаёт на ", 1)[-1].split(" (")[0])
        hint.append("TLS-соединение с адресом встаёт после первых килобайт: так ТСПУ ограничивает соединения с зарубежными "
                    "хостингами. Hysteria2 и AmneziaWG работают по UDP, их это не задевает: смотри строки UDP и Hysteria2.")
    partial = [r["title"] for r in rows if r["verdict"] == "partial" and r["id"] != "icmp"]
    if partial:
        parts.append("с ПК проходят не все попытки: " + ", ".join(partial))
    if by["tls"]["verdict"] == "mitm":
        parts.append("сертификат мишени подменён по дороге")
        hint.append("Так делают антивирусы с проверкой защищённых соединений (например Kaspersky), корпоративные прокси или "
                    "провайдер. Выключи проверку HTTPS в антивирусе и повтори.")
    if by["tunnel"]["verdict"] == "fail":
        parts.append("туннель Hysteria2 не поднялся")
        hint.append("Клиент Hysteria2 на ПК не поднял туннель по ссылке группы: проверь, что ссылка свежая (sudo iof hy2 show) "
                    "и hysteria.exe новой версии.")
    if "UDP, похожий на QUIC" in blocked and "UDP" not in blocked:
        hint.append("Похожие на QUIC пакеты режутся, обычный UDP проходит. Hysteria2 без Salamander выглядит как QUIC: "
                    "Salamander это прячет, см. «Режим маскировки» в блоке «Защита от РКН».")
    elif "Порт Hysteria2" in blocked:
        hint.append("Порт Hysteria2 с ПК не отвечает, хотя отвечает управляющему серверу: его режут по дороге. "
                    "Варианты — другой порт или смена портов (port hopping), см. блок «Защита от РКН».")
    if "TCP" in blocked and "UDP" in blocked:
        hint.append("С ПК не доходит ничего: похоже, адрес узла заблокирован целиком. Проверь из другой сети (мобильный "
                    "интернет): если так везде, помогает только новый адрес у хостера или другой узел.")
    if not parts:
        quiet = all(r["verdict"] in ("ok", "skipped", "unknown") for r in rows)
        parts.append("с ПК проходят все проверенные слои" if quiet else "сравнить не с чем")
    for r in rows:
        if r["note"] and r["status"] in ("warn", "crit"):
            detail.append(r["note"])
    return {"addr": n.get("addr", ""), "status": st, "confidence": lc, "value": "; ".join(parts), "detail": detail,
            "hint": " ".join(hint) if st in ("warn", "crit") else "", "cmd": "", "layers": rows}


def report_confidence(rep, sess, srcs, who):
    """Уверенность во всём отчёте и почему она такая. Возвращает (уверенность, причины, сеть ПК)."""
    conf, reasons = "high", []

    def lower(to, why):
        nonlocal conf
        if CONF[to] < CONF[conf]:
            conf = to
        reasons.append(why)

    ips = {}
    for name, n in sess["nodes"].items():
        for a in (n.get("ip"), n.get("addr")):
            if a:
                ips[a] = name
    src = max(set(srcs), key=srcs.count) if srcs else ""
    remap = rep.get("remap") is True
    net = {"label": "не определена", "ip": "", "vpn": "no", "remap": remap}
    if src:
        net["ip"] = re.sub(r"\.\d+$", ".0/24", src) if re.match(r"^\d+\.\d+\.\d+\.\d+$", src) else src
    if src in ips:
        net["vpn"] = "yes"
        lower("low", f"IP источника — адрес узла {ips[src]}: проверка шла через VPN на этот узел. Выключи VPN на ПК и повтори")
    elif src and private(src) and not remap:
        net["vpn"] = "yes"
        lower("low", "IP источника частный: ПК ходил к узлам через VPN или из одной с ними сети")
    elif not src:
        reasons.append("IP источника неизвестен: ни одна попытка не дошла до данных")
    if remap:
        reasons.append("Адреса узлов подменены IOF_PROBE_MAP: это стенд, путь до узлов идёт не через провайдера")
    w = who.split("|")
    if w[0] == "ok":
        net["label"] = " ".join(x for x in (w[1], w[2]) if x) + (f" ({w[3]})" if w[3] else "") or "не определена"
        if w[3] and w[3] != "RU":
            net["vpn"] = "suspect" if net["vpn"] == "no" else net["vpn"]
            lower("medium", f"По whois сеть ПК не российская ({w[3]}): провайдер другой страны или VPN")
    elif w[0] == "private":
        net["label"] = "частный адрес"
    client = obj(rep.get("client"))
    vpn = [txt(x, 80) for x in client.get("vpn") or [] if isinstance(x, str)][:5] if isinstance(client.get("vpn"), list) else []
    if vpn:
        if net["vpn"] == "no":
            net["vpn"] = "suspect"
        lower("medium", "На ПК включён адаптер " + ", ".join(vpn) + ": если это VPN в режиме TUN, трафик шёл через него")
    if client.get("proxy") in ("manual", "pac"):
        reasons.append("В системе задан прокси. На проверку он не влияет: скрипт ходит напрямую")
    lists = [x for x in rep.get("lists") or [] if isinstance(x, dict)] if isinstance(rep.get("lists"), list) else []
    white = [x for x in lists if x.get("list") == "white"]
    black = [x for x in lists if x.get("list") == "black"]
    wok, bok = sum(x.get("ok") is True for x in white), sum(x.get("ok") is True for x in black)
    internet = "unknown" if not white else "ok" if wok == len(white) else "fail" if not wok else "partial"
    filtering = "unknown" if not black else "yes" if not bok else "no" if bok == len(black) else "partial"
    if internet == "fail":
        lower("low", "Не открылся ни один сайт из probe-white.txt: у ПК нет интернета или его режут")
    elif internet == "partial":
        lower("medium", "Открылись не все сайты из probe-white.txt")
    if filtering == "no":
        lower("medium", "Сайты из probe-black.txt открываются: провайдер их не блокирует или трафик идёт в обход (VPN, прокси)")
    elif filtering == "partial":
        reasons.append("Часть сайтов из probe-black.txt открывается")
    return conf, reasons, net, internet, filtering, lists


def read_session(base):
    sess = load(os.path.join(base, "session.json"), None)
    return sess if isinstance(sess, dict) and isinstance(sess.get("nodes"), dict) else None


def probe_session(base):
    sess = {"id": "", "started": 0, "expires": 0, "ttl": 0, "stopped": 0, "lists": {"white": [], "black": []}, "nodes": {}}
    cur = None
    for raw in sys.stdin:
        f = raw.rstrip("\n").split("\t") + [""] * 6
        if f[0] == "P":
            sess.update(id=f[1], started=int(f[2]), ttl=int(f[3]), expires=int(f[2]) + int(f[3]))
        elif f[0] in ("W", "X"):
            sess["lists"]["white" if f[0] == "W" else "black"].append(f[1])
        elif f[0] == "N":
            cur = {"addr": f[2], "local": f[4] == "1", "state": "" if f[3] == "1" else "down", "error": f[5][:200],
                   "ip": "", "port": 0, "fp": "", "hy2_port": 0, "fw": "", "control": None}
            sess["nodes"][f[1]] = cur
        elif f[0] == "F" and cur is not None:
            k, _, v = f[1].partition("=")
            if k == "probe":
                cur["state"] = v
            elif k in ("port", "hy2_port"):
                cur[k] = int(v) if v.isdigit() else 0
            elif k in ("fp", "fw", "ip", "error"):
                cur[k] = v[:200]
            elif k == "trace":
                try:
                    cur["control"] = json.loads(v)
                except ValueError:
                    cur["control"] = {}
    for n in sess["nodes"].values():
        n["state"] = n["state"] or "error"
        n["check"] = check_line(side(n["control"])) if n["state"] == "started" else ""
    started = any(n["state"] == "started" for n in sess["nodes"].values())
    if started:
        write(os.path.join(base, "session.json"), json.dumps(sess, ensure_ascii=False))
    for name, n in sess["nodes"].items():
        if n["state"] == "started":
            print(f"  {name:<20} порт {n['port']:<6} контроль: {n['check']}")
        else:
            text, cmd = NOT_STARTED.get(n["state"], ("мишень не запустилась", ""))
            print(f"  {name:<20} не проверяется: {text}" + (f" ({n['error']})" if n["error"] and not cmd else "")
                  + (f". Исправить на узле: {cmd}" if cmd else ""))
    if not started:
        sys.exit(3)


def probe_stop(base):
    sess = read_session(base)
    if sess and not sess.get("stopped"):
        sess["stopped"] = int(time.time())
        write(os.path.join(base, "session.json"), json.dumps(sess, ensure_ascii=False))


def probe_nodes(base):
    sess = read_session(base)
    if sess:
        print(sess["id"], sess["expires"], sess.get("stopped", 0))
        for name in sess["nodes"]:
            print(name)


def report_srcs(rep):
    out = []
    for t in rep.get("targets") or []:
        if isinstance(t, dict):
            out += side(t)["src"]
    return [s for s in out if re.match(r"^[0-9a-fA-F.:]+$", s)]


def load_report(path, sess, token):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        fail("отчёт не прочитать")
    if token and token.encode() in raw:
        fail("в отчёте есть токен мишеней, такой отчёт не принимаю")
    try:
        rep = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError):
        fail("отчёт не JSON")
    if not isinstance(rep, dict) or rep.get("v") != 1:
        fail("это не отчёт probe.ps1")
    if sess is not None and rep.get("session") != sess["id"]:
        fail(f"отчёт от другой проверки ({txt(rep.get('session'), 20) or 'без номера'}), сейчас {sess['id']}")
    return rep


def probe_src(path):
    srcs = report_srcs(load_report(path, None, ""))
    if srcs:
        print(max(set(srcs), key=srcs.count))


def results(base):
    names = sorted(f for f in os.listdir(base) if re.match(r"^\d{8}-\d{6}(-\d+)?\.json$", f)) if os.path.isdir(base) else []
    return names


def probe_import(base, keep, path):
    sess = read_session(base)
    if sess is None:
        fail("нет сессии проверки с ПК: сначала sudo iof audit probe start")
    try:
        with open(os.path.join(base, "token"), encoding="utf-8") as f:
            token = f.read().strip()
    except OSError:
        token = ""
    rep = load_report(path, sess, token)
    who = ""
    for raw in sys.stdin:
        f = raw.rstrip("\n").split("\t") + [""]
        if f[0] == "W":
            who = f[1]
    by = {}
    for t in rep.get("targets") or []:
        if isinstance(t, dict) and t.get("node") in sess["nodes"] and t["node"] not in by:
            by[t["node"]] = t
    conf, reasons, net, internet, filtering, lists = report_confidence(rep, sess, report_srcs(rep), who)
    client = obj(rep.get("client"))
    out = {"at": int(time.time()), "session": sess["id"], "started": sess["started"], "confidence": conf,
           "reasons": reasons, "net": net, "internet": internet, "filtering": filtering,
           "client": {"os": txt(client.get("os"), 60), "proxy": txt(client.get("proxy"), 10)},
           "lists": [{"host": txt(x.get("host"), 80), "list": x.get("list"), "ok": x.get("ok") is True,
                      "err": txt(x.get("err"), 60)} for x in lists][:40],
           "nodes": {}, "counts": dict.fromkeys(RANK, 0)}
    for name, n in sess["nodes"].items():
        r = node_result(name, n, by.get(name), conf)
        out["nodes"][name] = r
        out["counts"][r["status"]] += 1
    os.makedirs(base, exist_ok=True)
    stamp, i = time.strftime("%Y%m%d-%H%M%S", time.localtime(out["at"])), 1
    name = stamp + ".json"
    while os.path.exists(os.path.join(base, name)):
        i += 1
        name = f"{stamp}-{i}.json"
    write(os.path.join(base, name), json.dumps(out, ensure_ascii=False))
    for old in results(base)[:-max(keep, 1)]:
        os.remove(os.path.join(base, old))
    print_result(out, False)


def print_result(r, full):
    color = os.environ.get("IOF_COLOR") == "1"

    def paint(st, text):
        return f"\033[{COLOR[st]}m{text}\033[0m" if color and st in COLOR else text

    when = time.strftime("%d.%m.%Y %H:%M", time.localtime(r["at"]))
    print(f"Проверка с ПК {r['session']} от {when}: сеть ПК {r['net']['label']}, уверенность {CONF_WORD[r['confidence']]}")
    for why in r["reasons"]:
        print(f"     {why}")
    for name, n in r["nodes"].items():
        print(f"  {paint(n['status'], MARK[n['status']])} {name}: {n['value']}")
        if not full:
            continue
        for line in n["detail"]:
            print(f"       {line}")
        for x in n["layers"]:
            print(f"       {paint(x['status'], MARK[x['status']])} {x['title']}: с ПК {x['pc']}; контроль {x['control']}")
        if n["hint"]:
            print(f"       Что делать: {n['hint']}")
        if n["cmd"]:
            print(f"       Исправить на узле: {n['cmd']}")


def probe_list(base):
    names = results(base)
    if not names:
        print("Проверок с ПК ещё не было: sudo iof audit probe start, затем страница «Безопасность» панели")
        return
    print_result(load(os.path.join(base, names[-1]), {}), True)
    if len(names) > 1:
        print("\nРаньше:")
        for name in reversed(names[:-1]):
            r = load(os.path.join(base, name), {})
            if r:
                c = r["counts"]
                print(f"  {time.strftime('%d.%m.%Y %H:%M', time.localtime(r['at']))}  {r['net']['label']}, "
                      f"уверенность {CONF_WORD[r['confidence']]}: проблем {c['crit']}, внимание {c['warn']}, "
                      f"в порядке {c['good']}, нет данных {c['none']}")


def probe_api(base):
    """Раздел probe для iof api audit: сессия без токена и контроля, последний результат, история."""
    sess, names = read_session(base), results(base)
    pub = None
    if sess:
        pub = {k: sess.get(k) for k in ("id", "started", "expires", "stopped")}
        pub["nodes"] = {name: {k: n.get(k) for k in ("addr", "state", "port", "fw", "error", "local", "check")}
                        for name, n in sess["nodes"].items()}
    hist = []
    for name in names:
        r = load(os.path.join(base, name), {})
        if r:
            hist.append({"at": r["at"], "session": r["session"], "confidence": r["confidence"],
                         "net": r["net"]["label"], "counts": r["counts"]})
    last = load(os.path.join(base, names[-1]), None) if names else None
    return {"session": pub, "last": last, "history": hist}


mode = sys.argv[1]
if mode == "save":
    save(sys.argv[2], sys.argv[3], int(sys.argv[4]))
elif mode == "api":
    api(sys.argv[2])
elif mode == "probe-session":
    probe_session(sys.argv[2])
elif mode == "probe-nodes":
    probe_nodes(sys.argv[2])
elif mode == "probe-stop":
    probe_stop(sys.argv[2])
elif mode == "probe-src":
    probe_src(sys.argv[2])
elif mode == "probe-import":
    probe_import(sys.argv[2], int(sys.argv[3]), sys.argv[4])
elif mode == "probe-list":
    probe_list(sys.argv[2])
else:
    show(sys.argv[2], sys.argv[3], sys.argv[4].split(","), sys.argv[5:])
EOF
)

audit_py() {
  local color=0
  if [[ -t 1 ]]; then color=1; fi
  IOF_COLOR="$color" python3 -c "$AUDIT_PY" "$@"
}

audit_need_python() {
  have python3 || die "iof audit хранит результат в JSON, для этого нужен python3: apt install python3"
}

# Проверка выбранных узлов (-n): блок server, dpi или оба (all, так по умолчанию). В AUDIT_WORSE
# остаются проверки, которые стали хуже прошлого раза
AUDIT_WORSE=""
audit_run() {
  local block="${1:-all}" i failed=() names=()
  case "$block" in
    server|dpi) AUDIT_RUN="$block" ;;
    all)        AUDIT_RUN="server dpi" ;;
    *)          die "используй: iof audit run [server|dpi|all]" ;;
  esac
  audit_need_python
  read_nodes
  read_relays
  select_nodes
  mkdir -p "$AUDIT_DIR"
  chmod 700 "$AUDIT_DIR"
  if [[ "$AUDIT_RUN" == *dpi* ]]; then audit_dpi_prepare; fi
  echo "Проверяю узлы: ${#SEL[@]}, одновременно до $PARALLEL"
  pmap audit_job "${SEL[@]}"
  AUDIT_WORSE="$({ audit_catalog; audit_nodes; audit_results; } | audit_py save "$block" "$AUDIT_DIR" "$AUDIT_KEEP")" \
    || die "не удалось сохранить результат аудита в $AUDIT_DIR"
  for i in "${SEL[@]}"; do
    names+=("${N_NAME[$i]}")
    pm_ok "$i" || failed+=("$i")
  done
  echo
  audit_catalog | audit_py show "$AUDIT_DIR" brief "${AUDIT_RUN// /,}" "${names[@]}"
  if (( ${#failed[@]} > 0 )); then
    echo
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
  fi
  echo
  echo "Подробно и как исправить: sudo iof audit show [узел], в панели — страница «Безопасность»"
}

# Последняя проверка без опроса узлов: все проверки узла, подробности и как исправить
audit_show() {
  local i names=()
  audit_need_python
  [[ -f "$AUDIT_DIR/server.json" || -f "$AUDIT_DIR/dpi.json" ]] || die "проверок ещё не было, сначала: sudo iof audit run"
  read_nodes
  select_nodes "$@"
  for i in "${SEL[@]}"; do names+=("${N_NAME[$i]}"); done
  audit_catalog | audit_py show "$AUDIT_DIR" full server,dpi "${names[@]}"
}

# Для cron раз в сутки: проверка всех узлов и одно сообщение в Telegram, если что-то стало хуже.
# О потере связи с узлом сообщает iof check, здесь это ухудшением не считается
audit_cron() {
  local total
  audit_run all >/dev/null
  if [[ -z "$AUDIT_WORSE" ]]; then return 0; fi
  echo "$AUDIT_WORSE"
  total="$(grep -c . <<<"$AUDIT_WORSE")"
  if (( total > 25 )); then
    AUDIT_WORSE="$(head -n 25 <<<"$AUDIT_WORSE")"$'\n'"… и ещё $((total - 25))"
  fi
  tg_send "Аудит безопасности, стало хуже:"$'\n'"$AUDIT_WORSE"$'\n'"Подробно: sudo iof audit show или страница «Безопасность» панели"
}

# Для страницы «Безопасность» панели: JSON с последними проверками, справочником, историей
# и настройками (строка cron с iof audit, настроен ли Telegram). Узлы не опрашивает
api_audit() {
  local cron tg="no"
  audit_need_python
  read_nodes
  cron="$(crontab -l -u root 2>/dev/null | grep -v '^[[:space:]]*#' | grep -F 'iof audit' | head -n 1 || true)"
  if [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then tg="yes"; fi
  { audit_catalog; audit_nodes; printf 'S\tcron\t%s\nS\ttg\t%s\n' "$cron" "$tg"; } | audit_py api "$AUDIT_DIR"
}


# Проверка доступности узлов с ПК: iof [-n узлы] audit probe start | stop | import | list.
# start поднимает на узлах мишени (n_probe_start) и сразу проходит до них все слои отсюда: это контроль.
# Скрипт probe.ps1 на ПК проходит те же слои и сдаёт сырой отчёт в панель, import считает вердикт.
# Токен мишеней лежит в $PROBE_DIR/token, в вывод iof, лог задачи и JSON он не попадает

PROBE_ID=""
PROBE_TOKEN=""
PROBE_RUN_TTL=""

# PROBE_PORTS: пусто, порт или диапазон a-b
probe_ports_ok() {
  local a b
  if [[ -z "$1" ]]; then return 0; fi
  if [[ "$1" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
  elif [[ "$1" =~ ^[0-9]{1,5}$ ]]; then a="$1"; b="$1"
  else return 1; fi
  (( 10#$a >= 1 && 10#$a <= 10#$b && 10#$b <= 65535 ))
}

# Контрольные списки для ПК создаются при первой проверке. Печатает строки W (белый) и X (чёрный)
# для AUDIT_PY, не больше 10 сайтов в каждом
probe_lists() {
  local f h
  if [[ ! -f "$PROBE_WHITE" ]]; then
    printf '%s\n' "# Проверка с ПК (iof audit probe): сайты, которые из России открываются всегда." \
      "# Если с ПК не откроется ни один, у него нет интернета и результат проверки не в счёт" \
      ya.ru vk.com gosuslugi.ru > "$PROBE_WHITE"
  fi
  if [[ ! -f "$PROBE_BLACK" ]]; then
    printf '%s\n' "# Проверка с ПК (iof audit probe): сайты, давно заблокированные РКН." \
      "# Если они открываются, провайдер не фильтрует или ПК ходит в обход (VPN, прокси)" \
      rutracker.org linkedin.com instagram.com > "$PROBE_BLACK"
  fi
  for f in "$PROBE_WHITE:W" "$PROBE_BLACK:X"; do
    { grep -vE '^[[:space:]]*(#|$)' "${f%:*}" || true; } | awk '{ print $1 }' | head -n 10 | while IFS= read -r h; do
      if host_ok "$h" && [[ "$h" == *.* ]]; then printf '%s\t%s\n' "${f##*:}" "$h"; fi
    done
  done
}

# Для pmap: мишень на узле $1 и контроль до неё. Строки n_probe_start, ip (адрес узла IPv4)
# и trace (JSON контроля, см. AUDIT_NET_PY)
probe_start_job() {
  local i="$1" out ip="${N_ADDR[$1]}" port fp hy2
  out="$(run_on "${N_SSH[$i]}" n_probe_start "$PROBE_ID" "$PROBE_RUN_TTL" "$PROBE_PORTS" "$PROBE_TOKEN")" || return $?
  if ! grep -q '^now=' <<<"$out"; then
    echo "узел не ответил" >&2
    return 1
  fi
  printf '%s\n' "$out"
  if [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    ip="$(timeout 5 getent ahostsv4 "$ip" 2>/dev/null | awk '{ print $1; exit }' || true)"
  fi
  echo "ip=$ip"
  if [[ "$(kv_get "$out" probe)" != "started" || -z "$ip" ]]; then return 0; fi
  port="$(kv_get "$out" port)"
  fp="$(kv_get "$out" fp)"
  hy2="$(kv_get "$out" hy2_port)"
  if ! port_ok "$hy2"; then hy2=0; fi
  echo "trace=$(timeout 120 python3 -c "$AUDIT_NET_PY" trace "$ip" "$port" "$fp" "$hy2" <<<"$PROBE_TOKEN" 2>/dev/null || echo '{}')"
}

probe_stop_job() { run_on "${N_SSH[$1]}" n_probe_stop "$PROBE_ID"; }

# Одна проверка за раз: пока мишени прошлой живы и её не остановили, новая не начинается
probe_free() {
  local head id until stopped
  [[ -f "$PROBE_DIR/session.json" ]] || return 0
  head="$(audit_py probe-nodes "$PROBE_DIR")"
  read -r id until stopped <<<"${head%%$'\n'*}"
  if [[ "${stopped:-0}" == "0" && "${until:-0}" =~ ^[0-9]+$ ]] && (( until > $(date +%s) )); then
    die "уже идёт проверка с ПК $id, мишени живут до $(date -d "@$until" +%H:%M).
  Остановить: sudo iof audit probe stop"
  fi
}

audit_probe_start() {
  local ttl="$PROBE_TTL" i rc=0 msg started failed=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ttl) ttl="${2:-}"; shift; if [[ $# -gt 0 ]]; then shift; fi ;;
      *)     die "используй: iof [-n узлы] audit probe start [--ttl секунд]" ;;
    esac
  done
  if [[ ! "$ttl" =~ ^[0-9]{1,4}$ ]] || (( 10#$ttl < 20 || 10#$ttl > 3600 )); then
    die "срок мишеней (PROBE_TTL в $ENV_FILE или --ttl): от 20 до 3600 секунд"
  fi
  probe_ports_ok "$PROBE_PORTS" || die "PROBE_PORTS в $ENV_FILE: пусто, порт или диапазон a-b, например 40000-40100"
  audit_need_python
  read_nodes
  select_nodes
  mkdir -p "$PROBE_DIR"
  chmod 700 "$AUDIT_DIR" "$PROBE_DIR"
  probe_free
  PROBE_ID="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  PROBE_TOKEN="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  PROBE_RUN_TTL="$((10#$ttl))"
  rm -f "$PROBE_DIR/session.json"
  (umask 077; printf '%s\n' "$PROBE_TOKEN" > "$PROBE_DIR/token")
  started="$(date +%s)"
  echo "Проверка с ПК $PROBE_ID: запускаю мишени на узлах (${#SEL[@]}) на $((PROBE_RUN_TTL / 60)) мин и проверяю их отсюда"
  pmap probe_start_job "${SEL[@]}"
  {
    printf 'P\t%s\t%s\t%s\n' "$PROBE_ID" "$started" "$PROBE_RUN_TTL"
    probe_lists
    for i in "${SEL[@]}"; do
      msg=""
      if ! pm_ok "$i"; then msg="$(pm_err "$i" | grep -v '^[[:space:]]*$' | tail -n 1 || true)"; fi
      printf 'N\t%s\t%s\t%s\t%s\t%s\n' "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(pm_ok "$i" && echo 1 || echo 0)" \
        "$([[ "${N_SSH[$i]}" == "local" ]] && echo 1 || echo 0)" "${msg//$'\t'/ }"
      if pm_ok "$i"; then pm_out "$i" | sed 's/^/F\t/'; fi
    done
  } | audit_py probe-session "$PROBE_DIR" || rc=$?
  for i in "${SEL[@]}"; do
    pm_ok "$i" || failed+=("$i")
  done
  if (( ${#failed[@]} > 0 )); then
    echo
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
  fi
  if (( rc == 3 )); then
    rm -f "$PROBE_DIR/token"
    die "ни на одном узле мишень не запустилась, проверять с ПК нечего"
  fi
  (( rc == 0 )) || die "не удалось записать сессию в $PROBE_DIR"
  echo
  echo "Мишени работают до $(date -d "@$((started + PROBE_RUN_TTL))" +%H:%M). Дальше страница «Безопасность» панели,"
  echo "карточка «Доступность из РФ»: там команда для ПК. Остановить раньше: sudo iof audit probe stop"
}

# Останавливает мишени текущей проверки, сессия остаётся для import. Без сессии убирает мишени
# и их остатки со всех выбранных узлов (-n)
audit_probe_stop() {
  local out="" names=() n i id="" left msg failed=()
  audit_need_python
  read_nodes
  if [[ -f "$PROBE_DIR/session.json" ]]; then out="$(audit_py probe-nodes "$PROBE_DIR")"; fi
  if [[ -n "$out" ]]; then
    id="${out%% *}"
    mapfile -t names < <(tail -n +2 <<<"$out")
    SEL=()
    for n in "${names[@]}"; do
      if i="$(node_index "$n")"; then SEL+=("$i"); fi
    done
  else
    select_nodes
  fi
  PROBE_ID="$id"
  if (( ${#SEL[@]} > 0 )); then
    echo "Останавливаю мишени${id:+ проверки $id} на узлах: ${#SEL[@]}"
    pmap probe_stop_job "${SEL[@]}"
    for i in "${SEL[@]}"; do
      if ! pm_ok "$i"; then failed+=("$i"); continue; fi
      out="$(pm_out "$i")"
      n="$(audit_num "$(kv_get "$out" stopped)")"
      left="$(audit_num "$(kv_get "$out" left)")"
      msg="мишеней не было"
      if (( n > 0 )); then msg="остановлено мишеней: $n"; fi
      if (( left > 0 )); then msg+=", убраны остатки: $left"; fi
      printf '  %-20s %s\n' "${N_NAME[$i]}" "$msg"
    done
  fi
  if [[ -n "$id" ]]; then audit_py probe-stop "$PROBE_DIR"; fi
  if (( ${#failed[@]} > 0 )); then
    echo
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
    echo "Мишени на этих узлах systemd остановит сам по сроку (PROBE_TTL)."
  fi
}

# Отчёт probe.ps1 со stdin: вердикт по слоям в $PROBE_DIR/<время>.json. Адрес ПК, с которого шла
# проверка, уходит в whois регионального реестра: по нему видно сеть и страну. В результат он
# попадает только с маской /24
audit_probe_import() {
  local tmp src who="" rc=0
  audit_need_python
  [[ ! -t 0 ]] || die "отчёт подаётся через stdin: sudo iof audit probe import < iof-probe-report.json"
  [[ -f "$PROBE_DIR/session.json" ]] || die "нет сессии проверки с ПК: сначала sudo iof audit probe start"
  tmp="$(mktemp "$PROBE_DIR/report.XXXXXX")"
  head -c 300000 > "$tmp"
  src="$(audit_py probe-src "$tmp" 2>/dev/null || true)"
  if [[ "$src" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    who="$(timeout 25 python3 -c "$AUDIT_NET_PY" whois "$src" "" 2>/dev/null || echo 'fail|||')"
  fi
  printf 'W\t%s\n' "$who" | audit_py probe-import "$PROBE_DIR" "$AUDIT_KEEP" "$tmp" || rc=$?
  rm -f "$tmp"
  if (( rc != 0 )); then exit 1; fi
  echo
  echo "Подробно по слоям: sudo iof audit probe list, в панели — страница «Безопасность»"
}

audit_probe() {
  local action="${1:-}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    start)  audit_probe_start "$@" ;;
    stop)   audit_probe_stop ;;
    import) audit_probe_import ;;
    list)   audit_need_python; audit_py probe-list "$PROBE_DIR" ;;
    *)      die "используй: iof [-n узлы] audit probe start [--ttl секунд] | stop | import < отчёт | list" ;;
  esac
}

cmd_audit() {
  local action="${1:-}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    run)   audit_run "$@" ;;
    show)  audit_show "$@" ;;
    cron)  audit_cron ;;
    probe) audit_probe "$@" ;;
    *)     die "используй: iof audit run [server|dpi|all] | show [узел] | cron | probe start|stop|import|list" ;;
  esac
}


# Перенос управляющего сервера: iof migrate start | finish | cancel | status
# start на старом сервере ставит iof на новый и копирует туда данные, а у себя запрещает изменения.
# finish на новом снимает роль управляющего со старого (тот остаётся узлом) и ставит задания cron.
# cancel на старом отменяет перенос. Состояние в migrate.conf (key=value): role=source на старом,
# role=target на новом, общий номер переноса id, peer — адрес SSH другого сервера

# Задания cron, которые переезжают вместе с управлением: iof check, iof-nightly
MIGRATE_CRON_RE='(^|[[:space:]/])iof(-nightly)?([[:space:]]|$)'

# Значение ключа $2 из строк key=value в $1
kv_get() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' <<<"$1"; }

# Значение ключа $1 из migrate.conf, пусто, если переноса нет
migrate_get() {
  if [[ -f "$MIGRATE_FILE" ]]; then kv_get "$(cat "$MIGRATE_FILE")" "$1"; fi
}

# Пока идёт перенос отсюда, изменения здесь не попали бы на новый сервер, поэтому они запрещены
migrate_guard() {
  if [[ "$(migrate_get role)" != "source" ]]; then return 0; fi
  die "идёт перенос управления на $(migrate_get peer), здесь изменения заблокированы.
  Завершить: в панели нового сервера (Перенос) или на нём: sudo iof migrate finish
  Отменить:  sudo iof migrate cancel"
}

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

# Как новый сервер будет заходить на этот: root@<адрес узла local>[:порт sshd]
migrate_self_default() {
  local i port
  for i in "${!N_NAME[@]}"; do
    if [[ "${N_SSH[$i]}" != "local" ]]; then continue; fi
    port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
    if [[ -n "$port" && "$port" != "22" ]]; then
      printf 'root@%s:%s' "${N_ADDR[$i]}" "$port"
    else
      printf 'root@%s' "${N_ADDR[$i]}"
    fi
    return 0
  done
  return 1
}

# Ключ iof в authorized_keys пользователя из $1 (user@host[:port]) на этом сервере:
# после переноса новый сервер заходит сюда как на обычный узел
migrate_trust_self() {
  local user="${1%%@*}" home pub f
  home="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$home" ]] || die "на этом сервере нет пользователя $user (--self)"
  pub="$(cat "$SSH_KEY.pub")"
  f="$home/.ssh/authorized_keys"
  (umask 077; mkdir -p "$home/.ssh"; touch "$f")
  if grep -qxF "$pub" "$f"; then return 0; fi
  # Без перевода строки в конце файла ключ склеился бы с последней строкой
  if [[ -s "$f" && -n "$(tail -c 1 "$f")" ]]; then echo >> "$f"; fi
  printf '%s\n' "$pub" >> "$f"
  if [[ "$user" != "root" ]]; then chown "$user:" "$home/.ssh" "$f"; fi
}

# nodes.conf для нового сервера ($1, правится на месте): узел local становится $2 (так новый
# сервер заходит на этот), а узел с адресом SSH нового сервера ($3), если он был, становится local
migrate_nodes_conf() {
  local file="$1" self="$2" target="$3"
  [[ -f "$file" ]] || return 0
  awk -F'|' -v self="$self" -v target="${target%:22}" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*(#|$)/ { print; next }
    {
      t = trim($3); n = t; sub(/:22$/, "", n)
      if (t == "" || t == "local") t = self
      else if (n == target) t = "local"
      else { print; next }
      line = trim($1) " | " trim($2) " | " t " | " trim($4)
      sub(/[[:space:]]+$/, "", line)
      print line
    }' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# Собирает в папке $1 всё, что нужно новому серверу: data (копия $BASE с правками для него),
# ssh (ключ iof и known_hosts), src (клон репозитория $IOF_SRC)
migrate_bundle() {
  local stage="$1" id="$2" self="$3" target="$4" tpl cn
  mkdir -p "$stage/ssh"
  cp -a "$BASE" "$stage/data"
  rm -rf "$stage/data/migrate.conf" "$stage/data/.migrate-probe" "$stage/data"/.key.*
  cp -a "$IOF_SRC" "$stage/src"
  cp -p "$SSH_KEY" "$SSH_KEY.pub" "$stage/ssh/"
  if [[ -f /root/.ssh/known_hosts ]]; then cp -p /root/.ssh/known_hosts "$stage/ssh/"; fi

  migrate_nodes_conf "$stage/data/nodes.conf" "$self" "$target"

  # Шаблон Hysteria2 переезжает в папку iof. Сертификата, на который он ссылается, на новом
  # сервере нет, поэтому CN записывается явно. HY2_TEMPLATE нужен и iof, и панели
  tpl="${HY2_TEMPLATE:-/etc/hysteria/config.yaml}"
  if [[ -f "$tpl" ]]; then
    install -m 600 "$tpl" "$stage/data/hy2-template.yaml"
    env_set "$stage/data/iof.env" HY2_TEMPLATE "$BASE/hy2-template.yaml"
    env_set "$stage/data/web.env" HY2_TEMPLATE "$BASE/hy2-template.yaml"
    cn="${HY2_CN:-$(hy2_template_cn "$tpl")}"
    if [[ "$cn" =~ ^[A-Za-z0-9*._-]+$ ]]; then env_set "$stage/data/iof.env" HY2_CN "$cn"; fi
  else
    echo "   Внимание: нет шаблона Hysteria2 $tpl, на новом сервере iof hy2 install не заработает, пока не задашь HY2_TEMPLATE"
  fi

  # Задания cron ставятся на новом сервере только в iof migrate finish, иначе ночное
  # обслуживание и проверки шли бы с двух серверов
  { crontab -l -u root 2>/dev/null || true; } | { grep -E "$MIGRATE_CRON_RE" || true; } > "$stage/data/migrate-cron"

  printf 'role=target\nid=%s\npeer=%s\nstarted=%s\n' "$id" "$self" "$(date '+%F %T')" > "$stage/data/migrate.conf"
  chmod 600 "$stage/data/migrate.conf" "$stage/data/migrate-cron"
}

# iof migrate start <хост> [ssh_порт] [--user имя] [--key файл | --key-stdin | --password-stdin | --key-installed]
#   [--self user@host[:port]]
# На старом сервере. Вход как у iof node add. --self: как новый сервер будет заходить на этот,
# по умолчанию root@<адрес узла local>. Повторный запуск с тем же сервером безопасен
migrate_start() {
  local pos=() user="root" auth="ask" keyfile="" self="" host port target id role peer started
  local self_host self_port out err probe stage status total bad=()
  while (( $# > 0 )); do
    case "$1" in
      --user|--key|--self)
        [[ $# -ge 2 ]] || die "после $1 нужно значение"
        case "$1" in
          --user) user="$2" ;;
          --key)  auth="key-file"; keyfile="$2" ;;
          --self) self="$2" ;;
        esac
        shift 2 ;;
      --key-stdin)      auth="key-stdin"; shift ;;
      --password-stdin) auth="password-stdin"; shift ;;
      --key-installed)  auth="installed"; shift ;;
      -*) die "неизвестный параметр $1" ;;
      *)  pos+=("$1"); shift ;;
    esac
  done
  host="${pos[0]:-}"; port="${pos[1]:-22}"
  [[ -n "$host" ]] || die "используй: iof migrate start <хост> [ssh_порт] [--user имя] [--key файл]"
  host_ok "$host" || die "хост '$host': нужен IPv4 или имя хоста (латиница, цифры, точка, дефис)"
  user_ok "$user" || die "пользователь '$user': строчная латиница, цифры, _ и -"
  port_ok "$port" || die "ssh-порт '$port' вне 1-65535"
  port="$((10#$port))"
  target="$user@$host"
  if (( port != 22 )); then target="$target:$port"; fi

  read_nodes
  [[ -d "$IOF_SRC/.git" ]] || die "нет клона репозитория в $IOF_SRC, из него iof ставится на новый сервер"
  [[ -s "$SSH_KEY" && -s "$SSH_KEY.pub" ]] || die "нет ключа iof $SSH_KEY"
  role="$(migrate_get role)"
  peer="$(migrate_get peer)"
  if [[ "$role" == "target" ]]; then die "этот сервер сам принимает управление от $peer, сначала: sudo iof migrate finish"; fi
  if [[ "$role" == "source" ]] && ! ssh_same "$peer" "$target"; then
    die "уже идёт перенос на $peer. Отменить его: sudo iof migrate cancel"
  fi
  id="$(migrate_get id)"
  if [[ -z "$id" ]]; then id="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi
  started="$(migrate_get started)"
  started="${started:-$(date '+%F %T')}"

  if [[ -z "$self" ]]; then
    self="$(migrate_self_default)" \
      || die "этот сервер не узел (в nodes.conf нет local): укажи, как новый сервер будет заходить сюда, --self root@адрес[:порт]"
  fi
  [[ "$self" =~ ^([a-z_][a-z0-9_-]*)@([^:@]+)(:([0-9]+))?$ ]] || die "--self '$self': нужен вид root@адрес[:порт]"
  self_host="${BASH_REMATCH[2]}"
  self_port="${BASH_REMATCH[4]:-22}"
  host_ok "$self_host" && port_ok "$self_port" || die "--self '$self': нужен вид root@адрес[:порт]"

  echo "== Вход на $target"
  read_auth "$auth" "$keyfile" "$user" "$host"
  if [[ "$AUTH_MODE" == "password" ]]; then ensure_sshpass; fi
  IM_HOST=("$host"); IM_PORT=("$port"); IM_USER=("$user"); IM_MODE=("$AUTH_MODE")
  IM_PASS=("$AUTH_PASS"); IM_KEY=("$AUTH_KEY")
  local rc=0
  err="$(push_key_job 0 2>&1 >/dev/null)" || rc=1
  if [[ -n "$AUTH_KEY" ]] && have shred; then shred -u "$AUTH_KEY" 2>/dev/null || true; fi
  (( rc == 0 )) || die "вход на $target: ${err:-не удался}"
  echo "   ключ iof работает"

  echo "== Проверка $target"
  probe="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  PM_DIRS+=("$BASE/.migrate-probe")
  printf '%s\n' "$probe" > "$BASE/.migrate-probe"
  out="$(run_on "$target" n_migrate_check)" || die "не удалось проверить $target"
  rm -f "$BASE/.migrate-probe"
  [[ "$(kv_get "$out" probe)" != "$probe" ]] || die "$target — это этот же сервер"
  [[ "$(kv_get "$out" apt)" == "yes" ]] || die "на $target нет apt-get ($(kv_get "$out" os)), нужен Ubuntu или Debian"
  if [[ "$(kv_get "$out" role)" == "source" ]]; then die "с $target самого идёт перенос, сначала отмени его там"; fi
  if [[ "$(kv_get "$out" nodes)" != "0" && "$(kv_get "$out" id)" != "$id" ]]; then
    die "на $target уже есть свои узлы iof ($(kv_get "$out" nodes) в /root/iof/nodes.conf), перенос их затрёт. Если они не нужны, убери их там: sudo mv /root/iof /root/iof.old"
  fi
  echo "   $(kv_get "$out" os), можно переносить"

  # С этого момента изменения здесь запрещены (migrate_guard), иначе они не попали бы на новый сервер
  printf 'role=source\nid=%s\npeer=%s\nself=%s\nstarted=%s\n' "$id" "$target" "$self" "$started" > "$MIGRATE_FILE"
  chmod 600 "$MIGRATE_FILE"
  migrate_trust_self "$self"

  echo "== Копирую на $target данные iof, ключ iof и клон репозитория"
  stage="$(mktemp -d)"
  PM_DIRS+=("$stage")
  migrate_bundle "$stage" "$id" "$self" "$target"
  tar -czf - -C "$stage" . \
    | ssh_cmd "$target" "$(remote_sudo "$target")bash -c 'rm -rf $MIGRATE_INBOX && mkdir -m 700 $MIGRATE_INBOX && tar -xzf - -C $MIGRATE_INBOX'" \
    || die "не удалось передать данные на $target. Повторить: та же команда, отменить перенос: sudo iof migrate cancel"

  echo "== Ставлю iof на $target"
  out="$(run_on "$target" n_migrate_receive "$id" "$MIGRATE_INBOX")" \
    || die "$target не принял управление, причина выше. Повторить: та же команда, отменить перенос: sudo iof migrate cancel"
  echo "   готово, версия ${out#received }"

  echo "== Проверка: видит ли новый сервер все узлы"
  status="$(ssh_cmd "$target" "$(remote_sudo "$target")/usr/local/bin/iof api status")" || die "iof на $target не отвечает"
  mapfile -t bad < <(awk '/^== /{ n = substr($0, 4) } /^reachable=no$/{ print n }' <<<"$status")
  total="$(grep -c '^== ' <<<"$status" || true)"
  echo "Узлов: $total, на связи с $host: $(( total - ${#bad[@]} ))"
  if (( ${#bad[@]} > 0 )); then
    echo "Ошибки (${#bad[@]}): нет связи с нового сервера"
    printf '  %s\n' "${bad[@]}"
    echo "Обычно это файрвол у хостера (SSH открыт только для IP этого сервера) или запрет входа root по ключу."
    echo "Почини и проверь на новом сервере: sudo iof status"
  fi

  echo
  echo "Управление скопировано на $target. Этот сервер пока управляющий, но изменения на нём заблокированы."
  echo "Дальше открой панель нового сервера: ssh -p $port -L 8089:127.0.0.1:8088 $user@$host"
  echo "и http://127.0.0.1:8089/ → Перенос → «Завершить перенос». Или на нём: sudo iof migrate finish"
  echo "Отменить перенос: sudo iof migrate cancel"
}

# iof migrate finish [--skip-old]: на новом сервере. Снимает роль управляющего со старого
# (он остаётся узлом) и ставит задания cron. --skip-old: старый сервер недоступен, он пропускается
migrate_finish() {
  local skip=0 id peer dest="" cur add
  if [[ "${1:-}" == "--skip-old" ]]; then skip=1; elif [[ -n "${1:-}" ]]; then die "неизвестный параметр $1"; fi
  [[ "$(migrate_get role)" == "target" ]] || die "этот сервер не принимает управление (нет $MIGRATE_FILE с role=target)"
  id="$(migrate_get id)"
  peer="$(migrate_get peer)"
  exec </dev/null

  if (( skip )); then
    echo "Старый сервер $peer пропускаю. Если он ещё работает, сними с него iof вручную, иначе ночное обслуживание пойдёт и оттуда:"
    echo "  sudo crontab -e   (убрать строки с iof)"
    echo "  sudo systemctl disable --now iof-web && sudo rm /usr/local/bin/iof /usr/local/sbin/iof-nightly"
  else
    echo "== Снимаю управление со старого сервера $peer"
    dest="$(run_on "$peer" n_migrate_demote "$id" "$MIGRATE_CRON_RE")" \
      || die "не удалось снять управление с $peer, причина выше. Если он недоступен совсем: sudo iof migrate finish --skip-old"
  fi

  if [[ -s "$BASE/migrate-cron" ]]; then
    cur="$(crontab -l -u root 2>/dev/null || true)"
    add="$(grep -vxF -f <(printf '%s\n' "$cur") "$BASE/migrate-cron" || true)"
    if [[ -n "$add" ]]; then
      { if [[ -n "$cur" ]]; then printf '%s\n' "$cur"; fi; printf '%s\n' "$add"; } | crontab -u root -
      echo "В cron добавлено:"
      sed 's/^/  /' <<<"$add"
    fi
  else
    echo "На старом сервере заданий iof в cron не было. Ночное обслуживание: sudo crontab -e, строка: 0 4 * * * /usr/local/sbin/iof-nightly"
  fi
  rm -f "$BASE/migrate-cron" "$MIGRATE_FILE"

  echo
  echo "Перенос завершён, управляющий сервер теперь этот."
  if [[ -n "$dest" ]]; then
    echo "Старый сервер остался узлом. Его прежние данные iof: $dest, удали их, когда убедишься, что всё работает."
  fi
}

# iof migrate cancel: на старом сервере. Снимает блокировку и убирает с нового сервера iof и копию данных
migrate_cancel() {
  local id peer keep=0 i
  [[ "$(migrate_get role)" == "source" ]] || die "отсюда перенос не начат"
  id="$(migrate_get id)"
  peer="$(migrate_get peer)"
  exec </dev/null
  read_nodes
  # Если новый сервер ещё и узел этого, ключ iof на нём нужен
  for i in "${!N_SSH[@]}"; do
    if ssh_same "${N_SSH[$i]}" "$peer"; then keep=1; fi
  done
  echo "== Убираю копию с $peer"
  # Строку «Ошибки (» панель показывает как «готово с ошибками»
  if ! run_on "$peer" n_migrate_abort "$id" "$keep" "$MIGRATE_INBOX" "$MIGRATE_CRON_RE"; then
    echo "Ошибки (1): $peer недоступен, там могли остаться iof, копия данных и ключ iof. Удали их на нём:"
    echo "  sudo systemctl disable --now iof-web; sudo rm -rf /root/iof /root/.iof-migrate /root/.ssh/iof_ed25519 /root/.ssh/iof_ed25519.pub"
  fi
  rm -f "$MIGRATE_FILE"
  echo "Перенос отменён, этот сервер снова управляющий без ограничений."
}

migrate_status() {
  case "$(migrate_get role)" in
    source)
      echo "Идёт перенос управления отсюда на $(migrate_get peer), начат $(migrate_get started)."
      echo "Изменения здесь заблокированы. Завершить: на новом сервере sudo iof migrate finish. Отменить: sudo iof migrate cancel" ;;
    target)
      echo "Этот сервер принимает управление от $(migrate_get peer), начато $(migrate_get started)."
      echo "Проверь, что все узлы на связи (sudo iof status), затем: sudo iof migrate finish" ;;
    *)
      echo "Переноса нет. Начать: sudo iof migrate start <хост> [ssh_порт]" ;;
  esac
}

cmd_migrate() {
  local action="${1:-status}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    start)  migrate_start "$@" ;;
    finish) migrate_finish "$@" ;;
    cancel) migrate_cancel ;;
    status) migrate_status ;;
    *)      die "используй: iof migrate start | finish | cancel | status" ;;
  esac
}

usage() {
  cat <<'EOF'
Island of Freedom управление VPN-серверами // by meldevlp

Общее
  iof status                  сводная таблица по узлам
  iof check                   проверка для cron, уведомление в Telegram при изменениях
  iof exec "команда"          выполнить команду на узлах
  iof refresh                 пересобрать все ссылки hy2 и ключи awg
  iof init                    первичная настройка управляющего сервера
  iof api status|service|updates   данные для веб-панели в виде key=value (api audit — JSON)
  iof update [--no-web]       обновить iof и веб-панель с GitHub (клон в /opt/iof)
  iof version                 установленная версия (коммит и дата)

Узлы
  iof node import файл        добавить много серверов по паролям root (строки: имя | ip | пароль | подпись | ssh_порт)
  iof node add имя ip [подпись] [порт]   добавить один сервер, пароль спросит
      --user mel                вход не под root (нужен sudo без пароля)
      --key файл                вход SSH-ключом вместо пароля
      --key-installed           ключ iof (/root/.ssh/iof_ed25519.pub) уже добавлен на сервер
      --addr адрес              адрес для клиентов, если отличается от адреса SSH
  iof node list               список узлов
  iof node del имя            убрать узел из списка (сервер не трогает)

Hysteria2
  iof hy2 install all         поставить на все узлы, где её нет (конфиг по образцу этого сервера)
  iof hy2 install de-1 'nl-*' на выбранные узлы, --force перезапишет конфиг и там, где уже стоит
  iof hy2 add "Подпись"       создать группу ссылок по всем узлам
  iof hy2 del "Подпись"       удалить группу
  iof hy2 list                список групп
  iof hy2 show "Подпись"      показать ссылки группы
  iof hy2 refresh             пересобрать все группы
  iof hy2 status              состояние Hysteria2 на узлах
  iof hy2 restart узлы        перезапустить Hysteria2 (all — на всех) и проверить, что поднялась

AmneziaWG 2.0
  iof awg add "Имя"           создать клиента на всех узлах и выдать ключи vpn://
  iof awg keys "Имя"          снова показать ключи
  iof awg del "Имя"           удалить клиента со всех узлов
  iof awg show "Имя" [France] показать конфиги и QR-коды
  iof awg export "Имя"        скопировать конфиги в домашнюю папку для WinSCP
  iof awg list                клиенты, созданные через iof
  iof awg clients             все клиенты на каждом сервере с проверкой дублей
  iof awg refresh             пересобрать ключи всех клиентов
  iof awg status              состояние AmneziaWG на узлах

VLESS
  iof vless                   в разработке (WIP)

Ретрансляторы (для hy2 и awg сразу)
  iof relay add узел через    например: iof relay add france netherlands
  iof relay del узел через    убрать ретранслятор
  iof relay list              ретрансляторы и их состояние
  iof relay apply             заново применить правила

Безопасность (run, show и cron на узлах ничего не меняют)
  iof audit run [блок]        проверить узлы. Блоки: server — SSH, файрвол, подбор паролей, обновления,
                              открытые порты; dpi — чем узел заметен для фильтров и зондов: маскировка
                              Hysteria2 и AmneziaWG, что видно снаружи, репутация адреса; all — оба (по умолчанию)
  iof audit show [узел]       последняя проверка: все пункты, что не так и как исправить
  iof audit cron              для cron раз в сутки: проверка и сообщение в Telegram, если стало хуже

Доступность из РФ, проверка с ПК (на узлах на время проверки работают мишени)
  iof audit probe start       мишени на узлах на PROBE_TTL секунд (900) и проверка до них отсюда;
                              --ttl секунд — свой срок. Скрипт для ПК даёт страница «Безопасность» панели
  iof audit probe stop        остановить мишени раньше срока
  iof audit probe import < отчёт.json   принять отчёт скрипта с ПК, если он не дошёл до панели
  iof audit probe list        последняя проверка по слоям и прошлые проверки

Перенос управляющего сервера (этот остаётся VPN-узлом, клиенты ничего не заметят)
  iof migrate start хост [порт]   на старом: поставить iof на новый сервер и скопировать туда данные
      --user, --key, --key-installed  вход как у node add
      --self root@адрес[:порт]    как новый сервер будет заходить сюда (по умолчанию адрес узла local)
  iof migrate finish          на новом: снять управление со старого (--skip-old, если тот недоступен)
  iof migrate cancel          на старом: отменить перенос
  iof migrate status          идёт ли перенос

Выбор узлов: -n перед командой ограничивает status, check, exec, hy2 status, awg status, awg clients, audit
  iof -n 'de-*' status
  iof -n de-1,de-2 exec "apt update"
Сколько узлов одновременно: PARALLEL в /root/iof/iof.env (по умолчанию 20)
EOF
}


# Точка входа

[[ $EUID -eq 0 ]] || die "запусти от root: sudo iof ..."

while [[ "${1:-}" == "-n" ]]; do
  IOF_ONLY="${2:-}"
  [[ -n "$IOF_ONLY" ]] || die "после -n укажи узлы, например: iof -n 'de-*' status"
  shift 2
done

cmd="${1:-}"
if [[ $# -gt 0 ]]; then shift; fi

# Пока идёт перенос отсюда, команды, которые что-то меняют, запрещены
case "$cmd:${1:-}" in
  init:*|refresh:*|node:add|node:import|node:del|relay:add|relay:del|relay:apply) migrate_guard ;;
  hy2:add|hy2:del|hy2:refresh|hy2:install|awg:add|awg:del|awg:refresh) migrate_guard ;;
esac
# Мишени проверки с ПК меняют узлы, а import пишет результат сюда, а не на новый сервер
case "$cmd:${1:-}:${2:-}" in
  audit:probe:start|audit:probe:stop|audit:probe:import) migrate_guard ;;
esac

case "$cmd" in
  hy2)     cmd_hy2 "$@" ;;
  awg)     cmd_awg "$@" ;;
  vless)   cmd_vless "$@" ;;
  node)    cmd_node "$@" ;;
  relay)   cmd_relay "$@" ;;
  migrate) cmd_migrate "$@" ;;
  audit)   cmd_audit "$@" ;;
  status)  cmd_status ;;
  check)   cmd_check ;;
  exec)    cmd_exec "$@" ;;
  refresh) cmd_refresh ;;
  api)     cmd_api "$@" ;;
  update)  cmd_update "$@" ;;
  version) echo "iof $IOF_VERSION" ;;
  init)    cmd_init ;;
  *)       usage ;;
esac
