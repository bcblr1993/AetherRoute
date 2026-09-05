#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
AUDIT_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-repository-ci.XXXXXX")
trap 'find "$AUDIT_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

test "$(uname -m)" = arm64 || {
  echo "Repository CI requires an Apple Silicon runner" >&2
  exit 1
}

python3 "$ROOT/scripts/repository_worktree_snapshot.py" "$ROOT" \
  >"$AUDIT_TEMP/before.json"
"$ROOT/scripts/test_repository_worktree_snapshot.sh"
"$ROOT/scripts/test_ui_design_token_guards.sh"
"$ROOT/scripts/test_external_profile_sanitizer.sh"

# Syntax-check every script with the interpreter it actually declares.
# Checking a zsh script with `sh -n` reports its valid zsh constructs as
# errors, which failed CI on a script that runs correctly.
find "$ROOT/scripts" -type f -name '*.sh' -print | LC_ALL=C sort |
  while IFS= read -r script; do
    case "$(head -1 "$script")" in
      *zsh) zsh -n "$script" ;;
      *bash) bash -n "$script" ;;
      *) sh -n "$script" ;;
    esac
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
"$ROOT/scripts/verify_ui_design_tokens.sh"
"$ROOT/scripts/test_go_vulnerabilities.sh"

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

python3 "$ROOT/scripts/repository_worktree_snapshot.py" "$ROOT" \
  >"$AUDIT_TEMP/after.json"
cmp -s "$AUDIT_TEMP/before.json" "$AUDIT_TEMP/after.json" || {
  echo "Repository CI changed source, index, untracked files, or submodule state" >&2
  exit 1
}
echo "Repository CI passed without loading a Network Extension."
