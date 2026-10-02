#!/bin/sh
# Regression: a plain `type: http` node must actually be dialed.
#
# 1.0.4/1.0.5 accepted such a profile but never opened a connection to the
# node. This drives the production core through its local HTTP and SOCKS
# inbounds to a loopback CONNECT proxy that requires Basic credentials, and
# requires the fixture to have relayed both requests to a loopback target.
# Everything stays on 127.0.0.1; no external network is used.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-http-node.XXXXXX")
PIDS=""
cleanup() {
  for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done
  for pid in $PIDS; do wait "$pid" 2>/dev/null || true; done
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$WORK/runtime" "$WORK/www"

clang \
  -std=c17 \
  -Wall \
  -Wextra \
  -Werror \
  -mmacosx-version-min=14.0 \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_local_proxy_runner.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$WORK/runner"

wait_for_line() {
  file=$1
  for _ in $(seq 1 100); do
    [ -s "$file" ] && { head -1 "$file"; return 0; }
    sleep 0.1
  done
  echo "timed out waiting for $file" >&2
  return 1
}

printf 'aether-http-node-ok\n' >"$WORK/www/probe.txt"
python3 -c '
import functools, http.server, sys
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
handler.log_message = lambda *_: None
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
print(server.server_address[1], flush=True)
server.serve_forever()
' "$WORK/www" >"$WORK/target.port" 2>/dev/null &
PIDS="$PIDS $!"
TARGET_PORT=$(wait_for_line "$WORK/target.port")

python3 "$ROOT/Tests/CoreSmoke/http_connect_fixture.py" \
  "$WORK/fixture.log" fixture-user fixture-pass >"$WORK/fixture.port" &
PIDS="$PIDS $!"
NODE_PORT=$(wait_for_line "$WORK/fixture.port")

set -- $(python3 -c '
import socket
sockets = [socket.socket() for _ in range(2)]
for s in sockets: s.bind(("127.0.0.1", 0))
print(*(s.getsockname()[1] for s in sockets))
')
HTTP_PORT=$1
SOCKS_PORT=$2

cat >"$WORK/profile.yaml" <<EOF
mode: rule
log-level: warning
ipv6: false
dns:
  enable: false
proxies:
  - name: HTTP Node
    type: http
    server: 127.0.0.1
    port: $NODE_PORT
    username: fixture-user
    password: fixture-pass
proxy-groups:
  - name: Node Group
    type: select
    proxies:
      - HTTP Node
rules:
  - MATCH,Node Group
EOF

"$WORK/runner" "$WORK/profile.yaml" "$WORK/runtime" "$HTTP_PORT" "$SOCKS_PORT" \
  >"$WORK/runner.log" 2>&1 &
RUNNER_PID=$!
PIDS="$PIDS $RUNNER_PID"
ready=0
for _ in $(seq 1 150); do
  grep -q '^READY ' "$WORK/runner.log" && { ready=1; break; }
  kill -0 "$RUNNER_PID" 2>/dev/null || break
  sleep 0.1
done
[ "$ready" = 1 ] || { cat "$WORK/runner.log" >&2; echo "core did not start" >&2; exit 1; }

URL="http://127.0.0.1:$TARGET_PORT/probe.txt"
via_http=$(curl -sS --noproxy '' -m 10 -x "http://127.0.0.1:$HTTP_PORT" "$URL")
via_socks=$(curl -sS --noproxy '' -m 10 --socks5 "127.0.0.1:$SOCKS_PORT" "$URL")
[ "$via_http" = aether-http-node-ok ] || { echo "HTTP inbound did not reach the target through the node" >&2; exit 1; }
[ "$via_socks" = aether-http-node-ok ] || { echo "SOCKS inbound did not reach the target through the node" >&2; exit 1; }

relayed=$(grep -c "^CONNECT 127.0.0.1:$TARGET_PORT\$" "$WORK/fixture.log" 2>/dev/null || true)
[ "$relayed" -ge 2 ] || {
  echo "type: http node was not dialed (fixture relayed $relayed of 2 requests)" >&2
  exit 1
}
echo "HTTP node dial: authenticated CONNECT relayed via HTTP and SOCKS inbounds ($relayed requests)"
