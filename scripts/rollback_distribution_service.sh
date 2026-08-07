#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOST=${1:-}
TARGET_RELEASE=${2:-}
REMOTE_ROOT=/home/chenyn/services/aetherroute-license
BASE_URL=https://license-staging.baizhiedu.xin

usage() {
  echo "usage: $0 user@host target-staging-release-id" >&2
}

test -n "$HOST" || { usage; exit 64; }
printf '%s\n' "$TARGET_RELEASE" \
  | grep -Eq '^staging-[0-9A-Za-z][0-9A-Za-z._-]{2,55}$' \
  || { usage; exit 64; }

temporary=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-service-rollback.XXXXXX")
remote_verification="$REMOTE_ROOT/.rollback-verification-$TARGET_RELEASE"
previous=
license_id=
target_deployed=0
committed=0
cleanup_started=0

restore_previous() {
  [ -n "$previous" ] || return 0
  ssh -o BatchMode=yes -o LogLevel=ERROR "$HOST" "
    set -eu
    case '$previous' in releases/*) ;; *) exit 1 ;; esac
    previous_root='$REMOTE_ROOT/$previous'
    test -x \"\$previous_root/activate-release.sh\"
    \"\$previous_root/activate-release.sh\" \"\$previous_root\" >/dev/null
  "
}

revoke_verification_license() {
  [ -n "$license_id" ] || return 0
  ssh -o BatchMode=yes -o LogLevel=ERROR "$HOST" "
    set -eu
    target_root='$REMOTE_ROOT/releases/$TARGET_RELEASE'
    image=\$(jq -er .image \"\$target_root/metadata.json\")
    docker run --rm --network none --read-only --cap-drop ALL \
      --security-opt no-new-privileges --user 10002:12000 \
      --entrypoint /usr/local/bin/aetherroute-distribution \
      -v /var/lib/aetherroute-license/state:/var/lib/aetherroute \
      -v /etc/aetherroute-license/web/license-pepper.raw:/run/secrets/license-pepper.raw:ro \
      \"\$image\" set-state \
        -product-id com.aetherroute.desktop \
        -state /var/lib/aetherroute/licenses.json \
        -pepper /run/secrets/license-pepper.raw \
        -license-id '$license_id' -new-state revoked
  "
  license_id=
}

cleanup() {
  status=$?
  if [ "$cleanup_started" -eq 1 ]; then
    exit "$status"
  fi
  cleanup_started=1
  trap - EXIT HUP INT TERM
  set +e
  revoke_verification_license
  if [ "$target_deployed" -eq 1 ] && [ "$committed" -eq 0 ]; then
    restore_previous
  fi
  ssh -o BatchMode=yes -o LogLevel=ERROR "$HOST" "
    if [ -d '$remote_verification' ]; then
      find '$remote_verification' -depth -delete
    fi
  " >/dev/null 2>&1
  find "$temporary" -depth -delete 2>/dev/null
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

previous=$(ssh -o BatchMode=yes -o LogLevel=ERROR "$HOST" "
  set -eu
  current=\$(readlink '$REMOTE_ROOT/current')
  case \"\$current\" in releases/*) ;; *) exit 1 ;; esac
  test \"\$current\" != 'releases/$TARGET_RELEASE'
  current_root='$REMOTE_ROOT/'\"\$current\"
  target_root='$REMOTE_ROOT/releases/$TARGET_RELEASE'
  test -x \"\$current_root/activate-release.sh\"
  test -x \"\$target_root/activate-release.sh\"
  test ! -e '$remote_verification'
  mkdir '$remote_verification'
  chmod 700 '$remote_verification'
  cp \"\$target_root/metadata.json\" '$remote_verification/metadata.json'
  sudo -n install -m 600 -o chenyn -g chenyn \
    /etc/aetherroute-license/web/signing-public.raw \
    '$remote_verification/public-key.raw'
  image=\$(jq -er .image \"\$target_root/metadata.json\")
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user 10002:12000 \
    --entrypoint /usr/local/bin/aetherroute-distribution \
    -v /var/lib/aetherroute-license/state:/var/lib/aetherroute \
    -v /etc/aetherroute-license/web/license-pepper.raw:/run/secrets/license-pepper.raw:ro \
    \"\$image\" issue \
      -product-id com.aetherroute.desktop \
      -state /var/lib/aetherroute/licenses.json \
      -pepper /run/secrets/license-pepper.raw \
      -max-devices 1 >'$remote_verification/license.json'
  chmod 600 '$remote_verification/license.json'
  printf '%s\\n' \"\$current\"
")
case "$previous" in releases/*) ;; *) exit 1 ;; esac

scp -q "$HOST:$remote_verification/metadata.json" "$temporary/metadata.json"
scp -q "$HOST:$remote_verification/public-key.raw" "$temporary/public-key.raw"
scp -q "$HOST:$remote_verification/license.json" "$temporary/license.json"
jq -er .activationKey "$temporary/license.json" >"$temporary/activation-key.txt"
chmod 600 "$temporary/activation-key.txt"
license_id=$(jq -er .license.licenseID "$temporary/license.json")
expected_build=$(jq -er .build "$temporary/metadata.json")
expected_download_url=$(jq -er .downloadURL "$temporary/metadata.json")

ssh -o BatchMode=yes -o LogLevel=ERROR "$HOST" "
  set -eu
  target_root='$REMOTE_ROOT/releases/$TARGET_RELEASE'
  \"\$target_root/activate-release.sh\" \"\$target_root\" >/dev/null
"
target_deployed=1

"$ROOT/scripts/verify_distribution_service_https.sh" \
  "$BASE_URL" "$temporary/public-key.raw" "$temporary/activation-key.txt" \
  "$expected_build" "$expected_download_url"

revoke_verification_license
ssh -o BatchMode=yes -o LogLevel=ERROR "$HOST" "
  set -eu
  test \"\$(readlink '$REMOTE_ROOT/current')\" = '$previous'
  ln -sfn 'releases/$TARGET_RELEASE' '$REMOTE_ROOT/current.next'
  mv -Tf '$REMOTE_ROOT/current.next' '$REMOTE_ROOT/current'
"
committed=1

printf '%s\n' \
  "Rolled back and publicly verified distribution service: $previous -> releases/$TARGET_RELEASE"
