#!/bin/sh
# The remote gate's payload manifest must stay byte-for-byte what the
# original one-shasum-per-file loop produced (both ends compare it), while
# hashing in batches: per-file processes cost about ten minutes on each side
# for the ~45k-file payload.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/payload_manifest.sh
. "$ROOT/scripts/payload_manifest.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-payload-manifest.XXXXXX")
trap 'find "$WORK" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

reference_manifest() {
  (
    cd "$1"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r file
    do
      hash=$(shasum -a 256 "$file" | awk '{print $1}')
      printf '%s  %s\n' "$hash" "$file"
    done
  ) >"$2"
}

TREE="$WORK/tree"
mkdir -p "$TREE/a b/c" "$TREE/Ünicode" "$TREE/.hidden" "$TREE/empty-dir"
printf 'one' >"$TREE/a b/c/file one.txt"
printf 'two' >"$TREE/Ünicode/名称.yaml"
: >"$TREE/.hidden/empty"
printf 'B' >"$TREE/B"
printf 'a' >"$TREE/a"
printf '%s' "-dash" >"$TREE/-leading-dash"
i=0
while [ "$i" -lt 300 ]; do printf '%s' "$i" >"$TREE/a b/many-$i"; i=$((i + 1)); done
ln -s "a" "$TREE/link-to-a"

reference_manifest "$TREE" "$WORK/reference"
create_payload_manifest "$TREE" "$WORK/batched"
cmp -s "$WORK/reference" "$WORK/batched" || {
  diff -u "$WORK/reference" "$WORK/batched" | head -20 >&2
  echo "payload manifest differs from the reference" >&2
  exit 1
}
test "$(wc -l <"$WORK/batched" | tr -d ' ')" -eq 306 || {
  echo "payload manifest lists the wrong number of files" >&2
  exit 1
}
echo "Payload manifest: batched hashing matches the per-file reference (306 files)."
