#!/bin/sh
set -eu

APP=${1:-}
IDENTITY=${2:--}

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "Usage: $0 /path/to/AetherRoute.app [IDENTITY]" >&2
  exit 1
fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$SPARKLE" ]; then
  exit 0
fi

find "$SPARKLE" -type f | while read -r binary_file; do
  if file "$binary_file" | grep -q "Mach-O"; then
    archs=$(lipo -archs "$binary_file")
    if echo "$archs" | grep -q "x86_64"; then
      lipo -thin arm64 "$binary_file" -output "$binary_file.thin"
      mv "$binary_file.thin" "$binary_file"
    fi
  fi
done

find "$SPARKLE" -name "*.xpc" -o -name "Updater.app" -o -name "Autoupdate" | while read -r helper; do
  if [ "$IDENTITY" = "-" ]; then
    codesign -f -s - "$helper"
  else
    codesign -f -s "$IDENTITY" -o runtime --timestamp "$helper"
  fi
done

if [ "$IDENTITY" = "-" ]; then
  codesign -f -s - "$SPARKLE"
  codesign -f -s - "$APP"
else
  ENTITLEMENTS=$(mktemp "${TMPDIR:-/tmp}/sparkle_entitlements.XXXXXX.plist")
  trap 'rm -f "$ENTITLEMENTS"' EXIT HUP INT TERM
  codesign -d --entitlements :"$ENTITLEMENTS" "$APP"
  if grep -q '\$(' "$ENTITLEMENTS"; then
    echo "Extracted entitlements contain unexpanded template variables: $(grep '\$(' "$ENTITLEMENTS")" >&2
    exit 1
  fi
  codesign -f -s "$IDENTITY" -o runtime --timestamp "$SPARKLE"
  codesign -f -s "$IDENTITY" --entitlements "$ENTITLEMENTS" -o runtime --timestamp "$APP"
  rm -f "$ENTITLEMENTS"
  trap - EXIT HUP INT TERM
fi
