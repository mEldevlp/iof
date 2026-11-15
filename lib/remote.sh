#!/usr/bin/env bash


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
  # Смена портов Hysteria2: drop-in службы и скрипт, который он запускает перед её стартом
  HOP_DROPIN="/etc/systemd/system/hysteria-server.service.d/iof-hop.conf"
  HOP_CLEAN="/usr/local/sbin/iof-hy2-hop-clean"
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

# Строка listen из $CONFIG тремя полями «адрес|основной порт|остальные порты». Адрес бывает пустым
# (listen: :443), остальные порты — диапазон смены портов: listen: :443,10000-19999 даёт |443|10000-19999.
# Hysteria2 слушает основной порт, а остальные перенаправляет на него сама. Если listen начинается
# с диапазона (:20000-50000), основной порт — его начало, а в остальных весь диапазон
n_hy2_listen() {
  local s host ports base rest=""
  s="$(sed -n 's/^listen:[[:space:]]*//p' "$CONFIG" 2>/dev/null | sed -E "s/[[:space:]]+#.*\$//; s/[\"']//g; s/[[:space:]]+\$//" | head -n 1 || true)"
  if [[ -z "$s" ]]; then s=":443"; fi
  host=""
  ports="$s"
  if [[ "$s" == *:* ]]; then host="${s%:*}"; ports="${s##*:}"; fi
  base="${ports%%[,-]*}"
  if [[ "$ports" == "$base,"* ]]; then rest="${ports#*,}"
  elif [[ "$ports" == "$base-"* ]]; then rest="$ports"; fi
  printf '%s|%s|%s\n' "$host" "$base" "$rest"
}

# Заменяет первую строку listen в $CONFIG на «listen: $1» (или дописывает её). Файл остаётся тем же:
# права и владелец не меняются
n_hy2_listen_set() {
  local tmp
  tmp="$(mktemp)"
  awk -v v="$1" '!done && /^listen:/ { print "listen: " v; done = 1; next } { print } END { if (!done) print "listen: " v }' "$CONFIG" > "$tmp"
  cat "$tmp" > "$CONFIG"
  rm -f "$tmp"
}

# Версия hysteria без v в начале: 2.13.0
n_hy2_version() {
  hysteria version 2>/dev/null | awk -F':[[:space:]]*' '/^Version/ { sub(/^v/, "", $2); print $2; exit }' || true
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
# hop=1 (группа со сменой портов): если в listen есть диапазон, порт в ссылке — список «443,10000-19999»
n_hy2_add() {
  local name="$1" pass="$2" label="$3" host="$4" hop="${5:-0}"
  local port acme auth_type auth_str existing sni base range
  local obfs="" pin="" obfs_type obfs_pass cert fp
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  [[ -f "$CONFIG" ]] || n_err "не найден $CONFIG"

  port="$(n_hy2_port)"
  if [[ "$hop" == "1" ]]; then
    IFS='|' read -r _ base range <<<"$(n_hy2_listen)"
    if [[ -n "$range" ]]; then port="$base,$range"; fi
  fi
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
  local tpl="$1" cn="$2" force="$3" cert key port p ver lh lb lr
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
  # Смена портов включается на каждом узле отдельно (iof hy2 hop on), диапазон из шаблона не переносится
  IFS='|' read -r lh lb lr <<<"$(n_hy2_listen)"
  if [[ -n "$lr" ]]; then
    n_hy2_listen_set "$lh:$lb"
    echo "[$(hostname)] диапазон портов $lr из шаблона не перенесён, смену портов включает iof hy2 hop on" >&2
  fi
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

# Диапазоны UDP, перенаправленные на порт $1, по строке a-b. Правила nftables (так их ставит сама
# Hysteria2, если nft есть) и iptables: прямые REDIRECT и DNAT и переходы в цепочку, которая
# перенаправляет на этот порт (HYSTERIA-PR-*, если nft нет). Цепочки ретранслятора IOF-* не в счёт:
# там DNAT одного порта на другой узел
n_hy2_hop_rules() {
  local port="$1"
  {
    if command -v iptables >/dev/null 2>&1; then
      timeout 10 iptables -w 5 -t nat -S 2>/dev/null | grep -v -- '^-[AN] IOF-' | awk -v p="$port" '
        { line[NR] = $0 }
        $1 == "-A" && $2 != "PREROUTING" && $2 != "OUTPUT" && / -j REDIRECT --to-ports / && $NF == p { to[$2] = 1 }
        END {
          for (i = 1; i <= NR; i++) {
            if (line[i] !~ / -p udp /) continue
            n = split(line[i], f, " ")
            t = ""
            for (j = 1; j < n; j++) if (f[j] == "-j") t = f[j + 1]
            if ((t in to) || (t == "REDIRECT" && f[n] == p) || (t == "DNAT" && f[n] ~ ":" p "$"))
              for (j = 1; j < n; j++) if (f[j] == "--dport" || f[j] == "--dports") print f[j + 1]
          }
        }' || true
    fi
    if command -v nft >/dev/null 2>&1; then
      timeout 10 nft list ruleset 2>/dev/null | awk -v p="$port" '
        /udp dport/ && ($0 ~ "redirect to :" p "([^0-9]|$)" || $0 ~ "dnat (ip )?to [0-9.]*:" p "([^0-9]|$)") {
          for (i = 1; i < NF; i++) if ($i == "dport") print $(i + 1)
        }' || true
    fi
  } | tr ':' '-' | grep -xE '[0-9]+-[0-9]+' | sort -u || true
}

# Drop-in службы Hysteria2 и скрипт, который он запускает перед её стартом: убирает правила смены
# портов, оставшиеся после аварийного завершения. Hysteria2 снимает свои правила сама при остановке,
# но после падения на iptables осталась бы цепочка, и следующий запуск не прошёл бы.
# n_hy2_hop_files on [iptables] пишет оба файла (с iptables drop-in ещё и велит Hysteria2 ставить
# правила через iptables, а не nftables), off удаляет. systemctl daemon-reload — за вызывающим
n_hy2_hop_files() {
  if [[ "$1" != "on" ]]; then
    rm -f "$HOP_DROPIN" "$HOP_CLEAN"
    rmdir "$(dirname "$HOP_DROPIN")" 2>/dev/null || true
    return 0
  fi
  mkdir -p "$(dirname "$HOP_DROPIN")"
  cat > "$HOP_CLEAN" <<'EOS'
#!/bin/bash
# iof: убирает правила смены портов Hysteria2, оставшиеся после аварийного завершения службы:
# таблицы nftables hysteria_* и цепочки iptables HYSTERIA-PR-*. Запускается перед стартом
# hysteria-server (drop-in iof-hop.conf), когда своих правил у службы ещё нет
set -u
if command -v nft >/dev/null 2>&1; then
  nft list tables 2>/dev/null | while read -r _ fam name; do
    case "$name" in hysteria_*) nft delete table "$fam" "$name" 2>/dev/null ;; esac
  done
fi
for ipt in iptables ip6tables; do
  command -v "$ipt" >/dev/null 2>&1 || continue
  "$ipt" -w 5 -t nat -S 2>/dev/null | grep -E -- ' -j HYSTERIA-PR-[0-9a-f]+$' | while read -r -a rule; do
    rule[0]=-D
    "$ipt" -w 5 -t nat "${rule[@]}" 2>/dev/null
  done
  for chain in $("$ipt" -w 5 -t nat -S 2>/dev/null | awk '$1 == "-N" && $2 ~ /^HYSTERIA-PR-/ { print $2 }'); do
    "$ipt" -w 5 -t nat -F "$chain" 2>/dev/null
    "$ipt" -w 5 -t nat -X "$chain" 2>/dev/null
  done
done
exit 0
EOS
  chmod 755 "$HOP_CLEAN"
  {
    printf '%s\n' "# iof hy2 hop: перед запуском убрать правила смены портов, оставшиеся после аварийного завершения" \
      "[Service]" "ExecStartPre=+$HOP_CLEAN"
    if [[ "${2:-}" == "iptables" ]]; then
      printf '%s\n' "# Правила через nftables здесь не встали (ядро без нужных модулей), поэтому через iptables" \
        "Environment=HYSTERIA_FIREWALL_BACKEND=iptables"
    fi
  } > "$HOP_DROPIN"
}

# Ждёт, пока служба Hysteria2 слушает основной порт $1 и, если задан диапазон $2, перенаправляет его.
# Код 1, если служба упала или правил нет. Без вывода
n_hy2_hop_ready() {
  local i
  sleep 2
  for (( i = 0; i < 16; i++ )); do
    if ! systemctl is-active --quiet "$SERVICE"; then return 1; fi
    if [[ -n "$(ss -Huln "sport = :$1" 2>/dev/null)" ]] \
       && { [[ -z "$2" ]] || grep -qxF "$2" <<<"$(n_hy2_hop_rules "$1")"; }; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# Последняя ошибка Hysteria2 из журнала одной строкой, без цветов
n_hy2_last_error() {
  journalctl -u "$SERVICE" -n 30 --no-pager -o cat 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g' \
    | grep -E 'FATAL|ERROR' | tail -n 1 | sed -E 's/^.*"error": "//; s/\\n.*$//; s/"\}$//' | cut -c1-300 || true
}

# Смена портов (port hopping): n_hy2_hop <on|off> <диапазон a-b> <занятые порты через запятую> <версия от>.
# on дописывает диапазон в listen (listen: :443,10000-19999): Hysteria2 слушает основной порт, а пакеты
# на порты диапазона перенаправляет на него сама правилами nftables или iptables и снимает их при
# остановке. Основной порт не меняется, поэтому выданные ссылки и ретрансляторы работают как раньше.
# Файрвол узла диапазон открывать не должен: перенаправление случается раньше, чем пакет до него дойдёт.
# Если служба не поднялась или правил нет, конфиг и drop-in возвращаются как были, узел остаётся
# на прежних портах. off оставляет в listen основной порт и снимает drop-in.
# Печатает hop (on или off), port (основной), range, was (что было: диапазон, none или same)
n_hy2_hop() {
  local act="$1" range="$2" busy="$3" min="$4" host base cur lo hi ver p s bak had=0 want ok=0 olddrop backend="auto"
  local bad=()
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  if [[ ! -f "$CONFIG" ]] || ! systemctl cat "$SERVICE" >/dev/null 2>&1; then n_err "Hysteria2 не установлена"; fi
  IFS='|' read -r host base cur <<<"$(n_hy2_listen)"
  [[ "$base" =~ ^[0-9]+$ ]] || n_err "не разобрал listen в $CONFIG"
  if [[ -f "$HOP_DROPIN" ]]; then had=1; fi

  if [[ "$act" == "off" ]]; then
    if [[ -z "$cur" ]]; then
      # Уже один порт: остатки правил и drop-in убираются без перезапуска службы
      if (( had )); then
        "$HOP_CLEAN" || true
        n_hy2_hop_files off
        systemctl daemon-reload
      fi
      printf 'hop=off\nport=%s\nrange=\nwas=same\n' "$base"
      return 0
    fi
    want="$host:$base"
  else
    [[ "$range" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || n_err "диапазон: нужен вид 10000-19999"
    lo=$((10#${BASH_REMATCH[1]}))
    hi=$((10#${BASH_REMATCH[2]}))
    (( lo >= 1024 && lo < hi && hi <= 65535 )) || n_err "диапазон: порты от 1024 до 65535, начало меньше конца"
    (( base < lo || base > hi )) || n_err "основной порт $base попадает в диапазон $range"
    ver="$(n_hy2_version)"
    [[ -n "$ver" ]] || n_err "не узнал версию hysteria"
    if [[ "$(printf '%s\n%s\n' "$min" "$ver" | sort -V | head -n 1)" != "$min" ]]; then
      n_err "Hysteria2 $ver, а смене портов нужна версия от $min: сначала обнови её (iof hy2 upgrade)"
    fi
    if ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
      n_err "нет ни nft, ни iptables: Hysteria2 нечем перенаправить диапазон"
    fi
    if [[ "$cur" == "$range" ]] && systemctl is-active --quiet "$SERVICE" \
       && grep -qxF "$range" <<<"$(n_hy2_hop_rules "$base")"; then
      if (( ! had )); then n_hy2_hop_files on; systemctl daemon-reload; fi
      printf 'hop=on\nport=%s\nrange=%s\nwas=same\n' "$base" "$range"
      return 0
    fi

    # Порты диапазона, которые уже чьи-то: слушатели UDP, порты ретранслятора, опубликованные порты
    # контейнеров, перенаправления nat (кроме своих правил Hysteria2) и то, что передал управляющий сервер
    s="$( {
      ss -Huln 2>/dev/null | awk '{ p = $4; sub(/^.*:/, "", p); print p }'
      if [[ -f /etc/iof/relay.rules ]]; then awk '$1 !~ /^#/ && NF >= 4 { print $2 }' /etc/iof/relay.rules; fi
      if command -v docker >/dev/null 2>&1; then
        timeout 10 docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
          | sed -nE 's/^.*:([0-9]+(-[0-9]+)?)->[0-9-]+\/udp.*$/\1/p' || true
      fi
      if command -v iptables >/dev/null 2>&1; then
        timeout 10 iptables -w 5 -t nat -S 2>/dev/null | grep -v -- '-j HYSTERIA-PR-' | grep -- ' -p udp ' \
          | grep -oE -- '--dports? [0-9:,]+' | cut -d' ' -f2 | tr ',' '\n' || true
      fi
      tr ',' '\n' <<<"$busy"
    } | tr ':' '-' | grep -xE '[0-9]+(-[0-9]+)?' | sort -u || true)"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      if awk -F- -v lo="$lo" -v hi="$hi" '{ b = (NF > 1 ? $2 : $1); exit !($1 <= hi && b >= lo) }' <<<"$p"; then bad+=("$p"); fi
    done <<<"$s"
    if (( ${#bad[@]} > 0 )); then
      n_err "в диапазоне $range уже заняты порты UDP: $(printf '%s\n' "${bad[@]}" | sort -n | head -n 10 | paste -sd, -). Выбери другой диапазон"
    fi
    want="$host:$base,$range"
  fi

  bak="$CONFIG.bak.$(date +%s)"
  cp -p "$CONFIG" "$bak"
  olddrop="$(cat "$HOP_DROPIN" 2>/dev/null || true)"
  if [[ "$act" == "on" ]]; then
    # Hysteria2 выбирает nftables, если есть nft. Если с ними служба не поднялась (бывает на ядрах
    # без нужных модулей), второй заход — через iptables. Если так было и раньше, сразу через iptables
    if grep -q 'HYSTERIA_FIREWALL_BACKEND=iptables' <<<"$olddrop"; then backend="iptables"; fi
    n_hy2_hop_files on "$backend"
    systemctl daemon-reload
    n_hy2_listen_set "$want"
    systemctl restart "$SERVICE" >/dev/null 2>&1 || true
    if n_hy2_hop_ready "$base" "$range"; then ok=1
    elif [[ "$backend" == "auto" ]] && command -v nft >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
      s="$(n_hy2_last_error)"
      echo "[$(hostname)] через nftables не вышло${s:+ ($s)}, пробую через iptables" >&2
      n_hy2_hop_files on iptables
      systemctl daemon-reload
      systemctl restart "$SERVICE" >/dev/null 2>&1 || true
      if n_hy2_hop_ready "$base" "$range"; then ok=1; backend="iptables"; fi
    fi
  else
    # Свои правила Hysteria2 снимает при остановке, остальное добирает скрипт
    n_hy2_listen_set "$want"
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    "$HOP_CLEAN" 2>/dev/null || true
    n_hy2_hop_files off
    systemctl daemon-reload
    systemctl start "$SERVICE" >/dev/null 2>&1 || true
    if n_hy2_hop_ready "$base" ""; then ok=1; fi
  fi

  # Не вышло: конфиг и drop-in как были, служба перезапускается с ними
  if (( ! ok )); then
    s="$(n_hy2_last_error)"
    cat "$bak" > "$CONFIG"
    if [[ -x "$HOP_CLEAN" ]]; then "$HOP_CLEAN" || true; fi
    if (( had )); then
      n_hy2_hop_files on
      printf '%s\n' "$olddrop" > "$HOP_DROPIN"
    else
      n_hy2_hop_files off
    fi
    systemctl daemon-reload
    systemctl restart "$SERVICE" >/dev/null 2>&1 || true
    if [[ "$act" == "on" ]]; then s="служба не поднялась с диапазоном или не поставила правила${s:+: $s}"
    else s="служба не поднялась без диапазона${s:+: $s}"; fi
    n_err "$s. Конфиг возвращён как был (копия: $bak)"
  fi
  if [[ "$act" == "on" ]]; then
    printf 'hop=on\nport=%s\nrange=%s\nwas=%s\nbackend=%s\n' "$base" "$range" "${cur:-none}" "$backend"
  else
    printf 'hop=off\nport=%s\nrange=\nwas=%s\n' "$base" "$cur"
  fi
}

# Обновление Hysteria2 официальным установщиком: n_hy2_upgrade. Конфиг он не трогает, юнит службы
# перезаписывает (drop-in iof-hop.conf остаётся) и сам перезапускает работающую службу. Перед этим
# бинарник и юнит копируются в /var/backups/iof-hy2, хранятся три последние копии. Если служба после
# обновления не работает, а до него работала, бинарник и юнит возвращаются и служба перезапускается.
# Печатает "same <версия>" (уже последняя) или "upgraded <была> <стала>"
n_hy2_upgrade() {
  local bin="/usr/local/bin/hysteria" unit="/etc/systemd/system/hysteria-server.service"
  local dir="/var/backups/iof-hy2" log="/var/log/iof-hy2-upgrade.log" old new ts active=0 s rc=0
  n_defaults
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  [[ -x "$bin" ]] || n_err "нет $bin: Hysteria2 не установлена или поставлена не официальным установщиком"
  command -v curl >/dev/null 2>&1 || n_err "нет curl: apt install curl"
  old="$(n_hy2_version)"
  if systemctl is-active --quiet "$SERVICE"; then active=1; fi
  ts="$(date +%s)"
  mkdir -p "$dir"
  chmod 700 "$dir"
  cp -p "$bin" "$dir/hysteria-${old:-unknown}-$ts"
  if [[ -f "$unit" ]]; then cp -p "$unit" "$dir/hysteria-server.service-$ts"; fi

  bash <(curl -fsSL https://get.hy2.sh/) > "$log" 2>&1 || rc=$?
  new="$(n_hy2_version)"
  if (( rc == 0 )) && [[ -n "$new" && "$new" == "$old" ]]; then
    rm -f "$dir/hysteria-${old:-unknown}-$ts" "$dir/hysteria-server.service-$ts"
    echo "same $new"
    return 0
  fi
  sleep 2
  if (( rc != 0 )) || { (( active )) && ! systemctl is-active --quiet "$SERVICE"; }; then
    s="$(journalctl -u "$SERVICE" -n 5 --no-pager -o cat 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1 || true)"
    install -m 755 "$dir/hysteria-${old:-unknown}-$ts" "$bin"
    if [[ -f "$dir/hysteria-server.service-$ts" ]]; then cp -p "$dir/hysteria-server.service-$ts" "$unit"; fi
    systemctl daemon-reload
    if (( active )); then systemctl restart "$SERVICE" >/dev/null 2>&1 || true; fi
    if (( rc != 0 )); then s="установщик завершился с ошибкой (лог: $log)"
    else s="после обновления до ${new:-?} служба не работает${s:+: $s}"; fi
    n_err "$s. Возвращена версия ${old:-прежняя}"
  fi
  # Три последние копии, остальные удаляются
  # shellcheck disable=SC2012 # имена копий без пробелов
  ls -1t "$dir"/hysteria-[0-9u]* 2>/dev/null | tail -n +4 | xargs -r rm -f
  # shellcheck disable=SC2012
  ls -1t "$dir"/hysteria-server.service-* 2>/dev/null | tail -n +4 | xargs -r rm -f
  echo "upgraded ${old:-?} ${new:-?}"
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
  local installed="no" state="" udp="no" port="" auth="" users=0 ver="" range=""
  local awg_state="none" awg_port="" awg_peers="" awg_online="" aconf
  n_defaults

  if command -v hysteria >/dev/null 2>&1 || [[ -f "$CONFIG" ]]; then installed="yes"; fi
  if [[ -f "$CONFIG" ]]; then
    port="$(n_hy2_port)"
    range="$(n_hy2_listen | cut -d'|' -f3)"
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
    "hy2_range=$range" \
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

# $1 свободных портов из диапазона 20000-60000, по одному в строке. Мимо слушателей, правил
# ретранслятора и диапазона смены портов Hysteria2: пакеты на его порты ушли бы в Hysteria2
n_free_ports() {
  local need="$1" got=() p tries=0 hop=""
  n_defaults
  if [[ -f "$CONFIG" ]]; then hop="$(n_hy2_listen | cut -d'|' -f3 | tr ',' '\n')"; fi
  while (( ${#got[@]} < need && tries < 200 )); do
    tries=$((tries + 1))
    p="$(shuf -i 20000-60000 -n 1)"
    if [[ -n "$(ss -Htuln "sport = :$p" 2>/dev/null)" ]]; then continue; fi
    if [[ -f /etc/iof/relay.rules ]] && awk -v p="$p" '$2 == p { f = 1 } END { exit !f }' /etc/iof/relay.rules; then continue; fi
    if [[ -n "$hop" ]] && awk -F- -v p="$p" 'NF { b = (NF > 1 ? $2 : $1); if (p >= $1 && p <= b) f = 1 } END { exit !f }' <<<"$hop"; then continue; fi
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


# Блок-лист сканеров на узле (iof block). Пакеты с адресов из списка отбрасываются в таблице raw,
# в цепочке IOF-BLOCK с переходом из PREROUTING: раньше NAT, поэтому под список попадают и порты
# контейнеров Docker, и порты ретранслятора, которые через INPUT не идут. Адреса из block.allow
# не блокируются никогда. Список возвращает после перезагрузки служба iof-block, как iof-relay

# n_block_apply <on|update|off> <список: gzip и base64> <защищённые адреса через пробел> <время списка>.
# on и update пишут /etc/iof/block.list (время файла — когда управляющий сервер скачал список) и
# /etc/iof/block.allow: к адресам с управляющего сервера добавляются свои адреса узла, loopback
# и собеседники текущих сессий SSH. Наборы ipset подменяются целиком (ipset swap), старый список
# действует, пока не готов новый. update меняет список только там, где он уже включён.
# off снимает всё: переход, цепочку, наборы, службу и файлы.
# Печатает block (on, same, skip, off), entries, allow
n_block_apply() {
  local act="$1" b64="$2" allow="$3" at="$4" tmp n m
  [[ $EUID -eq 0 ]] || n_err "нужны права root"
  if [[ "$act" == "off" ]]; then
    systemctl disable --now iof-block.service >/dev/null 2>&1 || true
    if [[ -x /usr/local/sbin/iof-block ]]; then /usr/local/sbin/iof-block stop || true; fi
    rm -f /etc/systemd/system/iof-block.service /usr/local/sbin/iof-block /etc/iof/block.list /etc/iof/block.allow
    systemctl daemon-reload
    echo "block=off"
    return 0
  fi
  if [[ "$act" == "update" && ! -f /etc/iof/block.list ]]; then echo "block=skip"; return 0; fi
  command -v iptables >/dev/null 2>&1 || n_err "нет iptables: блок-лист iof ставит правилом iptables с набором ipset, узел только с nftables так не защитить"
  if ! command -v ipset >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y -qq ipset >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq ipset >/dev/null 2>&1 || n_err "не удалось установить ipset: apt install ipset"
    fi
  fi
  [[ "$at" =~ ^[0-9]+$ ]] || at="$(date +%s)"

  mkdir -p /etc/iof
  tmp="$(mktemp)"
  if ! printf '%s' "$b64" | base64 -d 2>/dev/null | gzip -dc > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    n_err "список повреждён при передаче"
  fi
  if [[ ! -s "$tmp" ]] || grep -qvE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$' "$tmp"; then
    rm -f "$tmp"
    n_err "список пуст или в нём есть строки не IPv4"
  fi
  {
    tr ' ,' '\n\n' <<<"$allow"
    echo "127.0.0.0/8"
    ip -4 -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }'
    ss -Htnp state established 2>/dev/null | awk '/"sshd/ { p = $4; sub(/:[0-9]+$/, "", p); gsub(/[][]/, "", p); sub(/^::ffff:/, "", p); print p }'
  } | grep -xE '[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?' | sort -u > "$tmp.allow" || true

  # Тот же список уже применён: только время списка
  if cmp -s "$tmp" /etc/iof/block.list && cmp -s "$tmp.allow" /etc/iof/block.allow \
     && systemctl is-active --quiet iof-block.service && iptables -w 5 -t raw -C PREROUTING -j IOF-BLOCK 2>/dev/null; then
    rm -f "$tmp" "$tmp.allow"
    touch -d "@$at" /etc/iof/block.list
    printf 'block=same\nentries=%s\nallow=%s\n' "$(grep -c . /etc/iof/block.list)" "$(grep -c . /etc/iof/block.allow || true)"
    return 0
  fi
  install -m 600 "$tmp" /etc/iof/block.list
  install -m 600 "$tmp.allow" /etc/iof/block.allow
  rm -f "$tmp" "$tmp.allow"
  touch -d "@$at" /etc/iof/block.list

  cat > /usr/local/sbin/iof-block <<'EOS'
#!/bin/bash
# iof: блок-лист сканеров. Пакеты с адресов из /etc/iof/block.list отбрасываются в таблице raw,
# раньше NAT, ufw и Docker. Адреса из /etc/iof/block.allow не блокируются никогда.
# start и reload загружают списки заново (ipset swap, старый действует до готовности нового), stop снимает всё
set -u
LIST=/etc/iof/block.list
ALLOW=/etc/iof/block.allow
ipt() { iptables -w 5 "$@"; }

# Набор $1 из файла $2: собирается под именем $1-new и подменяет прежний целиком
load() {
  local set="$1" file="$2" max=65536 n
  n="$(grep -c . "$file" 2>/dev/null || true)"
  if (( ${n:-0} + 1024 > max )); then max=$(( n + 1024 )); fi
  ipset destroy "$set-new" 2>/dev/null
  { echo "create $set-new hash:net family inet maxelem $max"
    grep -E '^[0-9]' "$file" | sed "s/^/add $set-new /"
  } | ipset restore -exist || return 1
  if ipset -q list -n "$set" >/dev/null; then
    ipset swap "$set-new" "$set" && ipset destroy "$set-new"
  else
    ipset rename "$set-new" "$set"
  fi
}

stop() {
  local s
  while ipt -t raw -D PREROUTING -j IOF-BLOCK 2>/dev/null; do :; done
  ipt -t raw -F IOF-BLOCK 2>/dev/null
  ipt -t raw -X IOF-BLOCK 2>/dev/null
  for s in iof-block iof-allow iof-block-new iof-allow-new; do ipset destroy "$s" 2>/dev/null; done
  return 0
}

start() {
  [[ -s "$LIST" ]] || { stop; return 0; }
  touch "$ALLOW"
  load iof-allow "$ALLOW" || return 1
  load iof-block "$LIST" || return 1
  ipt -t raw -N IOF-BLOCK 2>/dev/null
  ipt -t raw -C IOF-BLOCK -m set --match-set iof-allow src -j RETURN 2>/dev/null \
    || ipt -t raw -I IOF-BLOCK 1 -m set --match-set iof-allow src -j RETURN || return 1
  ipt -t raw -C IOF-BLOCK -m set --match-set iof-block src -j DROP 2>/dev/null \
    || ipt -t raw -A IOF-BLOCK -m set --match-set iof-block src -j DROP || return 1
  ipt -t raw -C PREROUTING -j IOF-BLOCK 2>/dev/null || ipt -t raw -I PREROUTING 1 -j IOF-BLOCK
}

case "${1:-start}" in
  start|reload) start ;;
  stop)         stop ;;
  *)            echo "usage: iof-block start|reload|stop" >&2; exit 2 ;;
esac
EOS
  chmod 755 /usr/local/sbin/iof-block

  cat > /etc/systemd/system/iof-block.service <<'EOS'
[Unit]
Description=iof block list (drops packets from scanner addresses)
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/iof-block start
ExecReload=/usr/local/sbin/iof-block reload
ExecStop=/usr/local/sbin/iof-block stop

[Install]
WantedBy=multi-user.target
EOS
  systemctl daemon-reload
  systemctl enable iof-block.service >/dev/null 2>&1
  if systemctl is-active --quiet iof-block.service; then
    systemctl reload iof-block.service || n_err "список не применился: journalctl -u iof-block -n 20"
  else
    systemctl restart iof-block.service || n_err "список не применился: journalctl -u iof-block -n 20"
  fi
  iptables -w 5 -t raw -C PREROUTING -j IOF-BLOCK 2>/dev/null || n_err "нет перехода в IOF-BLOCK после применения: journalctl -u iof-block -n 20"
  n="$(ipset list -t iof-block 2>/dev/null | sed -n 's/^Number of entries:[[:space:]]*//p')"
  m="$(ipset list -t iof-allow 2>/dev/null | sed -n 's/^Number of entries:[[:space:]]*//p')"
  printf 'block=on\nentries=%s\nallow=%s\n' "${n:-0}" "${m:-0}"
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
    # У listen только основной порт: диапазон смены портов у каждого узла свой (iof hy2 hop)
    /^listen:/ { gsub(/["\047]/, ""); sub(/[,-][0-9,-]*$/, "") }
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
#  hy2 yes/no, hy2_state, hy2_port, hy2_ver, hy2_range (диапазон портов в listen), hy2_obfs none/salamander,
#  hy2_obfs_pass set/empty, hy2_masq none/proxy/file/string, hy2_masq_url, hy2_masq_code (ответ цели
#  proxy с узла), hy2_masq_dir yes/no, hy2_http и hy2_https (порты listenHTTP и listenHTTPS),
#  hy2_acme yes/no, hy2_cert_cn, hy2_cert_self yes/no, hy2_log (уровень журнала), hy2_hop (диапазоны
#  портов, перенаправленные на порт Hysteria2, через запятую),
#  awg none/stopped/noconf/running, awg_c, awg_if, awg_hash, awg_log_driver, awg_log_max, awg_log_size,
#  web none/loopback/any/unknown, web_addr (на чём слушает iof-web),
#  block_set yes/no, block_entries, block_ipt yes/no, block_chain yes/no, block_hook yes/no, block_svc,
#  block_at (блок-лист сканеров: ipset iof-block, цепочка IOF-BLOCK в raw, служба iof-block,
#  время /etc/iof/block.list),
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
    echo "hy2_ver=$(n_hy2_version)"
    # Hysteria2 слушает основной порт, остальные порты из listen перенаправляет на него сама
    echo "hy2_range=$(n_hy2_listen | cut -d'|' -f3)"
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

    # Диапазоны UDP, которые сейчас перенаправлены на порт Hysteria2: её собственные правила
    # (диапазон в listen) или поставленные вручную
    echo "hy2_hop=$(n_hy2_hop_rules "$port" | paste -sd, || true)"

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

  # Блок-лист сканеров (iof block): набор iof-block, цепочка IOF-BLOCK в таблице raw с переходом
  # из PREROUTING, служба iof-block, время списка — когда его скачал управляющий сервер
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
    echo "block_ipt=yes"
    s="$(timeout 10 iptables -w 5 -t raw -S IOF-BLOCK 2>/dev/null || true)"
    v="$(timeout 10 iptables -w 5 -t raw -S PREROUTING 2>/dev/null || true)"
  else
    echo "block_ipt=no"
  fi
  if grep -q -- '--match-set iof-block src -j DROP' <<<"$s"; then echo "block_chain=yes"; else echo "block_chain=no"; fi
  if grep -q -- '-j IOF-BLOCK' <<<"$v"; then echo "block_hook=yes"; else echo "block_hook=no"; fi
  echo "block_svc=$(systemctl is-enabled iof-block.service 2>/dev/null || true)"
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


# Доступ к российским серверам с узла (iof check раз в сутки): n_ru_reach "<цели в РФ>" "<зарубежные>".
# Все цели проверяются сразу, каждая — n_ru_target. Печатает их строки в порядке целей
n_ru_reach() {
  local dir t kind list k=0
  dir="$(mktemp -d)"
  for kind in ru ctl; do
    list="$1"
    if [[ "$kind" == "ctl" ]]; then list="$2"; fi
    for t in $list; do
      k=$((k + 1))
      n_ru_target "$kind" "$t" > "$dir/$(printf '%03d' "$k")" &
    done
  done
  wait
  cat "$dir"/* 2>/dev/null || true
  rm -rf "$dir"
}

# Одна цель: имя или IPv4. TCP-соединение на 443 и, если оно не вышло, ping: многие сайты на ping не
# отвечают, а в некоторых сетях (облака) молчит ICMP. Строка «вид<TAB>цель<TAB>адрес<TAB>tcp<TAB>ping»
n_ru_target() {
  local kind="$1" t="$2" ip="" tcp=0 ping=0 re='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
  if [[ "$t" =~ $re ]]; then
    ip="$t"
  elif [[ "$t" =~ ^[A-Za-z0-9.-]+$ ]]; then
    ip="$(timeout 5 getent ahostsv4 "$t" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
  fi
  if [[ "$ip" =~ $re ]]; then
    if timeout 4 bash -c "exec 3<>/dev/tcp/$ip/443" 2>/dev/null; then
      tcp=1
    elif command -v ping >/dev/null 2>&1 && ping -n -q -c 2 -w 3 "$ip" >/dev/null 2>&1; then
      ping=1
    fi
  else
    ip="-"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$t" "$ip" "$tcp" "$ping"
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
  n_hy2_port n_hy2_listen n_hy2_listen_set n_hy2_version
  n_hy2_userpass n_hy2_user_add n_hy2_user_del n_hy2_restart n_hy2_service_restart
  n_hy2_add n_hy2_del n_hy2_install n_hy2_hop_rules n_hy2_hop_files n_hy2_hop_ready n_hy2_last_error
  n_hy2_hop n_hy2_upgrade
  n_awg_find n_awg_running n_awg_iface n_awg_table_pubs n_awg_table_add n_awg_table_del n_awg_pubkey
  n_awg_clients n_awg_backup n_awg_add n_awg_del
  n_status
  n_free_ports n_relay_apply n_relay_status n_block_apply
  n_audit_listen n_audit_expect n_audit_server n_audit_hy2_blocks n_audit_awg_params n_audit_dpi
  n_probe_start n_probe_stop n_ru_reach n_ru_target
  n_migrate_check n_migrate_receive n_migrate_uninstall n_migrate_demote n_migrate_abort
)
