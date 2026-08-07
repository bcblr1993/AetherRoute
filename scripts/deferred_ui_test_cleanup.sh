#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 test-root derived-data runner-app product-app" >&2
  exit 64
fi

TEMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
GRACE_SECONDS=${AETHERROUTE_UI_CLEANUP_GRACE_SECONDS:-600}
PROBE_ONLY=${AETHERROUTE_UI_CLEANUP_PROBE_ONLY:-NO}

case "$GRACE_SECONDS" in
  ''|*[!0-9]*)
    echo "AETHERROUTE_UI_CLEANUP_GRACE_SECONDS must be an integer" >&2
    exit 64
    ;;
esac
if [ "$GRACE_SECONDS" -gt 1800 ]; then
  echo "AETHERROUTE_UI_CLEANUP_GRACE_SECONDS must not exceed 1800" >&2
  exit 64
fi
case "$PROBE_ONLY" in
  YES|NO) ;;
  *)
    echo "AETHERROUTE_UI_CLEANUP_PROBE_ONLY must be YES or NO" >&2
    exit 64
    ;;
esac
if [ "$PROBE_ONLY" = YES ]; then
  case "$(basename "$TEMP_BASE")" in
    aetherroute-ui-isolation-guards.*) ;;
    *)
      echo "UI cleanup probe mode is restricted to its disposable guard root" >&2
      exit 64
      ;;
  esac
  if [ "$GRACE_SECONDS" -gt 2 ]; then
    echo "UI cleanup probe mode must use a grace period of at most 2 seconds" >&2
    exit 64
  fi
fi

for directory in "$1" "$2" "$3" "$4"; do
  test -d "$directory" || {
    echo "Deferred UI cleanup requires existing directories" >&2
    exit 64
  }
done
TEST_ROOT=$(CDPATH= cd -- "$1" && pwd -P)
DERIVED_DATA=$(CDPATH= cd -- "$2" && pwd -P)
RUNNER_APP=$(CDPATH= cd -- "$3" && pwd -P)
PRODUCT_APP=$(CDPATH= cd -- "$4" && pwd -P)

test_root_parent=$(CDPATH= cd -- "$TEST_ROOT/.." && pwd -P)
test_root_name=$(basename "$TEST_ROOT")
if [ "$test_root_parent" != "$TEMP_BASE" ]; then
  echo "Refusing deferred cleanup outside the physical temporary directory" >&2
  exit 64
fi
case "$test_root_name" in
  aetherroute-ui-tests.*|aetherroute-signed-ne.*) ;;
  *)
    echo "Refusing deferred cleanup outside an AetherRoute UI test root" >&2
    exit 64
    ;;
esac
if [ "$DERIVED_DATA" != "$TEST_ROOT/DerivedData" ]; then
  echo "Refusing deferred cleanup for an unexpected DerivedData path" >&2
  exit 64
fi
case "$RUNNER_APP" in
  "$DERIVED_DATA"/Build/Products/Debug/AetherRouteUITests-Runner.app|\
  "$DERIVED_DATA"/Build/Products/Release/AetherRouteUITests-Runner.app) ;;
  *)
    echo "Refusing deferred cleanup for an unexpected UI runner path" >&2
    exit 64
    ;;
esac
case "$PRODUCT_APP" in
  "$DERIVED_DATA"/Build/Products/Debug/AetherRoute.app|\
  "$DERIVED_DATA"/Build/Products/Release/AetherRoute.app) ;;
  *)
    echo "Refusing deferred cleanup for an unexpected product path" >&2
    exit 64
    ;;
esac

cleanup() {
  find "$TEST_ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM
trap '' HUP

# Retaining all DerivedData for the LaunchServices quiet period wastes disk.
# Keep only Build/Products, which contains the exact signed runner and target
# paths needed by a delayed XCTest launch request, and remove the copied
# workspace, logs, indexes, intermediates, result bundle, and isolated home
# immediately. The final cleanup below still removes this compact remainder.
prune_children_except() {
  parent=$1
  keep=$2
  for child in "$parent"/* "$parent"/.[!.]* "$parent"/..?*; do
    [ -e "$child" ] || continue
    if [ "$child" != "$keep" ]; then
      find "$child" -depth -delete 2>/dev/null || true
    fi
  done
}
BUILD_DIRECTORY="$DERIVED_DATA/Build"
PRODUCTS_DIRECTORY="$BUILD_DIRECTORY/Products"
if [ ! -d "$PRODUCTS_DIRECTORY" ]; then
  echo "Deferred UI cleanup requires Build/Products" >&2
  exit 64
fi
prune_children_except "$TEST_ROOT" "$DERIVED_DATA"
prune_children_except "$DERIVED_DATA" "$BUILD_DIRECTORY"
prune_children_except "$BUILD_DIRECTORY" "$PRODUCTS_DIRECTORY"

# XCTest and LaunchServices exchange launch requests asynchronously. Keep the
# still-signed runner at its exact path for a bounded ten-minute quiet period,
# because macOS can retain a failed Automation Mode request for several minutes.
# Deleting the path while that request is pending turns a harmless timeout into
# a misleading "damaged application" alert. Nothing runs from this directory;
# any late matching process is stopped before the timer restarts.
quiet_ticks=0
required_ticks=$((GRACE_SECONDS * 4))
total_ticks=0
maximum_ticks=$((required_ticks * 2 + 4))
export AETHERROUTE_UI_DERIVED_DATA_NEEDLE=$DERIVED_DATA
matching_processes() {
  ps -axo pid=,ppid=,command= | awk -v self="$$" -v parent="$PPID" '
    BEGIN { needle = ENVIRON["AETHERROUTE_UI_DERIVED_DATA_NEEDLE"] }
    {
      pid = $1
      ppid = $2
      if (pid != self && pid != parent && index($0, needle) != 0) {
        print pid
      }
    }
  '
}
stop_matching_processes() {
  signal=$1
  found=0
  for pid in $(matching_processes); do
    found=1
    kill "-$signal" "$pid" 2>/dev/null || true
  done
  return "$found"
}
while [ "$quiet_ticks" -lt "$required_ticks" ] \
  && [ "$total_ticks" -lt "$maximum_ticks" ]; do
  if ! stop_matching_processes TERM; then
    quiet_ticks=0
  else
    quiet_ticks=$((quiet_ticks + 1))
  fi
  total_ticks=$((total_ticks + 1))
  if [ "$required_ticks" -gt 0 ]; then
    sleep 0.25
  fi
done
stop_matching_processes KILL || true

if [ "$PROBE_ONLY" = NO ]; then
  for application in "$RUNNER_APP" "$PRODUCT_APP"; do
    if [ -d "$application" ]; then
      /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
        -u "$application" >/dev/null 2>&1 || true
    fi
  done
fi
