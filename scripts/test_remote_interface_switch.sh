#!/bin/sh
set -eu

# Runs scripts/test_interface_switch_recovery.sh on a remote Mac and waits for
# its verdict. The switch drops the SSH connection on the interface that
# moves, so the test runs detached there and this side polls its result file,
# reconnecting as needed (Tailscale or the other uplink comes back first).
#
#   sh scripts/test_remote_interface_switch.sh chenxu@100.64.0.3
#
# AetherRoute must already be connected on the remote Mac in the mode under
# test. Exit status is the remote script's: 0 PASS, 1 FAIL, 2 INCONCLUSIVE;
# 3 when no verdict arrived in time.

HOST=${1:?usage: test_remote_interface_switch.sh user@host}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
POLL_SECONDS=${AETHERROUTE_SWITCH_POLL_SECONDS:-5}
TIMEOUT_SECONDS=${AETHERROUTE_SWITCH_TIMEOUT_SECONDS:-900}
REMOTE_SCRIPT=aetherroute-interface-switch.sh
REMOTE_RESULT=aetherroute-interface-switch.txt

case "${AETHERROUTE_SWITCH_CYCLES:-3}" in
  ''|*[!0-9]*) echo "cycle count must be a positive integer" >&2; exit 64 ;;
esac
printf '%s\n' "$HOST" | grep -Eq '^[A-Za-z0-9._-]+@[A-Za-z0-9.:-]+$' || {
  echo "invalid host" >&2
  exit 64
}

remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=2 "$HOST" "$@"
}

scp -q -o BatchMode=yes -o ConnectTimeout=8 \
  "$ROOT/scripts/test_interface_switch_recovery.sh" "$HOST:$REMOTE_SCRIPT"
remote "rm -f $REMOTE_RESULT; AETHERROUTE_SWITCH_RESULT_FILE=\$HOME/$REMOTE_RESULT \
  AETHERROUTE_SWITCH_CYCLES=${AETHERROUTE_SWITCH_CYCLES:-3} \
  nohup sh \$HOME/$REMOTE_SCRIPT > /dev/null 2>&1 < /dev/null &"

waited=0
verdict=
while [ "$waited" -lt "$TIMEOUT_SECONDS" ]; do
  sleep "$POLL_SECONDS"
  waited=$((waited + POLL_SECONDS))
  result=$(remote "cat $REMOTE_RESULT 2>/dev/null" 2>/dev/null || true)
  case "$result" in
    *PASS:*) verdict=0 ;;
    *FAIL:*) verdict=1 ;;
    *INCONCLUSIVE:*) verdict=2 ;;
    *) continue ;;
  esac
  break
done

printf '%s\n' "${result:-}"
remote "rm -f $REMOTE_SCRIPT" 2>/dev/null || true
if [ -z "$verdict" ]; then
  echo "no verdict from $HOST within ${TIMEOUT_SECONDS}s" >&2
  exit 3
fi
exit "$verdict"
