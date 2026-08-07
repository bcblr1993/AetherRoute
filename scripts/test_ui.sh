#!/bin/sh
set -eu

REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SIGNING_HOME=$HOME
TEMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
case "$TEMP_BASE/" in
  "$HOME/Documents/"*|*/Documents/*)
    echo "AetherRoute UI tests refuse a temporary root inside Documents." >&2
    exit 1
    ;;
esac
DEVELOPER_TOOLS_STATUS=$(
  /usr/sbin/DevToolsSecurity -status 2>&1 || true
)
if ! printf '%s\n' "$DEVELOPER_TOOLS_STATUS" \
  | grep -Fq 'Developer mode is currently enabled.'; then
  echo "macOS Automation Mode is unavailable; no UI runner was started." >&2
  echo "Enable Developer Tools Security once, then rerun:" >&2
  echo "  sudo /usr/sbin/DevToolsSecurity -enable" >&2
  exit 77
fi
UI_SIGNING_IDENTITY=$(
  "$REPOSITORY_ROOT/scripts/resolve_development_signing_identity.sh"
)
LOCK_DIRECTORY="$TEMP_BASE/aetherroute-ui-tests.lock"
if ! mkdir "$LOCK_DIRECTORY" 2>/dev/null; then
  if [ "${AETHERROUTE_UI_TEST_WAIT_FOR_LOCK:-0}" != "1" ]; then
    echo "Another isolated AetherRoute UI test is already running." >&2
    exit 75
  fi
  echo "Waiting for the isolated AetherRoute UI test lock..." >&2
  until mkdir "$LOCK_DIRECTORY" 2>/dev/null; do
    sleep 1
  done
fi

TEST_ROOT=$(mktemp -d "$TEMP_BASE/aetherroute-ui-tests.XXXXXX")
ROOT="$TEST_ROOT/Workspace/AetherRoute"
DERIVED_DATA="$TEST_ROOT/DerivedData"
RESULT_BUNDLE="$TEST_ROOT/AetherRouteUITests.xcresult"
ISOLATED_HOME="$TEST_ROOT/Home"
RUN_DIRECTORY="$TEST_ROOT/Run"
ONLY_TEST=${AETHERROUTE_UI_TEST_ONLY:-}
SCREENSHOT_OUTPUT=${AETHERROUTE_UI_TEST_SCREENSHOT_OUTPUT:-}
CONFIGURATION=${AETHERROUTE_UI_TEST_CONFIGURATION:-Debug}
case "$CONFIGURATION" in
  Debug|Release) ;;
  *)
    echo "AETHERROUTE_UI_TEST_CONFIGURATION must be Debug or Release." >&2
    exit 64
    ;;
esac

cleanup() {
  RUNNER_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/AetherRouteUITests-Runner.app"
  PRODUCT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/AetherRoute.app"
  # Stop the complete test session first. Otherwise xcodebuild may deliver a
  # queued launch request after the generated runner has already been removed,
  # which macOS misleadingly reports as a damaged application.
  pkill -TERM -f "$DERIVED_DATA" 2>/dev/null || true
  attempts=0
  while [ "$attempts" -lt 25 ]; do
    if ! pgrep -f "$DERIVED_DATA" >/dev/null 2>&1; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 0.2
  done
  pkill -KILL -f "$DERIVED_DATA" 2>/dev/null || true
  # LaunchServices accepts XCTest launch requests asynchronously. Keep the
  # signed bundles in place briefly after the last matching process exits so a
  # queued request cannot resolve to an app that cleanup has already removed.
  sleep 2
  for application in "$RUNNER_APP" "$PRODUCT_APP"; do
    if [ -d "$application" ]; then
      /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
        -u "$application" >/dev/null 2>&1 || true
    fi
  done
  if [ -d /Applications/AetherRoute.app ]; then
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
      -f /Applications/AetherRoute.app >/dev/null 2>&1 || true
  fi
  find "$TEST_ROOT" -depth -delete 2>/dev/null || true
  rmdir "$LOCK_DIRECTORY" 2>/dev/null || true
}
cleanup_and_exit() {
  exit_code=$1
  trap - EXIT HUP INT TERM
  cleanup
  exit "$exit_code"
}
trap cleanup EXIT
trap 'cleanup_and_exit 129' HUP
trap 'cleanup_and_exit 130' INT
trap 'cleanup_and_exit 143' TERM

if [ -n "$SCREENSHOT_OUTPUT" ]; then
  case "$SCREENSHOT_OUTPUT" in
    /*) ;;
    *) SCREENSHOT_OUTPUT="$REPOSITORY_ROOT/$SCREENSHOT_OUTPUT" ;;
  esac
  if [ -e "$SCREENSHOT_OUTPUT" ]; then
    echo "Refusing to overwrite screenshot output: $SCREENSHOT_OUTPUT" >&2
    exit 1
  fi
fi

copy_test_workspace() {
  mkdir -p "$ROOT"
  for item in \
    .tools Config Core Licenses Services Sources Tests project.yml scripts
  do
    ditto "$REPOSITORY_ROOT/$item" "$ROOT/$item"
  done
}

extract_safe_screenshots() {
  [ -n "$SCREENSHOT_OUTPUT" ] || return 0
  ATTACHMENTS="$TEST_ROOT/Attachments"
  xcrun xcresulttool export attachments \
    --path "$RESULT_BUNDLE" \
    --output-path "$ATTACHMENTS" >/dev/null
  mkdir -p "$SCREENSHOT_OUTPUT"
  jq -r '
    .[] | .attachments[]
    | select(
        (.suggestedHumanReadableName | startswith("language-settings-zh"))
        or (.suggestedHumanReadableName | startswith("language-about-zh"))
        or (.suggestedHumanReadableName | startswith("expanded-overview-en-dark"))
        or (.suggestedHumanReadableName | startswith("expanded-overview-zh-light"))
      )
    | [.exportedFileName, .suggestedHumanReadableName] | @tsv
  ' "$ATTACHMENTS/manifest.json" |
  while IFS="$(printf '\t')" read -r exported name; do
    case "$name" in
      language-settings-zh*)
        cp "$ATTACHMENTS/$exported" \
          "$SCREENSHOT_OUTPUT/language-settings-zh.png"
        ;;
      language-about-zh*)
        cp "$ATTACHMENTS/$exported" \
          "$SCREENSHOT_OUTPUT/language-about-zh.png"
        ;;
      expanded-overview-en-dark*)
        cp "$ATTACHMENTS/$exported" \
          "$SCREENSHOT_OUTPUT/expanded-overview-en-dark.png"
        ;;
      expanded-overview-zh-light*)
        cp "$ATTACHMENTS/$exported" \
          "$SCREENSHOT_OUTPUT/expanded-overview-zh-light.png"
        ;;
    esac
  done
  screenshot_count=$(
    find "$SCREENSHOT_OUTPUT" -type f -name '*.png' | wc -l | tr -d ' '
  )
  expected_screenshot_count=0
  case "$ONLY_TEST" in
    "") expected_screenshot_count=4 ;;
    *testExpandedTextRemainsUsableAcross*) expected_screenshot_count=1 ;;
    *testApplicationLanguageChangesImmediatelyWithoutRelaunch*)
      expected_screenshot_count=2
      ;;
  esac
  if [ "$screenshot_count" -ne "$expected_screenshot_count" ]; then
    if [ "${test_status:-1}" -eq 0 ]; then
      echo "Expected $expected_screenshot_count safe UI screenshot(s), found $screenshot_count." >&2
      return 1
    fi
    printf 'Copied %s safe screenshot(s) before the UI test failure.\n' \
      "$screenshot_count"
    return 0
  fi
  printf 'Safe screenshots copied to %s; raw attachments remain temporary.\n' \
    "$SCREENSHOT_OUTPUT"
}

mkdir -p "$ISOLATED_HOME/tmp" "$RUN_DIRECTORY"
copy_test_workspace
"$ROOT/scripts/bootstrap.sh"

set -- xcodebuild build-for-testing \
  -project "$ROOT/AetherRoute.xcodeproj" \
  -scheme AetherRouteUIReview \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_ENTITLEMENTS= \
  "CODE_SIGN_IDENTITY=$UI_SIGNING_IDENTITY" \
  AD_HOC_CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

if [ "${AETHERROUTE_RUN_UI_RESPONSIVENESS:-NO}" = YES ]; then
  set -- "$@" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) AETHERROUTE_UI_RESPONSIVENESS'
fi

cd "$RUN_DIRECTORY"
build_status=0
HOME="$SIGNING_HOME" \
CFFIXED_USER_HOME="$ISOLATED_HOME" \
TMPDIR="$ISOLATED_HOME/tmp" \
AETHERROUTE_UI_TEST_ISOLATED_HOME="$ISOLATED_HOME" \
  "$@" \
  >"$TEST_ROOT/xcodebuild.log" 2>&1 || build_status=$?
if [ "$build_status" -ne 0 ]; then
  tail -160 "$TEST_ROOT/xcodebuild.log" >&2
  exit 1
fi

RUNNER_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/AetherRouteUITests-Runner.app"
PRODUCT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/AetherRoute.app"
for application in "$RUNNER_APP" "$PRODUCT_APP"; do
  codesign --verify --deep --strict "$application"
  codesign -dv --verbose=4 "$application" 2>&1 \
    | grep -Fq 'Authority=Apple Development:'
  if xattr -p com.apple.quarantine "$application" >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$application"
  fi
done

set -- xcodebuild test-without-building \
  -project "$ROOT/AetherRoute.xcodeproj" \
  -scheme AetherRouteUIReview \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_ENTITLEMENTS= \
  "CODE_SIGN_IDENTITY=$UI_SIGNING_IDENTITY" \
  AD_HOC_CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

if [ "${AETHERROUTE_RUN_UI_RESPONSIVENESS:-NO}" = YES ]; then
  set -- "$@" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) AETHERROUTE_UI_RESPONSIVENESS'
fi

if [ -n "$ONLY_TEST" ]; then
  set -- "$@" "-only-testing:$ONLY_TEST"
fi

test_status=0
HOME="$ISOLATED_HOME" \
CFFIXED_USER_HOME="$ISOLATED_HOME" \
TMPDIR="$ISOLATED_HOME/tmp" \
AETHERROUTE_UI_TEST_ISOLATED_HOME="$ISOLATED_HOME" \
  "$@" \
  >"$TEST_ROOT/xcodebuild.log" 2>&1 || test_status=$?
if [ "$test_status" -ne 0 ] &&
   grep -Fq 'Timed out while enabling automation mode.' \
     "$TEST_ROOT/xcodebuild.log"; then
  echo "XCTest automation service timed out; retrying once in the same isolated workspace." >&2
  pkill -TERM -f "$RUNNER_APP" 2>/dev/null || true
  pkill -TERM -f "$PRODUCT_APP" 2>/dev/null || true
  find "$RESULT_BUNDLE" -depth -delete 2>/dev/null || true
  : >"$TEST_ROOT/xcodebuild.log"
  test_status=0
  HOME="$ISOLATED_HOME" \
  CFFIXED_USER_HOME="$ISOLATED_HOME" \
  TMPDIR="$ISOLATED_HOME/tmp" \
  AETHERROUTE_UI_TEST_ISOLATED_HOME="$ISOLATED_HOME" \
    "$@" \
    >"$TEST_ROOT/xcodebuild.log" 2>&1 || test_status=$?
fi
if [ "$test_status" -ne 0 ] &&
   grep -Fq 'Timed out while enabling automation mode.' \
     "$TEST_ROOT/xcodebuild.log"; then
  echo "macOS Automation Mode is unavailable; no Documents access is required." >&2
  echo "Enable Developer Tools Security once, then rerun:" >&2
  echo "  sudo /usr/sbin/DevToolsSecurity -enable" >&2
  exit 77
fi
extract_safe_screenshots
if [ "$test_status" -ne 0 ]; then
  tail -160 "$TEST_ROOT/xcodebuild.log" >&2
  xcrun xcresulttool get test-results summary \
    --path "$RESULT_BUNDLE" 2>/dev/null || true
  exit 1
fi
tail -16 "$TEST_ROOT/xcodebuild.log"
printf 'UI tests passed; temporary result bundle deleted on exit.\n'
