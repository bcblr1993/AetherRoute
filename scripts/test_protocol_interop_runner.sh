#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUNNER="$ROOT/scripts/test_protocol_interop.sh"

sh -n "$RUNNER"

require_line() {
  grep -F "$1" "$RUNNER" >/dev/null || {
    echo "protocol interop runner is missing required guard: $1" >&2
    exit 1
  }
}

require_line 'SHADOW_TLS_BIN=${SHADOW_TLS_BIN:?set SHADOW_TLS_BIN to shadow-tls 0.2.25 darwin arm64}'
require_line 'EXPECTED_SHADOW_TLS_SHA256=${SHADOW_TLS_SHA256:-a7c39d70cfc5868f654b19766b768518413ac4ffd9532ea8534a36a1d447b5b1}'
require_line 'verify_sha256 "$EXPECTED_SHADOW_TLS_SHA256" "$SHADOW_TLS_BIN"'
require_line '"$SHADOW_TLS_BIN" --version | grep -F "shadow-tls 0.2.25" >/dev/null'
require_line 'RUST_LOG=error "$SHADOW_TLS_BIN" --v3 server \'
require_line '    --listen 127.0.0.1:59021 \'
require_line '    --server 127.0.0.1:59002 \'
require_line '    --tls www.feishu.cn:443 \'
require_line 'lsof -nP -a -p "$SHADOW_TLS_PID" -iTCP:59021 -sTCP:LISTEN'
require_line "grep -Eq '\\*:59021|0\\.0\\.0\\.0:59021|\\[::\\]:59021'"
require_line 'kill "$SHADOW_TLS_PID"'

# The fetch script downloads exactly what the prebuilt runners pin.
FETCH="$ROOT/scripts/fetch_interop_tools.sh"
RUN_ALL="$ROOT/scripts/test_protocol_interop_all.sh"
sh -n "$FETCH"
sh -n "$RUN_ALL"
fetch_pin() {
  value=$(sed -n "s/^$1=//p" "$FETCH")
  test -n "$value" || {
    echo "fetch_interop_tools.sh is missing $1" >&2
    exit 1
  }
  printf '%s\n' "$value"
}
require_pin() {
  grep -F "$2" "$1" >/dev/null || {
    echo "$(basename "$1") does not pin $2 like fetch_interop_tools.sh" >&2
    exit 1
  }
}
INTEROP="$ROOT/Tests/Interop"
require_pin "$INTEROP/run-prebuilt-matrix.sh" "$(fetch_pin SING_BOX_SHA256)"
require_pin "$INTEROP/run-prebuilt-matrix.sh" "sing-box version $(fetch_pin SING_BOX_VERSION)"
require_pin "$INTEROP/run-prebuilt-matrix.sh" "$(fetch_pin SHADOW_TLS_SHA256)"
require_pin "$INTEROP/run-prebuilt-matrix.sh" "shadow-tls $(fetch_pin SHADOW_TLS_VERSION)"
require_pin "$INTEROP/run-prebuilt-reality.sh" "$(fetch_pin XRAY_SHA256)"
require_pin "$INTEROP/run-prebuilt-reality.sh" "Xray $(fetch_pin XRAY_VERSION)"
require_pin "$INTEROP/run-prebuilt-shadowquic.sh" "$(fetch_pin MIHOMO_SHA256)"
require_pin "$INTEROP/run-prebuilt-shadowquic.sh" "v$(fetch_pin MIHOMO_VERSION).gz"
require_pin "$RUN_ALL" "mihomo-darwin-arm64-v$(fetch_pin MIHOMO_VERSION).gz"
require_pin "$RUNNER" "$(fetch_pin SING_BOX_SHA256)"
require_pin "$RUNNER" "$(fetch_pin SHADOW_TLS_SHA256)"

echo "Protocol interoperability runner guards verified"
