#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/Sources/AetherRouteApp/AetherRouteApp.swift"
TUNNEL="$ROOT/Sources/AetherRouteApp/TunnelManager.swift"

require_literal() {
  file=$1
  literal=$2
  grep -F "$literal" "$file" >/dev/null || {
    echo "missing application termination guard: $literal" >&2
    exit 1
  }
}

# SIGTERM must be converted into the normal AppKit termination request. That
# path is allowed to defer process exit until NetworkExtension has restored
# system routes and DNS state.
require_literal "$APP" 'Darwin.signal(SIGTERM, SIG_IGN)'
require_literal "$APP" 'DispatchSource.makeSignalSource('
require_literal "$APP" 'signal: SIGTERM'
require_literal "$APP" 'await self?.handleTerminationSignal()'
require_literal "$APP" 'private func handleTerminationSignal() async'
require_literal "$APP" 'await tunnel.disconnectForApplicationTermination()'
require_literal "$APP" 'Darwin.exit(EXIT_SUCCESS)'
require_literal "$APP" 'func applicationShouldTerminate('
require_literal "$APP" '.disconnectForApplicationTermination()'
require_literal "$TUNNEL" 'func disconnectForApplicationTermination() async -> Bool'
require_literal "$TUNNEL" 'await setEnabled(false)'
require_literal "$TUNNEL" 'waitForProviderToBecomeInactive('

echo "application termination signal guard passed"
