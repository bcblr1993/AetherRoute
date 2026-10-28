#!/bin/sh
# source_manifest.sh must hash every listed file exactly as `shasum -a 256`
# does one file at a time, and must reject a checkout that lost a tracked
# engine file.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-source-manifest-test.XXXXXX")
trap 'find "$WORK" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

FIXTURE="$WORK/repository"
mkdir -p "$FIXTURE/scripts" "$FIXTURE/Sources/App" "$FIXTURE/Config" \
  "$FIXTURE/Docs/with space" "$FIXTURE/Core/Engine/src" "$FIXTURE/.github" \
  "$FIXTURE/AetherRoute.xcodeproj" "$FIXTURE/Artifacts/Validation" \
  "$FIXTURE/Core/Headers" "$FIXTURE/Design" "$FIXTURE/Licenses" \
  "$FIXTURE/Services" "$FIXTURE/Tests"
cp "$ROOT/scripts/source_manifest.sh" "$FIXTURE/scripts/"
printf 'secret\n' >"$FIXTURE/Config/Signing.json"
printf 'name: fixture\n' >"$FIXTURE/project.yml"
printf '# notes\n' >"$FIXTURE/Docs/with space/a file.md"
i=0
while [ "$i" -lt 300 ]; do
  printf 'let value%s = %s\n' "$i" "$i" >"$FIXTURE/Sources/App/File$i.swift"
  i=$((i + 1))
done
(
  cd "$FIXTURE/Core/Engine"
  git init -q
  printf 'fn main() {}\n' >src/main.rs
  printf 'target\n' >.gitignore
  mkdir target
  printf 'build output\n' >target/ignored.o
  git add src/main.rs .gitignore
  git -c user.email=t@example.invalid -c user.name=t commit -q -m fixture
)

sh "$FIXTURE/scripts/source_manifest.sh" >"$WORK/actual.txt"

# Reference: one shasum per listed path, the format the remote gate and every
# evidence file already record.
sed '$d' "$WORK/actual.txt" | sed 's/^[0-9a-f]*  //' >"$WORK/paths.txt"
(
  cd "$FIXTURE"
  while IFS= read -r path; do
    shasum -a 256 "$path"
  done <"$WORK/paths.txt"
) >"$WORK/expected-body.txt"
printf 'MANIFEST_SHA256  %s\n' \
  "$(shasum -a 256 "$WORK/expected-body.txt" | awk '{print $1}')" \
  >"$WORK/expected-tail.txt"
cat "$WORK/expected-body.txt" "$WORK/expected-tail.txt" >"$WORK/expected.txt"
cmp -s "$WORK/expected.txt" "$WORK/actual.txt" || {
  echo "source manifest differs from per-file shasum output" >&2
  diff -u "$WORK/expected.txt" "$WORK/actual.txt" | head -20 >&2
  exit 1
}

count=$(wc -l <"$WORK/paths.txt" | tr -d ' ')
# 300 sources + 1 doc + project.yml + source_manifest.sh + 2 engine files.
test "$count" = 305 || { echo "expected 305 manifest entries, got $count" >&2; exit 1; }
grep -F 'Docs/with space/a file.md' "$WORK/paths.txt" >/dev/null
if grep -E 'Signing.json|target/ignored.o' "$WORK/paths.txt" >/dev/null; then
  echo "source manifest included an excluded file" >&2
  exit 1
fi

find "$FIXTURE/Core/Engine/src/main.rs" -delete
if sh "$FIXTURE/scripts/source_manifest.sh" >"$WORK/missing.txt" 2>"$WORK/missing.err"; then
  echo "source manifest accepted a checkout missing a tracked engine file" >&2
  exit 1
fi

echo "Source manifest guards passed: $count files match per-file shasum; missing tracked file rejected."
