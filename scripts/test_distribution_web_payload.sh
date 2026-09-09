#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PREPARER="$ROOT/scripts/prepare_distribution_web_payload.sh"
TOOL="$ROOT/scripts/distribution_envelope_tool.swift"

sh -n "$PREPARER"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-web-payload-test.XXXXXX")
cleanup() {
  if [ -d "$temporary" ]; then
    chmod -R u+w "$temporary" 2>/dev/null || true
    find "$temporary" -depth -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

private_key="$temporary/private-key.raw"
public_key="$temporary/public-key.raw"
dmg="$temporary/AetherRoute-1.0.0-arm64.dmg"
candidate="$temporary/AetherRoute-1.0.0-arm64.candidate.json"
production="$temporary/AetherRoute-1.0.0-arm64.production.json"
update="$temporary/current.update.json"
site="$temporary/site"
printf '01234567890123456789012345678901' >"$private_key"
chmod 600 "$private_key"
printf 'stable-distribution-payload-fixture-with-range-capable-bytes' >"$dmg"
ditto "$ROOT/Services/WebDistribution/public" "$site"

xcrun swift "$TOOL" public-key "$private_key" "$public_key"
public_key_base64=$(base64 <"$public_key" | tr -d '\n')
public_key_sha=$(shasum -a 256 "$public_key" | awk '{print $1}')
dmg_sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
dmg_bytes=$(stat -f '%z' "$dmg")
git_commit=$(git -C "$ROOT" rev-parse HEAD)
source_manifest=$("$ROOT/scripts/source_manifest.sh" \
  | awk '$1 == "MANIFEST_SHA256" {print $2}')

jq -n \
  --arg productID com.aetherroute.desktop \
  --arg version 1.0.0 \
  --arg releasedAt 2026-08-07T08:00:00Z \
  --arg minimumSystemVersion 15.0 \
  --arg gitCommit "$git_commit" \
  --arg sourceManifest "$source_manifest" \
  --arg publicKeySHA "$public_key_sha" \
  --arg dmgSHA "$dmg_sha" \
  --argjson dmgBytes "$dmg_bytes" '
  {
    schemaVersion: 1,
    releaseStatus: "notarized-candidate",
    product: "AetherRoute",
    author: "陈艳男 (ChenYanNan)",
    productID: $productID,
    version: $version,
    build: 100,
    releasedAt: $releasedAt,
    minimumSystemVersion: $minimumSystemVersion,
    architecture: "arm64",
    source: {gitCommit: $gitCommit, manifestSHA256: $sourceManifest},
    distribution: {updateSigningPublicKeySHA256: $publicKeySHA},
    dmg: {sha256: $dmgSHA, bytes: $dmgBytes},
    notarization: {status: "Accepted", submissionID: "test-submission"},
    stability: {schema: 2, evidenceSHA256: ("a" * 64), durationSeconds: 86400, rounds: 800},
    signedRuntime: {schema: 1, evidenceSHA256: ("b" * 64), engines: ["tun", "transparent"], cyclesPerEngine: 3}
  }' >"$candidate"
candidate_sha=$(shasum -a 256 "$candidate" | awk '{print $1}')
jq \
  --arg candidateSHA "$candidate_sha" '
  .releaseStatus = "production-approved" |
  .promotion = {
    schema: 1,
    approvedAt: "2026-08-07T09:00:00Z",
    candidateManifestSHA256: $candidateSHA,
    postInstallEvidenceSHA256: ("c" * 64),
    exactDMGSHA256: .dmg.sha256
  }' "$candidate" >"$production"

AETHERROUTE_DISTRIBUTION_PUBLIC_KEY="$public_key_base64" \
  "$ROOT/scripts/generate_update_envelope.sh" \
  "$private_key" "$dmg" com.aetherroute.desktop 1.0.0 100 \
  2026-08-07T09:00:00Z 15.0 \
  https://downloads.baizhiedu.xin/releases/1.0.0/AetherRoute-1.0.0-arm64.dmg \
  https://aetherroute.baizhiedu.xin/releases/1.0.0/ \
  "$update" >/dev/null

output="$temporary/output"
AETHERROUTE_DISTRIBUTION_PUBLIC_KEY="$public_key_base64" \
  "$PREPARER" "$dmg" "$candidate" "$production" "$update" \
  "$site" "$output" >/dev/null

test "$(jq -r '.releaseID' "$output/metadata.json")" = \
  stable-1.0.0-build-100
test "$(jq -r '.updateHTTPStatus' "$output/metadata.json")" = 200
jq -e '.distributionMode == "licensed" and .updateEndpointPresent == true' \
  "$output/metadata.json" >/dev/null
test -s "$output/payload/downloads/releases/1.0.0/$(
  basename "$dmg"
)"
(
  cd "$output/payload/downloads/releases/1.0.0"
  shasum -a 256 -c SHA256SUMS >/dev/null
)
cmp -s "$update" "$output/payload/updates/current.update.json"
rg -F '下载 AetherRoute 1.0.0' "$output/payload/site/index.html" >/dev/null
rg -F 'Current stable' "$output/payload/site/releases/index.html" >/dev/null
rg -F "$dmg_sha" \
  "$output/payload/site/releases/1.0.0/index.html" >/dev/null
if rg -F 'downloads.baizhiedu.xin/prerelease/' \
  "$output/payload/site/index.html" >/dev/null; then
  echo "stable homepage still links to the preview download" >&2
  exit 1
fi

tampered_update="$temporary/tampered.update.json"
jq '.signature = ((if (.signature | startswith("A")) then "B" else "A" end) + .signature[1:])' \
  "$update" >"$tampered_update"
if AETHERROUTE_DISTRIBUTION_PUBLIC_KEY="$public_key_base64" \
  "$PREPARER" "$dmg" "$candidate" "$production" "$tampered_update" \
  "$site" "$temporary/tampered-output" >/dev/null 2>&1; then
  echo "stable distribution accepted a tampered update envelope" >&2
  exit 1
fi
test ! -e "$temporary/tampered-output"

mkdir -p "$temporary/wrong-candidate" "$temporary/wrong-product"
wrong_candidate="$temporary/wrong-candidate/AetherRoute-1.0.0-arm64.candidate.json"
jq '.author = "unexpected"' "$candidate" >"$wrong_candidate"
if AETHERROUTE_DISTRIBUTION_PUBLIC_KEY="$public_key_base64" \
  "$PREPARER" "$dmg" "$wrong_candidate" "$production" "$update" \
  "$site" "$temporary/wrong-output" >/dev/null 2>&1; then
  echo "stable distribution accepted a production manifest from another candidate" >&2
  exit 1
fi
test ! -e "$temporary/wrong-output"

wrong_product="$temporary/wrong-product/AetherRoute-1.0.0-arm64.production.json"
jq '.productID = "com.example.wrong"' "$production" >"$wrong_product"
if AETHERROUTE_DISTRIBUTION_PUBLIC_KEY="$public_key_base64" \
  "$PREPARER" "$dmg" "$candidate" "$wrong_product" "$update" \
  "$site" "$temporary/product-output" >/dev/null 2>&1; then
  echo "stable distribution accepted another product identifier" >&2
  exit 1
fi
test ! -e "$temporary/product-output"

mkdir -p "$temporary/predated" "$temporary/symlink-site"
predated="$temporary/predated/AetherRoute-1.0.0-arm64.production.json"
jq '.promotion.approvedAt = "2026-08-07T07:00:00Z"' \
  "$production" >"$predated"
if AETHERROUTE_DISTRIBUTION_PUBLIC_KEY="$public_key_base64" \
  "$PREPARER" "$dmg" "$candidate" "$predated" "$update" \
  "$site" "$temporary/predated-output" >/dev/null 2>&1; then
  echo "stable distribution accepted approval before candidate creation" >&2
  exit 1
fi
test ! -e "$temporary/predated-output"

ditto "$site" "$temporary/symlink-site/public"
ln -s /etc/hosts "$temporary/symlink-site/public/untrusted-link"
if AETHERROUTE_DISTRIBUTION_PUBLIC_KEY="$public_key_base64" \
  "$PREPARER" "$dmg" "$candidate" "$production" "$update" \
  "$temporary/symlink-site/public" "$temporary/symlink-output" \
  >/dev/null 2>&1; then
  echo "stable distribution accepted a symlink in the website source" >&2
  exit 1
fi
test ! -e "$temporary/symlink-output"

# Exercise the actual preparer with both new explicit modes and legacy licensed
# manifests. These are synthetic evidence fixtures, never real release approval.
write_approval() {
  input=$1
  target=$2
  input_sha=$(shasum -a 256 "$input" | awk '{print $1}')
  jq --arg candidateSHA "$input_sha" '
    .releaseStatus = "production-approved" |
    .promotion = {schema: 1, approvedAt: "2026-08-07T09:00:00Z",
      candidateManifestSHA256: $candidateSHA,
      postInstallEvidenceSHA256: ("c" * 64), exactDMGSHA256: .dmg.sha256}
  ' "$input" >"$target"
}
expect_rejection() {
  label=$1
  reason=$2
  shift 2
  if "$@" >"$temporary/rejection.log" 2>&1; then
    echo "distribution payload unexpectedly accepted: $label" >&2
    exit 1
  fi
  grep -F "$reason" "$temporary/rejection.log" >/dev/null || {
    echo "distribution payload failed at an unrelated guard: $label" >&2
    cat "$temporary/rejection.log" >&2
    exit 1
  }
  echo "Rejected expected invalid payload: $label"
}

mkdir "$temporary/explicit-licensed" "$temporary/free"
licensed_candidate="$temporary/explicit-licensed/$(basename "$candidate")"
licensed_production="$temporary/explicit-licensed/$(basename "$production")"
jq '.distribution.mode = "licensed"' "$candidate" >"$licensed_candidate"
write_approval "$licensed_candidate" "$licensed_production"
AETHERROUTE_DISTRIBUTION_PUBLIC_KEY="$public_key_base64" \
  "$PREPARER" "$dmg" "$licensed_candidate" "$licensed_production" \
  "$update" "$site" "$temporary/explicit-licensed-output" >/dev/null
jq -e '.distributionMode == "licensed" and .updateEndpointPresent == true and .updateHTTPStatus == 200' \
  "$temporary/explicit-licensed-output/metadata.json" >/dev/null
cmp -s "$update" "$temporary/explicit-licensed-output/payload/updates/current.update.json"
expect_rejection licensed-without-key 'requires AETHERROUTE_DISTRIBUTION_PUBLIC_KEY' \
  env -u AETHERROUTE_DISTRIBUTION_PUBLIC_KEY "$PREPARER" "$dmg" \
  "$licensed_candidate" "$licensed_production" "$update" "$site" "$temporary/missing-key-output"
expect_rejection licensed-without-envelope 'omit current.update.json for free; supply it for licensed' \
  env AETHERROUTE_DISTRIBUTION_PUBLIC_KEY="$public_key_base64" "$PREPARER" "$dmg" \
  "$licensed_candidate" "$licensed_production" "$site" "$temporary/missing-envelope-output"

free_candidate="$temporary/free/$(basename "$candidate")"
free_production="$temporary/free/$(basename "$production")"
jq '.distribution = {mode: "free", updateSigningPublicKeySHA256: null}' \
  "$candidate" >"$free_candidate"
write_approval "$free_candidate" "$free_production"
env -u AETHERROUTE_DISTRIBUTION_PUBLIC_KEY "$PREPARER" "$dmg" \
  "$free_candidate" "$free_production" "$site" "$temporary/free-output" >/dev/null
jq -e '.distributionMode == "free" and .updateEndpointPresent == false and .updateHTTPStatus == 404' \
  "$temporary/free-output/metadata.json" >/dev/null
test -d "$temporary/free-output/payload/updates"
test -z "$(find "$temporary/free-output/payload/updates" -type f -print)"
(
  cd "$temporary/free-output/payload/downloads/releases/1.0.0"
  shasum -a 256 -c SHA256SUMS >/dev/null
  cmp -s "$dmg" "$(basename "$dmg")"
  cmp -s "$free_candidate" "$(basename "$candidate")"
  cmp -s "$free_production" "$(basename "$production")"
)
expect_rejection free-with-envelope 'free distribution must not supply' \
  env -u AETHERROUTE_DISTRIBUTION_PUBLIC_KEY "$PREPARER" "$dmg" \
  "$free_candidate" "$free_production" "$update" "$site" "$temporary/free-envelope-output"
expect_rejection free-with-key 'free distribution must not supply' \
  env AETHERROUTE_DISTRIBUTION_PUBLIC_KEY="$public_key_base64" "$PREPARER" "$dmg" \
  "$free_candidate" "$free_production" "$site" "$temporary/free-key-output"
expect_rejection free-without-production 'stable distribution input is missing' \
  env -u AETHERROUTE_DISTRIBUTION_PUBLIC_KEY "$PREPARER" "$dmg" \
  "$free_candidate" "$temporary/absent.production.json" "$site" "$temporary/free-missing-production-output"

# Modify candidate + approval together so deeper guards, not just the exact
# manifest comparison, have to reject each bad source/DMG/signing claim.
for label in mode-null mode-false mode-unknown nonnull-key no-mode-null-key unapproved \
  notarization soak signed-runtime product source-commit source-manifest dmg-hash dmg-bytes
do
  case "$label" in
    mode-null) expression='.distribution.mode = null'; reason='production manifest is incomplete' ;;
    mode-false) expression='.distribution.mode = false'; reason='production manifest is incomplete' ;;
    mode-unknown) expression='.distribution.mode = "development"'; reason='production manifest is incomplete' ;;
    nonnull-key) expression='.distribution.updateSigningPublicKeySHA256 = ("a" * 64)'; reason='production manifest is incomplete' ;;
    no-mode-null-key) expression='del(.distribution.mode)'; reason='production manifest is incomplete' ;;
    unapproved) expression='.'; reason='production manifest is incomplete' ;;
    notarization) expression='.notarization.status = "Rejected"'; reason='production manifest is incomplete' ;;
    soak) expression='del(.stability)'; reason='production manifest is incomplete' ;;
    signed-runtime) expression='.signedRuntime.engines = ["tun"]'; reason='production manifest is incomplete' ;;
    product) expression='.productID = "com.example.wrong"'; reason='production manifest is incomplete' ;;
    source-commit) expression='.source.gitCommit = ("0" * 40)'; reason='current Git commit' ;;
    source-manifest) expression='.source.manifestSHA256 = ("0" * 64)'; reason='current source manifest' ;;
    dmg-hash) expression='.dmg.sha256 = ("0" * 64)'; reason='stable DMG SHA-256' ;;
    dmg-bytes) expression='.dmg.bytes += 1'; reason='stable DMG byte count' ;;
  esac
  folder="$temporary/negative-$label"
  mkdir "$folder"
  bad_candidate="$folder/$(basename "$candidate")"
  bad_production="$folder/$(basename "$production")"
  jq "$expression" "$free_candidate" >"$bad_candidate"
  write_approval "$bad_candidate" "$bad_production"
  if [ "$label" = unapproved ]; then cp "$bad_candidate" "$bad_production"; fi
  expect_rejection "$label" "$reason" env -u AETHERROUTE_DISTRIBUTION_PUBLIC_KEY \
    "$PREPARER" "$dmg" "$bad_candidate" "$bad_production" "$site" "$folder/output"
  test ! -e "$folder/output"
done

mkdir "$temporary/free-wrong-candidate"
jq '.author = "changed"' "$free_candidate" \
  >"$temporary/free-wrong-candidate/$(basename "$candidate")"
expect_rejection free-exact-candidate 'production manifest does not preserve the exact candidate' \
  env -u AETHERROUTE_DISTRIBUTION_PUBLIC_KEY "$PREPARER" "$dmg" \
  "$temporary/free-wrong-candidate/$(basename "$candidate")" "$free_production" \
  "$site" "$temporary/free-wrong-candidate/output"
expect_rejection free-site-symlink 'site source must not contain symbolic links' \
  env -u AETHERROUTE_DISTRIBUTION_PUBLIC_KEY "$PREPARER" "$dmg" \
  "$free_candidate" "$free_production" "$temporary/symlink-site/public" "$temporary/free-symlink-output"
expect_rejection free-refuse-overwrite 'refusing to overwrite distribution payload' \
  env -u AETHERROUTE_DISTRIBUTION_PUBLIC_KEY "$PREPARER" "$dmg" \
  "$free_candidate" "$free_production" "$site" "$temporary/free-output"

echo "Stable distribution payload tests passed: legacy and explicit licensed, free, and strict invalid evidence."

# Preview fixtures exercise real plist, executable SHA and published checksums.
# Only macOS signing/mount services are mocked; no preparer bypass is enabled.
PREVIEW_PREPARER="$ROOT/scripts/prepare_distribution_web_preview_payload.sh"
sh -n "$PREVIEW_PREPARER"
preview_root="$temporary/preview"
preview_candidate="$preview_root/candidate"
preview_tools="$preview_root/tools"
preview_app="$preview_root/mounted-app/AetherRoute.app"
preview_version=1.0.0
preview_build=2026090901
preview_stem="AetherRoute-$preview_version-build-$preview_build-arm64-Notarized-Test-Normal-Core"
mkdir -p "$preview_candidate" "$preview_tools" "$preview_app/Contents/MacOS"
printf 'normal-core-preview-DMG-fixture' >"$preview_candidate/$preview_stem.dmg"
printf 'MANIFEST_SHA256 %064d\n' 0 >"$preview_candidate/source-manifest.txt"
printf 'Synthetic free beta fixture; not a signed release.\n' >"$preview_candidate/README.txt"

for role in app packetTunnel transparentProxy; do
  case "$role" in
    app) bundle_id=com.aetherroute.desktop; bundle="$preview_app" ;;
    packetTunnel) bundle_id=com.aetherroute.desktop.tunnel
      bundle="$preview_app/Contents/Library/SystemExtensions/$bundle_id.systemextension" ;;
    transparentProxy) bundle_id=com.aetherroute.desktop.transparent-proxy
      bundle="$preview_app/Contents/Library/SystemExtensions/$bundle_id.systemextension" ;;
  esac
  mkdir -p "$bundle/Contents/MacOS"
  printf 'synthetic executable: %s\n' "$role" >"$bundle/Contents/MacOS/$bundle_id"
  chmod 755 "$bundle/Contents/MacOS/$bundle_id"
  plist="$bundle/Contents/Info.plist"
  plutil -create xml1 "$plist"
  plutil -insert CFBundleIdentifier -string "$bundle_id" "$plist"
  plutil -insert CFBundleExecutable -string "$bundle_id" "$plist"
  plutil -insert CFBundleShortVersionString -string "$preview_version" "$plist"
  plutil -insert CFBundleVersion -string "$preview_build" "$plist"
done
preview_plist="$preview_app/Contents/Info.plist"
plutil -insert AetherRouteDistributionMode -string free "$preview_plist"
plutil -insert LSMinimumSystemVersion -string 15.0 "$preview_plist"

cat >"$preview_tools/codesign" <<'MOCK'
#!/bin/sh
set -eu
case "$1" in
  --verify) exit 0 ;;
  -dv)
    printf '%s\n' 'Authority=Developer ID Application: Test Fixture' \
      'CDHash=cccccccccccccccccccccccccccccccccccccccc' >&2 ;;
  *) echo 'unexpected codesign fixture invocation' >&2; exit 1 ;;
esac
MOCK
cat >"$preview_tools/xcrun" <<'MOCK'
#!/bin/sh
set -eu
test "$1" = stapler && test "$2" = validate
MOCK
cat >"$preview_tools/hdiutil" <<'MOCK'
#!/bin/sh
set -eu
case "$1" in
  attach)
    shift
    mount_point=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -mountpoint ]; then shift; mount_point=$1; fi
      shift
    done
    test -n "$mount_point"
    ditto "$AETHERROUTE_TEST_PREVIEW_APP" "$mount_point/AetherRoute.app" ;;
  detach) test -d "$2/AetherRoute.app" ;;
  *) echo 'unexpected hdiutil fixture invocation' >&2; exit 1 ;;
esac
MOCK
chmod 755 "$preview_tools/codesign" "$preview_tools/xcrun" "$preview_tools/hdiutil"
preview_sha=$(shasum -a 256 "$preview_candidate/$preview_stem.dmg" | awk '{print $1}')
preview_bytes=$(stat -f '%z' "$preview_candidate/$preview_stem.dmg")
preview_app_sha=$(shasum -a 256 "$preview_app/Contents/MacOS/com.aetherroute.desktop" | awk '{print $1}')
preview_tun_sha=$(shasum -a 256 "$preview_app/Contents/Library/SystemExtensions/com.aetherroute.desktop.tunnel.systemextension/Contents/MacOS/com.aetherroute.desktop.tunnel" | awk '{print $1}')
preview_tp_sha=$(shasum -a 256 "$preview_app/Contents/Library/SystemExtensions/com.aetherroute.desktop.transparent-proxy.systemextension/Contents/MacOS/com.aetherroute.desktop.transparent-proxy" | awk '{print $1}')
jq -n --arg version "$preview_version" --arg build "$preview_build" \
  --arg sha "$preview_sha" --argjson bytes "$preview_bytes" \
  --arg appSHA "$preview_app_sha" --arg tunSHA "$preview_tun_sha" --arg tpSHA "$preview_tp_sha" '
  {
    schemaVersion: 1, releaseStatus: "notarized-test-candidate",
    product: "AetherRoute", author: "陈艳男 (ChenYanNan)",
    version: $version, build: $build, createdAt: "2026-09-09T01:00:00Z",
    architecture: "arm64", sourceManifestSHA256: ("0" * 64),
    safety: {productionApproved: false, networkActivatedDuringBuild: false,
      systemNetworkState: "unchanged", diagnosticsIncluded: false},
    core: {variant: "normal", diagnosticsIncluded: false,
      protocolReference: {matchesCandidateArtifacts: true}},
    dmg: {sha256: $sha, bytes: $bytes},
    notarization: {status: "Accepted", appTicketStapled: true, dmgTicketStapled: true,
      submissionID: "00000000-0000-0000-0000-000000000000"},
    signing: {
      app: {bundleID: "com.aetherroute.desktop", cdhash: ("c" * 40), executableSHA256: $appSHA},
      packetTunnel: {bundleID: "com.aetherroute.desktop.tunnel", cdhash: ("c" * 40), executableSHA256: $tunSHA},
      transparentProxy: {bundleID: "com.aetherroute.desktop.transparent-proxy", cdhash: ("c" * 40), executableSHA256: $tpSHA}
    }
  }' >"$preview_candidate/$preview_stem.json"
preview_checksums() {
  (cd "$1" && shasum -a 256 "$preview_stem.dmg" "$preview_stem.json" \
    source-manifest.txt README.txt >SHA256SUMS)
}
run_preview() {
  env PATH="$preview_tools:$PATH" AETHERROUTE_TEST_PREVIEW_APP="$preview_app" \
    "$PREVIEW_PREPARER" "$@"
}
preview_checksums "$preview_candidate"
preview_output="$preview_root/output"
run_preview "$preview_candidate" "$site" "$preview_output" >/dev/null
jq -e --arg sha "$preview_sha" --arg artifact "$preview_stem.dmg" '
  .version == "1.0.0" and .build == 2026090901 and
  .distributionMode == "free" and .productionApproved == false and
  .releaseStatus == "notarized-test-candidate" and .channel == "prerelease/build-2026090901" and
  .artifactName == $artifact and .sha256 == $sha and
  .updateHTTPStatus == 404 and .publishedFiles == 5
' "$preview_output/metadata.json" >/dev/null
preview_notes="$preview_output/payload/site/releases/1.0.0-beta-2026090901/index.html"
test -s "$preview_notes"
for page in "$preview_output/payload/site/index.html" \
  "$preview_output/payload/site/releases/index.html" "$preview_notes"; do
  rg -F '1.0.0' "$page" >/dev/null
  rg -F '2026090901' "$page" >/dev/null
done
rg -F "https://downloads.baizhiedu.xin/prerelease/build-2026090901/$preview_stem.dmg" \
  "$preview_output/payload/site/index.html" >/dev/null
rg -F '/releases/1.0.0-beta-2026090901/' \
  "$preview_output/payload/site/index.html" >/dev/null
rg -F "$preview_sha" "$preview_notes" >/dev/null
rg -F 'https://downloads.baizhiedu.xin/prerelease/build-2026090901/SHA256SUMS' \
  "$preview_notes" >/dev/null
if rg -F 'https://downloads.baizhiedu.xin/prerelease/SHA256SUMS' "$preview_notes" >/dev/null; then
  echo "preview notes still use a shared checksum URL" >&2
  exit 1
fi
find "$preview_output/payload/site/releases" -name index.html -type f | while IFS= read -r page; do
  test "$page" != "$preview_notes" || continue
  if rg -F 'https://downloads.baizhiedu.xin/prerelease/' "$page" >/dev/null; then
    echo "historical release still links to a preview download: $page" >&2
    exit 1
  fi
done
test "$(find "$preview_output/payload/downloads/prerelease" -type f | wc -l | tr -d ' ')" -eq 5
(cd "$preview_output/payload/downloads/prerelease/build-2026090901" && shasum -a 256 -c SHA256SUMS >/dev/null)
test -d "$preview_output/payload/updates"
test -z "$(find "$preview_output/payload/updates" -type f -print)"
for label in diagnostics filename-build checksum; do
  folder="$preview_root/$label"
  ditto "$preview_candidate" "$folder"
  case "$label" in
    diagnostics)
      jq '.core.diagnosticsIncluded = true' "$folder/$preview_stem.json" >"$preview_root/changed.json"
      mv "$preview_root/changed.json" "$folder/$preview_stem.json"
      preview_checksums "$folder"
      reason='preview manifest does not describe the exact notarized test candidate' ;;
    filename-build)
      jq '.build = "2026090902"' "$folder/$preview_stem.json" >"$preview_root/changed.json"
      mv "$preview_root/changed.json" "$folder/$preview_stem.json"
      preview_checksums "$folder"
      reason='preview filename differs from its manifest version or build' ;;
    checksum)
      printf 'tampered\n' >>"$folder/README.txt"
      reason='README.txt: FAILED' ;;
  esac
  expect_rejection "preview-$label" "$reason" run_preview "$folder" "$site" "$preview_root/$label-output"
  test ! -e "$preview_root/$label-output"
done
plutil -replace AetherRouteDistributionMode -string licensed "$preview_plist"
expect_rejection preview-nonfree 'public preview app must explicitly use free distribution' \
  run_preview "$preview_candidate" "$site" "$preview_root/nonfree-output"
test ! -e "$preview_root/nonfree-output"
plutil -replace AetherRouteDistributionMode -string free "$preview_plist"
plutil -insert AetherRouteDistributionSigningPublicKey -string fixture-key "$preview_plist"
expect_rejection preview-free-with-signing-key 'free preview must not embed licensing or update-service configuration' \
  run_preview "$preview_candidate" "$site" "$preview_root/free-key-output"
test ! -e "$preview_root/free-key-output"
echo "Preview distribution payload tests passed: dynamic free beta and strict invalid evidence."


python3 -B "$ROOT/scripts/test_distribution_web_deploy_modes.py"
