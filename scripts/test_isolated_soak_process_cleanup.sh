#!/bin/sh
set -eu
umask 077

# Exercise the exact runner cleanup against real, disposable processes. This
# compiles a tiny signal fixture; it never links a proxy core or changes network
# settings, and does not start the long soak.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-soak-cleanup-test.XXXXXX")
CURRENT_PID=
FLOW_BINARY="$TEMP/flow-core-smoke"
PACKET_BINARY="$TEMP/packet-core-smoke"
UNRELATED_PID=
cleanup_test() {
  stop_current_round 2>/dev/null || true
  if [ -n "$UNRELATED_PID" ]; then
    kill -KILL "$UNRELATED_PID" 2>/dev/null || true
    wait "$UNRELATED_PID" 2>/dev/null || true
  fi
  rm -rf "$TEMP"
}
trap cleanup_test EXIT HUP INT TERM

# Source only the marked production functions, not a second implementation of
# the kill logic and not the runner's build/24-hour execution entry point.
awk '/^# BEGIN owned round cleanup$/ {copy=1; next}
     /^# END owned round cleanup$/ {copy=0; exit}
     copy {print}' "$ROOT/scripts/test_isolated_soak.sh" >"$TEMP/cleanup.sh"
grep -q '^stop_current_round()' "$TEMP/cleanup.sh"
. "$TEMP/cleanup.sh"
awk '/^run_with_watchdog\(\)/ {copy=1}
     copy {print}
     copy && /^}$/ {exit}' "$ROOT/scripts/test_isolated_soak.sh" >"$TEMP/watchdog.sh"
grep -q '^run_with_watchdog()' "$TEMP/watchdog.sh"
. "$TEMP/watchdog.sh"
cat >"$TEMP/linger.c" <<'C'
#include <signal.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "ignore") == 0) {
        signal(SIGTERM, SIG_IGN);
    }
    if (argc > 1 && strcmp(argv[1], "fork") == 0) {
        signal(SIGTERM, SIG_IGN);
        if (fork() < 0) return 2;
    }
    for (;;) pause();
}
C
clang -std=c17 -Wall -Wextra -Werror "$TEMP/linger.c" -o "$FLOW_BINARY"
cp "$FLOW_BINARY" "$PACKET_BINARY"
mkdir "$TEMP/unrelated"
cp "$FLOW_BINARY" "$TEMP/unrelated/flow-core-smoke"

await_child() {
  attempt=0
  CHILD_PID=
  while [ "$attempt" -lt 50 ]; do
    CHILD_PID=$(pgrep -P "$CURRENT_PID" 2>/dev/null | head -1 || true)
    [ -z "$CHILD_PID" ] || return 0
    attempt=$((attempt + 1))
    sleep 0.1
  done
  echo 'time wrapper did not launch its fixture child' >&2
  exit 1
}

assert_gone() {
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    remaining=no
    for observed_pid in "$@"; do
      if kill -0 "$observed_pid" 2>/dev/null; then remaining=yes; fi
    done
    [ "$remaining" = yes ] || return 0
    attempt=$((attempt + 1))
    sleep 0.1
  done
  echo "cleanup left an owned process running: $*" >&2
  exit 1
}

# Trigger the actual production watchdog against a hung fixture, with its
# deadline shortened to one second. It must return 124 and preserve failure
# evidence after terminating both the timed wrapper and its child.
OUTPUT="$TEMP/evidence"
mkdir "$OUTPUT" "$TEMP/flow-runtime"
ROUND_TIMEOUT=1
FD_GROWTH_BUDGET=4
watchdog_status=0
run_with_watchdog flow 1 || watchdog_status=$?
test "$watchdog_status" -eq 124
test -f "$OUTPUT/failure-flow-round-1.log"
test -z "$CURRENT_PID"
for observed_pid in $(pgrep -f "$FLOW_BINARY" 2>/dev/null || true); do
  executable=$(ps -p "$observed_pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//')
  test "$executable" != "$FLOW_BINARY"
done
echo 'PASS: production watchdog times out, records evidence, and leaves no harness'

# A normal timeout/signal cleanup terminates both /usr/bin/time and its child.
/usr/bin/time -lp "$FLOW_BINARY" >"$TEMP/graceful.log" 2>&1 &
CURRENT_PID=$!
await_child
observed_pids="$CURRENT_PID $CHILD_PID"
stop_current_round
assert_gone $observed_pids
echo 'PASS: time wrapper and harness terminate together'

# A harness that ignores TERM still dies after the bounded grace period, along
# with its descendant; the runner may then safely remove its temporary files.
/usr/bin/time -lp "$FLOW_BINARY" fork >"$TEMP/stubborn.log" 2>&1 &
CURRENT_PID=$!
await_child
attempt=0
grandchild=
while [ "$attempt" -lt 50 ]; do
  grandchild=$(pgrep -P "$CHILD_PID" 2>/dev/null | head -1 || true)
  [ -z "$grandchild" ] || break
  attempt=$((attempt + 1))
  sleep 0.1
done
test -n "$grandchild"
observed_pids="$CURRENT_PID $CHILD_PID $grandchild"
stop_current_round
assert_gone $observed_pids
echo 'PASS: TERM-resistant harness and grandchild are killed within the timeout'

# Reproduce the original bug: the wrapper is already dead, so the harness has
# been reparented. Exact executable matching recovers it without touching an
# unrelated process that happens to use the same executable basename.
"$TEMP/unrelated/flow-core-smoke" ignore >"$TEMP/unrelated.log" 2>&1 &
UNRELATED_PID=$!
/usr/bin/time -lp "$PACKET_BINARY" ignore >"$TEMP/orphan.log" 2>&1 &
CURRENT_PID=$!
await_child
orphan_pid=$CHILD_PID
kill -TERM "$CURRENT_PID"
wait "$CURRENT_PID" 2>/dev/null || true
CURRENT_PID=
kill -0 "$orphan_pid"
stop_current_round
assert_gone "$orphan_pid"
kill -0 "$UNRELATED_PID"
echo 'PASS: orphaned harness is removed while an unrelated same-name process survives'

echo 'Isolated soak process cleanup regressions passed: 4 cases'
