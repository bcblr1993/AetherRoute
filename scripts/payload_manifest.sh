#!/bin/sh
# SHA-256 manifest of every regular file under a directory, one line per
# file in byte order: "<hash>  ./<path>". Sourced by test_remote_arm64.sh
# (local snapshot) and remote_arm64_worker.sh (remote check); both sides must
# produce identical bytes. Files are hashed in batches: one shasum per file
# took about ten minutes on each side for the ~45k-file payload.
create_payload_manifest() {
  manifest_root=$1
  manifest_output=$2
  (
    cd "$manifest_root"
    if [ -n "$(find . -type f -print -quit)" ]; then
      find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
    fi
  ) >"$manifest_output"
}
