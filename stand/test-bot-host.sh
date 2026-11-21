#!/usr/bin/env bash

# Перенос Telegram-бота на отдельных Ubuntu-контейнерах из образа iof-stand.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NET="iof-bot-$$"
CONTROL="$NET-control"
FIRST="$NET-first"
SECOND="$NET-second"
export MSYS_NO_PATHCONV=1

cleanup() {
  local rc=$?
  if (( rc )); then
    docker exec "$CONTROL" journalctl -u iof-web -n 25 --no-pager || true
  fi
  docker rm -f "$CONTROL" "$FIRST" "$SECOND" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$NET" >/dev/null
for c in "$CONTROL" "$FIRST" "$SECOND"; do
  docker run -d --name "$c" --hostname "$c" --network "$NET" --privileged --cgroupns=host \
    --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$ROOT:/opt/iof:ro" iof-stand >/dev/null
done
containers=()
for c in "$CONTROL" "$FIRST" "$SECOND"; do
  docker exec "$c" bash -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends python3 >/dev/null' &
  containers+=("$!")
done
for p in "${containers[@]}"; do wait "$p"; done

ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
control_ip="$(ip "$CONTROL")"
first_ip="$(ip "$FIRST")"
second_ip="$(ip "$SECOND")"
docker exec -i "$CONTROL" bash -s -- "$control_ip" "$first_ip" "$second_ip" <<'SH'
set -euo pipefail
mkdir -m 700 -p /root/iof /root/.ssh
ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/iof_ed25519
printf 'first | %s | root@%s | Первый узел\nsecond | %s | root@%s | Второй узел\n' "$2" "$2" "$3" "$3" > /root/iof/nodes.conf
printf 'IOF_TG_API=http://%s:8089\n' "$1" > /root/iof/web.env
systemd-run --quiet --unit=fake-tg python3 /opt/iof/stand/fake-tg.py --listen 0.0.0.0:8089 --max-wait 2
bash /opt/iof/install.sh >/dev/null
printf '%s\n' iof-stand-panel | iof web reset-password --password-stdin >/dev/null
SH
for c in "$FIRST" "$SECOND"; do
  docker exec "$CONTROL" cat /root/.ssh/iof_ed25519.pub \
    | docker exec -i "$c" bash -c 'umask 077; mkdir -p /root/.ssh; cat >> /root/.ssh/authorized_keys'
done
# Тот же путь SSH с sudo -n, который iof использует для узлов с входом не под root.
docker exec "$SECOND" bash -c '
  set -e
  useradd -m -s /bin/bash iofoperator
  install -d -o iofoperator -g iofoperator -m 700 /home/iofoperator/.ssh
  install -o iofoperator -g iofoperator -m 600 /root/.ssh/authorized_keys /home/iofoperator/.ssh/authorized_keys
  echo "iofoperator ALL=(root) NOPASSWD: ALL" > /etc/sudoers.d/iof-test-operator'
docker exec "$CONTROL" sed -i 's/| root@\([^|]*\) | Второй/| iofoperator@\1 | Второй/' /root/iof/nodes.conf

run_test() {
  docker exec "$CONTROL" python3 /opt/iof/stand/test-bot-host.py "$1" "$control_ip" "$first_ip" "$second_ip"
}
run_test before-reboot
docker exec "$FIRST" stat -c '%a' /run/iof-bot/bot.token | grep -qx 600
docker exec "$SECOND" test ! -e /run/iof-bot/bot.token
docker restart "$FIRST" >/dev/null
run_test after-reboot
docker exec "$FIRST" test ! -e /run/iof-bot/bot.token
docker exec "$SECOND" test ! -e /run/iof-bot/bot.token
