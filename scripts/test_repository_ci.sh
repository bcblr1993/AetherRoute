#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AUDIT_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-repository-ci.XXXXXX")
cleanup() {
  find "$AUDIT_TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

capture_worktree() {
  destination=$1
  git -C "$ROOT" diff --binary -- . ':!AetherRoute.xcodeproj' \
    >"$destination.diff"
  git -C "$ROOT" diff --cached --binary -- . ':!AetherRoute.xcodeproj' \
    >"$destination.cached.diff"
  git -C "$ROOT" status --porcelain=v1 --untracked-files=all \
    | grep -v ' AetherRoute.xcodeproj/' \
    >"$destination.status" || true
}

test "$(uname -m)" = arm64 || {
  echo "Repository CI requires an Apple Silicon runner" >&2
  exit 1
}

capture_worktree "$AUDIT_TEMP/before"

find "$ROOT/scripts" -type f -name '*.sh' -print | LC_ALL=C sort |
  while IFS= read -r script; do
    sh -n "$script"
  done

find "$ROOT/Config" -type f -name '*.json' -print | LC_ALL=C sort |
  while IFS= read -r json; do
    jq -e . "$json" >/dev/null
  done

find "$ROOT/Config" -type f \( -name '*.plist' -o -name '*.xcprivacy' \) \
  -print | LC_ALL=C sort | while IFS= read -r plist; do
    plutil -lint "$plist" >/dev/null
  done

"$ROOT/scripts/bootstrap.sh"
xcodebuild -project "$ROOT/AetherRoute.xcodeproj" -list >/dev/null
"$ROOT/scripts/verify_localizations.sh"
"$ROOT/scripts/verify_app_icon.sh"
"$ROOT/scripts/test_go_vulnerabilities.sh"
"$ROOT/scripts/test_distribution_deployment.sh"

(
  cd "$ROOT/Services/DistributionService"
  unformatted=$(gofmt -l .)
  test -z "$unformatted" || {
    echo "Go files require gofmt:" >&2
    printf '%s\n' "$unformatted" >&2
    exit 1
  }
  go vet ./...
  go test -race ./...
)

capture_worktree "$AUDIT_TEMP/after"
for snapshot in diff cached.diff status; do
  cmp -s "$AUDIT_TEMP/before.$snapshot" "$AUDIT_TEMP/after.$snapshot" || {
    echo "Repository CI changed source or worktree state: $snapshot" >&2
    diff -u "$AUDIT_TEMP/before.$snapshot" "$AUDIT_TEMP/after.$snapshot" \
      >&2 || true
    exit 1
  }
done
echo "Repository CI passed without loading a Network Extension."
