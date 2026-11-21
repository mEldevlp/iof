#!/usr/bin/env bash

# SSH запускается после начальной настройки systemd, включая очистку /tmp.
# Иначе при загрузке контейнера могут пропасть временные файлы проверки подписей APT.
wait_ready() {
  local server="$1"; shift
  for _ in {1..60}; do
    if "$@" "$server" systemctl is-active --quiet ssh.service </dev/null 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  printf 'Ошибка: ssh.service на %s не запустилась за 60 секунд\n' "$server" >&2
  "$@" "$server" systemctl --failed --no-pager </dev/null >&2 || true
  return 1
}
