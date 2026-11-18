#!/usr/bin/env bash

# Состояние пишется целиком: обрыв записи не должен мешать безопасному повтору.
setup_save_state() {
  local tmp
  tmp="$(mktemp "$BASE/.setup-state.XXXXXX")"
  printf 'mode=%s\nphase=%s\nname=%s\naddr=%s\n' "$1" "$2" "${3:-}" "${4:-}" > "$tmp"
  mv "$tmp" "$BASE/setup.state"
}

# Перенаправленный порт не виден в ss: проверяем также NAT, в том числе публикации Docker.
setup_port_check() {
  local port="$1" used
  have ss || die "нет ss: sudo apt install iproute2"
  if ss -Huln | awk '{print $4}' | grep -qE ":${port}$"; then
    die "UDP-порт $port занят; проверь sudo ss -ulpn и освободи порт либо выбери другой до создания шаблона"
  fi
  used="$( {
    if have iptables; then timeout 10 iptables -w 5 -t nat -S 2>/dev/null | grep -E -- ' -p udp( |$)' | grep -oE -- '--dports? [0-9:,]+' | cut -d' ' -f2 | tr ',' '\n'; fi
    if have nft; then
      timeout 10 nft list ruleset 2>/dev/null | awk '/udp dport/ && /redirect|dnat/ {
        for (i = 1; i <= NF; i++) if ($i == "dport") for (j = i + 1; j <= NF; j++) {
          v = $j; gsub(/[{},;]/, "", v)
          if (v ~ /^[0-9]+(-[0-9]+)?$/) print v; else if (v != "") break
        }
      }'
    fi
    if [[ -f /etc/iof/relay.rules ]]; then awk '$1 == "udp" && NF >= 4 { print $2 }' /etc/iof/relay.rules; fi
  } | tr ':' '-' || true)"
  if awk -F- -v p="$port" 'NF { b = (NF > 1 ? $2 : $1); if (p >= $1 && p <= b) f = 1 } END { exit !f }' <<<"$used"; then
    die "порт $port занят перенаправлением; проверь sudo iptables -t nat -S и повтори setup"
  fi
}

# Первый запуск не раздаёт SSH-ключи и не меняет существующие VPN-конфиги.
cmd_setup() (
  local name=main addr="" title="" port=443 obfs=none only=0 a tpl tmp found=0 out cert key
  local state="$BASE/setup.state" managed="$BASE/hy2-template.yaml" phase="" old_name="" old_addr=""
  local port_set=0 obfs_set=0
  if (( $# == 0 )) && [[ -t 0 ]]; then
    read -r -p 'Этот сервер будет VPN-узлом? [Да/нет]: ' a
    case "$a" in нет|Нет|no|n) only=1 ;; esac
    if (( ! only )); then
      read -r -p 'Имя узла [main]: ' a; name="${a:-main}"
      read -r -p 'Адрес для VPN-клиентов (IPv4 или домен): ' addr
      read -r -p 'Подпись узла [как имя]: ' title
    fi
    read -r -p 'UDP-порт [443]: ' a; port="${a:-443}"
    read -r -p 'Обфускация (none или salamander) [none]: ' a; obfs="${a:-none}"
  fi
  while (( $# )); do
    case "$1" in
      --template-only) only=1; shift ;;
      --name|--addr|--title|--port|--obfs)
        a="$1"; (( $# >= 2 )) || die "после $a нужно значение"
        case "$a" in
          --name) name="$2" ;; --addr) addr="$2" ;; --title) title="$2" ;;
          --port) port="$2"; port_set=1 ;; --obfs) obfs="$2"; obfs_set=1 ;;
        esac
        shift 2 ;;
      *) die "неизвестный аргумент setup: $1" ;;
    esac
  done
  [[ -z "$IOF_ONLY" ]] || die "setup не принимает -n"
  port_ok "$port" || die "UDP-порт должен быть от 1 до 65535"
  [[ "$obfs" == none || "$obfs" == salamander ]] || die "обфускация: none или salamander"
  if (( ! only )); then
    node_name_ok "$name" && (( ${#name} <= 40 )) && [[ "$name" != . && "$name" != .. && "$name" != all ]] || die "неверное имя узла"
    host_ok "$addr" && [[ "${addr,,}" != localhost && "$addr" != 127.* && "$addr" != 0.0.0.0 ]] || die "укажи адрес для VPN-клиентов: sudo iof setup --addr <IPv4 или домен>"
    title="${title:-$name}"
    title_ok "$title" && [[ "$title" != *$'\r'* && "$title" != *$'\t'* ]] || die "неверная подпись узла"
  fi
  migrate_guard
  umask 077
  mkdir -p "$BASE"; chmod 700 "$BASE"
  exec 8>"$BASE/setup.lock"
  flock -n 8 || die "уже идёт начальная настройка, дождись её окончания"
  migrate_guard
  tpl="$(hy2_template_path)"
  if [[ -n "${HY2_TEMPLATE:-}" && ! -f "$tpl" ]]; then
    die "нет явно заданного шаблона $tpl; исправь HY2_TEMPLATE в $ENV_FILE"
  fi
  # Конфликт обнаруживаем до создания шаблона, ключа или записи узла.
  if (( ! only )) && [[ -f "$NODES_FILE" ]] && grep -qE '^[[:space:]]*[^#[:space:]]' "$NODES_FILE"; then
    read_nodes
    for a in "${!N_NAME[@]}"; do
      if [[ "${N_NAME[$a]}" == "$name" && "${N_ADDR[$a]}" == "$addr" && "${N_SSH[$a]}" == local ]]; then
        found=1
      elif [[ "${N_NAME[$a]}" == "$name" || "${N_ADDR[$a]}" == "$addr" || "${N_SSH[$a]}" == local ]]; then
        die "конфликт с узлом ${N_NAME[$a]}; setup не заменяет существующие записи, проверь: sudo iof node list"
      fi
    done
  fi
  if [[ -f "$state" ]]; then
    phase="$(kv_get "$(cat "$state")" phase)"
    old_name="$(kv_get "$(cat "$state")" name)"
    old_addr="$(kv_get "$(cat "$state")" addr)"
  fi
  if (( ! only )) && [[ -f /etc/hysteria/config.yaml ]] && ! systemctl is-active --quiet hysteria-server; then
    [[ "$phase" == installing && "$old_name" == "$name" && "$old_addr" == "$addr" ]] || die "найден остановленный Hysteria2; конфиг сохранён. Проверь: journalctl -u hysteria-server -n 30"
  fi
  if (( ! only )) && [[ ! -f "$tpl" && ! -f /etc/hysteria/config.yaml ]]; then setup_port_check "$port"; fi
  if [[ -f "$tpl" ]]; then
    # Не делаем вид, что новые параметры применились к чужому шаблону.
    if (( port_set )); then
      CONFIG="$tpl"
      [[ "$(n_hy2_port)" == "$port" ]] || die "порт уже задан в $tpl; повтори без --port, шаблон не изменён"
    fi
    if (( obfs_set )); then
      CONFIG="$tpl"
      [[ "${obfs/none/}" == "$(n_yaml_value obfs type)" ]] || die "обфускация уже задана в $tpl; повтори без --obfs, шаблон не изменён"
    fi
    echo "Использую существующий шаблон: $tpl (параметры и секреты сохранены)"
  else
    tmp="$(mktemp "$BASE/.setup-template.XXXXXX")"
    trap 'rm -f -- "${tmp:-}"' EXIT
    {
      printf 'listen: :%s\n\ntls:\n  cert: /etc/hysteria/server.crt\n  key: /etc/hysteria/server.key\n\nauth:\n  type: password\n  password: %s\n' "$port" "$(gen_pass)"
      if [[ "$obfs" == salamander ]]; then
        printf '\nobfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$(gen_pass)"
      fi
    } > "$tmp"
    mv -n "$tmp" "$managed"
    tpl="$managed"
    echo "Создан шаблон: $tpl (пароли сохранены только в файле)"
  fi
  init_files
  if (( only )); then
    if [[ "$phase" != installing ]]; then
      setup_save_state template-only "done"
    fi
    echo "Шаблон готов. Добавь удалённый сервер на странице «Добавить сервер», затем создай группу Hysteria2."
    return 0
  fi
  # Один TLS-файл без второго никогда не перезаписываем автоматической генерацией.
  CONFIG="$tpl"
  port="$(n_hy2_port)"
  cert="$(n_yaml_value tls cert)"; key="$(n_yaml_value tls key)"
  [[ -n "$cert" && -n "$key" ]] || die "в шаблоне нужны tls.cert и tls.key; ACME мастер не поддерживает"
  if { [[ -e "$cert" ]] && [[ ! -s "$key" ]]; } || { [[ -e "$key" ]] && [[ ! -s "$cert" ]]; }; then
    die "неполная пара сертификат/ключ; восстанови оба файла вручную, существующие файлы сохранены"
  fi
  if [[ ! -f /etc/hysteria/config.yaml ]]; then setup_port_check "$port"; fi
  if (( ! found )); then
    tmp="$(mktemp "$BASE/.setup-nodes.XXXXXX")"
    cat "$NODES_FILE" > "$tmp"
    printf '\n%s | %s | local | %s\n' "$name" "$addr" "$title" >> "$tmp"
    mv "$tmp" "$NODES_FILE"
  fi
  setup_save_state local installing "$name" "$addr"
  # Сохраняющий режим установщика не меняет даже остановленный существующий конфиг.
  out="$(run_on local n_hy2_install "$(base64 -w0 "$tpl")" "${HY2_CN:-bing.com}" 0 preserve)" || die "установка прервалась; повтори sudo iof setup --name $name --addr $addr; подробности выше"
  [[ "$out" == *installed* || "$out" == *skip* ]] || die "неожиданный результат установки Hysteria2"
  CONFIG=/etc/hysteria/config.yaml
  port="$(n_hy2_port)"
  systemctl is-active --quiet hysteria-server && ss -Huln | awk '{print $4}' | grep -qE ":${port}$" || die "Hysteria2 не слушает UDP $port; проверь journalctl -u hysteria-server -n 30 и повтори setup"
  setup_save_state local "done" "$name" "$addr"
  echo "Готово: узел $name, Hysteria2 работает, UDP $port."
  echo "Открой UDP $port в файрволе провайдера. Активный UFW на сервере настраивается установщиком; другие правила firewall мастер не меняет. Доступность извне ещё не проверена."
  echo 'Создай группу на странице Hysteria2 или командой: sudo iof hy2 add "Мои устройства"'
)
