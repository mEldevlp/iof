#!/usr/bin/env bash

# Данные для веб-панели (iof-web): блок на узел, первая строка "== имя", дальше key=value.
# Поля те же, что отдаёт n_status, плюс адрес, подпись, отклик и проблемы через "; "
cmd_api() {
  case "${1:-}" in
    status)  api_status ;;
    service) api_service ;;
    updates) api_updates ;;
    audit)   api_audit ;;
    *)       die "используй: iof api status | service | updates | audit" ;;
  esac
}

# Для страницы «Сервис»: версия, клон репозитория, настроен ли Telegram, задания cron iof
api_service() {
  printf 'version=%s\nsrc=%s\n' "$IOF_VERSION" "$IOF_SRC"
  if [[ -d "$IOF_SRC/.git" ]] && have git; then
    printf 'src_version=%s\n' "$(git -C "$IOF_SRC" log -1 --format='%h %cd' --date=short 2>/dev/null || true)"
  fi
  if [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then echo "tg=yes"; else echo "tg=no"; fi
  crontab -l -u root 2>/dev/null | grep -v '^[[:space:]]*#' | grep -F 'iof' | sed 's/^/cron=/' || true
}

# Для страницы «Сервис»: git fetch в клоне, затем коммиты, которые принесёт iof update
api_updates() {
  local err
  [[ -d "$IOF_SRC/.git" ]] || die "нет клона репозитория в $IOF_SRC"
  have git || die "нет git: apt install git"
  err="$(GIT_TERMINAL_PROMPT=0 git -C "$IOF_SRC" fetch --quiet 2>&1)" || die "git fetch не прошёл: $(tail -n 1 <<<"$err")"
  git -C "$IOF_SRC" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 \
    || die "у ветки в $IOF_SRC нет вышестоящей (upstream), iof update не сможет сделать git pull"
  printf 'branch=%s\n' "$(git -C "$IOF_SRC" rev-parse --abbrev-ref '@{u}')"
  git -C "$IOF_SRC" log --format='commit=%h%x09%cd%x09%s' --date=short 'HEAD..@{u}'
}

api_status() {
  read_nodes
  select_nodes
  local i k
  probe_all "${SEL[@]}"
  for i in "${SEL[@]}"; do
    echo "== ${N_NAME[$i]}"
    printf 'addr=%s\ntitle=%s\n' "${N_ADDR[$i]}" "$(node_title "$i")"
    if probe_load "$i"; then
      printf 'reachable=yes\nms=%s\nissues=%s\n' "$P_MS" "$(node_issues)"
      for k in "${!P[@]}"; do printf '%s=%s\n' "$k" "${P[$k]}"; done
    else
      printf 'reachable=no\nissues=нет связи по SSH\n'
    fi
  done
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
