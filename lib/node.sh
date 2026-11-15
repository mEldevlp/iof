#!/usr/bin/env bash



# Узлы: iof node add | import | del | list

# Раздача ключа iof на узел с индексом $1 в массивах IM_*: вход по паролю (sshpass) или ключом
push_key_job() {
  local j="$1" host="${IM_HOST[$1]}" port="${IM_PORT[$1]}" user="${IM_USER[$1]}" pub cmd err="" rc=0
  pub="$(cat "$SSH_KEY.pub")"
  [[ -n "$pub" ]] || { echo "нет публичного ключа" >&2; return 1; }
  cmd="umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys"
  # Не root: iof выполняет команды через sudo -n, без него ключ класть незачем
  if [[ "$user" != "root" ]]; then cmd="sudo -n true 2>/dev/null || exit 42; $cmd"; fi
  # stderr ssh нужен, чтобы отличить неверный пароль от недоступного сервера
  case "${IM_MODE[$j]}" in
    installed) ;;  # ключ iof положен вручную, остаётся проверка ниже
    key)
      err="$(ssh -i "${IM_KEY[$j]}" -p "$port" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$user@$host" "$cmd" \
        2>&1 >/dev/null)" || rc=$? ;;
    *)
      err="$(SSHPASS="${IM_PASS[$j]}" sshpass -e ssh -p "$port" \
        -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout=10 "$user@$host" "$cmd" \
        2>&1 >/dev/null)" || rc=$? ;;
  esac
  case "$rc" in
    0) ;;
    42) echo "у $user нет sudo без пароля (NOPASSWD), iof с ним работать не сможет" >&2; return 1 ;;
    5) echo "неверный пароль $user" >&2; return 1 ;;
    6) echo "ключ хоста изменился, удали старую запись: ssh-keygen -R $host" >&2; return 1 ;;
    255)
      if [[ "$err" == *"Permission denied"* && "${IM_MODE[$j]}" == "key" ]]; then
        echo "ключ не подходит для $user" >&2
      elif [[ "$err" == *"Permission denied"* ]]; then
        echo "неверный пароль $user или вход по паролю запрещён" >&2
      else
        err="$(grep -v '^Warning: Permanently added' <<<"$err" | tail -n 1 | tr -d '\r')"
        echo "нет связи по SSH${err:+: $err}" >&2
      fi
      return 1 ;;
    *) echo "ошибка входа (код $rc)" >&2; return 1 ;;
  esac
  if ! ssh_cmd "$user@$host:$port" "$(remote_sudo "$user@$host")true" </dev/null >/dev/null 2>&1; then
    if [[ "${IM_MODE[$j]}" != "installed" ]]; then
      echo "вход удался, но ключ iof не работает" >&2
    elif [[ "$user" != "root" ]]; then
      echo "ключ iof не подошёл или у $user нет sudo без пароля (NOPASSWD)" >&2
    else
      echo "нет связи по SSH или ключ iof не добавлен в ~/.ssh/authorized_keys у $user" >&2
    fi
    return 1
  fi
}

ensure_ssh_key() {
  if [[ ! -f "$SSH_KEY" ]]; then
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "iof@$(hostname)" >/dev/null || die "не удалось создать SSH-ключ"
  fi
  [[ -s "$SSH_KEY.pub" ]] || die "нет публичного ключа $SSH_KEY.pub"
}

# sshpass нужен только для входа по паролю
ensure_sshpass() {
  if have sshpass; then return 0; fi
  echo "Ставлю sshpass..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null 2>&1 \
    || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass >/dev/null 2>&1; } \
    || die "не удалось установить sshpass"
}

# Пароль или ключ для первого входа на сервер (iof node add, iof migrate start):
# read_auth <ask|password-stdin|key-file|key-stdin|installed> <файл ключа> <пользователь> <хост>.
# Результат: AUTH_MODE (password, key или installed), AUTH_PASS, AUTH_KEY (временная копия ключа,
# после входа её надо удалить). Варианты со stdin нужны веб-панели: так пароль и ключ не видны
# в списке процессов
read_auth() {
  local auth="$1" keyfile="$2" user="$3" host="$4" tmp
  AUTH_PASS=""
  AUTH_KEY=""
  case "$auth" in
    installed) ;;
    ask)
      read -rsp "Пароль $user для $host: " AUTH_PASS
      echo ;;
    password-stdin)
      IFS= read -r AUTH_PASS || true ;;
    key-file|key-stdin)
      mkdir -p "$BASE"
      tmp="$(mktemp -d "$BASE/.key.XXXXXX")"
      PM_DIRS+=("$tmp")
      AUTH_KEY="$tmp/key"
      # Переводы строк Windows и отсутствие последнего перевода строки ssh не принимает
      if [[ "$auth" == "key-file" ]]; then
        [[ -r "$keyfile" ]] || die "нет файла ключа $keyfile"
        (umask 077; printf '%s\n' "$(tr -d '\r' < "$keyfile")" > "$AUTH_KEY")
      else
        (umask 077; printf '%s\n' "$(tr -d '\r')" > "$AUTH_KEY")
      fi
      if grep -q 'PuTTY-User-Key-File' "$AUTH_KEY"; then
        die "это ключ PuTTY (.ppk). Сконвертируй в PuTTYgen: Conversions -> Export OpenSSH key"
      fi
      grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$AUTH_KEY" || die "нужен приватный ключ OpenSSH (-----BEGIN ... PRIVATE KEY-----), а не .pub"
      ssh-keygen -y -P "" -f "$AUTH_KEY" >/dev/null 2>&1 \
        || die "ключ не читается: защищён паролем или повреждён. Снять пароль: ssh-keygen -p -f <ключ>" ;;
  esac
  # Дальше stdin не нужен: ssh в фоновых задачах не должен его читать
  exec </dev/null
  AUTH_MODE="password"
  if [[ -n "$AUTH_KEY" ]]; then AUTH_MODE="key"; elif [[ "$auth" == "installed" ]]; then AUTH_MODE="installed"; fi
  if [[ "$AUTH_MODE" == "password" && -z "$AUTH_PASS" ]]; then die "пароль пустой"; fi
}

# Раздаёт ключ на узлы из массивов IM_NAME IM_HOST IM_ADDR IM_USER IM_PORT IM_TITLE, способ
# входа в IM_MODE: password (IM_PASS), key (файл ключа в IM_KEY) или installed (ключ iof уже
# положен вручную). Удачные узлы дописывает в nodes.conf.
# Код 0, если добавлен хотя бы один узел
onboard_nodes() {
  local j target ok=0
  local failed=()
  mkdir -p "$BASE"
  chmod 700 "$BASE"
  ensure_ssh_key
  if [[ " ${IM_MODE[*]} " == *" password "* ]]; then ensure_sshpass; fi
  touch "$NODES_FILE"

  echo "Раздаю SSH-ключ на узлы: ${#IM_NAME[@]}, одновременно до $PARALLEL"
  pmap push_key_job "${!IM_NAME[@]}"
  for j in "${!IM_NAME[@]}"; do
    if pm_ok "$j"; then
      target="${IM_USER[$j]}@${IM_HOST[$j]}"
      if [[ "${IM_PORT[$j]}" != "22" ]]; then target="$target:${IM_PORT[$j]}"; fi
      printf '%s | %s | %s | %s\n' "${IM_NAME[$j]}" "${IM_ADDR[$j]}" "$target" "${IM_TITLE[$j]}" >> "$NODES_FILE"
      ok=$((ok + 1))
    else
      failed+=("$j")
    fi
  done
  echo "Добавлено в nodes.conf: $ok"
  if (( ${#failed[@]} > 0 )); then
    echo "Не удалось (${#failed[@]}), в nodes.conf не попали:"
    for j in "${failed[@]}"; do
      printf '  %-20s %-16s %s\n' "${IM_NAME[$j]}" "${IM_HOST[$j]}" "$(pm_err "$j" | tail -n 1)"
    done
  fi
  (( ok > 0 ))
}

# Файл: по строке на сервер "имя | ip | пароль root | подпись | ssh-порт", последние два необязательны
cmd_node_import() {
  local file="${1:-}" name ip pw title port seen=" " n=0
  [[ -n "$file" && -f "$file" ]] || die "укажи файл: iof node import servers.txt"
  N_NAME=()
  if nodes_present; then read_nodes; fi
  IM_NAME=(); IM_HOST=(); IM_ADDR=(); IM_USER=(); IM_MODE=(); IM_PASS=(); IM_KEY=(); IM_TITLE=(); IM_PORT=()
  while IFS='|' read -r name ip pw title port || [[ -n "$name" ]]; do
    name="$(trim "$name")"
    if [[ -z "$name" || "$name" == \#* ]]; then continue; fi
    ip="$(trim "${ip:-}")"
    pw="$(trim "${pw:-}")"
    title="$(trim "${title:-}")"
    port="$(trim "${port:-}")"
    n=$((n + 1))
    node_name_ok "$name" || die "строка $n: имя '$name' — только латиница, цифры, точка, дефис, подчёркивание"
    [[ -n "$ip" && -n "$pw" ]] || die "строка $n ($name): нужны IP и пароль"
    host_ok "$ip" || die "строка $n ($name): '$ip' не похож на IPv4 или имя хоста"
    port_ok "${port:-22}" || die "строка $n ($name): порт '$port' вне 1-65535"
    [[ "$seen" != *" $name "* ]] || die "имя '$name' встречается в файле дважды"
    seen+="$name "
    if node_index "$name" >/dev/null 2>&1; then
      echo "Пропускаю $name: уже есть в nodes.conf"
      continue
    fi
    IM_NAME+=("$name"); IM_HOST+=("$ip"); IM_ADDR+=("$ip"); IM_USER+=("root"); IM_MODE+=("password")
    IM_PASS+=("$pw"); IM_KEY+=(""); IM_TITLE+=("${title:-$name}"); IM_PORT+=("${port:-22}")
  done < "$file"
  (( ${#IM_NAME[@]} > 0 )) || die "в файле нет новых узлов"

  onboard_nodes || true
  echo
  echo "Пароли больше не нужны, удали файл: shred -u $file"
  echo "Дальше: sudo iof hy2 install all"
}

# iof node add <имя> <хост> [подпись] [ssh_порт] [--user имя] [--addr адрес_для_клиентов]
#   [--key файл | --key-stdin | --password-stdin | --key-installed]
# Без них пароль спрашивается в терминале. --key-installed: ключ iof уже добавлен на сервер вручную
cmd_node_add() {
  local pos=() user="root" addr="" auth="ask" keyfile="" name host title port
  while (( $# > 0 )); do
    case "$1" in
      --user|--addr|--key)
        [[ $# -ge 2 ]] || die "после $1 нужно значение"
        case "$1" in
          --user) user="$2" ;;
          --addr) addr="$2" ;;
          --key)  auth="key-file"; keyfile="$2" ;;
        esac
        shift 2 ;;
      --key-stdin)      auth="key-stdin"; shift ;;
      --password-stdin) auth="password-stdin"; shift ;;
      --key-installed)  auth="installed"; shift ;;
      -*) die "неизвестный параметр $1" ;;
      *)  pos+=("$1"); shift ;;
    esac
  done
  name="${pos[0]:-}"; host="${pos[1]:-}"; title="${pos[2]:-}"; port="${pos[3]:-22}"
  addr="${addr:-$host}"
  [[ -n "$name" && -n "$host" ]] || die "используй: iof node add <имя> <хост> [подпись] [ssh_порт] [--user имя] [--key файл]"
  node_name_ok "$name" || die "имя: только латиница, цифры, точка, дефис, подчёркивание"
  host_ok "$host" || die "хост '$host': нужен IPv4 или имя хоста (латиница, цифры, точка, дефис)"
  host_ok "$addr" || die "адрес для клиентов '$addr': нужен IPv4 или имя хоста"
  user_ok "$user" || die "пользователь '$user': строчная латиница, цифры, _ и -"
  port_ok "$port" || die "ssh-порт '$port' вне 1-65535"
  title_ok "$title" || die "подпись не может содержать | и перевод строки"
  N_NAME=()
  if nodes_present; then
    read_nodes
    if node_index "$name" >/dev/null; then die "узел '$name' уже есть"; fi
  fi

  read_auth "$auth" "$keyfile" "$user" "$host"
  IM_NAME=("$name"); IM_HOST=("$host"); IM_ADDR=("$addr"); IM_USER=("$user"); IM_MODE=("$AUTH_MODE")
  IM_PASS=("$AUTH_PASS"); IM_KEY=("$AUTH_KEY"); IM_TITLE=("${title:-$name}"); IM_PORT=("$((10#$port))")
  local rc=0
  onboard_nodes || rc=1
  if [[ -n "$AUTH_KEY" ]] && have shred; then shred -u "$AUTH_KEY" 2>/dev/null || true; fi
  (( rc == 0 )) || exit 1
  echo "Дальше: sudo iof hy2 install $name"
}

# Убирает узел из nodes.conf, сам сервер не трогает
cmd_node_del() {
  local name="${1:-}" r
  [[ -n "$name" ]] || die "используй: iof node del <имя>"
  read_nodes
  node_index "$name" >/dev/null || die "узла '$name' нет"
  read_relays
  for r in "${!R_NODE[@]}"; do
    if [[ "${R_NODE[$r]}" == "$name" || "${R_VIA[$r]}" == "$name" ]]; then
      die "узел участвует в ретрансляторе ${R_NODE[$r]} через ${R_VIA[$r]}, сначала: iof relay del ${R_NODE[$r]} ${R_VIA[$r]}"
    fi
  done
  awk -F'|' -v n="$name" '{ k = $1; gsub(/[[:space:]]/, "", k) } k != n' "$NODES_FILE" > "${NODES_FILE}.tmp"
  mv "${NODES_FILE}.tmp" "$NODES_FILE"
  rm -f "$STATE_DIR/$name" "$RU_DIR/$name"
  echo "Узел $name убран из nodes.conf. Сам сервер не трогал."
  echo "Чтобы убрать его из ссылок и ключей: sudo iof refresh"
}

cmd_node_list() {
  read_nodes
  local i
  {
    row "ИМЯ" "АДРЕС" "SSH" "ПОДПИСЬ"
    for i in "${!N_NAME[@]}"; do
      row "${N_NAME[$i]}" "${N_ADDR[$i]}" "${N_SSH[$i]}" "${N_TITLE[$i]}"
    done
  } | table
  echo
  echo "Всего узлов: ${#N_NAME[@]}"
}

cmd_node() {
  local action="${1:-list}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    add)    cmd_node_add "$@" ;;
    import) cmd_node_import "$@" ;;
    del)    cmd_node_del "$@" ;;
    list)   cmd_node_list ;;
    *)      die "используй: iof node add | import | del | list" ;;
  esac
}
