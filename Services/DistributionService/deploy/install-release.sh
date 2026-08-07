#!/bin/sh
set -eu
umask 077

incoming=${1:-}
release_id=${2:-}
image_tag=${3:-}
artifact_name=${4:-}
version=${5:-}
build=${6:-}
published_at=${7:-}
download_url=${8:-}
release_notes_url=${9:-}

remote_root=/home/chenyn/services/aetherroute-license
system_root=/etc/aetherroute-license
state_root=/var/lib/aetherroute-license/state
runtime_root=/var/lib/aetherroute-license/runtime
stack_name=aetherroute-license-staging

case "$incoming" in /home/chenyn/services/aetherroute-license/.incoming-*) ;; *) exit 64 ;; esac
printf '%s\n' "$release_id" | grep -Eq '^[0-9A-Za-z][0-9A-Za-z._-]{2,63}$'
printf '%s\n' "$image_tag" | grep -Eq '^aetherroute-distribution:[0-9A-Za-z][0-9A-Za-z._-]{2,63}$'
printf '%s\n' "$artifact_name" | grep -Eq '^AetherRoute-[0-9A-Za-z._-]+-arm64[^/]*\.dmg$'
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'
case "$build" in ''|*[!0-9]*) exit 64 ;; esac
test "$build" -gt 1
printf '%s\n' "$published_at" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
case "$download_url" in https://downloads.baizhiedu.xin/*.dmg) ;; *) exit 64 ;; esac
case "$release_notes_url" in https://aetherroute.baizhiedu.xin/*) ;; *) exit 64 ;; esac

for command in docker jq sha256sum; do
  command -v "$command" >/dev/null
done
test -d "$incoming/context"
test -x "$incoming/aetherroute-distribution"
test -f "$incoming/$artifact_name"
test -f "$incoming/docker-stack.yml"
test -x "$incoming/activate-release.sh"
test -f "$incoming/source-manifest.sha256"
test ! -e "$remote_root/releases/$release_id"

source_manifest_size=$(wc -c <"$incoming/source-manifest.sha256" | tr -d ' ')
case "$source_manifest_size" in ''|*[!0-9]*) exit 1 ;; esac
test "$source_manifest_size" -gt 0
test "$source_manifest_size" -le 131072
if ! awk '
  NF != 2 || $1 !~ /^[0-9a-f]{64}$/ || $2 !~ /^[A-Za-z0-9][A-Za-z0-9._\/-]*$/ {
    exit 1
  }
' "$incoming/source-manifest.sha256"; then
  echo "invalid distribution source manifest" >&2
  exit 1
fi
source_manifest_sha=$(sha256sum "$incoming/source-manifest.sha256" | awk '{print $1}')

docker build --pull=false \
  --label org.opencontainers.image.title=AetherRoute-Distribution \
  --label org.opencontainers.image.revision="$release_id" \
  -t "$image_tag" "$incoming/context" >/dev/null
image_id=$(docker image inspect "$image_tag" --format '{{.Id}}')
test -n "$image_id"

sudo -n install -d -m 700 -o root -g root \
  "$system_root" "$system_root/signer" "$system_root/web"
sudo -n install -d -m 700 "$state_root" "$runtime_root"
sudo -n chown 10002:12000 "$state_root"
sudo -n chmod 700 "$state_root"
sudo -n chown 10001:12000 "$runtime_root"
sudo -n chmod 710 "$runtime_root"

if ! sudo -n test -f "$system_root/signer/signing-seed.raw"; then
  sudo -n "$incoming/aetherroute-distribution" keygen \
    -seed "$system_root/signer/signing-seed.raw" \
    -public-key "$system_root/signer/signing-public.raw"
  sudo -n chown 10001:10001 "$system_root/signer/signing-seed.raw"
  sudo -n chmod 400 "$system_root/signer/signing-seed.raw"
fi
sudo -n test -f "$system_root/signer/signing-public.raw"
sudo -n install -m 400 -o 10002 -g 10002 \
  "$system_root/signer/signing-public.raw" \
  "$system_root/web/signing-public.raw"

if ! sudo -n test -f "$system_root/web/license-pepper.raw"; then
  sudo -n "$incoming/aetherroute-distribution" generate-pepper \
    -output "$system_root/web/license-pepper.raw"
fi
sudo -n chown 10002:10002 "$system_root/web/license-pepper.raw"
sudo -n chmod 400 "$system_root/web/license-pepper.raw"

sudo -n "$incoming/aetherroute-distribution" sign-update \
  -product-id com.aetherroute.desktop \
  -seed "$system_root/signer/signing-seed.raw" \
  -dmg "$incoming/$artifact_name" \
  -version "$version" -build "$build" -published-at "$published_at" \
  -minimum-system 15.0 \
  -download-url "$download_url" \
  -release-notes-url "$release_notes_url" \
  -output "$incoming/current.update.json"
sudo -n chown 10002:10002 "$incoming/current.update.json"
sudo -n chmod 400 "$incoming/current.update.json"

artifact_sha=$(sha256sum "$incoming/$artifact_name" | awk '{print $1}')
previous=none
if [ -L "$remote_root/current" ]; then
  previous=$(readlink "$remote_root/current")
  case "$previous" in releases/*) ;; *) exit 1 ;; esac
fi
printf '%s\n' "$previous" >"$incoming/PREVIOUS"
jq -n \
  --arg releaseID "$release_id" \
  --arg image "$image_tag" \
  --arg imageID "$image_id" \
  --arg sourceManifestSHA256 "$source_manifest_sha" \
  --arg artifact "$artifact_name" \
  --arg sha256 "$artifact_sha" \
  --arg version "$version" \
  --argjson build "$build" \
  --arg publishedAt "$published_at" \
  --arg downloadURL "$download_url" \
  '{schemaVersion:1, channel:"staging", releaseID:$releaseID, image:$image, imageID:$imageID, sourceManifestSHA256:$sourceManifestSHA256, artifact:$artifact, sha256:$sha256, version:$version, build:$build, publishedAt:$publishedAt, downloadURL:$downloadURL}' \
  >"$incoming/metadata.json"

find "$incoming/context" -depth -delete
rm "$incoming/aetherroute-distribution" "$incoming/$artifact_name"
release_root="$remote_root/releases/$release_id"
mv "$incoming" "$release_root"
"$release_root/activate-release.sh" "$release_root" >/dev/null
printf '%s\n' "$release_id"
