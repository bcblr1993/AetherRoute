#!/bin/sh
# Shared local staging operation for remote validation; no SSH occurs here.
stage_remote_source_directory() {
  if [ "$3" = Config ]; then
    rsync -a --exclude '/Signing.json' --exclude '/sparkle_ed25519_priv.key' "$1/" "$2/"
  else
    rsync -a "$1/" "$2/"
  fi
}
