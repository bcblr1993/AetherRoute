#!/bin/sh
set -eu
umask 077

# Runtime acceptance matrix for an installed AetherRoute build.
#
# Checks the current connected state of THIS installed candidate. A successful
# result is a bounded runtime smoke check, not a lifecycle or release gate.
# It only observes — it never installs, never changes
# the routing mode, and never connects or disconnects. Whoever runs it decides
# what state the tunnel is in; the script reports what that state can do.
#
# That split is deliberate. Starting a Packet Tunnel requires the launch
# snapshot the app passes to startTunnelWithOptions, which no command-line
# entry point can supply, so an "acceptance script" that tried to connect would
# either be lying or would need a back door into a shipping VPN.
#
# Exit status is the number of failed checks, so CI can gate on it. An inactive
# or unobservable provider cannot pass. Privileged socket observation is opt-in
# for the designated test VM; it never prompts for a password.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP=${AETHERROUTE_APP_PATH:-/Applications/AetherRoute.app}
EXPECTED_BUILD=${1:-}
REPORT=${2:-}
PRIVILEGED_OBSERVATION=${AETHERROUTE_ACCEPTANCE_PRIVILEGED_OBSERVATION:-NO}

usage() {
  echo "usage: $0 [expected-build-number] [/absolute/report-path]" >&2
  echo "  AETHERROUTE_APP_PATH overrides the app location." >&2
  echo "  AETHERROUTE_ACCEPTANCE_PRIVILEGED_OBSERVATION=YES permits sudo -n lsof on the test VM." >&2
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
build=unknown

# Ignore ~/.curlrc as well as every conventional proxy environment variable.
# Explicit loopback tests must not silently bypass their proxy through NO_PROXY.
clean_curl() {
  env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
    -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
    curl -q "$@"
}

listener_pids() {
  # macOS exposes root-owned socket PIDs through verbose netstat even when
  # unprivileged lsof cannot see them. Resolve the PID column by its header:
  # recent versions use process:pid, older versions use separate pid/epid.
  socket_owners=$(netstat -anv -p tcp 2>/dev/null | awk -v port="$1" '
    /^Proto / {
      gsub(/Local Address/, "Local-Address")
      gsub(/Foreign Address/, "Foreign-Address")
      for (i=1; i<=NF; i++) if ($i=="process:pid" || $i=="pid") pid_column=i
      next
    }
    /^tcp/ && ($4=="127.0.0.1." port || $4=="*." port) && $6=="LISTEN" {
      if (!pid_column) {unverified=1; next}
      pid=$pid_column
      sub(/^.*:/, "", pid)
      if (pid !~ /^[1-9][0-9]*$/) {unverified=1; next}
      print pid
    }
    END {if (unverified) print "unverified"}
  ' | sort -u)
  if [ -n "$socket_owners" ] \
    && ! printf '%s\n' "$socket_owners" | grep -qx unverified; then
    printf '%s\n' "$socket_owners"
    return 0
  fi
  if [ "$PRIVILEGED_OBSERVATION" = YES ]; then
    sudo -n lsof -nP -a -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null
  else
    # A partly visible table could hide a second owner's socket. Ordinary lsof
    # cannot resolve that ambiguity for root-owned providers.
    if printf '%s\n' "$socket_owners" | grep -qx unverified; then
      return 1
    fi
    lsof -nP -a -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null
  fi | sort -u
}

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
  lines=$(printf '%s\n' "$extlist" \
    | awk -v id="com.aetherroute.desktop.$ext" '
        /waiting to uninstall/ {next}
        {for (i=1; i<=NF; i++) if ($i==id) {print; break}}
      ')
  count=$(printf '%s\n' "$lines" | awk 'NF {n++} END {print n+0}')
  if [ "$count" -ne 1 ]; then
    check "$ext activated" "$count registrations; expected exactly one" fail
    continue
  fi
  line=$lines
  case "$line" in
    *"activated enabled"*)
      v=$(printf '%s\n' "$line" | sed -n 's/.*([^/]*\/\([0-9][0-9]*\)).*/\1/p')
      if [ -n "$v" ] && [ "$v" = "$build" ]; then
        check "$ext activated" "$v" pass
      else
        check "$ext activated" "${v:-unknown}, expected installed build $build" fail
      fi ;;
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
ROUTING=$(defaults read "$PREFS_DOMAIN" defaultRoutingMode 2>/dev/null || echo unknown)
case "$ENGINE" in
  tun|transparent) check "network engine" "$ENGINE" pass ;;
  *) check "network engine" "$ENGINE" fail ;;
esac
case "$ROUTING" in
  rule|global|direct) check "routing mode" "$ROUTING" pass ;;
  *) check "routing mode" "$ROUTING" fail ;;
esac

status=$(scutil --nc status AetherRoute 2>/dev/null | head -1 || echo "no configuration")
route_if=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')
CONNECTED=no
PROVIDER_PID=
PROVIDER_BINARY=
PROVIDER_START=
PROVIDER_VERIFIED=no
case "$ENGINE" in
  transparent) PROVIDER_ID=com.aetherroute.desktop.transparent-proxy ;;
  *) PROVIDER_ID=com.aetherroute.desktop.tunnel ;;
esac
provider_pids=$(pgrep -x "$PROVIDER_ID" 2>/dev/null || true)
provider_count=$(printf '%s\n' "$provider_pids" | awk 'NF {n++} END {print n+0}')
if [ "$provider_count" -eq 1 ]; then
  PROVIDER_PID=$provider_pids
  PROVIDER_BINARY=$(ps -p "$PROVIDER_PID" -o comm= | sed 's/^[[:space:]]*//')
  bundled_binary="$APP/Contents/Library/SystemExtensions/$PROVIDER_ID.systemextension/Contents/MacOS/$PROVIDER_ID"
  if [ -f "$PROVIDER_BINARY" ] && [ -f "$bundled_binary" ] \
    && cmp -s "$PROVIDER_BINARY" "$bundled_binary"; then
    PROVIDER_VERIFIED=yes
    check "running provider candidate" "PID $PROVIDER_PID matches installed executable" pass
  else
    check "running provider candidate" "PID $PROVIDER_PID executable differs or cannot be verified" fail
  fi
  PROVIDER_START=$(LC_ALL=C ps -p "$PROVIDER_PID" -o lstart= | sed 's/^[[:space:]]*//')
else
  check "running provider candidate" "$provider_count processes; expected exactly one" fail
fi

case "$ENGINE" in
  transparent)
    # A provider process may survive a stop request. Require the latest lifecycle
    # event from this exact process lifetime, rather than pgrep or old log output.
    provider_started=$(LC_ALL=C date -j -f '%a %b %e %T %Y' \
      "$PROVIDER_START" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
    lifecycle=
    if [ "$PROVIDER_VERIFIED" = yes ] && [ -n "$provider_started" ]; then
      lifecycle=$(log show --start "$provider_started" --style compact --info \
        --predicate "processIdentifier == $PROVIDER_PID AND (eventMessage CONTAINS \"stage=startProxy\" OR eventMessage CONTAINS \"stage=stopProxy\")" \
        2>/dev/null | grep -E 'stage=(startProxy|stopProxy) (requested|success|failed)' | tail -1 || true)
    fi
    if printf '%s\n' "$lifecycle" | grep -q 'stage=startProxy success'; then
      check "transparent proxy ready" "current provider completed startup" pass
      CONNECTED=yes
    else
      check "transparent proxy ready" "current startup success cannot be verified" fail
    fi
    check "IPv4 default route" "${route_if:-unavailable} (transparent engine creates no route)" \
      "$([ -n "$route_if" ] && echo pass || echo fail)" ;;
  *)
    check "VPN configuration" "$status" \
      "$([ "$status" = Connected ] && echo pass || echo fail)"
    check "IPv4 default route" "${route_if:-unavailable}" \
      "$(printf '%s\n' "$route_if" | grep -q '^utun' && echo pass || echo fail)"
    if [ "$status" = Connected ] && [ "$PROVIDER_VERIFIED" = yes ] \
      && printf '%s\n' "$route_if" | grep -q '^utun'; then
      CONNECTED=yes
    fi ;;
esac
check "active candidate connection" "$CONNECTED" \
  "$([ "$CONNECTED" = yes ] && echo pass || echo fail)"

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
    http_owned=no
    for spec in "HTTP:http://127.0.0.1:$http_port" \
                "SOCKS5:socks5h://127.0.0.1:$socks_port"; do
      name=${spec%%:*}
      proxy=${spec#*:}
      port=${proxy##*:}
      case "$port" in
        ''|*[!0-9]*) check "$name port" "invalid configured port" fail; continue ;;
      esac
      if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        check "$name port" "invalid configured port" fail
        continue
      fi
      owner_pids=$(listener_pids "$port" || true)
      if [ "$CONNECTED" != yes ]; then
        check "$name proxy :$port" "candidate is not connected" fail
        continue
      fi
      # No visible owner is inconclusive, never proof that a socket belongs to
      # a root Network Extension. Every listener on this port must be our PID.
      if [ -z "$owner_pids" ]; then
        check "$name proxy :$port" "listener ownership unavailable; use privileged observation on the test VM" fail
        continue
      fi
      if [ "$owner_pids" != "$PROVIDER_PID" ]; then
        check "$name proxy :$port" "listener is not exclusively owned by candidate provider PID $PROVIDER_PID" fail
        continue
      fi
      [ "$name" != HTTP ] || http_owned=yes
      code=$(clean_curl --noproxy '' -s -o /dev/null -w '%{http_code}' --max-time 15 -x "$proxy" \
        http://cp.cloudflare.com/generate_204 2>/dev/null) || code=000
      if [ "$code" = 204 ]; then
        check "$name proxy :$port" "answered 204 (candidate PID $PROVIDER_PID)" pass
      else
        check "$name proxy :$port" "candidate listener returned $code" fail
      fi
    done

    # macOS stores one host:port per protocol, and every Clash-derived setup
    # points both HTTP and SOCKS at the primary port. When that port spoke only
    # HTTP, SOCKS clients failed instantly — browsers broke while curl over the
    # HTTP proxy stayed green, so the fault never showed up in testing.
    mixed=unverified
    if [ "$http_owned" = yes ]; then
      mixed=$(clean_curl --noproxy '' -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -x "socks5h://127.0.0.1:$http_port" \
        http://cp.cloudflare.com/generate_204 2>/dev/null) || mixed=000
    fi
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
  out=$(clean_curl --proxy '' -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 20 "$url" \
    2>/dev/null) || out="000 timeout"
  code=${out%% *}
  secs=${out##* }
  if [ "$CONNECTED" != yes ]; then
    check "$label" "HTTP $code (candidate not connected)" skip
  elif printf '%s\n' "$expect" | grep -qw "$code"; then
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

egress=$(clean_curl --proxy '' -s --max-time 20 \
  https://api.ipify.org 2>/dev/null || true)
if [ "$CONNECTED" != yes ]; then
  check "egress address" "candidate not connected" skip
elif printf '%s\n' "$egress" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9A-Fa-f]*:[0-9A-Fa-f:]+$'; then
  check "observed egress address" "$egress (connectivity only; not node attribution)" pass
elif [ "$ROUTING" = direct ]; then
  # Direct mode deliberately bypasses every node, so the request leaves from
  # the local network. Whether that reaches the internet says nothing about
  # AetherRoute.
  check "egress address" "no answer (direct mode bypasses nodes)" skip
else
  check "egress address" "no answer" \
    "$([ "$CONNECTED" = yes ] && echo fail || echo skip)"
fi

# Keep completion time, HTTPS health, and native IPv6 coverage separate. On
# macOS, curl -6 can still connect to an IPv4-mapped address from fake-IP DNS;
# that path does not exercise native IPv6. A fast TLS failure is not a stall,
# but must still fail HTTPS acceptance. Direct mode measures the host network.
v6_exit=0
v6=$(clean_curl --proxy '' -s -o /dev/null \
  -w '%{time_total}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{remote_ip}|%{http_code}|%{ssl_verify_result}' \
  --max-time 12 -6 \
  https://ipv6.google.com/ 2>/dev/null) || v6_exit=$?
v6_valid=$(printf '%s\n' "$v6" | awk -F '|' '
  NR == 1 && NF == 7 {
    valid=1
    for (i=1; i<=4; i++) if ($i !~ /^[0-9]+([.][0-9]+)?$/) valid=0
    if ($6 !~ /^[0-9][0-9][0-9]$/ || $7 !~ /^[0-9]+$/) valid=0
  }
  END {if (NR == 1 && valid) print "yes"}')
if [ "$CONNECTED" != yes ]; then
  check "IPv6 probe completion time" "candidate not connected" skip
  check "IPv6 probe HTTPS" "candidate not connected" skip
  check "native IPv6 HTTPS coverage" "candidate not connected" skip
elif [ "$ROUTING" = direct ]; then
  check "IPv6 probe completion time" "direct mode — host network" skip
  check "IPv6 probe HTTPS" "direct mode — host network" skip
  check "native IPv6 HTTPS coverage" "direct mode — host network" skip
elif [ "$v6_valid" != yes ]; then
  check "IPv6 probe completion time" "invalid curl metrics (exit $v6_exit)" fail
  check "IPv6 probe HTTPS" "response cannot be verified" fail
  check "native IPv6 HTTPS coverage" "address family cannot be verified" skip
else
  IFS='|' read -r v6_total v6_dns v6_tcp v6_tls v6_remote v6_http v6_verify <<METRICS
$v6
METRICS
  v6_family=unavailable
  v6_remote_lower=$(printf '%s' "$v6_remote" | tr '[:upper:]' '[:lower:]')
  case "$v6_remote_lower" in
    ::ffff:* | 0:0:0:0:0:ffff:* | *:*.*) v6_family=IPv4-mapped ;;
    *:*) v6_family=native-IPv6 ;;
    ?*) v6_family=IPv4 ;;
  esac
  emit "  probe: ipv6.google.com; remote=${v6_remote:-none}; family=$v6_family; DNS=${v6_dns}s; TCP=${v6_tcp}s; TLS=${v6_tls}s; HTTP=$v6_http; verify=$v6_verify"
  v6_fast=$(awk -v total="$v6_total" 'BEGIN {print (total < 8 ? "yes" : "no")}')
  check "IPv6 probe completion time" "${v6_total}s (curl exit $v6_exit)" \
    "$([ "$v6_fast" = yes ] && echo pass || echo fail)"
  v6_https=no
  if [ "$v6_exit" -eq 0 ] && [ "$v6_verify" -eq 0 ] \
    && awk -v tcp="$v6_tcp" -v tls="$v6_tls" -v code="$v6_http" \
      'BEGIN {exit !(tcp > 0 && tls > 0 && code >= 100 && code <= 599)}' \
    && [ "$v6_family" != unavailable ]; then
    v6_https=yes
    check "IPv6 probe HTTPS" "HTTP $v6_http; TLS completed in ${v6_tls}s" pass
  elif { [ "$v6_exit" -eq 6 ] || [ "$v6_exit" -eq 7 ]; } \
    && awk -v tcp="$v6_tcp" -v tls="$v6_tls" -v code="$v6_http" \
      'BEGIN {exit !(tcp == 0 && tls == 0 && code == 0)}'; then
    check "IPv6 probe HTTPS" "endpoint unavailable (curl exit $v6_exit); HTTPS untested" skip
  else
    check "IPv6 probe HTTPS" "HTTP $v6_http; curl exit $v6_exit; TLS=${v6_tls}s; verify=$v6_verify" fail
  fi
  if [ "$v6_family" = native-IPv6 ] && [ "$v6_https" = yes ]; then
    check "native IPv6 HTTPS coverage" "verified native IPv6 response" pass
  elif [ "$v6_family" = IPv4-mapped ] || [ "$v6_family" = IPv4 ]; then
    check "native IPv6 HTTPS coverage" "$v6_family transport; native IPv6 untested" skip
  else
    check "native IPv6 HTTPS coverage" "no verified native IPv6 HTTPS response" skip
  fi
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

# Prevent an old provider's successful probes from surviving a stop/restart
# during this report. Recheck the same process lifetime and live VPN state.
final_pids=$(pgrep -x "$PROVIDER_ID" 2>/dev/null || true)
final_start=
if [ -n "$PROVIDER_PID" ]; then
  final_start=$(LC_ALL=C ps -p "$PROVIDER_PID" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//')
fi
if [ "$CONNECTED" = yes ] && [ "$final_pids" = "$PROVIDER_PID" ] \
  && [ -n "$PROVIDER_START" ] && [ "$final_start" = "$PROVIDER_START" ]; then
  if [ "$ENGINE" = transparent ]; then
    final_event=$(log show --start "$provider_started" --style compact --info \
      --predicate "processIdentifier == $PROVIDER_PID AND (eventMessage CONTAINS \"stage=startProxy\" OR eventMessage CONTAINS \"stage=stopProxy\")" \
      2>/dev/null | grep -E 'stage=(startProxy|stopProxy) (requested|success|failed)' | tail -1 || true)
    continuous=$(printf '%s\n' "$final_event" | grep -q 'stage=startProxy success' && echo yes || echo no)
  else
    final_status=$(scutil --nc status AetherRoute 2>/dev/null | head -1 || true)
    continuous=$([ "$final_status" = Connected ] && echo yes || echo no)
  fi
else
  continuous=no
fi
check "provider survived all probes" "$continuous" \
  "$([ "$continuous" = yes ] && echo pass || echo fail)"
emit ""

emit "summary: $PASS passed, $FAIL failed, $SKIP skipped"
[ -n "$REPORT" ] && emit "report: $REPORT"
exit "$FAIL"
