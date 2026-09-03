#!/bin/sh
set -eu
umask 077

EXPECTED_USER=chenxu
EXPECTED_AGENT_SHA256=8f9d1c1ea802146cd1f4761b1add21cf4cb4299482bfe54f93d690fb1fd1dc3b
EXPECTED_TEAM_ID=9M2P8L4D89
LABEL=com.aetherroute.validation.tart-guest-agent

test "$(id -un)" = "$EXPECTED_USER" || {
  echo "Refusing unexpected user: $(id -un)" >&2
  exit 1
}
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_AGENT="$SOURCE_DIR/tart-guest-agent"
SOURCE_PLIST="$SOURCE_DIR/$LABEL.plist"
for path in "$SOURCE_AGENT" "$SOURCE_PLIST"; do
  test -f "$path" || {
    echo "Missing bootstrap input: $path" >&2
    exit 66
  }
done

ACTUAL_SHA256=$(shasum -a 256 "$SOURCE_AGENT" | awk '{print $1}')
test "$ACTUAL_SHA256" = "$EXPECTED_AGENT_SHA256" || {
  echo "Refusing Tart Guest Agent with unexpected SHA256" >&2
  exit 1
}
codesign --verify --strict --verbose=2 "$SOURCE_AGENT"
ACTUAL_TEAM_ID=$(codesign -dv --verbose=4 "$SOURCE_AGENT" 2>&1 \
  | awk -F= '$1 == "TeamIdentifier" {print $2; exit}')
test "$ACTUAL_TEAM_ID" = "$EXPECTED_TEAM_ID" || {
  echo "Refusing Tart Guest Agent with unexpected TeamIdentifier" >&2
  exit 1
}
plutil -lint "$SOURCE_PLIST" >/dev/null

DESTINATION_DIRECTORY="$HOME/Library/Application Support/AetherRouteValidation"
DESTINATION_AGENT="$DESTINATION_DIRECTORY/tart-guest-agent"
DESTINATION_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIRECTORY="$HOME/Library/Logs/AetherRouteValidation"
mkdir -p "$DESTINATION_DIRECTORY" "$HOME/Library/LaunchAgents" "$LOG_DIRECTORY"
chmod 700 "$DESTINATION_DIRECTORY" "$LOG_DIRECTORY"

if [ -e "$DESTINATION_AGENT" ] \
  && [ "$(shasum -a 256 "$DESTINATION_AGENT" | awk '{print $1}')" != "$EXPECTED_AGENT_SHA256" ]; then
  echo "Refusing to overwrite an unexpected existing validation agent" >&2
  exit 1
fi
if [ -e "$DESTINATION_PLIST" ] && ! cmp -s "$SOURCE_PLIST" "$DESTINATION_PLIST"; then
  echo "Refusing to overwrite an unexpected existing validation LaunchAgent" >&2
  exit 1
fi

cp -p "$SOURCE_AGENT" "$DESTINATION_AGENT"
cp -p "$SOURCE_PLIST" "$DESTINATION_PLIST"
chmod 500 "$DESTINATION_AGENT"
chmod 600 "$DESTINATION_PLIST"

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$DESTINATION_PLIST"
launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"
launchctl print "$DOMAIN/$LABEL" \
  | awk '/state =|pid =|last exit code/ {print}'

RUNNING_SHA256=$(shasum -a 256 "$DESTINATION_AGENT" | awk '{print $1}')
test "$RUNNING_SHA256" = "$EXPECTED_AGENT_SHA256"
echo "Tart Guest Agent validation channel is ready for tart exec."
