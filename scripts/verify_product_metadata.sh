#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:-source}
PRODUCTS_DIR=${2:-"$ROOT/.derivedData/Build/Products/Debug"}
CORE="$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a"
ENTITLEMENTS="$ROOT/Config/AetherRoute.entitlements"
INFO="$ROOT/Config/App-Info.plist"

fail() {
  echo "Independent product metadata verification failed: $*" >&2
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

verify_distribution_metadata() {
  info=$1
  channel=$(plist_value "$info" AetherRouteReleaseChannel)
  product=$(plist_value "$info" AetherRouteDistributionProductIdentifier)
  license_url=$(plist_value "$info" AetherRouteLicenseServiceURL)
  update_url=$(plist_value "$info" AetherRouteUpdateManifestURL)
  public_key=$(plist_value "$info" AetherRouteDistributionSigningPublicKey)

  if [ "$product" = '$(AETHERROUTE_DISTRIBUTION_PRODUCT_ID)' ] && \
     [ "$license_url" = '$(AETHERROUTE_LICENSE_SERVICE_URL)' ] && \
     [ "$update_url" = '$(AETHERROUTE_UPDATE_MANIFEST_URL)' ] && \
     [ "$public_key" = '$(AETHERROUTE_DISTRIBUTION_PUBLIC_KEY)' ]; then
    return
  fi
  if [ -z "$license_url$update_url$public_key" ]; then
    test "$channel" != stable || \
      fail "stable release is missing license/update configuration"
    return
  fi
  test -n "$product" || fail "distribution product identifier is empty"
  for url in "$license_url" "$update_url"; do
    case "$url" in
      https://?*) ;;
      *) fail "distribution services must use HTTPS" ;;
    esac
    if printf '%s\n' "$url" | grep -Eq '[@#[:space:]]'; then
      fail "distribution service URL contains credentials, fragment, or whitespace"
    fi
  done
  decoded_key_bytes=$(printf '%s' "$public_key" \
    | base64 -D 2>/dev/null | wc -c | tr -d ' ')
  test "$decoded_key_bytes" -eq 32 || \
    fail "distribution signing public key must decode to 32 bytes"
}

verify_source() {
  plutil -lint "$ENTITLEMENTS" "$INFO" >/dev/null
  verify_release_metadata "$INFO"
  verify_distribution_metadata "$INFO"
  test "$(plist_value "$INFO" AetherRouteAuthorName)" = \
    '陈艳男' || fail "author name is incorrect"
  test "$(plist_value "$INFO" AetherRouteAuthorRomanizedName)" = \
    'ChenYanNan' || fail "romanized author name is incorrect"
  test "$(plist_value "$INFO" NSHumanReadableCopyright)" = \
    'Created by 陈艳男 (ChenYanNan)' || \
    fail "author attribution is incorrect"
  test -n "$(plist_value "$INFO" NSSystemExtensionUsageDescription)" || \
    fail "host System Extension usage description is empty"
  test "$(plist_value "$ENTITLEMENTS" \
    com.apple.developer.networking.networkextension:0)" = \
    app-proxy-provider || fail "host app-proxy entitlement is missing"
  test "$(plist_value "$ENTITLEMENTS" \
    com.apple.developer.networking.networkextension:1)" = \
    packet-tunnel-provider || fail "host packet-tunnel entitlement is missing"
  test "$(plist_value "$ENTITLEMENTS" com.apple.security.app-sandbox)" = true || \
    fail "host sandbox entitlement is missing"
  test "$(plist_value "$ENTITLEMENTS" \
    com.apple.security.files.user-selected.read-write)" = true || \
    fail "host user-selected read-write entitlement is missing"
  if /usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.files.user-selected.read-only' \
    "$ENTITLEMENTS" >/dev/null 2>&1; then
    fail "host must not request both read-only and read-write file access"
  fi
  test "$(plist_value "$INFO" \
    UTExportedTypeDeclarations:0:UTTypeIdentifier)" = \
    '$(AETHERROUTE_PROFILE_ARCHIVE_TYPE)' || \
    fail "portable archive type declaration is missing"
  test "$(plist_value "$INFO" \
    CFBundleDocumentTypes:0:LSItemContentTypes:0)" = \
    '$(AETHERROUTE_PROFILE_ARCHIVE_TYPE)' || \
    fail "portable archive document type is missing"

  test -f "$CORE" || fail "Direct arm64 core artifact is missing"
  test "$(lipo -archs "$CORE")" = arm64 || \
    fail "Direct core must contain arm64 only"
  core_member=$(ar -t "$CORE" \
    | sed -n '/^clashrs\.clashrs\..*\.rcgu\.o$/ { p; q; }')
  test -n "$core_member" || fail "Direct core Mach-O member is missing"
  symbol_directory=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-direct-symbols.XXXXXX")
  cleanup_symbol_directory() {
    find "$symbol_directory" -depth -delete 2>/dev/null || true
  }
  trap cleanup_symbol_directory EXIT HUP INT TERM
  (
    cd "$symbol_directory"
    ar -x "$CORE" "$core_member"
  ) || fail "could not extract Direct core Mach-O member"
  nm -gU "$symbol_directory/$core_member" > "$symbol_directory/symbols.txt"
  for symbol in \
    clash_start_packet_flow \
    clash_start_packet_flow_with_mode \
    clash_start_packet_flow_with_policy_v1 \
    clash_shutdown \
    clash_free_string \
    clash_install_packet_flow \
    clash_packet_input \
    clash_packet_flow_ready \
    clash_packet_selector_snapshot_v1 \
    clash_packet_selector_select_v1 \
    clash_packet_selector_latency_v1 \
    clash_packet_selector_active_latency_v1 \
    clash_packet_telemetry_snapshot_v1 \
    clash_uninstall_packet_flow
  do
    awk '{print $NF}' "$symbol_directory/symbols.txt" \
      | grep -qx "_$symbol" || \
      fail "Direct core is missing PacketFlow ABI symbol $symbol"
  done
  nm -u "$symbol_directory/$core_member" > "$symbol_directory/undefined.txt"
  if awk '{print $NF}' "$symbol_directory/undefined.txt" \
    | grep -Eq '^_(fork|execv|execve|execvp|posix_spawn|posix_spawnp|dlsym)$'; then
    fail "Direct core references process launch or dynamic loading"
  fi
  find "$symbol_directory" -depth -delete
  trap - EXIT HUP INT TERM

  grep -F 'Core/Artifacts/macos-arm64/libclashrs-direct.a' \
    "$ROOT/project.yml" >/dev/null || \
    fail "Packet Tunnel target is not linked to the isolated Direct core"
  grep -F 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) AETHERROUTE_INDEPENDENT' \
    "$ROOT/project.yml" >/dev/null || \
    fail "Direct Swift compilation boundary is missing"
}

verify_built() {
  app="$PRODUCTS_DIR/AetherRoute.app"
  app_info="$app/Contents/Info.plist"
  packet_bundle_id=$(plist_value "$app_info" AetherRouteTunnelBundleIdentifier)
  transparent_bundle_id=$(plist_value "$app_info" \
    AetherRouteTransparentProxyBundleIdentifier)
  packet="$app/Contents/Library/SystemExtensions/$packet_bundle_id.systemextension"
  transparent="$app/Contents/Library/SystemExtensions/$transparent_bundle_id.systemextension"
  packet_info="$packet/Contents/Info.plist"
  transparent_info="$transparent/Contents/Info.plist"
  kit_info="$app/Contents/Frameworks/AetherRouteKit.framework/Resources/Info.plist"
  packet_executable=$(plist_value "$packet_info" CFBundleExecutable)
  packet_binary="$packet/Contents/MacOS/$packet_executable"
  packet_debug_binary="$packet/Contents/MacOS/$packet_executable.debug.dylib"
  packet_kit_binary="$packet/Contents/Frameworks/AetherRouteKit.framework/Versions/A/AetherRouteKit"

  test -d "$app" || fail "AetherRoute app is missing at $app"
  test -d "$packet" || fail "Packet Tunnel extension is not embedded"
  test -d "$transparent" || fail "Transparent Proxy extension is not embedded"
  test "$(plist_value "$packet_info" CFBundlePackageType)" = SYSX || \
    fail "Packet Tunnel is not packaged as a system extension"
  test "$(plist_value "$transparent_info" CFBundlePackageType)" = SYSX || \
    fail "Transparent Proxy is not packaged as a system extension"
  verify_release_metadata "$app_info"
  verify_distribution_metadata "$app_info"
  test "$(plist_value "$app_info" CFBundleDisplayName)" = \
    'AetherRoute' || fail "independent-distribution display name is incorrect"
  test "$(plist_value "$app_info" AetherRouteAuthorName)" = \
    '陈艳男' || fail "built Direct author name is incorrect"
  test "$(plist_value "$app_info" AetherRouteAuthorRomanizedName)" = \
    'ChenYanNan' || fail "built Direct romanized author name is incorrect"
  test "$(plist_value "$app_info" NSHumanReadableCopyright)" = \
    'Created by 陈艳男 (ChenYanNan)' || \
    fail "built Direct author attribution is incorrect"
  test -n "$(plist_value "$app_info" NSSystemExtensionUsageDescription)" || \
    fail "built host System Extension usage description is empty"
  app_bundle_id=$(plist_value "$app_info" CFBundleIdentifier)
  packet_bundle_id=$(plist_value "$packet_info" CFBundleIdentifier)
  transparent_bundle_id=$(plist_value "$transparent_info" CFBundleIdentifier)
  test "$packet_bundle_id" = \
    "$(plist_value "$app_info" AetherRouteTunnelBundleIdentifier)" || \
    fail "runtime Packet Tunnel identifier differs from the embedded extension"
  test "$transparent_bundle_id" = \
    "$(plist_value "$app_info" AetherRouteTransparentProxyBundleIdentifier)" || \
    fail "runtime Transparent Proxy identifier differs from the embedded extension"
  test "$(plist_value "$app_info" AetherRouteAppGroup)" = \
    "group.$app_bundle_id" || \
    fail "Direct App Group is not derived from the host bundle identifier"
  test "$(plist_value "$app_info" AetherRouteKeychainAccessGroupSuffix)" = \
    "$app_bundle_id.shared" || \
    fail "Direct Keychain suffix is not derived from the host bundle identifier"
  for identity_key in \
    AetherRouteAppGroup \
    AetherRouteKeychainAccessGroupSuffix \
    AetherRouteProfileArchiveTypeIdentifier \
    AetherRouteTransparentProxyBundleIdentifier \
    AetherRouteTunnelBundleIdentifier
  do
    test "$(plist_value "$kit_info" "$identity_key")" = \
      "$(plist_value "$app_info" "$identity_key")" || \
      fail "AetherRouteKit runtime identity $identity_key differs from Direct"
  done
  test "$(plist_value "$packet_info" \
    NetworkExtension:NEProviderClasses:com.apple.networkextension.packet-tunnel)" = \
    AetherRoutePacketTunnel.PacketTunnelProvider || \
    fail "Packet Tunnel system-extension provider class is incorrect"
  test "$(plist_value "$transparent_info" \
    NetworkExtension:NEProviderClasses:com.apple.networkextension.app-proxy)" = \
    AetherRouteTransparentProxy.TransparentProxyProvider || \
    fail "Transparent Proxy system-extension provider class is incorrect"
  test "$(lipo -archs "$packet_binary")" = arm64 || \
    fail "Packet Tunnel launcher must contain arm64 only"
  test -f "$packet_kit_binary" || \
    fail "Packet Tunnel is missing its embedded AetherRouteKit framework"
  otool -L "$packet_binary" | grep -F \
    '@rpath/AetherRouteKit.framework/Versions/A/AetherRouteKit' >/dev/null || \
    fail "Packet Tunnel does not link the embedded AetherRouteKit framework"

  inspected_binary=$packet_binary
  if [ -f "$packet_debug_binary" ]; then
    inspected_binary=$packet_debug_binary
  fi
  for symbol in \
    clash_start_packet_flow_with_mode \
    clash_start_packet_flow_with_policy_v1 \
    clash_shutdown \
    clash_install_packet_flow \
    clash_packet_input \
    clash_packet_flow_ready \
    clash_packet_selector_snapshot_v1 \
    clash_packet_selector_select_v1 \
    clash_packet_selector_latency_v1 \
    clash_packet_selector_active_latency_v1 \
    clash_packet_telemetry_snapshot_v1 \
    clash_uninstall_packet_flow
  do
    nm "$inspected_binary" 2>/dev/null | awk '{print $NF}' \
      | grep -qx "_$symbol" || \
      fail "built Packet Tunnel does not define $symbol"
  done
  if nm -u "$inspected_binary" 2>/dev/null | awk '{print $NF}' \
    | grep -Eq '^_(fork|execv|execve|execvp|posix_spawn|posix_spawnp|dlsym)$'; then
    fail "built Packet Tunnel references process launch or dynamic loading"
  fi
}

case "$MODE" in
  source)
    verify_source
    ;;
  built)
    verify_source
    verify_built
    ;;
  *)
    fail "unknown mode '$MODE' (expected source or built)"
    ;;
esac

echo "Independent product metadata verification passed ($MODE)."
