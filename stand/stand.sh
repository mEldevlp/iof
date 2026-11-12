#!/usr/bin/env bash

# Тестовый стенд iof на Docker: «серверы» Ubuntu 24.04 с systemd и SSH в своей сети 172.30.0.0/24.
#   old   172.30.0.10  управляющий сервер и VPN-узел, SSH с компьютера: 127.0.0.1:2201
#   node1 172.30.0.11  узел, 2202
#   node2 172.30.0.12  узел, 2203
#   new   172.30.0.20  чистый сервер для проверки переноса управления, 2204
# Пароль root везде stand. Запуск из WSL Ubuntu или Linux с Docker Engine (systemd в контейнерах),
# из Git Bash — если работает Docker Desktop. WSL гасит Ubuntu вместе с Docker, когда в ней нет
# открытых сессий: пока стенд нужен, держи окно Ubuntu открытым.
#
#   bash stand/stand.sh up [сервер...]   собрать образ и поднять серверы (по умолчанию все, CI: old node1)
#   bash stand/stand.sh setup         поставить iof на old из рабочей копии, подключить поднятые node1
#                                     и node2, Hysteria2, группу ссылок, задания cron, терминал в панели,
#                                     python3 на node1 для мишеней проверки с ПК
#   bash stand/stand.sh test [сервер] проверить, что iof работает (stand/test.sh); сервер — управляющий,
#                                     по умолчанию old
#   bash stand/stand.sh sync [сервер] обновить iof из рабочей копии (по умолчанию на old и new, где он стоит)
#   bash stand/stand.sh tunnel        туннели к панелям: old -> http://127.0.0.1:8081/, new -> :8082
#   bash stand/stand.sh probe start|show|stop   VPN-клиент на node2 через Hysteria2 на old и проверка
#                                     связи раз в 2 секунды: видно, рвётся ли она при переносе
#   bash stand/stand.sh pc on [сервер] | pc off   проверка с ПК (iof audit probe) с Windows против
#                                     стенда: пробросы с адреса WSL к мишеням и Hysteria2 серверов,
#                                     печатает $env:IOF_PROBE_MAP для probe.ps1; сервер — управляющий
#   bash stand/stand.sh iof old status   команда iof на сервере
#   bash stand/stand.sh sh old        оболочка на сервере
#   bash stand/stand.sh down          убрать серверы (образ остаётся)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
# Ключ для туннелей к панелям. В домашней папке, а не в репозитории: на /mnt/c из WSL у файлов
# права 777, и ssh такой ключ не берёт
KEY="$HOME/.iof-stand/id_ed25519"
SERVERS=(old node1 node2 new)
# Git Bash иначе превращает /opt/iof в аргументах docker в путь Windows
export MSYS_NO_PATHCONV=1

die() { echo "Ошибка: $*" >&2; exit 1; }
dc()  { (cd "$DIR" && docker compose "$@"); }
on()  { local s="$1"; shift; dc exec -T "$s" "$@"; }

# Скрипт со stdin выполняется на сервере из файла: при bash -s команды внутри могли бы
# прочитать из stdin остаток самого скрипта
run_script() {
  local s="$1"
  on "$s" bash -c 'cat > /root/.stand-script.sh'
  on "$s" bash /root/.stand-script.sh </dev/null
}

# Поднятые серверы стенда в порядке SERVERS, по одному в строке
running() {
  local up s
  up="$(dc ps --services --status running)"
  for s in "${SERVERS[@]}"; do
    if grep -qx "$s" <<<"$up"; then echo "$s"; fi
  done
}

# Ждёт, пока на сервере поднимутся systemd и sshd
wait_ready() {
  local s="$1"
  for _ in $(seq 1 60); do
    if [[ "$(on "$s" systemctl is-active ssh 2>/dev/null || true)" == "active" ]]; then return 0; fi
    sleep 1
  done
  die "$s не поднялся: bash stand/stand.sh sh $s, затем systemctl --failed"
}

# Рабочая копия репозитория в /opt/iof на сервере, вместе с .git: iof migrate ставит iof на новый сервер из клона
push_src() {
  local s="$1"
  tar -cf - -C "$ROOT" --exclude=./.claude --exclude=./stand/.ssh . \
    | on "$s" bash -c 'rm -rf /opt/iof && mkdir -p /opt/iof && tar -xf - -C /opt/iof && chown -R root:root /opt/iof && chmod -R u=rwX,go=rX /opt/iof'
}

# Ключ для туннелей с этого компьютера в authorized_keys root на всех поднятых серверах
ensure_key() {
  local s
  if [[ ! -f "$KEY" ]]; then
    mkdir -p "$(dirname "$KEY")"
    ssh-keygen -q -t ed25519 -N "" -C "iof-stand" -f "$KEY"
  fi
  for s in $(running); do
    on "$s" bash -c 'umask 077; mkdir -p /root/.ssh; k="$(cat)"; touch /root/.ssh/authorized_keys
      grep -qxF "$k" /root/.ssh/authorized_keys || printf "%s\n" "$k" >> /root/.ssh/authorized_keys' < "$KEY.pub"
  done
}

# Без аргументов поднимает все серверы, иначе только названные: CI поднимает old и node1
cmd_up() {
  local s list=("$@")
  if (( ${#list[@]} == 0 )); then list=("${SERVERS[@]}"); fi
  for s in "${list[@]}"; do
    [[ " ${SERVERS[*]} " == *" $s "* ]] || die "нет сервера $s, есть: ${SERVERS[*]}"
  done
  dc build
  dc up -d "${list[@]}"
  for s in "${list[@]}"; do wait_ready "$s"; done
  ensure_key
  echo "Стенд поднят: ${list[*]}. Дальше: bash stand/stand.sh setup"
}

cmd_setup() {
  local up n nodes=()
  up="$(running)"
  grep -qx old <<<"$up" || die "old не поднят, сначала: bash stand/stand.sh up"
  # Подключаются только поднятые узлы
  for n in node1:11 node2:12; do
    if grep -qx "${n%%:*}" <<<"$up"; then nodes+=("$n"); fi
  done
  # Мишеням проверки с ПК нужен python3: на node1 он ставится, на node2 нет. Так стенд проверяет оба
  # случая, а new остаётся чистым сервером для переноса
  if grep -qx node1 <<<"$up"; then
    echo "== node1: python3 для мишеней проверки с ПК"
    run_script node1 <<'EOS'
command -v python3 >/dev/null || { apt-get update -qq >/dev/null && apt-get install -y -qq python3 >/dev/null; }
EOS
  fi
  push_src old
  { printf 'NODES="%s"\n' "${nodes[*]}"; cat; } <<'EOS' | run_script old
set -euo pipefail
echo "== old: пакеты и iof"
apt-get update -qq >/dev/null
# nftables: с ним Hysteria2 ставит правила смены портов через nft (в ядре WSL нет fib для IPv6,
# и iof переходит на iptables), на остальных узлах — через iptables. Так test проверяет оба пути
apt-get install -y -qq git python3 qrencode sshpass nftables >/dev/null
bash /opt/iof/install.sh

echo "== old: шаблон Hysteria2 и nodes.conf"
mkdir -p /etc/hysteria /root/iof
chmod 700 /root/iof
[[ -f /etc/hysteria/config.yaml ]] || cp /opt/iof/stand/hy2-template.yaml /etc/hysteria/config.yaml
[[ -f /root/iof/nodes.conf ]] || printf 'old | 172.30.0.10 | local | Old\n' > /root/iof/nodes.conf
# Мишени проверки с ПК на одном порту: stand.sh pc on пробрасывает к нему порты с адреса WSL
grep -q '^PROBE_PORTS=' /root/iof/iof.env 2>/dev/null || (umask 077; echo 'PROBE_PORTS=47000' >> /root/iof/iof.env)

echo "== old: терминал в панели (IOF_WEB_TERMINAL=1)"
if ! grep -qx 'IOF_WEB_TERMINAL=1' /root/iof/web.env 2>/dev/null; then
  (umask 077; echo 'IOF_WEB_TERMINAL=1' >> /root/iof/web.env)
  systemctl restart iof-web
fi

for n in $NODES; do
  name="${n%%:*}"
  if ! grep -q "^$name " /root/iof/nodes.conf; then
    echo "== old: iof node add $name"
    printf 'stand\n' | iof node add "$name" "172.30.0.${n#*:}" "Node ${name#node}" --password-stdin
  fi
done

echo "== old: iof hy2 install all"
iof hy2 install all
if ! iof hy2 list | grep -q 'Stand'; then iof hy2 add "Stand" >/dev/null; fi

# Задания cron, которые должны переехать при переносе
{ crontab -l 2>/dev/null | grep -v iof || true
  echo '0 4 * * * /usr/local/sbin/iof-nightly'
  echo '*/5 * * * * /usr/local/bin/iof check >/dev/null 2>&1'
} | crontab -

echo
iof status
EOS
  echo
  echo "Готово. Панель old: bash stand/stand.sh tunnel, затем http://127.0.0.1:8081/"
}

cmd_sync() {
  local s
  local targets=("$@")
  if (( ${#targets[@]} == 0 )); then targets=(old new); fi
  for s in "${targets[@]}"; do
    if [[ $# -eq 0 ]] && ! on "$s" test -x /usr/local/bin/iof; then continue; fi
    echo "== $s"
    push_src "$s"
    on "$s" bash /opt/iof/install.sh
  done
}

cmd_tunnel() {
  ensure_key
  local opts=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ExitOnForwardFailure=yes -N)
  echo "Панель old: http://127.0.0.1:8081/   панель new: http://127.0.0.1:8082/   (Ctrl+C — закрыть)"
  ssh "${opts[@]}" -p 2201 -L 8081:127.0.0.1:8088 root@127.0.0.1 &
  ssh "${opts[@]}" -p 2204 -L 8082:127.0.0.1:8088 root@127.0.0.1 &
  wait
}

# Клиент Hysteria2 на node2 подключается к old и раз в 2 секунды открывает страницу через туннель
cmd_probe() {
  case "${1:-show}" in
    start)
      run_script node2 <<'EOS'
set -euo pipefail
command -v hysteria >/dev/null || { echo "на node2 нет hysteria, сначала: bash stand/stand.sh setup" >&2; exit 1; }
cat > /root/stand-client.yaml <<'EOF'
server: 172.30.0.10:443
auth: stand-hy2-password
tls:
  sni: bing.com
  insecure: true
socks5:
  listen: 127.0.0.1:1080
EOF
systemctl stop stand-client stand-probe 2>/dev/null || true
systemctl reset-failed stand-client stand-probe 2>/dev/null || true
: > /var/log/stand-probe.log
systemd-run -q --unit=stand-client /usr/local/bin/hysteria client -c /root/stand-client.yaml
systemd-run -q --unit=stand-probe /bin/bash -c 'while :; do
  if curl -s -o /dev/null -m 5 --socks5-hostname 127.0.0.1:1080 http://connectivitycheck.gstatic.com/generate_204; then r=ok; else r=FAIL; fi
  echo "$(date +%T) $r" >> /var/log/stand-probe.log; sleep 2; done'
echo "Клиент запущен: node2 -> Hysteria2 на old (172.30.0.10:443). Журнал: bash stand/stand.sh probe show"
EOS
      ;;
    show)
      on node2 bash -c 'f=/var/log/stand-probe.log; [[ -f $f ]] || { echo "клиент не запускался"; exit 0; }
        tail -n 5 "$f"; echo "проверок: $(wc -l < "$f"), ok: $(grep -c " ok$" "$f" || true), FAIL: $(grep -c FAIL "$f" || true)"' ;;
    stop)
      on node2 systemctl stop stand-client stand-probe 2>/dev/null || true ;;
    *) die "используй: probe start | show | stop" ;;
  esac
}

# Проверка с ПК против стенда с Windows. UDP с Windows доходит до WSL только по адресу WSL (через
# 127.0.0.1 пересылается один TCP), а до сети стенда 172.30.0.0/24 не доходит вовсе. pc on ставит
# в WSL DNAT с адреса WSL на сервер стенда .N: порт 470NN на мишень 47000 (TCP и UDP, PROBE_PORTS на
# управляющем сервере), 471NN на Hysteria2 443/udp, и ACCEPT в DOCKER-USER. Контейнеры не
# пересоздаются, права администратора в Windows не нужны. Адрес WSL меняется при её перезапуске:
# тогда pc on заново. Печатает строку для PowerShell
cmd_pc() {
  local action="${1:-on}" m="${2:-old}" ip s t r oct spec proto port to map=()
  local -A octet=([old]=10 [node1]=11 [node2]=12 [new]=20)
  [[ "$action" == "on" || "$action" == "off" ]] || die "используй: pc on [управляющий сервер] | pc off"
  for t in nat:PREROUTING filter:DOCKER-USER; do
    while IFS= read -r r; do
      # shellcheck disable=SC2086 # правило из iptables -S в слова
      iptables -w -t "${t%%:*}" ${r/#-A/-D}
    done < <(iptables -w -t "${t%%:*}" -S "${t#*:}" 2>/dev/null | grep -- '--comment iof-stand-pc' || true)
  done
  if [[ "$action" == "off" ]]; then echo "Пробросы для проверки с ПК убраны"; return 0; fi
  ip="$(ip -4 -o addr show eth0 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1 | head -n 1)"
  [[ -n "$ip" ]] || die "нет адреса на eth0: pc on запускается в WSL"
  for s in $(running); do
    oct="${octet[$s]}"
    for spec in "tcp $((47000 + oct)) 47000" "udp $((47000 + oct)) 47000" "udp $((47100 + oct)) 443"; do
      read -r proto port to <<<"$spec"
      iptables -w -t nat -A PREROUTING -i eth0 -p "$proto" --dport "$port" -m comment --comment iof-stand-pc \
        -j DNAT --to-destination "172.30.0.$oct:$to"
    done
    map+=("$s=$ip:$((47000 + oct)):$((47100 + oct))")
  done
  iptables -w -I DOCKER-USER -m conntrack --ctstate DNAT -m comment --comment iof-stand-pc -j ACCEPT
  on "$m" bash -c 'f=/root/iof/iof.env; grep -q "^PROBE_PORTS=" "$f" 2>/dev/null || (umask 077; echo PROBE_PORTS=47000 >> "$f")'
  echo "Пробросы с $ip готовы, мишени на $m: PROBE_PORTS=47000. В PowerShell на Windows перед запуском скрипта:"
  echo "\$env:IOF_PROBE_MAP = \"$(IFS=,; echo "${map[*]}")\""
}

case "${1:-}" in
  up)     shift; cmd_up "$@" ;;
  setup)  cmd_setup ;;
  test)   shift; exec bash "$DIR/test.sh" "$@" ;;
  sync)   shift; cmd_sync "$@" ;;
  tunnel) cmd_tunnel ;;
  probe)  shift; cmd_probe "$@" ;;
  pc)     shift; cmd_pc "$@" ;;
  iof)    shift; s="${1:?укажи сервер}"; shift; on "$s" iof "$@" ;;
  sh)     dc exec "${2:?укажи сервер}" bash ;;
  down)   dc down ;;
  *)      sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
