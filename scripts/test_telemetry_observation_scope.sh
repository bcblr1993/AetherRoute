#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/Sources/AetherRouteApp/AetherRouteApp.swift"
CONTENT="$ROOT/Sources/AetherRouteApp/ContentView.swift"
CONNECTIONS="$ROOT/Sources/AetherRouteApp/ConnectionsPageView.swift"
FLOW_ABI="$ROOT/Sources/AetherRouteFlowCoreBridge/FlowCoreABI.swift"
PACKET_CORE="$ROOT/Sources/AetherRoutePacketTunnel/CoreBridge.swift"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

if grep -F '.environmentObject(tunnel.telemetryViewModel)' \
  "$APP" "$CONTENT" "$CONNECTIONS" >/dev/null; then
  fail "high-frequency telemetry must not be injected at an application root"
fi

if grep -F '@EnvironmentObject private var telemetry: NetworkTelemetryViewModel' \
  "$APP" "$CONTENT" "$CONNECTIONS" >/dev/null; then
  fail "telemetry consumers must declare an explicit observed leaf dependency"
fi

grep -F 'MenuBarContent(telemetry: tunnel.telemetryViewModel)' "$APP" \
  >/dev/null || fail "menu telemetry must be passed explicitly"
grep -F 'MenuLiveTrafficValue(metric: metric, telemetry: telemetry)' "$APP" \
  >/dev/null || fail "menu values must own telemetry observation"
test "$(grep -Fc '@ObservedObject var telemetry: NetworkTelemetryViewModel' \
  "$APP")" -eq 1 || fail "menu must have exactly one telemetry observer"

grep -F 'ConnectionsView(telemetry: tunnel.telemetryViewModel)' "$CONTENT" \
  >/dev/null || fail "connections telemetry must be page-scoped"
grep -F 'LiveTelemetryMetricValue(' "$CONTENT" \
  >/dev/null || fail "overview values must own telemetry observation"
test "$(grep -Fc '@ObservedObject var telemetry: NetworkTelemetryViewModel' \
  "$CONTENT")" -eq 1 || fail "overview must have exactly one telemetry observer"

control_bar=$(
  awk '
    /private struct ConnectionControlBar:/ { inside = 1 }
    inside { print }
    inside && /private struct RouteSummary:/ { exit }
  ' "$CONTENT"
)
printf '%s\n' "$control_bar" | grep -F '@EnvironmentObject' >/dev/null \
  && fail "overview segmented controls must not observe TunnelManager directly"
printf '%s\n' "$control_bar" | grep -E '^[[:space:]]*Picker\(' >/dev/null \
  && fail "overview segmented controls must not use SwiftUI Picker"
printf '%s\n' "$control_bar" | grep -F '.pickerStyle(.segmented)' >/dev/null \
  && fail "overview segmented controls must not use SwiftUI segmented style"
grep -F 'private struct NetworkEngineSegmentedControl: NSViewRepresentable' \
  "$CONTENT" >/dev/null \
  || fail "network engine segmented control must use stable AppKit storage"
grep -F 'private struct RoutingModeSegmentedControl: NSViewRepresentable' \
  "$CONTENT" >/dev/null \
  || fail "routing segmented control must use stable AppKit storage"
test "$(grep -Fc 'let control = NSSegmentedControl(' "$CONTENT")" -eq 2 \
  || fail "both overview controls must be backed by NSSegmentedControl"
connection_hero=$(
  awk '
    /private struct ConnectionHero:/ { inside = 1 }
    inside { print }
    inside && /private struct ConnectionControlBar:/ { exit }
  ' "$CONTENT"
)
printf '%s\n' "$connection_hero" | grep -F 'private var connectionControls' >/dev/null \
  && fail "connection hero must not retain duplicate inactive segmented controls"

metric_value=$(
  awk '
    /private struct LiveTelemetryMetricValue:/ { inside = 1 }
    inside { print }
    inside && /private struct SafetyNotice:/ { exit }
  ' "$CONTENT"
)
printf '%s\n' "$metric_value" | grep -F '@EnvironmentObject' >/dev/null \
  && fail "live telemetry values must not observe TunnelManager directly"

test "$(grep -Fc '@ObservedObject var telemetry: NetworkTelemetryViewModel' \
  "$CONNECTIONS")" -eq 2 \
  || fail "connections page and session bar must explicitly observe telemetry"

if grep -F 'tunnel.telemetry.' "$APP" "$CONTENT" "$CONNECTIONS" \
  >/dev/null; then
  fail "UI telemetry reads must go through the isolated telemetry view model"
fi

# Connected runtimes request telemetry every five seconds and automatic route
# health every fifteen seconds. A 1 MiB worst-case scratch buffer on each call
# creates nearly 1 GiB/hour of short-lived allocation churn per extension and
# can make the provider RSS grow in allocator-sized steps. Keep latency buffers
# bound to the actual 64-member wire protocol and telemetry buffers exact-sized.
if grep -F 'count: ProxySelectionProviderMessageCodec.maximumMessageBytes' \
  "$FLOW_ABI" "$PACKET_CORE" >/dev/null; then
  fail "provider latency paths must not allocate the 1 MiB envelope maximum"
fi
if grep -E 'Data\(count: NetworkTelemetryCodec\.maximumMessageBytes\)' \
  "$FLOW_ABI" "$PACKET_CORE" >/dev/null; then
  fail "provider telemetry paths must query exact encoded length"
fi
latency_bound_uses=$(grep -Fhc 'maximumSelectorLatencyPayloadBytes' \
  "$FLOW_ABI" "$PACKET_CORE" | awk '{total+=$1} END{print total+0}')
test "$latency_bound_uses" -eq 4 \
  || fail "both engines must bound batch and active latency buffers"
telemetry_size_queries=$(grep -Fhc 'nil,' "$FLOW_ABI" "$PACKET_CORE" \
  | awk '{total+=$1} END{print total+0}')
test "$telemetry_size_queries" -ge 2 \
  || fail "both engines must perform telemetry size queries"

echo "Telemetry observation scope guards passed."
