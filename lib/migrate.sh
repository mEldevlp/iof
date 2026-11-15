#!/usr/bin/env bash

# Перенос управляющего сервера: iof migrate start | finish | cancel | status
# start на старом сервере ставит iof на новый и копирует туда данные, а у себя запрещает изменения.
# finish на новом снимает роль управляющего со старого (тот остаётся узлом) и ставит задания cron.
# cancel на старом отменяет перенос. Состояние в migrate.conf (key=value): role=source на старом,
# role=target на новом, общий номер переноса id, peer — адрес SSH другого сервера

# Задания cron, которые переезжают вместе с управлением: iof check, iof-nightly
MIGRATE_CRON_RE='(^|[[:space:]/])iof(-nightly)?([[:space:]]|$)'

# Значение ключа $1 из migrate.conf, пусто, если переноса нет
migrate_get() {
  if [[ -f "$MIGRATE_FILE" ]]; then kv_get "$(cat "$MIGRATE_FILE")" "$1"; fi
}

# Пока идёт перенос отсюда, изменения здесь не попали бы на новый сервер, поэтому они запрещены
migrate_guard() {
  if [[ "$(migrate_get role)" != "source" ]]; then return 0; fi
  die "идёт перенос управления на $(migrate_get peer), здесь изменения заблокированы.
  Завершить: в панели нового сервера (Перенос) или на нём: sudo iof migrate finish
  Отменить:  sudo iof migrate cancel"
}

# Как новый сервер будет заходить на этот: root@<адрес узла local>[:порт sshd]
migrate_self_default() {
  local i port
  for i in "${!N_NAME[@]}"; do
    if [[ "${N_SSH[$i]}" != "local" ]]; then continue; fi
    port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
    if [[ -n "$port" && "$port" != "22" ]]; then
      printf 'root@%s:%s' "${N_ADDR[$i]}" "$port"
    else
      printf 'root@%s' "${N_ADDR[$i]}"
    fi
    return 0
  done
  return 1
}

# Ключ iof в authorized_keys пользователя из $1 (user@host[:port]) на этом сервере:
# после переноса новый сервер заходит сюда как на обычный узел
migrate_trust_self() {
  local user="${1%%@*}" home pub f
  home="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$home" ]] || die "на этом сервере нет пользователя $user (--self)"
  pub="$(cat "$SSH_KEY.pub")"
  f="$home/.ssh/authorized_keys"
  (umask 077; mkdir -p "$home/.ssh"; touch "$f")
  if grep -qxF "$pub" "$f"; then return 0; fi
  # Без перевода строки в конце файла ключ склеился бы с последней строкой
  if [[ -s "$f" && -n "$(tail -c 1 "$f")" ]]; then echo >> "$f"; fi
  printf '%s\n' "$pub" >> "$f"
  if [[ "$user" != "root" ]]; then chown "$user:" "$home/.ssh" "$f"; fi
}

# nodes.conf для нового сервера ($1, правится на месте): узел local становится $2 (так новый
# сервер заходит на этот), а узел с адресом SSH нового сервера ($3), если он был, становится local
migrate_nodes_conf() {
  local file="$1" self="$2" target="$3"
  [[ -f "$file" ]] || return 0
  awk -F'|' -v self="$self" -v target="${target%:22}" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*(#|$)/ { print; next }
    {
      t = trim($3); n = t; sub(/:22$/, "", n)
      if (t == "" || t == "local") t = self
      else if (n == target) t = "local"
      else { print; next }
      line = trim($1) " | " trim($2) " | " t " | " trim($4)
      sub(/[[:space:]]+$/, "", line)
      print line
    }' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# Собирает в папке $1 всё, что нужно новому серверу: data (копия $BASE с правками для него),
# ssh (ключ iof и known_hosts), src (клон репозитория $IOF_SRC)
migrate_bundle() {
  local stage="$1" id="$2" self="$3" target="$4" tpl cn
  mkdir -p "$stage/ssh"
  cp -a "$BASE" "$stage/data"
  rm -rf "$stage/data/migrate.conf" "$stage/data/.migrate-probe" "$stage/data"/.key.*
  cp -a "$IOF_SRC" "$stage/src"
  cp -p "$SSH_KEY" "$SSH_KEY.pub" "$stage/ssh/"
  if [[ -f /root/.ssh/known_hosts ]]; then cp -p /root/.ssh/known_hosts "$stage/ssh/"; fi

  migrate_nodes_conf "$stage/data/nodes.conf" "$self" "$target"

  # Шаблон Hysteria2 переезжает в папку iof. Сертификата, на который он ссылается, на новом
  # сервере нет, поэтому CN записывается явно. HY2_TEMPLATE нужен и iof, и панели
  tpl="${HY2_TEMPLATE:-/etc/hysteria/config.yaml}"
  if [[ -f "$tpl" ]]; then
    install -m 600 "$tpl" "$stage/data/hy2-template.yaml"
    env_set "$stage/data/iof.env" HY2_TEMPLATE "$BASE/hy2-template.yaml"
    env_set "$stage/data/web.env" HY2_TEMPLATE "$BASE/hy2-template.yaml"
    cn="${HY2_CN:-$(hy2_template_cn "$tpl")}"
    if [[ "$cn" =~ ^[A-Za-z0-9*._-]+$ ]]; then env_set "$stage/data/iof.env" HY2_CN "$cn"; fi
  else
    echo "   Внимание: нет шаблона Hysteria2 $tpl, на новом сервере iof hy2 install не заработает, пока не задашь HY2_TEMPLATE"
  fi

  # Задания cron ставятся на новом сервере только в iof migrate finish, иначе ночное
  # обслуживание и проверки шли бы с двух серверов
  { crontab -l -u root 2>/dev/null || true; } | { grep -E "$MIGRATE_CRON_RE" || true; } > "$stage/data/migrate-cron"

  printf 'role=target\nid=%s\npeer=%s\nstarted=%s\n' "$id" "$self" "$(date '+%F %T')" > "$stage/data/migrate.conf"
  chmod 600 "$stage/data/migrate.conf" "$stage/data/migrate-cron"
}

# iof migrate start <хост> [ssh_порт] [--user имя] [--key файл | --key-stdin | --password-stdin | --key-installed]
#   [--self user@host[:port]]
# На старом сервере. Вход как у iof node add. --self: как новый сервер будет заходить на этот,
# по умолчанию root@<адрес узла local>. Повторный запуск с тем же сервером безопасен
migrate_start() {
  local pos=() user="root" auth="ask" keyfile="" self="" host port target id role peer started
  local self_host self_port out err probe stage status total bad=()
  while (( $# > 0 )); do
    case "$1" in
      --user|--key|--self)
        [[ $# -ge 2 ]] || die "после $1 нужно значение"
        case "$1" in
          --user) user="$2" ;;
          --key)  auth="key-file"; keyfile="$2" ;;
          --self) self="$2" ;;
        esac
        shift 2 ;;
      --key-stdin)      auth="key-stdin"; shift ;;
      --password-stdin) auth="password-stdin"; shift ;;
      --key-installed)  auth="installed"; shift ;;
      -*) die "неизвестный параметр $1" ;;
      *)  pos+=("$1"); shift ;;
    esac
  done
  host="${pos[0]:-}"; port="${pos[1]:-22}"
  [[ -n "$host" ]] || die "используй: iof migrate start <хост> [ssh_порт] [--user имя] [--key файл]"
  host_ok "$host" || die "хост '$host': нужен IPv4 или имя хоста (латиница, цифры, точка, дефис)"
  user_ok "$user" || die "пользователь '$user': строчная латиница, цифры, _ и -"
  port_ok "$port" || die "ssh-порт '$port' вне 1-65535"
  port="$((10#$port))"
  target="$user@$host"
  if (( port != 22 )); then target="$target:$port"; fi

  read_nodes
  [[ -d "$IOF_SRC/.git" ]] || die "нет клона репозитория в $IOF_SRC, из него iof ставится на новый сервер"
  [[ -s "$SSH_KEY" && -s "$SSH_KEY.pub" ]] || die "нет ключа iof $SSH_KEY"
  role="$(migrate_get role)"
  peer="$(migrate_get peer)"
  if [[ "$role" == "target" ]]; then die "этот сервер сам принимает управление от $peer, сначала: sudo iof migrate finish"; fi
  if [[ "$role" == "source" ]] && ! ssh_same "$peer" "$target"; then
    die "уже идёт перенос на $peer. Отменить его: sudo iof migrate cancel"
  fi
  id="$(migrate_get id)"
  if [[ -z "$id" ]]; then id="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi
  started="$(migrate_get started)"
  started="${started:-$(date '+%F %T')}"

  if [[ -z "$self" ]]; then
    self="$(migrate_self_default)" \
      || die "этот сервер не узел (в nodes.conf нет local): укажи, как новый сервер будет заходить сюда, --self root@адрес[:порт]"
  fi
  [[ "$self" =~ ^([a-z_][a-z0-9_-]*)@([^:@]+)(:([0-9]+))?$ ]] || die "--self '$self': нужен вид root@адрес[:порт]"
  self_host="${BASH_REMATCH[2]}"
  self_port="${BASH_REMATCH[4]:-22}"
  host_ok "$self_host" && port_ok "$self_port" || die "--self '$self': нужен вид root@адрес[:порт]"

  echo "== Вход на $target"
  read_auth "$auth" "$keyfile" "$user" "$host"
  if [[ "$AUTH_MODE" == "password" ]]; then ensure_sshpass; fi
  IM_HOST=("$host"); IM_PORT=("$port"); IM_USER=("$user"); IM_MODE=("$AUTH_MODE")
  IM_PASS=("$AUTH_PASS"); IM_KEY=("$AUTH_KEY")
  local rc=0
  err="$(push_key_job 0 2>&1 >/dev/null)" || rc=1
  if [[ -n "$AUTH_KEY" ]] && have shred; then shred -u "$AUTH_KEY" 2>/dev/null || true; fi
  (( rc == 0 )) || die "вход на $target: ${err:-не удался}"
  echo "   ключ iof работает"

  echo "== Проверка $target"
  probe="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  PM_DIRS+=("$BASE/.migrate-probe")
  printf '%s\n' "$probe" > "$BASE/.migrate-probe"
  out="$(run_on "$target" n_migrate_check)" || die "не удалось проверить $target"
  rm -f "$BASE/.migrate-probe"
  [[ "$(kv_get "$out" probe)" != "$probe" ]] || die "$target — это этот же сервер"
  [[ "$(kv_get "$out" apt)" == "yes" ]] || die "на $target нет apt-get ($(kv_get "$out" os)), нужен Ubuntu или Debian"
  if [[ "$(kv_get "$out" role)" == "source" ]]; then die "с $target самого идёт перенос, сначала отмени его там"; fi
  if [[ "$(kv_get "$out" nodes)" != "0" && "$(kv_get "$out" id)" != "$id" ]]; then
    die "на $target уже есть свои узлы iof ($(kv_get "$out" nodes) в /root/iof/nodes.conf), перенос их затрёт. Если они не нужны, убери их там: sudo mv /root/iof /root/iof.old"
  fi
  echo "   $(kv_get "$out" os), можно переносить"

  # С этого момента изменения здесь запрещены (migrate_guard), иначе они не попали бы на новый сервер
  printf 'role=source\nid=%s\npeer=%s\nself=%s\nstarted=%s\n' "$id" "$target" "$self" "$started" > "$MIGRATE_FILE"
  chmod 600 "$MIGRATE_FILE"
  migrate_trust_self "$self"

  echo "== Копирую на $target данные iof, ключ iof и клон репозитория"
  stage="$(mktemp -d)"
  PM_DIRS+=("$stage")
  migrate_bundle "$stage" "$id" "$self" "$target"
  tar -czf - -C "$stage" . \
    | ssh_cmd "$target" "$(remote_sudo "$target")bash -c 'rm -rf $MIGRATE_INBOX && mkdir -m 700 $MIGRATE_INBOX && tar -xzf - -C $MIGRATE_INBOX'" \
    || die "не удалось передать данные на $target. Повторить: та же команда, отменить перенос: sudo iof migrate cancel"

  echo "== Ставлю iof на $target"
  out="$(run_on "$target" n_migrate_receive "$id" "$MIGRATE_INBOX")" \
    || die "$target не принял управление, причина выше. Повторить: та же команда, отменить перенос: sudo iof migrate cancel"
  echo "   готово, версия ${out#received }"

  echo "== Проверка: видит ли новый сервер все узлы"
  status="$(ssh_cmd "$target" "$(remote_sudo "$target")/usr/local/bin/iof api status")" || die "iof на $target не отвечает"
  mapfile -t bad < <(awk '/^== /{ n = substr($0, 4) } /^reachable=no$/{ print n }' <<<"$status")
  total="$(grep -c '^== ' <<<"$status" || true)"
  echo "Узлов: $total, на связи с $host: $(( total - ${#bad[@]} ))"
  if (( ${#bad[@]} > 0 )); then
    echo "Ошибки (${#bad[@]}): нет связи с нового сервера"
    printf '  %s\n' "${bad[@]}"
    echo "Обычно это файрвол у хостера (SSH открыт только для IP этого сервера) или запрет входа root по ключу."
    echo "Почини и проверь на новом сервере: sudo iof status"
  fi

  echo
  echo "Управление скопировано на $target. Этот сервер пока управляющий, но изменения на нём заблокированы."
  echo "Дальше открой панель нового сервера: ssh -p $port -L 8089:127.0.0.1:8088 $user@$host"
  echo "и http://127.0.0.1:8089/ → Перенос → «Завершить перенос». Или на нём: sudo iof migrate finish"
  echo "Отменить перенос: sudo iof migrate cancel"
}

# iof migrate finish [--skip-old]: на новом сервере. Снимает роль управляющего со старого
# (он остаётся узлом) и ставит задания cron. --skip-old: старый сервер недоступен, он пропускается
migrate_finish() {
  local skip=0 id peer dest="" cur add
  if [[ "${1:-}" == "--skip-old" ]]; then skip=1; elif [[ -n "${1:-}" ]]; then die "неизвестный параметр $1"; fi
  [[ "$(migrate_get role)" == "target" ]] || die "этот сервер не принимает управление (нет $MIGRATE_FILE с role=target)"
  id="$(migrate_get id)"
  peer="$(migrate_get peer)"
  exec </dev/null

  if (( skip )); then
    echo "Старый сервер $peer пропускаю. Если он ещё работает, сними с него iof вручную, иначе ночное обслуживание пойдёт и оттуда:"
    echo "  sudo crontab -e   (убрать строки с iof)"
    echo "  sudo systemctl disable --now iof-web && sudo rm /usr/local/bin/iof /usr/local/sbin/iof-nightly"
  else
    echo "== Снимаю управление со старого сервера $peer"
    dest="$(run_on "$peer" n_migrate_demote "$id" "$MIGRATE_CRON_RE")" \
      || die "не удалось снять управление с $peer, причина выше. Если он недоступен совсем: sudo iof migrate finish --skip-old"
  fi

  if [[ -s "$BASE/migrate-cron" ]]; then
    cur="$(crontab -l -u root 2>/dev/null || true)"
    add="$(grep -vxF -f <(printf '%s\n' "$cur") "$BASE/migrate-cron" || true)"
    if [[ -n "$add" ]]; then
      { if [[ -n "$cur" ]]; then printf '%s\n' "$cur"; fi; printf '%s\n' "$add"; } | crontab -u root -
      echo "В cron добавлено:"
      sed 's/^/  /' <<<"$add"
    fi
  else
    echo "На старом сервере заданий iof в cron не было. Ночное обслуживание: sudo crontab -e, строка: 0 4 * * * /usr/local/sbin/iof-nightly"
  fi
  rm -f "$BASE/migrate-cron" "$MIGRATE_FILE"

  echo
  echo "Перенос завершён, управляющий сервер теперь этот."
  if [[ -n "$dest" ]]; then
    echo "Старый сервер остался узлом. Его прежние данные iof: $dest, удали их, когда убедишься, что всё работает."
  fi
}

# iof migrate cancel: на старом сервере. Снимает блокировку и убирает с нового сервера iof и копию данных
migrate_cancel() {
  local id peer keep=0 i
  [[ "$(migrate_get role)" == "source" ]] || die "отсюда перенос не начат"
  id="$(migrate_get id)"
  peer="$(migrate_get peer)"
  exec </dev/null
  read_nodes
  # Если новый сервер ещё и узел этого, ключ iof на нём нужен
  for i in "${!N_SSH[@]}"; do
    if ssh_same "${N_SSH[$i]}" "$peer"; then keep=1; fi
  done
  echo "== Убираю копию с $peer"
  # Строку «Ошибки (» панель показывает как «готово с ошибками»
  if ! run_on "$peer" n_migrate_abort "$id" "$keep" "$MIGRATE_INBOX" "$MIGRATE_CRON_RE"; then
    echo "Ошибки (1): $peer недоступен, там могли остаться iof, копия данных и ключ iof. Удали их на нём:"
    echo "  sudo systemctl disable --now iof-web; sudo rm -rf /root/iof /root/.iof-migrate /root/.ssh/iof_ed25519 /root/.ssh/iof_ed25519.pub"
  fi
  rm -f "$MIGRATE_FILE"
  echo "Перенос отменён, этот сервер снова управляющий без ограничений."
}

migrate_status() {
  case "$(migrate_get role)" in
    source)
      echo "Идёт перенос управления отсюда на $(migrate_get peer), начат $(migrate_get started)."
      echo "Изменения здесь заблокированы. Завершить: на новом сервере sudo iof migrate finish. Отменить: sudo iof migrate cancel" ;;
    target)
      echo "Этот сервер принимает управление от $(migrate_get peer), начато $(migrate_get started)."
      echo "Проверь, что все узлы на связи (sudo iof status), затем: sudo iof migrate finish" ;;
    *)
      echo "Переноса нет. Начать: sudo iof migrate start <хост> [ssh_порт]" ;;
  esac
}

cmd_migrate() {
  local action="${1:-status}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    start)  migrate_start "$@" ;;
    finish) migrate_finish "$@" ;;
    cancel) migrate_cancel ;;
    status) migrate_status ;;
    *)      die "используй: iof migrate start | finish | cancel | status" ;;
  esac
}
