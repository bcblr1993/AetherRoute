#!/bin/sh
# Shared local staging operation for remote validation; no SSH occurs here.
stage_remote_source_directory() {
  if [ "$3" = Config ]; then
    rsync -a --exclude '/Signing.json' --exclude '/sparkle_ed25519_priv.key' "$1/" "$2/"
  else
    rsync -a "$1/" "$2/"
  fi
}

stage_remote_interop_verifier() {
  interop_stage_source=${2:-$1}
  if [ ! -f "$interop_stage_source" ] || [ ! -x "$interop_stage_source" ]; then
    echo "Pinned protocol interoperability verifier is missing or not executable" >&2
    return 1
  fi
  rsync -a --checksum "$interop_stage_source" "$3"
}
