#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PAYLOAD_NAME=AetherRouteSignedNERunner
UI_TARGET=AetherRouteUITests
INSTALLED_APP=/Applications/AetherRoute.app

fail() {
  echo "signed prebuilt runner failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  signed_ne_prebuilt_runner.sh package SIGNING_JSON PRODUCTS_DIR CANDIDATE_JSON CANDIDATE_SOURCE_MANIFEST OUTPUT_ZIP
  signed_ne_prebuilt_runner.sh prepare ZIP ZIP_SHA256 SIGNING_JSON CANDIDATE_JSON CANDIDATE_SOURCE_MANIFEST EXPECTED_APP_CDHASH DESTINATION ENGINE --
  signed_ne_prebuilt_runner.sh run EFFECTIVE_XCTESTRUN EFFECTIVE_SHA256 SIGNING_JSON ENGINE RESULT_BUNDLE --

prepare selects public-https by default; controlled-relay-v1 requires an explicit
AETHERROUTE_SIGNED_PROBE_KIND and pinned private cycle bindings. Mixed modes are
rejected. Controlled dispatch does not add Tart transport or a recovery lease.
prepare reads the same credential-free AETHERROUTE_SIGNED_* values used by
test_signed_network_extension.sh and writes a verified effective_xctestrun path
plus artifact hashes to stdout. run surrounds the exact command below with the
same Tailscale route/MagicDNS watchdog and scoped AetherRoute TUN stop used by
the source-build gate:
  xcodebuild test-without-building -xctestrun EFFECTIVE_XCTESTRUN ...
EOF
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

code_sign_field() {
  bundle=$1
  field=$2
  codesign -dv --verbose=4 "$bundle" 2>&1 \
    | awk -F= -v field="$field" '$1 == field {print $2; exit}'
}

require_absolute_file() {
  path=$1
  label=$2
  case "$path" in /*) ;; *) fail "$label must be absolute" ;; esac
  test -f "$path" && test ! -L "$path" || fail "$label must be a regular non-symlink file"
}

load_signing_contract() {
  SIGNING_CONFIG=$1
  require_absolute_file "$SIGNING_CONFIG" "signing configuration"
  jq -e '
    .schemaVersion == 2 and
    (.teamID | test("^[A-Z0-9]{10}$")) and
    ([.profiles[].role] | sort) ==
      (["direct-host", "packet-tunnel", "transparent-proxy"] | sort) and
    (.profiles | length == 3)
  ' "$SIGNING_CONFIG" >/dev/null || fail "invalid signing configuration"
  EXPECTED_TEAM_ID=$(jq -r '.teamID' "$SIGNING_CONFIG")
  EXPECTED_HOST_BUNDLE=$(jq -r \
    '.profiles[] | select(.role == "direct-host") | .bundleID' \
    "$SIGNING_CONFIG")
  EXPECTED_PACKET_BUNDLE=$(jq -r \
    '.profiles[] | select(.role == "packet-tunnel") | .bundleID' \
    "$SIGNING_CONFIG")
  EXPECTED_TRANSPARENT_BUNDLE=$(jq -r \
    '.profiles[] | select(.role == "transparent-proxy") | .bundleID' \
    "$SIGNING_CONFIG")
  test "$EXPECTED_PACKET_BUNDLE" = "$EXPECTED_HOST_BUNDLE.tunnel" \
    || fail "packet bundle identifier does not match the host"
  test "$EXPECTED_TRANSPARENT_BUNDLE" = "$EXPECTED_HOST_BUNDLE.transparent-proxy" \
    || fail "transparent bundle identifier does not match the host"
}

verify_development_bundle() {
  bundle=$1
  expected_identifier=$2
  expected_cdhash=${3:-}
  codesign --verify --deep --strict "$bundle" >/dev/null 2>&1 \
    || fail "Apple Development bundle signature is invalid: $bundle"
  codesign -dv --verbose=4 "$bundle" 2>&1 \
    | grep -F 'Authority=Apple Development:' >/dev/null \
    || fail "bundle is not Apple Development signed: $bundle"
  actual_team=$(code_sign_field "$bundle" TeamIdentifier)
  actual_identifier=$(code_sign_field "$bundle" Identifier)
  actual_cdhash=$(code_sign_field "$bundle" CDHash | tr '[:upper:]' '[:lower:]')
  test "$actual_team" = "$EXPECTED_TEAM_ID" \
    || fail "Apple Development Team ID mismatch: $bundle"
  test "$actual_identifier" = "$expected_identifier" \
    || fail "Apple Development bundle identifier mismatch: $bundle"
  printf '%s\n' "$actual_cdhash" | grep -Eq '^[0-9a-f]{40}$' \
    || fail "Apple Development CDHash is invalid: $bundle"
  if [ -n "$expected_cdhash" ] && [ "$actual_cdhash" != "$expected_cdhash" ]; then
    fail "Apple Development CDHash changed: $bundle"
  fi
  printf '%s\n' "$actual_cdhash"
}

validate_candidate_manifest() {
  CANDIDATE_MANIFEST=$1
  require_absolute_file "$CANDIDATE_MANIFEST" "candidate manifest"
  jq -e '
    .schemaVersion == 1 and
    .product == "AetherRoute" and
    .architecture == "arm64" and
    (.releaseStatus == "notarized-test-candidate" or
      .releaseStatus == "signed-local-test-candidate") and
    (.sourceManifestSHA256 | test("^[0-9a-f]{64}$")) and
    (.version | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
    (.build | test("^[1-9][0-9]*$"))
  ' "$CANDIDATE_MANIFEST" >/dev/null \
    || fail "invalid candidate manifest"
  CANDIDATE_MANIFEST_SHA256=$(sha256 "$CANDIDATE_MANIFEST")
  CANDIDATE_SOURCE_SHA256=$(jq -r '.sourceManifestSHA256' "$CANDIDATE_MANIFEST")
  CANDIDATE_VERSION=$(jq -r '.version' "$CANDIDATE_MANIFEST")
  CANDIDATE_BUILD=$(jq -r '.build' "$CANDIDATE_MANIFEST")
  CANDIDATE_STATUS=$(jq -r '.releaseStatus' "$CANDIDATE_MANIFEST")
}

validate_candidate_source_manifest() {
  CANDIDATE_SOURCE_MANIFEST=$1
  require_absolute_file "$CANDIDATE_SOURCE_MANIFEST" "candidate source manifest"
  manifest_marker_count=$(grep -c '^MANIFEST_SHA256  ' \
    "$CANDIDATE_SOURCE_MANIFEST" || true)
  test "$manifest_marker_count" -eq 1 \
    || fail "candidate source manifest must contain one final digest"
  declared_manifest_sha=$(awk '
    /^MANIFEST_SHA256  / {value=$2}
    END {print value}
  ' "$CANDIDATE_SOURCE_MANIFEST")
  test "$declared_manifest_sha" = "$CANDIDATE_SOURCE_SHA256" \
    || fail "candidate source manifest digest differs from candidate JSON"
  test "$(tail -n 1 "$CANDIDATE_SOURCE_MANIFEST")" \
    = "MANIFEST_SHA256  $CANDIDATE_SOURCE_SHA256" \
    || fail "candidate source manifest digest is not the final row"
  calculated_manifest_sha=$(sed '$d' "$CANDIDATE_SOURCE_MANIFEST" \
    | shasum -a 256 | awk '{print $1}')
  test "$calculated_manifest_sha" = "$CANDIDATE_SOURCE_SHA256" \
    || fail "candidate source manifest content hash is invalid"
  frozen_ui_sha=$(awk '
    $2 == "Tests/AetherRouteUITests/AetherRouteUITests.swift" {
      matches++
      value=$1
    }
    END {
      if (matches != 1) exit 1
      print value
    }
  ' "$CANDIDATE_SOURCE_MANIFEST") \
    || fail "candidate source manifest does not uniquely bind the UI test"
  current_ui_sha=$(sha256 "$ROOT/Tests/AetherRouteUITests/AetherRouteUITests.swift")
  test "$frozen_ui_sha" = "$current_ui_sha" \
    || fail "current UI test differs from the frozen candidate source"
  # A lifecycle test may depend on additional Swift helpers. Bind the full
  # test-source set, so editing or adding a helper cannot reuse an older frozen
  # candidate merely because its original test entry point is unchanged.
  frozen_ui_sources=$(awk '
    $2 ~ /^Tests\/AetherRouteUITests\// {
      if (NF != 2 || $2 ~ /(^|\/)\.\.(\/|$)/) exit 1
      print
    }
  ' "$CANDIDATE_SOURCE_MANIFEST") || fail "unsafe UI source manifest entry"
  current_ui_sources=$(
    cd "$ROOT" || exit 1
    test -z "$(find Tests/AetherRouteUITests -type l -print)" || exit 1
    find Tests/AetherRouteUITests -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      test ! -L "$file" || exit 1
      printf '%s\n' "$file" | grep -Eq '^Tests/AetherRouteUITests/[A-Za-z0-9_./-]+$' || exit 1
      printf '%s  %s\n' "$(sha256 "$file")" "$file"
    done
  ) || fail "UI source set cannot be read safely"
  test -n "$frozen_ui_sources" && test "$frozen_ui_sources" = "$current_ui_sources" \
    || fail "current UI source set differs from the frozen candidate source"
  CANDIDATE_SOURCE_MANIFEST_FILE_SHA256=$(sha256 "$CANDIDATE_SOURCE_MANIFEST")
}

write_product_manifests() {
  payload=$1
  (
    cd "$payload"
    find Products -type f -print | LC_ALL=C sort | while IFS= read -r path; do
      case "$path" in
        /*|*../*|*/..|*\\*) exit 90 ;;
      esac
      printf '%s  %s\n' "$(sha256 "$path")" "$path"
    done
  ) >"$payload/files.sha256" || fail "unsafe product file path"
  (
    cd "$payload"
    find Products -type l -print | LC_ALL=C sort | while IFS= read -r path; do
      target=$(readlink "$path")
      case "$path:$target" in
        /*|*../*|*/..|*\\*|*:\/*) exit 91 ;;
      esac
      printf '%s\t%s\n' "$path" "$target"
    done
  ) >"$payload/links.txt" || fail "unsafe product symbolic link"
}

package_runner() {
  test "$#" -eq 5 || { usage; exit 64; }
  signing=$1
  products=$2
  candidate=$3
  candidate_source_manifest=$4
  output_zip=$5
  load_signing_contract "$signing"
  validate_candidate_manifest "$candidate"
  validate_candidate_source_manifest "$candidate_source_manifest"
  case "$products" in /*) ;; *) fail "Products directory must be absolute" ;; esac
  test -d "$products" && test ! -L "$products" \
    || fail "Products directory must be a real directory"
  case "$output_zip" in /*) ;; *) fail "output ZIP must be absolute" ;; esac
  test ! -e "$output_zip" || fail "refusing to overwrite output ZIP"
  test -d "$(dirname -- "$output_zip")" || fail "output ZIP parent is missing"

  runner="$products/Debug/AetherRouteUITests-Runner.app"
  test_bundle="$runner/Contents/PlugIns/AetherRouteUITests.xctest"
  test -d "$runner" && test -d "$test_bundle" \
    || fail "Products is missing the UI runner or UI test bundle"
  xctestrun_count=$(find "$products" -mindepth 1 -maxdepth 1 \
    -type f -name '*.xctestrun' | wc -l | tr -d ' ')
  test "$xctestrun_count" -eq 1 || fail "Products must contain exactly one xctestrun"
  xctestrun=$(find "$products" -mindepth 1 -maxdepth 1 \
    -type f -name '*.xctestrun' -print)
  runner_cdhash=$(verify_development_bundle \
    "$runner" "$EXPECTED_HOST_BUNDLE.ui-tests.xctrunner")
  test_cdhash=$(verify_development_bundle \
    "$test_bundle" "$EXPECTED_HOST_BUNDLE.ui-tests")
  plutil -extract "$UI_TARGET.TestHostPath" raw -o - "$xctestrun" \
    | grep -qx '__TESTROOT__/Debug/AetherRouteUITests-Runner.app' \
    || fail "xctestrun has an unexpected UI test host"
  plutil -extract "$UI_TARGET.TestBundlePath" raw -o - "$xctestrun" \
    | grep -qx '__TESTHOST__/Contents/PlugIns/AetherRouteUITests.xctest' \
    || fail "xctestrun has an unexpected UI test bundle"

  work=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-prebuilt-package.XXXXXX")
  cleanup_package() { find "$work" -depth -delete 2>/dev/null || true; }
  trap cleanup_package EXIT HUP INT TERM
  payload="$work/$PAYLOAD_NAME"
  mkdir "$payload"
  ditto "$products" "$payload/Products"
  write_product_manifests "$payload"
  relative_xctestrun="Products/$(basename "$xctestrun")"
  ui_sha=$frozen_ui_sha
  product_file_count=$(find "$payload/Products" -type f | wc -l | tr -d ' ')
  product_link_count=$(find "$payload/Products" -type l | wc -l | tr -d ' ')
  jq -n \
    --arg source "$CANDIDATE_SOURCE_SHA256" \
    --arg candidateSourceManifest "$CANDIDATE_SOURCE_MANIFEST_FILE_SHA256" \
    --arg candidateManifest "$CANDIDATE_MANIFEST_SHA256" \
    --arg candidateStatus "$CANDIDATE_STATUS" \
    --arg candidateVersion "$CANDIDATE_VERSION" \
    --arg candidateBuild "$CANDIDATE_BUILD" \
    --arg ui "$ui_sha" \
    --arg team "$EXPECTED_TEAM_ID" \
    --arg host "$EXPECTED_HOST_BUNDLE" \
    --arg packet "$EXPECTED_PACKET_BUNDLE" \
    --arg transparent "$EXPECTED_TRANSPARENT_BUNDLE" \
    --arg xctestrun "$relative_xctestrun" \
    --arg xctestrunSHA "$(sha256 "$payload/$relative_xctestrun")" \
    --arg runnerCDHash "$runner_cdhash" \
    --arg testCDHash "$test_cdhash" \
    --arg filesSHA "$(sha256 "$payload/files.sha256")" \
    --arg linksSHA "$(sha256 "$payload/links.txt")" \
    --argjson fileCount "$product_file_count" \
    --argjson linkCount "$product_link_count" '
      {schemaVersion: 1,
       product: "AetherRouteSignedNERunner",
       architecture: "arm64",
       sourceManifestSHA256: $source,
       candidateSourceManifestFileSHA256: $candidateSourceManifest,
       candidateManifestSHA256: $candidateManifest,
       candidateStatus: $candidateStatus,
       candidateVersion: $candidateVersion,
       candidateBuild: $candidateBuild,
       uiTestSHA256: $ui,
       teamID: $team,
       hostBundleID: $host,
       packetBundleID: $packet,
       transparentBundleID: $transparent,
       xctestrunPath: $xctestrun,
       xctestrunSHA256: $xctestrunSHA,
       runnerPath: "Products/Debug/AetherRouteUITests-Runner.app",
       runnerCDHash: $runnerCDHash,
       uiTestBundlePath: "Products/Debug/AetherRouteUITests-Runner.app/Contents/PlugIns/AetherRouteUITests.xctest",
       uiTestBundleCDHash: $testCDHash,
       productFilesSHA256: $filesSHA,
       productLinksSHA256: $linksSHA,
       productFileCount: $fileCount,
       productLinkCount: $linkCount}
    ' >"$payload/manifest.json"
  chmod 600 "$payload/manifest.json" "$payload/files.sha256" "$payload/links.txt"
  ditto -c -k --keepParent "$payload" "$output_zip"
  chmod 600 "$output_zip"
  printf 'prebuilt_zip=%s\n' "$output_zip"
  printf 'prebuilt_zip_sha256=%s\n' "$(sha256 "$output_zip")"
  printf 'candidate_source_manifest_sha256=%s\n' "$CANDIDATE_SOURCE_SHA256"
  printf 'ui_test_sha256=%s\n' "$ui_sha"
  trap - EXIT HUP INT TERM
  cleanup_package
}

# These input checks mirror the signed Swift runner's fixed controlled contract.
# They inspect bytes only; prepare never executes a probe or its Python runtime.
probe_private_directory() {
  pd_path=$1
  test -d "$pd_path" && test ! -L "$pd_path" \
    && test "$(CDPATH= cd -- "$pd_path" && pwd -P)" = "$pd_path" \
    && test "$(stat -f '%u:%Lp' "$pd_path")" = "$(id -u):700" \
    || fail "controlled probe directory is not private and physical"
}

probe_regular_file() {
  pf_path=$1 pf_limit=$2 pf_private=$3
  require_absolute_file "$pf_path" "controlled probe input"
  test "$(CDPATH= cd -- "$(dirname -- "$pf_path")" && pwd -P)/$(basename -- "$pf_path")" = "$pf_path" \
    || fail "controlled probe input has a nonphysical parent"
  pf_size=$(stat -f '%z' "$pf_path")
  test "$pf_size" -gt 0 && test "$pf_size" -le "$pf_limit" \
    || fail "controlled probe input size is invalid"
  pf_owner=$(stat -f '%u' "$pf_path") pf_mode=$(stat -f '%Lp' "$pf_path")
  if [ "$pf_private" = yes ]; then
    test "$pf_owner:$pf_mode:$(stat -f '%l' "$pf_path")" = "$(id -u):600:1" \
      || fail "controlled probe input is not a private regular file"
  else
    test "$pf_owner" = 0 || test "$pf_owner" = "$(id -u)" \
      || fail "controlled probe executable owner is invalid"
    test $((0$pf_mode & 022)) -eq 0 \
      || fail "controlled probe executable is writable by others"
  fi
}

probe_canonical_json() {
  pc_path=$1
  # jq compact/sorted bytes must exactly match the private input, without LF.
  # This also rejects duplicate keys and float spellings before field checks.
  pc_canonical_sha=$(jq -S -jc . "$pc_path" 2>/dev/null | shasum -a 256 | awk '{print $1}')
  test "$pc_canonical_sha" = "$(sha256 "$pc_path")" \
    || fail "controlled probe JSON is not canonical"
}

validate_python_runtime_record() {
  pr_record="$pc_session/python-runtime.json"
  probe_regular_file "$pr_record" 8192 yes
  test "$(sha256 "$pr_record")" = "$(jq -r '.runtimeRecordSHA256' "$PROBE_BINDINGS")" \
    || fail "controlled runtime record changed"
  probe_canonical_json "$pr_record"
  jq -e --arg python "$pc_python" '
    def hex($n): type == "string" and length == $n and test("^[0-9a-f]{" + ($n|tostring) + "}$");
    (keys|sort) == (["schema","policy","requirement","pythonPath","pythonSHA256","pythonCDHash","pythonVersion","frameworkPath","frameworkSHA256","frameworkCDHash","resourcesSHA256"]|sort) and
    (.schema|type == "number" and tostring == "1") and .policy == "apple-python-framework-v1" and
    .requirement == "identifier \"com.apple.python3\" and anchor apple" and .pythonPath == $python and
    (.pythonPath|type == "string" and length <= 4096 and test("^/[^\\r\\n]*Python3\\.framework/Versions/3\\.(9|1[0-4])/bin/python3\\.(9|1[0-4])$")) and
    ([.pythonSHA256,.frameworkSHA256,.resourcesSHA256]|all(.[];hex(64))) and
    ([.pythonCDHash,.frameworkCDHash]|all(.[];hex(40)))
  ' "$pr_record" >/dev/null 2>&1 || fail "controlled runtime source policy is invalid"
  pr_version=$(basename -- "$(dirname -- "$(dirname -- "$pc_python")")")
  test "$(basename -- "$pc_python")" = "python$pr_version" || fail "controlled runtime version path differs"
  pr_framework=$(dirname -- "$(dirname -- "$(dirname -- "$(dirname -- "$pc_python")")")")
  test "$(basename -- "$pr_framework")" = Python3.framework \
    && test "$pr_framework" = "$(jq -r '.frameworkPath' "$pr_record")" \
    && test "$(CDPATH= cd -- "$pr_framework" && pwd -P)" = "$pr_framework" \
    || fail "controlled runtime framework path differs"
  pr_root="$pr_framework/Versions/$pr_version"
  test "$(CDPATH= cd -- "$pr_framework/Versions/Current" && pwd -P)" = "$pr_root" \
    && test "$(CDPATH= cd -- "$pr_framework/Resources" && pwd -P)" = "$pr_root/Resources" \
    && test "$(readlink "$pr_framework/Python3")" = 'Versions/Current/Python3' \
    || fail "controlled runtime active framework differs"
  probe_regular_file "$pc_python" 8388608 no
  probe_regular_file "$pr_root/Python3" 67108864 no
  probe_regular_file "$pr_root/_CodeSignature/CodeResources" 67108864 no
  test -x "$pc_python" || fail "controlled runtime is not executable"
  # Use system codesign, never a PATH-provided signing stub or helper. The fixed
  # Apple requirement verifies source, not merely consistency with a JSON hash.
  /usr/bin/codesign --verify --strict --all-architectures -R '=identifier "com.apple.python3" and anchor apple' "$pc_python" >/dev/null 2>&1 \
    && /usr/bin/codesign --verify --strict --all-architectures --deep -R '=identifier "com.apple.python3" and anchor apple' "$pr_framework" >/dev/null 2>&1 \
    || fail "controlled runtime does not satisfy Apple source policy"
  pr_python_cd=$(/usr/bin/codesign -d --verbose=4 "$pc_python" 2>&1 | sed -n 's/^CDHash=//p')
  pr_framework_cd=$(/usr/bin/codesign -d --verbose=4 "$pr_framework" 2>&1 | sed -n 's/^CDHash=//p')
  pr_signed_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$pr_root/Resources/Info.plist")
  pr_minor_pattern=$(printf '%s' "$pr_version" | sed 's/\./\\./g')
  printf '%s\n' "$pr_signed_version" | grep -Eq "^$pr_minor_pattern\.[0-9]+$" \
    || fail "controlled runtime signed version differs"
  test "$pr_signed_version" = "$(jq -r '.pythonVersion' "$pr_record")" \
    && test "$pr_python_cd" = "$(jq -r '.pythonCDHash' "$pr_record")" \
    && test "$pr_framework_cd" = "$(jq -r '.frameworkCDHash' "$pr_record")" \
    && test "$(sha256 "$pc_python")" = "$(jq -r '.pythonSHA256' "$pr_record")" \
    && test "$(sha256 "$pr_root/Python3")" = "$(jq -r '.frameworkSHA256' "$pr_record")" \
    && test "$(sha256 "$pr_root/_CodeSignature/CodeResources")" = "$(jq -r '.resourcesSHA256' "$pr_record")" \
    || fail "controlled runtime identity changed"
}

validate_controlled_probe() {
  test "$CYCLES" -ge 3 || fail "controlled probes require at least three cycles"
  test "${#PROBE_RUN_ID}" -eq 32 || fail "controlled probe run ID is invalid"
  printf '%s\n' "$PROBE_RUN_ID" | grep -Eq '^[0-9a-f]{32}$' \
    || fail "controlled probe run ID is invalid"
  for pc_hash in "$PROBE_BINDINGS_SHA" "$PROBE_CANDIDATE_SHA"; do
    test "${#pc_hash}" -eq 64 || fail "controlled probe binding hash is invalid"
    printf '%s\n' "$pc_hash" | grep -Eq '^[0-9a-f]{64}$' \
      || fail "controlled probe binding hash is invalid"
  done
  test "$PROBE_CANDIDATE_SHA" = "$CANDIDATE_MANIFEST_SHA256" \
    || fail "controlled probe candidate differs from the verified candidate"
  pc_session="/private/tmp/aether-ne-session.$PROBE_RUN_ID"
  test "$PROBE_BINDINGS" = "$pc_session/cycle-bindings.json" \
    || fail "controlled probe bindings path is invalid"
  probe_private_directory "$pc_session"
  probe_regular_file "$PROBE_BINDINGS" 32768 yes
  test "$(sha256 "$PROBE_BINDINGS")" = "$PROBE_BINDINGS_SHA" \
    || fail "controlled probe bindings changed"
  probe_canonical_json "$PROBE_BINDINGS"
  jq -e --arg run "$PROBE_RUN_ID" --arg engine "$ENGINE" --argjson cycles "$CYCLES" \
    --arg candidate "$CANDIDATE_MANIFEST_SHA256" --arg helper "$pc_session/controlled_probe.py" '
    def hex($n): type == "string" and length == $n and test("^[0-9a-f]{" + ($n|tostring) + "}$");
    (keys | sort) == (["schema","runID","engine","cycles","candidateManifestSHA256","pythonPath","helperPath","runtimeRecordSHA256","bindings"] | sort) and
    (.schema|type == "number" and tostring == "1") and .runID == $run and .engine == $engine and .cycles == $cycles and (.cycles|tostring|test("^[0-9]+$")) and
    .candidateManifestSHA256 == $candidate and .helperPath == $helper and
    (.pythonPath|type == "string" and startswith("/") and length <= 4096) and
    (.runtimeRecordSHA256|hex(64)) and
    (.bindings | type == "array" and length == $cycles) and
    ([.bindings[].cycle] == [range(1; $cycles+1)]) and
    all(.bindings[];
      (.cycle|type == "number" and (tostring|test("^[0-9]+$"))) and
      (keys | sort) == (["cycle","stagePath","planSHA256","requestIdentitySHA256","peerIdentitySHA256","expectedResponseSHA256"] | sort) and
      (.stagePath | type == "string" and test("^/private/tmp/aether-ne-probe\\.[0-9a-f]{32}$")) and
      ([.planSHA256,.requestIdentitySHA256,.peerIdentitySHA256,.expectedResponseSHA256] | all(.[]; hex(64)))) and
    ([.bindings[].stagePath] | unique | length == $cycles) and
    ([.bindings[].planSHA256] | unique | length == $cycles) and
    ([.bindings[].requestIdentitySHA256] | unique | length == $cycles) and
    ([.bindings[].expectedResponseSHA256] | unique | length == $cycles) and
    ([.bindings[].peerIdentitySHA256] | unique | length == 1)
  ' "$PROBE_BINDINGS" >/dev/null 2>&1 || fail "controlled cycle bindings are invalid"
  pc_helper="$pc_session/controlled_probe.py"
  pc_python=$(jq -r '.pythonPath' "$PROBE_BINDINGS")
  probe_regular_file "$pc_helper" 131072 no
  test "$(sha256 "$pc_helper")" = 43f5329a0bb50dda0ccca42b5c96f5709d0d3720950989109e49cd26bf64489a \
    || fail "controlled probe helper changed"
  validate_python_runtime_record
  pc_cycle=1
  while [ "$pc_cycle" -le "$CYCLES" ]; do
    pc_stage=$(jq -r --argjson i "$((pc_cycle-1))" '.bindings[$i].stagePath' "$PROBE_BINDINGS")
    probe_private_directory "$pc_stage"
    pc_plan="$pc_stage/plan.json"
    probe_regular_file "$pc_plan" 8192 yes
    test "$(sha256 "$pc_plan")" = "$(jq -r --argjson i "$((pc_cycle-1))" '.bindings[$i].planSHA256' "$PROBE_BINDINGS")" \
      || fail "controlled cycle plan changed"
    probe_canonical_json "$pc_plan"
    jq -e --arg run "$PROBE_RUN_ID" --arg engine "$ENGINE" --argjson cycle "$pc_cycle" \
      --arg candidate "$CANDIDATE_MANIFEST_SHA256" '
      def hex($n): type == "string" and length == $n and test("^[0-9a-f]{" + ($n|tostring) + "}$");
      def address:
        type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$") and
        (split(".") | all(.[]; (tonumber|floor) == tonumber and (tonumber >= 0 and tonumber <= 255)) and
         (map(tonumber|tostring)|join(".")) == join("."));
      def privateIP:
        address and ((split(".")|map(tonumber)) as $b |
        ($b[0] == 10 and $b != [10,0,0,0] and $b != [10,255,255,255]) or
        ($b[0] == 172 and $b[1] >= 16 and $b[1] <= 31 and $b != [172,16,0,0] and $b != [172,31,255,255]) or
        ($b[0:2] == [192,168] and $b != [192,168,0,0] and $b != [192,168,255,255]));
      def testIP:
        address and ((split(".")|map(tonumber)) as $b |
        ([192,0,2] == $b[0:3] or [198,51,100] == $b[0:3] or [203,0,113] == $b[0:3]) and $b[3] >= 1 and $b[3] <= 254);
      (keys | sort) == (["schemaVersion","runID","engine","cycle","candidateManifestSHA256","peerID","peerSourceSHA256","hostname","port","controlAddress","dataAddress","requestID","token","certificateSHA256"] | sort) and
      (.schemaVersion|type == "number" and tostring == "1") and .runID == $run and .engine == $engine and .cycle == $cycle and (.cycle|tostring|test("^[0-9]+$")) and
      .candidateManifestSHA256 == $candidate and .hostname == "aether-performance.test" and
      (.port | type == "number" and (tostring|test("^[0-9]+$")) and . == floor and . >= 1024 and . <= 65535) and
      (.requestID|hex(32)) and ([.peerID,.peerSourceSHA256,.certificateSHA256] | all(.[]; hex(64))) and
      (.token|type == "string" and test("^[A-Za-z0-9_-]{32,128}\\z")) and
      (.controlAddress|privateIP) and (.dataAddress|testIP)
    ' "$pc_plan" >/dev/null 2>&1 || fail "controlled cycle plan is invalid"
    for pc_field in request peer response; do
      case "$pc_field" in
        request) pc_filter='.requestID'; pc_key=requestIdentitySHA256 ;;
        peer) pc_filter='.peerID'; pc_key=peerIdentitySHA256 ;;
        response) pc_filter='{requestID:.requestID,peerID:.peerID,accessPath:"relay"}'; pc_key=expectedResponseSHA256 ;;
      esac
      pc_actual=$(jq -jc "$pc_filter" "$pc_plan" | shasum -a 256 | awk '{print $1}')
      test "$pc_actual" = "$(jq -r --argjson i "$((pc_cycle-1))" --arg key "$pc_key" '.bindings[$i][$key]' "$PROBE_BINDINGS")" \
        || fail "controlled cycle identity is not bound to its plan"
    done
    probe_regular_file "$pc_stage/server-cert.pem" 65536 yes
    test "$(sha256 "$pc_stage/server-cert.pem")" = "$(jq -r '.certificateSHA256' "$pc_plan")" \
      || fail "controlled cycle certificate changed"
    pc_cycle=$((pc_cycle+1))
  done
}

validate_prepare_environment() {
  ENGINE=$1
  case "$ENGINE" in tun|transparent) ;; *) fail "engine must be tun or transparent" ;; esac
  CYCLES=${AETHERROUTE_SIGNED_NE_CYCLES:-}
  case "$CYCLES" in ''|*[!0-9]*) fail "AETHERROUTE_SIGNED_NE_CYCLES must be an integer" ;; esac
  test "$CYCLES" -ge 1 && test "$CYCLES" -le 20 \
    || fail "AETHERROUTE_SIGNED_NE_CYCLES must be between 1 and 20"
  PROBE_KIND=${AETHERROUTE_SIGNED_PROBE_KIND-public-https}
  PROBE_URL=${AETHERROUTE_SIGNED_PROBE_URL:-} PROBE_SHA=${AETHERROUTE_SIGNED_PROBE_SHA256:-}
  PROBE_BINDINGS=${AETHERROUTE_SIGNED_PROBE_BINDINGS:-} PROBE_BINDINGS_SHA=${AETHERROUTE_SIGNED_PROBE_BINDINGS_SHA256:-}
  PROBE_RUN_ID=${AETHERROUTE_SIGNED_NE_RUN_ID:-} PROBE_CANDIDATE_SHA=${AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST_SHA256:-}
  case "$PROBE_KIND" in
    public-https)
      for pc_key in AETHERROUTE_SIGNED_PROBE_BINDINGS AETHERROUTE_SIGNED_PROBE_BINDINGS_SHA256 AETHERROUTE_SIGNED_NE_RUN_ID AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST_SHA256; do
        if printenv "$pc_key" >/dev/null; then fail "public probe contains controlled configuration"; fi
      done
      case "$PROBE_URL" in https://*.*/*) ;; *) fail "signed probe URL is invalid" ;; esac
      printf '%s' "$PROBE_URL" | grep -Eq '[@?#[:space:]]' \
        && fail "signed probe URL contains a credential, query, fragment, or whitespace"
      printf '%s\n' "$PROBE_SHA" | grep -Eq '^[0-9a-f]{64}$' || fail "signed probe SHA-256 is invalid"
      ;;
    controlled-relay-v1)
      for pc_key in AETHERROUTE_SIGNED_PROBE_URL AETHERROUTE_SIGNED_PROBE_SHA256; do
        if printenv "$pc_key" >/dev/null; then fail "controlled probe contains public configuration"; fi
      done
      validate_controlled_probe
      ;;
    *) fail "unknown signed probe kind" ;;
  esac
  DNS_PROBE=${AETHERROUTE_SIGNED_DNS_PROBE_SCRIPT:-} DNS_SHA=${AETHERROUTE_SIGNED_DNS_PROBE_SHA256:-}
  BYPASS_CIDRS=${AETHERROUTE_SIGNED_NE_BYPASS_CIDRS:-}
  printf '%s\n' "$DNS_SHA" | grep -Eq '^[0-9a-f]{64}$' || fail "signed DNS probe SHA-256 is invalid"
  require_absolute_file "$DNS_PROBE" "signed DNS probe"
  test -x "$DNS_PROBE" || fail "signed DNS probe is not executable"
  test "$(sha256 "$DNS_PROBE")" = "$DNS_SHA" || fail "signed DNS probe hash mismatch"
}

probe_environment_keys() {
  printf '%s\n' AETHERROUTE_SIGNED_PROBE_KIND AETHERROUTE_SIGNED_PROBE_URL AETHERROUTE_SIGNED_PROBE_SHA256 \
    AETHERROUTE_SIGNED_PROBE_BINDINGS AETHERROUTE_SIGNED_PROBE_BINDINGS_SHA256 \
    AETHERROUTE_SIGNED_NE_RUN_ID AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST_SHA256
}

expected_probe_environment() {
  jq -S -cn --arg kind "$PROBE_KIND" --arg url "$PROBE_URL" --arg sha "$PROBE_SHA" \
    --arg bindings "$PROBE_BINDINGS" --arg bindingsSHA "$PROBE_BINDINGS_SHA" \
    --arg run "$PROBE_RUN_ID" --arg candidate "$PROBE_CANDIDATE_SHA" '
    {AETHERROUTE_SIGNED_PROBE_KIND:$kind} +
    (if $kind == "public-https" then {AETHERROUTE_SIGNED_PROBE_URL:$url,AETHERROUTE_SIGNED_PROBE_SHA256:$sha}
     else {AETHERROUTE_SIGNED_PROBE_BINDINGS:$bindings,AETHERROUTE_SIGNED_PROBE_BINDINGS_SHA256:$bindingsSHA,
           AETHERROUTE_SIGNED_NE_RUN_ID:$run,AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST_SHA256:$candidate} end)'
}

inject_probe_environment() {
  pe_file=$1
  pe_expected=$(expected_probe_environment)
  for pe_key in $(printf '%s\n' "$pe_expected" | jq -r 'keys[]'); do
    pe_value=$(printf '%s\n' "$pe_expected" | jq -r --arg key "$pe_key" '.[$key]')
    inject_environment_value "$pe_file" "$pe_key" "$pe_value"
  done
}

verify_probe_environment() {
  pe_file=$1
  pe_expected=$(expected_probe_environment)
  for pe_dictionary in EnvironmentVariables TestingEnvironmentVariables; do
    pe_actual=$(plutil -extract "$UI_TARGET.$pe_dictionary" json -o - "$pe_file" | jq -S -c '
      with_entries(select(.key | startswith("AETHERROUTE_SIGNED_PROBE_") or
        . == "AETHERROUTE_SIGNED_NE_RUN_ID" or . == "AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST_SHA256"))') \
      || fail "effective xctestrun probe environment is unreadable"
    test "$pe_actual" = "$pe_expected" || fail "effective xctestrun probe dispatch mismatch"
    test "$(plutil -extract "$UI_TARGET.$pe_dictionary.AETHERROUTE_SIGNED_NE_CYCLES" raw -o - "$pe_file")" = "$CYCLES" \
      || fail "effective xctestrun probe cycle count mismatch"
    test "$(plutil -extract "$UI_TARGET.$pe_dictionary.AETHERROUTE_SIGNED_NE_ENGINE" raw -o - "$pe_file")" = "$ENGINE" \
      || fail "effective xctestrun probe engine mismatch"
  done
  pe_app=$(plutil -extract "$UI_TARGET.UITargetAppEnvironmentVariables" json -o - "$pe_file") \
    || fail "effective xctestrun target environment is unreadable"
  printf '%s\n' "$pe_app" | jq -e 'type == "object" and (keys | all(.[];
    (startswith("AETHERROUTE_SIGNED_") or . == "AETHERROUTE_RUN_SIGNED_NE_TEST") | not))' >/dev/null \
    || fail "probe configuration escaped into the target App"
}

validate_effective_probe_environment() (
  pe_effective=$1 pe_engine=$2 pe_manifest=$3
  # Use the hash-bound xctestrun, not ambient shell values, for replay checks.
  for pe_key in $(probe_environment_keys) AETHERROUTE_SIGNED_NE_CYCLES AETHERROUTE_SIGNED_DNS_PROBE_SCRIPT AETHERROUTE_SIGNED_DNS_PROBE_SHA256; do
    unset "$pe_key"
    if pe_value=$(plutil -extract "$UI_TARGET.EnvironmentVariables.$pe_key" raw -o - "$pe_effective" 2>/dev/null); then
      export "$pe_key=$pe_value"
    fi
  done
  require_absolute_file "$pe_manifest" "prepared manifest"
  CANDIDATE_MANIFEST_SHA256=$(jq -er '.candidateManifestSHA256 | select(type == "string" and test("^[0-9a-f]{64}$"))' "$pe_manifest") \
    || fail "prepared candidate binding is invalid"
  validate_prepare_environment "$pe_engine"
  verify_probe_environment "$pe_effective"
)


validate_archive_listing() {
  zip_file=$1
  entries=$(zipinfo -1 "$zip_file") || fail "prebuilt ZIP cannot be listed"
  count=$(printf '%s\n' "$entries" | awk 'NF {count++} END {print count+0}')
  test "$count" -ge 4 && test "$count" -le 5000 \
    || fail "prebuilt ZIP has an unsafe entry count"
  printf '%s\n' "$entries" | while IFS= read -r entry; do
    case "$entry" in
      "$PAYLOAD_NAME"|"$PAYLOAD_NAME"/*) ;;
      *) exit 92 ;;
    esac
    case "$entry" in /*|*../*|*/..|*\\*|*$'\r'*) exit 93 ;; esac
  done || fail "prebuilt ZIP contains an unsafe path"
}

verify_extracted_payload() {
  payload=$1
  for file in manifest.json files.sha256 links.txt; do
    test -f "$payload/$file" && test ! -L "$payload/$file" \
      || fail "prebuilt payload is missing $file"
  done
  test -d "$payload/Products" && test ! -L "$payload/Products" \
    || fail "prebuilt payload is missing Products"
  unexpected=$(find "$payload" -mindepth 1 -maxdepth 1 \
    ! -name manifest.json ! -name files.sha256 ! -name links.txt \
    ! -name Products -print)
  test -z "$unexpected" || fail "prebuilt payload contains unexpected top-level files"
  test "$(sha256 "$payload/files.sha256")" \
    = "$(jq -r '.productFilesSHA256' "$payload/manifest.json")" \
    || fail "product checksum manifest hash mismatch"
  test "$(sha256 "$payload/links.txt")" \
    = "$(jq -r '.productLinksSHA256' "$payload/manifest.json")" \
    || fail "product link manifest hash mismatch"
  actual_files="$payload/actual-files.txt"
  expected_files="$payload/expected-files.txt"
  (cd "$payload" && find Products -type f -print | LC_ALL=C sort) >"$actual_files"
  awk '{print substr($0, 67)}' "$payload/files.sha256" >"$expected_files"
  cmp -s "$actual_files" "$expected_files" || fail "product file set differs from its manifest"
  grep -Eqv '^[0-9a-f]{64}  Products/' "$payload/files.sha256" \
    && fail "product checksum manifest has an invalid row"
  (cd "$payload" && shasum -a 256 -c files.sha256 >/dev/null) \
    || fail "a prebuilt product file hash changed"
  actual_links="$payload/actual-links.txt"
  (
    cd "$payload"
    find Products -type l -print | LC_ALL=C sort | while IFS= read -r path; do
      target=$(readlink "$path")
      case "$path:$target" in /*|*../*|*/..|*\\*|*:\/*) exit 94 ;; esac
      printf '%s\t%s\n' "$path" "$target"
    done
  ) >"$actual_links" || fail "extracted payload contains an unsafe symbolic link"
  cmp -s "$actual_links" "$payload/links.txt" \
    || fail "product symbolic links differ from their manifest"
  find "$actual_files" "$expected_files" "$actual_links" -delete
}

inject_environment_value() {
  xctestrun=$1
  key=$2
  value=$3
  for dictionary in EnvironmentVariables TestingEnvironmentVariables; do
    if plutil -extract "$UI_TARGET.$dictionary.$key" raw -o - "$xctestrun" \
      >/dev/null 2>&1; then
      fail "xctestrun already contains controlled environment key $key"
    fi
    plutil -insert "$UI_TARGET.$dictionary.$key" -string "$value" "$xctestrun"
  done
}

prepare_runner() {
  test "$#" -eq 9 || { usage; exit 64; }
  zip_file=$1
  expected_zip_sha=$2
  signing=$3
  candidate=$4
  candidate_source_manifest=$5
  expected_app_cdhash=$6
  destination=$7
  engine=$8
  reserved=$9
  test "$reserved" = -- || fail "prepare requires a final -- argument"
  require_absolute_file "$zip_file" "prebuilt ZIP"
  printf '%s\n' "$expected_zip_sha" | grep -Eq '^[0-9a-f]{64}$' \
    || fail "prebuilt ZIP SHA-256 is invalid"
  test "$(sha256 "$zip_file")" = "$expected_zip_sha" \
    || fail "prebuilt ZIP SHA-256 mismatch"
  zip_mode=$(stat -f '%Lp' "$zip_file")
  case "$zip_mode" in ''|*[!0-7]*) fail "prebuilt ZIP mode is invalid" ;; esac
  test $((0$zip_mode & 022)) -eq 0 \
    || fail "prebuilt ZIP is group/world writable"
  zip_bytes=$(stat -f '%z' "$zip_file")
  test "$zip_bytes" -gt 0 && test "$zip_bytes" -le 536870912 \
    || fail "prebuilt ZIP size is outside the safe bound"
  load_signing_contract "$signing"
  validate_candidate_manifest "$candidate"
  validate_candidate_source_manifest "$candidate_source_manifest"
  validate_prepare_environment "$engine"
  printf '%s\n' "$expected_app_cdhash" | grep -Eq '^[0-9a-f]{40}$' \
    || fail "expected installed candidate CDHash is invalid"
  case "$destination" in /*) ;; *) fail "destination must be absolute" ;; esac
  test ! -e "$destination" || fail "destination must not already exist"
  destination_parent=$(CDPATH= cd -- "$(dirname -- "$destination")" && pwd -P)
  temp_base=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
  test "$destination_parent" = "$temp_base" \
    || fail "destination must be directly inside the physical temporary directory"
  case "$(basename "$destination")" in
    aetherroute-prebuilt-runner.*) ;;
    *) fail "destination name must begin aetherroute-prebuilt-runner."
  esac
  validate_archive_listing "$zip_file"
  mkdir "$destination"
  cleanup_failed_prepare() {
    if [ "${PREPARE_COMPLETE:-0}" -eq 0 ]; then
      find "$destination" -depth -delete 2>/dev/null || true
    fi
  }
  PREPARE_COMPLETE=0
  trap cleanup_failed_prepare EXIT HUP INT TERM
  ditto -x -k "$zip_file" "$destination"
  payload="$destination/$PAYLOAD_NAME"
  verify_extracted_payload "$payload"
  manifest="$payload/manifest.json"
  jq -e \
    --arg source "$CANDIDATE_SOURCE_SHA256" \
    --arg candidateSourceManifest "$CANDIDATE_SOURCE_MANIFEST_FILE_SHA256" \
    --arg candidate "$CANDIDATE_MANIFEST_SHA256" \
    --arg status "$CANDIDATE_STATUS" \
    --arg version "$CANDIDATE_VERSION" \
    --arg build "$CANDIDATE_BUILD" \
    --arg ui "$frozen_ui_sha" \
    --arg team "$EXPECTED_TEAM_ID" \
    --arg host "$EXPECTED_HOST_BUNDLE" \
    --arg packet "$EXPECTED_PACKET_BUNDLE" \
    --arg transparent "$EXPECTED_TRANSPARENT_BUNDLE" '
      .schemaVersion == 1 and
      .product == "AetherRouteSignedNERunner" and
      .architecture == "arm64" and
      .sourceManifestSHA256 == $source and
      .candidateSourceManifestFileSHA256 == $candidateSourceManifest and
      .candidateManifestSHA256 == $candidate and
      .candidateStatus == $status and
      .candidateVersion == $version and
      .candidateBuild == $build and
      .uiTestSHA256 == $ui and
      .teamID == $team and
      .hostBundleID == $host and
      .packetBundleID == $packet and
      .transparentBundleID == $transparent and
      (.xctestrunPath | test("^Products/[^/]+\\.xctestrun$")) and
      (.xctestrunSHA256 | test("^[0-9a-f]{64}$")) and
      (.runnerCDHash | test("^[0-9a-f]{40}$")) and
      (.uiTestBundleCDHash | test("^[0-9a-f]{40}$"))
    ' "$manifest" >/dev/null || fail "prebuilt manifest binding failed"

  original="$payload/$(jq -r '.xctestrunPath' "$manifest")"
  runner="$payload/$(jq -r '.runnerPath' "$manifest")"
  test_bundle="$payload/$(jq -r '.uiTestBundlePath' "$manifest")"
  require_absolute_file "$original" "original xctestrun"
  test "$(sha256 "$original")" = "$(jq -r '.xctestrunSHA256' "$manifest")" \
    || fail "original xctestrun hash mismatch"
  verify_development_bundle "$runner" \
    "$EXPECTED_HOST_BUNDLE.ui-tests.xctrunner" \
    "$(jq -r '.runnerCDHash' "$manifest")" >/dev/null
  verify_development_bundle "$test_bundle" \
    "$EXPECTED_HOST_BUNDLE.ui-tests" \
    "$(jq -r '.uiTestBundleCDHash' "$manifest")" >/dev/null

  test -d "$INSTALLED_APP" || fail "installed AetherRoute app is missing"
  codesign --verify --deep --strict "$INSTALLED_APP" >/dev/null 2>&1 \
    || fail "installed candidate signature is invalid"
  codesign -dv --verbose=4 "$INSTALLED_APP" 2>&1 \
    | grep -F 'Authority=Developer ID Application:' >/dev/null \
    || fail "installed candidate is not Developer ID signed"
  actual_app_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$INSTALLED_APP/Contents/Info.plist")
  actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$INSTALLED_APP/Contents/Info.plist")
  actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$INSTALLED_APP/Contents/Info.plist")
  actual_app_cdhash=$(code_sign_field "$INSTALLED_APP" CDHash | tr '[:upper:]' '[:lower:]')
  test "$actual_app_bundle" = "$EXPECTED_HOST_BUNDLE" \
    || fail "installed candidate bundle identifier mismatch"
  test "$actual_version" = "$CANDIDATE_VERSION" \
    || fail "installed candidate version mismatch"
  test "$actual_build" = "$CANDIDATE_BUILD" \
    || fail "installed candidate build mismatch"
  test "$actual_app_cdhash" = "$expected_app_cdhash" \
    || fail "installed candidate CDHash mismatch"
  if [ "$CANDIDATE_STATUS" = notarized-test-candidate ]; then
    spctl --assess --type execute "$INSTALLED_APP" >/dev/null 2>&1 \
      || fail "installed notarized candidate failed Gatekeeper"
  elif [ "$(jq -r '.application.cdHash // empty' "$CANDIDATE_MANIFEST")" \
      != "$actual_app_cdhash" ]; then
    fail "installed local candidate CDHash differs from its candidate manifest"
  fi

  plutil -extract "$UI_TARGET.TestHostPath" raw -o - "$original" \
    | grep -qx '__TESTROOT__/Debug/AetherRouteUITests-Runner.app' \
    || fail "original xctestrun changed its runner host"
  plutil -extract "$UI_TARGET.TestBundlePath" raw -o - "$original" \
    | grep -qx '__TESTHOST__/Contents/PlugIns/AetherRouteUITests.xctest' \
    || fail "original xctestrun changed its UI test bundle"
  original_target=$(plutil -extract "$UI_TARGET.UITargetAppPath" raw -o - "$original")
  test "$original_target" = '__TESTROOT__/Debug/AetherRoute.app' \
    || fail "original xctestrun has an unexpected UI target app"
  dependency_index=$(plutil -extract "$UI_TARGET.DependentProductPaths" json \
    -o - "$original" | jq -r 'to_entries
      | map(select(.value == "__TESTROOT__/Debug/AetherRoute.app"))
      | if length == 1 then .[0].key else empty end')
  test -n "$dependency_index" || fail "xctestrun has no unique Debug app dependency"
  if plutil -extract "$UI_TARGET.UITargetAppEnvironmentVariables" json -o - \
    "$original" | jq -e 'keys | any(startswith("AETHERROUTE_SIGNED_") or . == "AETHERROUTE_RUN_SIGNED_NE_TEST")' \
    >/dev/null; then
    fail "test controls escaped into the target app environment"
  fi

  effective="$payload/Products/AetherRoute-$engine-effective.xctestrun"
  cp "$original" "$effective"
  plutil -replace "$UI_TARGET.UITargetAppPath" -string "$INSTALLED_APP" "$effective"
  # Replacing an array index with plutil can insert and retain the old entry.
  # Replace the complete array, preserving every unrelated dependency exactly.
  effective_dependencies=$(plutil -extract "$UI_TARGET.DependentProductPaths" json -o - "$original" \
    | jq -c --argjson index "$dependency_index" --arg app "$INSTALLED_APP" '.[$index] = $app') \
    || fail "xctestrun dependencies are unreadable"
  plutil -replace "$UI_TARGET.DependentProductPaths" -json "$effective_dependencies" "$effective"
  test "$(plutil -extract "$UI_TARGET.DependentProductPaths" json -o - "$effective" | jq -c .)" = "$effective_dependencies" \
    || fail "effective xctestrun app dependency binding failed"
  inject_environment_value "$effective" AETHERROUTE_RUN_SIGNED_NE_TEST YES
  inject_environment_value "$effective" AETHERROUTE_SIGNED_NE_PRODUCT independent
  inject_environment_value "$effective" AETHERROUTE_SIGNED_NE_ENGINE "$engine"
  inject_environment_value "$effective" AETHERROUTE_SIGNED_NE_CYCLES "$CYCLES"
  inject_probe_environment "$effective"
  inject_environment_value "$effective" AETHERROUTE_SIGNED_DNS_PROBE_SCRIPT "$DNS_PROBE"
  inject_environment_value "$effective" AETHERROUTE_SIGNED_DNS_PROBE_SHA256 "$DNS_SHA"
  inject_environment_value "$effective" AETHERROUTE_SIGNED_NE_BYPASS_CIDRS "$BYPASS_CIDRS"
  inject_environment_value "$effective" AETHERROUTE_SIGNED_NE_USE_INSTALLED_APP YES
  inject_environment_value "$effective" AETHERROUTE_SIGNED_NE_HOST_BUNDLE_ID "$EXPECTED_HOST_BUNDLE"
  plutil -lint "$effective" >/dev/null || fail "effective xctestrun is invalid"
  test "$(plutil -extract "$UI_TARGET.UITargetAppPath" raw -o - "$effective")" \
    = "$INSTALLED_APP" || fail "effective xctestrun did not bind the installed app"
  test "$(plutil -extract "$UI_TARGET.TestHostPath" raw -o - "$effective")" \
    = '__TESTROOT__/Debug/AetherRouteUITests-Runner.app' \
    || fail "effective xctestrun changed the runner host"

  verify_probe_environment "$effective"

  chmod 500 "$payload/Products/Debug/AetherRouteUITests-Runner.app"
  chmod 400 "$original" "$effective" "$manifest" \
    "$payload/files.sha256" "$payload/links.txt"
  PREPARE_COMPLETE=1
  trap - EXIT HUP INT TERM
  printf 'effective_xctestrun=%s\n' "$effective"
  printf 'original_xctestrun_sha256=%s\n' "$(sha256 "$original")"
  printf 'effective_xctestrun_sha256=%s\n' "$(sha256 "$effective")"
  printf 'prebuilt_zip_sha256=%s\n' "$expected_zip_sha"
  printf 'prebuilt_manifest_sha256=%s\n' "$(sha256 "$manifest")"
  printf 'candidate_manifest_sha256=%s\n' "$CANDIDATE_MANIFEST_SHA256"
  printf 'candidate_source_manifest_sha256=%s\n' "$CANDIDATE_SOURCE_SHA256"
  printf 'candidate_app_cdhash=%s\n' "$actual_app_cdhash"
  printf 'runner_cdhash=%s\n' "$(jq -r '.runnerCDHash' "$manifest")"
  printf 'ui_test_bundle_cdhash=%s\n' "$(jq -r '.uiTestBundleCDHash' "$manifest")"
  printf 'execution_contract=xcodebuild test-without-building -xctestrun\n'
}

run_prepared_runner() {
  test "$#" -eq 6 || { usage; exit 64; }
  effective=$1
  expected_effective_sha=$2
  signing=$3
  engine=$4
  result_bundle=$5
  reserved=$6
  test "$reserved" = -- || fail "run requires a final -- argument"
  require_absolute_file "$effective" "effective xctestrun"
  printf '%s\n' "$expected_effective_sha" | grep -Eq '^[0-9a-f]{64}$' \
    || fail "effective xctestrun SHA-256 is invalid"
  test "$(sha256 "$effective")" = "$expected_effective_sha" \
    || fail "effective xctestrun SHA-256 mismatch"
  load_signing_contract "$signing"
  case "$engine" in tun|transparent) ;; *) fail "engine must be tun or transparent" ;; esac
  case "$result_bundle" in /*) ;; *) fail "result bundle path must be absolute" ;; esac
  test ! -e "$result_bundle" || fail "refusing to overwrite a result bundle"

  products=$(CDPATH= cd -- "$(dirname -- "$effective")" && pwd -P)
  payload=$(CDPATH= cd -- "$products/.." && pwd -P)
  destination=$(CDPATH= cd -- "$payload/.." && pwd -P)
  temp_base=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
  destination_parent=$(CDPATH= cd -- "$destination/.." && pwd -P)
  test "$destination_parent" = "$temp_base" \
    || fail "effective xctestrun is outside the physical temporary directory"
  case "$(basename "$destination")" in
    aetherroute-prebuilt-runner.*) ;;
    *) fail "effective xctestrun is outside a prepared runner directory" ;;
  esac
  test "$(basename "$payload")" = "$PAYLOAD_NAME" \
    || fail "effective xctestrun payload name is invalid"
  test "$effective" = "$products/AetherRoute-$engine-effective.xctestrun" \
    || fail "effective xctestrun path is not the prepared engine path"
  result_parent=$(CDPATH= cd -- "$(dirname -- "$result_bundle")" && pwd -P)
  test "$result_parent" = "$destination" \
    || fail "result bundle must be directly inside the prepared runner directory"

  test "$(plutil -extract "$UI_TARGET.UITargetAppPath" raw -o - "$effective")" \
    = "$INSTALLED_APP" || fail "effective xctestrun does not target the installed app"
  test "$(plutil -extract "$UI_TARGET.TestHostPath" raw -o - "$effective")" \
    = '__TESTROOT__/Debug/AetherRouteUITests-Runner.app' \
    || fail "effective xctestrun does not preserve the runner host"
  for dictionary in EnvironmentVariables TestingEnvironmentVariables; do
    test "$(plutil -extract "$UI_TARGET.$dictionary.AETHERROUTE_RUN_SIGNED_NE_TEST" raw -o - "$effective")" = YES \
      || fail "effective xctestrun is missing its explicit opt-in"
    test "$(plutil -extract "$UI_TARGET.$dictionary.AETHERROUTE_SIGNED_NE_ENGINE" raw -o - "$effective")" = "$engine" \
      || fail "effective xctestrun engine binding mismatch"
    test "$(plutil -extract "$UI_TARGET.$dictionary.AETHERROUTE_SIGNED_NE_USE_INSTALLED_APP" raw -o - "$effective")" = YES \
      || fail "effective xctestrun does not require the installed app"
    test "$(plutil -extract "$UI_TARGET.$dictionary.AETHERROUTE_SIGNED_NE_HOST_BUNDLE_ID" raw -o - "$effective")" = "$EXPECTED_HOST_BUNDLE" \
      || fail "effective xctestrun host bundle binding mismatch"
  done

  validate_effective_probe_environment "$effective" "$engine" "$payload/manifest.json"

  if [ "${AETHERROUTE_ALLOW_REAL_NETWORK_TEST:-}" != YES ]; then
    fail "run requires AETHERROUTE_ALLOW_REAL_NETWORK_TEST=YES"
  fi
  expected_host=${AETHERROUTE_NETWORK_TEST_HOST:-}
  test -n "$expected_host" || fail "run requires AETHERROUTE_NETWORK_TEST_HOST"
  current_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
  test "$current_host" = "$expected_host" \
    || fail "refusing real Network Extension test on an unexpected host"
  control_peer=${AETHERROUTE_SIGNED_NE_CONTROL_PEER:-}
  printf '%s\n' "$control_peer" | awk -F. '
    NF != 4 {exit 1}
    {for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1}
  ' || fail "run requires a valid Tailscale control peer"
  control_timeout=${AETHERROUTE_SIGNED_NE_CONTROL_TIMEOUT_SECONDS:-540}
  case "$control_timeout" in ''|*[!0-9]*) fail "control timeout must be an integer" ;; esac
  test "$control_timeout" -ge 180 && test "$control_timeout" -le 3600 \
    || fail "control timeout must be between 180 and 3600 seconds"
  tailscale_cli=${AETHERROUTE_SIGNED_NE_TAILSCALE_CLI:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}
  case "$tailscale_cli" in /*) ;; *) fail "Tailscale CLI must be absolute" ;; esac
  test -x "$tailscale_cli" || fail "Tailscale CLI is not executable"
  route_command=/sbin/route
  magic_dns=100.100.100.100
  baseline_control_interface=$("$route_command" -n get "$control_peer" \
    2>/dev/null | awk '$1 == "interface:" {print $2; exit}')
  case "$baseline_control_interface" in utun[0-9]*) ;; *) fail "control peer is not on a Tailscale utun" ;; esac
  baseline_magic_interface=$("$route_command" -n get "$magic_dns" \
    2>/dev/null | awk '$1 == "interface:" {print $2; exit}')
  test "$baseline_magic_interface" = "$baseline_control_interface" \
    || fail "MagicDNS does not share the Tailscale control interface"

  tailscale_direct_ping() {
    ping_output=$("$tailscale_cli" ping --c 1 --timeout 2s \
      --until-direct=true "$control_peer" 2>/dev/null) || return 1
    printf '%s\n' "$ping_output" | grep -Eq \
      ' via ([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+( |$)| via \[[0-9A-Fa-f:]+\]:[0-9]+( |$)'
  }
  tailscale_direct_ping || fail "Tailscale control peer is not direct before the gate"
  network_control_hash() {
    {
      /usr/sbin/scutil --proxy
      /usr/sbin/scutil --dns
      /usr/sbin/netstat -rn -f inet | awk '$1 == "default" {print}'
      /usr/sbin/netstat -rn -f inet6 | awk '$1 == "default" {print}'
      /sbin/ifconfig -l
      "$route_command" -n get "$control_peer" 2>/dev/null \
        | awk '$1 == "destination:" || $1 == "gateway:" || $1 == "interface:" || $1 == "flags:" {print}'
      "$route_command" -n get "$magic_dns" 2>/dev/null \
        | awk '$1 == "destination:" || $1 == "gateway:" || $1 == "interface:" || $1 == "flags:" {print}'
    } | shasum -a 256 | awk '{print $1}'
  }
  network_before=$(network_control_hash)

  resolver="$ROOT/scripts/signed_ne_tun_service_resolver.sh"
  watchdog="$ROOT/scripts/signed_ne_control_watchdog.sh"
  test -x "$resolver" && test -x "$watchdog" \
    || fail "scoped TUN resolver or control watchdog is missing"
  safe_stop_tun() {
    service_id=$("$resolver" "$EXPECTED_HOST_BUNDLE" \
      "$EXPECTED_PACKET_BUNDLE" AetherRoute /usr/sbin/scutil) \
      || return 1
    /usr/sbin/scutil --nc stop "$service_id" >/dev/null 2>&1 || return 1
    stop_attempt=0
    while [ "$stop_attempt" -lt 20 ]; do
      state=$(/usr/sbin/scutil --nc status "$service_id" 2>/dev/null \
        | awk 'NR == 1 {print $1}' || true)
      case "$state" in
        Disconnected) return 0 ;;
        Connected|Connecting|Disconnecting) ;;
        *) return 1 ;;
      esac
      stop_attempt=$((stop_attempt + 1))
      sleep 1
    done
    return 1
  }

  set -- xcodebuild test-without-building \
    -xctestrun "$effective" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$result_bundle" \
    -only-testing:"$UI_TARGET/AetherRouteUITests/testSignedNetworkExtensionConnectDisconnectLifecycle"
  if [ "$engine" = tun ]; then
    stop_file="$destination/control-watchdog.stop"
    watchdog_log="$destination/control-watchdog.log"
    "$watchdog" "$control_peer" "$baseline_control_interface" \
      "$magic_dns" "$baseline_magic_interface" "$stop_file" \
      "$control_timeout" "$route_command" "$tailscale_cli" 2 5 \
      >"$watchdog_log" 2>&1 &
    watchdog_pid=$!
    "$@" &
    test_pid=$!
    completed=
    while [ -z "$completed" ]; do
      if ! kill -0 "$test_pid" 2>/dev/null; then
        completed=test
      elif ! kill -0 "$watchdog_pid" 2>/dev/null; then
        completed=watchdog
      else
        sleep 1
      fi
    done
    if [ "$completed" = watchdog ]; then
      wait "$watchdog_pid" 2>/dev/null || true
      safe_stop_tun || true
      kill -TERM "$test_pid" 2>/dev/null || true
      wait "$test_pid" 2>/dev/null || true
      pkill -TERM -f "$destination" 2>/dev/null || true
      safe_stop_tun || fail "watchdog fired and the scoped TUN stop could not be verified"
      fail "TUN control-path watchdog stopped the prebuilt runner"
    fi
    test_status=0
    wait "$test_pid" || test_status=$?
    : >"$stop_file"
    watchdog_status=0
    wait "$watchdog_pid" || watchdog_status=$?
    if [ "$test_status" -ne 0 ] || [ "$watchdog_status" -ne 0 ]; then
      safe_stop_tun || fail "failed prebuilt TUN run could not be stopped safely"
      fail "prebuilt TUN lifecycle or control watchdog failed"
    fi
    watchdog_checks=$(awk -F= \
      '$1 == "control-peer watchdog stopped: checks" {print $2; exit}' \
      "$watchdog_log")
    case "$watchdog_checks" in ''|*[!0-9]*|0) fail "watchdog completed without a real probe" ;; esac
  else
    "$@"
  fi

  current_control_interface=$("$route_command" -n get "$control_peer" \
    2>/dev/null | awk '$1 == "interface:" {print $2; exit}')
  current_magic_interface=$("$route_command" -n get "$magic_dns" \
    2>/dev/null | awk '$1 == "interface:" {print $2; exit}')
  test "$current_control_interface" = "$baseline_control_interface" \
    && test "$current_magic_interface" = "$baseline_magic_interface" \
    && tailscale_direct_ping \
    || fail "Tailscale control path was not restored after the gate"
  test "$(network_control_hash)" = "$network_before" \
    || fail "system proxy/DNS/default-route/interface state was not restored"
  printf 'run_result=passed\n'
  printf 'engine=%s\n' "$engine"
  printf 'effective_xctestrun_sha256=%s\n' "$expected_effective_sha"
  printf 'control_watchdog=%s\n' "$(test "$engine" = tun && printf passed || printf not-applicable)"
  printf 'network_control_restored=yes\n'
}

command=${1:-}
case "$command" in
  package)
    shift
    package_runner "$@"
    ;;
  prepare)
    shift
    prepare_runner "$@"
    ;;
  run)
    shift
    run_prepared_runner "$@"
    ;;
  *)
    usage
    exit 64
    ;;
esac
