#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REMOTE_HOST=${1:-${AETHERROUTE_REMOTE:-}}
LOCAL_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-remote-interop-controller.XXXXXX")
REMOTE_TEMP=

if [ -z "$REMOTE_HOST" ]; then
  echo "usage: $0 user@host" >&2
  exit 64
fi

cleanup() {
  if [ -n "$REMOTE_TEMP" ]; then
    case "$REMOTE_TEMP" in
      /tmp/aetherroute-remote-interop.*)
        ssh "$REMOTE_HOST" "find '$REMOTE_TEMP' -depth -delete" \
          >/dev/null 2>&1 || true
        ;;
    esac
  fi
  find "$LOCAL_TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

SOURCE="$LOCAL_TEMP/source"
INTEROP="$SOURCE/Tests/Interop"
mkdir -p "$INTEROP" "$SOURCE/scripts"
for file in \
  run-prebuilt-matrix.sh run-prebuilt-reality.sh \
  run-prebuilt-wireguard.sh test-openssh.sh run-prebuilt-shadowquic.sh \
  sing-box-server.json.template xray-reality-server.json \
  sshd_config.template mihomo-shadowquic-server.yaml
do
  cp "$ROOT/Tests/Interop/$file" "$INTEROP/$file"
done
cp "$ROOT/scripts/remote_protocol_interop_worker.sh" "$SOURCE/scripts/"
cp "$ROOT/../references/interop-tools/clash-rs-2272555/clash-lib-protocol-tests" \
  "$INTEROP/clash-lib-tests"
cp "$ROOT/../references/interop-tools/sing-box-1.13.15/sing-box-1.13.15-darwin-arm64/sing-box" \
  "$INTEROP/sing-box"
cp "$ROOT/../references/interop-tools/shadow-tls-0.2.25/shadow-tls-aarch64-apple-darwin" \
  "$INTEROP/shadow-tls"
cp "$ROOT/../references/interop-tools/xray-26.3.27/xray" "$INTEROP/xray"
cp "$ROOT/../references/interop-tools/wireguard-go-f333402bd9cb/wireguard-go-loopback-server" \
  "$INTEROP/wireguard-go-loopback-server"
cp "$ROOT/../references/interop-tools/mihomo-1.19.29/mihomo-darwin-arm64-v1.19.29.gz" \
  "$INTEROP/mihomo-darwin-arm64-v1.19.29.gz"
chmod 755 "$SOURCE/scripts/remote_protocol_interop_worker.sh" \
  "$INTEROP"/*.sh "$INTEROP/clash-lib-tests" "$INTEROP/sing-box" \
  "$INTEROP/shadow-tls" "$INTEROP/xray" \
  "$INTEROP/wireguard-go-loopback-server"

test "$(shasum -a 256 "$INTEROP/clash-lib-tests" | awk '{print $1}')" = \
  b964b5724d0f553037600c45415ed0f78fc448da2f216fa234f259b3ec0895fa
test "$(shasum -a 256 "$INTEROP/sing-box" | awk '{print $1}')" = \
  89629d674086064d2211c2cdb5715635e231c81f1bd47c23ab379da698d892f2
test "$(shasum -a 256 "$INTEROP/shadow-tls" | awk '{print $1}')" = \
  a7c39d70cfc5868f654b19766b768518413ac4ffd9532ea8534a36a1d447b5b1
test "$(shasum -a 256 "$INTEROP/xray" | awk '{print $1}')" = \
  5d9dd24c0aba4b6cfcc6a33a5d67f854816ee17f392bf932ec8176da46f7e404
test "$(shasum -a 256 "$INTEROP/wireguard-go-loopback-server" | awk '{print $1}')" = \
  44df91d2694a094e8b4156ba07634a4a296b4625ae62d050996914cda8a55487
test "$(shasum -a 256 "$INTEROP/mihomo-darwin-arm64-v1.19.29.gz" | awk '{print $1}')" = \
  4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca

REMOTE_TEMP=$(ssh "$REMOTE_HOST" \
  'mktemp -d /tmp/aetherroute-remote-interop.XXXXXX')
case "$REMOTE_TEMP" in
  /tmp/aetherroute-remote-interop.*) ;;
  *) echo "unexpected remote temporary path: $REMOTE_TEMP" >&2; exit 1 ;;
esac

rsync -a "$SOURCE/" "$REMOTE_HOST:$REMOTE_TEMP/source/"
set +e
ssh "$REMOTE_HOST" \
  "'$REMOTE_TEMP/source/scripts/remote_protocol_interop_worker.sh' '$REMOTE_TEMP/source' '$REMOTE_TEMP/evidence'"
status=$?
set -e
mkdir -p "$LOCAL_TEMP/evidence"
rsync -a "$REMOTE_HOST:$REMOTE_TEMP/evidence/" "$LOCAL_TEMP/evidence/" \
  >/dev/null 2>&1 || true

if [ -n "${AETHERROUTE_INTEROP_EVIDENCE_DIR:-}" ]; then
  case "$AETHERROUTE_INTEROP_EVIDENCE_DIR" in
    /*) ;;
    *) echo "AETHERROUTE_INTEROP_EVIDENCE_DIR must be absolute" >&2; exit 64 ;;
  esac
  mkdir -p "$AETHERROUTE_INTEROP_EVIDENCE_DIR"
  cp -R "$LOCAL_TEMP/evidence/." "$AETHERROUTE_INTEROP_EVIDENCE_DIR/"
fi

if [ -f "$LOCAL_TEMP/evidence/result.env" ]; then
  cat "$LOCAL_TEMP/evidence/result.env"
fi
if [ "$status" -ne 0 ]; then
  for log in "$LOCAL_TEMP"/evidence/*.log; do
    test -f "$log" || continue
    echo "--- $(basename "$log") ---" >&2
    tail -80 "$log" >&2
  done
  exit "$status"
fi

grep -F 'test_status=0' "$LOCAL_TEMP/evidence/result.env" >/dev/null
grep -F 'network_unchanged=true' "$LOCAL_TEMP/evidence/result.env" >/dev/null
grep -F 'source_unchanged=true' "$LOCAL_TEMP/evidence/result.env" >/dev/null
echo "Remote protocol evidence copied and temporary directories cleaned."
