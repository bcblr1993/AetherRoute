#!/bin/sh
set -eu

# Downloads an OCI VM image layer by layer into Tart's cache layout.
#
# `tart pull` fetches 96 blobs behind a token that expires every few minutes,
# which makes an interrupted pull expensive to resume by hand. This script
# refreshes the token per blob and skips blobs already on disk, so it can be
# stopped and restarted at any point without losing progress.

IMAGE=${1:-ghcr.io/cirruslabs/macos-tahoe-base:latest}
OUTPUT=${2:-$HOME/Downloads/tart-blobs}
CONCURRENCY=${TART_FETCH_CONCURRENCY:-6}

REPOSITORY=$(printf '%s' "$IMAGE" | sed 's|^ghcr.io/||; s|:.*$||')
TAG=$(printf '%s' "$IMAGE" | sed 's|^.*:||')

mkdir -p "$OUTPUT"

token() {
  curl -fsS --max-time 30 \
    "https://ghcr.io/token?scope=repository:${REPOSITORY}:pull" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'
}

echo "Fetching manifest for ${REPOSITORY}:${TAG}"
curl -fsS --max-time 30 -H "Authorization: Bearer $(token)" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  "https://ghcr.io/v2/${REPOSITORY}/manifests/${TAG}" \
  -o "$OUTPUT/manifest.json"

python3 - "$OUTPUT/manifest.json" >"$OUTPUT/digests.txt" <<'PYTHON'
import json, sys
manifest = json.load(open(sys.argv[1]))
for layer in manifest["layers"]:
    print(layer["digest"], layer["size"])
PYTHON

TOTAL=$(awk '{s+=$2} END {printf "%.1f", s/1024/1024/1024}' "$OUTPUT/digests.txt")
COUNT=$(wc -l <"$OUTPUT/digests.txt" | tr -d ' ')
echo "Layers: ${COUNT}, total ${TOTAL} GB"

fetch_one() {
  digest=$1
  size=$2
  name=$(printf '%s' "$digest" | sed 's|sha256:||')
  target="$OUTPUT/$name"
  actual=$(stat -f '%z' "$target" 2>/dev/null || echo 0)
  if [ "$actual" = "$size" ]; then
    echo "  skip $name (complete)"
    return 0
  fi
  # `-C -` resumes a partial blob instead of restarting it.
  curl -fsSL -C - --max-time 3600 \
    -H "Authorization: Bearer $(token)" \
    -o "$target" \
    "https://ghcr.io/v2/${REPOSITORY}/blobs/${digest}" \
    && echo "  done $name" \
    || echo "  FAILED $name (rerun to resume)"
}

running=0
while read -r digest size; do
  fetch_one "$digest" "$size" &
  running=$((running + 1))
  if [ "$running" -ge "$CONCURRENCY" ]; then
    wait
    running=0
  fi
done <"$OUTPUT/digests.txt"
wait

COMPLETE=0
while read -r digest size; do
  name=$(printf '%s' "$digest" | sed 's|sha256:||')
  actual=$(stat -f '%z' "$OUTPUT/$name" 2>/dev/null || echo 0)
  [ "$actual" = "$size" ] && COMPLETE=$((COMPLETE + 1))
done <"$OUTPUT/digests.txt"

echo "Complete layers: ${COMPLETE}/${COUNT}"
if [ "$COMPLETE" != "$COUNT" ]; then
  echo "Rerun this script to resume the remaining layers." >&2
  exit 1
fi
echo "All layers downloaded to ${OUTPUT}"
