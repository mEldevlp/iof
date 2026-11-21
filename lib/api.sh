#!/usr/bin/env bash

# Данные для веб-панели (iof-web): блок на узел, первая строка "== имя", дальше key=value.
# Поля те же, что отдаёт n_status, плюс адрес, подпись, отклик и проблемы через "; "
cmd_api() {
  case "${1:-}" in
    status)  api_status ;;
    controller) api_controller ;;
    service) api_service ;;
    updates) api_updates ;;
    audit)   api_audit ;;
    *)       die "используй: iof api status | controller | service | updates | audit" ;;
  esac
}

# Для страницы «Сервис»: версия, клон репозитория, настроен ли Telegram, задания cron iof
api_service() {
  printf 'version=%s\nrevision=%s\nsrc=%s\n' "$IOF_VERSION" "${IOF_REVISION:-}" "$IOF_SRC"
  if [[ -f "$BASE/update.lock" ]] && ! (flock -n 9) 9<"$BASE/update.lock"; then
    echo 'update_busy=yes'
  else
    echo 'update_busy=no'
  fi
  if [[ -d "$IOF_SRC/.git" ]] && have git; then
    printf 'src_version=%s\n' "$(source_version "$IOF_SRC" || true)"
  fi
  if [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then echo "tg=yes"; else echo "tg=no"; fi
  crontab -l -u root 2>/dev/null | grep -v '^[[:space:]]*#' | grep -F 'iof' | sed 's/^/cron=/' || true
}

# Для панели и уведомлений: только коммиты до тега последнего опубликованного релиза.
api_updates() {
  [[ -d "$IOF_SRC/.git" ]] || die "нет клона репозитория в $IOF_SRC"
  have git || die "нет git: apt install git"
  local channel kind tag published_channel installed_channel=unknown
  REL_CATALOG="$(release_catalog)" || die "не удалось проверить опубликованные релизы"
  for channel in stable test; do
    release_info "$channel"
    printf '%s_release=%s\n%s_commit=%s\n%s_state=%s\n' "$channel" "$REL_TAG" "$channel" "$REL_COMMIT" "$channel" "$REL_STATE"
    if [[ "$channel" == stable ]]; then
      printf 'release=%s\navailable=%s\n' "$REL_TAG" "$REL_AVAILABLE"
    fi
    if [[ "$REL_AVAILABLE" == yes && -n "$REL_INSTALLED" ]]; then
      git -C "$IOF_SRC" log --format="${channel}_commit_log=%h%x09%cd%x09%s" --date=short "$REL_INSTALLED..$REL_COMMIT"
      if [[ "$channel" == stable ]]; then
        git -C "$IOF_SRC" log --format='commit=%h%x09%cd%x09%s' --date=short "$REL_INSTALLED..$REL_COMMIT"
      fi
    fi
  done
  while IFS=$'\t' read -r kind tag published_channel; do
    if [[ "$kind" == published && "$tag" == "${IOF_VERSION%% *}" ]]; then installed_channel="$published_channel"; break; fi
  done <<< "$REL_CATALOG"
  printf 'installed_channel=%s\n' "$installed_channel"
}

api_status() {
  nodes_present || return 0
  read_nodes
  select_nodes
  local i
  probe_all "${SEL[@]}"
  for i in "${SEL[@]}"; do
    echo "== ${N_NAME[$i]}"
    printf 'addr=%s\ntitle=%s\n' "${N_ADDR[$i]}" "$(node_title "$i")"
    if probe_load "$i"; then
      api_probe_fields
    else
      printf 'reachable=no\nissues=нет связи по SSH\n'
    fi
  done
}

# Локальный опрос для панели, в том числе до регистрации VPN-узлов.
api_controller() {
  local out
  out="$(probe_target local)" && probe_parse "$out" || die "не удалось собрать данные управляющего сервера"
  printf '== %s\n' "$(hostname)"
  api_probe_fields
}

api_probe_fields() {
  local k
  printf 'reachable=yes\nms=%s\nissues=%s\n' "$P_MS" "$(node_issues)"
  for k in "${!P[@]}"; do printf '%s=%s\n' "$k" "${P[$k]}"; done
}

# Для страницы «Безопасность» панели: JSON с последними проверками, справочником, историей
# и настройками (строка cron с iof audit, настроен ли Telegram, диапазон HY2_HOP). Узлы не опрашивает
api_audit() {
  local cron tg="no"
  audit_need_python
  read_nodes
  local bcron bl="no"
  cron="$(crontab -l -u root 2>/dev/null | grep -v '^[[:space:]]*#' | grep -F 'iof audit' | head -n 1 || true)"
  bcron="$(crontab -l -u root 2>/dev/null | grep -v '^[[:space:]]*#' | grep -F 'iof block update' | head -n 1 || true)"
  if [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then tg="yes"; fi
  if [[ -n "$BLOCKLIST_URL" ]]; then bl="yes"; fi
  { audit_catalog; audit_nodes
    printf 'S\tcron\t%s\nS\ttg\t%s\nS\thop\t%s\nS\tblock_cron\t%s\nS\tblocklist\t%s\n' "$cron" "$tg" "$HY2_HOP" "$bcron" "$bl"
  } | audit_py api "$AUDIT_DIR"
}
