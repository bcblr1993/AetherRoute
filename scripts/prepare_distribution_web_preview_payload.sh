#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WEB="$ROOT/Services/WebDistribution"
CANDIDATE_DIRECTORY=${1:-}
SITE_SOURCE=${2:-}
OUTPUT=${3:-}

usage() {
  echo "usage: $0 /absolute/notarized-preview-directory /absolute/site-source /absolute/new-output-directory" >&2
}

for path in "$CANDIDATE_DIRECTORY" "$SITE_SOURCE" "$OUTPUT"; do
  case "$path" in /*) ;; *) usage; exit 64 ;; esac
done
for directory in "$CANDIDATE_DIRECTORY" "$SITE_SOURCE"; do
  test -d "$directory" && test ! -L "$directory" || {
    echo "preview input directory is missing or a symlink: $directory" >&2
    exit 1
  }
  if find "$directory" -type l -print -quit | grep -q .; then
    echo "preview input must not contain symbolic links: $directory" >&2
    exit 1
  fi
done
test ! -e "$OUTPUT" || {
  echo "refusing to overwrite preview distribution payload: $OUTPUT" >&2
  exit 1
}
output_parent=$(dirname "$OUTPUT")
test -d "$output_parent" && test ! -L "$output_parent" || {
  echo "preview distribution output parent is missing or a symlink" >&2
  exit 1
}
for command in codesign ditto hdiutil jq plutil shasum stat xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "preview distribution preparation requires $command" >&2
    exit 1
  }
done

set -- "$CANDIDATE_DIRECTORY"/*.dmg
test "$#" -eq 1 && test -f "$1" || {
  echo "preview candidate must contain exactly one DMG" >&2
  exit 1
}
DMG=$1
artifact_name=$(basename "$DMG")
printf '%s\n' "$artifact_name" \
  | grep -Eq '^AetherRoute-[0-9]+\.[0-9]+(\.[0-9]+)?-build-[1-9][0-9]*-arm64-Notarized-Test-Normal-Core\.dmg$' || {
    echo "public previews require a normal-core notarized test candidate filename" >&2
    exit 1
  }
manifest_name=${artifact_name%.dmg}.json
MANIFEST="$CANDIDATE_DIRECTORY/$manifest_name"
SOURCE_MANIFEST="$CANDIDATE_DIRECTORY/source-manifest.txt"
README="$CANDIDATE_DIRECTORY/README.txt"
SUMS="$CANDIDATE_DIRECTORY/SHA256SUMS"
for file in "$DMG" "$MANIFEST" "$SOURCE_MANIFEST" "$README" "$SUMS"; do
  test -f "$file" && test ! -L "$file" || {
    echo "preview candidate is incomplete or contains a symlink: $file" >&2
    exit 1
  }
done
candidate_file_count=$(find "$CANDIDATE_DIRECTORY" -type f | wc -l | tr -d ' ')
test "$candidate_file_count" -eq 5 || {
  echo "preview candidate must contain exactly five audited files" >&2
  exit 1
}
sum_names=$(sed -n 's/^[0-9a-f]\{64\}  //p' "$SUMS" | LC_ALL=C sort)
expected_names=$(printf '%s\n' "$artifact_name" "$manifest_name" source-manifest.txt README.txt | LC_ALL=C sort)
test "$(wc -l <"$SUMS" | tr -d ' ')" -eq 4 && test "$sum_names" = "$expected_names" || {
  echo "preview checksums must name exactly the four published audit files" >&2
  exit 1
}
(cd "$CANDIDATE_DIRECTORY" && shasum -a 256 -c SHA256SUMS)

actual_sha=$(shasum -a 256 "$DMG" | awk '{print $1}')
actual_bytes=$(stat -f '%z' "$DMG")
jq -e \
  --arg sha "$actual_sha" \
  --argjson bytes "$actual_bytes" '
    .schemaVersion == 1 and
    .releaseStatus == "notarized-test-candidate" and
    .product == "AetherRoute" and
    .author == "陈艳男 (ChenYanNan)" and
    (.version | type == "string" and test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
    (.build | type == "string" and test("^[1-9][0-9]*$")) and
    (.createdAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    .architecture == "arm64" and
    .safety.productionApproved == false and
    .safety.networkActivatedDuringBuild == false and
    .safety.systemNetworkState == "unchanged" and
    .safety.diagnosticsIncluded == false and
    .core.variant == "normal" and
    .core.diagnosticsIncluded == false and
    .core.protocolReference.matchesCandidateArtifacts == true and
    .dmg.sha256 == $sha and
    .dmg.bytes == $bytes and
    .notarization.status == "Accepted" and
    .notarization.appTicketStapled == true and
    .notarization.dmgTicketStapled == true and
    (.notarization.submissionID | test("^[0-9a-f-]{36}$")) and
    (.sourceManifestSHA256 | test("^[0-9a-f]{64}$"))
  ' "$MANIFEST" >/dev/null || {
  echo "preview manifest does not describe the exact notarized test candidate" >&2
  exit 1
}
version=$(jq -r '.version' "$MANIFEST")
build=$(jq -r '.build' "$MANIFEST")
release_date=$(jq -r '.createdAt | split("T")[0]' "$MANIFEST")
test "$artifact_name" = "AetherRoute-$version-build-$build-arm64-Notarized-Test-Normal-Core.dmg" || {
  echo "preview filename differs from its manifest version or build" >&2
  exit 1
}
source_manifest_sha=$(awk '$1 == "MANIFEST_SHA256" {print $2}' \
  "$SOURCE_MANIFEST")
test "$source_manifest_sha" = \
  "$(jq -r '.sourceManifestSHA256' "$MANIFEST")" || {
  echo "preview source manifest does not match the candidate manifest" >&2
  exit 1
}

for required in index.html releases/index.html assets/site.css assets/site.js sitemap.xml; do
  test -s "$SITE_SOURCE/$required" || {
    echo "preview site source is missing: $required" >&2
    exit 1
  }
done
test -s "$WEB/templates/preview-release.html" || {
  echo "preview release template is missing" >&2
  exit 1
}

temporary=$(mktemp -d "$output_parent/.aetherroute-web-preview.XXXXXX")
mounted=0
mount_point="$temporary/mount"
cleanup() {
  if [ "$mounted" -eq 1 ]; then
    hdiutil detach "$mount_point" -quiet 2>/dev/null || true
  fi
  test ! -d "$temporary" || find "$temporary" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

# A supplied manifest and checksum are not proof of notarization or free mode.
# Inspect the exact signed app without launching it or enabling an extension.
codesign --verify --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
mkdir "$mount_point"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$mount_point" -quiet
mounted=1
app="$mount_point/AetherRoute.app"
codesign --verify --deep --strict --verbose=2 "$app"
xcrun stapler validate "$app"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = "$version"
test "$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" = "$build"
test "$(plutil -extract AetherRouteDistributionMode raw -o - "$app/Contents/Info.plist")" = free || {
  echo "public preview app must explicitly use free distribution" >&2
  exit 1
}
for key in AetherRouteLicenseServiceURL AetherRouteUpdateManifestURL AetherRouteDistributionSigningPublicKey; do
  test -z "$(plutil -extract "$key" raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)" || {
    echo "free preview must not embed licensing or update-service configuration" >&2
    exit 1
  }
done
minimum_system_version=$(plutil -extract LSMinimumSystemVersion raw -o - "$app/Contents/Info.plist")
printf '%s\n' "$minimum_system_version" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'
for role in app packetTunnel transparentProxy; do
  bundle_id=$(jq -er --arg role "$role" '.signing[$role].bundleID' "$MANIFEST")
  printf '%s\n' "$bundle_id" | grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
  if [ "$role" = app ]; then bundle="$app"; else bundle="$app/Contents/Library/SystemExtensions/$bundle_id.systemextension"; fi
  test "$(plutil -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist")" = "$bundle_id"
  test "$(plutil -extract CFBundleVersion raw -o - "$bundle/Contents/Info.plist")" = "$build"
  signature=$(codesign -dv --verbose=4 "$bundle" 2>&1)
  printf '%s\n' "$signature" | grep -F 'Authority=Developer ID Application' >/dev/null
  cdhash=$(printf '%s\n' "$signature" | awk -F= '$1 == "CDHash" {print $2}')
  test "$cdhash" = "$(jq -r --arg role "$role" '.signing[$role].cdhash' "$MANIFEST")"
  executable=$(plutil -extract CFBundleExecutable raw -o - "$bundle/Contents/Info.plist")
  case "$executable" in ''|*/*|.|..) echo 'invalid bundle executable name' >&2; exit 1 ;; esac
  test "$(shasum -a 256 "$bundle/Contents/MacOS/$executable" | awk '{print $1}')" = \
    "$(jq -r --arg role "$role" '.signing[$role].executableSHA256' "$MANIFEST")"
done
hdiutil detach "$mount_point" -quiet
mounted=0

stage="$temporary/stage"
channel="prerelease/build-$build"
mkdir -p "$stage/payload/site" "$stage/payload/downloads/$channel" \
  "$stage/payload/updates"
ditto "$SITE_SOURCE" "$stage/payload/site"
cp "$WEB/nginx.conf" "$stage/payload/nginx.conf"
cp "$WEB/docker-stack.yml" "$stage/docker-stack.yml"
for file in "$DMG" "$MANIFEST" "$SOURCE_MANIFEST" "$README" "$SUMS"; do
  cp "$file" "$stage/payload/downloads/$channel/$(basename "$file")"
done

replace_block() {
  input=$1; begin=$2; end=$3; replacement=$4; output=$5
  test "$(grep -Fc "$begin" "$input" || true)" -eq 1 &&
    test "$(grep -Fc "$end" "$input" || true)" -eq 1 || {
    echo "preview site source contains an invalid release marker: $input" >&2
    exit 1
  }
  awk -v begin="$begin" -v end="$end" -v replacement="$replacement" '
    index($0, begin) { print; while ((getline line < replacement) > 0) print line; skip=1; next }
    index($0, end) { skip=0; print; next }
    !skip { print }
  ' "$input" >"$output"
}

download_url="https://downloads.baizhiedu.xin/$channel/$artifact_name"
notes_path="/releases/$version-beta-$build/"
dmg_size=$(LC_ALL=C awk -v bytes="$actual_bytes" 'BEGIN { printf "%.1f MB", bytes / 1000000 }')
cat >"$temporary/home-hero.html" <<EOF
        <span class="eyebrow"><span data-lang="zh">免费 Beta 测试版 · 已通过 Apple 公证</span><span data-lang="en">Free beta · Apple notarized</span></span>
        <h1><span data-lang="zh">导入订阅，<br><span class="gradient-text">轻松连接。</span></span><span data-lang="en">Bring your subscription.<br><span class="gradient-text">Connect with ease.</span></span></h1>
        <p class="lead"><span data-lang="zh">为 Apple 芯片 Mac 打造的原生网络客户端。自行导入订阅、节点或配置，即可开始使用；核心功能免费，无需注册或付费激活。</span><span data-lang="en">A native network client for Apple-silicon Macs. Import your own subscription, nodes, or configuration to get started. Core features are free, with no account or paid activation.</span></p>
        <div class="hero-actions">
          <a class="button primary" href="$download_url"><span data-lang="zh">下载 $version Beta</span><span data-lang="en">Download $version Beta</span> <span aria-hidden="true">↓</span></a>
          <a class="button" href="$notes_path"><span data-lang="zh">版本说明与安装指南</span><span data-lang="en">Release notes and setup</span></a>
        </div>
        <p class="meta-line"><span data-lang="zh">Apple 芯片 · macOS $minimum_system_version+ · $dmg_size · Build $build</span><span data-lang="en">Apple silicon · macOS $minimum_system_version+ · $dmg_size · Build $build</span></p>
EOF
replace_block "$stage/payload/site/index.html" \
  AETHERROUTE_RELEASE_HERO_BEGIN AETHERROUTE_RELEASE_HERO_END \
  "$temporary/home-hero.html" "$temporary/index-hero.html"
cat >"$temporary/release-panel.html" <<EOF
    <section class="section"><div class="shell release-panel">
      <div><span class="status-pill">Beta · $release_date</span><h2>AetherRoute $version</h2><p><span data-lang="zh">免费测试版，提供签名、公证安装包。仍在收集实际使用反馈，完整稳定性验证尚未完成。</span><span data-lang="en">A free beta with a signed, notarized installer. Real-world feedback and full stability validation are still in progress.</span></p></div>
      <a class="button" href="$notes_path"><span data-lang="zh">完整说明</span><span data-lang="en">Full notes</span> →</a>
    </div></section>
EOF
replace_block "$temporary/index-hero.html" \
  AETHERROUTE_RELEASE_PANEL_BEGIN AETHERROUTE_RELEASE_PANEL_END \
  "$temporary/release-panel.html" "$stage/payload/site/index.html"
cat >"$temporary/preview-card.html" <<EOF
<section class="card"><span class="status-pill"><span data-lang="zh">当前免费 Beta 测试版</span><span data-lang="en">Current free beta</span></span><h2>AetherRoute $version Beta</h2><p>Build $build · $release_date · Apple silicon · macOS $minimum_system_version+</p><p><span data-lang="zh">Developer ID 签名与 Apple 公证，无需账号或付费激活。完整稳定性验证尚未完成。</span><span data-lang="en">Developer ID signed and Apple notarized. No account or paid activation. Full stability validation is still in progress.</span></p><p><a class="button" href="$notes_path"><span data-lang="zh">查看详情</span><span data-lang="en">View details</span></a></p></section>
EOF
replace_block "$stage/payload/site/releases/index.html" \
  AETHERROUTE_PREVIEW_RELEASE_BEGIN AETHERROUTE_PREVIEW_RELEASE_END \
  "$temporary/preview-card.html" "$temporary/releases-index.html"
mv "$temporary/releases-index.html" "$stage/payload/site/releases/index.html"

mkdir -p "$stage/payload/site$notes_path"
awk -v version="$version" -v build="$build" -v date="$release_date" \
  -v minimum="$minimum_system_version" -v dmgURL="$download_url" \
  -v sumsURL="https://downloads.baizhiedu.xin/$channel/SHA256SUMS" \
  -v artifact="$artifact_name" -v sha="$actual_sha" '
  {
    gsub(/@@VERSION@@/, version); gsub(/@@BUILD@@/, build)
    gsub(/@@RELEASE_DATE@@/, date); gsub(/@@MINIMUM_SYSTEM_VERSION@@/, minimum)
    gsub(/@@DMG_URL@@/, dmgURL); gsub(/@@ARTIFACT_NAME@@/, artifact)
    gsub(/@@SHA256SUMS_URL@@/, sumsURL); gsub(/@@DMG_SHA256@@/, sha); print
  }
' "$WEB/templates/preview-release.html" >"$stage/payload/site${notes_path}index.html"
awk -v path="$notes_path" '
  /<\/urlset>/ { print "  <url><loc>https://aetherroute.baizhiedu.xin" path "</loc></url>" }
  { print }
' "$SITE_SOURCE/sitemap.xml" >"$stage/payload/site/sitemap.xml"
# The preview root publishes only this candidate. Keep historical notes, but do
# not expose their old DMG or the shared checksum URL as current downloads.
find "$stage/payload/site/releases" -name index.html -type f | while IFS= read -r page; do
  test "$page" != "$stage/payload/site${notes_path}index.html" || continue
  awk '
    /https:\/\/downloads.baizhiedu.xin\/prerelease\// {
      gsub(/<div class="hero-actions">.*<\/div><\/div>/,
        "<p><a href=\"/releases/\"><span data-lang=\"zh\">历史版本记录；下载当前 Beta 请查看版本列表。</span><span data-lang=\"en\">Historical release. Visit Releases for the current beta download.</span></a></p></div>")
    }
    { print }
  ' "$page" >"$temporary/history.html"
  mv "$temporary/history.html" "$page"
done
if grep -ER '@@[A-Z0-9_]+@@' "$stage/payload/site" >/dev/null; then
  echo "preview website contains an unresolved release placeholder" >&2
  exit 1
fi
jq -n \
  --arg version "$version" \
  --argjson build "$build" \
  --arg artifactName "$artifact_name" \
  --arg releaseNotesPath "$notes_path" \
  --arg channel "$channel" \
  --arg sha256 "$actual_sha" \
  '{schemaVersion: 1, releaseStatus: "notarized-test-candidate",
    version: $version, build: $build, productionApproved: false,
    distributionMode: "free", updateEndpointPresent: false,
    releaseNotesPath: $releaseNotesPath,
    artifactName: $artifactName, channel: $channel, sha256: $sha256,
    updateHTTPStatus: 404, publishedFiles: 5}' >"$stage/metadata.json"
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
mv "$stage" "$OUTPUT"

echo "Preview distribution payload prepared: $OUTPUT"
echo "DMG SHA-256: $actual_sha"
