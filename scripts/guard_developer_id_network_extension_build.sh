#!/bin/sh
set -eu

# Debug is intentionally available for unit tests and UI-only development.
# A real Network Extension runtime must always come from the manually signed
# Release pipeline, never from an Xcode-managed Mac Team profile.
if [ "${CONFIGURATION:-}" != Release ]; then
  exit 0
fi

fail() {
  echo "error: Release Network Extensions require the manual Developer ID pipeline: $*" >&2
  echo "error: Use scripts/build_signed_local_test_candidate.sh for local runtime QA or scripts/release.sh for production." >&2
  exit 1
}

# QA automation can start the tunnel with no UI, which is exactly what an
# unattended acceptance run needs and exactly what must never reach a user.
# It is allowed only on the non-stable channel; anything destined for
# distribution is rejected here rather than relying on the fixture staying
# unset at runtime.
case " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " in
  *' AETHERROUTE_QA_AUTOMATION '*)
    [ "${AETHERROUTE_RELEASE_CHANNEL:-development}" != stable ] \
      || fail "AETHERROUTE_QA_AUTOMATION cannot ship on the stable channel"
    [ "${AETHERROUTE_NOTARIZED_CANDIDATE:-NO}" != YES ] \
      || fail "AETHERROUTE_QA_AUTOMATION cannot be notarized for distribution"
    echo "QA automation fixture present; this build is local QA only." ;;
esac

# A few isolated gates compile an optimized product in a disposable root but
# never install or launch its Network Extensions. They must opt in explicitly,
# remain non-stable, use the build action, and carry a compile-time fixture
# that fails closed before real routing can start. Archive/install actions can
# never use this exception.
if [ "${AETHERROUTE_ALLOW_ISOLATED_RELEASE_TEST_BUILD:-NO}" = YES ]; then
  [ "${ACTION:-}" = build ] \
    || fail "isolated Release test builds are limited to ACTION=build"
  [ "${AETHERROUTE_RELEASE_CHANNEL:-development}" != stable ] \
    || fail "stable builds cannot use the isolated Release test exception"
  case " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " in
    *' AETHERROUTE_DEVELOPMENT_PREVIEW '*|\
    *' AETHERROUTE_PERFORMANCE_MEASUREMENT '*|\
    *' AETHERROUTE_UI_RESPONSIVENESS '*) ;;
    *) fail "isolated Release test builds require a fail-closed fixture" ;;
  esac
  echo "Isolated non-installing Release test build allowed; Network Extension runtime remains disabled."
  exit 0
fi

[ "${CODE_SIGN_STYLE:-}" = Manual ] \
  || fail "CODE_SIGN_STYLE must be Manual; automatic Mac Team signing is forbidden"

if [ "${CODE_SIGN_IDENTITY:-}" != "Developer ID Application" ] \
  && ! printf '%s\n' "${CODE_SIGN_IDENTITY:-}" \
    | grep -Eq '^[A-Fa-f0-9]{40}$'; then
  fail "CODE_SIGN_IDENTITY must resolve to Developer ID Application"
fi

for assignment in \
  "host:${AETHERROUTE_HOST_PROFILE_SPECIFIER:-}" \
  "packet-tunnel:${AETHERROUTE_PACKET_TUNNEL_PROFILE_SPECIFIER:-}" \
  "transparent-proxy:${AETHERROUTE_TRANSPARENT_PROXY_PROFILE_SPECIFIER:-}"
do
  role=${assignment%%:*}
  profile=${assignment#*:}
  [ -n "$profile" ] || fail "$role Developer ID provisioning profile is missing"
done

case "${AETHERROUTE_HOST_ENTITLEMENTS:-}" in
  *AetherRoute.DeveloperID.entitlements) ;;
  *) fail "host must use the Developer ID entitlement file" ;;
esac
case "${AETHERROUTE_PACKET_TUNNEL_ENTITLEMENTS:-}" in
  *AetherRoutePacketTunnel.DeveloperID.entitlements) ;;
  *) fail "Packet Tunnel must use the Developer ID entitlement file" ;;
esac
case "${AETHERROUTE_TRANSPARENT_PROXY_ENTITLEMENTS:-}" in
  *AetherRouteTransparentProxy.DeveloperID.entitlements) ;;
  *) fail "Transparent Proxy must use the Developer ID entitlement file" ;;
esac

echo "Developer ID Release signing guard passed; automatic Mac Team profiles are disabled."

