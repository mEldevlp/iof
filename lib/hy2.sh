#!/usr/bin/env bash

# Hysteria2: iof hy2 ...
# Группа ссылок = один файл $HY2_DIR/<логин>.txt со ссылками на все узлы и ретрансляторы.

hy2_add_job() {
  local i="$1" remark="$HY2_ADD_LABEL"
  if [[ -n "${N_TITLE[$i]}" ]]; then remark="$HY2_ADD_LABEL | ${N_TITLE[$i]}"; fi
  run_on "${N_SSH[$i]}" n_hy2_add "$HY2_ADD_NAME" "$HY2_ADD_PASS" "$remark" "${N_ADDR[$i]}" "$HY2_ADD_HOP"
}

hy2_del_job() { run_on "${N_SSH[$1]}" n_hy2_del "$HY2_DEL_NAME"; }

# Метка группы со сменой портов в ссылках: $HY2_DIR/<логин>.hop. У такой группы порт узла со сменой
# портов в ссылке — список «443,10000-19999». Его понимают Hiddify с 5.5.5 и официальный клиент,
# а v2rayN и Hiddify старше такую ссылку не импортируют, поэтому у новых групп метки нет
hy2_hop_mark() { printf '%s/%s.hop' "$HY2_DIR" "$1"; }

# Сколько групп со сменой портов в ссылках, строкой для аудита
hop_groups_line() {
  local n=0 t=0 name _l _c
  if [[ -f "$HY2_INDEX" ]]; then
    while IFS=$'\t' read -r name _l _c; do
      t=$((t + 1))
      if [[ -f "$(hy2_hop_mark "$name")" ]]; then n=$((n + 1)); fi
    done < "$HY2_INDEX"
  fi
  printf 'Групп ссылок со списком портов: %s из %s (sudo iof hy2 add "Подпись" --hop)' "$n" "$t"
}

# Создаёт или пересобирает группу ссылок. Повторный запуск с той же подписью безопасен.
# --hop включает смену портов в ссылках группы, --no-hop выключает, без них остаётся как было
hy2_add() {
  local label="" a hop=""
  for a in "$@"; do
    case "$a" in
      --hop)    hop=1 ;;
      --no-hop) hop=0 ;;
      *)        if [[ -z "$label" ]]; then label="$a"; else die "лишний аргумент: $a"; fi ;;
    esac
  done
  [[ -n "$label" ]] || die "укажи подпись: iof hy2 add \"Подпись\""
  # | разделяет подпись и узел в названии ссылки, табуляция — поля index.tsv
  title_ok "$label" && [[ "$label" != *$'\t'* ]] || die "подпись не может содержать |, табуляцию и перевод строки"
  read_nodes
  mkdir -p "$HY2_DIR"
  chmod 700 "$HY2_DIR"

  local name out tmp i link ok=0 r ni vi rl multi
  local node_link=() failed=()
  name="$(name_for "$label")"
  if [[ -z "$hop" ]]; then
    hop=0
    if [[ -f "$(hy2_hop_mark "$name")" ]]; then hop=1; fi
  fi
  HY2_ADD_NAME="$name"
  HY2_ADD_PASS="$(gen_pass)"
  HY2_ADD_LABEL="$label"
  HY2_ADD_HOP="$hop"
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
  if (( hop )); then
    : > "$(hy2_hop_mark "$name")"
    chmod 600 "$(hy2_hop_mark "$name")"
  else
    rm -f "$(hy2_hop_mark "$name")"
  fi

  echo
  echo "Подпись: $label"
  echo "Файл:    $out"
  echo
  cat "$out"
  echo
  echo "Скопируй строки выше и добавь в Hiddify из буфера обмена."
  if (( hop )); then
    multi="$(grep -cE '^hy2://[^@]*@[^/?#]*:[0-9]+,' "$out" || true)"
    echo
    echo "Смена портов в ссылках группы включена, со списком портов ссылок: $multi."
    echo "Такие ссылки импортируют Hiddify с версии 5.5.5 и официальный клиент Hysteria2, а v2rayN"
    echo "и Hiddify старше — нет. Вернуть обычные ссылки: sudo iof hy2 add \"$label\" --no-hop"
    if (( multi == 0 )); then echo "На узлах смена портов не включена: sudo iof hy2 hop on <узел>"; fi
  fi
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
  rm -f "$HY2_DIR/$name.txt" "$(hy2_hop_mark "$name")"
  if [[ -f "$HY2_INDEX" ]]; then index_set "$HY2_INDEX" "$name"; fi
}

hy2_list() {
  if [[ ! -s "$HY2_INDEX" ]]; then
    echo "Групп ссылок Hysteria2 пока нет"
    return 0
  fi
  {
    row "ЛОГИН" "ПОДПИСЬ" "СОЗДАН" "СМЕНА ПОРТОВ" "ФАЙЛ"
    local name label created hop
    while IFS=$'\t' read -r name label created; do
      hop="нет"
      if [[ -f "$(hy2_hop_mark "$name")" ]]; then hop="в ссылках"; fi
      row "$name" "$label" "$created" "$hop" "$HY2_DIR/$name.txt"
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

# Версия $1 не ниже $2 (2.13.0 и 2.12.3)
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]; }

# Диапазон a-b для смены портов: порты от 1024 до 65535, не меньше 10 портов
hop_range_ok() {
  [[ "$1" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
  local lo=$((10#${BASH_REMATCH[1]})) hi=$((10#${BASH_REMATCH[2]}))
  (( lo >= 1024 && hi <= 65535 && hi - lo >= 9 ))
}

# Пересекаются ли «порт или a-b» $1 и $2
ports_overlap() {
  local a="$1" b="$2"
  [[ "$a" == *-* ]] || a="$a-$a"
  [[ "$b" == *-* ]] || b="$b-$b"
  (( 10#${a%-*} <= 10#${b#*-} && 10#${b%-*} <= 10#${a#*-} ))
}

# Порты ретрансляторов на узле $1 через запятую: у них нет сокета, а пакеты на них уходят через DNAT
hop_busy() {
  local r out=()
  for r in "${!R_NODE[@]}"; do
    [[ "${R_VIA[$r]}" == "$1" ]] || continue
    if [[ "${R_HYL[$r]}" != "-" ]]; then out+=("${R_HYL[$r]}"); fi
    if [[ "${R_AWL[$r]}" != "-" ]]; then out+=("${R_AWL[$r]}"); fi
  done
  local IFS=,
  printf '%s' "${out[*]}"
}

hy2_hop_job() { run_on "${N_SSH[$1]}" n_hy2_hop "$HOP_ACT" "$HOP_RANGE" "$(hop_busy "${N_NAME[$1]}")" "$HY2_HOP_MIN"; }

# Смена портов Hysteria2 (port hopping) на узлах: iof hy2 hop on|off <узлы|all> [--ports a-b].
# on дописывает диапазон (HY2_HOP или --ports) в listen: основной порт остаётся, выданные ссылки работают
# как раньше. Диапазон в ссылках получают только группы с меткой --hop, они пересобираются здесь же.
# off оставляет основной порт. Код 1, если на каком-то узле не получилось (там всё осталось как было)
hy2_hop() {
  local act="${1:-}" range="$HY2_HOP" i out port rng was groups=() done_on=() done_off=() same=() failed=() args=()
  local name label created l
  if [[ $# -gt 0 ]]; then shift; fi
  [[ "$act" == "on" || "$act" == "off" ]] || die "используй: iof hy2 hop on <узлы|all> [--ports 10000-19999]   или   iof hy2 hop off <узлы|all>"
  while (( $# > 0 )); do
    if [[ "$1" == "--ports" ]]; then
      range="${2:-}"
      shift
      if [[ $# -gt 0 ]]; then shift; fi
    else
      args+=("$1")
      shift
    fi
  done
  (( ${#args[@]} > 0 )) || die "укажи узлы: iof hy2 hop $act node-1   или   iof hy2 hop $act all"
  if [[ "$act" == "on" ]]; then
    hop_range_ok "$range" || die "диапазон '$range': нужен вид 10000-19999, порты от 1024 до 65535, не меньше 10 портов (HY2_HOP в $ENV_FILE или --ports)"
    if [[ -n "$PROBE_PORTS" ]] && ports_overlap "$PROBE_PORTS" "$range"; then
      die "PROBE_PORTS ($PROBE_PORTS) пересекается с диапазоном $range: мишени проверки с ПК не поднимутся. Выбери другой диапазон: --ports a-b"
    fi
  fi
  read_nodes
  read_relays
  select_nodes "${args[@]}"
  HOP_ACT="$act"
  HOP_RANGE="$range"
  if [[ "$act" == "on" ]]; then
    echo "Включаю смену портов $range на узлах: ${#SEL[@]}"
  else
    echo "Выключаю смену портов на узлах: ${#SEL[@]}"
  fi
  pmap hy2_hop_job "${SEL[@]}"
  for i in "${SEL[@]}"; do
    out="$(pm_out "$i")"
    if ! pm_ok "$i" || ! grep -q '^hop=' <<<"$out"; then failed+=("$i"); continue; fi
    port="$(kv_get "$out" port)"
    rng="$(kv_get "$out" range)"
    was="$(kv_get "$out" was)"
    if [[ "$was" == "same" ]]; then same+=("${N_NAME[$i]}")
    elif [[ "$act" == "on" && "$(kv_get "$out" backend)" == "iptables" ]]; then
      done_on+=("${N_NAME[$i]}: порты $rng -> $port (правила через iptables: с nftables служба не поднялась)")
    elif [[ "$act" == "on" ]]; then done_on+=("${N_NAME[$i]}: порты $rng -> $port")
    else done_off+=("${N_NAME[$i]}: остался порт $port"); fi
  done

  echo
  for l in "${done_on[@]}"; do echo "Включено  $l"; done
  for l in "${done_off[@]}"; do echo "Выключено $l"; done
  if (( ${#same[@]} > 0 )); then echo "Уже было так (${#same[@]}): ${same[*]}"; fi
  if (( ${#failed[@]} > 0 )); then
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
  fi

  # Ссылки меняются только у групп со сменой портов в ссылках
  if (( ${#done_on[@]} + ${#done_off[@]} > 0 )) && [[ -s "$HY2_INDEX" ]]; then
    while IFS=$'\t' read -r name label created; do
      if [[ -f "$(hy2_hop_mark "$name")" ]]; then groups+=("$label"); fi
    done < "$HY2_INDEX"
    echo
    if (( ${#groups[@]} > 0 )); then
      for l in "${groups[@]}"; do
        echo "Пересобираю группу со сменой портов в ссылках: $l"
        ( trap pm_cleanup EXIT; hy2_add "$l" >/dev/null ) || echo "Не удалось обновить: $l"
      done
      if (( ${#done_off[@]} > 0 )); then
        echo "Клиентам этих групп нужны новые ссылки: в старых диапазон, а его порты на этих узлах закрыты."
      fi
    else
      echo "Ссылки групп не менялись: в них по-прежнему основной порт. Смену портов в ссылках группы включает"
      echo "  sudo iof hy2 add \"Подпись\" --hop   (её импортируют Hiddify с 5.5.5 и официальный клиент, v2rayN — нет)"
    fi
  fi
  if (( ${#done_on[@]} > 0 )); then
    echo
    echo "Если у хостера свой файрвол в панели, открой там UDP $range. Файрвол самого узла трогать не нужно:"
    echo "Hysteria2 перенаправляет диапазон на основной порт раньше, чем пакет до него дойдёт."
  fi
  if (( ${#failed[@]} > 0 )); then return 1; fi
}

hy2_upgrade_job() { run_on "${N_SSH[$1]}" n_hy2_upgrade; }

# Обновление Hysteria2 на узлах официальным установщиком: iof hy2 upgrade <узлы|all>. Бинарник и юнит
# сохраняются на узле в /var/backups/iof-hy2, если служба после обновления не работает, возвращаются.
# Код 1, если где-то не получилось
hy2_upgrade() {
  local i out a b up=() same=() failed=()
  (( $# > 0 )) || die "укажи узлы: iof hy2 upgrade node-1   или   iof hy2 upgrade all"
  read_nodes
  select_nodes "$@"
  echo "Обновляю Hysteria2 на узлах: ${#SEL[@]}, одновременно до $PARALLEL"
  pmap hy2_upgrade_job "${SEL[@]}"
  for i in "${SEL[@]}"; do
    out="$(pm_out "$i" | tail -n 1)"
    if pm_ok "$i" && [[ "$out" == upgraded* ]]; then
      read -r _ a b <<<"$out"
      up+=("${N_NAME[$i]}: $a -> $b")
    elif pm_ok "$i" && [[ "$out" == same* ]]; then
      same+=("${N_NAME[$i]} (${out#same })")
    else
      failed+=("$i")
    fi
  done
  echo
  echo "Обновлено: ${#up[@]}"
  for out in "${up[@]}"; do echo "  $out"; done
  if (( ${#same[@]} > 0 )); then echo "Уже последняя версия (${#same[@]}): ${same[*]}"; fi
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
  rows+=("$(row "УЗЕЛ" "АДРЕС" "СОСТОЯНИЕ" "ДОСТУП" "ПОРТЫ" "ВЕРСИЯ")")
  for i in "${SEL[@]}"; do
    if probe_load "$i"; then
      rows+=("$(row "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(cell_hy2)" "$(cell_hy2_access)" \
        "${P[hy2_port]:--}${P[hy2_range]:+,${P[hy2_range]}}" "${P[hy2_ver]:--}")")
    else
      rows+=("$(row "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(c_red "НЕТ СВЯЗИ")" "-" "-" "-")")
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
    hop)     hy2_hop "$@" ;;
    upgrade) hy2_upgrade "$@" ;;
    *)       die "используй: iof hy2 add | del | list | show | refresh | status | install | restart | hop | upgrade" ;;
  esac
}
