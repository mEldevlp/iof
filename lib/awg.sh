#!/usr/bin/env bash

# AmneziaWG 2.0: iof awg ...
# Клиент = папка $AWG_LINKS/<логин> с конфигами по узлам (France.conf), публичными ключами
# (France.pub: "ключ контейнер") и ключами vpn:// в keys.txt.

awg_dir_for() {
  local label="$1"
  if node_name_ok "$label" && [[ "$label" != . && "$label" != .. && -d "$AWG_LINKS/$label" ]]; then
    printf '%s' "$AWG_LINKS/$label"
  else
    printf '%s' "$AWG_LINKS/$(name_for "$label")"
  fi
}

awg_label_for() {
  local dir="$1" name l
  name="$(basename "$dir")"
  l="$(awk -F'\t' -v n="$name" '$1==n{print $2; exit}' "$AWG_INDEX" 2>/dev/null || true)"
  printf '%s' "${l:-$name}"
}

# Создаёт клиента на узле, если для этого узла ещё нет конфига. Печатает skip или created
awg_add_job() {
  local i="$1" f cfg
  umask 077
  f="$AWG_ADD_DIR/$(node_file_name "$i")"
  if [[ -s "$f" ]]; then
    echo "skip"
    return 0
  fi
  cfg="$(run_on "${N_SSH[$i]}" n_awg_add "$AWG_ADD_LABEL" "${N_ADDR[$i]}")" || return $?
  [[ "$cfg" == IOF\ * && "$cfg" == *"[Interface]"* ]] || { echo "сервер вернул неожиданный ответ" >&2; return 1; }
  printf '%s\n' "${cfg%%$'\n'*}" | cut -d' ' -f2- > "${f%.conf}.pub" || return 1
  printf '%s\n' "${cfg#*$'\n'}" > "$f.tmp" && chmod 600 "$f.tmp" "${f%.conf}.pub" && mv -f "$f.tmp" "$f" || return 1
  echo "created"
}

awg_add() {
  local label="${1:-}"
  [[ -n "$label" ]] || die "укажи имя клиента: iof awg add \"Мама iPhone\""
  shift
  if [[ "$label" == *[[:cntrl:]]* || "$label" == *'|'* ]]; then die "имя содержит недопустимые символы"; fi
  read_nodes
  local name dir i existing ok=0 skipped=0 failed=() noawg=() targets=("$@")
  if (( ${#targets[@]} == 0 )); then targets=("${!N_NAME[@]}"); fi
  name="$(name_for "$label")"
  dir="$AWG_LINKS/$name"
  existing="$(awk -F'\t' -v n="$name" '$1==n{print $2; exit}' "$AWG_INDEX" 2>/dev/null || true)"
  if [[ -n "$existing" && "$existing" != "$label" ]]; then
    die "имя уже используется другим клиентом, выбери другое"
  fi
  mkdir -p "$dir" && chmod 700 "$AWG_LINKS" "$dir" || die "не удалось подготовить каталог клиента"
  AWG_ADD_DIR="$dir"
  AWG_ADD_LABEL="$label"

  echo "Создаю клиента на узлах: ${#targets[@]}" >&2
  pmap awg_add_job "${targets[@]}"
  for i in "${targets[@]}"; do
    if pm_ok "$i"; then
      ok=$((ok + 1))
      if [[ "$(pm_out "$i")" == "skip" ]]; then skipped=$((skipped + 1)); fi
    elif pm_err "$i" | grep -q 'не найден контейнер AmneziaWG'; then
      noawg+=("${N_NAME[$i]}")
    else
      failed+=("$i")
    fi
  done

  if (( ok == 0 )); then
    rmdir "$dir" 2>/dev/null || true
    if (( ${#failed[@]} > 0 )); then report_failures "${failed[@]}"; fi
    if (( ${#noawg[@]} == ${#targets[@]} )); then die "сначала установи AmneziaWG хотя бы на одном узле"; fi
    die "ни один сервер не создал клиента"
  fi
  index_set "$AWG_INDEX" "$name" "$label" || die "не удалось записать список клиентов"

  echo
  awg_build_keys "$dir"
  echo "Клиент: $name"
  echo
  echo "Клиент AWG: $label (готов на $ok узлах, из них раньше созданных: $skipped)"
  echo "Каждый ключ выше вставь в Amnezia VPN: + , затем Вставить ключ."
  echo "Снова показать ключи:         sudo iof awg keys \"$label\""
  echo "Файлы .conf для WinSCP:       sudo iof awg export \"$label\""
  if (( ${#noawg[@]} > 0 )); then
    echo "Без AmneziaWG, пропущены (${#noawg[@]}): ${noawg[*]}"
  fi
  if (( ${#failed[@]} > 0 )); then
    echo
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
    echo "Когда починишь, повтори команду, готовые конфиги не пересоздадутся."
  fi
}

awg_install_job() { run_on "${N_SSH[$1]}" n_awg_install "$AWG_INSTALL_PORT"; }

awg_install() {
  local i port="" name label created
  local args=() ready=() failed=()
  while (( $# )); do
    case "$1" in
      --) shift; args+=("$@"); break ;;
      --port)
        port_ok "${2:-}" || die "порт должен быть от 1 до 65535"
        port="$((10#$2))"
        shift
        ;;
      -*) die "неизвестный параметр установки: $1" ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  (( ${#args[@]} > 0 )) || die "укажи узлы: iof awg install <узлы|all> [--port 51820]"
  read_nodes
  select_nodes "${args[@]}"
  AWG_INSTALL_PORT="$port"
  echo "Устанавливаю AmneziaWG 2.0 на узлах: ${#SEL[@]}, одновременно до $PARALLEL"
  pmap awg_install_job "${SEL[@]}"
  for i in "${SEL[@]}"; do
    if pm_ok "$i"; then
      ready+=("$i")
      printf '  %s: %s\n' "${N_NAME[$i]}" "$(pm_out "$i" | tail -n 1)"
    else
      failed+=("$i")
    fi
  done
  if (( ${#failed[@]} )); then
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
  fi
  (( ${#ready[@]} )) || die "ни на одном узле AmneziaWG не заработал"
  [[ -s "$AWG_INDEX" ]] || return 0
  echo "Добавляю готовые узлы к существующим клиентам AmneziaWG"
  while IFS=$'\t' read -r name label created; do
    if ! (AWG_QUIET_KEYS=1 awg_add "$label" "${ready[@]}"); then
      echo "Не удалось обновить: $label"
    fi
  done < "$AWG_INDEX"
}

# Ключ vpn:// в формате приложения Amnezia VPN из готового .conf: <файл> <публичный ключ> <контейнер> <название>.
# Формат: 4 байта длины JSON (big-endian) + zlib(JSON), всё в base64url без "="
awg_make_key() {
  python3 -c '
import base64, json, struct, sys, zlib

path, pub, container, title = sys.argv[1:5]
iface, peer, sec = {}, {}, None
for line in open(path, encoding="utf-8"):
    s = line.strip()
    if s.startswith("["):
        sec = s
        continue
    if not s or s.startswith("#") or "=" not in s:
        continue
    k, v = s.split("=", 1)
    (iface if sec == "[Interface]" else peer)[k.strip()] = v.strip()

ip = iface["Address"].split("/")[0]
dns = [d.strip() for d in iface.get("DNS", "1.1.1.1, 1.0.0.1").split(",") if d.strip()]
host, port = peer["Endpoint"].rsplit(":", 1)
names = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1", "I2", "I3", "I4", "I5"]
params = {k: iface[k] for k in names if iface.get(k)}

priv = iface["PrivateKey"]
srv = peer["PublicKey"]
psk = peer["PresharedKey"]
lines = ["[Interface]", f"Address = {ip}/32", "DNS = $PRIMARY_DNS, $SECONDARY_DNS", f"PrivateKey = {priv}"]
lines += [f"{k} = {params[k]}" for k in names if k in params]
lines += ["", "[Peer]", f"PublicKey = {srv}", f"PresharedKey = {psk}",
          "AllowedIPs = 0.0.0.0/0, ::/0", f"Endpoint = {host}:{port}", "PersistentKeepalive = 25", ""]

last = dict(params)
last.update({
    "allowed_ips": ["0.0.0.0/0", "::/0"],
    "clientId": pub,
    "client_ip": ip,
    "client_priv_key": priv,
    "client_pub_key": pub,
    "config": "\n".join(lines),
    "hostName": host,
    "mtu": "1376",
    "persistent_keep_alive": "25",
    "port": int(port),
    "psk_key": psk,
    "server_pub_key": srv,
})
awg = dict(params)
awg.update({
    "last_config": json.dumps(last, indent=4, ensure_ascii=False, sort_keys=True),
    "port": port,
    "subnet_address": ip.rsplit(".", 1)[0] + ".0",
    "subnet_cidr": "24",
    "transport_proto": "udp",
})
if container == "amnezia-awg2":
    awg["protocol_version"] = "2"
root = {
    "containers": [{"awg": awg, "container": container}],
    "defaultContainer": container,
    "description": title,
    "dns1": dns[0] if dns else "1.1.1.1",
    "dns2": dns[1] if len(dns) > 1 else (dns[0] if dns else "1.0.0.1"),
    "hostName": host,
    "nameOverriddenByUser": True,
}
data = json.dumps(root, indent=4, ensure_ascii=False, sort_keys=True).encode()
blob = struct.pack(">I", len(data)) + zlib.compress(data, 8)
print("vpn://" + base64.urlsafe_b64encode(blob).decode().rstrip("="))
' "$1" "$2" "$3" "$4"
}

# Печатает ключи vpn:// для всех конфигов клиента (узлы и ретрансляторы) и сохраняет в keys.txt
awg_build_keys() {
  local dir="$1" i f meta pub container title priv out key
  local failed=0
  umask 077
  have python3 || die "нужен python3"
  read_nodes
  out="$dir/keys.txt"
  : > "$out.tmp" && chmod 600 "$out.tmp" || die "не удалось подготовить файл ссылок"
  for i in "${!N_NAME[@]}"; do
    f="$dir/$(node_file_name "$i")"
    [[ -s "$f" ]] || continue
    title="${N_TITLE[$i]:-${N_NAME[$i]}}"
    # Для клиентов, созданных до появления .pub, ключ вычисляется на узле
    if [[ ! -s "${f%.conf}.pub" ]]; then
      priv="$(awk -F'=' '/^[[:space:]]*PrivateKey[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$f")"
      if meta="$(run_on "${N_SSH[$i]}" n_awg_pubkey "$priv" 2>/dev/null)" && [[ -n "$meta" ]]; then
        printf '%s\n' "$meta" > "${f%.conf}.pub"
        chmod 600 "${f%.conf}.pub"
      else
        echo "== $title: не удалось получить публичный ключ, сервер недоступен" >&2
        failed=$((failed + 1))
        continue
      fi
    fi
    read -r pub container < "${f%.conf}.pub"
    if key="$(awg_make_key "$f" "$pub" "${container:-amnezia-awg2}" "$title")"; then
      printf '%s\n%s\n\n' "== $title" "$key" >> "$out.tmp" || die "не удалось записать ссылку"
    else
      echo "== $title: не удалось собрать ключ" >&2
      failed=$((failed + 1))
    fi
  done

  # Конфиги через ретрансляторы: конфиг узла с Endpoint ретранслятора, пересоздаются каждый раз
  local r ni vi base rf
  rm -f "$dir"/*_via_*.conf
  read_relays
  for r in "${!R_NODE[@]}"; do
    ni="$(node_index "${R_NODE[$r]}")" || continue
    vi="$(node_index "${R_VIA[$r]}")" || continue
    [[ "${R_AWL[$r]}" != "-" ]] || continue
    f="$dir/$(node_file_name "$ni")"
    [[ -s "$f" && -s "${f%.conf}.pub" ]] || continue
    base="$(node_file_name "$vi")"
    rf="${f%.conf}_via_${base%.conf}.conf"
    sed -E "s#^[[:space:]]*Endpoint[[:space:]]*=.*#Endpoint = ${N_ADDR[$vi]}:${R_AWL[$r]}#" "$f" > "$rf"
    chmod 600 "$rf"
    title="$(node_title "$ni") via $(node_title "$vi")"
    read -r pub container < "${f%.conf}.pub"
    if key="$(awg_make_key "$rf" "$pub" "${container:-amnezia-awg2}" "$title")"; then
      printf '%s\n%s\n\n' "== $title" "$key" >> "$out.tmp" || die "не удалось записать ссылку"
    else
      echo "== $title: не удалось собрать ключ" >&2
      failed=$((failed + 1))
    fi
  done
  mv -f "$out.tmp" "$out" || die "не удалось сохранить ссылки"
  if [[ "${AWG_QUIET_KEYS:-}" != 1 ]]; then cat "$out"; fi
  if (( failed )); then echo "Ошибки ($failed): часть ссылок AmneziaWG не собрана" >&2; fi
}

awg_keys() {
  local label="${1:-}" dir
  [[ -n "$label" ]] || die "укажи имя клиента: iof awg keys \"Мама iPhone\""
  dir="$(awg_dir_for "$label")"
  [[ -d "$dir" ]] || die "клиент '$label' не найден, см. iof awg list"
  awg_build_keys "$dir"
  echo "Каждый ключ вставь в Amnezia VPN: + , затем Вставить ключ."
}

# Пересобирает ключи всех клиентов (после смены узлов или ретрансляторов)
awg_refresh() {
  local name label created
  if [[ ! -s "$AWG_INDEX" ]]; then
    echo "AWG: клиентов нет"
    return 0
  fi
  while IFS=$'\t' read -r name label created; do
    if [[ -d "$AWG_LINKS/$name" ]]; then
      awg_build_keys "$AWG_LINKS/$name" >/dev/null
      echo "AWG: ключи для '$label' пересобраны (sudo iof awg keys \"$label\")"
    fi
  done < "$AWG_INDEX"
}

awg_del_job() {
  local i="$1" f pub=""
  f="$AWG_DEL_DIR/$(node_file_name "$i")"
  if [[ -s "${f%.conf}.pub" ]]; then read -r pub _ < "${f%.conf}.pub"; fi
  run_on "${N_SSH[$i]}" n_awg_del "$AWG_DEL_LABEL" "$pub"
}

awg_del() {
  local label="${1:-}"
  [[ -n "$label" ]] || die "укажи имя клиента: iof awg del \"Мама iPhone\""
  read_nodes
  local dir i failed=()
  dir="$(awg_dir_for "$label")"
  AWG_DEL_DIR="$dir"
  AWG_DEL_LABEL="$label"
  if [[ -d "$dir" ]]; then AWG_DEL_LABEL="$(awg_label_for "$dir")"; fi
  pmap awg_del_job "${!N_NAME[@]}"
  for i in "${!N_NAME[@]}"; do
    if pm_ok "$i"; then continue; fi
    if [[ -s "$dir/$(node_file_name "$i")" ]] || ! pm_err "$i" | grep -q 'не найден контейнер AmneziaWG'; then
      failed+=("$i")
    fi
  done
  if (( ${#failed[@]} )); then
    echo "Ошибки (${#failed[@]}):"
    report_failures "${failed[@]}"
    die "удаление не завершено, повтори команду, когда узлы будут доступны"
  fi
  rm -rf "$dir"
  index_set "$AWG_INDEX" "$(basename "$dir")"
  echo "Клиент '$AWG_DEL_LABEL' удалён"
}

# Конфиги клиента и QR-коды, второй аргумент оставляет один узел: iof awg show "Имя" France
awg_show() {
  local label="${1:-}" only="${2:-}" dir f
  [[ -n "$label" ]] || die "укажи имя клиента: iof awg show \"Мама iPhone\" [France]"
  dir="$(awg_dir_for "$label")"
  [[ -d "$dir" ]] || die "клиент '$label' не найден, см. iof awg list"
  for f in "$dir"/*.conf; do
    [[ -f "$f" ]] || continue
    if [[ -n "$only" && "$(basename "$f" .conf)" != "$only" ]]; then continue; fi
    echo "== $(basename "$f" .conf)"
    cat "$f"
    echo
    if have qrencode; then
      qrencode -t ANSIUTF8 < "$f"
    fi
  done
  if ! have qrencode; then echo "Для QR-кодов установи qrencode: sudo apt install -y qrencode"; fi
}

# Копия конфигов и keys.txt в домашнюю папку пользователя, вызвавшего sudo
awg_export() {
  local label="${1:-}" dir user home dest
  [[ -n "$label" ]] || die "укажи имя клиента: iof awg export \"Мама iPhone\""
  dir="$(awg_dir_for "$label")"
  [[ -d "$dir" ]] || die "клиент '$label' не найден, см. iof awg list"
  user="${SUDO_USER:-}"
  [[ -n "$user" && "$user" != "root" ]] || die "запусти через sudo от своего пользователя"
  home="$(getent passwd "$user" | cut -d: -f6)"
  dest="$home/iof-export/$(basename "$dir")"
  mkdir -p "$dest"
  cp "$dir"/*.conf "$dest"/
  if [[ -s "$dir/keys.txt" ]]; then cp "$dir/keys.txt" "$dest"/; fi
  chown -R "$user:" "$home/iof-export"
  chmod 700 "$home/iof-export" "$dest"
  chmod 600 "$dest"/*
  echo "Скопировано в $dest"
  ls -1 "$dest"
  echo "Забери файлы через WinSCP и удали папку: rm -rf ~/iof-export"
}

awg_list() {
  if [[ ! -s "$AWG_INDEX" ]]; then
    echo "Клиентов AWG, созданных через iof, пока нет"
    return 0
  fi
  {
    row "ИМЯ" "СОЗДАН" "КОНФИГИ" "ПАПКА"
    local name label created files
    while IFS=$'\t' read -r name label created; do
      files="$(cd "$AWG_LINKS/$name" 2>/dev/null && ls -1 *.conf 2>/dev/null | sed 's/\.conf$//' | paste -sd, - || true)"
      row "$label" "$created" "${files:--}" "$AWG_LINKS/$name"
    done < "$AWG_INDEX"
  } | table
}

awg_clients_job() { run_on "${N_SSH[$1]}" n_awg_clients; }

# Все клиенты каждого сервера, включая созданные в приложении Amnezia
awg_clients() {
  read_nodes
  select_nodes
  local i
  pmap awg_clients_job "${SEL[@]}"
  for i in "${SEL[@]}"; do
    echo "== ${N_NAME[$i]} (${N_ADDR[$i]})"
    if pm_ok "$i"; then
      { row "АДРЕС" "ИМЯ" "ПОДКЛЮЧАЛСЯ" "КЛЮЧ" "СОСТОЯНИЕ"; pm_out "$i"; } | table
    else
      echo "   не удалось получить список: $(pm_err "$i" | tail -n 1)"
    fi
    echo
  done
}

awg_status() {
  read_nodes
  select_nodes
  local i rows=()
  probe_all "${SEL[@]}"
  rows+=("$(row "УЗЕЛ" "АДРЕС" "СОСТОЯНИЕ" "КЛИЕНТОВ" "ОНЛАЙН (3 мин)")")
  for i in "${SEL[@]}"; do
    if probe_load "$i"; then
      rows+=("$(row "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(cell_awg)" "${P[awg_peers]:--}" "${P[awg_online]:--}")")
    else
      rows+=("$(row "${N_NAME[$i]}" "${N_ADDR[$i]}" "$(c_red "НЕТ СВЯЗИ")" "-" "-")")
    fi
  done
  printf '%s\n' "${rows[@]}" | table
}

cmd_awg() {
  local action="${1:-}"
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    install|add|del|keys|refresh)
      (umask 077; mkdir -p "$AWG_LINKS")
      exec 8>"$AWG_LINKS/.lock"
      flock -w 60 8 || die "другая операция с клиентами AmneziaWG ещё выполняется"
      ;;
  esac
  case "$action" in
    install) awg_install "$@" ;;
    add)     awg_add "${1:-}" ;;
    del)     awg_del "$@" ;;
    keys)    awg_keys "$@" ;;
    show)    awg_show "$@" ;;
    export)  awg_export "$@" ;;
    list)    awg_list ;;
    clients) awg_clients ;;
    refresh) awg_refresh ;;
    status)  awg_status ;;
    *)       die "используй: iof awg install | add | del | keys | show | export | list | clients | refresh | status" ;;
  esac
}
