#!/usr/bin/env bash

# Чистый первый запуск в отдельных контейнерах: существующий стенд и его данные не трогаем.
# Нужен заранее собранный образ iof-stand: bash stand/stand.sh up old node1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="iof-setup-$$"
NET="$PREFIX-net"
LOCAL="$PREFIX-local"
CONTROL="$PREFIX-control"
PEER="$PREFIX-peer"
export MSYS_NO_PATHCONV=1
cleanup() {
  docker rm -f "$LOCAL" "$CONTROL" "$PEER" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
docker network create "$NET" >/dev/null
for c in "$LOCAL" "$CONTROL" "$PEER"; do
  docker run -d --name "$c" --hostname "$c" --network "$NET" --privileged --cgroupns=host \
    --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$ROOT:/opt/iof:ro" iof-stand >/dev/null
done
for c in "$LOCAL" "$CONTROL"; do
  docker exec "$c" bash -c 'apt-get update -qq && apt-get install -y -qq python3 git qrencode >/dev/null && bash /opt/iof/install.sh' >/dev/null
done
local_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$LOCAL")"
peer_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PEER")"
# Панель остаётся тем же процессом: новый шаблон виден без перезапуска.
for c in "$LOCAL" "$CONTROL"; do
  mode=local; addr="$local_ip"
  if [[ "$c" == "$CONTROL" ]]; then mode=template-only; addr=""; fi
  docker exec -i "$c" python3 - "$mode" "$addr" <<'PY'
import json, pathlib, sys, time, urllib.error, urllib.request
mode, addr = sys.argv[1:]
def api(path, body=None):
    req = urllib.request.Request('http://127.0.0.1:8088/api/' + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'X-IOF-Request': '1', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)
def wait(job):
    for _ in range(180):
        value = next(j for j in api('jobs')['jobs'] if j['id'] == job)
        if value['state'] != 'running':
            assert value['state'] == 'ok', value
            return value
        time.sleep(1)
    raise AssertionError('таймаут setup')
assert not api('setup')['template']
body = {'mode': mode}
if mode == 'local': body.update(name='main', addr=addr)
job = api('setup', body)['job']
if mode == 'local':
    try:
        api('setup', body)
        raise AssertionError('вторая задача принята при занятой очереди')
    except urllib.error.HTTPError as e:
        assert e.code == 409
first = wait(job)
base = pathlib.Path('/root/iof')
template = (base / 'hy2-template.yaml').read_bytes()
state = api('setup')
assert state['template']
assert api('nodes/add-info')['hy2_template']
secret = template.decode().split('password: ', 1)[1].splitlines()[0]
assert secret not in json.dumps([state, first])
if mode == 'template-only':
    assert state['nodes'] == 0
    assert not pathlib.Path('/etc/hysteria/config.yaml').exists()
else:
    assert state['nodes'] == 1 and state['local']['name'] == 'main'
files = [base / 'hy2-template.yaml', base / 'nodes.conf']
if mode == 'local': files += [pathlib.Path('/etc/hysteria/' + n) for n in ('config.yaml', 'server.crt', 'server.key')]
before = [p.read_bytes() for p in files]
wait(api('setup', body)['job'])
assert before == [p.read_bytes() for p in files], 'повтор изменил файлы или секреты'
print('ok: API setup, повтор без изменений, секретов в API и логе нет:', mode)
PY
done
# Выделенный управляющий сервер использует новый шаблон для удалённого узла.
docker exec -i "$CONTROL" bash -s -- "$peer_ip" <<'SH'
set -euo pipefail
printf 'stand\n' | iof node add peer "$1" Peer --password-stdin >/dev/null
iof hy2 install peer
iof hy2 add Проверка >/dev/null
SH
docker exec "$LOCAL" bash -c 'iof hy2 add Проверка >/dev/null'
# Реальный клиент на другом сервере открывает страницу через новый local-узел.
docker exec "$LOCAL" bash -c 'cat /root/iof/hy2/*.txt' | docker exec -i "$PEER" bash -c '
set -euo pipefail
read -r link
umask 077
printf "server: %s\nsocks5:\n  listen: 127.0.0.1:1080\n" "$link" > /run/setup-client.yaml
hysteria -c /run/setup-client.yaml client >/run/setup-client.log 2>&1 &
pid=$!
trap '\''kill "$pid" 2>/dev/null || true; rm -f /run/setup-client.yaml /run/setup-client.log'\'' EXIT
curl -fsS --retry 10 --retry-delay 1 --retry-connrefused --max-time 30 --socks5-hostname 127.0.0.1:1080 https://www.google.com/generate_204 >/dev/null
'
echo 'ok: template-only → удалённый узел; local → реальный клиентский туннель'
