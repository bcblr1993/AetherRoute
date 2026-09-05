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
  echo "   or: $0 user@host stable /absolute/release.dmg /absolute/release.candidate.json /absolute/release.production.json [/absolute/current.update.json]" >&2
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
    prepared="$temporary/prepared"
    "$ROOT/scripts/prepare_distribution_web_preview_payload.sh" \
      "$CANDIDATE_DIRECTORY" "$WEB/public" "$prepared"
    actual_sha=$(jq -r '.sha256' "$prepared/metadata.json")
    artifact_name=$(jq -r '.artifactName' "$prepared/metadata.json")
    channel=$(jq -r '.channel' "$prepared/metadata.json")
    expected_update_status=$(jq -r '.updateHTTPStatus' \
      "$prepared/metadata.json")
    mv "$prepared/payload" "$temporary/payload"
    mv "$prepared/docker-stack.yml" "$temporary/docker-stack.yml"
    ;;
  stable)
    DMG=${3:-}
    CANDIDATE_MANIFEST=${4:-}
    PRODUCTION_MANIFEST=${5:-}
    UPDATE_ENVELOPE=${6:-}
    for path in "$DMG" "$CANDIDATE_MANIFEST" "$PRODUCTION_MANIFEST"
    do
      case "$path" in /*) ;; *) usage; exit 64 ;; esac
    done
    prepared="$temporary/prepared"
    if [ -n "$UPDATE_ENVELOPE" ]; then
      "$ROOT/scripts/prepare_distribution_web_payload.sh" \
        "$DMG" "$CANDIDATE_MANIFEST" "$PRODUCTION_MANIFEST" \
        "$UPDATE_ENVELOPE" "$WEB/public" "$prepared"
    else
      "$ROOT/scripts/prepare_distribution_web_payload.sh" \
        "$DMG" "$CANDIDATE_MANIFEST" "$PRODUCTION_MANIFEST" \
        "$WEB/public" "$prepared"
    fi
    RELEASE_ID=$(jq -r '.releaseID' "$prepared/metadata.json")
    actual_sha=$(jq -r '.sha256' "$prepared/metadata.json")
    artifact_name=$(jq -r '.artifactName' "$prepared/metadata.json")
    channel=$(jq -r '.channel' "$prepared/metadata.json")
    # Require metadata consistent with the already-validated production mode.
    distribution_mode=$(jq -r 'if (.distribution | has("mode")) then .distribution.mode else "licensed" end' "$PRODUCTION_MANIFEST")
    jq -e --arg mode "$distribution_mode" '
      .distributionMode == $mode and
      (if .distributionMode == "free" then
        .updateEndpointPresent == false and .updateHTTPStatus == 404
      elif .distributionMode == "licensed" then
        .updateEndpointPresent == true and .updateHTTPStatus == 200
      else false end)
    ' "$prepared/metadata.json" >/dev/null
    if [ "$distribution_mode" = free ]; then
      test ! -e "$prepared/payload/updates/current.update.json"
      test ! -L "$prepared/payload/updates/current.update.json"
    else
      test -s "$prepared/payload/updates/current.update.json"
    fi
    expected_update_status=$(jq -r '.updateHTTPStatus' "$prepared/metadata.json")
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

ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$HOST" "
  set -eu
  test ! -e '$remote_incoming'
  test ! -e '$remote_release'
  mkdir -p '$REMOTE_ROOT/releases' '$remote_incoming'
"
scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes \
  "$temporary/payload.tgz" "$temporary/docker-stack.yml" \
  "$HOST:$remote_incoming/"

ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$HOST" "
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

verify_audit_directory=
if [ "$MODE" = preview ]; then
  verify_audit_directory=$CANDIDATE_DIRECTORY
fi
if ! "$ROOT/scripts/verify_distribution_web.sh" \
  "$actual_sha" "$artifact_name" "$channel" "$expected_update_status" \
  "$verify_audit_directory"; then
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$HOST" "
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

ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$HOST" "
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

