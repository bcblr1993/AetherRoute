#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-manifest.XXXXXX")
cleanup() {
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
LIST="$WORK/files.txt"
MANIFEST="$WORK/manifest.txt"

(
  cd "$ROOT"
  for manifest_path in \
    .github \
    AetherRoute.xcodeproj \
    Artifacts/Validation \
    Config \
    Core/Headers \
    Docs \
    Design \
    Licenses \
    Services \
    Sources \
    Tests \
    scripts
  do
    find "$manifest_path" -type f \
      ! -path 'Config/Signing.json' \
      ! -path '*/xcuserdata/*' \
      ! -name '*.xcuserstate' -print
  done
  for manifest_path in \
    .gitmodules \
    CHANGELOG.md \
    CONTRIBUTING.md \
    README.md \
    SECURITY.md \
    project.yml \
    Core/Artifacts/macos-arm64/libclashrs.a \
    Core/Artifacts/macos-arm64/libclashrs-direct.a
  do
    if [ -f "$manifest_path" ]; then
      printf '%s\n' "$manifest_path"
    fi
  done

  # The networking engine is a nested Git worktree. Binding only the static
  # archives proves the shipped bytes but cannot independently identify the
  # source that produced them. Include every tracked and non-ignored untracked
  # engine source file while still excluding `.git`, `target`, and other
  # ignored build state. A missing tracked file is intentionally left in the
  # list so the hashing pass rejects an incomplete checkout.
  if [ -d Core/Engine ] \
    && git -C Core/Engine rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C Core/Engine ls-files --cached --others --exclude-standard \
      | while IFS= read -r engine_path
        do
          printf 'Core/Engine/%s\n' "$engine_path"
        done
  fi
) | LC_ALL=C sort -u > "$LIST"

# One shasum per batch, not per file: spawning two processes for each of the
# thousands of files took most of an hour on the Tart VM. The output is the
# same "hash  path" line shasum prints for a single file, in list order, and a
# missing file now fails the run instead of leaving an empty hash.
(
  cd "$ROOT"
  if [ -s "$LIST" ]; then
    tr '\n' '\0' < "$LIST" | xargs -0 shasum -a 256 --
  fi
) > "$MANIFEST"

cat "$MANIFEST"
printf 'MANIFEST_SHA256  %s\n' "$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
