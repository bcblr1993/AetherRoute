#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REMOTE=${AETHERROUTE_REMOTE:-${1:-}}
MODE=${2:-fast}
ALLOW=${AETHERROUTE_ALLOW_REMOTE_GATE:-NO}
KEEP_FAILURE=${AETHERROUTE_KEEP_REMOTE_FAILURE:-NO}

usage() {
  echo "Usage: AETHERROUTE_ALLOW_REMOTE_GATE=YES $0 user@host [fast|full]" >&2
}

if [ "$ALLOW" != YES ]; then
  echo "Remote validation requires explicit AETHERROUTE_ALLOW_REMOTE_GATE=YES opt-in" >&2
  exit 64
fi
case "$MODE" in
  fast|full) ;;
  *) usage; exit 64 ;;
esac
case "$REMOTE" in
  ''|*[!A-Za-z0-9._@-]*|-*|@*|*@|*@*@*)
    echo "Remote endpoint must be a plain user@host or host value" >&2
    exit 64
    ;;
esac
remote_host=${REMOTE##*@}
case "$remote_host" in
  localhost|localhost.localdomain|127.*|0.0.0.0|::1)
    echo "Remote gate refuses a local endpoint" >&2
    exit 64
    ;;
esac
local_short=$(hostname -s)
local_full=$(hostname)
if [ "$remote_host" = "$local_short" ] || [ "$remote_host" = "$local_full" ]; then
  echo "Remote gate refuses the current Mac" >&2
  exit 64
fi

for command in ssh rsync shasum xcodebuild; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Remote validation requires $command" >&2
    exit 1
  }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-remote-controller.XXXXXX")
PAYLOAD="$WORK/payload"
STAGED_ROOT="$PAYLOAD/AetherRoute"
EXPECTED_PAYLOAD="$WORK/payload.sha256"
EXPECTED_SOURCE="$WORK/source-manifest.txt"
CURRENT_SOURCE="$WORK/source-manifest-current.txt"
INTEROP_TEST_SOURCE="$ROOT/../references/interop-tools/clash-rs-2272555/clash-lib-protocol-tests"
REMOTE_BASE=
RUN_STATUS=failed
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
EVIDENCE="$ROOT/outputs/test-evidence/remote-arm64-$STAMP-$MODE"
mkdir -p "$STAGED_ROOT"

remote_delete() {
  if safe_remote_base "$REMOTE_BASE"; then
    ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$REMOTE" \
      "/usr/bin/find '$REMOTE_BASE' -depth -delete" >/dev/null 2>&1 || true
  fi
}

safe_remote_base() {
  candidate=$1
  prefix=/tmp/aetherroute-remote-gate.
  suffix=${candidate#"$prefix"}
  [ "$candidate" != "$suffix" ] || return 1
  case "$suffix" in
    ''|*[!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}

cleanup() {
  if [ -n "$REMOTE_BASE" ]; then
    if [ "$RUN_STATUS" = failed ] && [ "$KEEP_FAILURE" = YES ]; then
      echo "Remote failure directory retained by explicit request: $REMOTE_BASE" >&2
    else
      remote_delete
    fi
  fi
  find "$WORK" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

"$ROOT/scripts/source_manifest.sh" > "$EXPECTED_SOURCE"

for relative_path in \
  .github \
  .gitmodules \
  AetherRoute.xcodeproj \
  Artifacts/Validation \
  CHANGELOG.md \
  CONTRIBUTING.md \
  Config \
  Design \
  Docs \
  Licenses \
  Services \
  SECURITY.md \
  Sources \
  Tests \
  scripts \
  .tools/xcodegen \
  README.md \
  project.yml
do
  source_path="$ROOT/$relative_path"
  test -e "$source_path" || {
    echo "Required remote payload path is missing: $relative_path" >&2
    exit 1
  }
  destination_path="$STAGED_ROOT/$relative_path"
  mkdir -p "$(dirname -- "$destination_path")"
  if [ -d "$source_path" ]; then
    mkdir -p "$destination_path"
    rsync -a "$source_path/" "$destination_path/"
  else
    rsync -a "$source_path" "$destination_path"
  fi
done

mkdir -p "$STAGED_ROOT/Core"
rsync -a --exclude '/Engine/target/' "$ROOT/Core/" "$STAGED_ROOT/Core/"
if [ -d "$ROOT/.git/modules/Core/Engine" ]; then
  mkdir -p "$STAGED_ROOT/.git/modules/Core"
  rsync -a "$ROOT/.git/modules/Core/Engine" "$STAGED_ROOT/.git/modules/Core/"
fi

local_commit=$(git -C "$ROOT" rev-parse HEAD)
git -C "$STAGED_ROOT" init -q
mkdir -p "$STAGED_ROOT/.git/refs/heads"
printf '%s\n' "$local_commit" > "$STAGED_ROOT/.git/refs/heads/main"
printf 'ref: refs/heads/main\n' > "$STAGED_ROOT/.git/HEAD"

test -f "$INTEROP_TEST_SOURCE" || {
  echo "Pinned protocol interoperability verifier is missing" >&2
  exit 1
}
interop_destination="$PAYLOAD/references/interop-tools/clash-rs-2272555"
mkdir -p "$interop_destination"
rsync -a "$INTEROP_TEST_SOURCE" "$interop_destination/"

"$STAGED_ROOT/scripts/source_manifest.sh" > "$WORK/source-manifest-staged.txt"
cmp -s "$EXPECTED_SOURCE" "$WORK/source-manifest-staged.txt" || {
  echo "Local source changed while staging the remote snapshot" >&2
  exit 1
}

create_payload_manifest() {
  manifest_root=$1
  manifest_output=$2
  (
    cd "$manifest_root"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r file
    do
      hash=$(shasum -a 256 "$file" | awk '{print $1}')
      printf '%s  %s\n' "$hash" "$file"
    done
  ) > "$manifest_output"
}
create_payload_manifest "$PAYLOAD" "$EXPECTED_PAYLOAD"

local_uuid=$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice \
  | awk -F'"' '/IOPlatformUUID/ {print $(NF - 1); exit}')
test -n "$local_uuid" || {
  echo "Could not read the local Mac identity" >&2
  exit 1
}
local_uuid_hash=$(printf '%s' "$local_uuid" | shasum -a 256 | awk '{print $1}')
preflight=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$REMOTE" '
  arch=$(uname -m)
  xcode=$(xcodebuild -version | paste -sd " " -)
  free_kb=$(df -Pk /tmp | awk "END {print \$4}")
  uuid=$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | awk -F\" "/IOPlatformUUID/ {print \$(NF - 1); exit}")
  test -n "$uuid"
  uuid_hash=$(printf "%s" "$uuid" | shasum -a 256 | awk "{print \$1}")
  printf "arch=%s\nxcode=%s\nfree_kb=%s\nuuid_hash=%s\n" "$arch" "$xcode" "$free_kb" "$uuid_hash"
')
remote_arch=$(printf '%s\n' "$preflight" | sed -n 's/^arch=//p')
remote_xcode=$(printf '%s\n' "$preflight" | sed -n 's/^xcode=//p')
remote_uuid_hash=$(printf '%s\n' "$preflight" | sed -n 's/^uuid_hash=//p')
remote_free_kb=$(printf '%s\n' "$preflight" | sed -n 's/^free_kb=//p')
test "$remote_arch" = arm64 || {
  echo "Remote validation requires an arm64 Mac" >&2
  exit 1
}
test -n "$remote_uuid_hash"
test "$remote_uuid_hash" != "$local_uuid_hash" || {
  echo "Remote gate resolved to the current Mac" >&2
  exit 1
}
case "$MODE" in
  fast) required_free_kb=$((8 * 1024 * 1024)) ;;
  full) required_free_kb=$((20 * 1024 * 1024)) ;;
esac
case "$remote_free_kb" in
  ''|*[!0-9]*)
    echo "Remote free-space preflight returned an invalid value" >&2
    exit 1
    ;;
esac
test "$remote_free_kb" -ge "$required_free_kb" || {
  echo "Remote /tmp does not have enough free space for $MODE mode" >&2
  exit 1
}
mkdir -p "$EVIDENCE"
{
  printf 'architecture=%s\n' "$remote_arch"
  printf 'xcode=%s\n' "$remote_xcode"
  printf 'available_tmp_kb=%s\n' "$remote_free_kb"
  printf 'distinct_machine=yes\n'
} > "$EVIDENCE/preflight.env"

REMOTE_BASE=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$REMOTE" \
  'mktemp -d /tmp/aetherroute-remote-gate.XXXXXX')
safe_remote_base "$REMOTE_BASE" || {
  echo "Remote host returned an unsafe temporary directory" >&2
  exit 1
}

rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=8' \
  "$PAYLOAD/" "$REMOTE:$REMOTE_BASE/payload/"
rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=8' \
  "$EXPECTED_PAYLOAD" "$REMOTE:$REMOTE_BASE/payload.sha256"
rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=8' \
  "$EXPECTED_SOURCE" "$REMOTE:$REMOTE_BASE/source-manifest.txt"

set +e
ssh -o BatchMode=yes -o ConnectTimeout=8 -- "$REMOTE" \
  "'$REMOTE_BASE/payload/AetherRoute/scripts/remote_arm64_worker.sh' '$REMOTE_BASE' '$MODE'" \
  > "$EVIDENCE/run.log" 2>&1
remote_status=$?
set -e

rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=8' \
  "$REMOTE:$REMOTE_BASE/evidence/" "$EVIDENCE/" >/dev/null 2>&1 || true

"$ROOT/scripts/source_manifest.sh" > "$CURRENT_SOURCE"
if ! cmp -s "$EXPECTED_SOURCE" "$CURRENT_SOURCE"; then
  echo "Local source changed while the remote gate was running; evidence is not current" >&2
  exit 1
fi
if [ "$remote_status" -ne 0 ]; then
  tail -120 "$EVIDENCE/run.log" >&2
  exit "$remote_status"
fi
grep -F 'status=passed' "$EVIDENCE/result.env" >/dev/null

cp "$EXPECTED_SOURCE" "$EVIDENCE/source-manifest.txt"
cp "$EXPECTED_PAYLOAD" "$EVIDENCE/payload-manifest.txt"
(
  cd "$EVIDENCE"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -print \
    | LC_ALL=C sort | while IFS= read -r evidence_file
  do
    shasum -a 256 "$evidence_file"
  done
) > "$EVIDENCE/SHA256SUMS"
RUN_STATUS=passed
echo "Remote arm64 $MODE gate passed: $EVIDENCE"
