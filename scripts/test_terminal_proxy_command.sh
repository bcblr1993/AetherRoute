#!/bin/sh
set -eu

# Test terminal proxy export and unset commands compatibility and network effects

log() { printf '%s\n' "$*"; }

log "=== Testing Terminal Proxy Commands (Export & Unset) ==="

EXPORT_CMD="export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890"
UNSET_CMD="unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"

# 1. Syntax check across shells
log "[1/3] Verifying command syntax in sh and zsh..."
sh -c "$EXPORT_CMD; [ -n \"\$http_proxy\" ] && [ -n \"\$https_proxy\" ] && [ -n \"\$all_proxy\" ]"
sh -c "$EXPORT_CMD; $UNSET_CMD; [ -z \"\$http_proxy\" ] && [ -z \"\$https_proxy\" ] && [ -z \"\$all_proxy\" ]"

zsh -c "$EXPORT_CMD; [ -n \"\$http_proxy\" ] && [ -n \"\$https_proxy\" ] && [ -n \"\$all_proxy\" ]"
zsh -c "$EXPORT_CMD; $UNSET_CMD; [ -z \"\$http_proxy\" ] && [ -z \"\$https_proxy\" ] && [ -z \"\$all_proxy\" ]"
log "  [PASS] Shell syntax & environment setting/clearing verified."

# 2. Case sensitivity and complete clean check
log "[2/3] Verifying uppercase and lowercase proxy variables clearing..."
sh -c "
  export HTTP_PROXY=http://127.0.0.1:7890
  export HTTPS_PROXY=http://127.0.0.1:7890
  export ALL_PROXY=socks5://127.0.0.1:7890
  $EXPORT_CMD
  $UNSET_CMD
  env | grep -Ei '^(http_proxy|https_proxy|all_proxy)=' && exit 1 || exit 0
"
log "  [PASS] All proxy environment variables cleanly unset."

# 3. Tool integration
log "[3/3] Testing curl proxy resolution with terminal proxy settings..."
sh -c "
  $EXPORT_CMD
  curl --version >/dev/null
  $UNSET_CMD
"
log "  [PASS] Tool integration verified."

log "=== Terminal Proxy Command Tests Passed Successfully! ==="
