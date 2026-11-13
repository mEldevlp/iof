#!/usr/bin/env bash

# Проверка iof на поднятом стенде, её же запускает CI на каждый push. Управляющий сервер видит
# узлы и выполняет на них команды, ссылки Hysteria2 из iof работают с другого сервера, ретранслятор
# пересылает трафик, смена портов Hysteria2 включается и выключается (клиент ходит по ссылке со списком
# портов), аудит безопасности видит изменения на узле (в том числе расхождение конфига Hysteria2
# с шаблоном в блоке dpi), блок-лист отбрасывает пакеты с адресов из списка и не трогает защищённые,
# действия запрещены во время переноса, Telegram-бот панели через поддельный Bot API принимает коды
# приглашений, молчит чужим, показывает состояние, выполняет действия после подтверждения и выдаёт
# ссылки Hysteria2 с QR, мишени проверки с ПК отвечают только с токеном, готовый отчёт
# даёт ожидаемые оценки, мишени исчезают по сроку; панель отвечает, отбивает чужие
# запросы, выполняет задачи, выдаёт скрипт для ПК по билету и открывает терминал на каждый узел
# (stand.sh setup включает его в web.env). Созданные группы ссылок и ретранслятор удаляются,
# изменения на узле для аудита, смены портов, блок-листа и проверки с ПК откатываются, стенд остаётся как был.
#   bash stand/stand.sh test [сервер]   сервер — управляющий, по умолчанию old (после переноса: new)
# Имена узлов в nodes.conf совпадают с именами контейнеров, как после stand.sh setup. Узлов нужно
# хотя бы два, а стенду — интернет: трафик через туннель идёт на PROBE_URL.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
M="${1:-old}"
PROBE_URL="${PROBE_URL:-http://connectivitycheck.gstatic.com/generate_204}"
# Группы ссылок, которые проверка создаёт и удаляет: из консоли и из панели
GROUP="CI проверка"
PANEL_GROUP="CI панель"
HOP_GROUP="CI смена портов"
BOT_GROUP="CI бот"
export MSYS_NO_PATHCONV=1

PASSED=0
FAILED=0
GROUP_LEFT=0
RELAY_LEFT=""
AUDIT_LEFT=""
PROBE_LEFT=0        # 1 — могли остаться мишени проверки с ПК
PROBE_FW_LEFT=""    # узел, где для проверки с ПК запрещены входящие
PROBE_PY=()         # узлы с python3: на них поднимаются мишени
HOP_LEFT=0          # 1 — могла остаться смена портов на узлах и группа со списком портов
BLOCK_LEFT=""       # «узел|сервер с тестовыми адресами»: там мог остаться блок-лист
GUARD_LEFT=0        # 1 — на управляющем сервере остался поддельный migrate.conf
BOT_LEFT=0          # 1 — bot.json и bot.token заменены проверкой бота, прежние лежат в /root/.iof-test-bot
NAMES=()
declare -A ADDR=()

dc() { (cd "$DIR" && docker compose "$@"); }
# Команда на сервере без stdin: иначе docker compose exec съест ввод, предназначенный не ему
on() { local s="$1"; shift; dc exec -T "$s" "$@" </dev/null; }
# То же, но stdin передаётся на сервер
on_in() { local s="$1"; shift; dc exec -T "$s" "$@"; }
iofm() { on "$M" iof "$@"; }

# Пароли из ссылок hy2:// в вывод не попадают
mask() { sed -E 's#(hy2://)[^@[:space:]]*@#\1***@#g'; }
step() { echo; echo "== $*"; }
ok()   { PASSED=$((PASSED + 1)); echo "ok    $*"; summary ok "$*"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL  $*"; summary "**ошибка**" "$*"; }
# Подробности к FAIL: последние строки вывода команды с отступом
details() { tail -n "${2:-15}" <<<"$1" | mask | sed 's/^/      /'; }
# Таблица итогов на странице запуска в GitHub Actions
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '| %s | %s |\n' "$1" "${2//|/\\|}" >> "$GITHUB_STEP_SUMMARY"; fi
}

# Если проверка оборвалась посередине, убирает созданное ею
cleanup() {
  if (( GUARD_LEFT )); then
    echo "Убираю поддельный migrate.conf"
    on "$M" rm -f /root/iof/migrate.conf || true
  fi
  if (( BOT_LEFT )); then
    echo "Возвращаю настройки бота как были"
    bot_restore
  fi
  if (( HOP_LEFT )); then
    echo "Выключаю смену портов и убираю группу «$HOP_GROUP»"
    iofm hy2 hop off all >/dev/null 2>&1 || true
    iofm hy2 del "$HOP_GROUP" >/dev/null 2>&1 || true
  fi
  if [[ -n "$BLOCK_LEFT" ]]; then
    echo "Снимаю блок-лист с ${BLOCK_LEFT%%|*}"
    block_restore "${BLOCK_LEFT%%|*}" "${BLOCK_LEFT#*|}"
  fi
  if [[ -n "$AUDIT_LEFT" ]]; then
    echo "Возвращаю $AUDIT_LEFT как был"
    audit_restore "$AUDIT_LEFT"
  fi
  if (( PROBE_LEFT )); then
    echo "Останавливаю мишени проверки с ПК"
    iofm audit probe stop >/dev/null 2>&1 || true
    on "$M" bash -c 'rm -f /root/iof-test-probe-*.json' || true
  fi
  if [[ -n "$PROBE_FW_LEFT" ]]; then
    echo "Возвращаю файрвол $PROBE_FW_LEFT как был"
    probe_fw "$PROBE_FW_LEFT" off
  fi
  if [[ -n "$RELAY_LEFT" ]]; then
    echo "Убираю ретранслятор $RELAY_LEFT"
    # shellcheck disable=SC2086 # два слова: узел и через какой
    iofm relay del $RELAY_LEFT >/dev/null 2>&1 || true
  fi
  if (( GROUP_LEFT )); then
    echo "Убираю группу «$GROUP»"
    iofm hy2 del "$GROUP" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Ссылки группы с подписью $1, по строке
group_links() {
  local login
  login="$(on "$M" awk -F'\t' -v l="$1" '$2 == l {print $1}' /root/iof/hy2/index.tsv)"
  [[ -n "$login" ]] && on "$M" grep '^hy2://' "/root/iof/hy2/$login.txt"
}

# Хост из ссылки hy2://пароль@хост:порт/?...
link_host() { local h="${1#*@}"; h="${h%%[/?#]*}"; echo "${h%:*}"; }
link_hostport() { local h="${1#*@}"; echo "${h%%[/?#]*}"; }

# Сервер стенда с другим адресом, чем $1: с него проверяется ссылка, чтобы трафик шёл между серверами
other_server() {
  local n
  for n in "${NAMES[@]}"; do
    if [[ "${ADDR[$n]}" != "$1" ]]; then echo "$n"; return 0; fi
  done
  return 1
}

# Клиент Hysteria2 на сервере $1 подключается по ссылке $2 и открывает PROBE_URL через туннель.
# Ссылка идёт через stdin, пароль не попадает в аргументы. Код 0, если ответ 2xx
tunnel() {
  printf '%s\n' "$2" | on_in "$1" bash -c '
    command -v hysteria >/dev/null || { echo "на сервере нет hysteria"; exit 1; }
    link="$(cat)"
    # Формат конфига hysteria понимает по расширению
    cfg="$(mktemp --suffix=.yaml)"
    log="$(mktemp)"
    printf "server: \"%s\"\nsocks5:\n  listen: 127.0.0.1:10801\n" "$link" > "$cfg"
    timeout 60 hysteria client -c "$cfg" > "$log" 2>&1 &
    code=000
    for _ in $(seq 1 20); do
      code="$(curl -s -o /dev/null -w "%{http_code}" -m 5 --socks5-hostname 127.0.0.1:10801 "$1")" || true
      if [[ "$code" == 2* ]]; then break; fi
      sleep 0.5
    done
    kill %1 2>/dev/null
    wait 2>/dev/null
    if [[ "$code" != 2* ]]; then echo "ответ $code, лог клиента:"; tail -n 5 "$log"; fi
    rm -f "$cfg" "$log"
    [[ "$code" == 2* ]]' _ "$PROBE_URL"
}

# То же со сменой портов: клиент меняет порт каждые 5 с и 14 секунд подряд открывает PROBE_URL.
# Код 0, если удачных запросов хотя бы 12, печатает их число
tunnel_hop() {
  printf '%s\n' "$2" | on_in "$1" bash -c '
    command -v hysteria >/dev/null || { echo "на сервере нет hysteria"; exit 1; }
    link="$(cat)"
    cfg="$(mktemp --suffix=.yaml)"
    log="$(mktemp)"
    printf "server: \"%s\"\ntransport:\n  udp:\n    hopInterval: 5s\nsocks5:\n  listen: 127.0.0.1:10804\n" "$link" > "$cfg"
    timeout 90 hysteria client -c "$cfg" > "$log" 2>&1 &
    good=0
    for _ in $(seq 1 14); do
      code="$(curl -s -o /dev/null -w "%{http_code}" -m 5 --socks5-hostname 127.0.0.1:10804 "$1")" || true
      if [[ "$code" == 2* ]]; then good=$((good + 1)); fi
      sleep 1
    done
    kill %1 2>/dev/null
    wait 2>/dev/null
    echo "удачных запросов: $good из 14"
    if (( good < 12 )); then tail -n 5 "$log"; fi
    rm -f "$cfg" "$log"
    (( good >= 12 ))' _ "$PROBE_URL"
}

# Сколько новых потоков ушло в перенаправление Hysteria2 на узле $1 (счётчик перехода в HYSTERIA-PR-*).
# Пусто, если правила стоят в nftables: там счётчиков нет
hop_flows() {
  on "$1" bash -c 'iptables -w -t nat -L PREROUTING -v -n -x 2>/dev/null | awk "/HYSTERIA-PR-/ { s += \$1; f = 1 } END { if (f) print s }"'
}

# Доходит ли TCP с сервера $1 до порта 22 сервера $2, $3 — ключи curl (например, --interface адрес)
reach() {
  on "$1" bash -c "curl -sv -m 3 $3 telnet://$2:22 </dev/null 2>&1 | grep -q 'Connected to'"
}

# То же с адреса $3, который висит на сервере $1 только на время захода. Иначе, если $1 — управляющий
# сервер (в CI другого нет), iof block взял бы и этот адрес в «не блокировать» вместе с hostname -I
reach_from() {
  local rc=0
  on "$1" ip addr add "$3/32" dev eth0 >/dev/null 2>&1 || true
  reach "$1" "$2" "--interface $3" || rc=1
  on "$1" ip addr del "$3/32" dev eth0 >/dev/null 2>&1 || true
  return "$rc"
}

# Задача панели: POST /api/security с телом $1 (JSON) на управляющем сервере, ждёт её конца.
# Печатает «состояние заголовок» и хвост лога, при отказе — «refused код текст»
panel_act() {
  on_in "$M" python3 - "$1" <<'PY'
import json, sys, time, urllib.error, urllib.request

BASE = "http://127.0.0.1:8088"
POST = {"X-IOF-Request": "1", "Content-Type": "application/json", "Origin": BASE}
r = urllib.request.Request(BASE + "/api/security", data=sys.argv[1].encode(), method="POST", headers=POST)
try:
    with urllib.request.urlopen(r, timeout=30) as resp:
        code, data = resp.status, json.loads(resp.read())
except urllib.error.HTTPError as e:
    code, data = e.code, json.loads(e.read() or b"{}")
if code != 202:
    print(f"refused {code} {data.get('error', '')}")
    sys.exit(0)
for _ in range(600):
    with urllib.request.urlopen(BASE + "/api/jobs", timeout=30) as resp:
        job = next((j for j in json.loads(resp.read())["jobs"] if j["id"] == data["job"]), None)
    if job and job["state"] != "running":
        print(job["state"], job["title"])
        print("\n".join(job["log"][-15:]))
        sys.exit(0)
    time.sleep(1)
print("timeout")
PY
}

# Все узлы на связи, без проблем, Hysteria2 работает. Заполняет NAMES и ADDR
check_nodes() {
  local out line name="" n
  local -A reach=() hy2=() issues=()
  if ! out="$(iofm api status 2>&1)"; then
    fail "iof api status на $M"
    details "$out"
    return 1
  fi
  NAMES=()
  while IFS= read -r line; do
    case "$line" in
      "== "*)      name="${line#== }"; NAMES+=("$name") ;;
      addr=*)      ADDR[$name]="${line#addr=}" ;;
      reachable=*) reach[$name]="${line#reachable=}" ;;
      hy2_state=*) hy2[$name]="${line#hy2_state=}" ;;
      issues=*)    issues[$name]="${line#issues=}" ;;
    esac
  done <<<"$out"
  if (( ${#NAMES[@]} >= 2 )); then
    ok "узлов в nodes.conf: ${#NAMES[@]}"
  else
    fail "узлов в nodes.conf: ${#NAMES[@]}, нужно хотя бы два (управляющий сервер и узел)"
  fi
  for n in "${NAMES[@]}"; do
    if [[ "${reach[$n]:-}" != "yes" ]]; then
      fail "$n (${ADDR[$n]:-?}): ${issues[$n]:-нет связи}"
    elif [[ -n "${issues[$n]:-}" ]]; then
      fail "$n (${ADDR[$n]}): ${issues[$n]}"
    elif [[ "${hy2[$n]:-}" != "active" ]]; then
      fail "$n (${ADDR[$n]}): Hysteria2 не работает (${hy2[$n]:-не установлена})"
    else
      ok "$n (${ADDR[$n]}): на связи, Hysteria2 работает"
    fi
  done
}

# iof exec выполняет команду на каждом узле, а не где-то ещё: hostname совпадает с именем узла
check_exec() {
  local out n got
  if ! out="$(iofm exec hostname 2>&1)"; then
    fail "iof exec hostname"
    details "$out"
    return 1
  fi
  for n in "${NAMES[@]}"; do
    got="$(awk -v n="$n" 'f {print; exit} $0 == "== " n {f = 1}' <<<"$out")"
    if [[ "$got" == "$n" ]]; then ok "iof exec на $n: hostname $got"; else fail "iof exec на $n: hostname «$got»"; fi
  done
}

check_check() {
  local out last
  if out="$(iofm check 2>&1)"; then ok "iof check: проблем нет"; else fail "iof check"; details "$out"; fi
  last="$(on "$M" cat /root/iof/check.last 2>&1)"
  if grep -qx 'bad=0' <<<"$last" && grep -qx "total=${#NAMES[@]}" <<<"$last"; then
    ok "check.last: total=${#NAMES[@]} bad=0"
  else
    fail "check.last"
    details "$last"
  fi
}

# Группа ссылок, по ссылке на узел; каждая проверяется туннелем с другого сервера.
# Ссылка с неверным паролем работать не должна: так видно, что проверка что-то проверяет
check_hy2() {
  local out relays links=() link l host n client bad
  relays="$(on "$M" sh -c 'grep -v "^[[:space:]]*#" /root/iof/relays.conf 2>/dev/null | grep -c . || true')"
  GROUP_LEFT=1
  if out="$(iofm hy2 add "$GROUP" 2>&1)"; then ok "iof hy2 add «$GROUP»"; else fail "iof hy2 add «$GROUP»"; details "$out"; return 1; fi
  mapfile -t links < <(group_links "$GROUP")
  if (( ${#links[@]} == ${#NAMES[@]} + relays )); then
    ok "в группе ссылок: ${#links[@]}"
  else
    fail "в группе ссылок: ${#links[@]}, ожидалось $(( ${#NAMES[@]} + relays ))"
  fi
  for n in "${NAMES[@]}"; do
    link=""
    for l in "${links[@]}"; do
      if [[ "$(link_host "$l")" == "${ADDR[$n]}" ]]; then link="$l"; break; fi
    done
    if [[ -z "$link" ]]; then fail "нет ссылки на $n (${ADDR[$n]})"; continue; fi
    client="$(other_server "${ADDR[$n]}")" || { fail "не с какого сервера проверить ссылку на $n"; continue; }
    if out="$(tunnel "$client" "$link" 2>&1)"; then
      ok "туннель $client -> $n ($(link_hostport "$link")): $PROBE_URL открывается"
    else
      fail "туннель $client -> $n ($(link_hostport "$link"))"
      details "$out"
    fi
  done
  if (( ${#links[@]} > 0 )); then
    host="$(link_host "${links[0]}")"
    client="$(other_server "$host")"
    bad="$(sed -E 's#^(hy2://)[^@]*@#\1wrong-password@#' <<<"${links[0]}")"
    if out="$(tunnel "$client" "$bad" 2>&1)"; then
      fail "ссылка на $host с неверным паролем работает"
    elif grep -q 'authentication error' <<<"$out"; then
      ok "ссылка на $host с неверным паролем: сервер не пустил (authentication error)"
    else
      fail "ссылка на $host с неверным паролем не работает, но не из-за пароля"
      details "$out"
    fi
  fi
}

# Ретранслятор: узел через управляющий сервер (если тот не узел, как после переноса, — через первый
# узел). В группе появляется ссылка с адресом ретранслятора, и по ней трафик доходит до узла
check_relay() {
  local via="$M" node="" n out before=() after=() link="" l
  if [[ -z "${ADDR[$M]:-}" ]]; then via="${NAMES[0]}"; fi
  for n in "${NAMES[@]}"; do
    if [[ "$n" != "$via" ]]; then node="$n"; break; fi
  done
  if [[ -z "$node" ]]; then
    fail "ретранслятор: нужно хотя бы два узла"
    return 1
  fi
  mapfile -t before < <(group_links "$GROUP")
  RELAY_LEFT="$node $via"
  if out="$(iofm relay add "$node" "$via" 2>&1)"; then
    ok "iof relay add $node $via"
  else
    fail "iof relay add $node $via"
    details "$out"
    return 1
  fi
  if out="$(iofm relay list 2>&1)" && grep -q 'служба active' <<<"$out"; then
    ok "iof relay list: служба ретранслятора на $via работает"
  else
    fail "iof relay list"
    details "$out"
  fi
  mapfile -t after < <(group_links "$GROUP")
  for l in "${after[@]}"; do
    if [[ " ${before[*]} " != *" $l "* ]]; then link="$l"; fi
  done
  # Клиент на самом узле: пакеты идут на ретранслятор и возвращаются оттуда на узел
  if [[ -z "$link" || ${#after[@]} -ne $(( ${#before[@]} + 1 )) ]]; then
    fail "после relay add в группе ссылок: ${#after[@]}, было ${#before[@]}"
  elif [[ "$(link_host "$link")" != "${ADDR[$via]}" ]]; then
    fail "ссылка через ретранслятор ведёт на $(link_hostport "$link"), а не на $via"
  elif out="$(tunnel "$node" "$link" 2>&1)"; then
    ok "туннель $node -> $via ($(link_hostport "$link")) -> $node: $PROBE_URL открывается"
  else
    fail "туннель через ретранслятор $via ($(link_hostport "$link")) до $node"
    details "$out"
  fi
  if out="$(iofm relay del "$node" "$via" 2>&1)"; then
    RELAY_LEFT=""
    ok "iof relay del $node $via"
  else
    fail "iof relay del $node $via"
    details "$out"
  fi
  mapfile -t after < <(group_links "$GROUP")
  if (( ${#after[@]} == ${#before[@]} )); then
    ok "после relay del ссылка через ретранслятор убрана"
  else
    fail "после relay del в группе ссылок: ${#after[@]}, ожидалось ${#before[@]}"
  fi
}

check_hy2_del() {
  local out
  if out="$(iofm hy2 del "$GROUP" 2>&1)"; then
    GROUP_LEFT=0
    ok "iof hy2 del «$GROUP»"
  else
    fail "iof hy2 del «$GROUP»"
    details "$out"
  fi
  if on "$M" cut -f2 /root/iof/hy2/index.tsv | grep -qxF "$GROUP"; then
    fail "группа «$GROUP» осталась в index.tsv"
  fi
}

check_restart() {
  local out
  if out="$(iofm hy2 restart all 2>&1)"; then ok "iof hy2 restart all"; else fail "iof hy2 restart all"; details "$out"; fi
}

# Ссылка группы $1 на сервер с адресом $2
group_link_to() {
  local l
  while IFS= read -r l; do
    if [[ "$(link_host "$l")" == "$2" ]]; then echo "$l"; return 0; fi
  done < <(group_links "$1")
  return 1
}

# Смена портов Hysteria2: iof hy2 hop on на всех узлах; по ссылке группы с --hop клиент с другого сервера
# меняет порт каждые 5 с (где правила в iptables, видно по счётчику, что потоков было несколько), прямой заход
# на порт из диапазона, оценка аудита, refresh не теряет диапазон; затем hop off — снова один порт, ссылки
# рабочие, на узлах нет правил и drop-in. Включение и выключение из панели задачей. На первом узле, который
# не управляющий сервер, входящие запрещены политикой DROP, открыты только 22/tcp и 443/udp
check_hop() {
  local out n link one client got range lo before after fwnode="" count
  for n in "${NAMES[@]}"; do
    if [[ "$n" != "$M" && -z "$fwnode" ]]; then fwnode="$n"; fi
  done
  HOP_LEFT=1
  if [[ -n "$fwnode" ]]; then
    PROBE_FW_LEFT="$fwnode"
    probe_fw "$fwnode" on
  fi
  if out="$(iofm hy2 hop on all 2>&1)" && (( $(grep -c '^Включено ' <<<"$out" || true) == ${#NAMES[@]} )); then
    ok "iof hy2 hop on all: включено на узлах: ${#NAMES[@]}"
  else
    fail "iof hy2 hop on all"
    details "$out"
    return 1
  fi
  if grep -q 'через iptables' <<<"$out"; then
    echo "      $(grep 'через iptables' <<<"$out" | head -n 3 | sed 's/^Включено *//' | paste -sd';' -)"
  fi
  range="$(grep -m1 -oE 'порты [0-9]+-[0-9]+' <<<"$out" | cut -d' ' -f2)"
  lo="${range%-*}"
  out="$(iofm hy2 hop on all 2>&1)" || true
  if grep -q "^Уже было так (${#NAMES[@]})" <<<"$out"; then ok "повтор hop on: ничего не меняет"; else fail "повтор hop on"; details "$out"; fi
  if out="$(iofm hy2 add "$HOP_GROUP" --hop 2>&1)"; then ok "iof hy2 add «$HOP_GROUP» --hop"; else fail "iof hy2 add «$HOP_GROUP» --hop"; details "$out"; return 1; fi

  for n in "${NAMES[@]}"; do
    link="$(group_link_to "$HOP_GROUP" "${ADDR[$n]}")" || { fail "в группе «$HOP_GROUP» нет ссылки на $n"; continue; }
    if [[ "$(link_hostport "$link")" != *",$range" ]]; then fail "ссылка на $n без диапазона: $(link_hostport "$link")"; continue; fi
    client="$(other_server "${ADDR[$n]}")" || { fail "не с какого сервера проверить $n"; continue; }
    before="$(hop_flows "$n")"
    if out="$(tunnel_hop "$client" "$link" 2>&1)"; then
      ok "туннель со сменой портов $client -> $n ($(link_hostport "$link")): $(head -n 1 <<<"$out")"
    else
      fail "туннель со сменой портов $client -> $n ($(link_hostport "$link"))"
      details "$out"
    fi
    after="$(hop_flows "$n")"
    if [[ -n "$before" && -n "$after" ]]; then
      if (( after - before >= 2 )); then ok "$n: клиент менял порт, новых потоков на диапазон: $((after - before))"
      else fail "$n: новых потоков на диапазон $((after - before)), ожидалось хотя бы 2"; fi
    fi
    one="$(sed -E "s#@([^/?@]*):[0-9,-]+/#@\\1:$((lo + 123))/#" <<<"$link")"
    if out="$(tunnel "$client" "$one" 2>&1)"; then ok "туннель $client -> $n на порт $((lo + 123)) из диапазона"
    else fail "туннель $client -> $n на порт $((lo + 123)) из диапазона"; details "$out"; fi
  done

  iofm audit run dpi >/dev/null 2>&1 || true
  for n in "${NAMES[@]}"; do
    got="$(audit_get "$n" hy2_hop dpi)"
    if [[ "$got" == good*"$range"* ]]; then ok "dpi $n: смена портов — $got"; else fail "dpi $n: смена портов — «$got»"; fi
    got="$(audit_get "$n" hy2_template dpi)"
    if [[ "$got" == good* ]]; then ok "dpi $n: диапазон в listen не считается расхождением с шаблоном"; else fail "dpi $n: конфиг и шаблон — «$got»"; fi
  done
  iofm hy2 refresh >/dev/null 2>&1 || true
  count="$(group_links "$HOP_GROUP" | grep -c ":[0-9]*,$range/" || true)"
  if (( count == ${#NAMES[@]} )); then ok "iof hy2 refresh: диапазон в ссылках остался ($count)"; else fail "после refresh ссылок с диапазоном: $count из ${#NAMES[@]}"; fi

  # Выключение: снова один порт
  if out="$(iofm hy2 hop off all 2>&1)" && (( $(grep -c '^Выключено ' <<<"$out" || true) == ${#NAMES[@]} )); then
    ok "iof hy2 hop off all: выключено на узлах: ${#NAMES[@]}"
  else
    fail "iof hy2 hop off all"
    details "$out"
  fi
  count="$(group_links "$HOP_GROUP" | grep -c ':[0-9]*,' || true)"
  if (( count == 0 )); then ok "после hop off в ссылках группы один порт"; else fail "после hop off ссылок со списком портов: $count"; fi
  for n in "${NAMES[@]}"; do
    out="$(on "$n" bash -c 'grep "^listen" /etc/hysteria/config.yaml; ls /etc/systemd/system/hysteria-server.service.d/iof-hop.conf 2>/dev/null
      iptables -w -t nat -S 2>/dev/null | grep -c HYSTERIA-PR || true; nft list tables 2>/dev/null | grep -c hysteria_ || true')"
    if [[ "$(head -n 1 <<<"$out")" == "listen: :443" && "$(tail -n 2 <<<"$out" | paste -sd' ' -)" == "0 0" && "$out" != *iof-hop.conf* ]]; then
      ok "$n: в listen один порт, правил и drop-in нет"
    else
      fail "$n после hop off: $(paste -sd' ' - <<<"$out")"
    fi
    link="$(group_link_to "$HOP_GROUP" "${ADDR[$n]}")" || continue
    client="$(other_server "${ADDR[$n]}")" || continue
    if out="$(tunnel "$client" "$link" 2>&1)"; then ok "туннель $client -> $n ($(link_hostport "$link")) после hop off"
    else fail "туннель $client -> $n после hop off"; details "$out"; fi
  done

  # Из панели: задача включает и выключает на одном узле, после неё узел проверен заново
  n="${fwnode:-${NAMES[0]}}"
  out="$(panel_act "{\"action\": \"hop_on\", \"node\": \"$n\"}")"
  if [[ "$out" == ok* ]] && [[ "$(audit_get "$n" hy2_hop dpi)" == good* ]]; then ok "панель: смена портов на $n включена задачей, проверка — good"
  else fail "панель: включение смены портов на $n"; details "$out"; fi
  out="$(panel_act "{\"action\": \"hop_off\", \"node\": \"$n\"}")"
  if [[ "$out" == ok* ]] && [[ "$(audit_get "$n" hy2_hop dpi)" == warn* ]]; then ok "панель: смена портов на $n выключена задачей"
  else fail "панель: выключение смены портов на $n"; details "$out"; fi
  out="$(panel_act '{"action": "hop_on", "node": "all"}')"
  if [[ "$out" == refused* ]]; then ok "панель: действие на «all» не принято (${out#refused })"; else fail "панель приняла действие на all"; details "$out"; fi

  if [[ -n "$fwnode" ]]; then
    probe_fw "$fwnode" off
    PROBE_FW_LEFT=""
  fi
  if iofm hy2 del "$HOP_GROUP" >/dev/null 2>&1; then HOP_LEFT=0; ok "группа «$HOP_GROUP» удалена"; else fail "не удалилась группа «$HOP_GROUP»"; fi
}

# Возвращает как было после проверки блок-листа на узле $1 с тестовыми адресами на сервере $2
block_restore() {
  iofm block off "$1" >/dev/null 2>&1 || true
  on "$2" bash -c 'ip addr del 1.2.3.4/32 dev eth0; ip addr del 1.2.3.5/32 dev eth0' >/dev/null 2>&1 || true
  on "$1" ip route del 1.2.3.0/24 >/dev/null 2>&1 || true
  on "$M" bash -c 'systemctl stop iof-test-www 2>/dev/null; systemctl reset-failed iof-test-www 2>/dev/null; rm -rf /root/iof-test-www
    if [[ -f /root/iof-test-env.bak ]]; then cat /root/iof-test-env.bak > /root/iof/iof.env; rm -f /root/iof-test-env.bak; fi
    rm -f /root/iof/audit/cache/blocklist.txt*' >/dev/null 2>&1 || true
}

# Блок-лист сканеров на первом узле, который не управляющий сервер. Другой сервер стенда на время каждого
# захода получает внешний адрес: 1.2.3.4 из списка или 1.2.3.5 из BLOCK_ALLOW, узел ходит к ним через этот
# сервер. Список
# (с частными сетями, IPv6, слишком широкими записями и мусором, их iof пропускает) раздаёт управляющий
# сервер python3 -m http.server на 127.0.0.1. Пакеты с 1.2.3.4 узел отбрасывает, с остальных — нет,
# после перезапуска службы список на месте, update без изменений ничего не меняет, снятие убирает всё
check_block() {
  local out node="" src="" n got me
  for n in "${NAMES[@]}"; do
    if [[ "$n" != "$M" && -z "$node" ]]; then node="$n"; fi
  done
  if [[ -z "$node" ]]; then echo "      блок-лист: нет узла, кроме управляющего сервера, пропускаю"; return 0; fi
  src="$(other_server "${ADDR[$node]}")" || { fail "блок-лист: не с какого сервера проверить $node"; return 1; }
  BLOCK_LEFT="$node|$src"
  on_in "$M" bash -s <<'EOF'
mkdir -p /root/iof-test-www
printf '# тестовый список iof\n1.2.3.0/24\n172.30.0.0/24\n10.0.0.0/8\n1.0.0.0/4\n2001:db8::/32\nне адрес\n' > /root/iof-test-www/list.txt
systemctl stop iof-test-www 2>/dev/null; systemctl reset-failed iof-test-www 2>/dev/null
systemd-run --quiet --unit iof-test-www python3 -m http.server 8765 --bind 127.0.0.1 --directory /root/iof-test-www
[[ -f /root/iof-test-env.bak ]] || cp -p /root/iof/iof.env /root/iof-test-env.bak
grep -vE '^(BLOCKLIST_URL|BLOCK_ALLOW)=' /root/iof-test-env.bak > /root/iof/iof.env
printf 'BLOCKLIST_URL="http://127.0.0.1:8765/list.txt"\nBLOCK_ALLOW="1.2.3.5"\n' >> /root/iof/iof.env
rm -f /root/iof/audit/cache/blocklist.txt*
sleep 1
EOF
  on "$node" ip route replace 1.2.3.0/24 via "${ADDR[$src]}"

  if out="$(iofm block on "$node" 2>&1)" && grep -q "^  $node: записей 1," <<<"$out"; then
    ok "iof block on $node: $(grep "^  $node:" <<<"$out" | sed 's/^ *//')"
  else
    fail "iof block on $node"
    details "$out"
    return 1
  fi
  if grep -q 'пропущено: IPv6 1, шире /16 2, частных и служебных 1, нечитаемых 1' <<<"$out"; then
    ok "из списка пропущены IPv6, слишком широкие записи, частные сети и мусор"
  else
    fail "пропущено не то: $(grep 'пропущено' <<<"$out")"
  fi
  me="$(on "$M" hostname -I | awk '{ print $1 }')"
  out="$(on "$node" cat /etc/iof/block.allow)"
  got="ok"
  for n in "${NAMES[@]}"; do grep -qx "${ADDR[$n]}" <<<"$out" || got="нет ${ADDR[$n]}"; done
  grep -qx "$me" <<<"$out" || got="нет $me"
  grep -qx "1.2.3.5" <<<"$out" || got="нет 1.2.3.5"
  if [[ "$got" == ok ]]; then ok "$node: не блокируются узлы из nodes.conf, управляющий сервер ($me) и BLOCK_ALLOW"
  else fail "$node: в block.allow $got"; fi

  if ! reach_from "$src" "${ADDR[$node]}" 1.2.3.4; then ok "$node отбрасывает пакеты с 1.2.3.4 (в списке)"; else fail "$node принимает пакеты с 1.2.3.4"; fi
  if reach_from "$src" "${ADDR[$node]}" 1.2.3.5; then ok "$node принимает 1.2.3.5 (BLOCK_ALLOW)"; else fail "$node отбрасывает 1.2.3.5 из BLOCK_ALLOW"; fi
  if reach "$src" "${ADDR[$node]}" ""; then ok "$node принимает $src с его адреса из nodes.conf"; else fail "$node отбрасывает $src"; fi
  if reach "$M" "${ADDR[$node]}" ""; then ok "$node принимает управляющий сервер $M"; else fail "$node отбрасывает управляющий сервер"; fi

  out="$(on "$node" bash -c 'systemctl restart iof-block && ipset list -t iof-block | sed -n "s/^Number of entries: //p"; iptables -w -t raw -C PREROUTING -j IOF-BLOCK && echo hook')"
  if [[ "$out" == $'1\nhook' ]] && ! reach_from "$src" "${ADDR[$node]}" 1.2.3.4; then
    ok "$node: после перезапуска iof-block список на месте"
  else
    fail "$node после перезапуска iof-block: $(paste -sd' ' - <<<"$out")"
  fi
  out="$(iofm block update 2>&1)" || true
  if grep -q "^Список тот же, не менялся (1): $node" <<<"$out"; then ok "iof block update: тот же список не трогает"; else fail "iof block update"; details "$out"; fi
  iofm -n "$node" audit run dpi >/dev/null 2>&1 || true
  got="$(audit_get "$node" blocklist dpi)"
  if [[ "$got" == good*"применён"* ]]; then ok "dpi $node: блок-лист — $got"; else fail "dpi $node: блок-лист — «$got»"; fi

  out="$(panel_act "{\"action\": \"block_update\", \"node\": \"$node\"}")"
  if [[ "$out" == ok* ]]; then ok "панель: обновление блок-листа на $node задачей"; else fail "панель: обновление блок-листа на $node"; details "$out"; fi
  out="$(panel_act "{\"action\": \"block_off\", \"node\": \"$node\"}")"
  got="$(on "$node" bash -c 'ipset list -n 2>/dev/null | grep -c "^iof-" || true; iptables -w -t raw -S 2>/dev/null | grep -c IOF-BLOCK || true
    ls /etc/iof/block.list /etc/systemd/system/iof-block.service /usr/local/sbin/iof-block 2>/dev/null | wc -l')"
  if [[ "$out" == ok* && "$(paste -sd' ' - <<<"$got")" == "0 0 0" ]]; then
    ok "панель: блок-лист снят с $node целиком (наборов, правил и файлов нет)"
  else
    fail "панель: снятие блок-листа с $node: $(paste -sd' ' - <<<"$got")"
    details "$out"
  fi
  if reach_from "$src" "${ADDR[$node]}" 1.2.3.4; then ok "$node после снятия принимает 1.2.3.4"; else fail "$node после снятия отбрасывает 1.2.3.4"; fi
  got="$(audit_get "$node" blocklist dpi)"
  if [[ "$got" == warn*"не применён"* ]]; then ok "dpi $node после снятия: $got"; else fail "dpi $node после снятия: «$got»"; fi
  block_restore "$node" "$src"
  BLOCK_LEFT=""
}

# Во время переноса управления (migrate.conf с role=source) действия запрещены и в консоли, и в панели,
# а проверка разрешена. migrate.conf подделывается, если переноса нет
check_guard() {
  local out n="${NAMES[0]}"
  if on "$M" test -f /root/iof/migrate.conf; then echo "      идёт настоящий перенос, проверку запрета пропускаю"; return 0; fi
  GUARD_LEFT=1
  on "$M" bash -c 'printf "role=source\nid=iof-test\npeer=root@192.0.2.1\nstarted=%s\n" "$(date +%s)" > /root/iof/migrate.conf'
  if out="$(iofm hy2 hop on "$n" 2>&1)"; then fail "hy2 hop on во время переноса выполнилась"
  elif grep -q 'идёт перенос' <<<"$out"; then ok "во время переноса: iof hy2 hop on запрещена"
  else fail "hy2 hop on во время переноса: не та ошибка"; details "$out"; fi
  if out="$(iofm block on "$n" 2>&1)"; then fail "block on во время переноса выполнилась"
  elif grep -q 'идёт перенос' <<<"$out"; then ok "во время переноса: iof block on запрещена"
  else fail "block on во время переноса: не та ошибка"; details "$out"; fi
  if out="$(iofm hy2 upgrade "$n" 2>&1)"; then fail "hy2 upgrade во время переноса выполнилась"
  elif grep -q 'идёт перенос' <<<"$out"; then ok "во время переноса: iof hy2 upgrade запрещена"
  else fail "hy2 upgrade во время переноса: не та ошибка"; details "$out"; fi
  out="$(panel_act "{\"action\": \"hop_on\", \"node\": \"$n\"}")"
  if [[ "$out" == refused*перенос* ]]; then ok "панель: действие во время переноса не принято (${out#refused })"; else fail "панель приняла действие во время переноса"; details "$out"; fi
  if out="$(iofm -n "$n" audit run dpi 2>&1)"; then ok "во время переноса: iof audit run разрешена"; else fail "audit run во время переноса"; details "$out"; fi
  on "$M" rm -f /root/iof/migrate.conf
  GUARD_LEFT=0
}

# Копии bot.json и bot.token до проверки бота, после неё всё возвращается как было
bot_save() {
  on "$M" bash -c 'rm -rf /root/.iof-test-bot && mkdir -m 700 /root/.iof-test-bot
    for f in bot.json bot.token; do if [[ -f /root/iof/$f ]]; then cp -p /root/iof/$f /root/.iof-test-bot/; fi; done'
  BOT_LEFT=1
}

bot_restore() {
  on "$M" bash -c 'for f in bot.json bot.token; do
      rm -f /root/iof/$f
      if [[ -f /root/.iof-test-bot/$f ]]; then cp -p /root/.iof-test-bot/$f /root/iof/$f; fi
    done
    rm -rf /root/.iof-test-bot
    # Узел с длинным именем из проверки кнопок бота
    sed -i "/^ci-bot-long-/d" /root/iof/nodes.conf
    # qrencode, убранный для проверки ссылок без QR
    for f in /usr/bin/qrencode.iof-test /usr/local/bin/qrencode.iof-test; do
      if [[ -e $f ]]; then mv "$f" "${f%.iof-test}"; fi
    done' || true
  # Группа, которую создаёт бот
  if on "$M" cut -f2 /root/iof/hy2/index.tsv 2>/dev/null | grep -qxF "$BOT_GROUP"; then
    iofm hy2 del "$BOT_GROUP" >/dev/null 2>&1 || true
  fi
  BOT_LEFT=0
}

# Telegram-бот панели через поддельный Bot API (stand/fake-tg.py, его ставит stand.sh setup на old):
# iof bot token (неверный и верный), on без токена, бот опрашивает API и ставит меню команд; чужому
# не отвечает, на неверный код отвечает «не подошёл»; приглашение верное, повторное, просроченное,
# по ссылке /start <код>, из группового чата; старое сообщение пропускается; админу отвечает на /start
# и /help, в группе не отвечает и ему; настройки и админы меняются командой; 409 от второго опроса
# пишется в журнал, и бот продолжает работать; при переносе изменения и коды отказаны, на сервере,
# принимающем управление, бот не опрашивает API; выключение и удаление токена. Страница «Телеграм бот»:
# /api/bot без токена и хэшей, настройки, приглашение и отзыв, админы, токен и выключатель через панель,
# при переносе панель изменения не принимает. Команды просмотра (/status, /node, /audit, /service, /hy2):
# кнопки узлов и «Обновить» (editMessageText того же сообщения), answerCallbackQuery, нажатия чужого и в
# группе без ответа, узел с длинным именем (хэш в callback_data) и кнопка удалённого узла, в ответах нет
# паролей Hysteria2. Действия: отказ при выключенных действиях и обычному админу, кнопки только главному,
# подтверждение и отмена, повторное, чужое, истёкшее нажатие и после перезапуска панели, занятая очередь,
# ход задачи правками одного сообщения, перенос (check разрешён), перезапуск Hysteria2 и проверка узла,
# группа $BOT_GROUP создаётся и удаляется из бота, её ссылки с QR и без qrencode, выдача ссылок выключена;
# паролей Hysteria2 нет в журнале и логах задач. Токен не попадает в журналы, bot.json и iof bot show
check_bot() {
  local out rc
  if on "$M" test -f /root/iof/migrate.conf; then echo "      идёт настоящий перенос, проверку бота пропускаю"; return 0; fi
  if ! on "$M" bash -c 'systemctl is-active --quiet fake-tg && grep -qx "IOF_TG_API=http://127.0.0.1:8089" /root/iof/web.env'; then
    echo "      на $M нет поддельного Bot API (его ставит stand.sh setup на old), проверку бота пропускаю"
    return 0
  fi
  bot_save
  GUARD_LEFT=1
  out="$(on_in "$M" python3 - "$BOT_GROUP" 2>&1 <<'PY'
import glob, hashlib, json, os, re, shutil, subprocess, sys, time, urllib.error, urllib.request
from html import escape

FAKE = "http://127.0.0.1:8089"
PANEL = "http://127.0.0.1:8088"
POST = {"X-IOF-Request": "1", "Content-Type": "application/json", "Origin": PANEL}
# Токены для поддельного API: номер 0 он считает отозванным. Настоящего токена здесь нет
TOKEN = "777000:AAEstandFakeTokenForIofBotTests_x1"
BAD_TOKEN = "0:AAEstandFakeTokenRevokedXXXXXXXXXX"
BOT_JSON, BOT_TOKEN, MIGRATE = "/root/iof/bot.json", "/root/iof/bot.token", "/root/iof/migrate.conf"
T0 = time.time()


def report(good, text):
    print(("ok" if good else "fail") + "\t" + text, flush=True)


def iof(*args, stdin=""):
    p = subprocess.run(["iof", "bot", *args], input=stdin.encode(), capture_output=True, timeout=60)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def fake(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(FAKE + path, data=data, method="POST" if data else "GET",
                               headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=20) as resp:
        return json.loads(resp.read())


def panel(path, body=None, headers=None):
    """Запрос к панели: без тела GET, с телом POST с обычной защитой. -> (код, JSON-ответ)."""
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(PANEL + path, data=data, method="POST" if data else "GET",
                               headers=headers if headers is not None else (POST if data else {}))
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}


def thread_state(want, timeout=20):
    """Поток бота в /api/bot пришёл в состояние want."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if (panel("/api/bot")[1].get("thread") or {}).get("state") == want:
            return True
        time.sleep(0.5)
    return False


def cfg():
    with open(BOT_JSON, encoding="utf-8") as f:
        return json.load(f)


def admin(uid):
    return next((a for a in cfg()["admins"] if a["id"] == uid), None)


def code_of(out):
    m = re.search(r"^([0-9a-f]{64})$", out, re.M)
    return m.group(1) if m else ""


def say(uid, text, wait=True, **kw):
    """Сообщение боту от uid. Ждёт, пока бот подтвердит апдейт (обработал его) -> тексты ответов бота,
    None — не подтвердил за 20 с. wait=False: не ждать, (номер апдейта, номер последнего вызова)."""
    before = fake("/fake/state")["sent"]
    upd = fake("/fake/message", {"from_id": uid, "text": text, **kw})["update_id"]
    if not wait:
        return upd, before
    return replies(upd, before, 20)


def replies(upd, before, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if fake("/fake/state")["offset"] > upd:
            return [s["params"].get("text", "") for s in fake(f"/fake/sent?after={before}") if s["method"] == "sendMessage"]
        time.sleep(0.3)
    return None


def first(r):
    return r[0] if r else ""


def journal():
    p = subprocess.run(["journalctl", "-u", "iof-web", "-u", "fake-tg", "--since", f"@{int(T0) - 1}", "-o", "cat", "--no-pager"],
                       capture_output=True, timeout=30)
    return p.stdout.decode("utf-8", "replace")


def in_journal(text, timeout=5):
    """Строка появилась в журнале: journald пишет его с небольшой задержкой."""
    deadline = time.time() + timeout
    while True:
        if text in journal():
            return True
        if time.time() > deadline:
            return False
        time.sleep(0.5)


def polling(timeout=20):
    """Бот ждёт ответа на getUpdates."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if fake("/fake/state")["waiting"] > 0:
            return True
        time.sleep(0.3)
    return False


def quiet(seconds=5):
    """Бот не опрашивает API: никто не ждёт getUpdates и новых опросов за seconds секунд нет."""
    deadline = time.time() + 15
    while time.time() < deadline and fake("/fake/state")["waiting"] > 0:
        time.sleep(0.5)
    polls = fake("/fake/state")["polls"]
    time.sleep(seconds)
    st = fake("/fake/state")
    return st["waiting"] == 0 and st["polls"] == polls


def check_page():
    """Страница «Телеграм бот»: /api/bot без токена и хэшей приглашений; настройки, приглашение и его
    отзыв, админы, токен и выключатель через POST /api/bot. Бот включён, токен TOKEN, админ 5001."""
    secret = TOKEN.split(":", 1)[1]
    code, data = panel("/api/bot")
    c = data.get("config") or {}
    report(code == 200 and data.get("token") is True and (data.get("thread") or {}).get("state") == "running"
           and c.get("enabled") is True and c.get("username") == "iof_stand_bot" and any(a["id"] == 5001 for a in c.get("admins", [])),
           f"панель: /api/bot ({code}) — токен есть, бот работает, админы на месте")
    report(secret not in json.dumps(data), "панель: токена нет в /api/bot")

    codes = [panel("/api/bot", {"action": "set", "key": "actions", "on": False})[0],
             panel("/api/bot", {"action": "set", "key": "links", "on": True})[0],
             panel("/api/bot", {"action": "set", "key": "quiet", "value": "22:30-07:00"})[0]]
    c = cfg()
    report(codes == [200, 200, 200] and c["actions"] is False and c["hy2_links"] is True and c["quiet"] == {"from": "22:30", "to": "07:00"},
           f"панель: настройки бота — действия, ссылки, тихие часы ({codes})")
    code, _ = panel("/api/bot", {"action": "set", "key": "quiet", "value": "25:00-07:00"})
    report(code == 400 and cfg()["quiet"] == {"from": "22:30", "to": "07:00"}, f"панель: неверные тихие часы не приняты ({code})")
    code, _ = panel("/api/bot", {"action": "set", "key": "quiet", "value": "off"})
    report(code == 200 and cfg()["quiet"] is None, "панель: тихие часы выключены")
    code, _ = panel("/api/bot", {"action": "set", "key": "actions", "on": True}, {"Content-Type": "application/json"})
    report(code == 403 and cfg()["actions"] is False, f"панель: изменение бота без X-IOF-Request отклонено ({code})")

    code, data = panel("/api/bot", {"action": "invite", "role": "main"})
    inv = data.get("invite") or {}
    pcode = inv.get("code", "")
    h = hashlib.sha256(pcode.encode()).hexdigest()
    report(code == 200 and re.fullmatch(r"[0-9a-f]{64}", pcode) is not None and inv.get("role") == "main"
           and inv.get("link") == f"https://t.me/iof_stand_bot?start={pcode}" and any(i["hash"] == h for i in cfg()["invites"]),
           "панель: приглашение создано — код из 64 знаков, ссылка t.me, в bot.json его хэш")
    code, data = panel("/api/bot")
    raw = json.dumps(data)
    report([i["hash"] for i in (data.get("config") or {}).get("invites", [])] == [h[:12]] and pcode not in raw and h not in raw,
           "панель: в /api/bot у приглашения только начало хэша, кода нет")
    code, _ = panel("/api/bot", {"action": "invite_del", "hash": h[:12]})
    r = say(5006, pcode)
    report(code == 200 and not cfg()["invites"] and "не подошёл" in first(r) and admin(5006) is None,
           "панель: приглашение отозвано, код больше не принимается")
    code, data = panel("/api/bot", {"action": "invite", "role": "regular"})
    pcode2 = (data.get("invite") or {}).get("code", "")
    r = say(5006, pcode2)
    report(code == 200 and "обычный" in first(r) and (admin(5006) or {}).get("role") == "regular",
           "панель: по коду из панели бот добавил админа с ролью «обычный»")
    report(pcode not in journal() and pcode2 not in journal(), "панель: кодов приглашений нет в журнале")

    c1 = panel("/api/bot", {"action": "admin_set", "id": 5006, "role": "main"})[0]
    c2 = panel("/api/bot", {"action": "admin_set", "id": 5006, "sound": True})[0]
    a = admin(5006) or {}
    report(c1 == 200 and c2 == 200 and a.get("role") == "main" and a.get("sound") is True, "панель: роль и звук в тихие часы у админа")
    code, _ = panel("/api/bot", {"action": "admin_del", "id": 5006})
    report(code == 200 and admin(5006) is None, "панель: админ удалён")
    code, data = panel("/api/bot", {"action": "admin_del", "id": 9999})
    report(code == 400 and "нет" in data.get("error", ""), f"панель: удаление неизвестного админа отклонено ({code})")

    code, data = panel("/api/bot", {"action": "token", "token": BAD_TOKEN})
    report(code == 400 and "не принял" in data.get("error", "") and open(BOT_TOKEN).read().strip() == TOKEN,
           "панель: отозванный токен не принят, прежний на месте")
    code, data = panel("/api/bot", {"action": "token", "token": TOKEN})
    report(code == 200 and (data.get("bot") or {}).get("token") is True and secret not in json.dumps(data),
           "панель: токен принят (iof bot token со stdin), в ответе его нет")
    code, _ = panel("/api/bot", {"action": "enable", "on": False})
    report(code == 200 and quiet() and cfg()["enabled"] is False and thread_state("off"), "панель: бот выключен и не опрашивает API")
    code, _ = panel("/api/bot", {"action": "enable", "on": True})
    report(code == 200 and polling() and thread_state("running"), "панель: бот включён и снова опрашивает API")


def calls(before):
    return fake(f"/fake/sent?after={before}")


def wait_calls(before, done, timeout=90):
    """Вызовы бота после before, как только done(вызовы) истинно (или по таймауту). Команды просмотра
    бот выполняет в отдельном потоке, поэтому ответ приходит позже подтверждения апдейта."""
    deadline = time.time() + timeout
    while True:
        got = calls(before)
        if done(got) or time.time() > deadline:
            return got
        time.sleep(0.3)


def text_of(c):
    return str(c["params"].get("text", ""))


def buttons(c):
    markup = c["params"].get("reply_markup") or {}
    return [b for row in markup.get("inline_keyboard", []) for b in row]


def msg_id(c):
    """Номер сообщения, которое показывает вызов: у правки — исправленное, у отправки — новое."""
    return int(c["params"]["message_id"]) if c["method"] == "editMessageText" else c["message_id"]


def last_with(got, needle, method=("sendMessage", "editMessageText")):
    return next((c for c in reversed(got) if c["method"] in method and needle in text_of(c)), None)


def ask(uid, text, needle, timeout=90, absent=None):
    """Команда от uid, ждёт ответ (новый или исправленный), где есть needle и нет absent -> (все вызовы, ответ)."""
    before = fake("/fake/state")["sent"]
    fake("/fake/message", {"from_id": uid, "text": text})

    def done(got):
        c = last_with(got, needle)
        return c is not None and not (absent and absent in text_of(c))
    got = wait_calls(before, done, timeout)
    return got, last_with(got, needle)


def press(uid, mid, data, chat_type="private"):
    """Нажатие кнопки data под сообщением бота mid -> (номер апдейта, номер последнего вызова, id нажатия)."""
    before = fake("/fake/state")["sent"]
    user = {"id": uid, "is_bot": False, "first_name": f"User{uid}", "username": f"user{uid}"}
    chat = ({"id": uid, "type": "private", "first_name": user["first_name"]} if chat_type == "private"
            else {"id": -1000000000000 - uid, "type": chat_type, "title": "Stand group"})
    qid = f"{uid}{time.time_ns()}"
    q = {"id": qid, "from": user, "chat_instance": "1", "data": data,
         "message": {"message_id": mid, "chat": chat, "date": int(time.time()), "text": "…",
                     "from": {"id": 777000, "is_bot": True, "first_name": "iof stand", "username": "iof_stand_bot"}}}
    upd = fake("/fake/update", {"callback_query": q})["update_id"]
    return upd, before, qid


def answered(got, qid):
    return next((c for c in got if c["method"] == "answerCallbackQuery" and c["params"].get("callback_query_id") == qid), None)


def node_names():
    names = []
    for line in open("/root/iof/nodes.conf", encoding="utf-8"):
        name = line.split("|")[0].strip()
        if name and not name.startswith("#"):
            names.append(name)
    return names


def hy2_secrets():
    """Пароли из ссылок групп Hysteria2 (часть после «логин:» или весь пароль). Короткие не берутся:
    логин бывает и в подписи группы."""
    out = set()
    for path in glob.glob("/root/iof/hy2/*.txt"):
        for line in open(path, encoding="utf-8"):
            if line.startswith("hy2://") and "@" in line:
                auth = line[6:line.rindex("@")]
                out |= {p for p in (auth, auth.split(":", 1)[-1]) if len(p) >= 8}
    return out


LONG = "ci-bot-long-" + "x" * 60


def check_views():
    """Команды просмотра (этап 3): /status с кнопками узлов и «Обновить», карточка узла и её «Обновить»
    (editMessageText), /node с неизвестным узлом, /audit, /service, /hy2, /help; нажатия чужого и в группе
    без ответа; узел с длинным именем (callback_data с хэшем) и устаревшая кнопка. Админ 5001, роль обычный."""
    start = fake("/fake/state")["sent"]
    names = node_names()
    first_node = names[0]

    # Первый /status: кэш опроса узлов к этому времени устарел (больше IOF_WEB_TTL без опроса), поэтому
    # сначала «опрашиваю узлы…», потом то же сообщение исправлено
    got, st = ask(5001, "/status", "<b>Узлы:")
    keys = [b.get("callback_data", "") for b in buttons(st)] if st else []
    report(st is not None and f"Узлы: {len(names)}" in text_of(st) and "в порядке" in text_of(st)
           and all(f"n:{n}" in keys for n in names) and keys[-1:] == ["st"],
           f"/status: узлов {len(names)}, кнопка на каждый узел и «Обновить»")
    wait = next((c for c in got if c["method"] == "sendMessage" and "Опрашиваю узлы" in text_of(c)), None)
    report(wait is not None and st is not None and st["method"] == "editMessageText" and msg_id(st) == wait["message_id"],
           "/status: пока идёт опрос — «Опрашиваю узлы…», потом то же сообщение исправлено")
    status_mid = msg_id(st) if st else 0

    upd, before, qid = press(5001, status_mid, f"n:{first_node}")
    got = wait_calls(before, lambda g: last_with(g, "Нагрузка") is not None)
    card = last_with(got, "Нагрузка")
    report(answered(got, qid) is not None, "кнопка узла: answerCallbackQuery")
    report(card is not None and card["method"] == "sendMessage" and f"<b>{first_node}</b>" in text_of(card)
           and all(s in text_of(card) for s in ("Адрес для клиентов", "ЦП", "Память", "Диск", "Hysteria2", "AmneziaWG"))
           and [b.get("callback_data") for b in buttons(card)] == [f"nr:{first_node}"],
           f"кнопка узла: карточка {first_node} новым сообщением — адрес, нагрузка, службы, кнопка «Обновить»")
    card_mid = msg_id(card) if card else 0

    # Принудительный опрос не чаще раза в 5 с: после паузы данные новые, и текст карточки другой
    time.sleep(6)
    upd, before, qid = press(5001, card_mid, f"nr:{first_node}")
    got = wait_calls(before, lambda g: any(c["method"] == "editMessageText" for c in g))
    edit = next((c for c in got if c["method"] == "editMessageText"), None)
    report(answered(got, qid) is not None and edit is not None and msg_id(edit) == card_mid
           and "Нагрузка" in text_of(edit) and not any(c["method"] == "sendMessage" for c in got),
           "«Обновить» у карточки узла: то же сообщение исправлено (editMessageText), нового нет")
    upd, before, qid = press(5001, card_mid, f"nr:{first_node}")
    got = wait_calls(before, lambda g: answered(g, qid) is not None, 20)
    time.sleep(3)
    got = calls(before)
    report(answered(got, qid) is not None and not any(c["method"] in ("sendMessage", "editMessageText") for c in got),
           "«Обновить» сразу ещё раз: данные те же, бот не шлёт ни нового, ни ошибки")
    time.sleep(6)
    upd, before, qid = press(5001, status_mid, "st")
    got = wait_calls(before, lambda g: last_with(g, "<b>Узлы:", ("editMessageText",)) is not None)
    edit = last_with(got, "<b>Узлы:", ("editMessageText",))
    report(answered(got, qid) is not None and edit is not None and msg_id(edit) == status_mid and len(buttons(edit)) == len(names) + 1,
           "«Обновить» у /status: то же сообщение исправлено, кнопки на месте")

    got, card = ask(5001, f"/node {first_node}", "Нагрузка")
    report(card is not None and f"<b>{first_node}</b>" in text_of(card), f"/node {first_node}: карточка узла")
    got, c = ask(5001, "/node no-such-node", "нет в nodes.conf")
    report(c is not None and "no-such-node" in text_of(c) and [b.get("callback_data") for b in buttons(c)] == [f"n:{n}" for n in names],
           "/node с неизвестным узлом: «нет в nodes.conf» и кнопки узлов")
    got, c = ask(5001, "/node", "Какой узел")
    report(c is not None and len(buttons(c)) == len(names), "/node без имени: выбор узла кнопками")

    got, c = ask(5001, "/audit", "Защита от РКН")
    report(c is not None and "Аудит сервера" in text_of(c) and "Проверка:" in text_of(c) and "проблем" in text_of(c),
           "/audit: итог по блокам «Аудит сервера» и «Защита от РКН»")
    got, c = ask(5001, "/service", "Ночное обслуживание", 120, absent="Проверяю обновления")
    report(c is not None and all(s in text_of(c) for s in ("Установлена:", "Проверка узлов")) and "Проверяю обновления" not in text_of(c),
           "/service: версия, обновления, проверка узлов, ночное обслуживание")
    labels = [line.split("\t")[1] for line in open("/root/iof/hy2/index.tsv", encoding="utf-8") if "\t" in line]
    got, c = ask(5001, "/hy2", "Группы ссылок")
    report(c is not None and labels and all(escape(lb, quote=False) in text_of(c) for lb in labels) and "ссылк" in text_of(c),
           f"/hy2: группы ({', '.join(labels)}) с числом ссылок")
    got, c = ask(5001, "/help", "<b>Команды</b>")
    report(c is not None and all(f"/{k}" in text_of(c) for k in ("status", "node", "audit", "service", "hy2")),
           "/help: новые команды")

    # Чужой и группа: ни ответа на нажатие, ни сообщений
    upd, before, qid = press(5009, status_mid, "st")
    replies(upd, before, 20)
    time.sleep(2)
    report(not calls(before), "нажатие кнопки чужим: без ответа")
    report(in_journal("нажатие кнопки от чужого, без ответа: id 5009"), "нажатие чужого записано в журнал")
    upd, before, qid = press(5001, status_mid, "st", chat_type="group")
    replies(upd, before, 20)
    time.sleep(2)
    report(not calls(before), "нажатие кнопки в группе: без ответа и админу")
    upd, before, qid = press(5001, status_mid, "zz:old")
    got = wait_calls(before, lambda g: answered(g, qid) is not None, 20)
    report("устарела" in str((answered(got, qid) or {}).get("params", {}).get("text", "")), "незнакомая кнопка: «кнопка устарела»")

    # Узел с длинным именем: «n:<имя>» больше 64 байт, в кнопке хэш имени. Узла нет на самом деле:
    # адрес из TEST-NET, iof до него не достучится
    with open("/root/iof/nodes.conf", "a", encoding="utf-8") as f:
        f.write(f"{LONG} | 192.0.2.10 | root@192.0.2.10 | CI бот длинное имя\n")
    deadline = time.time() + 90
    while time.time() < deadline and not any(n["name"] == LONG for n in panel("/api/dashboard?force=1")[1].get("nodes", [])):
        time.sleep(2)
    got, st = ask(5001, "/status", f"<b>Узлы: {len(names) + 1}")
    data = next((b.get("callback_data", "") for b in buttons(st) if b["text"].endswith("…")), "") if st else ""
    report(st is not None and data.startswith("n#") and len(data.encode()) <= 64
           and all(len(b.get("callback_data", "").encode()) <= 64 for b in buttons(st)),
           f"длинное имя узла: в кнопке хэш ({data}), callback_data не длиннее 64 байт")
    upd, before, qid = press(5001, msg_id(st) if st else 0, data)
    got = wait_calls(before, lambda g: last_with(g, "Нет связи по SSH") is not None)
    card = last_with(got, "Нет связи по SSH")
    nr = [b.get("callback_data", "") for b in buttons(card)] if card else []
    report(card is not None and LONG in text_of(card) and len(nr) == 1 and nr[0].startswith("nr#"),
           "кнопка длинного узла: карточка «нет связи по SSH», «Обновить» тоже с хэшем")
    remove_long()
    upd, before, qid = press(5001, msg_id(card) if card else 0, nr[0] if nr else "nr#0")
    got = wait_calls(before, lambda g: answered(g, qid) is not None, 20)
    time.sleep(2)
    a = answered(calls(before), qid) or {"params": {}}
    report("больше нет" in str(a["params"].get("text", "")) and a["params"].get("show_alert") is True
           and not any(c["method"] in ("sendMessage", "editMessageText") for c in calls(before)),
           "кнопка удалённого узла: «узла больше нет» во всплывающем окне")
    upd, before, qid = press(5001, status_mid, f"n:{LONG[:40]}")
    got = wait_calls(before, lambda g: answered(g, qid) is not None, 20)
    report("больше нет" in str((answered(got, qid) or {"params": {}})["params"].get("text", "")),
           "кнопка узла не из nodes.conf: «узла больше нет»")

    raw = json.dumps(calls(start), ensure_ascii=False)
    secrets = hy2_secrets()
    leaks = [s for s in secrets if s in raw]
    report(secrets and not leaks and TOKEN.split(":", 1)[1] not in raw and "PrivateKey" not in raw,
           f"в ответах бота нет паролей Hysteria2 ({len(secrets)}), ключей AWG и токена")


def remove_long():
    with open("/root/iof/nodes.conf", encoding="utf-8") as f:
        lines = f.readlines()
    with open("/root/iof/nodes.conf.t", "w", encoding="utf-8") as f:
        f.writelines(line for line in lines if not line.startswith(LONG))
    os.replace("/root/iof/nodes.conf.t", "/root/iof/nodes.conf")


FINAL = re.compile(r"^(✅|⚠️|❌) <b>")
INDEX = "/root/iof/hy2/index.tsv"


def ref(kind, name):
    """callback_data кнопки узла или группы, как ref_button в боте."""
    data = f"{kind}:{name}"
    return data if len(data.encode()) <= 64 else f"{kind}#{hashlib.sha256(name.encode()).hexdigest()[:24]}"


def keys(c):
    return [b.get("callback_data", "") for b in buttons(c)] if c else []


def ok_no(c):
    """Кнопки «Подтвердить» и «Отмена» под сообщением c."""
    k = keys(c)
    return (next((x for x in k if x.startswith("ok:")), "ok:" + "0" * 16),
            next((x for x in k if x.startswith("no:")), "no:" + "0" * 16))


def tap(uid, mid, data, done=lambda g: True, timeout=60):
    """Нажатие кнопки data под сообщением mid -> (вызовы бота после него, ответ на нажатие), как только
    ответ на нажатие есть и done(вызовы) истинно."""
    upd, before, qid = press(uid, mid, data)
    got = wait_calls(before, lambda g: answered(g, qid) is not None and done(g), timeout)
    return got, answered(got, qid)


def toast(a):
    return str(((a or {}).get("params") or {}).get("text", ""))


def bot_jobs():
    return [j for j in panel("/api/jobs")[1].get("jobs", []) if j.get("kind") == "bot"]


def job_ids():
    return {j["id"] for j in bot_jobs()}


def final_edit(got, mid):
    """Итог задачи: правка сообщения mid, которая начинается с ✅, ⚠️ или ❌."""
    return next((c for c in reversed(got) if c["method"] == "editMessageText" and msg_id(c) == mid
                 and FINAL.match(text_of(c))), None)


def confirmation(got):
    return last_with(got, "Подтверди действие", ("sendMessage",))


def run_action(uid, c, timeout=300):
    """«Подтвердить» под сообщением c и ход задачи до итога -> (вызовы, ответ на нажатие, итог, задача)."""
    mid, known = msg_id(c) if c else 0, job_ids()
    got, a = tap(uid, mid, ok_no(c)[0], lambda g: final_edit(g, mid) is not None, timeout)
    return got, a, final_edit(got, mid), next((j for j in bot_jobs() if j["id"] not in known), None)


def groups():
    """index.tsv: {подпись: логин}."""
    out = {}
    for line in open(INDEX, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2:
            out[parts[1]] = parts[0]
    return out


def links_of(login):
    try:
        return [line.strip() for line in open(f"/root/iof/hy2/{login}.txt", encoding="utf-8") if line.startswith("hy2://")]
    except OSError:
        return []


def panel_up(timeout=30):
    """Панель снова отвечает после systemctl restart."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if panel("/api/bot")[0] == 200:
                return True
        except OSError:
            pass
        time.sleep(0.5)
    return False


def wait_job(job_id, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        job = next((j for j in panel("/api/jobs")[1].get("jobs", []) if j["id"] == job_id), None)
        if job and job["state"] != "running":
            return job
        time.sleep(1)
    return None


def check_expired():
    """Истёкший номер подтверждения: 5 минут в тесте не ждать, поэтому Bot из модуля панели в этом
    процессе и номер, которому срок уже вышел."""
    sys.path.insert(0, "/opt/iof-web")
    import iof_bot
    sent = []

    class Stub:
        token = "1:stub"

        def call(self, method, params=None, timeout=20, files=None):
            sent.append((method, params or {}))
            return True
    bot = iof_bot.Bot("/root/iof", "/usr/local/bin/iof")
    num = "0123456789abcdef"
    bot.pending[num] = {"uid": 5001, "msg": 7, "kind": "check", "body": {}, "title": "t", "expires": time.time() - 1}
    bot.confirm(Stub(), "q1", {"id": 5001}, {"id": 5001, "role": "main"}, 5001, 7, "ok", num)
    report(sent and sent[0][0] == "answerCallbackQuery" and "устарело" in sent[0][1].get("text", "") and num not in bot.pending,
           "истёкший номер подтверждения (старше 5 минут): «устарело», номер удалён")


def check_actions(label):
    """Действия (этап 4): права (действия выключены, обычный админ), кнопки только главному, подтверждение
    и отмена, ход задачи одним сообщением, повторное, чужое, устаревшее нажатие и после перезапуска панели,
    занятая очередь, перенос, перезапуск Hysteria2 и проверка узла, создание и удаление группы, ссылки
    с QR и без qrencode, выдача ссылок выключена. Админ 5001 обычный, действия выключены, ссылки включены."""
    start = fake("/fake/state")["sent"]
    node = node_names()[0]

    got, c = ask(5001, "/check", "выключены")
    report(c is not None and "Телеграм бот" in text_of(c) and not buttons(c), "действия выключены: /check — отказ «включить в панели»")
    iof("set", "actions", "on")
    got, c = ask(5001, "/check", "только главному")
    report(c is not None and not buttons(c), "обычному админу /check — отказ «только главному админу»")
    got, card = ask(5001, f"/node {node}", "Нагрузка")
    report(keys(card) == [f"nr:{node}"], "обычному админу под карточкой узла кнопок действий нет")
    got, c = ask(5001, "/hy2", "Группы ссылок")
    report(keys(c) and all(k.startswith(("g:", "g#")) for k in keys(c)), "обычному админу в /hy2 только кнопки ссылок")
    got, c = ask(5001, "/audit", "Защита от РКН")
    report(c is not None and not buttons(c), "обычному админу под /audit кнопок нет")
    got, a = tap(5001, msg_id(card), f"hr:{node}")
    report("только главному" in toast(a) and not any(x["method"] == "sendMessage" for x in got),
           "обычный админ нажал старую кнопку «Перезапустить»: отказ во всплывающем окне")

    iof("admin", "set", "5001", "role", "main")
    got, card = ask(5001, f"/node {node}", "Нагрузка")
    report(keys(card) == [f"hr:{node}", f"as:{node}", f"ad:{node}", f"nr:{node}"],
           f"главному под карточкой {node}: перезапуск Hysteria2, проверки, «Обновить» ({', '.join(keys(card))})")
    logins = list(groups().values())
    got, c = ask(5001, "/hy2", "Группы ссылок")
    report(all(ref(k, g) in keys(c) for g in logins for k in ("g", "gd")) and keys(c)[-1:] == ["hf"],
           "главному в /hy2: ссылки и удаление у каждой группы, «Пересобрать все»")
    got, c = ask(5001, "/audit", "Защита от РКН")
    report(keys(c) == ["au:server", "au:dpi"], "главному под /audit: проверить все узлы по блокам")
    got, c = ask(5001, "/help", "<b>Команды</b>")
    report(c is not None and all(f"/{k}" in text_of(c) for k in ("check", "hy2add", "hy2refresh")) and "Тебе они доступны" in text_of(c),
           "/help: команды действий и «тебе они доступны»")
    menu = [x.get("command") for x in fake("/fake/state")["commands"]]
    report(all(k in menu for k in ("check", "hy2add", "hy2refresh")), "меню команд с действиями")

    # «Отмена», потом «Подтвердить» того же сообщения
    got, c = ask(5001, "/check", "Подтверди действие")
    ok, no = ok_no(c)
    mid, known = msg_id(c) if c else 0, job_ids()
    report(c is not None and "iof check" in text_of(c) and re.fullmatch(r"ok:[0-9a-f]{16}", ok) is not None and no == "no:" + ok[3:],
           "/check: «что будет сделано», кнопки «Подтвердить» и «Отмена»")
    got, a = tap(5001, mid, no, lambda g: any(x["method"] == "editMessageText" for x in g))
    edit = next((x for x in got if x["method"] == "editMessageText"), None)
    report(toast(a) == "Отменено" and edit is not None and msg_id(edit) == mid and "Отменено" in text_of(edit) and not buttons(edit),
           "«Отмена»: сообщение исправлено, кнопок больше нет")
    got, a = tap(5001, mid, ok)
    report("устарело" in toast(a) and job_ids() == known, "«Подтвердить» после «Отмены»: «устарело», задачи нет")

    # Запуск, ход задачи в том же сообщении, итог; повторное нажатие
    got, c = ask(5001, "/check", "Подтверди действие")
    mid = msg_id(c) if c else 0
    got, a, fin, job = run_action(5001, c)
    edits = [x for x in got if x["method"] == "editMessageText"]
    report(toast(a) == "Запускаю" and job is not None and job["title"] == "Проверка всех узлов (iof check)" and job["state"] in ("ok", "warn"),
           f"«Подтвердить»: задача бота в очереди панели, вид bot ({job and job['state']})")
    report(fin is not None and all(msg_id(x) == mid for x in edits) and any("Выполняется" in text_of(x) for x in edits)
           and not any(x["method"] == "sendMessage" for x in got) and not buttons(fin),
           f"ход задачи: правки того же сообщения ({len(edits)}), «выполняется», потом итог")
    report(fin is not None and job is not None and "<pre>" in text_of(fin) and all(f"{n}: " in text_of(fin) for n in node_names())
           and ("готово" in text_of(fin) if job["state"] == "ok" else "проблемы" in text_of(fin)),
           "итог /check: состояние и последние строки лога по каждому узлу")
    count = len(bot_jobs())
    got, a = tap(5001, mid, ok_no(c)[0])
    report("устарело" in toast(a) and len(bot_jobs()) == count, "повторное «Подтвердить»: «устарело», второй задачи нет")
    check_expired()

    # Чужой номер, занятая очередь, потом то же «Подтвердить» срабатывает
    rc, out, err = iof("invite", "main")
    say(5010, code_of(out))
    got, c3 = ask(5001, "/hy2refresh", "Подтверди действие")
    known = job_ids()
    got, a = tap(5010, msg_id(c3) if c3 else 0, ok_no(c3)[0])
    report(admin(5010) is not None and "устарело" in toast(a) and job_ids() == known, "номер подтверждения другого админа: «устарело»")
    code, data = panel("/api/security", {"block": "dpi"})
    got, a = tap(5001, msg_id(c3) if c3 else 0, ok_no(c3)[0])
    report(code == 202 and "«Защита от РКН: все узлы»" in toast(a) and job_ids() == known,
           f"очередь занята задачей панели: «сейчас идёт задача «Защита от РКН: все узлы»» ({code})")
    wait_job(data.get("job", ""))
    got, a, fin, job = run_action(5001, c3)
    report(job is not None and job["title"] == "Пересборка всех групп Hysteria2" and job["state"] == "ok" and fin is not None and "готово" in text_of(fin),
           "очередь освободилась: то же «Подтвердить» запускает hy2 refresh, итог «готово»")

    # Кнопки действий под карточкой узла
    got, _ = tap(5001, msg_id(card), f"hr:{node}", lambda g: confirmation(g) is not None)
    conf = confirmation(got)
    report(conf is not None and f"Перезапуск Hysteria2 на {node}" in text_of(conf) and "прервутся" in text_of(conf),
           "«Перезапустить Hysteria2»: подтверждение с предупреждением, новым сообщением")
    got, a, fin, job = run_action(5001, conf)
    report(job is not None and job["title"] == f"Перезапуск Hysteria2 на {node}" and job["state"] == "ok" and fin is not None,
           f"перезапуск Hysteria2 на {node} из бота: «готово»")
    got, _ = tap(5001, msg_id(card), f"as:{node}", lambda g: confirmation(g) is not None)
    conf = confirmation(got)
    got, a, fin, job = run_action(5001, conf)
    report(job is not None and job["title"] == f"Аудит сервера: {node}" and job["state"] == "ok" and fin is not None,
           f"проверка узла {node} (аудит сервера) из бота")

    # После перезапуска панели номера подтверждений забыты
    got, c4 = ask(5001, "/hy2refresh", "Подтверди действие")
    subprocess.run(["systemctl", "restart", "iof-web"], timeout=60)
    restarted = panel_up() and thread_state("running", 30) and polling()
    known = job_ids()
    got, a = tap(5001, msg_id(c4) if c4 else 0, ok_no(c4)[0])
    report(restarted and "устарело" in toast(a) and job_ids() == known, "«Подтвердить» после перезапуска панели: «устарело»")

    # Перенос отсюда: меняющее действие отказано сразу, check разрешён
    got, c5 = ask(5001, "/hy2refresh", "Подтверди действие")
    with open(MIGRATE, "w") as f:
        f.write(f"role=source\nid=iof-test\npeer=root@192.0.2.1\nstarted={int(time.time())}\n")
    try:
        got, c = ask(5001, f"/hy2add {label}", "перенос")
        report(c is not None and "идёт перенос управления" in text_of(c) and not buttons(c),
               "при переносе /hy2add — отказ «идёт перенос управления», без подтверждения")
        known = job_ids()
        got, a = tap(5001, msg_id(c5) if c5 else 0, ok_no(c5)[0])
        report("перенос" in toast(a) and job_ids() == known, "при переносе «Подтвердить», полученное до него: отказ")
        got, c = ask(5001, "/check", "Подтверди действие")
        got, a, fin, job = run_action(5001, c)
        report(job is not None and job["title"] == "Проверка всех узлов (iof check)" and fin is not None,
               "при переносе /check разрешён, как iof check")
    finally:
        os.remove(MIGRATE)

    # Группа из бота: создание, ссылки с QR и без qrencode, выдача ссылок выключена, удаление
    got, c = ask(5001, f"/hy2add {label}", "Подтверди действие")
    report(c is not None and f"«{label}»" in text_of(c) and "iof hy2 add" in text_of(c), f"/hy2add {label}: подтверждение с командой")
    got, a, fin, job = run_action(5001, c)
    login = groups().get(label, "")
    links = links_of(login)
    btn = next((k for k in keys(fin) if k.startswith(("g:", "g#"))), "")
    report(job is not None and job["title"] == f"Создание группы «{label}»" and job["state"] == "ok" and login and links,
           f"группа «{label}» создана из бота: есть в index.tsv, ссылок {len(links)}")
    report(btn == ref("g", login), f"под итогом — кнопка ссылок группы ({btn})")
    secrets = {p for link in links for p in (link[6:link.rindex("@")], link[6:link.rindex("@")].split(":", 1)[-1]) if len(p) >= 8}
    mid = msg_id(fin) if fin else 0
    got, a = tap(5001, mid, btn, lambda g: sum(x["method"] == "sendPhoto" for x in g) >= len(links))
    photos = [x for x in got if x["method"] == "sendPhoto"]
    caps = [str(x["params"].get("caption", "")) for x in photos]
    report(len(photos) == len(links) and all((x["params"].get("photo") or {}).get("filename") == "qr.png"
                                              and (x["params"].get("photo") or {}).get("size", 0) > 100 for x in photos)
           and all(any(escape(link, quote=False) in cap for cap in caps) for link in links) and all("<pre>hy2://" in cap for cap in caps),
           f"ссылки группы: {len(photos)} фото QR (PNG), в подписи узел и ссылка в <pre>")
    qr = shutil.which("qrencode")
    if qr:
        os.rename(qr, qr + ".iof-test")
    try:
        got, a = tap(5001, mid, btn, lambda g: sum(x["method"] == "sendMessage" for x in g) >= len(links))
    finally:
        if qr:
            os.rename(qr + ".iof-test", qr)
    texts = [text_of(x) for x in got if x["method"] == "sendMessage"]
    report(qr and len(texts) == len(links) and not any(x["method"] == "sendPhoto" for x in got)
           and all(any(escape(link, quote=False) in t for t in texts) for link in links),
           "без qrencode: ссылки только текстом")
    iof("set", "links", "off")
    got, c = ask(5001, "/hy2", "Группы ссылок")
    report(c is not None and "выключена" in text_of(c) and not any(k.startswith(("g:", "g#")) for k in keys(c)) and ref("gd", login) in keys(c),
           "выдача ссылок выключена: в /hy2 нет кнопок ссылок, «выключена в панели»")
    got, a = tap(5001, mid, btn)
    report("выключена" in toast(a) and not any(x["method"] in ("sendPhoto", "sendMessage") for x in got),
           "выдача ссылок выключена: старая кнопка ссылок — отказ")
    iof("set", "links", "on")
    got, _ = tap(5001, msg_id(c) if c else 0, ref("gd", login), lambda g: confirmation(g) is not None)
    conf = confirmation(got)
    report(conf is not None and f"Удаление группы «{label}»" in text_of(conf) and "перестанут работать" in text_of(conf),
           "🗑 у группы: подтверждение удаления с предупреждением")
    got, a, fin2, job = run_action(5001, conf)
    report(job is not None and job["title"] == f"Удаление группы «{label}»" and job["state"] == "ok" and label not in groups(),
           f"группа «{label}» удалена из бота: в index.tsv её нет")
    got, a = tap(5001, mid, btn)
    report("Группы больше нет" in toast(a), "кнопка ссылок удалённой группы: «группы больше нет»")

    answers = json.dumps(calls(start), ensure_ascii=False)
    logs = journal() + json.dumps(panel("/api/jobs")[1], ensure_ascii=False)
    report(secrets and all(s in answers for s in secrets) and not [s for s in secrets | hy2_secrets() if s in logs],
           f"паролей Hysteria2 ({len(secrets)}) нет в журнале iof-web и логах задач, они только в ответах админу")
    iof("set", "actions", "off")


def run():
    for f in (BOT_JSON, BOT_TOKEN):
        if os.path.exists(f):
            os.remove(f)
    fake("/fake/reset", {})

    rc, out, err = iof("on")
    report(rc != 0 and "токен" in err, "iof bot on без токена: отказ")
    rc, out, err = iof("token", stdin="не токен\n")
    report(rc != 0 and "не токен" in err, "iof bot token: не токен — отказ")
    rc, out, err = iof("token", stdin=BAD_TOKEN + "\n")
    report(rc != 0 and "не принял" in err and not os.path.exists(BOT_TOKEN), f"iof bot token: отозванный токен — отказ ({err.strip()[:80]})")
    rc, out, err = iof("token", stdin=TOKEN + "\n")
    report(rc == 0 and "@iof_stand_bot" in out, "iof bot token: getMe прошёл, бот @iof_stand_bot")
    modes = {f: oct(os.stat(f).st_mode & 0o777) for f in (BOT_JSON, BOT_TOKEN)}
    report(set(modes.values()) == {"0o600"}, f"bot.json и bot.token с правами 600 ({modes})")
    report(cfg()["username"] == "iof_stand_bot" and not cfg()["enabled"], "в bot.json имя бота, бот ещё выключен")

    rc, out, err = iof("on")
    report(rc == 0 and polling(), "iof bot on: бот опрашивает Bot API")
    menu = [c.get("command") for c in fake("/fake/state")["commands"]]
    report(menu == ["status", "node", "audit", "service", "hy2", "check", "hy2add", "hy2refresh", "start", "help"],
           f"меню команд: {', '.join(menu)}")

    r = say(5001, "/start")
    report(r == [], "чужому на /start бот не отвечает")
    r = say(5001, "a" * 64)
    report(len(r or []) == 1 and "не подошёл" in first(r), "неверный код приглашения: «не подошёл»")
    report(in_journal("сообщение от чужого, без ответа: id 5001 @user5001"), "сообщение чужого записано в журнал (ID, username)")

    rc, out, err = iof("invite", "regular")
    code = code_of(out)
    raw = open(BOT_JSON, encoding="utf-8").read()
    report(rc == 0 and code and hashlib.sha256(code.encode()).hexdigest() in raw and code not in raw,
           "iof bot invite regular: код из 64 знаков, в bot.json только хэш")
    report(f"t.me/iof_stand_bot?start={code}" in out, "iof bot invite: ссылка t.me с кодом")
    r = say(5001, code)
    a = admin(5001)
    report("ты админ" in first(r) and "обычный" in first(r), "код приглашения принят, ответ с ролью")
    report(bool(a) and a["role"] == "regular" and a["username"] == "user5001" and not cfg()["invites"],
           "админ добавлен с ролью «обычный», приглашение израсходовано")
    r = say(5002, code)
    report("не подошёл" in first(r) and admin(5002) is None, "тот же код второй раз не принят")

    rc, out, err = iof("invite", "main")
    code2 = code_of(out)
    data = cfg()
    data["invites"][0]["expires"] = int(time.time()) - 10
    with open(BOT_JSON + ".t", "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.chmod(BOT_JSON + ".t", 0o600)
    os.replace(BOT_JSON + ".t", BOT_JSON)
    r = say(5002, code2)
    report("не подошёл" in first(r) and admin(5002) is None, "просроченный код не принят")

    r = say(5001, "/start")
    report("Привет" in first(r) and "обычный" in first(r), "/start админу: приветствие и роль")
    r = say(5001, "/help")
    report("/start" in first(r) and "/help" in first(r), "/help админу: список команд")
    sent = fake("/fake/sent?after=0")
    report(sent[-1]["params"].get("parse_mode") == "HTML" and sent[-1]["params"].get("chat_id") == 5001, "ответ в личный чат, parse_mode HTML")
    r = say(5001, "что-то непонятное")
    report("/help" in first(r), "непонятное от админа: подсказка /help")
    r = say(5001, "/start", chat_type="group")
    report(r == [], "в групповом чате бот не отвечает и админу")

    rc, out, err = iof("invite", "main")
    code3 = code_of(out)
    r = say(5003, code3, chat_type="supergroup")
    report(r == [] and admin(5003) is None and len(cfg()["invites"]) == 1, "код из группового чата не принят, приглашение цело")
    r = say(5003, f"/start {code3}")
    report("главный" in first(r) and (admin(5003) or {}).get("role") == "main", "код по ссылке (/start <код>): админ с ролью «главный»")

    rc, out, err = iof("invite", "main")
    code4 = code_of(out)
    r = say(5004, code4, date=int(time.time()) - 3600)
    report(r == [] and admin(5004) is None, "сообщение старше запуска бота на 5 минут пропущено")
    h4 = hashlib.sha256(code4.encode()).hexdigest()
    rc, out, err = iof("show")
    report(rc == 0 and h4[:12] in out and code4 not in out and TOKEN not in out and "5003" in out,
           "iof bot show: админы, хэш приглашения, без кода и токена")
    rc, out, err = iof("invite", "del", h4[:8])
    r = say(5004, code4)
    report(rc == 0 and not cfg()["invites"] and "не подошёл" in first(r), "iof bot invite del: приглашение отозвано")

    rc1, _, _ = iof("admin", "set", "5003", "role", "regular")
    rc2, _, _ = iof("admin", "set", "5003", "sound", "on")
    a = admin(5003) or {}
    report(rc1 == 0 and rc2 == 0 and a.get("role") == "regular" and a.get("sound") is True, "admin set: роль и звук в тихие часы")
    rc, _, err = iof("admin", "set", "9999", "role", "main")
    report(rc != 0 and "нет" in err, "admin set: неизвестный ID — отказ")
    rc, _, _ = iof("admin", "del", "5003")
    r = say(5003, "/start")
    report(rc == 0 and admin(5003) is None and r == [], "admin del: админ удалён, бот ему больше не отвечает")
    ok = [iof("set", "actions", "on")[0], iof("set", "links", "off")[0], iof("set", "quiet", "23:00-8:00")[0]]
    c = cfg()
    report(ok == [0, 0, 0] and c["actions"] is True and c["hy2_links"] is False and c["quiet"] == {"from": "23:00", "to": "08:00"},
           "iof bot set: действия, ссылки, тихие часы")
    rc, _, _ = iof("set", "quiet", "25:00-08:00")
    rc2, _, _ = iof("set", "quiet", "off")
    report(rc != 0 and rc2 == 0 and cfg()["quiet"] is None, "тихие часы: неверное время — отказ, off — выключены")
    check_page()
    check_views()
    check_actions(sys.argv[1])

    # Второй опрос с тем же токеном: поддельный API, как Telegram, обрывает ждущий опрос бота ответом 409
    polling()
    try:
        urllib.request.urlopen(urllib.request.Request(f"{FAKE}/bot{TOKEN}/getUpdates", data=b'{"timeout": 0}',
                                                      headers={"Content-Type": "application/json"}), timeout=10).read()
    except OSError:
        pass
    report(in_journal("опрашивает кто-то ещё (409)"), "409 (токен опрашивает кто-то ещё) записан в журнал панели")
    r = say(5001, "/help")
    report("/start" in first(r), "после 409 бот снова отвечает")

    rc, out, err = iof("invite", "main")
    code5 = code_of(out)
    with open(MIGRATE, "w") as f:
        f.write(f"role=source\nid=iof-test\npeer=root@192.0.2.1\nstarted={int(time.time())}\n")
    rc, out, err = iof("invite", "main")
    report(rc != 0 and "идёт перенос" in err, "при переносе отсюда: iof bot invite отказана")
    rc, out, err = iof("show")
    report(rc == 0 and "Перенос" in out, "при переносе: iof bot show работает")
    code, data = panel("/api/bot", {"action": "set", "key": "actions", "on": True})
    report(code == 400 and "перенос" in data.get("error", "") and cfg()["actions"] is False, "при переносе: панель не меняет настройки бота")
    r = say(5005, code5)
    report("перенос" in first(r) and admin(5005) is None and len(cfg()["invites"]) == 1, "при переносе: код не принят, бот отвечает, что идёт перенос")

    with open(MIGRATE, "w") as f:
        f.write(f"role=target\nid=iof-test\npeer=root@192.0.2.1\nstarted={int(time.time())}\n")
    report(quiet(), "сервер принимает управление (role=target): бот не опрашивает API")
    report(thread_state("migrate"), "role=target: /api/bot показывает, что бот ждёт конца переноса")
    upd, before = say(5001, "/help", wait=False)
    time.sleep(4)
    report(fake("/fake/state")["offset"] <= upd and not fake(f"/fake/sent?after={before}"), "role=target: сообщение не обработано")
    os.remove(MIGRATE)
    r = replies(upd, before, 20)
    report("/start" in first(r), "без переноса бот снова работает и отвечает на ждавшее сообщение")

    rc, out, err = iof("off")
    report(rc == 0 and quiet() and cfg()["enabled"] is False, "iof bot off: бот не опрашивает API")
    rc, out, err = iof("on")
    report(rc == 0 and polling(), "iof bot on: снова опрашивает")
    rc, out, err = iof("token", stdin="\n")
    report(rc == 0 and not os.path.exists(BOT_TOKEN) and cfg()["enabled"] is False and quiet(),
           "пустой токен: токен удалён, бот выключен и не опрашивает API")

    secret = TOKEN.split(":", 1)[1]
    leaks = [name for name, text in (("журнал iof-web и fake-tg", journal()), ("bot.json", open(BOT_JSON).read()),
                                     ("iof bot show", iof("show")[1])) if secret in text]
    report(not leaks, "токена нет в журналах, bot.json и iof bot show" + (f": есть в {', '.join(leaks)}" if leaks else ""))


try:
    run()
finally:
    if os.path.exists(MIGRATE):
        os.remove(MIGRATE)
    remove_long()
PY
)"
  rc=$?
  tally "$out"
  if (( rc != 0 )); then fail "проверка бота завершилась с кодом $rc"; fi
  on "$M" rm -f /root/iof/migrate.conf
  GUARD_LEFT=0
  bot_restore
}

# Оценка проверки $2 на узле $1 из iof api audit: "статус значение", down — узел не ответил.
# $3 — блок, по умолчанию server
audit_get() {
  iofm api audit 2>/dev/null | on_in "$M" python3 -c '
import json, sys
node = json.load(sys.stdin)["blocks"][sys.argv[3]]["nodes"].get(sys.argv[1])
check = next((c for c in node["checks"] if c["id"] == sys.argv[2]), None) if node else None
print("нет" if not node else "down" if not node["reachable"] else "%s %s" % (check["status"], check["value"]) if check else "нет")
' "$1" "$2" "${3:-server}"
}

# То, что check_audit и check_dpi меняют на узле $1: лишний слушатель, настройка sshd, остановленный
# ssh, конфиг Hysteria2 (его копия лежит рядом, служба с правленым конфигом не перезапускалась)
audit_restore() {
  on "$1" bash -c 'systemctl stop iof-test-listen 2>/dev/null; systemctl reset-failed iof-test-listen 2>/dev/null
    rm -f /etc/ssh/sshd_config.d/00-iof-test.conf; systemctl start ssh
    if [[ -f /etc/hysteria/config.yaml.iof-test ]]; then mv -f /etc/hysteria/config.yaml.iof-test /etc/hysteria/config.yaml; fi' >/dev/null 2>&1 || true
}

# Аудит безопасности: все узлы проверены, вход root по паролю (на стенде он включён) оценён как
# проблема. Меняется то, что меняется на узле: лишний слушающий порт попадает в «лишние», а
# iof audit cron сообщает об ухудшении; PasswordAuthentication no снимает проблему; узел без ssh
# остаётся без оценок. Узел для этого — первый, который не управляющий сервер
check_audit() {
  local out n node="" got
  if out="$(iofm audit run 2>&1)"; then ok "iof audit run"; else fail "iof audit run"; details "$out"; return 1; fi
  for n in "${NAMES[@]}"; do
    if [[ "$n" != "$M" && -z "$node" ]]; then node="$n"; fi
    got="$(audit_get "$n" ssh_password)"
    if [[ "$got" == crit* ]]; then ok "аудит $n: вход по паролю — $got"; else fail "аудит $n: вход по паролю — «$got», ожидалась проблема"; fi
  done
  got="$(audit_get "$node" ports)"
  if [[ "$got" == good* ]]; then ok "аудит $node: слушающие порты — $got"; else fail "аудит $node: слушающие порты — «$got»"; fi

  AUDIT_LEFT="$node"
  on "$node" systemd-run --quiet --collect --unit=iof-test-listen perl -MIO::Socket::INET \
    -e '@keep = (IO::Socket::INET->new(Listen => 1, LocalPort => 18080, ReuseAddr => 1)); sleep 300' >/dev/null 2>&1
  sleep 1
  out="$(iofm audit cron 2>&1)" || true
  got="$(audit_get "$node" ports)"
  if [[ "$got" == crit*18080/tcp* ]]; then ok "аудит $node: лишний порт найден — $got"; else fail "аудит $node: лишний порт 18080 не найден — «$got»"; fi
  if grep -q "^$node: Слушающие порты" <<<"$out"; then
    ok "iof audit cron: сообщил, что на $node стало хуже"
  else
    fail "iof audit cron не сообщил об ухудшении на $node"
    details "$out"
  fi
  on "$node" systemctl stop iof-test-listen >/dev/null 2>&1

  on "$node" bash -c 'echo "PasswordAuthentication no" > /etc/ssh/sshd_config.d/00-iof-test.conf'
  iofm -n "$node" audit run server >/dev/null 2>&1
  got="$(audit_get "$node" ssh_password)"
  if [[ "$got" == good* ]]; then ok "аудит $node: после PasswordAuthentication no — $got"; else fail "аудит $node: после PasswordAuthentication no — «$got»"; fi
  got="$(audit_get "$node" ports)"
  if [[ "$got" == good* ]]; then ok "аудит $node: лишний порт пропал — $got"; else fail "аудит $node: слушающие порты после остановки слушателя — «$got»"; fi
  on "$node" rm -f /etc/ssh/sshd_config.d/00-iof-test.conf

  on "$node" systemctl stop ssh >/dev/null 2>&1
  out="$(iofm -n "$node" audit run server 2>&1)" || true
  got="$(audit_get "$node" ssh_password)"
  on "$node" systemctl start ssh >/dev/null 2>&1
  if [[ "$got" == "down" ]] && grep -q '^Ошибки (1):' <<<"$out"; then
    ok "аудит $node без ssh: узел без оценок, в выводе «Ошибки (1)»"
  else
    fail "аудит $node без ssh: «$got»"
    details "$out"
  fi
  for _ in $(seq 1 20); do
    if [[ "$(on "$node" systemctl is-active ssh 2>/dev/null || true)" == "active" ]]; then break; fi
    sleep 0.5
  done
  if out="$(iofm -n "$node" audit run server 2>&1)" && [[ "$(audit_get "$node" ssh_password)" == crit* ]]; then
    AUDIT_LEFT=""
    ok "аудит $node: узел снова проверен, стенд как был"
  else
    fail "аудит $node после возврата ssh"
    details "$out"
  fi
}

# Блок «Защита от РКН» (dpi), его уже проверил iof audit run в check_audit: у каждого узла конфиг
# Hysteria2 совпадает с шаблоном, порт отвечает на зонд QUIC, AmneziaWG «не установлен» (на стенде
# его нет). На узле, который не управляющий сервер, в конфиг дописывается блок (служба не
# перезапускается): проверка видит расхождение с шаблоном, iof audit cron сообщает об ухудшении,
# после возврата конфига расхождения нет. Пароль Hysteria2 из шаблона в результаты не попадает
check_dpi() {
  local out n node="" got secret
  for n in "${NAMES[@]}"; do
    if [[ "$n" != "$M" && -z "$node" ]]; then node="$n"; fi
    got="$(audit_get "$n" hy2_template dpi)"
    if [[ "$got" == good* ]]; then ok "dpi $n: конфиг и шаблон — $got"; else fail "dpi $n: конфиг и шаблон — «$got», ожидалось совпадение"; fi
    got="$(audit_get "$n" hy2_quic dpi)"
    if [[ "$got" == good* ]]; then ok "dpi $n: зонд QUIC — $got"; else fail "dpi $n: зонд QUIC — «$got»"; fi
    got="$(audit_get "$n" awg_params dpi)"
    if [[ "$got" == none*"не установлен"* ]]; then ok "dpi $n: AmneziaWG — $got"; else fail "dpi $n: AmneziaWG — «$got», ожидалось «не установлен»"; fi
  done

  AUDIT_LEFT="$node"
  on "$node" bash -c 'cp -p /etc/hysteria/config.yaml /etc/hysteria/config.yaml.iof-test
    printf "\nmasquerade:\n  type: string\n  string:\n    content: iof-test\n" >> /etc/hysteria/config.yaml'
  out="$(iofm audit cron 2>&1)" || true
  got="$(audit_get "$node" hy2_template dpi)"
  if [[ "$got" == warn*masquerade* ]]; then ok "dpi $node: правка конфига найдена — $got"; else fail "dpi $node: правка конфига не найдена — «$got»"; fi
  if grep -q "^$node: Конфиг и шаблон" <<<"$out"; then
    ok "iof audit cron: сообщил, что на $node конфиг разошёлся с шаблоном"
  else
    fail "iof audit cron не сообщил о расхождении с шаблоном на $node"
    details "$out"
  fi
  on "$node" mv -f /etc/hysteria/config.yaml.iof-test /etc/hysteria/config.yaml
  if out="$(iofm -n "$node" audit run dpi 2>&1)" && [[ "$(audit_get "$node" hy2_template dpi)" == good* ]]; then
    AUDIT_LEFT=""
    ok "dpi $node: конфиг возвращён, расхождения нет"
  else
    fail "dpi $node после возврата конфига: «$(audit_get "$node" hy2_template dpi)»"
    details "$out"
  fi

  secret="$(on "$M" bash -c 'f="$(. /root/iof/iof.env 2>/dev/null; echo "${HY2_TEMPLATE:-/etc/hysteria/config.yaml}")"
    sed -n "s/^[[:space:]]*password:[[:space:]]*//p" "$f" | head -n 1')"
  if [[ -z "$secret" ]]; then
    fail "dpi: в шаблоне Hysteria2 на $M не нашёлся пароль, проверить утечку нечем"
  elif on "$M" bash -c 'grep -rqF -- "$0" /root/iof/audit || iof audit show 2>/dev/null | grep -qF -- "$0" || iof api audit 2>/dev/null | grep -qF -- "$0"' "$secret"; then
    fail "dpi: пароль Hysteria2 попал в результаты аудита"
  else
    ok "dpi: пароля Hysteria2 нет в /root/iof/audit, iof audit show и iof api audit"
  fi
}

# Что осталось от мишеней на узле $1: «юнитов папок_в_/run правил_iptables»
probe_left() {
  on "$1" bash -c 'printf "%s %s %s" "$(systemctl list-units --all --plain --no-legend "iof-probe-*" | wc -l)" \
    "$(ls -d /run/iof-probe-* 2>/dev/null | wc -l)" "$(iptables -w -S INPUT 2>/dev/null | grep -c iof-probe || true)"'
}

# Входящие на узле $1 запрещены политикой DROP, открыты только SSH, Hysteria2 и ответы (on); off — как было
probe_fw() {
  if [[ "$2" == "on" ]]; then
    on "$1" bash -c 'c="-m comment --comment iof-test-fw"
      iptables -w -A INPUT -i lo $c -j ACCEPT
      iptables -w -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED $c -j ACCEPT
      iptables -w -A INPUT -p tcp --dport 22 $c -j ACCEPT
      iptables -w -A INPUT -p udp --dport 443 $c -j ACCEPT
      iptables -w -P INPUT DROP'
  else
    on "$1" bash -c 'iptables -w -P INPUT ACCEPT
      iptables -w -S INPUT | grep -- "--comment iof-test-fw" | sed "s/^-A/-D/" | while read -r r; do iptables -w $r; done' >/dev/null 2>&1 || true
  fi
}

# Последний результат проверки с ПК по узлу $1: «статус уверенность», нет — узла в результате нет
probe_result() {
  iofm api audit 2>/dev/null | on_in "$M" python3 -c '
import json, sys
r = json.load(sys.stdin)["probe"]["last"] or {}
n = r.get("nodes", {}).get(sys.argv[1])
print("%s %s" % (n["status"], r["confidence"]) if n else "нет")' "$1"
}

# Готовые отчёты probe.ps1 из контроля текущей сессии, в /root/iof-test-probe-<вид>.json на управляющем
# сервере: block — у первого узла с ПК не проходит TCP, остальное как у контроля; vpn — IP источника
# равен адресу узла; token — в отчёте токен мишеней; alien — отчёт от другой проверки
probe_reports() {
  on_in "$M" python3 - "$1" <<'PY'
import copy, json, sys
s = json.load(open("/root/iof/audit/probe/session.json"))
token = open("/root/iof/audit/probe/token").read().strip()
first = sys.argv[1]
PC = "172.30.0.99"  # адрес ПК: частный, но в отчёте remap, как со стенда


def report(kind):
    targets = []
    for name, n in s["nodes"].items():
        if n["state"] != "started":
            continue
        t = copy.deepcopy(n["control"])
        t["node"] = name
        t["icmp"] = {"sent": 3, "got": 3, "ms": 40}
        t["tunnel"] = {"tested": False, "reason": "nohysteria"}
        if kind == "block" and name == first:
            t["conn"] = [{"tcp": None, "tls": None, "fp": "", "bytes": 0, "ms": 0, "src": "", "err": "tcp: timeout"}] * 3
        # IP источника, как его видит мишень. В контроле это адрес управляющего сервера, а он бывает
        # узлом (в CI так всегда): с ним отчёт значил бы «ПК ходил через VPN на этот узел»
        for c in t["conn"]:
            if c.get("src"):
                c["src"] = s["nodes"][first]["ip"] if kind == "vpn" else PC
        targets.append(t)
    lists = [{"host": h, "list": "white", "ok": True, "err": ""} for h in s["lists"]["white"]]
    lists += [{"host": h, "list": "black", "ok": False, "err": "tls: timeout"} for h in s["lists"]["black"]]
    rep = {"v": 1, "session": "deadbeef" if kind == "alien" else s["id"], "remap": kind != "vpn",
           "client": {"os": "Windows 10.0", "vpn": [], "proxy": "none"}, "lists": lists, "targets": targets}
    if kind == "token":
        rep["note"] = token
    return rep


for kind in ("block", "vpn", "token", "alien"):
    with open(f"/root/iof-test-probe-{kind}.json", "w") as f:
        json.dump(report(kind), f)
PY
}

# Мишень узла $1 из текущей сессии отвечает с токеном и молчит без него, по TLS и по UDP. Строки ok/fail
probe_answers() {
  on_in "$M" python3 - "$1" <<'PY'
import json, socket, ssl, sys
s = json.load(open("/root/iof/audit/probe/session.json"))
token = open("/root/iof/audit/probe/token").read().strip().encode()
n = s["nodes"][sys.argv[1]]
ip, port = n["ip"], n["port"]


def tls(line):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    got = b""
    try:
        c = ctx.wrap_socket(socket.create_connection((ip, port), timeout=10))
        c.sendall(line)
        while len(got) < 262144 + 64:
            x = c.recv(65536)
            if not x:
                break
            got += x
            if got.startswith(b"OK ") and b"\n" in got and len(got.split(b"\n", 1)[1]) >= 262144:
                break
        c.close()
    except OSError:
        pass
    return got


def udp(data):
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.settimeout(1.5)
    u.sendto(data, (ip, port))
    try:
        return u.recv(2048)
    except OSError:
        return b""


def say(good, text):
    print(("ok" if good else "fail") + "\t" + text)


a, b = tls(b"hello\n"), tls(b"IOF-PROBE " + token + b"\n")
say(a == b"", f"мишень {sys.argv[1]}: TLS без токена — ничего ({len(a)} байт)")
say(b.startswith(b"OK ") and len(b.split(b"\n", 1)[1]) == 262144, f"мишень {sys.argv[1]}: TLS с токеном — ответ и 256 КБ ({len(b)} байт)")
c, d = udp(b"hello" * 8), udp(b"IOFP" + token + b"12345678")
say(c == b"", f"мишень {sys.argv[1]}: UDP без токена — ничего ({len(c)} байт)")
say(d == b"IOFP" + b"\0" * len(token) + b"12345678", f"мишень {sys.argv[1]}: UDP с токеном — пакет с затёртым токеном ({len(d)} байт)")
PY
}

# Строки ok/fail от python на сервере в итоги проверки
tally() {
  local line
  while IFS= read -r line; do
    case "$line" in
      ok$'\t'*)   ok "${line#ok$'\t'}" ;;
      fail$'\t'*) fail "${line#fail$'\t'}" ;;
      *)          echo "$line" | mask ;;
    esac
  done <<<"$1"
}

# Проверка с ПК (iof audit probe). Мишени поднимаются на узлах с python3, узел без него получает
# «не проверяется». На первом узле с python3, который не управляющий сервер, входящие запрещены
# политикой DROP: мишень открывает свой порт правилом и снимает его. Мишени отвечают с токеном
# и молчат без него, готовый отчёт даёт ожидаемые оценки, отчёт с токеном и чужой не принимаются,
# токена нет в выводе и результатах. После stop и по сроку (RuntimeMaxSec) на узлах ничего не остаётся
check_probe() {
  local out start n node="" got token nopy=() first
  PROBE_PY=()
  for n in "${NAMES[@]}"; do
    if on "$n" bash -c 'command -v python3' >/dev/null 2>&1; then
      PROBE_PY+=("$n")
      if [[ "$n" != "$M" && -z "$node" ]]; then node="$n"; fi
    else
      nopy+=("$n")
    fi
  done
  if (( ${#PROBE_PY[@]} == 0 )); then fail "проверка с ПК: ни на одном узле нет python3"; return 1; fi
  first="${PROBE_PY[0]}"
  PROBE_LEFT=1
  iofm audit probe stop >/dev/null 2>&1 || true
  if [[ -n "$node" ]]; then
    PROBE_FW_LEFT="$node"
    probe_fw "$node" on
  fi

  if start="$(iofm audit probe start --ttl 600 2>&1)"; then ok "iof audit probe start"; else fail "iof audit probe start"; details "$start"; return 1; fi
  for n in "${PROBE_PY[@]}"; do
    if grep -qE "^  $n +порт [0-9]+ +контроль: (ping [0-9]/[0-9] · )?TCP 3/3 · TLS 3/3 · данные 3/3 · UDP 5/5 · QUIC 5/5" <<<"$start"; then
      ok "мишень $n: контроль с управляющего сервера прошёл все слои"
    else
      fail "мишень $n: контроль прошёл не все слои"
      details "$start"
    fi
  done
  for n in "${nopy[@]}"; do
    if grep -qE "^  $n +не проверяется: нет python3.*apt install python3" <<<"$start"; then
      ok "мишень $n: нет python3 — не проверяется, с командой"
    else
      fail "мишень $n без python3: нет строки «не проверяется»"
    fi
  done
  if (( ${#nopy[@]} == 0 )); then echo "      узла без python3 нет: этот случай не проверялся"; fi
  if [[ -n "$node" ]]; then
    got="$(probe_left "$node")"
    if [[ "$got" == "1 1 2" ]]; then ok "мишень $node: входящие запрещены, порт открыт правилами iof-probe"; else fail "мишень $node при запрете входящих: «$got», ожидалось «1 1 2»"; fi
  fi
  tally "$(probe_answers "$first")"

  probe_reports "$first"
  if out="$(on "$M" bash -c 'iof audit probe import < /root/iof-test-probe-block.json' 2>&1)"; then ok "iof audit probe import"; else fail "iof audit probe import"; details "$out"; fi
  got="$(probe_result "$first")"
  if [[ "$got" == "crit high" ]]; then ok "отчёт: у $first с ПК не проходит TCP — проблема, уверенность высокая"; else fail "отчёт: $first — «$got», ожидалось «crit high»"; fi
  for n in "${PROBE_PY[@]:1}"; do
    got="$(probe_result "$n")"
    if [[ "$got" == "good high" ]]; then ok "отчёт: $n — всё проходит"; else fail "отчёт: $n — «$got», ожидалось «good high»"; fi
  done
  for n in "${nopy[@]}"; do
    got="$(probe_result "$n")"
    if [[ "$got" == none* ]]; then ok "отчёт: $n без мишени — нет данных"; else fail "отчёт: $n — «$got», ожидалось «none»"; fi
  done
  if out="$(on "$M" bash -c 'iof audit probe import < /root/iof-test-probe-vpn.json' 2>&1)" \
     && [[ "$(probe_result "$first")" == "none low" ]] && grep -q "адрес узла $first" <<<"$out"; then
    ok "отчёт через VPN (IP источника — адрес $first): уверенность низкая, оценок нет"
  else
    fail "отчёт через VPN: «$(probe_result "$first")»"
    details "$out"
  fi
  if out="$(on "$M" bash -c 'iof audit probe import < /root/iof-test-probe-token.json' 2>&1)"; then
    fail "отчёт с токеном мишеней принят"
  elif grep -q 'токен' <<<"$out"; then ok "отчёт с токеном мишеней отклонён"; else fail "отчёт с токеном: «$out»"; fi
  if out="$(on "$M" bash -c 'iof audit probe import < /root/iof-test-probe-alien.json' 2>&1)"; then
    fail "отчёт от другой проверки принят"
  elif grep -q 'другой проверки' <<<"$out"; then ok "отчёт от другой проверки отклонён"; else fail "отчёт от другой проверки: «$out»"; fi

  token="$(on "$M" cat /root/iof/audit/probe/token)"
  if [[ -z "$token" ]]; then
    fail "проверка с ПК: нет токена мишеней, утечку проверить нечем"
  elif grep -qF -- "$token" <<<"$start" \
     || on "$M" bash -c 'grep -rqF --exclude=token -- "$0" /root/iof/audit || iof api audit | grep -qF -- "$0" || iof audit probe list | grep -qF -- "$0"' "$token"; then
    fail "токен мишеней попал в вывод iof или результаты"
  else
    ok "токена мишеней нет в выводе probe start, /root/iof/audit, iof api audit и probe list"
  fi

  out="$(iofm audit probe stop 2>&1)" || true
  for n in "${PROBE_PY[@]}"; do
    got="$(probe_left "$n")"
    if [[ "$got" == "0 0 0" ]]; then ok "мишень $n: после stop ничего не осталось"; else fail "мишень $n после stop: «$got» (юнитов, папок, правил)"; details "$out"; fi
  done

  # По сроку: systemd останавливает мишени сам, ExecStopPost снимает правило и файлы
  if ! out="$(iofm audit probe start --ttl 20 2>&1)"; then fail "iof audit probe start --ttl 20"; details "$out"; fi
  sleep 28
  for n in "${PROBE_PY[@]}"; do
    got="$(probe_left "$n")"
    if [[ "$got" == "0 0 0" ]]; then ok "мишень $n: по сроку (RuntimeMaxSec) исчезла вместе с правилами"; else fail "мишень $n через 28 с при сроке 20 с: «$got»"; fi
  done
  iofm audit probe stop >/dev/null 2>&1 || true
  on "$M" bash -c 'rm -f /root/iof-test-probe-*.json'
  PROBE_LEFT=0
  if [[ -n "$node" ]]; then
    probe_fw "$node" off
    PROBE_FW_LEFT=""
  fi
}

# После проверки с ПК из панели (check_panel): задача с отчётом остановила мишени
check_probe_after() {
  local n got
  for n in "${PROBE_PY[@]}"; do
    got="$(probe_left "$n")"
    if [[ "$got" == "0 0 0" ]]; then ok "панель: после отчёта мишени на $n остановлены"; else fail "панель: после отчёта на $n осталось «$got»"; fi
  done
}

# Панель на управляющем сервере: страницы и API, защита от DNS rebinding и CSRF, задача iof
# из панели (создать и удалить группу ссылок), терминал на каждый узел через WebSocket.
# Проверяет python3 на сервере, он там есть для панели
check_panel() {
  local out rc line
  out="$(on_in "$M" python3 - "$PANEL_GROUP" "${NAMES[*]}" "${PROBE_PY[*]}" 2>&1 <<'PY'
import base64, json, os, re, socket, struct, sys, time, urllib.error, urllib.request

BASE = "http://127.0.0.1:8088"
label, nodes = sys.argv[1], set(sys.argv[2].split())
probe_nodes = sys.argv[3].split() if len(sys.argv) > 3 else []
POST = {"X-IOF-Request": "1", "Content-Type": "application/json", "Origin": BASE}


def req(path, method="GET", body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(r, timeout=200) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def report(good, text):
    print(("ok" if good else "fail") + "\t" + text, flush=True)


def job(body, title, path="/api/hy2"):
    code, resp = req(path, "POST", body, POST)
    if code != 202:
        report(False, f"{title}: ответ {code} {resp.decode('utf-8', 'replace')[:200]}")
        return None
    data = json.loads(resp)
    wait_job(lambda j: j["id"] == data["job"], title)
    return data


# Ждёт первую задачу, подходящую под match, и отчитывается, как она закончилась
def wait_job(match, title):
    deadline = time.time() + 300
    while time.time() < deadline:
        j = next((j for j in json.loads(req("/api/jobs")[1])["jobs"] if match(j)), None)
        if j and j["state"] != "running":
            report(j["state"] == "ok", f"{title}: задача завершилась ({j['state']})")
            if j["state"] != "ok":
                print("\n".join("      " + line for line in j["log"][-10:]))
            return j
        time.sleep(1)
    report(False, f"{title}: задача не завершилась за 5 минут")
    return None


def group(data):
    return next((g for g in data.get("groups", []) if g["label"] == label), None)


def ws_open(path, origin=BASE):
    """Рукопожатие WebSocket с панелью: (сокет, код ответа). Заголовки читаются по байту,
    чтобы не съесть первый кадр."""
    s = socket.create_connection(("127.0.0.1", 8088), timeout=20)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:8088\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nOrigin: {origin}\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        c = s.recv(1)
        if not c:
            break
        head += c
    parts = head.split(b" ", 2)
    return s, int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0


def ws_send(s, opcode, data):
    # От клиента кадры только с маской
    mask, n = os.urandom(4), len(data)
    head = bytes([0x80 | opcode]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n))
    s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def ws_recv(s):
    def exact(n):
        buf = b""
        while len(buf) < n:
            c = s.recv(n - len(buf))
            if not c:
                raise EOFError
            buf += c
        return buf
    b1, b2 = exact(2)
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack(">H", exact(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", exact(8))[0]
    return b1 & 0x0F, exact(n)


def ticket(node):
    code, resp = req("/api/term", "POST", {"name": node, "cols": 100, "rows": 30}, POST)
    if code != 200:
        report(False, f"терминал {node}: билет не выдан ({code} {resp.decode('utf-8', 'replace')[:200]})")
        return None
    return json.loads(resp)["ticket"]


# Терминал на узел: размер окна при открытии и после resize доходит до оболочки, команда выполняется,
# по exit приходит код выхода. В выводе ищется 42, а не набранное $((6*7)): так эхо ввода не засчитается
def terminal(node):
    t = ticket(node)
    if t is None:
        return
    s, code = ws_open(f"/api/term/ws?t={t}")
    if code != 101:
        report(False, f"терминал {node}: WebSocket не открылся ({code})")
        return
    out, exit_msg = b"", None
    try:
        ws_send(s, 2, b"stty size\r")
        time.sleep(1.5)
        ws_send(s, 1, json.dumps({"type": "resize", "cols": 120, "rows": 40}).encode())
        time.sleep(1.5)
        ws_send(s, 2, b"stty size; echo iof-term-$((6*7)); exit\r")
        deadline = time.time() + 30
        while time.time() < deadline:
            op, data = ws_recv(s)
            if op == 2:
                out += data
            elif op == 1:
                exit_msg = json.loads(data)
            elif op == 8:
                break
    except (EOFError, OSError):
        pass
    s.close()
    text = out.decode("utf-8", "replace")
    good = "30 100" in text and "40 120" in text and "iof-term-42" in text and exit_msg == {"type": "exit", "code": 0}
    report(good, f"терминал {node}: команда выполнилась, размер окна дошёл, выход {exit_msg}")
    if not good:
        print("\n".join("      " + line for line in text.replace("\r", "").splitlines()[-10:]))
    # По тому же билету второй раз не войти
    s, code = ws_open(f"/api/term/ws?t={t}")
    s.close()
    report(code == 403, f"терминал {node}: повторный вход по билету отклонён ({code})")


code, body = req("/")
report(code == 200 and b"</html>" in body, f"панель: GET / ({code})")
code, body = req("/app.css")
report(code == 200, f"панель: GET /app.css ({code})")

code, body = req("/api/dashboard?force=1")
data = json.loads(body) if code == 200 else {}
got = {n["name"] for n in data.get("nodes", [])}
bad = sorted(n["name"] for n in data.get("nodes", []) if not n["ok"])
report(code == 200 and not data.get("status_error") and got == nodes and not bad,
       f"панель: /api/dashboard ({code}), узлы: {' '.join(sorted(got)) or 'нет'}"
       + (f", с проблемами: {' '.join(bad)}" if bad else "")
       + (f", ошибка: {data['status_error']}" if data.get("status_error") else ""))

code, _ = req("/api/dashboard", headers={"Host": "evil.example"})
report(code == 403, f"панель: чужой Host отклонён ({code}, защита от DNS rebinding)")
code, _ = req("/api/hy2", "POST", {"action": "refresh"}, {"Content-Type": "application/json"})
report(code == 403, f"панель: POST без X-IOF-Request отклонён ({code}, защита от CSRF)")
code, _ = req("/api/hy2", "POST", {"action": "refresh"}, dict(POST, Origin="http://evil.example"))
report(code == 403, f"панель: POST с чужим Origin отклонён ({code})")

job({"action": "add", "label": label}, f"панель: создать группу «{label}»")
code, body = req("/api/hy2")
g = group(json.loads(body)) if code == 200 else None
links = [link for link in g["links"] if not link["relay"]] if g else []
report(g is not None and len(links) == len(nodes),
       f"панель: в группе «{label}» ссылок на узлы: {len(links)}")
if g:
    job({"action": "del", "name": g["name"]}, f"панель: удалить группу «{label}»")
    code, body = req("/api/hy2")
    report(code == 200 and group(json.loads(body)) is None, f"панель: группы «{label}» больше нет")

# Страница «Безопасность»: результаты аудита по всем узлам, проверка одного узла задачей панели
code, body = req("/api/security")
sec = json.loads(body) if code == 200 else {}
checked = set(sec.get("blocks", {}).get("server", {}).get("nodes", {}))
report(code == 200 and not sec.get("error") and checked == nodes and len(sec.get("catalog", [])) >= 15,
       f"панель: /api/security ({code}), проверены узлы: {' '.join(sorted(checked)) or 'нет'}"
       + (f", ошибка: {sec['error']}" if sec.get("error") else ""))
dpi = sec.get("blocks", {}).get("dpi", {}).get("nodes", {})
ids = {c["id"] for c in sec.get("catalog", []) if c["block"] == "dpi"}
done = {n for n, v in dpi.items() if v.get("reachable") and {c["id"] for c in v["checks"]} == ids}
report(done == nodes and len(ids) >= 20,
       f"панель: блок dpi в /api/security, проверок в справочнике: {len(ids)}, узлы со всеми оценками: {' '.join(sorted(done)) or 'нет'}")
code, _ = req("/api/security", "POST", {"block": "нет-такого", "node": ""}, POST)
report(code == 400, f"панель: проверка неизвестного блока отклонена ({code})")
code, _ = req("/api/security", "POST", {"block": "server", "node": "нет-такого"}, POST)
report(code == 400, f"панель: проверка неизвестного узла отклонена ({code})")
one = sorted(nodes)[0]
before = sec.get("blocks", {}).get("server", {}).get("nodes", {}).get(one, {}).get("at", 0)
time.sleep(1)
job({"block": "server", "node": one}, f"панель: аудит узла {one}", "/api/security")
code, body = req("/api/security")
after = json.loads(body)["blocks"]["server"]["nodes"].get(one, {}) if code == 200 else {}
report(after.get("reachable") is True and after.get("at", 0) > before, f"панель: результат аудита {one} обновился")
before = dpi.get(one, {}).get("at", 0)
job({"block": "dpi", "node": one}, f"панель: проверка блока dpi на {one}", "/api/security")
code, body = req("/api/security")
after = json.loads(body)["blocks"]["dpi"]["nodes"].get(one, {}) if code == 200 else {}
report(after.get("reachable") is True and after.get("at", 0) > before, f"панель: результат блока dpi на {one} обновился")

# Проверка с ПК из панели: мишени задачей, скрипт по одноразовому билету с данными проверки, отчёт
# по тому же билету, задача остановки мишеней и импорта. Чужой и повторный билет отклоняются,
# токена мишеней нет в ответах панели и логах задач. Функция, чтобы имена не затёрли ticket() терминала
def probe_panel(one):
    started = job({"action": "start", "nodes": [one], "origin": BASE}, f"панель: мишень проверки с ПК на {one}", "/api/probe")
    ticket = (started or {}).get("ticket") or ""
    try:
        token = open("/root/iof/audit/probe/token", encoding="utf-8").read().strip()
    except OSError:
        token = ""
    code, body = req("/api/probe")
    st = json.loads(body) if code == 200 else {}
    panel = st.get("panel") or {}
    report(bool(ticket) and panel.get("ticket") == ticket and (st.get("session") or {}).get("nodes", {}).get(one, {}).get("state") == "started",
           f"панель: /api/probe — сессия с мишенью на {one}, билет для ПК")
    leaks = [p for p in ("/api/probe", "/api/security", "/api/jobs") if token and token in req(p)[1].decode("utf-8", "replace")]
    report(bool(token) and not leaks, "панель: токена мишеней нет в /api/probe, /api/security и логах задач" + (f" (есть в {', '.join(leaks)})" if leaks else ""))
    code, _ = req("/api/probe/script?t=wrong")
    report(code == 403, f"панель: скрипт по неверному билету не выдан ({code})")
    code, _ = req(f"/api/probe/script?t={ticket}", headers={"Host": "evil.example"})
    report(code == 403, f"панель: скрипт с чужим Host не выдан ({code})")
    code, body = req(f"/api/probe/script?t={ticket}")
    m = re.search(r"\$IofProbeConfig = '([A-Za-z0-9+/=]+)'", body.decode("utf-8", "replace")) if code == 200 else None
    cfg = json.loads(base64.b64decode(m.group(1))) if m else {}
    report(code == 200 and cfg.get("ticket") == ticket and cfg.get("token") == token
           and [t["node"] for t in cfg.get("targets", [])] == [one],
           f"панель: скрипт для ПК выдан с мишенью {one} и билетом ({code})")
    code, _ = req(f"/api/probe/script?t={ticket}")
    report(code == 403, f"панель: второй раз скрипт по тому же билету не выдан ({code})")
    ok_conn = {"tcp": 2, "tls": 3, "fp": "match", "bytes": 262144, "ms": 50, "src": "172.30.0.99", "err": ""}
    rep = {"v": 1, "session": cfg.get("session", ""), "remap": True, "client": {"os": "Windows 10.0", "vpn": [], "proxy": "none"},
           "lists": [], "targets": [{"node": t["node"], "icmp": {"sent": 3, "got": 3, "ms": 40}, "conn": [ok_conn] * 3,
                                     "udp": {"sent": 5, "got": 5, "closed": False}, "quic": {"sent": 5, "got": 5, "closed": False},
                                     "hy2": "vn" if t.get("hy2") else "", "tunnel": {"tested": False, "reason": "nohysteria"}}
                                    for t in cfg.get("targets", [])]}
    code, _ = req("/api/probe/result?t=wrong", "POST", rep, POST)
    report(code == 403, f"панель: отчёт по неверному билету отклонён ({code})")
    code, _ = req(f"/api/probe/result?t={ticket}", "POST", rep, {"Content-Type": "application/json"})
    report(code == 403, f"панель: отчёт без X-IOF-Request отклонён ({code})")
    # Как PowerShell: без Origin и без пароля панели
    code, _ = req(f"/api/probe/result?t={ticket}", "POST", rep, {"Content-Type": "application/json", "X-IOF-Request": "1"})
    report(code == 202, f"панель: отчёт с ПК принят ({code})")
    wait_job(lambda j: j["kind"] == "probe" and "результат" in j["title"] and j["started"] > time.time() - 120,
             "панель: остановка мишеней и приём отчёта")
    code, body = req("/api/security")
    last = (json.loads(body).get("probe") or {}).get("last") or {} if code == 200 else {}
    report(last.get("session") == cfg.get("session") and last.get("nodes", {}).get(one, {}).get("status") == "good",
           f"панель: результат проверки с ПК — {one} доступен")
    code, _ = req(f"/api/probe/result?t={ticket}", "POST", rep, {"Content-Type": "application/json", "X-IOF-Request": "1"})
    report(code == 403, f"панель: второй отчёт по тому же билету отклонён ({code})")


if probe_nodes:
    probe_panel(probe_nodes[0])

# Терминал: stand.sh setup включает его в web.env (IOF_WEB_TERMINAL=1)
for node in sorted(nodes):
    terminal(node)
code, _ = req("/api/term", "POST", {"name": "нет-такого", "cols": 80, "rows": 24}, POST)
report(code == 400, f"терминал: билет на неизвестный узел не выдан ({code})")
s, code = ws_open("/api/term/ws?t=wrong")
s.close()
report(code == 403, f"терминал: WebSocket с неверным билетом отклонён ({code})")
t = ticket(sorted(nodes)[0])
if t:
    s, code = ws_open(f"/api/term/ws?t={t}", origin="http://evil.example")
    s.close()
    report(code == 403, f"терминал: WebSocket с чужим Origin отклонён ({code})")
PY
)"
  rc=$?
  tally "$out"
  if (( rc != 0 )); then fail "проверка панели завершилась с кодом $rc"; fi
}

if ! on "$M" test -x /usr/local/bin/iof 2>/dev/null; then
  echo "Ошибка: на $M нет iof. Сначала: bash stand/stand.sh up && bash stand/stand.sh setup" >&2
  exit 1
fi
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '### Проверка на стенде (управляющий сервер %s)\n\n| Итог | Проверка |\n|---|---|\n' "$M" >> "$GITHUB_STEP_SUMMARY"
fi

step "Узлы"
check_nodes
if (( ${#NAMES[@]} == 0 )); then exit 1; fi
step "Команды на узлах"
check_exec
check_check
step "Hysteria2: группа ссылок и туннели"
check_hy2
step "Ретранслятор"
check_relay
check_hy2_del
check_restart
step "Смена портов Hysteria2"
check_hop
step "Аудит безопасности"
check_audit
step "Защита от РКН"
check_dpi
step "Блок-лист сканеров"
check_block
step "Действия во время переноса"
check_guard
step "Телеграм-бот"
check_bot
step "Проверка с ПК"
check_probe
step "Веб-панель"
check_panel
check_probe_after
step "Узлы после проверки"
check_nodes

echo
echo "Проверок: $((PASSED + FAILED)), успешно: $PASSED, с ошибкой: $FAILED"
(( FAILED == 0 ))
