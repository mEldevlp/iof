#!/usr/bin/env bash

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
