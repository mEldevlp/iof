#!/usr/bin/env bash

# Общие команды: init, update, exec, refresh; заглушка VLESS

init_files() {
  mkdir -p "$BASE" "$HY2_DIR" "$STATE_DIR"
  chmod 700 "$BASE"

  if [[ ! -f "$NODES_FILE" ]]; then
    cat > "$NODES_FILE" <<'EOF'
# имя | адрес для клиентов | ssh (local или user@host[:port]) | подпись в клиенте
# main   | 192.0.2.10    | local                 | Main
# node-1 | 198.51.100.20 | root@198.51.100.20    | Node 1
# node-2 | 203.0.113.30  | admin@203.0.113.30:22 | Node 2
EOF
    echo "Создан $NODES_FILE"
  fi

  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<'EOF'
# Уведомления в Telegram без бота: узлы (iof check) и аудит (audit cron), пусто = не отправлять.
# Бот (sudo iof bot, страница «Телеграм бот» панели) шлёт их каждому админу и умеет больше
TG_TOKEN=""
TG_CHAT=""

# Российские серверы, до которых iof check раз в сутки проверяет путь с узлов (пусто — не проверять)
RU_TARGETS="ya.ru vk.com mail.ru ozon.ru wildberries.ru rt.ru"

# Сколько узлов обрабатывать одновременно
PARALLEL=20

# Диапазон смены портов Hysteria2 для iof hy2 hop on
HY2_HOP="10000-19999"

# Блок-лист сканеров (iof block): адрес списка и адреса, которые не блокируются никогда
BLOCKLIST_URL=""
BLOCK_ALLOW=""
EOF
    chmod 600 "$ENV_FILE"
    echo "Создан $ENV_FILE"
  fi

  ensure_ssh_key
  chmod 600 "$NODES_FILE"
}

cmd_init() {
  init_files
  if ! grep -qE '^[[:space:]]*[^#[:space:]]' "$NODES_FILE"; then
    echo "Узлов пока нет. Первый запуск: sudo iof setup (или мастер на Обзоре панели)."
    return 0
  fi

  # Раздача ключа по одному узлу с вводом пароля. Для многих серверов удобнее iof node import
  read_nodes
  local i
  for i in "${!N_NAME[@]}"; do
    if [[ "${N_SSH[$i]}" == "local" ]]; then continue; fi
    echo "== ${N_NAME[$i]} (${N_SSH[$i]})"
    if ssh_cmd "${N_SSH[$i]}" true 2>/dev/null; then
      echo "   ключ уже работает"
      continue
    fi
    split_target "${N_SSH[$i]}"
    echo "   копирую ключ, введи пароль этого сервера"
    if ssh-copy-id -i "${SSH_KEY}.pub" -p "$T_PORT" -o StrictHostKeyChecking=accept-new "$T_HOST"; then
      echo "   готово"
    else
      echo "   не получилось, добавь содержимое ${SSH_KEY}.pub в authorized_keys на узле вручную"
    fi
  done
  echo
  echo "Проверка: iof status"
}

# Рабочая ветка сохраняет git pull. Панель и клон на теге устанавливают только опубликованные релизы.
cmd_update() {
  local old new release=0 channel=stable tag="" downgrade=0 expected="" installer_args=()
  while (( $# )); do
    case "$1" in
      --release) release=1 ;;
      --channel) (( $# >= 2 )) || die "после --channel нужен stable или test"; channel="$2"; release=1; shift ;;
      --tag) (( $# >= 2 )) || die "после --tag нужен тег vN.N"; tag="$2"; release=1; shift ;;
      --revision) (( $# >= 2 )) || die "после --revision нужен полный SHA"; expected="$2"; release=1; shift ;;
      --allow-downgrade) downgrade=1; release=1 ;;
      --no-web) installer_args=(--no-web) ;;
      *) die "используй: iof update [--release] [--channel stable|test] [--tag vN.N] [--allow-downgrade] [--no-web]" ;;
    esac
    shift
  done
  [[ "$channel" == stable || "$channel" == test ]] || die "неизвестный канал обновления"
  [[ -z "$expected" || "$expected" =~ ^[0-9a-f]{40}$ ]] || die "неверный SHA релиза"
  [[ "$downgrade" == 0 || ( "$channel" == stable && -n "$tag" ) ]] || die "для возврата нужны --channel stable и --tag vN.N"
  [[ -d "$IOF_SRC/.git" ]] || die "нет клона репозитория в $IOF_SRC, сначала: git clone https://github.com/mEldevlp/iof $IOF_SRC"
  have git || die "нет git: apt install git"
  (umask 077; mkdir -p "$BASE")
  exec 9>>"$BASE/update.lock"
  flock -n 9 || die "iof уже обновляется"
  if (( release )) || ! git -C "$IOF_SRC" symbolic-ref -q HEAD >/dev/null; then
    update_release "$channel" "$tag" "$downgrade" "$expected" "${installer_args[@]}"
    return
  fi
  old="$(git -C "$IOF_SRC" rev-parse --short HEAD)"
  git -C "$IOF_SRC" pull --ff-only --quiet || die "git pull не прошёл, проверь $IOF_SRC (git -C $IOF_SRC status)"
  new="$(git -C "$IOF_SRC" rev-parse --short HEAD)"
  if [[ "$old" == "$new" ]]; then
    echo "Новых изменений нет ($new), переустанавливаю текущую версию"
  else
    echo "Изменения $old..$new:"
    git -C "$IOF_SRC" log --format='  %h %s' "$old..$new"
  fi
  exec bash "$IOF_SRC/install.sh" "${installer_args[@]}"
}

# Локальное восстановление входа в панель. Пароль принимает только Python через терминал или stdin.
cmd_web() {
  [[ "${1:-}" == reset-password && $# -le 2 && ( $# == 1 || "$2" == --password-stdin ) ]] \
    || die "использование: iof web reset-password [--password-stdin]"
  local auth=/opt/iof-web/iof_auth.py
  [[ -f "$auth" ]] || die "панель не установлена: sudo bash $IOF_SRC/install.sh"
  shift
  exec python3 "$auth" reset "$BASE" "$@"
}

exec_job() {
  local i="$1"
  if [[ "${N_SSH[$i]}" == "local" ]]; then
    bash -c "$EXEC_CMD" 2>&1
  else
    ssh_cmd "${N_SSH[$i]}" "$(remote_sudo "${N_SSH[$i]}")bash -c $(printf '%q' "$EXEC_CMD")" 2>&1
  fi
}

# Произвольная команда на узлах, вывод по узлам в порядке nodes.conf
cmd_exec() {
  [[ $# -gt 0 ]] || die "укажи команду: iof exec \"apt update\""
  read_nodes
  select_nodes
  local i rc failed=0
  EXEC_CMD="$*"
  pmap exec_job "${SEL[@]}"
  for i in "${SEL[@]}"; do
    rc="$(pm_rc "$i")"
    echo "== ${N_NAME[$i]}"
    pm_out "$i"
    if [[ "$rc" != "0" ]]; then
      echo "   код выхода $rc"
      failed=$((failed + 1))
    fi
  done
  echo
  echo "Выполнено на ${#SEL[@]} узлах, с ошибкой: $failed"
}

# Пересборка всех ссылок Hysteria2 и ключей AWG (после смены узлов, пароля или ретранслятора)
cmd_refresh() {
  hy2_refresh
  echo
  cmd_awg refresh
}

# VLESS: iof vless ... (WIP, команд пока нет)

cmd_vless() {
  echo "VLESS: в разработке (WIP), команд пока нет."
  return 2
}
