#!/usr/bin/env bash

# Опрос состояния узлов (n_status). Поля узла попадают в ассоциативный массив P,
# время ответа в миллисекундах в P_MS.

declare -A P=()
P_MS=0

probe_job() {
  probe_target "${N_SSH[$1]}"
}

probe_target() {
  local target="$1" t0 t1 out
  t0="$(date +%s%N)"
  out="$(run_on "$target" n_status 2>/dev/null)" || return 1
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
# одно сообщение со всеми изменениями. Код выхода 1, если есть проблемные узлы.
# Раз в сутки (или с --daily) ещё обновления iof и доступ к российским серверам с узлов, см. check_daily
cmd_check() {
  local daily=0
  case "${1:-}" in
    "") ;;
    --daily) daily=1 ;;
    *) die "используй: iof [-n узлы] check [--daily]" ;;
  esac
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
    tg_send nodes "$(printf '%s\n' "${changes[@]}")"
  fi
  # Итог для страницы «Сервис» панели: когда была проверка и что нашла
  printf 'time=%s\ntotal=%s\nbad=%s\nproblems=%s\nchanges=%s\n' \
    "$(date '+%F %T')" "${#SEL[@]}" "$bad" "${bad_names[*]}" "${#changes[@]}" > "$CHECK_FILE"
  if (( daily )) || daily_due; then check_daily; fi
  (( bad == 0 ))
}

# Значение ключа из check.daily, пусто, если его нет
daily_get() {
  if [[ -f "$DAILY_FILE" ]]; then kv_get "$(cat "$DAILY_FILE")" "$1"; fi
}
daily_set() { env_set "$DAILY_FILE" "$1" "$2"; }

# Пора ли ежедневной части: прошли сутки без 5 минут (так она не уползает по cron раз в 5 минут) и проверка
# идёт по всем узлам, а не по выбранным через -n
daily_due() {
  local last
  [[ -z "$IOF_ONLY" ]] || return 1
  last="$(daily_get time)"
  [[ "$last" =~ ^[0-9]+$ ]] || return 0
  (( $(date +%s) - last >= 86100 ))
}

# Раз в сутки из iof check. Время ставится сразу: если что-то здесь упадёт, cron не повторит это через 5 минут
check_daily() {
  daily_set time "$(date +%s)"
  echo
  echo "Раз в сутки: обновления iof и доступ к российским серверам с узлов"
  check_updates
  check_ru
}

# Вышла ли новая версия iof: git fetch в клоне и коммиты, которые принесёт iof update. Сообщение уходит
# один раз на каждую новую вершину вышестоящей ветки
check_updates() {
  local err branch head log count text
  daily_set updates ""
  if [[ ! -d "$IOF_SRC/.git" ]] || ! have git; then
    echo "  обновления iof: нет git-клона в $IOF_SRC, не проверяю"
    return 0
  fi
  if ! err="$(GIT_TERMINAL_PROMPT=0 timeout 60 git -C "$IOF_SRC" fetch --quiet 2>&1)"; then
    echo "  обновления iof: git fetch не прошёл: $(tail -n 1 <<<"$err")"
    return 0
  fi
  if ! branch="$(git -C "$IOF_SRC" rev-parse --abbrev-ref '@{u}' 2>/dev/null)"; then
    echo "  обновления iof: у ветки в $IOF_SRC нет вышестоящей (upstream), iof update не сможет сделать git pull"
    return 0
  fi
  head="$(git -C "$IOF_SRC" rev-parse '@{u}')"
  log="$(git -C "$IOF_SRC" log --format='• %h %s' 'HEAD..@{u}')"
  count="$(grep -c . <<<"$log" || true)"
  daily_set updates "$count"
  if (( count == 0 )); then
    echo "  обновления iof: нет, в $branch ничего нового"
    return 0
  fi
  echo "  обновления iof: в $branch новых коммитов: $count"
  if [[ "$head" == "$(daily_get updates_head)" ]]; then return 0; fi
  text="В $branch новых коммитов: $count."$'\n'"$(head -n 10 <<<"$log")"
  if (( count > 10 )); then text+=$'\n'"… и ещё $((count - 10))"; fi
  text+=$'\n'"Обновить: sudo iof update или кнопка «Обновить» на странице «Сервис» панели"
  tg_send updates "$text"
  daily_set updates_head "$head"
}

ru_job() { run_on "${N_SSH[$1]}" n_ru_reach "$RU_TARGETS" "$RU_CONTROL"; }

# Аргументы через запятую с пробелом: a, b, c
join_comma() {
  local s="" x
  for x in "$@"; do s+="${s:+, }$x"; done
  printf '%s' "$s"
}

# Доступ к российским серверам с каждого узла. Отвечает меньше половины из RU_TARGETS, а зарубежные из
# RU_CONTROL отвечают — путь между Россией и сетью узла, похоже, закрыт (так РКН отрезает хостеров);
# не отвечают и они — у узла нет интернета. Сайт, который режет заграницу или отвечает с зарубежного
# CDN, порог выдерживает. Сообщение уходит, только когда состояние узла меняется
check_ru() {
  local i t kind tcp ping ok total ctl state prev title line up=() dn=() changes=() cut=() noinet=() down=()
  for t in $RU_TARGETS $RU_CONTROL; do
    [[ "$t" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "  доступ к РФ: в RU_TARGETS или RU_CONTROL не имя и не IPv4: «$t»"; return 0; }
  done
  if [[ -z "${RU_TARGETS//[[:space:]]/}" ]]; then
    echo "  доступ к РФ: RU_TARGETS пуст, не проверяю"
    daily_set ru_off 1
    return 0
  fi
  mkdir -p "$RU_DIR"
  pmap ru_job "${SEL[@]}"
  for i in "${SEL[@]}"; do
    title="${N_NAME[$i]} (${N_ADDR[$i]})"
    if ! pm_ok "$i"; then
      down+=("${N_NAME[$i]}")
      echo "  доступ к РФ с ${N_NAME[$i]}: не проверен, нет связи с узлом"
      continue
    fi
    ok=0 total=0 ctl=0
    up=()
    dn=()
    while IFS=$'\t' read -r kind t _ tcp ping; do
      if [[ "$kind" == "ru" ]]; then
        total=$((total + 1))
        if [[ "$tcp" == 1 || "$ping" == 1 ]]; then ok=$((ok + 1)); up+=("$t"); else dn+=("$t"); fi
      elif [[ "$kind" == "ctl" && ( "$tcp" == 1 || "$ping" == 1 ) ]]; then
        ctl=$((ctl + 1))
      fi
    done < <(pm_out "$i")
    if (( total == 0 )); then
      down+=("${N_NAME[$i]}")
      echo "  доступ к РФ с ${N_NAME[$i]}: узел не ответил по делу"
      continue
    fi
    state=ok
    if (( ok * 2 < total )); then
      state="cut"
      if [[ -n "${RU_CONTROL//[[:space:]]/}" ]] && (( ctl == 0 )); then state=noinet; fi
    fi
    line="  доступ к РФ с ${N_NAME[$i]}: отвечают $ok из $total"
    if (( ${#dn[@]} > 0 )); then line+=", нет ответа: $(join_comma "${dn[@]}")"; fi
    case "$state" in
      cut)    line+=" — путь к РФ закрыт?"; cut+=("${N_NAME[$i]}") ;;
      noinet) line+=", зарубежные тоже молчат — нет интернета"; noinet+=("${N_NAME[$i]}") ;;
    esac
    echo "$line"
    prev="$(cat "$RU_DIR/${N_NAME[$i]}" 2>/dev/null || echo ok)"
    if [[ "$state" == "$prev" ]]; then continue; fi
    printf '%s\n' "$state" > "$RU_DIR/${N_NAME[$i]}"
    case "$state" in
      cut)
        line="[РФ НЕДОСТУПНА] $title: из российских серверов отвечают $ok из $total"
        if (( ok > 0 )); then line+=" ($(join_comma "${up[@]}"))"; fi
        changes+=("$line, а зарубежные отвечают. Похоже, путь между Россией и сетью узла закрыт: клиенты из России могут не подключиться") ;;
      noinet)
        changes+=("[НЕТ ИНТЕРНЕТА] $title: с узла не отвечают ни российские серверы, ни ${RU_CONTROL// /, }") ;;
      ok)
        changes+=("[OK] $title: российские серверы снова отвечают ($ok из $total)") ;;
    esac
  done
  daily_set ru_off ""
  daily_set ru_time "$(date +%s)"
  daily_set ru_nodes "$(( ${#SEL[@]} - ${#down[@]} ))"
  daily_set ru_cut "${cut[*]}"
  daily_set ru_noinet "${noinet[*]}"
  daily_set ru_down "${down[*]}"
  if (( ${#changes[@]} > 0 )); then
    tg_send ru "$(printf '%s\n' "${changes[@]}")"
  fi
}
