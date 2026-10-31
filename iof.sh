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
SSH_KEY="/root/.ssh/iof_ed25519"

# Настройки по умолчанию, переопределяются в iof.env
TG_TOKEN=""
TG_CHAT=""
PARALLEL=20
IOF_SRC="/opt/iof"   # клон репозитория для iof update
IOF_ONLY=""
if [[ -f "$ENV_FILE" ]]; then
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
  ver="$(hysteria version 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}' || true)"
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
  ver="$(hysteria version 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}' || true)"

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

# Всё, что run_on передаёт на узел
NODE_FUNCS=(
  n_defaults n_err n_yaml_value n_urlencode
  n_hy2_port n_hy2_userpass n_hy2_user_add n_hy2_user_del n_hy2_restart n_hy2_add n_hy2_del n_hy2_install
  n_awg_find n_awg_running n_awg_iface n_awg_table_pubs n_awg_table_add n_awg_table_del n_awg_pubkey
  n_awg_clients n_awg_backup n_awg_add n_awg_del
  n_status
  n_free_ports n_relay_apply n_relay_status
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

# Удаляет из индекса (файл $1) строку с ключом $2, при переданных $3 дописывает новую
index_set() {
  local file="$1" name="$2" label="${3:-}"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -v -P "^\Q$name\E\t" "$file" > "${file}.tmp" || true
  if [[ -n "$label" ]]; then
    printf '%s\t%s\t%s\n' "$name" "$label" "$(date '+%F %T')" >> "${file}.tmp"
  fi
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
  local i state prev bad=0 changes=()
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
    if [[ "$state" != "ok" ]]; then bad=$((bad + 1)); fi
    echo "${N_NAME[$i]}: $state"
  done
  if (( ${#changes[@]} > 0 )); then
    tg_send "$(printf '%s\n' "${changes[@]}")"
  fi
  (( bad == 0 ))
}

# Данные для веб-панели (iof-web): блок на узел, первая строка "== имя", дальше key=value.
# Поля те же, что отдаёт n_status, плюс адрес, подпись, отклик и проблемы через "; "
cmd_api() {
  case "${1:-}" in
    status) api_status ;;
    *)      die "используй: iof api status" ;;
  esac
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

# Раздача ключа по паролю на узел с индексом $1 в массивах IM_*
push_key_job() {
  local j="$1" ip="${IM_IP[$1]}" port="${IM_PORT[$1]}" pub rc=0
  pub="$(cat "$SSH_KEY.pub")"
  [[ -n "$pub" ]] || { echo "нет публичного ключа" >&2; return 1; }
  SSHPASS="${IM_PASS[$j]}" sshpass -e ssh -p "$port" \
    -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=10 "root@$ip" \
    "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys" \
    >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    5) echo "неверный пароль root" >&2; return 1 ;;
    6) echo "ключ хоста изменился, удали старую запись: ssh-keygen -R $ip" >&2; return 1 ;;
    255) echo "нет связи по SSH или вход root по паролю запрещён" >&2; return 1 ;;
    *) echo "ошибка входа по паролю (код $rc)" >&2; return 1 ;;
  esac
  ssh -i "$SSH_KEY" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "root@$ip" true >/dev/null 2>&1 || { echo "пароль подошёл, но вход по ключу не работает" >&2; return 1; }
}

# Раздаёт ключ на узлы из массивов IM_NAME IM_IP IM_PASS IM_TITLE IM_PORT и дописывает
# удачные в nodes.conf. Код 0, если добавлен хотя бы один узел
onboard_nodes() {
  local j target ok=0
  local failed=()
  mkdir -p "$BASE"
  chmod 700 "$BASE"
  if [[ ! -f "$SSH_KEY" ]]; then
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "iof@$(hostname)" >/dev/null || die "не удалось создать SSH-ключ"
  fi
  [[ -s "$SSH_KEY.pub" ]] || die "нет публичного ключа $SSH_KEY.pub"
  if ! have sshpass; then
    echo "Ставлю sshpass..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null 2>&1 \
      || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null 2>&1; } \
      || die "не удалось установить sshpass"
  fi
  touch "$NODES_FILE"

  echo "Раздаю SSH-ключ на узлы: ${#IM_NAME[@]}, одновременно до $PARALLEL"
  pmap push_key_job "${!IM_NAME[@]}"
  for j in "${!IM_NAME[@]}"; do
    if pm_ok "$j"; then
      target="root@${IM_IP[$j]}"
      if [[ "${IM_PORT[$j]}" != "22" ]]; then target="$target:${IM_PORT[$j]}"; fi
      printf '%s | %s | %s | %s\n' "${IM_NAME[$j]}" "${IM_IP[$j]}" "$target" "${IM_TITLE[$j]}" >> "$NODES_FILE"
      ok=$((ok + 1))
    else
      failed+=("$j")
    fi
  done
  echo "Добавлено в nodes.conf: $ok"
  if (( ${#failed[@]} > 0 )); then
    echo "Не удалось (${#failed[@]}), в nodes.conf не попали:"
    for j in "${failed[@]}"; do
      printf '  %-20s %-16s %s\n' "${IM_NAME[$j]}" "${IM_IP[$j]}" "$(pm_err "$j" | tail -n 1)"
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
  IM_NAME=(); IM_IP=(); IM_PASS=(); IM_TITLE=(); IM_PORT=()
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
    [[ "$seen" != *" $name "* ]] || die "имя '$name' встречается в файле дважды"
    seen+="$name "
    if node_index "$name" >/dev/null 2>&1; then
      echo "Пропускаю $name: уже есть в nodes.conf"
      continue
    fi
    IM_NAME+=("$name"); IM_IP+=("$ip"); IM_PASS+=("$pw"); IM_TITLE+=("${title:-$name}"); IM_PORT+=("${port:-22}")
  done < "$file"
  (( ${#IM_NAME[@]} > 0 )) || die "в файле нет новых узлов"

  onboard_nodes || true
  echo
  echo "Пароли больше не нужны, удали файл: shred -u $file"
  echo "Дальше: sudo iof hy2 install all"
}

cmd_node_add() {
  local name="${1:-}" ip="${2:-}" title="${3:-}" port="${4:-22}" pw
  [[ -n "$name" && -n "$ip" ]] || die "используй: iof node add <имя> <ip> [подпись] [ssh_порт]"
  node_name_ok "$name" || die "имя: только латиница, цифры, точка, дефис, подчёркивание"
  N_NAME=()
  if nodes_present; then
    read_nodes
    if node_index "$name" >/dev/null; then die "узел '$name' уже есть"; fi
  fi
  read -rsp "Пароль root для $ip: " pw
  echo
  [[ -n "$pw" ]] || die "пароль пустой"
  IM_NAME=("$name"); IM_IP=("$ip"); IM_PASS=("$pw"); IM_TITLE=("${title:-$name}"); IM_PORT=("$port")
  onboard_nodes || exit 1
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
    echo "Ошибки:"
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
  for l in "${labels[@]}"; do
    echo "Hysteria2: пересобираю '$l'"
    hy2_add "$l" || echo "Не удалось обновить: $l"
  done
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

# Установка на узлы. Шаблон: конфиг Hysteria2 управляющего сервера (или $HY2_TEMPLATE),
# CN сертификата берётся из его сертификата
hy2_install() {
  local force=0 a i out tplsrc cert
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
  HY2_INST_CN=""
  cert="$(awk '/^[[:space:]]*cert:/{print $2; exit}' "$tplsrc" | tr -d "\"'")"
  if [[ -n "$cert" && -f "$cert" ]]; then
    HY2_INST_CN="$(openssl x509 -noout -subject -in "$cert" 2>/dev/null | sed -nE 's/.*CN[[:space:]]*=[[:space:]]*([^,/]+).*/\1/p')"
  fi
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
    *)       die "используй: iof hy2 add | del | list | show | refresh | status | install" ;;
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

usage() {
  cat <<'EOF'
Island of Freedom управление VPN-серверами // by meldevlp

Общее
  iof status                  сводная таблица по узлам
  iof check                   проверка для cron, уведомление в Telegram при изменениях
  iof exec "команда"          выполнить команду на узлах
  iof refresh                 пересобрать все ссылки hy2 и ключи awg
  iof init                    первичная настройка управляющего сервера
  iof api status              состояние узлов в виде key=value для веб-панели
  iof update [--no-web]       обновить iof и веб-панель с GitHub (клон в /opt/iof)

Узлы
  iof node import файл        добавить много серверов по паролям root (строки: имя | ip | пароль | подпись | ssh_порт)
  iof node add имя ip [подпись] [порт]   добавить один сервер, пароль спросит
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

Выбор узлов: -n перед командой ограничивает status, check, exec, hy2 status, awg status, awg clients
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

case "$cmd" in
  hy2)     cmd_hy2 "$@" ;;
  awg)     cmd_awg "$@" ;;
  vless)   cmd_vless "$@" ;;
  node)    cmd_node "$@" ;;
  relay)   cmd_relay "$@" ;;
  status)  cmd_status ;;
  check)   cmd_check ;;
  exec)    cmd_exec "$@" ;;
  refresh) cmd_refresh ;;
  api)     cmd_api "$@" ;;
  update)  cmd_update "$@" ;;
  init)    cmd_init ;;
  *)       usage ;;
esac
