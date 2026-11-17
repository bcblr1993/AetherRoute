#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-mac-tests.XXXXXX")
trap 'find "$TEST_TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
ARCH=$(uname -m)

# Build AetherRouteKit.framework from the current checkout with an embedded
# Info.plist so AppConstants resolves identity keys without a host bundle.
FW="$TEST_TEMP/AetherRouteKit.framework"
mkdir -p "$FW/Versions/A/Modules/AetherRouteKit.swiftmodule" "$FW/Versions/A/Resources"
cat > "$FW/Versions/A/Resources/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.aetherroute.desktop.kit</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>3.0.2</string>
  <key>CFBundleVersion</key>
  <string>2026111702</string>
  <key>AetherRouteAppGroup</key>
  <string>group.com.aetherroute.desktop</string>
  <key>AetherRouteKeychainAccessGroupSuffix</key>
  <string>com.aetherroute.desktop.shared</string>
  <key>AetherRouteTunnelBundleIdentifier</key>
  <string>com.aetherroute.desktop.tunnel</string>
  <key>AetherRouteTransparentProxyBundleIdentifier</key>
  <string>com.aetherroute.desktop.transparent-proxy</string>
  <key>AetherRouteProfileArchiveTypeIdentifier</key>
  <string>com.aetherroute.desktop.profile-archive</string>
</dict>
</plist>
EOF
ln -s A "$FW/Versions/Current"
ln -s Versions/Current/AetherRouteKit "$FW/AetherRouteKit"
ln -s Versions/Current/Modules "$FW/Modules"
ln -s Versions/Current/Resources "$FW/Resources"

xcrun --sdk macosx swiftc -sdk "$SDK_PATH" -swift-version 6 -warnings-as-errors \
  -emit-library -emit-module -module-name AetherRouteKit \
  -Xlinker -install_name -Xlinker "@rpath/AetherRouteKit.framework/Versions/A/AetherRouteKit" \
  "$ROOT"/Sources/AetherRouteKit/*.swift \
  -emit-module-path "$FW/Versions/A/Modules/AetherRouteKit.swiftmodule/$ARCH-apple-macos.swiftmodule" \
  -o "$FW/Versions/A/AetherRouteKit"

echo "Running MacUISmoothnessAndPolishTests..."
xcrun --sdk macosx swiftc -sdk "$SDK_PATH" -swift-version 6 -warnings-as-errors \
  -D DEBUG -D AETHERROUTE_INDEPENDENT -parse-as-library \
  -F "$TEST_TEMP" -Xlinker -rpath -Xlinker "$TEST_TEMP" -framework AetherRouteKit \
  "$ROOT/Sources/AetherRouteApp/AetherRouteVisualSystem.swift" \
  "$ROOT/Sources/AetherRouteApp/AetherMotion.swift" \
  "$ROOT/Sources/AetherRouteApp/AetherSegmentedPicker.swift" \
  "$ROOT/Sources/AetherRouteApp/MenuBarTrafficController.swift" \
  "$ROOT/Sources/AetherRouteApp/AppMenuBarIconController.swift" \
  "$ROOT/Sources/AetherRouteApp/SourceAppDirectory.swift" \
  "$ROOT/Sources/AetherRouteApp/AppWindowManager.swift" \
  "$ROOT/Sources/AetherRouteApp/AppDockVisibilityController.swift" \
  "$ROOT/Sources/AetherRouteApp/WindowVisibilityCoordinator.swift" \
  "$ROOT/Sources/AetherRouteApp/HelpTopics.swift" \
  "$ROOT/Sources/AetherRouteApp/ProxyLatencyStore.swift" \
  "$ROOT/Tests/AetherRouteTests/MacUISmoothnessAndPolishTests.swift" \
  -o "$TEST_TEMP/mac-ui-smoothness-tests"
AETHERROUTE_REPO_ROOT="$ROOT" "$TEST_TEMP/mac-ui-smoothness-tests"

SPARKLE_DIR=""
for candidate in \
  "${AETHERROUTE_PRODUCTS_DIR:-}" \
  "$ROOT/build/DerivedData/Build/Products/Debug" \
  "$ROOT/build/Debug/Build/Products/Debug" \
  "$ROOT/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64" \
  "$ROOT/build/DerivedData-unit/Build/Products/Debug"
do
  if [ -n "$candidate" ] && [ -d "$candidate/Sparkle.framework" ]; then
    SPARKLE_DIR="$candidate"
    break
  fi
done

if [ -z "$SPARKLE_DIR" ]; then
  if [ "${AETHERROUTE_REQUIRE_SPARKLE:-0}" = 1 ]; then
    echo "MacFuncLifecycleAndV3FixTests requires Sparkle.framework in AETHERROUTE_PRODUCTS_DIR" >&2
    exit 1
  fi
  echo "MacFuncLifecycleAndV3FixTests: Sparkle.framework not found, skipping"
  exit 0
fi

echo "Running MacFuncLifecycleAndV3FixTests..."
xcrun --sdk macosx swiftc -sdk "$SDK_PATH" -swift-version 6 -warnings-as-errors \
  -D DEBUG -D AETHERROUTE_INDEPENDENT -parse-as-library \
  -F "$TEST_TEMP" -F "$SPARKLE_DIR" \
  -Xlinker -rpath -Xlinker "$TEST_TEMP" \
  -Xlinker -rpath -Xlinker "$SPARKLE_DIR" \
  -framework AetherRouteKit -framework Sparkle \
  "$ROOT/Sources/AetherRouteApp/ProxyLatencyStore.swift" \
  "$ROOT"/Sources/AetherRouteApp/TunnelManager*.swift \
  "$ROOT/Sources/AetherRouteApp/LANProxyServer.swift" \
  "$ROOT/Sources/AetherRouteApp/AppAutomationController.swift" \
  "$ROOT/Sources/AetherRouteApp/AppStartupController.swift" \
  "$ROOT/Sources/AetherRouteApp/SystemExtensionActivationCoordinator.swift" \
  "$ROOT/Sources/AetherRouteApp/IndependentDistributionController.swift" \
  "$ROOT/Sources/AetherRouteApp/SparkleUpdaterController.swift" \
  "$ROOT/Sources/AetherRouteApp/AppLanguageController.swift" \
  "$ROOT/Sources/AetherRouteApp/AppRuntimeEnvironmentController.swift" \
  "$ROOT/Sources/AetherRouteApp/TrafficHistory.swift" \
  "$ROOT/Sources/AetherRouteApp/ConnectionTableItem.swift" \
  "$ROOT/Sources/AetherRouteApp/SourceAppDirectory.swift" \
  "$ROOT/Sources/AetherRouteApp/ProxyNodeStatus.swift" \
  "$ROOT/Sources/AetherRouteApp/ProxyPageNodeOrder.swift" \
  "$ROOT/Sources/AetherRouteApp/MenuProxyNodeOrder.swift" \
  "$ROOT/Tests/AetherRouteTests/MacFuncLifecycleAndV3FixTests.swift" \
  -o "$TEST_TEMP/mac-func-lifecycle-tests"
"$TEST_TEMP/mac-func-lifecycle-tests"
