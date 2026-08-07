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

echo "Stable distribution payload tests passed."
