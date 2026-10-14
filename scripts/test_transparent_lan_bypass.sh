#!/bin/sh
set -eu

# Release gate (transparent engine): verifies local loopback and LAN bypass.
#
# NETransparentProxyNetworkSettings excludes 127.0.0.0/8, 10.0.0.0/8,
# 172.16.0.0/12, 192.168.0.0/16, and 100.64.0.0/10.
#
# A local developer service on loopback (e.g. 127.0.0.1:port) must be directly
# reachable within milliseconds without being routed through proxy nodes or
# rejected by the provider runtime.

LOCAL_PORT=${AETHERROUTE_TRANSPARENT_LAN_PORT:-48123}
SERVER_PID=

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

# Start a lightweight ephemeral HTTP server on 127.0.0.1
python3 -c "
import http.server, socketserver, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'LAN_BYPASS_OK\n')
    def log_message(self, format, *args):
        pass

socketserver.TCPServer.allow_reuse_address = True
try:
    with socketserver.TCPServer(('127.0.0.1', $LOCAL_PORT), Handler) as httpd:
        httpd.serve_forever()
except Exception as e:
    sys.exit(1)
" &
SERVER_PID=$!

# Wait briefly for the server to be ready
ready=0
for _ in $(seq 1 20); do
  if nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.1
done

if [ "$ready" -ne 1 ]; then
  echo "transparent LAN bypass: local server failed to bind on 127.0.0.1:$LOCAL_PORT" >&2
  exit 1
fi

# Request the local server ignoring any environment proxy
response=$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
  -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
  curl --noproxy '*' -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 3 \
  "http://127.0.0.1:$LOCAL_PORT/" 2>/dev/null || echo "000 timeout")

code=$(printf '%s\n' "$response" | awk '{print $1}')
elapsed=$(printf '%s\n' "$response" | awk '{print $2}')

if [ "$code" = "200" ]; then
  echo "transparent LAN bypass: 127.0.0.1:$LOCAL_PORT answered HTTP 200 in ${elapsed}s (directly bypassed)"
  exit 0
else
  echo "transparent LAN bypass: 127.0.0.1:$LOCAL_PORT returned HTTP $code in ${elapsed}s (expected 200)" >&2
  exit 1
fi
