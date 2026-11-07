#!/usr/bin/env bash
set -euo pipefail
dist="$(cd "$1" && pwd)"
image="${2:-mijialan-bridge:candidate}"

for os in debian:12-slim ubuntu:24.04; do
  docker run --rm --platform linux/amd64 -v "$dist:/packages:ro" "$os" bash -eu -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends /packages/*.deb
    test "$(dpkg-query -W -f="\${Architecture}" mijialan-rust)" = amd64
    dpkg --compare-versions "$(dpkg-query -W -f="\${Version}" mijialan-rust)" gt 0.1.0
    mijia-rust --help | grep -q serve
    mijia-rust --demo list >/tmp/devices.json
    test -s /tmp/devices.json
    for binary in /usr/bin/mijia-rust /usr/bin/mijialan-rust; do
      ldd "$binary" >/tmp/dependencies
      ! grep -F "not found" /tmp/dependencies
    done
    test -s /usr/share/applications/mijialan-rust.desktop
    test -s /usr/share/icons/hicolor/scalable/apps/mijialan-rust.svg
  '
done

name="mijialan-bridge-smoke-$$"
cookie="$(mktemp)"
cleanup() {
  rm -f "$cookie"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm "$name-data" "$name-keys" >/dev/null 2>&1 || true
}
trap cleanup EXIT
start() {
  docker run -d --name "$name" --platform linux/amd64 --read-only --init \
    --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp:mode=1777,size=16m \
    -v "$name-data:/data" -v "$name-keys:/keys" \
    --entrypoint /bin/sh "$image" -c 'exec mijia-rust serve --lan-ip "$(hostname -i)"' >/dev/null
}
wait_for_wizard() {
  origin="http://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name"):17890"
  for _ in {1..30}; do
    if curl --noproxy '*' -fsS --max-time 1 "$origin/" >/dev/null 2>&1; then return; fi
    sleep 1
  done
  echo "Bridge setup did not open" >&2
  docker logs "$name" 2>&1 | sed -E 's/(一次性设置码: ).*/\1[redacted]/' >&2
  return 1
}

start
wait_for_wizard
test "$(docker exec "$name" id -u)" = 10001
test "$(docker exec "$name" stat -c %a /keys/master.key)" = 600
key_digest="$(docker exec "$name" sha256sum /keys/master.key)"
test "$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "$origin/api/state")" = 401
code="$(docker logs "$name" | sed -n 's/^一次性设置码: //p')"
test "${#code}" = 48
curl --noproxy '*' -fsS -c "$cookie" -H "Origin: $origin" -H 'Content-Type: application/json' \
  --data-binary "{\"code\":\"$code\"}" "$origin/api/unlock"
curl --noproxy '*' -fsS -b "$cookie" "$origin/api/state" | python3 -c \
  'import json, sys; state=json.load(sys.stdin); assert state["devices"] == [] and state["bridge"]["pin"] is None'
unset code
docker stop "$name" >/dev/null
test "$(docker inspect -f '{{.State.ExitCode}}' "$name")" = 0
docker rm "$name" >/dev/null
start
wait_for_wizard
test "$(docker exec "$name" sha256sum /keys/master.key)" = "$key_digest"
test "$(curl --noproxy '*' -s -b "$cookie" -o /dev/null -w '%{http_code}' "$origin/api/state")" = 401
