#!/bin/sh
set -eu

HOST=${1:-}
BASE_URL=${2:-https://license-staging.baizhiedu.xin}

usage() {
  echo "usage: $0 user@host [https://license-staging.baizhiedu.xin]" >&2
}

test -n "$HOST" || { usage; exit 64; }
case "$BASE_URL" in
  https://license-staging.baizhiedu.xin) ;;
  *) usage; exit 64 ;;
esac

ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o LogLevel=ERROR "$HOST" \
  'bash -s' -- "$BASE_URL" <<'REMOTE'
set -eu
umask 077

base_url=$1
stack=aetherroute-license-staging
signer_service=${stack}_signer
web_service=${stack}_web
remote_root=/home/chenyn/services/aetherroute-license
state_root=/var/lib/aetherroute-license/state
runtime_root=/var/lib/aetherroute-license/runtime
work=$(mktemp -d "$remote_root/.operations.XXXXXX")
license_id=
stage=initialize

current=$(readlink "$remote_root/current")
case "$current" in releases/*) ;; *) exit 1 ;; esac
release="$remote_root/$current"
image=$(jq -er .image "$release/metadata.json")

admin() {
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges \
    --user 10002:12000 \
    --entrypoint /usr/local/bin/aetherroute-distribution \
    -v "$state_root:/var/lib/aetherroute" \
    -v /etc/aetherroute-license/web/license-pepper.raw:/run/secrets/license-pepper.raw:ro \
    "$image" "$@"
}

wait_for_signer() {
  expected=$1
  attempt=0
  while [ "$attempt" -lt 60 ]; do
    statuses=$(docker ps \
      --filter "label=com.docker.swarm.service.name=$signer_service" \
      --format '{{.Status}}')
    count=$(printf '%s\n' "$statuses" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ "$expected" = stopped ] && [ "$count" -eq 0 ]; then
      return 0
    fi
    case "$expected:$count:$statuses" in
      healthy:1:*\(healthy\)*) return 0 ;;
    esac
    attempt=$((attempt + 1))
    sleep 1
  done
  docker service ps --no-trunc "$signer_service" >&2 || true
  return 1
}

cleanup() {
  set +e
  docker service scale "$signer_service=1" >/dev/null 2>&1
  wait_for_signer healthy >/dev/null 2>&1
  if [ -n "$license_id" ]; then
    admin set-state \
      -product-id com.aetherroute.desktop \
      -state /var/lib/aetherroute/licenses.json \
      -pepper /run/secrets/license-pepper.raw \
      -license-id "$license_id" -new-state revoked \
      >/dev/null 2>&1
  fi
  sudo -n find "$work" -depth -delete 2>/dev/null
}
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  cleanup
  if [ "$status" -ne 0 ]; then
    echo "Distribution operations failed during stage: $stage" >&2
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

stage=issue-license
admin issue \
  -product-id com.aetherroute.desktop \
  -state /var/lib/aetherroute/licenses.json \
  -pepper /run/secrets/license-pepper.raw \
  -max-devices 1 >"$work/license.json"
chmod 600 "$work/license.json"
license_id=$(jq -er .license.licenseID "$work/license.json")
jq -n \
  --arg key "$(jq -er .activationKey "$work/license.json")" \
  '{schemaVersion:1,action:"activate",productID:"com.aetherroute.desktop",deviceID:"11111111-2222-4333-8444-555555555555",appVersion:"0.1.0",appBuild:"2026080703",licenseKey:$key,signedReceipt:null}' \
  >"$work/activate.json"
chmod 600 "$work/activate.json"

stage=stop-signer
docker service scale "$signer_service=0" >/dev/null
wait_for_signer stopped
stage=expect-fail-closed
status=$(curl --noproxy '*' --silent --show-error \
  --proto '=https' --tlsv1.2 --max-redirs 0 \
  --connect-timeout 10 --max-time 20 \
  -H 'Content-Type: application/json' \
  --data-binary "@$work/activate.json" \
  --output "$work/unavailable.json" --write-out '%{http_code}' \
  "$base_url/v1/license")
test "$status" = 503

stage=restore-signer
docker service scale "$signer_service=1" >/dev/null
wait_for_signer healthy
stage=activate-after-recovery
status=$(curl --noproxy '*' --silent --show-error \
  --proto '=https' --tlsv1.2 --max-redirs 0 \
  --connect-timeout 10 --max-time 20 \
  -H 'Content-Type: application/json' \
  --data-binary "@$work/activate.json" \
  --output "$work/receipt.json" --write-out '%{http_code}' \
  "$base_url/v1/license")
test "$status" = 200
jq -e '.payload | type == "string"' "$work/receipt.json" >/dev/null
jq -e '.signature | type == "string"' "$work/receipt.json" >/dev/null

stage=deactivate
base64 -w 0 "$work/receipt.json" >"$work/receipt.base64"
jq -n \
  --rawfile receipt "$work/receipt.base64" \
  '{schemaVersion:1,action:"deactivate",productID:"com.aetherroute.desktop",deviceID:"11111111-2222-4333-8444-555555555555",appVersion:"0.1.0",appBuild:"2026080703",licenseKey:null,signedReceipt:$receipt}' \
  >"$work/deactivate.json"
status=$(curl --noproxy '*' --silent --show-error \
  --proto '=https' --tlsv1.2 --max-redirs 0 \
  --connect-timeout 10 --max-time 20 \
  -H 'Content-Type: application/json' \
  --data-binary "@$work/deactivate.json" \
  --output "$work/deactivated.json" --write-out '%{http_code}' \
  "$base_url/v1/license")
test "$status" = 204

stage=exact-method-boundary
test "$(curl --noproxy '*' --silent --show-error \
  --proto '=https' --tlsv1.2 --max-redirs 0 \
  --output /dev/null --write-out '%{http_code}' \
  "$base_url/v1/license")" = 405
test "$(curl --noproxy '*' --silent --show-error \
  --proto '=https' --tlsv1.2 --max-redirs 0 \
  --request POST --output /dev/null --write-out '%{http_code}' \
  "$base_url/v1/update")" = 405
test "$(curl --noproxy '*' --silent --show-error \
  --proto '=https' --tlsv1.2 --max-redirs 0 \
  --output /dev/null --write-out '%{http_code}' \
  "$base_url/not-a-route")" = 404

stage=isolated-backup-restore
clone="$work/clone"
sudo install -d -m 700 -o 10002 -g 12000 "$clone"
sudo install -m 600 -o 10002 -g 12000 \
  "$state_root/licenses.json" "$clone/backup.json"
sudo cp "$clone/backup.json" "$clone/working.json"
sudo chown 10002:12000 "$clone/working.json"
live_before=$(sudo sha256sum "$state_root/licenses.json" | awk '{print $1}')
backup_hash=$(sudo sha256sum "$clone/backup.json" | awk '{print $1}')
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges \
  --user 10002:12000 \
  --entrypoint /usr/local/bin/aetherroute-distribution \
  -v "$clone:/audit" \
  -v /etc/aetherroute-license/web/license-pepper.raw:/run/secrets/license-pepper.raw:ro \
  "$image" issue \
    -product-id com.aetherroute.desktop \
    -state /audit/working.json \
    -pepper /run/secrets/license-pepper.raw \
    -max-devices 1 >/dev/null
mutated_hash=$(sudo sha256sum "$clone/working.json" | awk '{print $1}')
test "$mutated_hash" != "$backup_hash"
sudo cp "$clone/backup.json" "$clone/working.json"
restored_hash=$(sudo sha256sum "$clone/working.json" | awk '{print $1}')
test "$restored_hash" = "$backup_hash"
live_after=$(sudo sha256sum "$state_root/licenses.json" | awk '{print $1}')
test "$live_after" = "$live_before"

stage=bounded-update-load
export base_url
seq 1 200 | xargs -n 1 -P 8 sh -c '
  code=$(curl --noproxy "*" --silent --show-error \
    --proto "=https" --tlsv1.2 --max-redirs 0 \
    --connect-timeout 10 --max-time 20 \
    --output /dev/null --write-out "%{http_code}" \
    "$base_url/v1/update")
  test "$code" = 200
' _

stage=log-privacy
web_container=$(docker ps -q --filter "name=$web_service" | head -1)
test -n "$web_container"
if docker logs "$web_container" 2>&1 | grep -Eq 'client:|request:'; then
  echo "Current Web task logged client request metadata" >&2
  exit 1
fi

stage=revoke-test-license
admin set-state \
  -product-id com.aetherroute.desktop \
  -state /var/lib/aetherroute/licenses.json \
  -pepper /run/secrets/license-pepper.raw \
  -license-id "$license_id" -new-state revoked
license_id=

stage=complete
printf '%s\n' \
  'Distribution operations passed: signer fail-closed, recovery, deactivate, exact methods, isolated restore, 200-request bounded load, private logs.'
REMOTE
