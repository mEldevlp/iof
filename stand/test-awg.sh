#!/usr/bin/env bash
# Проверка туннеля из vpn:// в отдельных контейнерах, без вложенного Docker.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/remote.sh
source "$ROOT/lib/remote.sh"
# shellcheck source=lib/awg.sh
source "$ROOT/lib/awg.sh"
IMAGE=amneziavpn/amneziawg-go:0.2.19
DIR="$(mktemp -d)"
NET="iof-awg-test-$$"
SERVER="$NET-server"
CLIENT="$NET-client"

cleanup() {
  if (( $? )); then docker logs --tail 20 "$SERVER" >&2 || true; fi
  docker rm -f "$CLIENT" "$SERVER" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$DIR"
}
trap cleanup EXIT
umask 077

n_awg_seed_config "$DIR" 51820 "$IMAGE"
docker network create --internal "$NET" >/dev/null
docker run -d --name "$SERVER" --network "$NET" --cap-add NET_ADMIN --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 -v "$DIR:/opt/amnezia/awg" \
  "$IMAGE" bash -ec "$(n_awg_startup)" iof 10.8.1.0/24 >/dev/null
docker run -d --name "$CLIENT" --network "$NET" --cap-add NET_ADMIN --device /dev/net/tun \
  "$IMAGE" sleep infinity >/dev/null
for (( i=0; i<20; i++ )); do
  docker exec "$SERVER" awg show awg0 listen-port 2>/dev/null | grep -qx 51820 && break
  sleep 0.5
done
addr="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$SERVER")"
private="$(docker exec "$CLIENT" awg genkey)"
public="$(printf '%s\n' "$private" | docker exec -i "$CLIENT" awg pubkey)"
psk="$(cat "$DIR/wireguard_psk.key")"
srvpub="$(cat "$DIR/wireguard_server_public_key.key")"

printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 10.8.1.2/32\n' "$public" "$psk" >> "$DIR/awg0.conf"
docker exec "$SERVER" awg set awg0 peer "$public" preshared-key /opt/amnezia/awg/wireguard_psk.key allowed-ips 10.8.1.2/32
{
  printf '[Interface]\nAddress = 10.8.1.2/32\nPrivateKey = %s\n' "$private"
  grep -E '^[JSH][a-z0-9]+ = ' "$DIR/awg0.conf"
  printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s:51820\n' "$srvpub" "$psk" "$addr"
} > "$DIR/client.conf"
awg_make_key "$DIR/client.conf" "$public" amnezia-awg2 "Тестовый сервер" | python3 -c '
import base64, json, sys, zlib
key = sys.stdin.read().strip()
assert key.startswith("vpn://")
encoded = key[6:]
blob = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
data = zlib.decompress(blob[4:])
assert int.from_bytes(blob[:4], "big") == len(data)
container, = json.loads(data)["containers"]
awg = container["awg"]
assert awg["protocol_version"] == "2"
print(json.loads(awg["last_config"])["config"])
' | docker exec -i "$CLIENT" bash -eu -c '
  umask 077
  sed -e "/^DNS = /d" -e "s|^AllowedIPs = .*|AllowedIPs = 10.8.1.0/24|" > /tmp/awg0.conf
  awg-quick up /tmp/awg0.conf
  ping -c 2 -W 5 10.8.1.1
  test "$(awg show awg0 latest-handshakes | cut -f2)" -gt 0
'
docker restart "$SERVER" >/dev/null
for (( i=0; i<10; i++ )); do
  if docker exec "$CLIENT" ping -c 1 -W 2 10.8.1.1 >/dev/null; then
    echo "Туннель из vpn:// работает, клиент сохранился после перезапуска сервера"
    exit 0
  fi
done
echo "Туннель не восстановился после перезапуска сервера" >&2
exit 1
