#!/usr/bin/env bash

# Блок-лист сканеров: iof block on <узлы|all> | update [узлы] | off <узлы|all>.
# Список — BLOCKLIST_URL, его же смотрит iof audit (кэш $AUDIT_DIR/cache, скачивается не чаще раза
# в сутки). Здесь он чистится: только IPv4, без частных и служебных сетей и без записей шире
# /$BLOCK_MIN_PREFIX, чтобы ошибка в списке не отрезала клиентов. Узлы из nodes.conf, адреса
# управляющего сервера и BLOCK_ALLOW уходят на узлы списком, который не блокируется никогда.
# Применяет список на узле n_block_apply

# IPv4-адреса имени или адреса $1, по строке
block_resolve() {
  if [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then echo "$1"; return 0; fi
  getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1 }' | sort -u || true
}

# Адреса, которые блок-лист не блокирует, через пробел: адреса узлов для клиентов и для SSH,
# адреса этого сервера и BLOCK_ALLOW. Узел добавит к ним свои адреса и собеседников сессий SSH
block_allow() {
  local i h out=()
  for i in "${!N_NAME[@]}"; do
    out+=("${N_ADDR[$i]}")
    if [[ "${N_SSH[$i]}" != "local" ]]; then
      split_target "${N_SSH[$i]}"
      out+=("${T_HOST#*@}")
    fi
  done
  {
    for h in "${out[@]}"; do block_resolve "$h"; done
    hostname -I 2>/dev/null | tr ' ' '\n'
    tr ' ,' '\n\n' <<<"$BLOCK_ALLOW"
  } | grep -xE '[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?' | sort -u | paste -sd' ' - || true
}

BLOCK_ACT=""; BLOCK_B64=""; BLOCK_ALLOWED=""; BLOCK_AT=""
block_job() { run_on "${N_SSH[$1]}" n_block_apply "$BLOCK_ACT" "$BLOCK_B64" "$BLOCK_ALLOWED" "$BLOCK_AT"; }

# Готовит список для узлов: BLOCK_B64 (gzip и base64), BLOCK_AT (когда скачан), BLOCK_ALLOWED.
# Печатает, сколько записей пропущено и почему
block_prepare() {
  local f="$AUDIT_DIR/cache/blocklist.txt" out stats n v6 wide special junk hit
  have python3 || die "для блок-листа нужен python3: apt install python3"
  [[ -n "$BLOCKLIST_URL" ]] || die "не задан BLOCKLIST_URL в $ENV_FILE: адрес списка, по IP или CIDR в строке, # — комментарий"
  mkdir -p "$AUDIT_DIR/cache"
  chmod 700 "$AUDIT_DIR" "$AUDIT_DIR/cache"
  audit_fetch blocklist "$BLOCKLIST_URL"
  [[ -s "$f" ]] || die "список не скачался ($(cat "$f.err" 2>/dev/null || echo 'нет копии')): проверь BLOCKLIST_URL, curl -fsSL \"\$BLOCKLIST_URL\" | head"
  if [[ -f "$f.err" ]]; then
    echo "Внимание: список не скачался ($(cat "$f.err")), на узлы идёт прошлая копия от $(audit_when "$(stat -c %Y "$f")")"
  fi
  BLOCK_AT="$(stat -c %Y "$f")"
  BLOCK_ALLOWED="$(block_allow)"
  # shellcheck disable=SC2086 # адреса через пробел — отдельные аргументы
  out="$(python3 -c "$AUDIT_NET_PY" blocklist "$f" "$BLOCK_MIN_PREFIX" $BLOCK_ALLOWED)" || die "не удалось разобрать список $f"
  stats="$(head -n 1 <<<"$out")"
  read -r _ n v6 wide special junk hit <<<"$stats"
  [[ "$stats" =~ ^S( [0-9]+){6}$ ]] || die "не удалось разобрать список $f"
  (( n > 0 )) || die "в списке нет ни одной записи, которую можно применить (пропущено: IPv6 $v6, шире /$BLOCK_MIN_PREFIX $wide, частных и служебных $special, нечитаемых $junk)"
  (( n <= 262144 )) || die "в списке $n записей, это слишком много для узлов (до 262144)"
  BLOCK_B64="$(tail -n +2 <<<"$out" | gzip -9c | base64 -w0)"
  echo "Список: записей $n, скачан $(audit_when "$BLOCK_AT")"
  if (( v6 + wide + special + junk > 0 )); then
    echo "  пропущено: IPv6 $v6, шире /$BLOCK_MIN_PREFIX $wide, частных и служебных $special, нечитаемых $junk"
  fi
  if (( hit > 0 )); then
    echo "  записей, в которые попадают узлы, этот сервер или BLOCK_ALLOW: $hit (эти адреса блокироваться не будут)"
  fi
}

# Применить (on), обновить там, где включён (update), или снять (off) на выбранных узлах
block_apply() {
  local act="$1" i out st items=() same=() skip=() failed=()
  shift
  read_nodes
  select_nodes "$@"
  BLOCK_ACT="$act"
  BLOCK_B64=""; BLOCK_ALLOWED=""; BLOCK_AT=""
  if [[ "$act" != "off" ]]; then
    if [[ "$act" == "update" && -z "$BLOCKLIST_URL" ]]; then
      echo "BLOCKLIST_URL не задан, обновлять нечего"
      return 0
    fi
    block_prepare
  fi
  case "$act" in
    on)     echo "Применяю на узлах: ${#SEL[@]}" ;;
    update) echo "Обновляю там, где список включён, проверяю узлов: ${#SEL[@]}" ;;
    off)    echo "Снимаю на узлах: ${#SEL[@]}" ;;
  esac
  pmap block_job "${SEL[@]}"
  for i in "${SEL[@]}"; do
    out="$(pm_out "$i")"
    st="$(kv_get "$out" block)"
    if ! pm_ok "$i" || [[ -z "$st" ]]; then failed+=("$i"); continue; fi
    case "$st" in
      on)   items+=("${N_NAME[$i]}: записей $(kv_get "$out" entries), не блокируются $(kv_get "$out" allow)") ;;
      same) same+=("${N_NAME[$i]}") ;;
      skip) skip+=("${N_NAME[$i]}") ;;
      off)  items+=("${N_NAME[$i]}: снят") ;;
    esac
  done
  echo
  for out in "${items[@]}"; do echo "  $out"; done
  if (( ${#same[@]} > 0 )); then echo "Список тот же, не менялся (${#same[@]}): ${same[*]}"; fi
  if (( ${#skip[@]} > 0 )); then echo "Блок-лист не включён, не трогал (${#skip[@]}): ${skip[*]}"; fi
  if (( ${#failed[@]} > 0 )); then
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
  fi
  if [[ "$act" == "on" ]] && ! crontab -l -u root 2>/dev/null | grep -q 'iof block update'; then
    echo
    echo "Обновлять раз в сутки: sudo crontab -e, строка: 15 5 * * * /usr/local/bin/iof block update >/dev/null 2>&1"
  fi
  if (( ${#failed[@]} > 0 )); then return 1; fi
}

cmd_block() {
  local action="${1:-}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    on|off)
      (( $# > 0 )) || die "укажи узлы: iof block $action node-1   или   iof block $action all"
      block_apply "$action" "$@" ;;
    update) block_apply update "$@" ;;
    *)      die "используй: iof block on <узлы|all> | update [узлы] | off <узлы|all>" ;;
  esac
}
