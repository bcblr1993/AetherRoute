#!/bin/sh
set -eu

release_root=${1:-}
remote_root=/home/chenyn/services/aetherroute-license
system_root=/etc/aetherroute-license
state_root=/var/lib/aetherroute-license/state
runtime_root=/var/lib/aetherroute-license/runtime
stack_name=aetherroute-license-staging

case "$release_root" in
  "$remote_root"/releases/*) ;;
  *) echo "invalid distribution release root" >&2; exit 64 ;;
esac
test -f "$release_root/metadata.json"
test -f "$release_root/docker-stack.yml"
test -f "$release_root/current.update.json"
test -f "$release_root/source-manifest.sha256"

image_tag=$(jq -er .image "$release_root/metadata.json")
expected_image_id=$(jq -er .imageID "$release_root/metadata.json")
expected_source_manifest_sha=$(jq -er .sourceManifestSHA256 "$release_root/metadata.json")
actual_image_id=$(docker image inspect "$image_tag" --format '{{.Id}}')
test "$actual_image_id" = "$expected_image_id"
actual_source_manifest_sha=$(sha256sum "$release_root/source-manifest.sha256" | awk '{print $1}')
test "$actual_source_manifest_sha" = "$expected_source_manifest_sha"

if docker stack --help 2>/dev/null | grep -q ' config'; then
  validator='docker stack config -c'
elif command -v docker-compose >/dev/null 2>&1; then
  validator='docker-compose -f'
elif docker compose version >/dev/null 2>&1; then
  validator='docker compose -f'
else
  echo "no supported Compose configuration validator is installed" >&2
  exit 1
fi

release_environment() {
  env \
    AETHERROUTE_DISTRIBUTION_IMAGE="$image_tag" \
    AETHERROUTE_SIGNER_SEED="$system_root/signer/signing-seed.raw" \
    AETHERROUTE_LICENSE_PEPPER="$system_root/web/license-pepper.raw" \
    AETHERROUTE_PUBLIC_KEY="$system_root/web/signing-public.raw" \
    AETHERROUTE_LICENSE_STATE_ROOT="$state_root" \
    AETHERROUTE_RUNTIME_ROOT="$runtime_root" \
    AETHERROUTE_UPDATE_ENVELOPE="$release_root/current.update.json" \
    "$@"
}

release_environment sh -c \
  "$validator \"$release_root/docker-stack.yml\" config" >/dev/null
release_environment docker stack deploy --resolve-image never \
  -c "$release_root/docker-stack.yml" "$stack_name" >/dev/null

for service in signer web; do
  healthy=no
  attempt=0
  while [ "$attempt" -lt 45 ]; do
    tasks=$(docker ps \
      --filter "label=com.docker.swarm.service.name=${stack_name}_${service}" \
      --format '{{.Image}}|{{.Status}}')
    running_count=$(printf '%s\n' "$tasks" | sed '/^$/d' | wc -l | tr -d ' ')
    case "$running_count:$tasks" in
      1:"$image_tag"\|*\(healthy\)*) healthy=yes; break ;;
    esac
    attempt=$((attempt + 1))
    sleep 2
  done
  if [ "$healthy" != yes ]; then
    docker service ps --no-trunc "${stack_name}_${service}" >&2 || true
    exit 1
  fi
done

test "$(docker service inspect "${stack_name}_signer" \
  --format '{{.Spec.TaskTemplate.ContainerSpec.User}}')" = 10001:12000
test "$(docker service inspect "${stack_name}_web" \
  --format '{{.Spec.TaskTemplate.ContainerSpec.User}}')" = 10002:12000
for service in signer web; do
  container=$(docker ps \
    --filter "label=com.docker.swarm.service.name=${stack_name}_${service}" \
    --format '{{.ID}}')
  test -n "$container"
  child_pid=$(docker exec "$container" awk '{print $1}' /proc/1/task/1/children)
  case "$child_pid" in ''|*[!0-9]*) exit 1 ;; esac
  no_new_privileges=$(docker exec "$container" \
    awk '$1 == "NoNewPrivs:" {print $2}' "/proc/$child_pid/status")
  test "$no_new_privileges" = 1
done

printf '%s\n' "$(basename "$release_root")"
