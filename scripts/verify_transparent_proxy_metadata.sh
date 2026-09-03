#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:-source}
PRODUCTS_DIR=${2:-"$ROOT/.derivedData/Build/Products/Debug"}

APP_INFO="$ROOT/Config/App-Info.plist"
EXTENSION_INFO="$ROOT/Config/PacketTunnel-Info.plist"
TRANSPARENT_INFO="$ROOT/Config/TransparentProxy-Info.plist"
APP_PRIVACY="$ROOT/Config/App/PrivacyInfo.xcprivacy"
KIT_PRIVACY="$ROOT/Config/Kit/PrivacyInfo.xcprivacy"
EXTENSION_PRIVACY="$ROOT/Config/PacketTunnel/PrivacyInfo.xcprivacy"
TRANSPARENT_PRIVACY="$ROOT/Config/TransparentProxy/PrivacyInfo.xcprivacy"
APP_INFO_PLIST_EN="$ROOT/Sources/AetherRouteApp/en.lproj/InfoPlist.strings"
APP_INFO_PLIST_ZH="$ROOT/Sources/AetherRouteApp/zh-Hans.lproj/InfoPlist.strings"
PACKET_INFO_PLIST_EN="$ROOT/Sources/AetherRoutePacketTunnel/en.lproj/InfoPlist.strings"
PACKET_INFO_PLIST_ZH="$ROOT/Sources/AetherRoutePacketTunnel/zh-Hans.lproj/InfoPlist.strings"
TRANSPARENT_INFO_PLIST_EN="$ROOT/Sources/AetherRouteTransparentProxy/en.lproj/InfoPlist.strings"
TRANSPARENT_INFO_PLIST_ZH="$ROOT/Sources/AetherRouteTransparentProxy/zh-Hans.lproj/InfoPlist.strings"
KEYCHAIN_ACCESS_GROUP_TEMPLATE='$(AppIdentifierPrefix)$(AETHERROUTE_KEYCHAIN_GROUP_SUFFIX)'
APP_GROUP_TEMPLATE='$(AETHERROUTE_APP_GROUP)'
PROFILE_ARCHIVE_TYPE_TEMPLATE='$(AETHERROUTE_PROFILE_ARCHIVE_TYPE)'
CORE_ARTIFACT="$ROOT/Core/Artifacts/macos-arm64/libclashrs.a"
FLOW_ABI_SYMBOLS='clash_flow_status_message
clash_flow_engine_create
clash_flow_engine_set_routing_mode_v1
clash_flow_engine_destroy
clash_flow_selector_snapshot_v1
clash_flow_selector_select_v1
clash_flow_selector_latency_v1
clash_flow_selector_active_latency_v1
clash_flow_telemetry_snapshot_v1
clash_flow_tcp_create
clash_flow_udp_create
clash_flow_activate
clash_flow_tcp_write
clash_flow_tcp_finish_write
clash_flow_tcp_read
clash_flow_udp_write
clash_flow_udp_read
clash_flow_cancel
clash_flow_destroy'

fail() {
  echo "Transparent Proxy metadata verification failed: $*" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

verify_release_metadata() {
  info=$1
  channel=$(plist_value "$info" AetherRouteReleaseChannel)
  timestamp=$(plist_value "$info" AetherRouteReleaseTimestamp)
  if [ "$channel" = '$(AETHERROUTE_RELEASE_CHANNEL)' ] && \
     [ "$timestamp" = '$(AETHERROUTE_RELEASE_TIMESTAMP)' ]; then
    return
  fi
  case "$channel" in
    development|beta|stable) ;;
    *) fail "invalid release channel in $info" ;;
  esac
  if [ -n "$timestamp" ]; then
    printf '%s\n' "$timestamp" \
      | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
      || fail "release timestamp must be UTC RFC 3339 in $info"
  elif [ "$channel" = stable ]; then
    fail "stable release timestamp is empty in $info"
  fi
}

assert_absent() {
  if /usr/libexec/PlistBuddy -c "Print :$2" "$1" >/dev/null 2>&1; then
    fail "$2 must be absent from $1"
  fi
}

verify_privacy_manifest() {
  manifest=$1
  accessed_api_policy=${2:-none}
  plutil -lint "$manifest" >/dev/null
  test "$(plist_value "$manifest" NSPrivacyTracking)" = false || \
    fail "NSPrivacyTracking must be false in $manifest"
  test "$(plutil -extract NSPrivacyCollectedDataTypes json -o - "$manifest")" = '[]' || \
    fail "NSPrivacyCollectedDataTypes must be an empty array in $manifest"
  assert_absent "$manifest" NSPrivacyTrackingDomains
  case "$accessed_api_policy" in
    user-defaults)
      test "$(plist_value "$manifest" \
        NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPIType)" = \
        NSPrivacyAccessedAPICategoryUserDefaults || \
        fail "UserDefaults API category is missing from $manifest"
      test "$(plist_value "$manifest" \
        NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPITypeReasons:0)" = \
        CA92.1 || fail "UserDefaults reason CA92.1 is missing from $manifest"
      if /usr/libexec/PlistBuddy -c \
        'Print :NSPrivacyAccessedAPITypes:1' "$manifest" >/dev/null 2>&1; then
        fail "unexpected additional accessed API category in $manifest"
      fi
      ;;
    none)
      assert_absent "$manifest" NSPrivacyAccessedAPITypes
      ;;
    *)
      fail "unknown accessed API policy '$accessed_api_policy'"
      ;;
  esac
}

verify_core_artifact() {
  test -f "$CORE_ARTIFACT" || fail "arm64 core artifact is missing"
  test "$(lipo -archs "$CORE_ARTIFACT")" = arm64 || \
    fail "core artifact must contain arm64 only"

  # Apple nm cannot parse some Rust 1.96/LLVM 22 compiler_builtins members.
  # Inspect this crate's Mach-O member directly so an unrelated archive member
  # cannot turn a valid Flow ABI into a false-negative verification result.
  core_member=$(ar -t "$CORE_ARTIFACT" \
    | sed -n '/^clashrs\.clashrs\..*\.rcgu\.o$/ { p; q; }')
  test -n "$core_member" || fail "core artifact does not contain the clashrs Mach-O member"
  core_symbols_directory=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-core-symbols.XXXXXX")
  cleanup_core_symbols_directory() {
    find "$core_symbols_directory" -depth -delete 2>/dev/null || true
  }
  trap cleanup_core_symbols_directory EXIT HUP INT TERM
  (
    cd "$core_symbols_directory"
    ar -x "$CORE_ARTIFACT" "$core_member"
  ) || fail "could not extract the clashrs Mach-O member"
  nm -gU "$core_symbols_directory/$core_member" \
    > "$core_symbols_directory/symbols.txt" || \
    fail "could not inspect the clashrs Mach-O member"
  for symbol in $FLOW_ABI_SYMBOLS; do
    awk '{print $NF}' "$core_symbols_directory/symbols.txt" \
      | grep -qx "_$symbol" || \
      fail "core artifact is missing required Flow ABI symbol $symbol"
  done
  flow_symbol_count=$(awk '{print $NF}' \
    "$core_symbols_directory/symbols.txt" | grep -Ec '^_clash_flow_' || true)
  test "$flow_symbol_count" -eq 19 || \
    fail "core artifact exposes an unexpected Flow ABI count: $flow_symbol_count"
  if awk '{print $NF}' "$core_symbols_directory/symbols.txt" \
    | grep -Eq '^_clash_(start|shutdown|packet_|push_packet_|install_packet_|uninstall_packet_|is_packet_)'; then
    fail "core artifact exposes a legacy process or PacketFlow ABI"
  fi
  nm -u "$core_symbols_directory/$core_member" \
    > "$core_symbols_directory/undefined.txt" || \
    fail "could not inspect core artifact undefined symbols"
  if awk '{print $NF}' "$core_symbols_directory/undefined.txt" \
    | grep -Eq '^_(fork|execv|execve|execvp|posix_spawn|posix_spawnp|dlsym)$'; then
    fail "core artifact entry object references process launch or dynamic loading"
  fi
  find "$core_symbols_directory" -depth -delete
  trap - EXIT HUP INT TERM
  grep -F -- \
    '-Wl,-force_load,$(SRCROOT)/Core/Artifacts/macos-arm64/libclashrs.a' \
    "$ROOT/project.yml" >/dev/null || \
    fail "FlowCoreBridge does not force-load the reviewed core artifact"
  if grep -F -- '-Wl,-undefined,dynamic_lookup' \
    "$ROOT/project.yml" >/dev/null; then
    fail "unbounded dynamic symbol lookup is forbidden"
  fi
}

verify_source() {
  verify_core_artifact
  plutil -lint "$APP_INFO" "$EXTENSION_INFO" "$TRANSPARENT_INFO" >/dev/null
  verify_privacy_manifest "$APP_PRIVACY" user-defaults
  verify_privacy_manifest "$KIT_PRIVACY" user-defaults
  verify_privacy_manifest "$EXTENSION_PRIVACY"
  verify_privacy_manifest "$TRANSPARENT_PRIVACY"
  verify_release_metadata "$APP_INFO"

  test "$(plist_value "$EXTENSION_INFO" CFBundlePackageType)" = SYSX || \
    fail "Packet Tunnel source plist must declare the SYSX package type"
  test "$(plist_value "$TRANSPARENT_INFO" CFBundlePackageType)" = SYSX || \
    fail "Transparent Proxy source plist must declare the SYSX package type"

  for info in "$APP_INFO" "$EXTENSION_INFO" "$TRANSPARENT_INFO"; do
    system_extension_description=$(plist_value "$info" \
      NSSystemExtensionUsageDescription)
    test -n "$system_extension_description" || \
      fail "System Extension usage description is empty in $info"
  done
  for localized_info in \
    "$APP_INFO_PLIST_EN" \
    "$APP_INFO_PLIST_ZH" \
    "$PACKET_INFO_PLIST_EN" \
    "$PACKET_INFO_PLIST_ZH" \
    "$TRANSPARENT_INFO_PLIST_EN" \
    "$TRANSPARENT_INFO_PLIST_ZH"
  do
    plutil -lint "$localized_info" >/dev/null
    test -n "$(plist_value "$localized_info" \
      NSSystemExtensionUsageDescription)" || \
      fail "localized System Extension usage description is empty in $localized_info"
  done

  test "$(plist_value "$APP_INFO" CFBundleShortVersionString)" = \
    '$(MARKETING_VERSION)' || fail "host marketing version is not build-setting driven"
  test "$(plist_value "$EXTENSION_INFO" CFBundleShortVersionString)" = \
    '$(MARKETING_VERSION)' || fail "extension marketing version is not build-setting driven"
  test "$(plist_value "$APP_INFO" CFBundleVersion)" = \
    '$(CURRENT_PROJECT_VERSION)' || fail "host build number is not build-setting driven"
  test "$(plist_value "$APP_INFO" AetherRouteAuthorName)" = \
    '陈艳男' || fail "host author name is incorrect"
  test "$(plist_value "$APP_INFO" AetherRouteAuthorRomanizedName)" = \
    'ChenYanNan' || fail "host romanized author name is incorrect"
  test "$(plist_value "$APP_INFO" NSHumanReadableCopyright)" = \
    'Created by 陈艳男 (ChenYanNan)' || \
    fail "host author attribution is incorrect"
  test "$(plist_value "$EXTENSION_INFO" CFBundleVersion)" = \
    '$(CURRENT_PROJECT_VERSION)' || fail "extension build number is not build-setting driven"
  test "$(plist_value "$TRANSPARENT_INFO" CFBundleShortVersionString)" = \
    '$(MARKETING_VERSION)' || fail "transparent extension marketing version is not build-setting driven"
  test "$(plist_value "$TRANSPARENT_INFO" CFBundleVersion)" = \
    '$(CURRENT_PROJECT_VERSION)' || fail "transparent extension build number is not build-setting driven"
  test "$(plist_value "$EXTENSION_INFO" \
    NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel)" = \
    '$(PRODUCT_MODULE_NAME).PacketTunnelProvider' || \
    fail "packet system-extension provider class is incorrect"
  test "$(plist_value "$TRANSPARENT_INFO" \
    NetworkExtension:NEProviderClasses:com.apple.networkextension.app-proxy)" = \
    '$(PRODUCT_MODULE_NAME).TransparentProxyProvider' || \
    fail "transparent system-extension provider class is incorrect"

  for info in "$APP_INFO" "$EXTENSION_INFO" "$TRANSPARENT_INFO"; do
    test "$(plist_value "$info" AetherRouteKeychainAccessGroup)" = \
      "$KEYCHAIN_ACCESS_GROUP_TEMPLATE" || \
      fail "shared Keychain access group is not build-setting driven in $info"
    test "$(plist_value "$info" AetherRouteAppGroup)" = \
      "$APP_GROUP_TEMPLATE" || \
      fail "App Group is not build-setting driven in $info"
    test "$(plist_value "$info" AetherRouteKeychainAccessGroupSuffix)" = \
      '$(AETHERROUTE_KEYCHAIN_GROUP_SUFFIX)' || \
      fail "Keychain suffix is not build-setting driven in $info"
  done

  local_network_description=$(plist_value "$APP_INFO" NSLocalNetworkUsageDescription)
  test -n "$local_network_description" || fail "host local-network purpose string is empty"
  test "$(plist_value "$APP_INFO" \
    UTExportedTypeDeclarations:0:UTTypeIdentifier)" = \
    "$PROFILE_ARCHIVE_TYPE_TEMPLATE" || \
    fail "portable archive type declaration is missing"
  test "$(plist_value "$APP_INFO" \
    UTExportedTypeDeclarations:0:UTTypeConformsTo:0)" = public.data || \
    fail "portable archive type must conform to public.data"
  test "$(plist_value "$APP_INFO" \
    UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0)" = \
    aetherroute || fail "portable archive filename extension is missing"
  test "$(plist_value "$APP_INFO" \
    CFBundleDocumentTypes:0:LSItemContentTypes:0)" = \
    "$PROFILE_ARCHIVE_TYPE_TEMPLATE" || \
    fail "portable archive document type is missing"
  assert_absent "$APP_INFO" NSBonjourServices
  assert_absent "$EXTENSION_INFO" NSLocalNetworkUsageDescription
  assert_absent "$EXTENSION_INFO" NSBonjourServices
  assert_absent "$TRANSPARENT_INFO" NSLocalNetworkUsageDescription
  assert_absent "$TRANSPARENT_INFO" NSBonjourServices
}

verify_built_products() {
  app="$PRODUCTS_DIR/AetherRoute.app"
  app_built_info="$app/Contents/Info.plist"
  transparent_bundle_id=$(plist_value "$app_built_info" \
    AetherRouteTransparentProxyBundleIdentifier)
  packet_bundle_id=$(plist_value "$app_built_info" \
    AetherRouteTunnelBundleIdentifier)
  transparent_extension="$app/Contents/Library/SystemExtensions/$transparent_bundle_id.systemextension"
  packet_extension="$app/Contents/Library/SystemExtensions/$packet_bundle_id.systemextension"
  app_manifest="$app/Contents/Resources/PrivacyInfo.xcprivacy"
  kit_manifest="$app/Contents/Frameworks/AetherRouteKit.framework/Resources/PrivacyInfo.xcprivacy"
  transparent_manifest="$transparent_extension/Contents/Resources/PrivacyInfo.xcprivacy"
  packet_built_info="$packet_extension/Contents/Info.plist"
  transparent_built_info="$transparent_extension/Contents/Info.plist"
  kit_built_info="$app/Contents/Frameworks/AetherRouteKit.framework/Resources/Info.plist"
  transparent_frameworks="$transparent_extension/Contents/Frameworks"
  flow_core="$transparent_frameworks/AetherRouteFlowCoreBridge.framework/AetherRouteFlowCoreBridge"

  test -d "$app" || fail "host app not found at $app"
  test -d "$transparent_extension" || \
    fail "embedded transparent extension not found at $transparent_extension"
  test -d "$packet_extension" || \
    fail "independent app must embed the Packet Tunnel extension"
  test "$(plist_value "$packet_built_info" CFBundlePackageType)" = SYSX || \
    fail "Packet Tunnel is not packaged as a system extension"
  test "$(plist_value "$transparent_built_info" CFBundlePackageType)" = SYSX || \
    fail "Transparent Proxy is not packaged as a system extension"
  for info in \
    "$app_built_info" \
    "$packet_built_info" \
    "$transparent_built_info"
  do
    test -n "$(plist_value "$info" NSSystemExtensionUsageDescription)" || \
      fail "built System Extension usage description is empty in $info"
  done
  test -f "$flow_core" || \
    fail "embedded strong-linked FlowCoreBridge framework is missing"
  test -f "$app_manifest" || fail "host privacy manifest was not packaged"
  test -f "$kit_manifest" || fail "kit privacy manifest was not packaged"
  test -f "$transparent_manifest" || \
    fail "transparent extension privacy manifest was not packaged"
  cmp -s "$APP_PRIVACY" "$app_manifest" || fail "host packaged privacy manifest differs from source"
  cmp -s "$KIT_PRIVACY" "$kit_manifest" || fail "kit packaged privacy manifest differs from source"
  cmp -s "$TRANSPARENT_PRIVACY" "$transparent_manifest" || \
    fail "transparent extension packaged privacy manifest differs from source"
  verify_privacy_manifest "$app_manifest" user-defaults
  verify_privacy_manifest "$kit_manifest" user-defaults
  verify_privacy_manifest "$transparent_manifest"
  verify_release_metadata "$app_built_info"

  app_marketing_version=$(plist_value "$app_built_info" CFBundleShortVersionString)
  app_build_number=$(plist_value "$app_built_info" CFBundleVersion)
  transparent_marketing_version=$(plist_value "$transparent_built_info" CFBundleShortVersionString)
  transparent_build_number=$(plist_value "$transparent_built_info" CFBundleVersion)
  app_keychain_group=$(plist_value "$app_built_info" AetherRouteKeychainAccessGroup)
  transparent_keychain_group=$(plist_value "$transparent_built_info" AetherRouteKeychainAccessGroup)
  app_keychain_suffix=$(plist_value "$app_built_info" AetherRouteKeychainAccessGroupSuffix)
  app_group=$(plist_value "$app_built_info" AetherRouteAppGroup)
  transparent_app_group=$(plist_value "$transparent_built_info" AetherRouteAppGroup)
  app_bundle_id=$(plist_value "$app_built_info" CFBundleIdentifier)
  transparent_bundle_id=$(plist_value "$transparent_built_info" CFBundleIdentifier)
  configured_transparent_bundle=$(plist_value \
    "$app_built_info" AetherRouteTransparentProxyBundleIdentifier)
  profile_archive_type=$(plist_value \
    "$app_built_info" AetherRouteProfileArchiveTypeIdentifier)

  test -n "$app_marketing_version" || fail "built host marketing version is empty"
  test -n "$app_build_number" || fail "built host build number is empty"
  test "$(plist_value "$app_built_info" AetherRouteAuthorName)" = \
    '陈艳男' || fail "built host author name is incorrect"
  test "$(plist_value "$app_built_info" AetherRouteAuthorRomanizedName)" = \
    'ChenYanNan' || fail "built host romanized author name is incorrect"
  test "$(plist_value "$app_built_info" NSHumanReadableCopyright)" = \
    'Created by 陈艳男 (ChenYanNan)' || \
    fail "built host author attribution is incorrect"
  test "$app_marketing_version" = "$transparent_marketing_version" || \
    fail "host and transparent extension marketing versions differ"
  test "$app_build_number" = "$transparent_build_number" || \
    fail "host and transparent extension build numbers differ"
  test "$app_keychain_group" = "$transparent_keychain_group" || \
    fail "host and transparent extension Keychain access groups differ"
  test "$app_group" = "$transparent_app_group" || \
    fail "host and transparent extension App Groups differ"
  test -n "$app_keychain_suffix" || fail "built Keychain suffix is empty"
  test -n "$app_group" || fail "built App Group is empty"
  test "$transparent_bundle_id" = "$configured_transparent_bundle" || \
    fail "runtime Transparent Proxy identifier differs from the embedded extension"
  test "$app_group" = "group.$app_bundle_id" || \
    fail "built App Group is not derived from the host bundle identifier"
  test "$app_keychain_suffix" = "$app_bundle_id.shared" || \
    fail "built Keychain suffix is not derived from the host bundle identifier"
  test "$profile_archive_type" = "$app_bundle_id.profile-archive" || \
    fail "built profile archive type is not derived from the host bundle identifier"
  for identity_key in \
    AetherRouteAppGroup \
    AetherRouteKeychainAccessGroupSuffix \
    AetherRouteProfileArchiveTypeIdentifier \
    AetherRouteTransparentProxyBundleIdentifier \
    AetherRouteTunnelBundleIdentifier
  do
    test "$(plist_value "$kit_built_info" "$identity_key")" = \
      "$(plist_value "$app_built_info" "$identity_key")" || \
      fail "AetherRouteKit runtime identity $identity_key differs from the host"
  done
  case "$app_keychain_group" in
    *'$('*) fail "built Keychain access group still contains a build setting" ;;
    *"$app_keychain_suffix") ;;
    *) fail "built Keychain access group has an unexpected suffix" ;;
  esac
  test "$(plist_value "$packet_built_info" \
    NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel)" = \
    AetherRoutePacketTunnel.PacketTunnelProvider || \
    fail "built packet system-extension provider class is incorrect"
  test "$(plist_value "$transparent_built_info" \
    NetworkExtension:NEProviderClasses:com.apple.networkextension.app-proxy)" = \
    AetherRouteTransparentProxy.TransparentProxyProvider || \
    fail "built transparent system-extension provider class is incorrect"
  test "$(plist_value "$app_built_info" NSLocalNetworkUsageDescription)" = \
    "$(plist_value "$APP_INFO" NSLocalNetworkUsageDescription)" || \
    fail "built host local-network purpose string differs from source"
  assert_absent "$app_built_info" NSBonjourServices
  assert_absent "$transparent_built_info" NSBonjourServices

  for symbol in $FLOW_ABI_SYMBOLS; do
    nm -gU "$flow_core" 2>/dev/null \
      | awk '{print $NF}' \
      | grep -qx "_$symbol" || \
      fail "built FlowCoreBridge does not define $symbol"
    if nm -u "$flow_core" 2>/dev/null \
      | awk '{print $NF}' \
      | grep -qx "_$symbol"; then
      fail "built FlowCoreBridge leaves $symbol undefined"
    fi
  done
  if nm -gU "$flow_core" 2>/dev/null \
    | awk '{print $NF}' \
    | grep -Eq '^_clash_(start|shutdown|packet_|push_packet_|install_packet_|uninstall_packet_|is_packet_)'; then
    fail "built FlowCoreBridge exposes a legacy process or PacketFlow ABI"
  fi
  if nm -u "$flow_core" 2>/dev/null \
    | awk '{print $NF}' \
    | grep -Eq '^_(fork|execv|execve|execvp|posix_spawn|posix_spawnp|dlsym)$'; then
    fail "built FlowCoreBridge references process launch or dynamic loading"
  fi

  harness_directory=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-flow-abi.XXXXXX")
  harness="$harness_directory/flow-abi-load"
  cleanup_harness_directory() {
    find "$harness_directory" -depth -delete 2>/dev/null || true
  }
  trap cleanup_harness_directory EXIT HUP INT TERM
  clang \
    -arch arm64 \
    -mmacosx-version-min=15.0 \
    -Wall -Wextra -Werror \
    -I "$ROOT/Sources/AetherRouteFlowABI/include" \
    -I "$ROOT/Core/Headers" \
    -F "$transparent_frameworks" \
    -Wl,-rpath,"$transparent_frameworks" \
    "$ROOT/Tests/FlowABI/flow_abi_load.c" \
    -framework AetherRouteFlowCoreBridge \
    -o "$harness"
  DYLD_FRAMEWORK_PATH="$transparent_frameworks" "$harness" || \
    fail "the versioned AetherRoute Flow ABI tables did not load"
  find "$harness_directory" -depth -delete
  trap - EXIT HUP INT TERM
}

case "$MODE" in
  source)
    verify_source
    ;;
  built)
    verify_source
    verify_built_products
    ;;
  *)
    fail "unknown mode '$MODE' (expected source or built)"
    ;;
esac

echo "Transparent Proxy metadata verification passed ($MODE)."
