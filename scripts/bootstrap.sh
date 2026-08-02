#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOLS="$ROOT/.tools"
XCODEGEN_VERSION=2.46.0
XCODEGEN="$TOOLS/xcodegen/xcodegen/bin/xcodegen"
XCODEGEN_ARCHIVE_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
XCODEGEN_BINARY_SHA256=8774da746668bc18fe74e54cbaf10f2631a1fb05947cd374179aa912f14f99db

mkdir -p "$TOOLS"

file_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

if [ ! -x "$XCODEGEN" ] || \
  [ "$(file_sha256 "$XCODEGEN")" != "$XCODEGEN_BINARY_SHA256" ]; then
  ARCHIVE="$TOOLS/xcodegen.zip"
  DOWNLOAD="$TOOLS/xcodegen.zip.download"
  curl --fail --location --silent --show-error \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
    --output "$DOWNLOAD"
  if [ "$(file_sha256 "$DOWNLOAD")" != "$XCODEGEN_ARCHIVE_SHA256" ]; then
    rm -f "$DOWNLOAD"
    echo "XcodeGen archive checksum mismatch" >&2
    exit 1
  fi
  mv "$DOWNLOAD" "$ARCHIVE"
  rm -rf "$TOOLS/xcodegen"
  mkdir -p "$TOOLS/xcodegen"
  ditto -x -k "$ARCHIVE" "$TOOLS/xcodegen"
fi

if [ "$(file_sha256 "$XCODEGEN")" != "$XCODEGEN_BINARY_SHA256" ]; then
  echo "XcodeGen binary checksum mismatch" >&2
  exit 1
fi

"$XCODEGEN" generate --spec "$ROOT/project.yml" --project "$ROOT"
