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

codesign_with_retry() {
  attempt=1
  while [ "$attempt" -le 5 ]; do
    output=
    if output=$(codesign "$@" 2>&1); then
      [ -z "$output" ] || printf '%s\n' "$output"
      return 0
    fi
    if [ "$attempt" -lt 5 ] && printf '%s\n' "$output" | grep -Eiq '(timestamp service is not available|A timestamp was expected but was not found|resource temporarily unavailable)'; then
      echo "Apple timestamp service unavailable; retrying codesign ($attempt/5)..." >&2
      attempt=$((attempt + 1))
      sleep 3
      continue
    fi
    printf '%s\n' "$output" >&2
    return 1
  done
  return 1
}

find "$SPARKLE" -name "*.xpc" -o -name "Updater.app" -o -name "Autoupdate" | while read -r helper; do
  if [ "$IDENTITY" = "-" ]; then
    codesign -f -s - "$helper"
  else
    codesign_with_retry -f -s "$IDENTITY" -o runtime --timestamp=http://timestamp.apple.com/ts01 "$helper"
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
  codesign_with_retry -f -s "$IDENTITY" -o runtime --timestamp=http://timestamp.apple.com/ts01 "$SPARKLE"
  codesign_with_retry -f -s "$IDENTITY" --entitlements "$ENTITLEMENTS" -o runtime --timestamp=http://timestamp.apple.com/ts01 "$APP"
  rm -f "$ENTITLEMENTS"
  trap - EXIT HUP INT TERM
fi
