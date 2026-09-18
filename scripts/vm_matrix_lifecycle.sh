#!/bin/sh
set -eu
umask 077

# Guest-only lifecycle checks for test_vm_acceptance_matrix.sh. System-owned
# providers may remain resident after NE teardown; PID absence is not teardown.
ACTION=${1:-}
BUILD=${2:-}
ARG=${3:-}
ENGINE=${4:-}
APP=${AETHERROUTE_APP_PATH:-/Applications/AetherRoute.app}
TIMEOUT=${AETHERROUTE_MATRIX_QUIT_TIMEOUT_SECONDS:-45}
case "$ACTION" in baseline|quit|ready) ;; *) exit 64 ;; esac
case "$BUILD:$TIMEOUT" in *[!0-9:]*|:*|*:) exit 64 ;; esac
test "$TIMEOUT" -ge 1 && test "$TIMEOUT" -le 60 || exit 64
test "$(defaults read "$APP/Contents/Info" CFBundleVersion)" = "$BUILD" || {
  echo 'lifecycle candidate build mismatch' >&2; exit 1;
}
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-matrix-lifecycle.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

pids_for() {
  pgrep -x "$1" 2>/dev/null && return 0
  status=$?
  test "$status" -eq 1
}

process_start() {
  started=$(LC_ALL=C ps -p "$1" -o lstart=) || return 1
  LC_ALL=C date -j -f '%a %b %e %T %Y' \
    "$(printf '%s\n' "$started" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" '+%Y-%m-%d %H:%M:%S'
}

provider_state() {
  provider_id=com.aetherroute.desktop.$1
  provider_pids=$(pids_for "$provider_id") || return 1
  provider_pid=$(printf '%s\n' "$provider_pids" | awk 'NF{n++;p=$1} END{if(n==1)print p}')
  if [ -z "$provider_pids" ]; then
    provider_event=absent; provider_identity=absent; return 0
  fi
  test -n "$provider_pid" || { echo "$provider_id has multiple processes"; return 1; }
  provider_binary=$(ps -p "$provider_pid" -o comm= | sed 's/^[[:space:]]*//')
  bundled="$APP/Contents/Library/SystemExtensions/$provider_id.systemextension/Contents/MacOS/$provider_id"
  test -f "$provider_binary" && cmp -s "$provider_binary" "$bundled" || {
    echo "$provider_id PID $provider_pid does not match the installed candidate"; return 1;
  }
  provider_started=$(process_start "$provider_pid") || return 1
  provider_identity=$provider_pid@$provider_started
  log show --start "$provider_started" --style compact --info \
    --predicate "processIdentifier == $provider_pid AND (eventMessage CONTAINS \"stage=startTunnel\" OR eventMessage CONTAINS \"stage=startCore\" OR eventMessage CONTAINS \"stage=stopTunnel\" OR eventMessage CONTAINS \"stage=startProxy\" OR eventMessage CONTAINS \"stage=stopProxy\")" \
    >"$TEMP/provider.log" 2>"$TEMP/log-error.txt" || {
      echo "cannot read current lifetime for $provider_id"; return 1;
    }
  provider_event=$(awk '/stage=(startTunnel|startCore|stopTunnel|startProxy|stopProxy) (requested|begin|submitted|success|failed|complete)/ {last=$0} END{print last}' "$TEMP/provider.log")
}

network_snapshot() {
  for destination in default 198.18.0.2; do
    route_state=$(route -n get "$destination" 2>/dev/null) || return 1
    route_interface=$(printf '%s\n' "$route_state" | awk '/interface:/{print $2;exit}')
    route_gateway=$(printf '%s\n' "$route_state" | awk '/gateway:/{print $2;exit}')
    test -n "$route_interface" && test -n "$route_gateway" || return 1
    printf 'route_%s=%s %s\n' "$destination" "$route_interface" "$route_gateway"
  done
  v6_routes=$(netstat -rn -f inet6) || return 1
  printf '%s\n' "$v6_routes" | grep -q '^Destination ' || return 1
  v6_defaults=$(printf '%s\n' "$v6_routes" | awk '$1=="default"{print $2,$4}' | LC_ALL=C sort)
  printf 'ipv6_defaults=%s\n' "$(printf '%s\n' "$v6_defaults" | shasum -a 256 | awk '{print $1}')"
  proxy_state=$(scutil --proxy) || return 1
  printf 'proxy_settings=%s\n' "$(printf '%s\n' "$proxy_state" | shasum -a 256 | awk '{print $1}')"
}

network_inactive() {
  app_pids=$(pids_for AetherRoute) || return 1
  test -z "$app_pids" || { echo 'App has not exited'; return 1; }
  nc_state=$(scutil --nc status AetherRoute 2>/dev/null) || return 1
  test "$(printf '%s\n' "$nc_state" | head -1)" = Disconnected || {
    echo 'NE configuration is not Disconnected'; return 1;
  }
  sockets=$(netstat -an -p tcp) || return 1
  printf '%s\n' "$sockets" | grep -q '^Proto ' || return 1
  listeners=$(printf '%s\n' "$sockets" | awk '/^tcp/ && $6=="LISTEN" && $4 ~ /[.:](7890|7891)$/ {print $1,$4,$6}')
  test -z "$listeners" || { printf 'proxy listeners remain: %s\n' "$listeners"; return 1; }
  network_snapshot >"$TEMP/network.txt" || { echo 'network state unavailable'; return 1; }
}

if [ "$ACTION" = ready ]; then
  case "$ARG" in tun) extension=tunnel ;; transparent) extension=transparent-proxy ;; *) exit 64 ;; esac
  test -n "$(pids_for AetherRoute)" || exit 1
  provider_state "$extension" || exit 1
  test "$provider_event" != absent || exit 1
  if [ "$ARG" = transparent ]; then
    printf '%s\n' "$provider_event" | grep -q 'stage=startProxy success' || exit 1
  else
    test "$(scutil --nc status AetherRoute 2>/dev/null | head -1)" = Connected || exit 1
    route -n get default | awk '/interface:/{print $2;exit}' | grep -q '^utun' || exit 1
  fi
  printf 'active candidate: engine=%s pid=%s started=%s\n' "$ARG" "$provider_pid" "$provider_started"
  exit 0
fi

case "$ARG" in /*) ;; *) exit 64 ;; esac
if [ "$ACTION" = baseline ]; then
  test ! -e "$ARG" || { echo 'refusing to replace lifecycle baseline'; exit 1; }
  network_inactive || exit 1
  grep -Eq '^route_default=utun|^route_198.18.0.2=utun' "$TEMP/network.txt" && {
    echo 'baseline still has a tunnel route'; exit 1;
  }
  cp "$TEMP/network.txt" "$TEMP/baseline.txt"
  printf 'build=%s\n' "$BUILD" >>"$TEMP/baseline.txt"
  for extension in tunnel transparent-proxy; do
    provider_state "$extension" || exit 1
    case "$provider_event" in
      absent|*'stage=stopTunnel complete'*|*'stage=stopProxy success'*) ;;
      '')
        # A prepare-only process may not have started an NE session. Remember
        # that exact lifetime; it cannot excuse missing stop evidence later
        # for an engine that the matrix has actually exercised.
        printf 'unstarted_%s=%s\n' "$extension" "$provider_identity" >>"$TEMP/baseline.txt" ;;
      *) echo "$extension is not inactive at baseline: $provider_event"; exit 1 ;;
    esac
  done
  cp "$TEMP/baseline.txt" "$ARG"
  cat "$ARG"
  echo 'disconnected network baseline captured'
  exit 0
fi

case "$ENGINE" in tun) exercised=tunnel ;; transparent) exercised=transparent-proxy ;; *) exit 64 ;; esac
test "$(awk -F= '$1=="build"{print $2}' "$ARG")" = "$BUILD" || exit 1
grep -E '^(route_|ipv6_|proxy_)' "$ARG" >"$TEMP/expected-network.txt"
app_pids=$(pids_for AetherRoute)
app_pid=$(printf '%s\n' "$app_pids" | awk 'NF{n++;p=$1} END{if(n==1)print p}')
test -n "$app_pid" || { echo 'cannot bind quit evidence to one running App'; exit 1; }
app_started=$(process_start "$app_pid")
printf 'quit candidate build=%s engine=%s app_pid=%s app_started=%s\n' "$BUILD" "$ENGINE" "$app_pid" "$app_started"
deadline=$(($(date +%s) + TIMEOUT))
osascript -e 'with timeout of 5 seconds' \
  -e 'tell application "AetherRoute" to quit' -e 'end timeout' 2>/dev/null || true

quit_complete() {
  network_inactive || return 1
  cmp -s "$TEMP/expected-network.txt" "$TEMP/network.txt" || {
    echo 'default/stub routes or system proxy did not return to baseline'
    cat "$TEMP/network.txt"; return 1;
  }
  log show --start "$app_started" --style compact --info \
    --predicate "processIdentifier == $app_pid AND eventMessage CONTAINS \"stage=applicationTermination disconnect\"" \
    >"$TEMP/app.log" 2>"$TEMP/log-error.txt" || return 1
  app_event=$(awk '/stage=applicationTermination disconnect (begin|complete)/ {last=$0} END{print last}' "$TEMP/app.log")
  printf '%s\n' "$app_event" | grep -q 'stage=applicationTermination disconnect complete stopped=true' || {
    echo 'current App lifecycle does not confirm NE disconnect completion'; return 1;
  }
  printf '%s\n' "$app_event"
  for extension in tunnel transparent-proxy; do
    provider_state "$extension" || return 1
    case "$extension:$provider_event" in
      *:absent) echo "$extension process exited" ;;
      tunnel:*'stage=stopTunnel complete'*|transparent-proxy:*'stage=stopProxy success'*)
        printf 'resident idle %s pid=%s latest=%s\n' "$extension" "$provider_pid" "$provider_event" ;;
      *:)
        baseline_identity=$(awk -F= -v key="unstarted_$extension" '$1==key{print substr($0,index($0,"=")+1)}' "$ARG")
        if [ "$extension" = "$exercised" ] || [ "$baseline_identity" != "$provider_identity" ]; then
          echo "$extension has no current stop evidence"; return 1
        fi ;;
      *) echo "$extension latest lifecycle is not stopped: $provider_event"; return 1 ;;
    esac
  done
}

while :; do
  if quit_complete >"$TEMP/attempt.txt" 2>&1; then
    cat "$TEMP/attempt.txt" "$TEMP/network.txt"
    echo 'quit verified: App exited, NE disconnected, proxy listeners removed and network baseline restored'
    exit 0
  fi
  cat "$TEMP/attempt.txt"
  test "$(date +%s)" -lt "$deadline" || {
    echo "quit verification exceeded ${TIMEOUT}s" >&2; exit 1;
  }
  sleep 1
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    now=$(date +%s)
    remaining=$((deadline - now))
    if [ "$remaining" -gt 0 ]; then
      elapsed=$((TIMEOUT - remaining))
      if [ $((elapsed % 4)) -eq 0 ]; then
        osascript -e 'tell application "AetherRoute" to quit' 2>/dev/null || true
      fi
      if [ "$elapsed" -ge 12 ]; then
        kill -TERM "$app_pid" 2>/dev/null || true
      fi
    fi
  fi
done
