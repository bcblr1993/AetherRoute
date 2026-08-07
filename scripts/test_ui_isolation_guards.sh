#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UI_TEST_SCRIPT="$ROOT/scripts/test_ui.sh"
UI_CAPTURE_SCRIPT="$ROOT/scripts/capture_ui_review.sh"
IDLE_PERFORMANCE_SCRIPT="$ROOT/scripts/test_disconnected_idle_performance.sh"
SIGNING_HELPER="$ROOT/scripts/resolve_development_signing_identity.sh"
REMOTE_UI_WORKER="$ROOT/scripts/remote_ui_worker.sh"
UI_WINDOW_SELECTOR="$ROOT/scripts/ui_review_window_id.swift"
UI_TEST_SOURCE="$ROOT/Tests/AetherRouteUITests/AetherRouteUITests.swift"
UNIT_TEST_SCHEME="$ROOT/AetherRoute.xcodeproj/xcshareddata/xcschemes/AetherRouteUnitTests.xcscheme"

for script in \
  "$UI_TEST_SCRIPT" "$UI_CAPTURE_SCRIPT" "$IDLE_PERFORMANCE_SCRIPT" \
  "$SIGNING_HELPER"
do
  sh -n "$script"
done

for script in "$UI_TEST_SCRIPT" "$UI_CAPTURE_SCRIPT"; do
  grep -Fq 'aetherroute-ui-tests.lock' "$script"
  grep -Fq 'Workspace/AetherRoute' "$script"
done

sh -n "$REMOTE_UI_WORKER"
grep -Fq 'AETHERROUTE_UI_TEST_WAIT_FOR_LOCK=1' "$REMOTE_UI_WORKER"
grep -Fq 'network_control_before_sha256' "$REMOTE_UI_WORKER"
grep -Fq 'network_control_after_sha256' "$REMOTE_UI_WORKER"
grep -Fq 'source_unchanged=true' "$REMOTE_UI_WORKER"
grep -Fq '"IOConsoleLocked"' "$REMOTE_UI_WORKER"
grep -Fq 'console_locked_before=' "$REMOTE_UI_WORKER"
grep -Fq '/usr/bin/caffeinate -dimsu /usr/bin/env' "$REMOTE_UI_WORKER"
grep -Fq 'No UI runner was started' "$REMOTE_UI_WORKER"

grep -Fq 'copy_test_workspace' "$UI_TEST_SCRIPT"
grep -Fq 'UI tests refuse a temporary root inside Documents' "$UI_TEST_SCRIPT"
grep -Fq 'HOME="$ISOLATED_HOME"' "$UI_TEST_SCRIPT"
grep -Fq 'SIGNING_HOME=$HOME' "$UI_TEST_SCRIPT"
grep -Fq 'HOME="$SIGNING_HOME"' "$UI_TEST_SCRIPT"
grep -Fq 'CFFIXED_USER_HOME="$ISOLATED_HOME"' "$UI_TEST_SCRIPT"
grep -Fq 'TMPDIR="$ISOLATED_HOME/tmp"' "$UI_TEST_SCRIPT"
grep -Fq 'AETHERROUTE_UI_TEST_ISOLATED_HOME' "$UI_TEST_SCRIPT"
grep -Fq '/usr/sbin/DevToolsSecurity -status' "$UI_TEST_SCRIPT"
grep -Fq 'no UI runner was started.' "$UI_TEST_SCRIPT"
grep -Fq 'Timed out while enabling automation mode.' "$UI_TEST_SCRIPT"
grep -Fq 'no Documents access is required' "$UI_TEST_SCRIPT"
grep -Fq 'sudo /usr/sbin/DevToolsSecurity -enable' "$UI_TEST_SCRIPT"
grep -Fq 'security find-identity -v -p codesigning' "$SIGNING_HELPER"
grep -Fq 'A trusted Apple Development identity is required' "$SIGNING_HELPER"
for script in \
  "$UI_TEST_SCRIPT" "$UI_CAPTURE_SCRIPT" "$IDLE_PERFORMANCE_SCRIPT"
do
  grep -Fq 'resolve_development_signing_identity.sh' "$script"
  grep -Fq 'CODE_SIGN_STYLE=Manual' "$script"
  grep -Fq 'CODE_SIGNING_REQUIRED=YES' "$script"
  grep -Fq 'AD_HOC_CODE_SIGNING_ALLOWED=NO' "$script"
  grep -Fq 'Authority=Apple Development:' "$script"
  grep -Fq 'lsregister \' "$script"
  grep -Fq -- '-f /Applications/AetherRoute.app' "$script"
  if grep -Fq 'CODE_SIGN_IDENTITY=-' "$script"; then
    echo "Visible UI runs must not use an ad-hoc signature: $script" >&2
    exit 1
  fi
done
grep -Fq 'CODE_SIGN_STYLE=Manual' "$UI_TEST_SCRIPT"
grep -Fq 'CODE_SIGNING_REQUIRED=YES' "$UI_TEST_SCRIPT"
grep -Fq 'AD_HOC_CODE_SIGNING_ALLOWED=NO' "$UI_TEST_SCRIPT"
grep -Fq '/usr/sbin/DevToolsSecurity -status' \
  "$ROOT/scripts/test_disconnected_idle_performance.sh"
if grep -Fq 'AETHERROUTE_BUNDLE_ID=com.example.aetherroute.idle-measurement' \
  "$IDLE_PERFORMANCE_SCRIPT"; then
  echo "Idle performance must preserve the host-extension product relationship" >&2
  exit 1
fi
if grep -Fq '/var/db/com.apple.dt.automationmode/automation-enabled' \
  "$ROOT/scripts/test_disconnected_idle_performance.sh"; then
  echo "Idle performance gate relies on a non-authoritative automation sentinel" >&2
  exit 1
fi
grep -Fq 'find "$TEST_ROOT" -depth -delete' "$UI_TEST_SCRIPT"
grep -Fq 'pkill -TERM -f "$DERIVED_DATA"' "$UI_TEST_SCRIPT"
grep -Fq 'pkill -KILL -f "$DERIVED_DATA"' "$UI_TEST_SCRIPT"
grep -Fq 'LaunchServices accepts XCTest launch requests asynchronously' \
  "$UI_TEST_SCRIPT"
grep -Fq 'lsregister \' "$UI_TEST_SCRIPT"
grep -Fq 'codesign --verify --deep --strict "$application"' "$UI_TEST_SCRIPT"
grep -Fq 'copy_review_workspace' "$UI_CAPTURE_SCRIPT"
grep -Fq 'DERIVED_DATA_PATH="$TEMP/DerivedData"' "$UI_CAPTURE_SCRIPT"

SIGNED_NE_SCRIPT="$ROOT/scripts/test_signed_network_extension.sh"
grep -Fq 'AetherRouteUITests-Runner.app' "$SIGNED_NE_SCRIPT"
grep -Fq 'codesign --verify --deep --strict --verbose=2 "$RUNNER_APP"' \
  "$SIGNED_NE_SCRIPT"
grep -Fq 'Authority=Apple Development' "$SIGNED_NE_SCRIPT"
grep -Fq 'pkill -TERM -f "$DERIVED_DATA"' "$SIGNED_NE_SCRIPT"
grep -Fq 'LaunchServices accepts XCTest launch requests asynchronously' \
  "$SIGNED_NE_SCRIPT"
grep -Fq 'lsregister \' "$SIGNED_NE_SCRIPT"
grep -Fq 'find "$AUDIT_DIR" -depth -delete' "$SIGNED_NE_SCRIPT"
for non_ui_script in \
  "$ROOT/scripts/test.sh" \
  "$ROOT/scripts/test_large_import_performance.sh" \
  "$ROOT/scripts/test_sanitizers.sh"
do
  grep -Fq -- '-scheme AetherRouteUnitTests' "$non_ui_script"
done
grep -Fq '"$ROOT/scripts/bootstrap.sh"' "$ROOT/scripts/test_sanitizers.sh"
test -f "$UNIT_TEST_SCHEME"
if grep -Fq 'AetherRouteUITests' "$UNIT_TEST_SCHEME"; then
  echo "Non-UI test scheme must not contain AetherRouteUITests" >&2
  exit 1
fi
GO_VULN_SCRIPT="$ROOT/scripts/test_go_vulnerabilities.sh"
grep -Fq 'chmod -R u+w "$TEMP"' "$GO_VULN_SCRIPT"
grep -Fq 'find "$TEMP" -depth -delete' "$GO_VULN_SCRIPT"
grep -Fq 'find "$TEMP" -depth -delete' "$UI_CAPTURE_SCRIPT"
grep -Fq 'OUTPUT_COMPLETE=0' "$UI_CAPTURE_SCRIPT"
grep -Fq 'find "$OUTPUT" -depth -delete' "$UI_CAPTURE_SCRIPT"
grep -Fq 'test "$count" -eq "$CAPTURE_COUNT"' "$UI_CAPTURE_SCRIPT"
grep -Fq 'test "$log_count" -eq "$CAPTURE_COUNT"' "$UI_CAPTURE_SCRIPT"
grep -Fq 'AETHERROUTE_UI_REVIEW_CASE_FILTER' "$UI_CAPTURE_SCRIPT"
grep -Fq 'connections-en-dark-expanded' "$UI_CAPTURE_SCRIPT"
grep -Fq 'connections-zh-light-expanded' "$UI_CAPTURE_SCRIPT"
grep -Fq 'abs(width - 960) + abs(height - 640)' \
  "$ROOT/scripts/ui_review_window_id.swift"
grep -Fq 'candidates.min(by: { $0.settingsDistance < $1.settingsDistance })' \
  "$ROOT/scripts/ui_review_window_id.swift"
grep -Fq 'name.localizedCaseInsensitiveContains("settings")' \
  "$ROOT/scripts/ui_review_window_id.swift"
grep -Fq 'name.contains("设置")' \
  "$ROOT/scripts/ui_review_window_id.swift"
grep -Fq -- "-name '*.png' -o -name '*.log' -o -name 'source-manifest.txt'" \
  "$UI_CAPTURE_SCRIPT"
grep -Fq 'repository-source-before.txt' "$UI_CAPTURE_SCRIPT"
grep -Fq 'repository-source-after.txt' "$UI_CAPTURE_SCRIPT"
grep -Fq 'Repository source changed during UI review capture.' "$UI_CAPTURE_SCRIPT"
grep -Fq 'Application performed a reentrant operation' "$UI_CAPTURE_SCRIPT"
grep -Fq 'UI review rejected a runtime warning' "$UI_CAPTURE_SCRIPT"
grep -Fq -- '--settings' "$UI_CAPTURE_SCRIPT"
grep -Fq 'settingsOnly ? 900 : 780' "$UI_WINDOW_SELECTOR"
grep -Fq 'UI review capture always rebuilds inside its isolated temporary workspace.' \
  "$UI_CAPTURE_SCRIPT"
grep -Fq 'assertNoBroadDocumentsPrompt' "$UI_TEST_SOURCE"
grep -Fq '(28...120).contains(topChromeInset)' "$UI_TEST_SOURCE"
grep -Fq 'connections-upload-title' "$UI_TEST_SOURCE"

if grep -Fq 'DERIVED_DATA_PATH=${AETHERROUTE_DERIVED_DATA_PATH' \
  "$UI_CAPTURE_SCRIPT"; then
  echo "UI capture must not accept a DerivedData path outside its temporary workspace" >&2
  exit 1
fi

printf 'UI isolation guards passed: temporary source, build, home, lock, cleanup, protected-folder assertion\n'
