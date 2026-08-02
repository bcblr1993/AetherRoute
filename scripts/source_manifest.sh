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
    Artifacts/Validation \
    Config \
    Core/Headers \
    Docs \
    Licenses \
    Services \
    Sources \
    Tests \
    scripts
  do
    find "$manifest_path" -type f -print
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
) | LC_ALL=C sort -u > "$LIST"

(
  cd "$ROOT"
  while IFS= read -r manifest_path
  do
    hash=$(shasum -a 256 "$manifest_path" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "$manifest_path"
  done < "$LIST"
) > "$MANIFEST"

cat "$MANIFEST"
printf 'MANIFEST_SHA256  %s\n' "$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
