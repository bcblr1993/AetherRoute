#!/bin/sh
# Downloads the pinned third-party servers the protocol interoperability tests
# run against, and builds the WireGuard loopback helper. Every file is checked
# against the SHA-256 the Tests/Interop runners pin; a cached file that still
# matches is kept. Usage: fetch_interop_tools.sh [/absolute/tools-directory]
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOLS=${1:-"$ROOT/build/interop-tools"}

# Keep these equal to the defaults in Tests/Interop/run-prebuilt-*.sh;
# scripts/test_protocol_interop_runner.sh fails when they drift apart.
SING_BOX_VERSION=1.13.15
SING_BOX_SHA256=89629d674086064d2211c2cdb5715635e231c81f1bd47c23ab379da698d892f2
SHADOW_TLS_VERSION=0.2.25
SHADOW_TLS_SHA256=a7c39d70cfc5868f654b19766b768518413ac4ffd9532ea8534a36a1d447b5b1
XRAY_VERSION=26.3.27
XRAY_SHA256=5d9dd24c0aba4b6cfcc6a33a5d67f854816ee17f392bf932ec8176da46f7e404
MIHOMO_VERSION=1.19.29
MIHOMO_SHA256=4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca

case $TOOLS in
  /*) ;;
  *)
    echo "tools directory must be absolute: $TOOLS" >&2
    exit 1
    ;;
esac
for command in curl shasum tar unzip go; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "fetching interop tools requires $command" >&2
    exit 1
  fi
done

mkdir -p "$TOOLS"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-interop-tools.XXXXXX")
trap 'find "$WORK_DIR" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

is_current() {
  [ -f "$1" ] && [ "$(sha256 "$1")" = "$2" ]
}

download() {
  curl --proto '=https' --tlsv1.2 -fsSL --retry 2 -m 600 -o "$2" "$1"
}

# install_verified SOURCE DESTINATION SHA256: refuses a file whose hash does
# not match, so a changed upstream release never replaces a pinned tool.
install_verified() {
  actual=$(sha256 "$1")
  if [ "$actual" != "$3" ]; then
    echo "checksum mismatch for $(basename "$2"): $actual (expected $3)" >&2
    exit 1
  fi
  chmod 755 "$1"
  mv "$1" "$2"
  echo "installed $(basename "$2")"
}

if is_current "$TOOLS/sing-box" "$SING_BOX_SHA256"; then
  echo "sing-box $SING_BOX_VERSION already present"
else
  download "https://github.com/SagerNet/sing-box/releases/download/v$SING_BOX_VERSION/sing-box-$SING_BOX_VERSION-darwin-arm64.tar.gz" \
    "$WORK_DIR/sing-box.tar.gz"
  tar -xzf "$WORK_DIR/sing-box.tar.gz" -C "$WORK_DIR"
  install_verified "$WORK_DIR/sing-box-$SING_BOX_VERSION-darwin-arm64/sing-box" \
    "$TOOLS/sing-box" "$SING_BOX_SHA256"
fi

if is_current "$TOOLS/shadow-tls" "$SHADOW_TLS_SHA256"; then
  echo "shadow-tls $SHADOW_TLS_VERSION already present"
else
  download "https://github.com/ihciah/shadow-tls/releases/download/v$SHADOW_TLS_VERSION/shadow-tls-aarch64-apple-darwin" \
    "$WORK_DIR/shadow-tls"
  install_verified "$WORK_DIR/shadow-tls" "$TOOLS/shadow-tls" "$SHADOW_TLS_SHA256"
fi

if is_current "$TOOLS/xray" "$XRAY_SHA256"; then
  echo "Xray $XRAY_VERSION already present"
else
  download "https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/Xray-macos-arm64-v8a.zip" \
    "$WORK_DIR/xray.zip"
  unzip -q "$WORK_DIR/xray.zip" xray -d "$WORK_DIR/xray"
  install_verified "$WORK_DIR/xray/xray" "$TOOLS/xray" "$XRAY_SHA256"
fi

# The ShadowQUIC runner pins and unpacks the compressed archive itself.
MIHOMO_ARCHIVE="mihomo-darwin-arm64-v$MIHOMO_VERSION.gz"
if is_current "$TOOLS/$MIHOMO_ARCHIVE" "$MIHOMO_SHA256"; then
  echo "Mihomo $MIHOMO_VERSION already present"
else
  download "https://github.com/MetaCubeX/mihomo/releases/download/v$MIHOMO_VERSION/$MIHOMO_ARCHIVE" \
    "$WORK_DIR/$MIHOMO_ARCHIVE"
  install_verified "$WORK_DIR/$MIHOMO_ARCHIVE" "$TOOLS/$MIHOMO_ARCHIVE" "$MIHOMO_SHA256"
fi

# Built from the pinned module in Tests/Interop/WireGuardGoServer; build.sh
# verifies the module and prints the helper's checksum.
sh "$ROOT/Tests/Interop/WireGuardGoServer/build.sh" \
  "$TOOLS/wireguard-go-loopback-server" >/dev/null
echo "built wireguard-go-loopback-server"

echo "Interop tools ready in $TOOLS"
