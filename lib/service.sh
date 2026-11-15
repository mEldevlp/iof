#!/usr/bin/env bash

# Общие команды: init, update, exec, refresh; заглушка VLESS

cmd_init() {
  mkdir -p "$BASE" "$HY2_DIR" "$STATE_DIR"
  chmod 700 "$BASE"

  if [[ ! -f "$NODES_FILE" ]]; then
    cat > "$NODES_FILE" <<'EOF'
# имя | адрес для клиентов | ssh (local или user@host[:port]) | подпись в клиенте
main   | 192.0.2.10    | local                 | Main
node-1 | 198.51.100.20 | root@198.51.100.20    | Node 1
node-2 | 203.0.113.30  | admin@203.0.113.30:22 | Node 2
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

  if [[ ! -f "$SSH_KEY" ]]; then
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "iof@$(hostname)" >/dev/null
    echo "Создан SSH-ключ $SSH_KEY"
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

# Обновление из клона репозитория GitHub в $IOF_SRC: git pull, затем install.sh
# ставит новый iof и веб-панель
cmd_update() {
  local old new
  [[ -d "$IOF_SRC/.git" ]] || die "нет клона репозитория в $IOF_SRC, сначала: git clone https://github.com/mEldevlp/iof $IOF_SRC"
  have git || die "нет git: apt install git"
  old="$(git -C "$IOF_SRC" rev-parse --short HEAD)"
  git -C "$IOF_SRC" pull --ff-only --quiet || die "git pull не прошёл, проверь $IOF_SRC (git -C $IOF_SRC status)"
  new="$(git -C "$IOF_SRC" rev-parse --short HEAD)"
  if [[ "$old" == "$new" ]]; then
    echo "Новых изменений нет ($new), переустанавливаю текущую версию"
  else
    echo "Изменения $old..$new:"
    git -C "$IOF_SRC" log --format='  %h %s' "$old..$new"
  fi
  exec bash "$IOF_SRC/install.sh" "$@"
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
  awg_refresh
}

# VLESS: iof vless ... (WIP, команд пока нет)

cmd_vless() {
  echo "VLESS: в разработке (WIP), команд пока нет."
  return 2
}
