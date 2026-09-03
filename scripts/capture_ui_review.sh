#!/bin/sh
set -eu

REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SIGNING_IDENTITY=$(
  "$REPOSITORY_ROOT/scripts/resolve_development_signing_identity.sh"
)
STAMP=$(date '+%Y%m%d-%H%M%S')
OUTPUT=${1:-"outputs/aetherroute-ui-review-$STAMP"}
CASE_FILTER=${AETHERROUTE_UI_REVIEW_CASE_FILTER:-}
case "$OUTPUT" in
  /*) ;;
  *) OUTPUT="$REPOSITORY_ROOT/$OUTPUT" ;;
esac

if [ -e "$OUTPUT" ]; then
  echo "Refusing to overwrite existing UI review output: $OUTPUT" >&2
  exit 1
fi

TEMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
LOCK_DIRECTORY="$TEMP_BASE/aetherroute-ui-tests.lock"
if ! mkdir "$LOCK_DIRECTORY" 2>/dev/null; then
  echo "Another isolated AetherRoute UI session is already running." >&2
  exit 75
fi

TEMP=$(mktemp -d "$TEMP_BASE/aetherroute-ui-review.XXXXXX") || {
  rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
  exit 1
}
ROOT="$TEMP/Workspace/AetherRoute"
DERIVED_DATA_PATH="$TEMP/DerivedData"
CURRENT_PID=
OUTPUT_CREATED=0
OUTPUT_COMPLETE=0
cleanup() {
  if [ -n "$CURRENT_PID" ] && kill -0 "$CURRENT_PID" 2>/dev/null; then
    kill -TERM "$CURRENT_PID" 2>/dev/null || true
    wait "$CURRENT_PID" 2>/dev/null || true
  fi
  REVIEW_APP="$DERIVED_DATA_PATH/Build/Products/Debug/AetherRoute.app"
  if [ -d "$REVIEW_APP" ]; then
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
      -u "$REVIEW_APP" >/dev/null 2>&1 || true
  fi
  if [ -d /Applications/AetherRoute.app ]; then
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
      -f /Applications/AetherRoute.app >/dev/null 2>&1 || true
  fi
  find "$TEMP" -depth -delete 2>/dev/null || true
  if [ "$OUTPUT_CREATED" -eq 1 ] && [ "$OUTPUT_COMPLETE" -eq 0 ]; then
    find "$OUTPUT" -depth -delete 2>/dev/null || true
  fi
  rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

copy_review_workspace() {
  mkdir -p "$ROOT"
  for item in \
    .github .gitmodules .tools Artifacts/Validation CHANGELOG.md CONTRIBUTING.md \
    Config Docs Licenses README.md SECURITY.md Services Sources Tests \
    project.yml scripts
  do
    ditto "$REPOSITORY_ROOT/$item" "$ROOT/$item"
  done
  mkdir -p "$ROOT/Core"
  rsync -a --exclude '/Engine/target/' \
    "$REPOSITORY_ROOT/Core/" "$ROOT/Core/"
}

"$REPOSITORY_ROOT/scripts/source_manifest.sh" \
  >"$TEMP/repository-source-before.txt"
copy_review_workspace
"$ROOT/scripts/source_manifest.sh" >"$TEMP/source-manifest-pending.txt"
cmp -s \
  "$TEMP/repository-source-before.txt" \
  "$TEMP/source-manifest-pending.txt" || {
  echo "The disposable UI workspace does not match the repository source." >&2
  exit 1
}
xcrun swiftc \
  "$ROOT/scripts/ui_review_window_id.swift" \
  -o "$TEMP/ui_review_window_id"
if ! "$TEMP/ui_review_window_id" --preflight; then
  echo "Screen Recording permission is required for deterministic UI capture." >&2
  echo "Grant it to the launching terminal or SSH host process, then rerun." >&2
  exit 77
fi
mkdir -p "$OUTPUT"
OUTPUT_CREATED=1
mv "$TEMP/source-manifest-pending.txt" "$OUTPUT/source-manifest.txt"
mkdir -p "$TEMP/Home/tmp" "$TEMP/Run"

if [ -n "${AETHERROUTE_DERIVED_DATA_PATH:-}" ] || \
   [ "${AETHERROUTE_UI_REVIEW_SKIP_BUILD:-NO}" = YES ]; then
  echo "UI review capture always rebuilds inside its isolated temporary workspace." >&2
fi

"$ROOT/scripts/bootstrap.sh"
if ! xcodebuild \
  -jobs 1 \
  -project "$ROOT/AetherRoute.xcodeproj" \
  -scheme AetherRouteUIReview \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_ENTITLEMENTS= \
  "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY" \
  AD_HOC_CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  build >"$OUTPUT/build.log" 2>&1; then
  tail -160 "$OUTPUT/build.log" >&2
  exit 1
fi

APP="$DERIVED_DATA_PATH/Build/Products/Debug/AetherRoute.app"
EXECUTABLE="$APP/Contents/MacOS/AetherRoute"
test -x "$EXECUTABLE"
file "$EXECUTABLE" | grep -q 'arm64'
codesign --verify --deep --strict "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 \
  | grep -Fq 'Authority=Apple Development:'

capture() {
  name=$1
  language=$2
  appearance=$3
  section=$4
  window_size=$5
  state=$6
  engine=$7
  privacy=$8
  text_size=$9
  settings_tab=${10}
  png="$OUTPUT/$name.png"
  log="$OUTPUT/$name.log"

  if [ "$language" = zh-Hans ]; then
    locale=zh_CN
  else
    locale=en_US
  fi

  (
    cd "$TEMP/Run"
    exec env \
      HOME="$TEMP/Home" \
      CFFIXED_USER_HOME="$TEMP/Home" \
      TMPDIR="$TEMP/Home/tmp" \
      AETHERROUTE_UI_REVIEW="$state" \
      AETHERROUTE_UI_REVIEW_APPEARANCE="$appearance" \
      AETHERROUTE_UI_REVIEW_LANGUAGE="$language" \
      AETHERROUTE_UI_REVIEW_REDUCE_MOTION=1 \
      AETHERROUTE_UI_REVIEW_SECTION="$section" \
      AETHERROUTE_UI_REVIEW_WINDOW="$window_size" \
      AETHERROUTE_UI_REVIEW_ENGINE="$engine" \
      AETHERROUTE_UI_REVIEW_PRIVACY="$privacy" \
      AETHERROUTE_UI_REVIEW_TEXT_SIZE="$text_size" \
      AETHERROUTE_UI_REVIEW_SETTINGS_TAB="$settings_tab" \
      "$EXECUTABLE" \
        -AppleLanguages "($language)" \
        -AppleLocale "$locale" \
        -ApplePersistenceIgnoreState YES \
        -NSQuitAlwaysKeepsWindows NO \
        >"$log" 2>&1
  ) &
  CURRENT_PID=$!

  if [ "$settings_tab" != "-" ]; then
    # The main WindowGroup appears before SwiftUI creates the Settings scene.
    # Wait for that second scene so the largest-window lookup captures the
    # requested settings page instead of the now-inactive main window.
    sleep 1
  fi

  window_id=
  attempts=0
  while [ "$attempts" -lt 80 ]; do
    if [ "$settings_tab" = "-" ]; then
      window_id=$("$TEMP/ui_review_window_id" "$CURRENT_PID" 2>/dev/null || true)
    else
      window_id=$("$TEMP/ui_review_window_id" --settings "$CURRENT_PID" 2>/dev/null || true)
    fi
    if [ -n "$window_id" ]; then
      break
    fi
    if ! kill -0 "$CURRENT_PID" 2>/dev/null; then
      echo "AetherRoute exited before rendering $name" >&2
      exit 1
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  if [ -z "$window_id" ]; then
    echo "Timed out waiting for the AetherRoute review window: $name" >&2
    exit 1
  fi

  sleep 1
  screencapture -x -l "$window_id" "$png"
  test -s "$png"
  bytes=$(stat -f '%z' "$png")
  if [ "$bytes" -lt 40000 ]; then
    echo "UI review image is unexpectedly small: $name ($bytes bytes)" >&2
    exit 1
  fi
  expected_width=${window_size%x*}
  expected_height=${window_size#*x}
  pixel_width=$(sips -g pixelWidth "$png" | awk '/pixelWidth/ {print $2}')
  pixel_height=$(sips -g pixelHeight "$png" | awk '/pixelHeight/ {print $2}')
  if [ "$pixel_width" -lt "$expected_width" ] || \
     [ "$pixel_height" -lt "$expected_height" ]; then
    echo "UI review image has invalid dimensions: $name" >&2
    exit 1
  fi

  kill -TERM "$CURRENT_PID" 2>/dev/null || true
  wait "$CURRENT_PID" 2>/dev/null || true
  CURRENT_PID=
  printf '%s\t%sx%s\t%s bytes\n' \
    "$name" "$pixel_width" "$pixel_height" "$bytes"
}

CAPTURE_COUNT=0
while IFS='|' read -r name language appearance section size state engine privacy text_size settings_tab
do
  if [ -n "$CASE_FILTER" ] && \
     ! printf '%s\n' "$name" | grep -Eq "$CASE_FILTER"; then
    continue
  fi
  CAPTURE_COUNT=$((CAPTURE_COUNT + 1))
  capture \
    "$name" "$language" "$appearance" "$section" "$size" \
    "$state" "$engine" "$privacy" "$text_size" "$settings_tab"
done <<'CASES'
overview-en-light-tun|en|light|overview|940x640|connected|tun|accepted|standard|-
overview-zh-dark-transparent|zh-Hans|dark|overview|940x640|connected|transparent|accepted|standard|-
overview-en-light-disconnected|en|light|overview|940x640|disconnected|tun|accepted|standard|-
overview-zh-light-connecting|zh-Hans|light|overview|940x640|connecting|tun|accepted|standard|-
proxies-en-dark|en|dark|proxies|940x640|connected|tun|accepted|standard|-
proxies-zh-light|zh-Hans|light|proxies|940x640|connected|transparent|accepted|standard|-
proxies-disconnected-zh-light|zh-Hans|light|proxies|940x640|disconnected|transparent|accepted|standard|-
connections-en-light|en|light|connections|940x640|connected|tun|accepted|standard|-
connections-zh-dark|zh-Hans|dark|connections|940x640|connected|transparent|accepted|standard|-
connections-disconnected-zh-light|zh-Hans|light|connections|940x640|disconnected|transparent|accepted|standard|-
connections-en-dark-expanded|en|dark|connections|780x560|connected|tun|accepted|expanded|-
connections-zh-light-expanded|zh-Hans|light|connections|780x560|connected|tun|accepted|expanded|-
profiles-en-dark|en|dark|profiles|940x640|disconnected|tun|accepted|standard|-
profiles-zh-light|zh-Hans|light|profiles|940x640|disconnected|transparent|accepted|standard|-
rules-en-light|en|light|rules|940x640|connected|tun|accepted|standard|-
rules-zh-dark|zh-Hans|dark|rules|940x640|connected|transparent|accepted|standard|-
dns-en-dark|en|dark|dns|940x640|connected|tun|accepted|standard|-
dns-zh-light|zh-Hans|light|dns|940x640|connected|transparent|accepted|standard|-
minimum-en-expanded|en|light|overview|780x560|connected|tun|accepted|expanded|-
minimum-zh-expanded|zh-Hans|dark|overview|780x560|connected|tun|accepted|expanded|-
privacy-en-light|en|light|overview|780x560|loading|tun|pending|standard|-
privacy-zh-dark|zh-Hans|dark|overview|780x560|loading|tun|pending|standard|-
settings-general-en-light|en|light|overview|960x640|disconnected|tun|accepted|standard|general
settings-general-zh-dark|zh-Hans|dark|overview|960x640|disconnected|tun|accepted|standard|general
settings-privacy-en-dark|en|dark|overview|960x640|disconnected|tun|accepted|standard|privacy
settings-privacy-zh-light|zh-Hans|light|overview|960x640|disconnected|tun|accepted|standard|privacy
settings-bypass-en-light|en|light|overview|960x640|disconnected|tun|accepted|standard|bypass
settings-bypass-zh-dark|zh-Hans|dark|overview|960x640|disconnected|tun|accepted|standard|bypass
settings-diagnostics-en-dark|en|dark|overview|960x640|disconnected|tun|accepted|standard|diagnostics
settings-diagnostics-zh-light|zh-Hans|light|overview|960x640|disconnected|tun|accepted|standard|diagnostics
settings-account-en-light|en|light|overview|960x640|disconnected|tun|accepted|standard|account
settings-account-zh-dark|zh-Hans|dark|overview|960x640|disconnected|tun|accepted|standard|account
settings-licenses-en-dark|en|dark|overview|960x640|disconnected|tun|accepted|standard|licenses
settings-licenses-zh-light|zh-Hans|light|overview|960x640|disconnected|tun|accepted|standard|licenses
settings-about-en-light|en|light|overview|960x640|disconnected|tun|accepted|standard|about
settings-about-zh-dark|zh-Hans|dark|overview|960x640|disconnected|tun|accepted|standard|about
CASES

if grep -E \
  'WARNING: Application performed a reentrant operation|Fatal error:|Precondition failed|assertion failure' \
  "$OUTPUT"/*.log >&2; then
  echo "UI review rejected a runtime warning that may become a crash or assert." >&2
  exit 1
fi

"$REPOSITORY_ROOT/scripts/source_manifest.sh" \
  >"$TEMP/repository-source-after.txt"
cmp -s \
  "$TEMP/repository-source-before.txt" \
  "$TEMP/repository-source-after.txt" || {
  echo "Repository source changed during UI review capture." >&2
  exit 1
}
find "$OUTPUT/build.log" -delete 2>/dev/null || true
find "$OUTPUT" -type f \
  \( -name '*.png' -o -name '*.log' -o -name 'source-manifest.txt' \) \
  -print0 |
  sort -z |
  xargs -0 shasum -a 256 >"$OUTPUT/SHA256SUMS"
count=$(find "$OUTPUT" -name '*.png' -type f | wc -l | tr -d ' ')
log_count=$(find "$OUTPUT" -name '*.log' -type f | wc -l | tr -d ' ')
test "$CAPTURE_COUNT" -gt 0
test "$count" -eq "$CAPTURE_COUNT"
test "$log_count" -eq "$CAPTURE_COUNT"
OUTPUT_COMPLETE=1
printf 'UI review capture passed: screenshots=%s logs=%s output=%s network-extension=disabled\n' \
  "$count" "$log_count" "$OUTPUT"
