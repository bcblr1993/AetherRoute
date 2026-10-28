#!/bin/sh
# Compares a subscription on Mihomo (the reference) and on our engine.
#
# Usage: compare_subscription_with_mihomo.sh <https-url | /absolute/payload> [/absolute/output-dir]
#
# Mihomo loads the subscription as served; our engine loads what the app
# would: the import normalizer plus the domestic routing optimizer
# (AETHER_DIFFERENTIAL_NO_DOMESTIC=1 skips the optimizer). Every node is
# probed through both engines' delay API, and nodes Mihomo can use but we
# cannot, or that our engine never loaded, are reported.
#
# The subscription and engine configs live only in a private temporary
# directory that is deleted on exit; the report names protocols and options,
# never servers or credentials (AETHER_DIFFERENTIAL_REDACT_NAMES=1 also hides
# node names). Run it where no system-wide proxy or tunnel carries the
# engines' traffic, or the results describe that proxy instead: the script
# refuses to run while an AetherRoute or other VPN session is connected
# unless AETHER_DIFFERENTIAL_ALLOW_TUNNEL=1. On a Mac whose own traffic always
# goes through a tunnel, set AETHER_DIFFERENTIAL_HOST=user@host: the profile
# is still prepared here, then both engines run on that machine from a
# private temporary directory that is removed afterwards.
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOLS=${AETHER_INTEROP_TOOLS:-"$ROOT/build/interop-tools"}
ENGINE=${AETHER_DIFFERENTIAL_ENGINE:-"$ROOT/build/differential-target/release/clash-rs"}
MIHOMO_ARCHIVE="$TOOLS/mihomo-darwin-arm64-v1.19.29.gz"
MIHOMO_SHA256=${MIHOMO_SHA256:-}
SOURCE=${1:-}
OUTPUT=${2:-"$ROOT/outputs/subscription-diff-$(date -u +%Y%m%dT%H%M%SZ)"}

case "$SOURCE" in
  https://*|/*) ;;
  *) echo "usage: $0 <https-url | /absolute/payload> [/absolute/output-dir]" >&2; exit 64 ;;
esac
case "$OUTPUT" in
  /*) ;;
  *) echo "output directory must be absolute" >&2; exit 64 ;;
esac
test -f "$MIHOMO_ARCHIVE" || {
  echo "missing $MIHOMO_ARCHIVE; run scripts/fetch_interop_tools.sh first" >&2
  exit 1
}
if [ -n "$MIHOMO_SHA256" ]; then
  actual=$(shasum -a 256 "$MIHOMO_ARCHIVE" | awk '{print $1}')
  test "$actual" = "$MIHOMO_SHA256" || { echo "mihomo archive checksum mismatch" >&2; exit 1; }
fi
REMOTE=${AETHER_DIFFERENTIAL_HOST:-}
# A full tunnel owns the default route through a utun; a transparent proxy
# keeps the physical default route, but its running provider shows.
tunnel_active() {
  route -n get default 2>/dev/null | grep -q 'interface: utun' && return 0
  pgrep -f 'transparent-proxy\.systemext' >/dev/null 2>&1 \
    && pgrep -x AetherRoute >/dev/null 2>&1
}
if [ -z "$REMOTE" ] && [ "${AETHER_DIFFERENTIAL_ALLOW_TUNNEL:-0}" != 1 ] && tunnel_active; then
  echo "a VPN, AetherRoute tunnel or transparent proxy is active; its routing would skew the comparison." >&2
  echo "set AETHER_DIFFERENTIAL_HOST=user@host to run on a clean machine, or AETHER_DIFFERENTIAL_ALLOW_TUNNEL=1" >&2
  exit 69
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-subscription-diff.XXXXXX")
cleanup() {
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

if [ ! -x "$ENGINE" ]; then
  echo "Building our engine (clash-rs, app feature set)"
  (
    cd "$ROOT/Core/Engine"
    CARGO_TARGET_DIR="$ROOT/build/differential-target" cargo build --locked -p clash-rs \
      --release --no-default-features \
      --features "shadowsocks,ssh,shadowquic,wireguard,aws-lc-rs,clash-lib/aether-tuic,clash-lib/zero_copy"
  ) >"$WORK/engine-build.log" 2>&1 || { tail -n 30 "$WORK/engine-build.log" >&2; exit 1; }
fi

PAYLOAD="$WORK/payload"
case "$SOURCE" in
  https://*)
    curl -fsS --max-time 60 -A "clash-verge/v2.2.3" -o "$PAYLOAD" "$SOURCE" || {
      echo "subscription download failed" >&2
      exit 1
    }
    LABEL="url"
    ;;
  *)
    cp "$SOURCE" "$PAYLOAD"
    LABEL="file"
    ;;
esac

swiftc -swift-version 6 -parse-as-library \
  "$ROOT"/Sources/AetherRouteKit/*.swift \
  "$ROOT/Tests/SubscriptionDifferential/main.swift" \
  -o "$WORK/profile" >"$WORK/swiftc.log" 2>&1 || { tail -n 30 "$WORK/swiftc.log" >&2; exit 1; }
if [ "${AETHER_DIFFERENTIAL_NO_DOMESTIC:-0}" = 1 ]; then
  "$WORK/profile" "$PAYLOAD" "$WORK/ours.yaml" "$WORK/reference.yaml" "$WORK/normalize.json" --no-domestic
else
  "$WORK/profile" "$PAYLOAD" "$WORK/ours.yaml" "$WORK/reference.yaml" "$WORK/normalize.json"
fi

MIHOMO="$WORK/mihomo"
gunzip -c "$MIHOMO_ARCHIVE" >"$MIHOMO"
chmod 700 "$MIHOMO"
REDACT=
test "${AETHER_DIFFERENTIAL_REDACT_NAMES:-0}" = 1 && REDACT=--redact-names
status=0
if [ -z "$REMOTE" ]; then
  PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/subscription_differential.py" \
    --raw "$WORK/reference.yaml" --ours "$WORK/ours.yaml" --mihomo "$MIHOMO" \
    --engine "$ENGINE" --work "$WORK" --out "$OUTPUT" --source "$LABEL" $REDACT || status=$?
else
  # YAML is parsed here (the remote may lack Ruby); JSON travels.
  PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/scripts/subscription_differential.py" \
    --raw "$WORK/reference.yaml" --ours "$WORK/ours.yaml" --mihomo /dev/null \
    --engine /dev/null --work "$WORK" --out "$WORK" --to-json
  STAGE="$WORK/stage"
  mkdir -m 700 -p "$STAGE/scripts" "$STAGE/Config/RoutingResources" "$STAGE/bin" "$STAGE/in"
  cp "$ROOT/scripts/subscription_differential.py" "$STAGE/scripts/"
  cp "$ROOT/Config/RoutingResources/Country.mmdb" "$ROOT/Config/RoutingResources/GeoSite.dat" \
    "$STAGE/Config/RoutingResources/"
  cp "$MIHOMO" "$STAGE/bin/mihomo"
  cp "$ENGINE" "$STAGE/bin/clash-rs"
  cp "$WORK/reference.json" "$WORK/ours.json" "$STAGE/in/"
  REMOTE_DIR=$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$REMOTE" \
    'umask 077; mktemp -d /tmp/aetherroute-subscription-diff.XXXXXX')
  case "$REMOTE_DIR" in
    /tmp/aetherroute-subscription-diff.*) ;;
    *) echo "unexpected remote work directory" >&2; exit 1 ;;
  esac
  remote_cleanup() {
    ssh -o BatchMode=yes -o ConnectTimeout=20 "$REMOTE" \
      "find '$REMOTE_DIR' -depth -delete" 2>/dev/null || true
  }
  trap 'remote_cleanup; cleanup' EXIT HUP INT TERM
  (cd "$STAGE" && tar -cf - .) | ssh -o BatchMode=yes "$REMOTE" "tar -xf - -C '$REMOTE_DIR'"
  ssh -o BatchMode=yes -o ServerAliveInterval=15 "$REMOTE" \
    "cd '$REMOTE_DIR' && PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 scripts/subscription_differential.py \
      --raw in/reference.json --ours in/ours.json --mihomo bin/mihomo --engine bin/clash-rs \
      --work '$REMOTE_DIR' --out '$REMOTE_DIR/out' --source '$LABEL@remote' $REDACT" || status=$?
  mkdir -p "$OUTPUT"
  ssh -o BatchMode=yes "$REMOTE" "cat '$REMOTE_DIR/out/report.json'" >"$OUTPUT/report.json"
  ssh -o BatchMode=yes "$REMOTE" "cat '$REMOTE_DIR/out/report.md'" >"$OUTPUT/report.md"
fi
cp "$WORK/normalize.json" "$OUTPUT/normalize.json"
exit "$status"
