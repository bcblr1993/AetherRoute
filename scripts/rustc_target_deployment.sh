#!/bin/sh
# RUSTC_WRAPPER for the core builds: applies MACOSX_DEPLOYMENT_TARGET only to
# compilations for the explicit `--target`, never to host artifacts.
#
# Proc-macro dylibs and build scripts are host artifacts that rustc loads back
# into itself. With MACOSX_DEPLOYMENT_TARGET exported for the whole build,
# rustc 1.96 on macOS 27 can no longer read a freshly built proc macro
# ("E0463: can't find crate for `time_macros`"), so every clean build failed
# and only a warm `.build/core` cache kept releases working.
#
# Cargo passes `--target` only to target compilations when the build itself
# was started with `--target`, which both build scripts do.
set -eu

for argument in "$@"; do
  if [ "$argument" = "--target" ]; then
    MACOSX_DEPLOYMENT_TARGET=${AETHERROUTE_TARGET_DEPLOYMENT:?}
    export MACOSX_DEPLOYMENT_TARGET
    break
  fi
done
unset AETHERROUTE_TARGET_DEPLOYMENT
exec "$@"
