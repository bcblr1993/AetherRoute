#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SNAPSHOT="$ROOT/scripts/repository_worktree_snapshot.py"
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-worktree-test.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
git init -q "$TEMP/repo"
git init -q "$TEMP/core"
printf 'base\n' >"$TEMP/core/source.txt"
git -C "$TEMP/core" add source.txt
git -C "$TEMP/core" -c user.name=Test -c user.email=test@example.invalid commit -qm base
git -C "$TEMP/repo" -c protocol.file.allow=always submodule add -q "$TEMP/core" Core/Engine
printf 'base\n' >"$TEMP/repo/source.txt"
git -C "$TEMP/repo" add .
git -C "$TEMP/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm base
printf 'existing edit\n' >"$TEMP/repo/source.txt"
printf 'existing untracked\n' >"$TEMP/repo/notes with spaces.txt"
printf 'existing core edit\n' >"$TEMP/repo/Core/Engine/source.txt"
python3 "$SNAPSHOT" "$TEMP/repo" >"$TEMP/before"
python3 "$SNAPSHOT" "$TEMP/repo" >"$TEMP/after"
cmp -s "$TEMP/before" "$TEMP/after"

expect_change() {
  python3 "$SNAPSHOT" "$TEMP/repo" >"$TEMP/after"
  if cmp -s "$TEMP/before" "$TEMP/after"; then
    echo "Worktree guard missed $1" >&2
    exit 1
  fi
}
printf 'test changed tracked\n' >>"$TEMP/repo/source.txt"
expect_change 'tracked changes'
printf 'existing edit\n' >"$TEMP/repo/source.txt"
printf 'test changed untracked\n' >>"$TEMP/repo/notes with spaces.txt"
expect_change 'untracked content changes'
printf 'existing untracked\n' >"$TEMP/repo/notes with spaces.txt"
git -C "$TEMP/repo" add source.txt
expect_change 'index changes'
git -C "$TEMP/repo" restore --staged source.txt
printf 'test changed already-dirty core\n' >>"$TEMP/repo/Core/Engine/source.txt"
expect_change 'already-dirty submodule changes'
printf 'existing core edit\n' >"$TEMP/repo/Core/Engine/source.txt"
mkdir "$TEMP/repo/AetherRoute.xcodeproj"
printf 'generated\n' >"$TEMP/repo/AetherRoute.xcodeproj/project.pbxproj"
python3 "$SNAPSHOT" "$TEMP/repo" >"$TEMP/after"
cmp -s "$TEMP/before" "$TEMP/after"
echo "Repository worktree guard passed: existing edits preserved; tracked, staged, untracked and submodule mutations detected."
