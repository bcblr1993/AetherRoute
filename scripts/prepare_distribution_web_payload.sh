#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WEB="$ROOT/Services/WebDistribution"
DMG=${1:-}
CANDIDATE_MANIFEST=${2:-}
PRODUCTION_MANIFEST=${3:-}
UPDATE_ENVELOPE=${4:-}
SITE_SOURCE=${5:-}
OUTPUT=${6:-}

usage() {
  echo "usage: $0 /absolute/AetherRoute-version-arm64.dmg /absolute/AetherRoute-version-arm64.candidate.json /absolute/AetherRoute-version-arm64.production.json /absolute/current.update.json /absolute/site-source /absolute/new-output-directory" >&2
}

for path in "$DMG" "$CANDIDATE_MANIFEST" "$PRODUCTION_MANIFEST" \
  "$UPDATE_ENVELOPE" "$SITE_SOURCE" "$OUTPUT"
do
  case "$path" in /*) ;; *) usage; exit 64 ;; esac
done
for file in "$DMG" "$CANDIDATE_MANIFEST" "$PRODUCTION_MANIFEST" \
  "$UPDATE_ENVELOPE"
do
  test -f "$file" && test ! -L "$file" || {
    echo "stable distribution input is missing or a symlink: $file" >&2
    exit 1
  }
done
test -d "$SITE_SOURCE" && test ! -L "$SITE_SOURCE" || {
  echo "site source is missing or a symlink" >&2
  exit 1
}
if find "$SITE_SOURCE" -type l -print -quit | grep -q .; then
  echo "site source must not contain symbolic links" >&2
  exit 1
fi
test ! -e "$OUTPUT" || {
  echo "refusing to overwrite distribution payload: $OUTPUT" >&2
  exit 1
}
output_parent=$(dirname "$OUTPUT")
test -d "$output_parent" && test ! -L "$output_parent" || {
  echo "distribution output parent is missing or a symlink" >&2
  exit 1
}
for command in awk base64 cmp ditto git head jq shasum sort stat xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "stable distribution preparation requires $command" >&2
    exit 1
  }
done

public_key_base64=${AETHERROUTE_DISTRIBUTION_PUBLIC_KEY:-}
test -n "$public_key_base64" || {
  echo "stable distribution preparation requires AETHERROUTE_DISTRIBUTION_PUBLIC_KEY" >&2
  exit 64
}

jq -e '
  .schemaVersion == 1 and
  .releaseStatus == "production-approved" and
  .product == "AetherRoute" and
  .productID == "com.aetherroute.desktop" and
  (.version | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
  (.build | type == "number" and . > 0 and floor == .) and
  (.releasedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  (.minimumSystemVersion | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
  .architecture == "arm64" and
  (.source.gitCommit | test("^[0-9a-f]{40}$")) and
  (.source.manifestSHA256 | test("^[0-9a-f]{64}$")) and
  (.distribution.updateSigningPublicKeySHA256 | test("^[0-9a-f]{64}$")) and
  (.dmg.sha256 | test("^[0-9a-f]{64}$")) and
  (.dmg.bytes | type == "number" and . > 0 and floor == .) and
  .notarization.status == "Accepted" and
  .stability.schema == 2 and
  .signedRuntime.schema == 1 and
  .signedRuntime.engines == ["tun", "transparent"] and
  .promotion.schema == 1 and
  (.promotion.approvedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  (.promotion.candidateManifestSHA256 | test("^[0-9a-f]{64}$")) and
  (.promotion.postInstallEvidenceSHA256 | test("^[0-9a-f]{64}$")) and
  (.promotion.exactDMGSHA256 | test("^[0-9a-f]{64}$"))
' "$PRODUCTION_MANIFEST" >/dev/null || {
  echo "production manifest is incomplete or not approved" >&2
  exit 1
}

version=$(jq -r '.version' "$PRODUCTION_MANIFEST")
build=$(jq -r '.build' "$PRODUCTION_MANIFEST")
product_id=$(jq -r '.productID' "$PRODUCTION_MANIFEST")
released_at=$(jq -r '.releasedAt' "$PRODUCTION_MANIFEST")
approved_at=$(jq -r '.promotion.approvedAt' "$PRODUCTION_MANIFEST")
minimum_system_version=$(jq -r '.minimumSystemVersion' "$PRODUCTION_MANIFEST")
expected_dmg_sha=$(jq -r '.dmg.sha256' "$PRODUCTION_MANIFEST")
expected_dmg_bytes=$(jq -r '.dmg.bytes' "$PRODUCTION_MANIFEST")
first_timestamp=$(printf '%s\n%s\n' "$released_at" "$approved_at" \
  | LC_ALL=C sort | head -1)
test "$first_timestamp" = "$released_at" || {
  echo "production approval predates the notarized candidate" >&2
  exit 1
}
artifact_name="AetherRoute-$version-arm64.dmg"
candidate_name="AetherRoute-$version-arm64.candidate.json"
production_name="AetherRoute-$version-arm64.production.json"
test "$(basename "$DMG")" = "$artifact_name" || {
  echo "stable DMG filename does not match its production manifest" >&2
  exit 1
}
test "$(basename "$CANDIDATE_MANIFEST")" = "$candidate_name" || {
  echo "candidate manifest filename does not match the stable version" >&2
  exit 1
}
test "$(basename "$PRODUCTION_MANIFEST")" = "$production_name" || {
  echo "production manifest filename does not match the stable version" >&2
  exit 1
}

temporary=$(mktemp -d "$output_parent/.aetherroute-web-payload.XXXXXX")
cleanup() {
  test ! -d "$temporary" || find "$temporary" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

jq -S . "$CANDIDATE_MANIFEST" >"$temporary/candidate.canonical.json"
jq -S 'del(.promotion) | .releaseStatus = "notarized-candidate"' \
  "$PRODUCTION_MANIFEST" >"$temporary/production-as-candidate.json"
cmp -s "$temporary/candidate.canonical.json" \
  "$temporary/production-as-candidate.json" || {
  echo "production manifest does not preserve the exact candidate manifest" >&2
  exit 1
}
candidate_sha=$(shasum -a 256 "$CANDIDATE_MANIFEST" | awk '{print $1}')
test "$candidate_sha" = \
  "$(jq -r '.promotion.candidateManifestSHA256' "$PRODUCTION_MANIFEST")" || {
  echo "production manifest does not bind the supplied candidate manifest" >&2
  exit 1
}

actual_dmg_sha=$(shasum -a 256 "$DMG" | awk '{print $1}')
actual_dmg_bytes=$(stat -f '%z' "$DMG")
test "$actual_dmg_sha" = "$expected_dmg_sha" && \
  test "$actual_dmg_sha" = \
    "$(jq -r '.promotion.exactDMGSHA256' "$PRODUCTION_MANIFEST")" || {
  echo "stable DMG SHA-256 does not match production approval" >&2
  exit 1
}
test "$actual_dmg_bytes" = "$expected_dmg_bytes" || {
  echo "stable DMG byte count does not match production approval" >&2
  exit 1
}

current_git_commit=$(git -C "$ROOT" rev-parse HEAD)
test "$current_git_commit" = \
  "$(jq -r '.source.gitCommit' "$PRODUCTION_MANIFEST")" || {
  echo "stable artifact was not produced from the current Git commit" >&2
  exit 1
}
current_source_manifest=$("$ROOT/scripts/source_manifest.sh" \
  | awk '$1 == "MANIFEST_SHA256" {print $2}')
test "$current_source_manifest" = \
  "$(jq -r '.source.manifestSHA256' "$PRODUCTION_MANIFEST")" || {
  echo "stable artifact was not produced from the current source manifest" >&2
  exit 1
}

public_key="$temporary/public-key.raw"
printf '%s' "$public_key_base64" | base64 -D >"$public_key" 2>/dev/null || {
  echo "AETHERROUTE_DISTRIBUTION_PUBLIC_KEY is not valid base64" >&2
  exit 64
}
test "$(stat -f '%z' "$public_key")" -eq 32 || {
  echo "AETHERROUTE_DISTRIBUTION_PUBLIC_KEY must contain 32 raw bytes" >&2
  exit 64
}
public_key_sha=$(shasum -a 256 "$public_key" | awk '{print $1}')
test "$public_key_sha" = \
  "$(jq -r '.distribution.updateSigningPublicKeySHA256' "$PRODUCTION_MANIFEST")" || {
  echo "update verification key differs from the key embedded in the stable build" >&2
  exit 1
}
verified_update="$temporary/verified-update.json"
xcrun swift "$ROOT/scripts/distribution_envelope_tool.swift" verify \
  "$public_key" "$UPDATE_ENVELOPE" "$verified_update" >/dev/null

download_url="https://downloads.baizhiedu.xin/releases/$version/$artifact_name"
release_notes_url="https://aetherroute.baizhiedu.xin/releases/$version/"
jq -e \
  --arg productID "$product_id" \
  --arg version "$version" \
  --argjson build "$build" \
  --arg publishedAt "$approved_at" \
  --arg minimumSystemVersion "$minimum_system_version" \
  --arg downloadURL "$download_url" \
  --arg sha256 "$expected_dmg_sha" \
  --arg releaseNotesURL "$release_notes_url" '
    .schemaVersion == 1 and
    .productID == $productID and
    .version == $version and
    .build == $build and
    .publishedAt == $publishedAt and
    .minimumSystemVersion == $minimumSystemVersion and
    .architecture == "arm64" and
    .downloadURL == $downloadURL and
    .sha256 == $sha256 and
    .releaseNotesURL == $releaseNotesURL
  ' "$verified_update" >/dev/null || {
  echo "signed update envelope does not describe the exact stable release" >&2
  exit 1
}

for required in index.html releases/index.html assets/site.css assets/site.js; do
  test -s "$SITE_SOURCE/$required" || {
    echo "stable site source is missing: $required" >&2
    exit 1
  }
done
template="$WEB/templates/stable-release.html"
test -s "$template" || {
  echo "stable release-page template is missing" >&2
  exit 1
}

stage="$temporary/stage"
payload="$stage/payload"
mkdir -p "$payload/site" "$payload/downloads/releases/$version" \
  "$payload/updates"
ditto "$SITE_SOURCE" "$payload/site"
cp "$WEB/nginx.conf" "$payload/nginx.conf"
cp "$WEB/docker-stack.yml" "$stage/docker-stack.yml"
cp "$DMG" "$payload/downloads/releases/$version/$artifact_name"
cp "$CANDIDATE_MANIFEST" \
  "$payload/downloads/releases/$version/$candidate_name"
cp "$PRODUCTION_MANIFEST" \
  "$payload/downloads/releases/$version/$production_name"
cp "$UPDATE_ENVELOPE" "$payload/updates/current.update.json"
(
  cd "$payload/downloads/releases/$version"
  shasum -a 256 "$artifact_name" "$candidate_name" "$production_name" \
    >SHA256SUMS
)

replace_block() {
  input=$1
  begin=$2
  end=$3
  replacement=$4
  output=$5
  begin_count=$(grep -Fc "$begin" "$input" || true)
  end_count=$(grep -Fc "$end" "$input" || true)
  test "$begin_count" -eq 1 && test "$end_count" -eq 1 || {
    echo "stable site source contains an invalid release marker: $input" >&2
    exit 1
  }
  awk -v begin="$begin" -v end="$end" -v replacement="$replacement" '
    index($0, begin) { print; while ((getline line < replacement) > 0) print line; skip=1; next }
    index($0, end) { skip=0; print; next }
    !skip { print }
  ' "$input" >"$output"
}

dmg_size=$(LC_ALL=C awk -v bytes="$expected_dmg_bytes" \
  'BEGIN { printf "%.1f MB", bytes / 1000000 }')
cat >"$temporary/home-hero.html" <<EOF
        <span class="eyebrow"><span data-lang="zh">生产稳定版 · 已通过 Apple 公证</span><span data-lang="en">Production stable · Apple notarized</span></span>
        <h1><span data-lang="zh">路由，自然<br><span class="gradient-text">融入 macOS。</span></span><span data-lang="en">Routing that feels<br><span class="gradient-text">native to macOS.</span></span></h1>
        <p class="lead"><span data-lang="zh">原生 Swift、透明代理与 TUN，以及面向现代协议的高性能数据平面。简洁、私密，并且始终由你掌控。</span><span data-lang="en">Native Swift, Transparent Proxy and TUN, backed by a high-performance data plane for modern protocols. Private, focused, and always under your control.</span></p>
        <div class="hero-actions">
          <a class="button primary" href="$download_url"><span data-lang="zh">下载 AetherRoute $version</span><span data-lang="en">Download AetherRoute $version</span> <span aria-hidden="true">↓</span></a>
          <a class="button" href="/releases/$version/"><span data-lang="zh">查看版本说明</span><span data-lang="en">Release notes</span></a>
        </div>
        <p class="meta-line"><span data-lang="zh">仅支持 Apple 芯片 · macOS $minimum_system_version 或更高版本 · $dmg_size</span><span data-lang="en">Apple silicon only · macOS $minimum_system_version or later · $dmg_size</span></p>
EOF
replace_block "$payload/site/index.html" \
  'AETHERROUTE_RELEASE_HERO_BEGIN' 'AETHERROUTE_RELEASE_HERO_END' \
  "$temporary/home-hero.html" "$temporary/index-hero.html"

cat >"$temporary/screenshot-version.html" <<EOF
<span data-lang="zh">AetherRoute $version 稳定版真实界面</span><span data-lang="en">Real interface from AetherRoute $version stable</span>
EOF
replace_block "$temporary/index-hero.html" \
  'AETHERROUTE_SCREENSHOT_VERSION_BEGIN' \
  'AETHERROUTE_SCREENSHOT_VERSION_END' \
  "$temporary/screenshot-version.html" "$temporary/index-screenshot.html"

release_date=${released_at%%T*}
cat >"$temporary/release-panel.html" <<EOF
    <section class="section">
      <div class="shell release-panel">
        <div><span class="status-pill"><span data-lang="zh">稳定版 · $release_date</span><span data-lang="en">Stable · $release_date</span></span><h2>AetherRoute $version</h2><p><span data-lang="zh">已通过生产双引擎、泄漏与恢复、安装升级回滚、性能、UI 和长时间稳定性门禁。</span><span data-lang="en">Passed production dual-engine, leak and recovery, install/upgrade/rollback, performance, UI, and long-duration stability gates.</span></p></div>
        <a class="button" href="/releases/$version/"><span data-lang="zh">完整说明</span><span data-lang="en">Full notes</span> <span aria-hidden="true">→</span></a>
      </div>
    </section>
EOF
replace_block "$temporary/index-screenshot.html" \
  'AETHERROUTE_RELEASE_PANEL_BEGIN' 'AETHERROUTE_RELEASE_PANEL_END' \
  "$temporary/release-panel.html" "$payload/site/index.html.next"
mv "$payload/site/index.html.next" "$payload/site/index.html"

cat >"$temporary/releases-card.html" <<EOF
<section><h2><span data-lang="zh">稳定版本</span><span data-lang="en">Stable releases</span></h2><div class="card"><span class="status-pill"><span data-lang="zh">当前稳定版</span><span data-lang="en">Current stable</span></span><h2>AetherRoute $version</h2><p>Build $build · $release_date · Apple silicon · macOS $minimum_system_version+</p><p><span data-lang="zh">Developer ID 签名、Apple 公证并完成生产验证的首个稳定版本。</span><span data-lang="en">The first production-verified stable release, signed with Developer ID and notarized by Apple.</span></p><p><a class="button" href="/releases/$version/"><span data-lang="zh">查看详情</span><span data-lang="en">View details</span></a></p></div></section>
EOF
replace_block "$payload/site/releases/index.html" \
  'AETHERROUTE_STABLE_RELEASE_BEGIN' 'AETHERROUTE_STABLE_RELEASE_END' \
  "$temporary/releases-card.html" "$payload/site/releases/index.html.next"
mv "$payload/site/releases/index.html.next" "$payload/site/releases/index.html"

mkdir -p "$payload/site/releases/$version"
awk \
  -v version="$version" \
  -v build="$build" \
  -v date="$release_date" \
  -v minimum="$minimum_system_version" \
  -v dmgURL="$download_url" \
  -v sumsURL="https://downloads.baizhiedu.xin/releases/$version/SHA256SUMS" \
  -v sha="$expected_dmg_sha" '
  {
    gsub(/@@VERSION@@/, version)
    gsub(/@@BUILD@@/, build)
    gsub(/@@RELEASE_DATE@@/, date)
    gsub(/@@MINIMUM_SYSTEM_VERSION@@/, minimum)
    gsub(/@@DMG_URL@@/, dmgURL)
    gsub(/@@SHA256SUMS_URL@@/, sumsURL)
    gsub(/@@DMG_SHA256@@/, sha)
    print
  }
' "$template" >"$payload/site/releases/$version/index.html"
if grep -ER '@@[A-Z0-9_]+@@' "$payload/site" >/dev/null; then
  echo "stable website contains an unresolved release placeholder" >&2
  exit 1
fi

jq -n \
  --arg releaseID "stable-$version-build-$build" \
  --arg version "$version" \
  --argjson build "$build" \
  --arg artifactName "$artifact_name" \
  --arg channel "releases/$version" \
  --arg sha256 "$expected_dmg_sha" \
  '{schemaVersion: 1, releaseID: $releaseID, version: $version,
    build: $build, artifactName: $artifactName, channel: $channel,
    sha256: $sha256, updateHTTPStatus: 200}' >"$stage/metadata.json"
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
mv "$stage" "$OUTPUT"

echo "Stable distribution payload prepared: $OUTPUT"
echo "Release: AetherRoute $version ($build)"
echo "DMG SHA-256: $expected_dmg_sha"

