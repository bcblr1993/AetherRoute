#!/bin/sh
set -eu
# Writes only a new caller-selected private record. Never executes Python.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
test "$#" -eq 2 || { echo 'usage: prepare_signed_ne_python_runtime.sh /physical/python /physical/new-record.json' >&2; exit 1; }
runtime=$1 record=$2
case "$record" in /*) ;; *) echo 'runtime record requires absolute path' >&2; exit 1;; esac
test ! -e "$record" && test ! -L "$record" || { echo 'runtime record already exists' >&2; exit 1; }
parent=$(CDPATH= cd -- "$(dirname -- "$record")" && pwd -P)
test "$parent/$(basename -- "$record")" = "$record" || { echo 'runtime record parent is not physical' >&2; exit 1; }
umask 077
stage=$(mktemp -d /private/tmp/aether-python-prepare.XXXXXXXX)
cleanup() { find "$stage" -depth -delete; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
/usr/bin/xcrun swiftc -swift-version 6 -warnings-as-errors \
  "$ROOT/Tests/AetherRouteUITests/SignedNEPythonRuntime.swift" "$ROOT/Tests/SignedNEProbe/RuntimeTool.swift" \
  -o "$stage/inspect-runtime"
"$stage/inspect-runtime" inspect "$runtime" > "$stage/record.json"
# noclobber reserves the new file, including against a concurrent symlink.
(set -C; cat "$stage/record.json" > "$record")
test "$(stat -f '%Lp' "$record")" = 600
shasum -a 256 "$record"
