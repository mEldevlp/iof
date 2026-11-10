#!/usr/bin/env bash

# Проверка iof на поднятом стенде, её же запускает CI на каждый push. Управляющий сервер видит
# узлы и выполняет на них команды, ссылки Hysteria2 из iof работают с другого сервера, ретранслятор
# пересылает трафик, аудит безопасности видит изменения на узле (в том числе расхождение конфига
# Hysteria2 с шаблоном в блоке dpi), панель отвечает, отбивает чужие
# запросы, выполняет задачи и открывает терминал на каждый узел (stand.sh setup включает его
# в web.env). Созданные группы ссылок и ретранслятор удаляются, изменения на узле для аудита
# откатываются, стенд остаётся как был.
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

# Панель на управляющем сервере: страницы и API, защита от DNS rebinding и CSRF, задача iof
# из панели (создать и удалить группу ссылок), терминал на каждый узел через WebSocket.
# Проверяет python3 на сервере, он там есть для панели
check_panel() {
  local out rc line
  out="$(on_in "$M" python3 - "$PANEL_GROUP" "${NAMES[*]}" 2>&1 <<'PY'
import base64, json, os, socket, struct, sys, time, urllib.error, urllib.request

BASE = "http://127.0.0.1:8088"
label, nodes = sys.argv[1], set(sys.argv[2].split())
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
        return
    jid = json.loads(resp)["job"]
    deadline = time.time() + 300
    while time.time() < deadline:
        j = next((j for j in json.loads(req("/api/jobs")[1])["jobs"] if j["id"] == jid), None)
        if j and j["state"] != "running":
            report(j["state"] == "ok", f"{title}: задача завершилась ({j['state']})")
            if j["state"] != "ok":
                print("\n".join("      " + line for line in j["log"][-10:]))
            return
        time.sleep(1)
    report(False, f"{title}: задача не завершилась за 5 минут")


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
  while IFS= read -r line; do
    case "$line" in
      ok$'\t'*)   ok "${line#ok$'\t'}" ;;
      fail$'\t'*) fail "${line#fail$'\t'}" ;;
      *)          echo "$line" | mask ;;
    esac
  done <<<"$out"
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
step "Веб-панель"
check_panel
step "Узлы после проверки"
check_nodes

echo
echo "Проверок: $((PASSED + FAILED)), успешно: $PASSED, с ошибкой: $FAILED"
(( FAILED == 0 ))
