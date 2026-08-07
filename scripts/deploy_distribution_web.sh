#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WEB="$ROOT/Services/WebDistribution"
HOST=${1:-}
MODE=${2:-}
REMOTE_ROOT=/home/chenyn/services/aetherroute-distribution
IMAGE_TAG=nginx:1.28.3-alpine

usage() {
  echo "usage: $0 user@host preview /absolute/notarized-preview-directory unique-release-id" >&2
  echo "   or: $0 user@host stable /absolute/release.dmg /absolute/release.candidate.json /absolute/release.production.json /absolute/current.update.json" >&2
}

test -n "$HOST" && test -n "$MODE" || {
  usage
  exit 64
}

"$ROOT/scripts/test_distribution_web.sh"

temporary=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-web-deploy.XXXXXX")
cleanup() {
  test ! -d "$temporary" || find "$temporary" -depth -delete
}
trap cleanup EXIT HUP INT TERM

case "$MODE" in
  preview)
    CANDIDATE_DIRECTORY=${3:-}
    RELEASE_ID=${4:-}
    case "$CANDIDATE_DIRECTORY" in /*) ;; *) usage; exit 64 ;; esac
    test -d "$CANDIDATE_DIRECTORY" || {
      echo "preview directory does not exist" >&2
      exit 1
    }
    DMG="$CANDIDATE_DIRECTORY/AetherRoute-0.1.0-build-2026080703-arm64-Notarized-Test.dmg"
    SUMS="$CANDIDATE_DIRECTORY/SHA256SUMS"
    test -f "$DMG" && test -f "$SUMS" || {
      echo "preview directory does not contain the expected notarized package" >&2
      exit 1
    }
    (cd "$CANDIDATE_DIRECTORY" && shasum -a 256 -c SHA256SUMS)
    actual_sha=$(shasum -a 256 "$DMG" | awk '{print $1}')
    test "$actual_sha" = 4a18a47dfbd0886008753b9bbbbe9e4a36c5b1f7dc9f62951df59bea69299c20 || {
      echo "preview DMG checksum differs from the published release page" >&2
      exit 1
    }
    artifact_name=$(basename "$DMG")
    channel=prerelease
    expected_update_status=404
    mkdir -p "$temporary/payload/site" \
      "$temporary/payload/downloads/prerelease" "$temporary/payload/updates"
    cp -R "$WEB/public/." "$temporary/payload/site/"
    cp "$WEB/nginx.conf" "$temporary/payload/nginx.conf"
    cp "$DMG" "$temporary/payload/downloads/prerelease/"
    cp "$SUMS" "$temporary/payload/downloads/prerelease/SHA256SUMS"
    cp "$CANDIDATE_DIRECTORY/README.txt" \
      "$temporary/payload/downloads/prerelease/README.txt"
    cp "$WEB/docker-stack.yml" "$temporary/docker-stack.yml"
    ;;
  stable)
    DMG=${3:-}
    CANDIDATE_MANIFEST=${4:-}
    PRODUCTION_MANIFEST=${5:-}
    UPDATE_ENVELOPE=${6:-}
    for path in "$DMG" "$CANDIDATE_MANIFEST" "$PRODUCTION_MANIFEST" \
      "$UPDATE_ENVELOPE"
    do
      case "$path" in /*) ;; *) usage; exit 64 ;; esac
    done
    prepared="$temporary/prepared"
    "$ROOT/scripts/prepare_distribution_web_payload.sh" \
      "$DMG" "$CANDIDATE_MANIFEST" "$PRODUCTION_MANIFEST" \
      "$UPDATE_ENVELOPE" "$WEB/public" "$prepared"
    RELEASE_ID=$(jq -r '.releaseID' "$prepared/metadata.json")
    actual_sha=$(jq -r '.sha256' "$prepared/metadata.json")
    artifact_name=$(jq -r '.artifactName' "$prepared/metadata.json")
    channel=$(jq -r '.channel' "$prepared/metadata.json")
    expected_update_status=200
    mv "$prepared/payload" "$temporary/payload"
    mv "$prepared/docker-stack.yml" "$temporary/docker-stack.yml"
    ;;
  *)
    usage
    exit 64
    ;;
esac

printf '%s\n' "$RELEASE_ID" | grep -Eq '^[0-9A-Za-z][0-9A-Za-z._-]{2,63}$' || {
  echo "invalid release id" >&2
  exit 64
}
find "$temporary/payload" -type d -exec chmod 755 {} +
find "$temporary/payload" -type f -exec chmod 644 {} +
COPYFILE_DISABLE=1 tar --no-xattrs \
  -C "$temporary/payload" -czf "$temporary/payload.tgz" .

remote_incoming="$REMOTE_ROOT/.incoming-$RELEASE_ID"
remote_release="$REMOTE_ROOT/releases/$RELEASE_ID"

ssh -o BatchMode=yes "$HOST" "
  set -eu
  test ! -e '$remote_incoming'
  test ! -e '$remote_release'
  mkdir -p '$REMOTE_ROOT/releases' '$remote_incoming'
"
scp -q "$temporary/payload.tgz" "$temporary/docker-stack.yml" "$HOST:$remote_incoming/"

ssh -o BatchMode=yes "$HOST" "
  set -eu
  tar -xzf '$remote_incoming/payload.tgz' -C '$remote_incoming'
  rm '$remote_incoming/payload.tgz'
  chmod 755 '$remote_incoming' '$remote_incoming/site' '$remote_incoming/downloads' '$remote_incoming/updates'
  find '$remote_incoming' -type f -exec chmod 644 {} +
  mv '$remote_incoming' '$remote_release'
  previous=none
  if [ -L '$REMOTE_ROOT/current' ]; then
    previous=\$(readlink '$REMOTE_ROOT/current')
  fi
  restore_previous() {
    if [ \"\$previous\" = none ]; then
      docker stack rm aetherroute-web >/dev/null 2>&1 || true
    else
      if docker service inspect aetherroute-web_web >/dev/null 2>&1; then
        docker service rollback aetherroute-web_web >/dev/null 2>&1 || true
      fi
    fi
  }
  docker pull '$IMAGE_TAG' >/dev/null
  image=\$(docker image inspect '$IMAGE_TAG' --format '{{index .RepoDigests 0}}')
  test -n \"\$image\"
  export AETHERROUTE_WEB_IMAGE=\"\$image\"
  export AETHERROUTE_WEB_RELEASE_ROOT='$remote_release'
  if docker stack --help 2>/dev/null | grep -q ' config'; then
    docker stack config -c '$remote_release/docker-stack.yml' >/dev/null
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f '$remote_release/docker-stack.yml' config >/dev/null
  elif docker compose version >/dev/null 2>&1; then
    docker compose -f '$remote_release/docker-stack.yml' config >/dev/null
  else
    echo 'no supported Compose configuration validator is installed' >&2
    exit 1
  fi
  if ! docker stack deploy -c '$remote_release/docker-stack.yml' aetherroute-web; then
    restore_previous
    exit 1
  fi
  if ! mount_summary=\$(docker service inspect aetherroute-web_web \
    --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{.Target}}={{.Type}} {{end}}'); then
    restore_previous
    echo 'could not inspect the deployed Swarm mount specification' >&2
    exit 1
  fi
  case \"\$mount_summary\" in
    *'/tmp=tmpfs'*) ;;
    *)
      restore_previous
      echo 'Swarm dropped the required read-only-container tmpfs mount' >&2
      exit 1
      ;;
  esac
  healthy=no
  attempt=0
  while [ \"\$attempt\" -lt 30 ]; do
    update_state=\$(docker service inspect aetherroute-web_web \
      --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}completed{{end}}')
    statuses=\$(docker ps \
      --filter label=com.docker.swarm.service.name=aetherroute-web_web \
      --format '{{.Status}}')
    running_count=\$(printf '%s\n' \"\$statuses\" | sed '/^$/d' | wc -l | tr -d ' ')
    case \"\$update_state:\$running_count:\$statuses\" in
      completed:1:*\\(healthy\\)*) healthy=yes; break ;;
    esac
    attempt=\$((attempt + 1))
    sleep 2
  done
  if [ \"\$healthy\" != yes ]; then
    docker service ps --no-trunc aetherroute-web_web >&2 || true
    restore_previous
    echo 'AetherRoute web service did not become healthy; previous release restored' >&2
    exit 1
  fi
  printf '%s\n' \"\$previous\" >'$remote_release/PREVIOUS'
"

if ! "$ROOT/scripts/verify_distribution_web.sh" \
  "$actual_sha" "$artifact_name" "$channel" "$expected_update_status"; then
  ssh -o BatchMode=yes "$HOST" "
    set -eu
    previous=\$(cat '$remote_release/PREVIOUS')
    if [ \"\$previous\" = none ]; then
      docker stack rm aetherroute-web >/dev/null 2>&1 || true
    else
      case \"\$previous\" in releases/*) ;; *) echo 'invalid previous release pointer' >&2; exit 1 ;; esac
      docker service rollback aetherroute-web_web >/dev/null
      healthy=no
      attempt=0
      while [ \"\$attempt\" -lt 30 ]; do
        update_state=\$(docker service inspect aetherroute-web_web \
          --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}completed{{end}}')
        statuses=\$(docker ps \
          --filter label=com.docker.swarm.service.name=aetherroute-web_web \
          --format '{{.Status}}')
        running_count=\$(printf '%s\n' \"\$statuses\" | sed '/^$/d' | wc -l | tr -d ' ')
        case \"\$update_state:\$running_count:\$statuses\" in
          rollback_completed:1:*\\(healthy\\)*) healthy=yes; break ;;
          completed:1:*\\(healthy\\)*) healthy=yes; break ;;
        esac
        attempt=\$((attempt + 1))
        sleep 2
      done
      test \"\$healthy\" = yes
    fi
  " || echo "warning: automatic rollback also failed; operator action is required" >&2
  echo "public verification failed; the new release was not activated" >&2
  exit 1
fi

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

echo "Deployed and publicly verified AetherRoute web release: $RELEASE_ID"
