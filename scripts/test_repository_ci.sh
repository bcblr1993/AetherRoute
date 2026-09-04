#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

test "$(uname -m)" = arm64 || {
  echo "Repository CI requires an Apple Silicon runner" >&2
  exit 1
}

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

git -C "$ROOT" diff --exit-code -- . ':!AetherRoute.xcodeproj' >/dev/null
echo "Repository CI passed without loading a Network Extension."
