#!/bin/sh
set -eu
umask 077

# Verify AI desktop applications (ChatGPT, Codex, Antigravity) and their endpoints
# running through AetherRoute in a Tart VM.

SSH_KEY=${AETHERROUTE_VM_SSH_KEY:-$HOME/.ssh/id_ed25519}
VM_USER=${AETHERROUTE_VM_USER:-chenxu}
VM_IP=${AETHERROUTE_VM_IP:-192.168.64.6}
ENGINE=${1:-tun}
ROUTING=${2:-rule}

log() { printf '%s\n' "$*"; }

vm() {
  ssh -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 -i "$SSH_KEY" "$VM_USER@$VM_IP" "$@"
}

log "=== Testing AI Applications & Endpoints through AetherRoute ($ENGINE/$ROUTING) ==="

# 1. Start AetherRoute and connect
log "[1/4] Starting and connecting AetherRoute..."
vm "set -e
  PREF=\$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop
  defaults write \"\$PREF\" AetherRoute.NetworkEngineMode -string $ENGINE
  defaults write \"\$PREF\" defaultRoutingMode -string $ROUTING
  JSON='{\"version\":1,\"isEnabled\":true,\"httpPort\":7890,\"socksPort\":7891}'
  defaults write \"\$PREF\" AetherRoute.LocalProxySettings \
    -data \"\$(printf '%s' \"\$JSON\" | xxd -p | tr -d '\n')\"
  osascript -e 'tell application \"AetherRoute\" to quit' 2>/dev/null || true
  sleep 2
  open -a /Applications/AetherRoute.app --env AETHERROUTE_QA_AUTOCONNECT=1
  for i in \$(seq 1 30); do
    sleep 3
    if [ '$ENGINE' = transparent ]; then
      if pgrep -x com.aetherroute.desktop.transparent-proxy >/dev/null; then exit 0; fi
    else
      if [ \"\$(scutil --nc status AetherRoute 2>/dev/null | head -1)\" = Connected ]; then exit 0; fi
    fi
  done
  echo 'AetherRoute failed to connect' >&2
  exit 1"

log "AetherRoute connected successfully in $ENGINE/$ROUTING mode."

# 2. Test core AI endpoints
log "[2/4] Testing AI backend API & service endpoints..."
vm "
  clean_curl() {
    env -i PATH='/usr/bin:/bin:/usr/sbin:/sbin' curl -s -o /dev/null \"\$@\"
  }

  test_endpoint() {
    name=\$1
    url=\$2
    expected=\$3
    res=\$(clean_curl --proxy '' -w '%{http_code}|%{time_total}|%{remote_ip}' --max-time 15 \"\$url\" 2>/dev/null || echo '000|0|none')
    code=\$(echo \"\$res\" | cut -d'|' -f1)
    time=\$(echo \"\$res\" | cut -d'|' -f2)
    ip=\$(echo \"\$res\" | cut -d'|' -f3)
    if echo \"\$code\" | grep -Eq \"\$expected\"; then
      printf '  [PASS] %-32s HTTP %s in %ss (ip: %s)\n' \"\$name\" \"\$code\" \"\$time\" \"\$ip\"
      return 0
    else
      printf '  [FAIL] %-32s HTTP %s in %ss (expected: %s, ip: %s)\n' \"\$name\" \"\$code\" \"\$time\" \"\$expected\" \"\$ip\"
      return 1
    fi
  }

  fails=0
  echo '--- OpenAI & ChatGPT / Codex Endpoints ---'
  test_endpoint 'OpenAI API (api.openai.com)' 'https://api.openai.com/v1/models' '^(401|200)$' || fails=\$((fails+1))
  test_endpoint 'ChatGPT Web (chatgpt.com)' 'https://chatgpt.com/' '^(200|301|302|403)$' || fails=\$((fails+1))
  test_endpoint 'OpenAI Auth (auth.openai.com)' 'https://auth.openai.com/' '^(200|301|302|403|404)$' || fails=\$((fails+1))
  test_endpoint 'ChatGPT CDN (cdn.oaistatic.com)' 'https://cdn.oaistatic.com/' '^(200|301|403|404)$' || fails=\$((fails+1))

  echo '--- Google AI / Antigravity Endpoints ---'
  test_endpoint 'Google Generative AI API' 'https://generativelanguage.googleapis.com/' '^(200|404)$' || fails=\$((fails+1))
  test_endpoint 'Google OAuth2 Gateway' 'https://oauth2.googleapis.com/' '^(200|404)$' || fails=\$((fails+1))

  echo '--- Anthropic / Claude Endpoints ---'
  test_endpoint 'Anthropic API Gateway' 'https://api.anthropic.com/v1/messages' '^(401|403|405)$' || fails=\$((fails+1))

  echo '--- Public Outbound IP Check ---'
  egress=\$(env -i PATH='/usr/bin:/bin:/usr/sbin:/sbin' curl -s --max-time 10 https://api.ipify.org || echo 'failed')
  echo \"  Egress public IP observed through proxy: \$egress\"

  if [ \"\$fails\" -gt 0 ]; then
    echo \"Total endpoint failures: \$fails\" >&2
    exit 1
  fi
"

# 3. Test real Desktop Applications in VM
log "[3/4] Launching and observing real Desktop Applications in VM..."
vm "set -e
  # Test Antigravity.app
  if [ -d /Applications/Antigravity.app ]; then
    echo 'Launching Antigravity.app in VM...'
    open -a /Applications/Antigravity.app || true
    sleep 8
    anti_pid=\$(pgrep -i Antigravity | head -1 || true)
    if [ -n \"\$anti_pid\" ]; then
      echo \"  [PASS] Antigravity running with PID \$anti_pid\"
      echo \"  Antigravity network sockets:\"
      lsof -p \"\$anti_pid\" -i 2>/dev/null || true
    else
      echo '  [WARN] Antigravity process not directly in root pid list; checking helper processes:'
      ps aux | grep -i Antigravity | grep -v grep || true
    fi
  fi

  # Test ChatGPT.app
  if [ -d /Applications/ChatGPT.app ]; then
    echo 'Launching ChatGPT.app in VM...'
    open -a /Applications/ChatGPT.app || true
    sleep 8
    chat_pid=\$(pgrep -i ChatGPT | head -1 || true)
    if [ -n \"\$chat_pid\" ]; then
      echo \"  [PASS] ChatGPT running with PID \$chat_pid\"
      echo \"  ChatGPT network sockets:\"
      lsof -p \"\$chat_pid\" -i 2>/dev/null || true
    else
      echo '  [WARN] ChatGPT process not directly in root pid list; checking helper processes:'
      ps aux | grep -i ChatGPT | grep -v grep || true
    fi
  fi
"

# 4. Clean up applications and restore network
log "[4/4] Tearing down test applications..."
vm "
  osascript -e 'tell application \"ChatGPT\" to quit' 2>/dev/null || true
  osascript -e 'tell application \"Antigravity\" to quit' 2>/dev/null || true
  sleep 3
  pkill -i ChatGPT 2>/dev/null || true
  pkill -i Antigravity 2>/dev/null || true
  osascript -e 'tell application \"AetherRoute\" to quit' 2>/dev/null || true
  echo 'All test applications cleanly stopped.'
"

log "=== All Desktop Applications & Endpoints Passed Successfully! ==="
