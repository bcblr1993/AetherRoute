#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOST=${1:-}
DMG=${2:-}
RELEASE_ID=${3:-}
VERSION=${4:-}
BUILD=${5:-}
DOWNLOAD_URL=${6:-}
RELEASE_NOTES_URL=${7:-}
REMOTE_ROOT=/home/chenyn/services/aetherroute-license
BASE_URL=https://license-staging.baizhiedu.xin
IMAGE_TAG="aetherroute-distribution:$RELEASE_ID"

usage() {
  echo "usage: $0 user@host /absolute/notarized-preview.dmg unique-release-id version build https://downloads.baizhiedu.xin/path.dmg https://aetherroute.baizhiedu.xin/releases/" >&2
}

test -n "$HOST" || { usage; exit 64; }
case "$DMG" in /*) ;; *) usage; exit 64 ;; esac
test -f "$DMG"
printf '%s\n' "$RELEASE_ID" | grep -Eq '^[0-9A-Za-z][0-9A-Za-z._-]{2,63}$' || { usage; exit 64; }
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || { usage; exit 64; }
case "$BUILD" in ''|*[!0-9]*) usage; exit 64 ;; esac
test "$BUILD" -gt 1 || { usage; exit 64; }
case "$DOWNLOAD_URL" in https://downloads.baizhiedu.xin/*.dmg) ;; *) usage; exit 64 ;; esac
case "$RELEASE_NOTES_URL" in https://aetherroute.baizhiedu.xin/*) ;; *) usage; exit 64 ;; esac

"$ROOT/scripts/test_distribution_deployment.sh"
"$ROOT/scripts/test_distribution_service.sh"

temporary=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-service-deploy.XXXXXX")
cleanup() {
  find "$temporary" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

public_dmg="$temporary/public.dmg"
curl --noproxy '*' --fail --silent --show-error --proto '=https' --tlsv1.2 \
  --max-redirs 0 --connect-timeout 10 --max-time 120 \
  --output "$public_dmg" "$DOWNLOAD_URL"
local_sha=$(shasum -a 256 "$DMG" | awk '{print $1}')
public_sha=$(shasum -a 256 "$public_dmg" | awk '{print $1}')
test "$local_sha" = "$public_sha" || {
  echo "Published staging DMG does not match the local notarized artifact" >&2
  exit 1
}

context="$temporary/context"
mkdir -p "$context"
(cd "$ROOT/Services/DistributionService" && \
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -buildvcs=false -trimpath -ldflags='-s -w' \
    -o "$temporary/aetherroute-distribution" \
    ./cmd/aetherroute-distribution)
file "$temporary/aetherroute-distribution" | grep -F 'x86-64' >/dev/null
cp "$ROOT/Services/DistributionService/deploy/Dockerfile" "$context/Dockerfile"
cp "$ROOT/Services/DistributionService/deploy/nginx.conf" "$context/nginx.conf"
cp "$ROOT/Services/DistributionService/deploy/signer-entrypoint.sh" "$context/signer-entrypoint.sh"
cp "$ROOT/Services/DistributionService/deploy/web-entrypoint.sh" "$context/web-entrypoint.sh"
cp "$temporary/aetherroute-distribution" "$context/aetherroute-distribution"
chmod 555 "$context/aetherroute-distribution" \
  "$context/signer-entrypoint.sh" "$context/web-entrypoint.sh"
chmod 444 "$context/nginx.conf" "$context/Dockerfile"

payload="$temporary/payload"
mkdir -p "$payload/context"
cp -R "$context/." "$payload/context/"
cp "$temporary/aetherroute-distribution" "$payload/aetherroute-distribution"
cp "$ROOT/Services/DistributionService/deploy/docker-stack.yml" "$payload/docker-stack.yml"
cp "$ROOT/Services/DistributionService/deploy/install-release.sh" "$payload/install-release.sh"
cp "$ROOT/Services/DistributionService/deploy/activate-release.sh" "$payload/activate-release.sh"
cp "$DMG" "$payload/$(basename "$DMG")"

source_manifest="$payload/source-manifest.sha256"
(
  cd "$ROOT"
  {
    find Services/DistributionService -type f -print
    printf '%s\n' \
      scripts/deploy_distribution_service.sh \
      scripts/rollback_distribution_service.sh \
      scripts/test_distribution_deployment.sh \
      scripts/test_distribution_service_operations.sh \
      scripts/verify_distribution_service_https.sh
  } | LC_ALL=C sort -u | while IFS= read -r source; do
    test -f "$source"
    shasum -a 256 "$source"
  done
) >"$source_manifest"
test -s "$source_manifest"
chmod 700 "$payload"
chmod 755 "$payload/install-release.sh" "$payload/activate-release.sh" \
  "$payload/aetherroute-distribution"
chmod 555 "$payload/context/aetherroute-distribution" \
  "$payload/context/signer-entrypoint.sh" \
  "$payload/context/web-entrypoint.sh"
chmod 444 "$payload/context/Dockerfile" "$payload/context/nginx.conf"
chmod 444 "$source_manifest"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$payload" -czf "$temporary/payload.tgz" .

remote_incoming="$REMOTE_ROOT/.incoming-$RELEASE_ID"
remote_release="$REMOTE_ROOT/releases/$RELEASE_ID"
cleanup_failed_candidate() {
  ssh -o BatchMode=yes "$HOST" "
    set -eu
    previous=none
    if [ -f '$remote_release/PREVIOUS' ]; then
      previous=\$(cat '$remote_release/PREVIOUS')
    elif [ -L '$REMOTE_ROOT/current' ]; then
      previous=\$(readlink '$REMOTE_ROOT/current')
    fi
    case \"\$previous\" in none|releases/*) ;; *) exit 1 ;; esac
    if [ \"\$previous\" = none ]; then
      docker stack rm aetherroute-license-staging >/dev/null 2>&1 || true
      attempt=0
      while docker service inspect aetherroute-license-staging_web >/dev/null 2>&1 \
        || docker service inspect aetherroute-license-staging_signer >/dev/null 2>&1; do
        attempt=\$((attempt + 1))
        test \"\$attempt\" -lt 45
        sleep 1
      done
      sudo -n rm -f /var/lib/aetherroute-license/runtime/receipt-signer.sock
    else
      docker service rollback aetherroute-license-staging_web >/dev/null
      docker service rollback aetherroute-license-staging_signer >/dev/null
      healthy=no
      attempt=0
      previous_image=\$(jq -er .image '$REMOTE_ROOT/'\$previous'/metadata.json')
      while [ \"\$attempt\" -lt 45 ]; do
        web_tasks=\$(docker ps --filter label=com.docker.swarm.service.name=aetherroute-license-staging_web --format '{{.Image}}|{{.Status}}')
        signer_tasks=\$(docker ps --filter label=com.docker.swarm.service.name=aetherroute-license-staging_signer --format '{{.Image}}|{{.Status}}')
        web_count=\$(printf '%s\n' \"\$web_tasks\" | sed '/^$/d' | wc -l | tr -d ' ')
        signer_count=\$(printf '%s\n' \"\$signer_tasks\" | sed '/^$/d' | wc -l | tr -d ' ')
        case \"\$web_count:\$signer_count:\$web_tasks:\$signer_tasks\" in
          1:1:\"\$previous_image\"\\|*\\(healthy\\)*:\"\$previous_image\"\\|*\\(healthy\\)*) healthy=yes; break ;;
        esac
        attempt=\$((attempt + 1))
        sleep 2
      done
      test \"\$healthy\" = yes
    fi
    if [ -L '$REMOTE_ROOT/current' ]; then
      test \"\$(readlink '$REMOTE_ROOT/current')\" != 'releases/$RELEASE_ID'
    fi
    if [ -d '$remote_release' ]; then find '$remote_release' -depth -delete; fi
    if [ -d '$remote_incoming' ]; then find '$remote_incoming' -depth -delete; fi
    attempt=0
    while docker image inspect '$IMAGE_TAG' >/dev/null 2>&1; do
      docker image rm '$IMAGE_TAG' >/dev/null 2>&1 || true
      attempt=\$((attempt + 1))
      test \"\$attempt\" -lt 30
      sleep 1
    done
  "
}
ssh -o BatchMode=yes "$HOST" "
  set -eu
  test ! -e '$remote_incoming'
  test ! -e '$remote_release'
  mkdir -p '$REMOTE_ROOT/releases' '$remote_incoming'
  chmod 700 '$remote_incoming'
"
scp -q "$temporary/payload.tgz" "$HOST:$remote_incoming/payload.tgz"
install_code=0
ssh -o BatchMode=yes "$HOST" "
  set -eu
  tar -xzf '$remote_incoming/payload.tgz' -C '$remote_incoming'
  rm '$remote_incoming/payload.tgz'
  chmod 700 '$remote_incoming'
  chmod 755 '$remote_incoming/install-release.sh' \
    '$remote_incoming/activate-release.sh' \
    '$remote_incoming/aetherroute-distribution'
  '$remote_incoming/install-release.sh' \
    '$remote_incoming' '$RELEASE_ID' '$IMAGE_TAG' '$(basename "$DMG")' \
    '$VERSION' '$BUILD' '$(date -u '+%Y-%m-%dT%H:%M:%SZ')' \
    '$DOWNLOAD_URL' '$RELEASE_NOTES_URL'
" || install_code=$?
if [ "$install_code" -ne 0 ]; then
  cleanup_failed_candidate || {
    echo "Automatic cleanup failed; candidate retained for operator recovery" >&2
    exit 1
  }
  echo "Remote distribution install failed; failed candidate was removed" >&2
  exit "$install_code"
fi

rollback_candidate() {
  cleanup_failed_candidate
}

ssh -o BatchMode=yes "$HOST" "
  set -eu
  sudo -n install -m 600 -o chenyn -g chenyn \
    /etc/aetherroute-license/web/signing-public.raw \
    '$remote_release/public-key-for-verification.raw'
  image=\$(jq -r .image '$remote_release/metadata.json')
  test \"\$image\" = '$IMAGE_TAG'
  umask 077
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges \
    --user 10002:12000 \
    --entrypoint /usr/local/bin/aetherroute-distribution \
    -v /var/lib/aetherroute-license/state:/var/lib/aetherroute \
    -v /etc/aetherroute-license/web/license-pepper.raw:/run/secrets/license-pepper.raw:ro \
    \"\$image\" issue \
      -product-id com.aetherroute.desktop \
      -state /var/lib/aetherroute/licenses.json \
      -pepper /run/secrets/license-pepper.raw \
      -max-devices 1 >'$remote_release/verification-license.json'
  chmod 600 '$remote_release/verification-license.json'
"

scp -q "$HOST:$remote_release/public-key-for-verification.raw" "$temporary/public-key.raw"
scp -q "$HOST:$remote_release/verification-license.json" "$temporary/verification-license.json"
jq -er '.activationKey' "$temporary/verification-license.json" >"$temporary/activation-key.txt"
chmod 600 "$temporary/activation-key.txt"
license_id=$(jq -er '.license.licenseID' "$temporary/verification-license.json")
verification_license_revoked=0

revoke_verification_license() {
  if [ "$verification_license_revoked" -eq 1 ]; then
    return 0
  fi
  ssh -o BatchMode=yes "$HOST" "
    set -eu
    image=\$(jq -r .image '$remote_release/metadata.json')
    docker run --rm --network none --read-only --cap-drop ALL \
      --security-opt no-new-privileges \
      --user 10002:12000 \
      --entrypoint /usr/local/bin/aetherroute-distribution \
      -v /var/lib/aetherroute-license/state:/var/lib/aetherroute \
      -v /etc/aetherroute-license/web/license-pepper.raw:/run/secrets/license-pepper.raw:ro \
      \"\$image\" set-state \
        -product-id com.aetherroute.desktop \
        -state /var/lib/aetherroute/licenses.json \
        -pepper /run/secrets/license-pepper.raw \
        -license-id '$license_id' -new-state revoked
    sudo -n rm -f '$remote_release/verification-license.json' \
      '$remote_release/public-key-for-verification.raw'
  "
  verification_license_revoked=1
}

if ! "$ROOT/scripts/verify_distribution_service_https.sh" \
  "$BASE_URL" "$temporary/public-key.raw" "$temporary/activation-key.txt" \
  "$BUILD" "$DOWNLOAD_URL"; then
  revoke_verification_license
  rollback_candidate
  echo "Public distribution service verification failed; previous deployment restored" >&2
  exit 1
fi

revoke_verification_license
ssh -o BatchMode=yes "$HOST" "
  set -eu
  previous=\$(cat '$remote_release/PREVIOUS')
  if [ \"\$previous\" = none ]; then
    test ! -L '$REMOTE_ROOT/current'
  else
    test \"\$(readlink '$REMOTE_ROOT/current')\" = \"\$previous\"
  fi
  ln -sfn 'releases/$RELEASE_ID' '$REMOTE_ROOT/current.next'
  mv -Tf '$REMOTE_ROOT/current.next' '$REMOTE_ROOT/current'
"

printf '%s\n' \
  "Deployed and publicly verified owner HTTPS distribution staging release: $RELEASE_ID"
