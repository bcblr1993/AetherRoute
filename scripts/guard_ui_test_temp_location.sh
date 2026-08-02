#!/bin/sh
set -eu

case "${BUILD_DIR:-}" in
  "${SRCROOT:-}"/*|*/Documents/*)
    echo "error: AetherRoute UI tests must use scripts/test_ui.sh so the app runs outside Documents with temporary DerivedData." >&2
    exit 1
    ;;
esac

case "${PROJECT_TEMP_DIR:-}" in
  "${SRCROOT:-}"/*|*/Documents/*)
    echo "error: AetherRoute UI test intermediates may not be stored inside Documents." >&2
    exit 1
    ;;
esac
