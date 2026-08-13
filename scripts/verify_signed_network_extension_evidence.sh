#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EVIDENCE=${1:-}

fail() {
  echo "Signed Network Extension evidence failed: $*" >&2
  exit 1
}

case "$EVIDENCE" in
  /*) ;;
  '') echo "usage: verify_signed_network_extension_evidence.sh /absolute/evidence/directory" >&2; exit 64 ;;
  *) fail "evidence path must be absolute" ;;
esac
test -d "$EVIDENCE" && test ! -L "$EVIDENCE" \
  || fail "evidence must be a real directory"

for name in metadata.txt engine-tun.txt engine-transparent.txt result.txt SHA256SUMS; do
  test -f "$EVIDENCE/$name" && test ! -L "$EVIDENCE/$name" \
    || fail "$name must be a regular non-symlink file"
done
unexpected=$(find "$EVIDENCE" -mindepth 1 -maxdepth 1 \
  ! -name metadata.txt ! -name engine-tun.txt ! -name engine-transparent.txt \
  ! -name result.txt ! -name SHA256SUMS -print)
test -z "$unexpected" || fail "evidence contains unexpected raw files"
if grep -E -i 'https?://|token=|password=|probe_url=' \
  "$EVIDENCE/metadata.txt" "$EVIDENCE/engine-tun.txt" \
  "$EVIDENCE/engine-transparent.txt" "$EVIDENCE/result.txt" >/dev/null; then
  fail "evidence contains a URL or credential-like value"
fi

field() {
  file=$1
  key=$2
  count=$(awk -F= -v key="$key" '$1 == key {count++} END {print count+0}' "$file")
  test "$count" -eq 1 || fail "$file must contain exactly one $key field"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print}' "$file"
}

verify_hash() {
  name=$1
  expected=$(awk -v name="$name" '
    {
      hash=substr($0, 1, 64)
      path=substr($0, 65)
      sub(/^[[:space:]]+\*?/, "", path)
      sub(/^\*/, "", path)
      count=split(path, parts, "/")
      if (parts[count] == name) {matches++; matched_hash=hash}
    }
    END {if (matches != 1) exit 1; print matched_hash}
  ' "$EVIDENCE/SHA256SUMS") \
    || fail "SHA256SUMS must name $name exactly once"
  case "$expected" in
    ''|*[!0-9a-f]*) fail "$name has an invalid SHA-256" ;;
  esac
  test "${#expected}" -eq 64 || fail "$name has an invalid SHA-256 length"
  actual=$(shasum -a 256 "$EVIDENCE/$name" | awk '{print $1}')
  test "$actual" = "$expected" || fail "$name SHA-256 does not match"
}

for name in metadata.txt engine-tun.txt engine-transparent.txt result.txt; do
  verify_hash "$name"
done

metadata="$EVIDENCE/metadata.txt"
result="$EVIDENCE/result.txt"
test "$(field "$metadata" schema)" = 2 || fail "unsupported evidence schema"
test "$(field "$metadata" product)" = independent || fail "wrong product"
test "$(field "$metadata" machine)" = arm64 || fail "evidence is not arm64"
case "$(field "$metadata" engines)" in
  tun,transparent|transparent,tun) ;;
  *) fail "evidence does not cover both engines" ;;
esac
cycles=$(field "$metadata" cycles_per_engine)
case "$cycles" in ''|*[!0-9]*) fail "cycles_per_engine must be an integer" ;; esac
test "$cycles" -ge 3 && test "$cycles" -le 20 \
  || fail "each engine must pass between 3 and 20 cycles"
test "$(field "$metadata" signing_identity)" = 'Apple Development' \
  || fail "runtime evidence must use an Apple Development identity"
test "$(field "$metadata" runtime_signing_identity)" = 'Developer ID Application' \
  || fail "the tested runtime app was not Developer ID signed"
candidate_status=$(field "$metadata" candidate_release_status)
case "$candidate_status:${AETHERROUTE_ALLOW_LOCAL_SIGNED_NE_EVIDENCE:-NO}" in
  notarized-test-candidate:YES|notarized-test-candidate:NO) ;;
  signed-local-test-candidate:YES) ;;
  signed-local-test-candidate:NO)
    fail "local signed QA evidence cannot satisfy a production release gate"
    ;;
  *) fail "unsupported candidate release status" ;;
esac
test "$(field "$metadata" network_extension_runtime)" = enabled \
  || fail "Network Extension runtime was not enabled"
test "$(field "$metadata" raw_xcresult_retained)" = no \
  || fail "raw xcresult must not be retained"
test "$(field "$metadata" probe_url_retained)" = no \
  || fail "the canary URL must not be retained"
test "$(field "$metadata" control_peer_retained)" = no \
  || fail "the control peer must not be retained"
test "$(field "$metadata" dns_probe_host_retained)" = no \
  || fail "the ephemeral DNS probe host must not be retained"
test "$(field "$metadata" dns_nonce_retained)" = no \
  || fail "the ephemeral DNS nonce must not be retained"
test "$(field "$metadata" dns_gate_schema)" = public-best-effort-v1 \
  || fail "unsupported DNS evidence schema"
test "$(field "$metadata" dns_claim_level)" \
  = resolver-control+synthetic-stub-data-plane \
  || fail "the DNS claim level is invalid"
test "$(field "$metadata" dns_owner_canary)" = not-configured \
  || fail "public DNS evidence must not claim an owner canary"
test "$(field "$metadata" dns_upstream_path)" = not-verified \
  || fail "public DNS evidence must not claim a verified upstream path"
test "$(field "$metadata" dns_no_leak)" = not-verified \
  || fail "public DNS evidence must not claim no-leak verification"

for key in host_name_sha256 probe_url_sha256 probe_response_sha256 \
  network_control_before_sha256 candidate_manifest_sha256 \
  control_peer_sha256 control_interface_sha256 control_watchdog_sha256 \
  dns_probe_sha256; do
  value=$(field "$metadata" "$key")
  case "$value" in ''|*[!0-9a-f]*) fail "$key is not lowercase SHA-256" ;; esac
  test "${#value}" -eq 64 || fail "$key has the wrong length"
done
test "$(field "$metadata" control_watchdog_interval_seconds)" = 2 \
  || fail "the control watchdog interval must be two seconds"
test "$(field "$metadata" control_watchdog_failure_limit)" = 5 \
  || fail "the control watchdog must require five consecutive failures"
control_watchdog_timeout=$(field "$metadata" control_watchdog_hard_timeout_seconds)
case "$control_watchdog_timeout" in
  ''|*[!0-9]*) fail "control_watchdog_hard_timeout_seconds must be an integer" ;;
esac
test "$control_watchdog_timeout" -ge 180 \
  && test "$control_watchdog_timeout" -le 3600 \
  || fail "the control watchdog hard timeout is outside the safe range"
printf '%s\n' "$(field "$metadata" candidate_version)" \
  | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
  || fail "candidate_version is invalid"
printf '%s\n' "$(field "$metadata" candidate_build)" \
  | grep -Eq '^[1-9][0-9]*$' || fail "candidate_build is invalid"
for key in host_bundle_id packet_bundle_id transparent_bundle_id; do
  value=$(field "$metadata" "$key")
  printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' \
    || fail "$key is invalid"
  printf '%s\n' "$value" | grep -Eq 'example|yourcompany' \
    && fail "$key is still a placeholder"
done

for engine in tun transparent; do
  engine_file="$EVIDENCE/engine-$engine.txt"
  test "$(field "$engine_file" product)" = independent || fail "$engine product mismatch"
  test "$(field "$engine_file" engine)" = "$engine" || fail "$engine result mismatch"
  test "$(field "$engine_file" cycles)" = "$cycles" || fail "$engine cycle mismatch"
  test "$(field "$engine_file" before_connection_probe)" = unreachable \
    || fail "$engine canary was reachable before connection"
  test "$(field "$engine_file" connected_probe)" = matched \
    || fail "$engine did not carry the canary"
  test "$(field "$engine_file" after_disconnect_probe)" = unreachable \
    || fail "$engine canary remained reachable after disconnect"
  test "$(field "$engine_file" provider_readiness)" = reported \
    || fail "$engine did not report provider readiness"
  test "$(field "$engine_file" control_peer_route_and_direct_ping)" = passed \
    || fail "$engine did not preserve the control route and direct ping"
  test "$(field "$engine_file" tailscale_magic_dns_route)" = passed \
    || fail "$engine did not preserve the Tailscale MagicDNS route"
  case "$engine" in
    tun) expected_watchdog=passed ;;
    transparent) expected_watchdog=not-applicable ;;
  esac
  test "$(field "$engine_file" control_peer_watchdog)" = "$expected_watchdog" \
    || fail "$engine has the wrong control watchdog result"
  test "$(field "$engine_file" dns_gate_schema)" = public-best-effort-v1 \
    || fail "$engine has the wrong DNS evidence schema"
  test "$(field "$engine_file" dns_cycles)" = "$cycles" \
    || fail "$engine DNS cycle count does not match"
  test "$(field "$engine_file" dns_connected_checks)" = "$cycles" \
    || fail "$engine did not check DNS on every connected cycle"
  test "$(field "$engine_file" dns_disconnect_checks)" = "$cycles" \
    || fail "$engine did not check DNS after every disconnect"
  test "$(field "$engine_file" dns_baseline_stub)" = unavailable \
    || fail "$engine synthetic DNS stub was reachable before connection"
  test "$(field "$engine_file" dns_disconnect_resolver_restore)" = passed \
    || fail "$engine did not restore the resolver after every disconnect"
  test "$(field "$engine_file" dns_disconnect_stub)" = unavailable \
    || fail "$engine synthetic DNS stub remained reachable after disconnect"
  test "$(field "$engine_file" dns_upstream_path)" = not-verified \
    || fail "$engine overclaims DNS upstream verification"
  test "$(field "$engine_file" dns_no_leak)" = not-verified \
    || fail "$engine overclaims DNS no-leak verification"
  if [ "$engine" = tun ]; then
    test "$(field "$engine_file" dns_default_resolver)" = passed \
      || fail "TUN did not install the synthetic default resolver"
    test "$(field "$engine_file" dns_connected_resolver_unchanged)" \
      = not-applicable \
      || fail "TUN has an invalid unchanged-resolver claim"
    test "$(field "$engine_file" dns_stub_route)" = utun \
      || fail "TUN synthetic DNS stub was not routed through utun"
    test "$(field "$engine_file" dns_stub_interface)" \
      = 198.18.0.1-present \
      || fail "TUN synthetic DNS interface address was absent"
    test "$(field "$engine_file" dns_stub_udp_passed)" = "$cycles" \
      || fail "TUN synthetic DNS UDP did not pass every cycle"
    test "$(field "$engine_file" dns_stub_tcp_passed)" = "$cycles" \
      || fail "TUN synthetic DNS TCP did not pass every cycle"
  else
    test "$(field "$engine_file" dns_default_resolver)" = not-applicable \
      || fail "Transparent Proxy must not claim a synthetic default resolver"
    test "$(field "$engine_file" dns_connected_resolver_unchanged)" = passed \
      || fail "Transparent Proxy changed the resolver while connected"
    test "$(field "$engine_file" dns_stub_route)" = not-applicable \
      || fail "Transparent Proxy must not claim a synthetic DNS route"
    test "$(field "$engine_file" dns_stub_interface)" = not-applicable \
      || fail "Transparent Proxy must not claim a synthetic DNS interface"
    test "$(field "$engine_file" dns_stub_udp_passed)" = not-applicable \
      || fail "Transparent Proxy must not claim synthetic DNS UDP"
    test "$(field "$engine_file" dns_stub_tcp_passed)" = not-applicable \
      || fail "Transparent Proxy must not claim synthetic DNS TCP"
  fi
  test "$(field "$engine_file" network_control_restored)" = yes \
    || fail "$engine did not restore the system network control plane"
  test "$(field "$engine_file" result)" = passed || fail "$engine did not pass"
done

test "$(field "$result" engines)" = tun,transparent \
  || fail "combined result does not cover both engines"
test "$(field "$result" cycles_per_engine)" = "$cycles" \
  || fail "combined cycle count does not match"
test "$(field "$result" raw_xcresult_retained)" = no \
  || fail "combined result retained raw xcresult"
test "$(field "$result" tun_control_peer_watchdog)" = passed \
  || fail "combined result did not pass the TUN control watchdog"
test "$(field "$result" control_peer_route_and_direct_ping_restored)" = yes \
  || fail "combined result did not restore the control route and direct ping"
test "$(field "$result" tailscale_magic_dns_route_restored)" = yes \
  || fail "combined result did not restore the Tailscale MagicDNS route"
test "$(field "$result" dns_gate)" = passed \
  || fail "combined result did not pass the DNS gate"
test "$(field "$result" dns_claim_level)" \
  = resolver-control+synthetic-stub-data-plane \
  || fail "combined result has the wrong DNS claim level"
test "$(field "$result" dns_owner_canary)" = not-configured \
  || fail "combined public DNS result must not claim an owner canary"
test "$(field "$result" dns_upstream_path)" = not-verified \
  || fail "combined DNS result overclaims upstream verification"
test "$(field "$result" dns_no_leak)" = not-verified \
  || fail "combined DNS result overclaims no-leak verification"
test "$(field "$result" dns_status)" = passed-with-upstream-unproven \
  || fail "combined DNS status does not preserve its public-evidence limit"
test "$(field "$result" network_control_restored)" = yes \
  || fail "combined result did not restore the system network control plane"
test "$(field "$result" status)" = passed || fail "combined result did not pass"

current_source_manifest=$("$ROOT/scripts/source_manifest.sh" \
  | awk '$1 == "MANIFEST_SHA256" {print $2}')
test "$(field "$metadata" source_manifest_sha256)" = "$current_source_manifest" \
  || fail "source manifest does not match the current release tree"

verify_source_hash() {
  key=$1
  source=$2
  actual=$(shasum -a 256 "$source" | awk '{print $1}')
  test "$(field "$metadata" "$key")" = "$actual" \
    || fail "$key does not match the current release tree"
}
verify_source_hash runner_sha256 "$ROOT/scripts/test_signed_network_extension.sh"
verify_source_hash control_watchdog_sha256 "$ROOT/scripts/signed_ne_control_watchdog.sh"
verify_source_hash dns_probe_sha256 "$ROOT/scripts/signed_ne_dns_probe.sh"
verify_source_hash ui_test_sha256 "$ROOT/Tests/AetherRouteUITests/AetherRouteUITests.swift"
verify_source_hash flow_artifact_sha256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a"
verify_source_hash packet_artifact_sha256 "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a"

echo "Signed Network Extension evidence verified: both engines passed canary, resolver-control, synthetic TUN DNS, lifecycle, and restoration gates against the exact current source tree; DNS upstream and no-leak remain unverified."
