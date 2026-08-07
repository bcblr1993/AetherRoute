#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEPLOY="$ROOT/Services/DistributionService/deploy"
OPERATIONS_TEST="$ROOT/scripts/test_distribution_service_operations.sh"
ROLLBACK_SCRIPT="$ROOT/scripts/rollback_distribution_service.sh"

sh -n "$DEPLOY/signer-entrypoint.sh" "$DEPLOY/web-entrypoint.sh" \
  "$DEPLOY/activate-release.sh"
sh -n "$OPERATIONS_TEST"
test -x "$OPERATIONS_TEST"
sh -n "$ROLLBACK_SCRIPT"
test -x "$ROLLBACK_SCRIPT"
grep -Fq 'signer fail-closed' "$OPERATIONS_TEST"
grep -Fq 'sudo -n find "$work" -depth -delete' "$OPERATIONS_TEST"
grep -Fq 'restore_previous' "$ROLLBACK_SCRIPT"
grep -Fq 'verify_distribution_service_https.sh' "$ROLLBACK_SCRIPT"
grep -Fq 'target_deployed=1' "$ROLLBACK_SCRIPT"
grep -Fq 'committed=1' "$ROLLBACK_SCRIPT"
grep -Fq 'AETHERROUTE_UI' "$ROOT/scripts/test_ui_isolation_guards.sh"
grep -Fq 'nginx:1.28.3-alpine@sha256:' "$DEPLOY/Dockerfile"
grep -Fq 'STOPSIGNAL SIGTERM' "$DEPLOY/Dockerfile"
grep -Fq 'USER 10002:12000' "$DEPLOY/Dockerfile"
grep -Fq 'aetherroute-signer' "$DEPLOY/Dockerfile"
grep -Fq 'aetherroute-web' "$DEPLOY/Dockerfile"
grep -Fq '10001:12000:660' "$DEPLOY/signer-entrypoint.sh"
grep -Fq 'test -S "$socket"' "$DEPLOY/signer-entrypoint.sh"
grep -Fq 'refusing to replace a non-socket signer path' \
  "$DEPLOY/signer-entrypoint.sh"

grep -Fq 'user: "10001:12000"' "$DEPLOY/docker-stack.yml"
grep -Fq 'user: "10002:12000"' "$DEPLOY/docker-stack.yml"
test "$(grep -Fc 'cap_drop:' "$DEPLOY/docker-stack.yml")" -eq 2
test "$(grep -R -F -- '--no-new-privs' "$DEPLOY/Dockerfile" "$DEPLOY/docker-stack.yml" | wc -l | tr -d ' ')" -eq 2
test "$(grep -Fc 'read_only: true' "$DEPLOY/docker-stack.yml")" -eq 2
grep -Fq -- '-listen 127.0.0.1:9080' "$DEPLOY/web-entrypoint.sh"
grep -Fq -- '-trust-forwarded-for' "$DEPLOY/web-entrypoint.sh"
grep -Fq 'AETHERROUTE_SIGNER_SEED' "$DEPLOY/docker-stack.yml"
grep -Fq 'AETHERROUTE_LICENSE_PEPPER' "$DEPLOY/docker-stack.yml"
grep -Fq 'AETHERROUTE_LICENSE_STATE_ROOT' "$DEPLOY/docker-stack.yml"
grep -Fq 'docker-compose -f' "$DEPLOY/activate-release.sh"
grep -Fq 'docker stack deploy --resolve-image never' "$DEPLOY/activate-release.sh"
grep -Fq 'NoNewPrivs:' "$DEPLOY/activate-release.sh"
grep -Fq -- "--format '{{.Image}}|{{.Status}}'" "$DEPLOY/activate-release.sh"
grep -Fq 'expected_image_id' "$DEPLOY/activate-release.sh"
grep -Fq 'expected_source_manifest_sha' "$DEPLOY/activate-release.sh"
grep -Fq 'sourceManifestSHA256' "$DEPLOY/install-release.sh"
grep -Fq 'source-manifest.sha256' "$ROOT/scripts/deploy_distribution_service.sh"
test "$(grep -Fc 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' \
  "$ROOT/scripts/deploy_distribution_service.sh")" -eq 6
test "$(grep -Fc 'scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes' \
  "$ROOT/scripts/deploy_distribution_service.sh")" -eq 3
test "$(grep -Fc 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' \
  "$ROLLBACK_SCRIPT")" -eq 6
test "$(grep -Fc 'scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes' \
  "$ROLLBACK_SCRIPT")" -eq 3
grep -Fq 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' \
  "$OPERATIONS_TEST"
grep -Fq 'license-staging.baizhiedu.xin' "$DEPLOY/docker-stack.yml"
grep -Fq 'traefik.docker.network=proxy' "$DEPLOY/docker-stack.yml"
grep -Fq 'traefik.swarm.network=proxy' "$DEPLOY/docker-stack.yml"
grep -Fq 'entrypoints=websecure' "$DEPLOY/docker-stack.yml"
grep -Fq 'candidate edge did not become current' \
  "$ROOT/scripts/verify_distribution_service_https.sh"
grep -Fq 'revoke_verification_license' \
  "$ROOT/scripts/deploy_distribution_service.sh"
grep -Fq "curl --noproxy '*'" \
  "$ROOT/scripts/deploy_distribution_service.sh"
test "$(grep -Fc "curl --noproxy '*'" \
  "$ROOT/scripts/verify_distribution_service_https.sh")" -eq 3
if grep -Fq 'entrypoints=web,' "$DEPLOY/docker-stack.yml"; then
  echo "License API must not attach its router to the plain-HTTP entrypoint" >&2
  exit 1
fi

test "$(grep -Fc 'location = /v1/license' "$DEPLOY/nginx.conf")" -eq 1
test "$(grep -Fc 'location = /v1/update' "$DEPLOY/nginx.conf")" -eq 1
grep -Fq 'proxy_set_header X-Forwarded-For $remote_addr;' "$DEPLOY/nginx.conf"
grep -Fq 'access_log off;' "$DEPLOY/nginx.conf"
grep -Fq 'if ($request_method != POST) { return 405; }' "$DEPLOY/nginx.conf"
grep -Fq 'if ($request_method != GET) { return 405; }' "$DEPLOY/nginx.conf"
grep -Fq 'location / { return 404; }' "$DEPLOY/nginx.conf"
for temporary_directive in \
  'client_body_temp_path /tmp/client_temp;' \
  'proxy_temp_path /tmp/proxy_temp;' \
  'fastcgi_temp_path /tmp/fastcgi_temp;' \
  'uwsgi_temp_path /tmp/uwsgi_temp;' \
  'scgi_temp_path /tmp/scgi_temp;'
do
  grep -Fq "$temporary_directive" "$DEPLOY/nginx.conf"
done
if rg -n 'proxy_add_x_forwarded_for|access_log on|return 30[1278]|deny all' "$DEPLOY"; then
  echo "Distribution edge contains an unsafe forwarding, logging, or redirect rule" >&2
  exit 1
fi

if find "$DEPLOY" -type f \( -name '*.raw' -o -name 'licenses*.json' \) \
    -print -quit | grep -q .; then
  echo "Distribution deployment assets contain a secret or mutable state" >&2
  exit 1
fi

printf '%s\n' \
  'Distribution deployment guards passed: split users, loopback Web, exact HTTPS edge, immutable base, no embedded secrets.'
