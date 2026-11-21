#!/usr/bin/env bash

# HTTPS и SSH-туннель на отдельном сервере стенда, с собственной парой ключей и локальным DNS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="iof-test-web-$$"
export MSYS_NO_PATHCONV=1
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$NAME" --hostname panel --privileged --cgroupns=host \
  --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$ROOT:/src:ro" iof-stand >/dev/null

docker exec -i "$NAME" bash -s <<'SH'
set -euo pipefail
apt-get update -qq
apt-get install -y -qq python3 git nginx >/dev/null
ip=$(hostname -I | awk '{print $1}')
printf '%s panel.test\n' "$ip" >> /etc/hosts
umask 077
mkdir -p /root/iof /opt/iof /root/.ssh
cp -r /src/{build.sh,install.sh,iof.sh,iof-nightly,lib,web} /opt/iof/
# Локальный Git-источник позволяет выполнить штатный iof update без сети и публикации.
git init -q -b master --bare /tmp/iof-origin
git -C /opt/iof init -q -b master
git -C /opt/iof add .
git -C /opt/iof -c user.name='Стенд iof' -c user.email='iof@localhost' commit -qm 'Копия для проверки'
git -C /opt/iof remote add origin /tmp/iof-origin
git -C /opt/iof push -qu origin master

printf 'IOF_WEB_HOSTS=panel.test,%s\nIOF_WEB_TERMINAL=1\nIOF_WEB_PASSWORD="Прежний пароль iof"\n' "$ip" > /root/iof/web.env
printf 'IOF_RELEASE_API=file:///run/iof-test-release.json\n' >> /root/iof/web.env
printf 'panel | %s | local | Панель\n' "$ip" > /root/iof/nodes.conf
bash /opt/iof/install.sh
git clone -q /tmp/iof-origin /tmp/iof-new-version
git -C /tmp/iof-new-version -c user.name='Стенд iof' -c user.email='iof@localhost' \
  commit --allow-empty -qm 'Стабильный выпуск для проверки обновления'
git -C /tmp/iof-new-version tag v0.9
git -C /tmp/iof-new-version -c user.name='Стенд iof' -c user.email='iof@localhost' \
  commit --allow-empty -qm 'Неопубликованный коммит master'
git -C /tmp/iof-new-version tag v0.10
git -C /tmp/iof-new-version push -q --tags origin master
printf '{"tag_name":"v0.10","draft":false,"prerelease":true,"published_at":"2026-11-21T00:00:00Z"}\n' > /run/iof-test-release.json

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=panel.test \
  -addext 'subjectAltName=DNS:panel.test' -keyout /run/iof-test.key -out /run/iof-test.crt 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$ip" \
  -addext "subjectAltName=IP:$ip" -keyout /run/iof-test-ip.key -out /run/iof-test-ip.crt 2>/dev/null
cat > /etc/nginx/conf.d/iof-test.conf <<EOF
server {
    listen 80;
    server_name panel.test $ip;
    location / { return 308 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    server_name panel.test;
    ssl_certificate /run/iof-test.crt;
    ssl_certificate_key /run/iof-test.key;
    include /opt/iof/web/nginx-iof.conf;
    location / { return 404; }
}
server {
    listen 443 ssl default_server;
    server_name $ip;
    ssl_certificate /run/iof-test-ip.crt;
    ssl_certificate_key /run/iof-test-ip.key;
    include /opt/iof/web/nginx-iof.conf;
    location / { return 404; }
}
EOF
nginx -t
systemctl restart nginx
ssh-keygen -q -N '' -t ed25519 -f /run/iof-test-ssh
cat /run/iof-test-ssh.pub >> /root/.ssh/authorized_keys
ssh -fN -L 127.0.0.1:18088:127.0.0.1:8088 -i /run/iof-test-ssh \
  -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -o ExitOnForwardFailure=yes "root@$ip"
python3 -B /src/stand/test-web.py "$ip"
SH
