#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
swift scripts/generate_icon_source.swift
swift scripts/generate_app_icon.swift
swift scripts/generate_icon_composer_assets.swift
temporary=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-icns.XXXXXX")
trap 'find "$temporary" -depth -delete' EXIT HUP INT TERM
mkdir "$temporary/AppIcon.iconset"
icons=Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset
for size in 16 32 128 256 512; do
  cp "$icons/AppIcon-$size.png" "$temporary/AppIcon.iconset/icon_${size}x${size}.png"
  double=$((size * 2))
  cp "$icons/AppIcon-$double.png" "$temporary/AppIcon.iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$temporary/AppIcon.iconset" -o Config/App/AppIcon.icns
cp "$icons/AppIcon-128.png" Services/WebDistribution/public/assets/favicon.png
cp "$icons/AppIcon-512.png" Services/WebDistribution/public/assets/aetherroute-mark.png
{
  printf '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="512" height="512" viewBox="0 0 512 512"><image width="512" height="512" xlink:href="data:image/png;base64,'
  base64 < Services/WebDistribution/public/assets/aetherroute-mark.png | tr -d '\n'
  printf '"/></svg>\n'
} > Services/WebDistribution/public/assets/aetherroute-mark.svg
echo 'Silver Flight application and website assets generated.'
