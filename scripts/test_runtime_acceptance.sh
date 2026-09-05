#!/bin/sh
set -eu
umask 077

# Runtime acceptance matrix for an installed AetherRoute build.
#
# Answers one question: on THIS machine, with THIS build, does every runtime
# feature actually work? It only observes — it never installs, never changes
# the routing mode, and never connects or disconnects. Whoever runs it decides
# what state the tunnel is in; the script reports what that state can do.
#
# That split is deliberate. Starting a Packet Tunnel requires the launch
# snapshot the app passes to startTunnelWithOptions, which no command-line
# entry point can supply, so an "acceptance script" that tried to connect would
# either be lying or would need a back door into a shipping VPN.
#
# Exit status is the number of failed checks, so CI can gate on it.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP=${AETHERROUTE_APP_PATH:-/Applications/AetherRoute.app}
EXPECTED_BUILD=${1:-}
REPORT=${2:-}

usage() {
  echo "usage: $0 [expected-build-number] [/absolute/report-path]" >&2
  echo "  AETHERROUTE_APP_PATH overrides the app location." >&2
}

case "$REPORT" in
  "" | /*) ;;
  *) usage; exit 64 ;;
esac
if [ -n "$EXPECTED_BUILD" ]; then
  printf '%s\n' "$EXPECTED_BUILD" | grep -Eq '^[1-9][0-9]*$' || {
    usage
    exit 64
  }
fi

PASS=0
FAIL=0
SKIP=0

emit() {
  printf '%s\n' "$1"
  [ -n "$REPORT" ] && printf '%s\n' "$1" >>"$REPORT"
  return 0
}

check() {
  label=$1
  detail=$2
  verdict=$3
  case "$verdict" in
    pass) PASS=$((PASS + 1)); mark="PASS" ;;
    fail) FAIL=$((FAIL + 1)); mark="FAIL" ;;
    *) SKIP=$((SKIP + 1)); mark="SKIP" ;;
  esac
  emit "$(printf '  [%-4s] %-34s %s' "$mark" "$label" "$detail")"
}

if [ -n "$REPORT" ]; then
  test ! -e "$REPORT" || { echo "refusing to overwrite report: $REPORT" >&2; exit 1; }
  : >"$REPORT"
fi

emit "AetherRoute runtime acceptance — $(date '+%Y-%m-%d %H:%M:%S')"
emit "host: $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
emit ""

# ---------------------------------------------------------------- install ---
emit "install"
if [ -d "$APP" ]; then
  build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)
  if [ -n "$EXPECTED_BUILD" ] && [ "$build" != "$EXPECTED_BUILD" ]; then
    check "installed build" "found $build, expected $EXPECTED_BUILD" fail
  else
    check "installed build" "$build" pass
  fi

  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    check "code signature" "valid (deep, strict)" pass
  else
    check "code signature" "invalid" fail
  fi

  # A locally signed QA candidate is Developer ID signed but deliberately not
  # notarized, so Gatekeeper rejects it. That is the expected shape of a QA
  # build, not a defect — only a build claiming to be distributable must pass.
  assessment=$(spctl -a -vv -t exec "$APP" 2>&1 || true)
  case "$assessment" in
    *"Notarized Developer ID"*)
      check "notarization" "Notarized Developer ID" pass
      case "$assessment" in
        *accepted*) check "Gatekeeper" "accepted" pass ;;
        *) check "Gatekeeper" "rejected despite notarization" fail ;;
      esac ;;
    *)
      if codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'Developer ID Application'; then
        check "notarization" "signed, not notarized (QA build)" skip
        check "Gatekeeper" "rejected — expected for a QA build" skip
      else
        check "notarization" "not Developer ID signed" fail
        check "Gatekeeper" "rejected" fail
      fi ;;
  esac

  for ext in tunnel transparent-proxy; do
    plist="$APP/Contents/Library/SystemExtensions/com.aetherroute.desktop.$ext.systemextension/Contents/Info.plist"
    if [ -f "$plist" ]; then
      v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
      if [ "$v" = "$build" ]; then
        check "bundled $ext" "$v" pass
      else
        check "bundled $ext" "$v does not match app $build" fail
      fi
    else
      check "bundled $ext" "missing" fail
    fi
  done
else
  check "installed build" "no app at $APP" fail
fi
emit ""

# ------------------------------------------------------------- extensions ---
emit "system extensions"
extlist=$(systemextensionsctl list 2>/dev/null || true)
for ext in tunnel transparent-proxy; do
  line=$(printf '%s\n' "$extlist" \
    | grep "com.aetherroute.desktop.$ext" \
    | grep -v 'waiting to uninstall' | head -1 || true)
  case "$line" in
    *"activated enabled"*)
      v=$(printf '%s\n' "$line" | sed -n 's/.*(1\.0\.0\/\([0-9]*\)).*/\1/p')
      check "$ext activated" "${v:-unknown}" pass ;;
    "") check "$ext activated" "not present" fail ;;
    *) check "$ext activated" "present but not enabled" fail ;;
  esac
done
emit ""

# ------------------------------------------------------------------ tunnel ---
emit "tunnel state"
# The two engines are observable in different places. A Packet Tunnel shows up
# in `scutil --nc` and owns a utun default route; a Transparent Proxy uses
# NETransparentProxyManager, creates no interface and never appears there —
# judging it by the routing table reports a working tunnel as disconnected.
PREFS_DOMAIN="$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop"
ENGINE=$(defaults read "$PREFS_DOMAIN" AetherRoute.NetworkEngineMode 2>/dev/null || echo unknown)
ROUTING=$(defaults read "$PREFS_DOMAIN" defaultRoutingMode 2>/dev/null || echo rule)
check "network engine" "$ENGINE" pass
check "routing mode" "$ROUTING" pass

status=$(scutil --nc status AetherRoute 2>/dev/null | head -1 || echo "no configuration")
route_if=$(netstat -rn -f inet | awk '/^default/ {print $NF; exit}')

case "$ENGINE" in
  transparent)
    if pgrep -f com.aetherroute.desktop.transparent-proxy >/dev/null 2>&1; then
      check "transparent proxy running" "extension process alive" pass
      CONNECTED=yes
    else
      check "transparent proxy running" "extension not running" fail
      CONNECTED=no
    fi
    check "IPv4 default route" "$route_if (unchanged by design)" pass ;;
  *)
    check "VPN configuration" "$status" \
      "$([ "$status" = "no configuration" ] && echo fail || echo pass)"
    check "IPv4 default route" "$route_if" pass
    CONNECTED=$(printf '%s\n' "$route_if" | grep -q '^utun' && echo yes || echo no) ;;
esac

# The IPv6 regression: the tunnel used to claim an IPv6 default route even
# when its outbound could not carry IPv6, black-holing every AAAA connection.
if printf '%s\n' "$route_if" | grep -q '^utun'; then
  if netstat -rn -f inet6 | awk '/^default/ {print $NF}' \
    | grep -qx "$route_if"; then
    check "IPv6 not hijacked" "$route_if holds an IPv6 default route" fail
  else
    check "IPv6 not hijacked" "tunnel absent from IPv6 defaults" pass
  fi
  v6count=$(ifconfig "$route_if" 2>/dev/null \
    | grep inet6 | grep -vc fe80 || true)
  if [ "${v6count:-0}" -eq 0 ]; then
    check "tunnel IPv6 addresses" "0" pass
  else
    check "tunnel IPv6 addresses" "$v6count present" fail
  fi
elif [ "$ENGINE" = transparent ]; then
  check "IPv6 not hijacked" "transparent proxy claims no routes" pass
  check "tunnel IPv6 addresses" "no interface by design" pass
else
  check "IPv6 not hijacked" "tunnel not active" skip
  check "tunnel IPv6 addresses" "tunnel not active" skip
fi
emit ""

# ------------------------------------------------------------ local proxy ---
emit "local proxy"
# Read the ports AetherRoute is configured to use rather than probing whatever
# answers on loopback — another proxy (Clash, Surge, ...) listening nearby must
# never be mistaken for a working AetherRoute listener.
PREFS="$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop.plist"
# The settings are a JSON blob stored as plist <data>. `defaults read` prints
# it elided with "...", and `plutil -extract raw -o -` does not stream it, so
# read the base64 out of the XML form — the only representation that is both
# complete and available without Python on a bare test VM.
proxy_json=$(plutil -convert xml1 -o - "$PREFS" 2>/dev/null | awk '
  /<key>AetherRoute.LocalProxySettings<\/key>/ { found = 1; next }
  found && /<data>/                           { inside = 1; next }
  inside && /<\/data>/                        { exit }
  inside                                      { printf "%s", $0 }
' | tr -d ' \t' | base64 -d 2>/dev/null || true)
case "$ENGINE:$proxy_json" in
  transparent:*)
    # The loopback proxy is a Packet Tunnel feature; the transparent engine
    # captures flows directly and exposes no listener. Its absence here is the
    # designed behaviour, not a missing feature.
    check "local proxy" "not offered by the transparent engine" skip ;;
esac
case "$ENGINE:$proxy_json" in
  transparent:*) ;;
  *:*'"isEnabled":true'*)
    http_port=$(printf '%s' "$proxy_json" | sed -n 's/.*"httpPort":\([0-9]*\).*/\1/p')
    socks_port=$(printf '%s' "$proxy_json" | sed -n 's/.*"socksPort":\([0-9]*\).*/\1/p')
    for spec in "HTTP:http://127.0.0.1:$http_port" \
                "SOCKS5:socks5h://127.0.0.1:$socks_port"; do
      name=${spec%%:*}
      proxy=${spec#*:}
      port=${proxy##*:}
      # The listener belongs to the Network Extension, which runs as root, so
      # lsof shows nothing to an ordinary user. netstat sees every socket
      # regardless of owner and is the only reliable presence test here; lsof
      # is kept purely to name the owner when it happens to be visible.
      if netstat -an -p tcp 2>/dev/null | grep LISTEN \
        | grep -q "127\.0\.0\.1\.$port "; then
        owner=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null \
          | awk 'NR>1 {print $1; exit}')
        owner=${owner:-root-owned}
      else
        owner=""
      fi

      # While the tunnel is down AetherRoute holds no listener, so anything
      # answering here belongs to another proxy. Reporting that as a pass is
      # how a port clash (Clash, Surge, ...) hides until the tunnel starts and
      # silently fails to bind.
      if [ "$CONNECTED" != yes ]; then
        if [ -n "$owner" ]; then
          check "$name port :$port" \
            "held by $owner while tunnel is down — will block bind" fail
        else
          check "$name port :$port" "free (tunnel down)" pass
        fi
        continue
      fi

      if [ -z "$owner" ]; then
        check "$name proxy :$port" "not listening" fail
        continue
      fi
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "$proxy" \
        http://cp.cloudflare.com/generate_204 2>/dev/null || echo 000)
      if [ "$code" = 204 ]; then
        check "$name proxy :$port" "answered 204 ($owner)" pass
      else
        check "$name proxy :$port" "listening ($owner) but returned $code" fail
      fi
    done

    # macOS stores one host:port per protocol, and every Clash-derived setup
    # points both HTTP and SOCKS at the primary port. When that port spoke only
    # HTTP, SOCKS clients failed instantly — browsers broke while curl over the
    # HTTP proxy stayed green, so the fault never showed up in testing.
    mixed=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
      -x "socks5h://127.0.0.1:$http_port" \
      http://cp.cloudflare.com/generate_204 2>/dev/null || echo 000)
    if [ "$mixed" = 204 ]; then
      check "primary port speaks SOCKS too" "mixed listener on :$http_port" pass
    else
      check "primary port speaks SOCKS too" \
        "SOCKS to :$http_port returned $mixed — Clash-style system proxy will break" fail
    fi ;;
  *:) check "local proxy" "no preferences found" skip ;;
  *)  check "local proxy" "disabled in settings" skip ;;
esac
emit ""

# --------------------------------------------------------------- data path ---
emit "data path"
# needs_proxy marks a destination that is only expected to answer when traffic
# is actually leaving through a node. In direct mode those requests go out over
# the local network, so a failure describes that network, not AetherRoute.
probe() {
  label=$1
  url=$2
  expect=$3
  needs_proxy=${4:-no}
  out=$(env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u http_proxy -u https_proxy -u all_proxy \
    curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 "$url" \
    2>/dev/null || echo "000 timeout")
  code=${out%% *}
  secs=${out##* }
  if printf '%s\n' "$expect" | grep -qw "$code"; then
    check "$label" "HTTP $code in ${secs}s" pass
  elif [ "$needs_proxy" = yes ] && [ "$ROUTING" = direct ]; then
    check "$label" "HTTP $code (direct mode bypasses nodes)" skip
  else
    check "$label" "HTTP $code in ${secs}s" \
      "$([ "$CONNECTED" = yes ] && echo fail || echo skip)"
  fi
}
probe "captive portal probe" http://cp.cloudflare.com/generate_204 "204"
probe "anthropic reachable"  https://api.anthropic.com/v1/messages "405 403 401" yes
probe "china site direct"    https://www.baidu.com/ "200"

egress=$(env -u HTTPS_PROXY -u https_proxy curl -s --max-time 20 \
  https://api.ipify.org 2>/dev/null || true)
if [ -n "$egress" ]; then
  check "egress address" "$egress" pass
elif [ "$ROUTING" = direct ]; then
  # Direct mode deliberately bypasses every node, so the request leaves from
  # the local network. Whether that reaches the internet says nothing about
  # AetherRoute.
  check "egress address" "no answer (direct mode bypasses nodes)" skip
else
  check "egress address" "no answer" \
    "$([ "$CONNECTED" = yes ] && echo fail || echo skip)"
fi

# IPv6 must fail fast rather than hang: a black hole is what broke Electron
# apps, because Happy Eyeballs waited on a route that never answered. This is
# a property of the tunnel's routing, so it is only meaningful when the tunnel
# is actually routing — direct mode measures the host network instead.
v6=$(curl -s -o /dev/null -w '%{time_total}' --max-time 12 -6 \
  https://ipv6.google.com/ 2>/dev/null || echo 99)
v6_secs=$(printf '%s\n' "$v6" | cut -d. -f1)
if [ "$ROUTING" = direct ]; then
  check "IPv6 fails fast" "${v6}s (direct mode — host network)" skip
elif [ "$v6_secs" -lt 8 ]; then
  check "IPv6 fails fast" "${v6}s" pass
else
  check "IPv6 fails fast" "${v6}s — Happy Eyeballs will stall" fail
fi
emit ""

# ------------------------------------------------------------- diagnostics ---
emit "diagnostics"
crashes=$(ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null \
  | grep -ci aetherroute || true)
if [ "${crashes:-0}" -eq 0 ]; then
  check "crash reports" "0" pass
else
  check "crash reports" "$crashes found" fail
fi

errors=$(log show --last 10m \
  --predicate 'subsystem == "com.aetherroute.desktop"' \
  --style compact 2>/dev/null | grep -cE '^\S+ \S+ E ' || true)
check "error-level log lines (10m)" "${errors:-0}" \
  "$([ "${errors:-0}" -eq 0 ] && echo pass || echo skip)"
emit ""

emit "summary: $PASS passed, $FAIL failed, $SKIP skipped"
[ -n "$REPORT" ] && emit "report: $REPORT"
exit "$FAIL"
