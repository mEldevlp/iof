#!/usr/bin/env bash

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
