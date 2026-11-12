#!/usr/bin/env bash

# Проверка iof на поднятом стенде, её же запускает CI на каждый push. Управляющий сервер видит
# узлы и выполняет на них команды, ссылки Hysteria2 из iof работают с другого сервера, ретранслятор
# пересылает трафик, аудит безопасности видит изменения на узле (в том числе расхождение конфига
# Hysteria2 с шаблоном в блоке dpi), мишени проверки с ПК отвечают только с токеном, готовый отчёт
# даёт ожидаемые оценки, мишени исчезают по сроку; панель отвечает, отбивает чужие
# запросы, выполняет задачи, выдаёт скрипт для ПК по билету и открывает терминал на каждый узел
# (stand.sh setup включает его в web.env). Созданные группы ссылок и ретранслятор удаляются,
# изменения на узле для аудита и проверки с ПК откатываются, стенд остаётся как был.
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
export MSYS_NO_PATHCONV=1

PASSED=0
FAILED=0
GROUP_LEFT=0
RELAY_LEFT=""
AUDIT_LEFT=""
PROBE_LEFT=0        # 1 — могли остаться мишени проверки с ПК
PROBE_FW_LEFT=""    # узел, где для проверки с ПК запрещены входящие
PROBE_PY=()         # узлы с python3: на них поднимаются мишени
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
        if kind == "vpn":
            for c in t["conn"]:
                c["src"] = s["nodes"][first]["ip"]
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
step "Аудит безопасности"
check_audit
step "Защита от РКН"
check_dpi
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
