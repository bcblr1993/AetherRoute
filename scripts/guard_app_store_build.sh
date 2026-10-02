#!/bin/sh
set -eu
fail() { echo "error: Store build validation failed: $*" >&2; exit 1; }
case " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " in
  *' AETHERROUTE_QA_AUTOMATION '*|*' AETHERROUTE_DEVELOPMENT_PREVIEW '*)
    fail 'test fixtures cannot enter a Store product' ;;
esac
if [ "${CODE_SIGNING_ALLOWED:-YES}" = NO ]; then
  [ "${ACTION:-}" = build ] || fail 'unsigned builds are compilation checks only'
  exit 0
fi
[ "${CODE_SIGN_STYLE:-}" = Manual ] || fail 'manual Store profiles are required'
[ "${AETHERROUTE_DISTRIBUTION_MODE:-}" = free ] || fail 'independent licensing cannot ship in this Store edition'
[ -z "${AETHERROUTE_LICENSE_SERVICE_URL:-}${AETHERROUTE_UPDATE_MANIFEST_URL:-}" ] \
  || fail 'independent service endpoints cannot ship in the Store edition'
for role in HOST PACKET_TUNNEL TRANSPARENT_PROXY; do
  eval 'profile=${AETHERROUTE_'"$role"'_PROFILE_SPECIFIER:-}'
  [ -n "$profile" ] || fail "$role Store profile is missing"
done
echo 'Store build boundary verified; the signed bundle requires a separate final audit.'
