#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REMOTE_HOST=${1:-${AETHERROUTE_REMOTE:-}}
ONLY_TEST=${2:-}
LOCAL_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-remote-ui-controller.XXXXXX")
REMOTE_TEMP=

if [ -z "$REMOTE_HOST" ]; then
  echo "usage: $0 user@host [test-name]" >&2
  exit 64
fi

cleanup() {
  if [ -n "$REMOTE_TEMP" ]; then
    case "$REMOTE_TEMP" in
      /tmp/aetherroute-remote-ui.*)
        ssh "$REMOTE_HOST" "find '$REMOTE_TEMP' -depth -delete" \
          >/dev/null 2>&1 || true
        ;;
    esac
  fi
  find "$LOCAL_TEMP" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

SOURCE="$LOCAL_TEMP/source"
mkdir -p "$SOURCE"
for item in \
  .github .gitmodules .tools Artifacts/Validation CHANGELOG.md CONTRIBUTING.md \
  Config Core Docs Licenses README.md SECURITY.md Services Sources Tests \
  project.yml scripts
do
  if [ "$item" = Core ]; then
    mkdir -p "$SOURCE/Core"
    rsync -a --exclude '/Engine/target/' --exclude '/Engine/.git' \
      "$ROOT/Core/" "$SOURCE/Core/"
  else
    ditto "$ROOT/$item" "$SOURCE/$item"
  fi
done
"$SOURCE/scripts/source_manifest.sh" > "$LOCAL_TEMP/expected-source.txt"

REMOTE_TEMP=$(ssh "$REMOTE_HOST" 'mktemp -d /tmp/aetherroute-remote-ui.XXXXXX')
case "$REMOTE_TEMP" in
  /tmp/aetherroute-remote-ui.*) ;;
  *) echo "unexpected remote temporary path: $REMOTE_TEMP" >&2; exit 1 ;;
esac

rsync -a "$SOURCE/" "$REMOTE_HOST:$REMOTE_TEMP/source/"
rsync -a "$LOCAL_TEMP/expected-source.txt" \
  "$REMOTE_HOST:$REMOTE_TEMP/expected-source.txt"

set +e
if [ -n "$ONLY_TEST" ]; then
  ssh "$REMOTE_HOST" \
    "'$REMOTE_TEMP/source/scripts/remote_ui_worker.sh' '$REMOTE_TEMP/source' '$REMOTE_TEMP/evidence' '$REMOTE_TEMP/expected-source.txt' '$ONLY_TEST'"
else
  ssh "$REMOTE_HOST" \
    "'$REMOTE_TEMP/source/scripts/remote_ui_worker.sh' '$REMOTE_TEMP/source' '$REMOTE_TEMP/evidence' '$REMOTE_TEMP/expected-source.txt'"
fi
status=$?
set -e

mkdir -p "$LOCAL_TEMP/evidence"
rsync -a "$REMOTE_HOST:$REMOTE_TEMP/evidence/" "$LOCAL_TEMP/evidence/" \
  >/dev/null 2>&1 || true
if [ -n "${AETHERROUTE_UI_EVIDENCE_DIR:-}" ]; then
  case "$AETHERROUTE_UI_EVIDENCE_DIR" in
    /*) ;;
    *) echo "AETHERROUTE_UI_EVIDENCE_DIR must be absolute" >&2; exit 64 ;;
  esac
  mkdir -p "$AETHERROUTE_UI_EVIDENCE_DIR"
  cp -R "$LOCAL_TEMP/evidence/." "$AETHERROUTE_UI_EVIDENCE_DIR/"
fi

if [ -f "$LOCAL_TEMP/evidence/result.env" ]; then
  cat "$LOCAL_TEMP/evidence/result.env"
fi
if [ "$status" -ne 0 ]; then
  test -f "$LOCAL_TEMP/evidence/ui-test.log" && \
    tail -200 "$LOCAL_TEMP/evidence/ui-test.log" >&2
  exit "$status"
fi

grep -F 'test_status=0' "$LOCAL_TEMP/evidence/result.env" >/dev/null
grep -F 'network_unchanged=true' "$LOCAL_TEMP/evidence/result.env" >/dev/null
grep -F 'source_unchanged=true' "$LOCAL_TEMP/evidence/result.env" >/dev/null
echo "Remote UI gate passed; remote and local test workspaces cleaned."
