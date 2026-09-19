#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
ICON_DIRECTORY="$ROOT/Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset"
COMPOSER_DIRECTORY="$ROOT/Sources/AetherRouteApp/AppIcon.icon"
GENERATED_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-icon.XXXXXX")
GENERATED_COMPOSER_DIRECTORY=$(
  mktemp -d "${TMPDIR:-/tmp}/aetherroute-icon-composer.XXXXXX"
)
RENDER_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-icon-render.XXXXXX")
cleanup() {
  find "$GENERATED_DIRECTORY" -depth -delete 2>/dev/null || true
  find "$GENERATED_COMPOSER_DIRECTORY" -depth -delete 2>/dev/null || true
  find "$RENDER_DIRECTORY" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
test -x "$ICTOOL" || {
  echo "App icon verification failed: Icon Composer ictool is unavailable" >&2
  exit 1
}

jq -e . "$ICON_DIRECTORY/Contents.json" >/dev/null
jq -e '
  (.groups | length) == 1 and
  ([.groups[].layers[]."image-name"] | sort) == ["SilverFlight.png"] and
  (.["supported-platforms"].squares == "shared")
' "$COMPOSER_DIRECTORY/icon.json" >/dev/null || {
  echo "App icon verification failed: unexpected Icon Composer document" >&2
  exit 1
}
swift "$ROOT/scripts/generate_icon_source.swift" --output-directory "$RENDER_DIRECTORY" >/dev/null
cmp "$ICON_DIRECTORY/AppIcon-1024.png" "$RENDER_DIRECTORY/Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
cmp "$ICON_DIRECTORY/AppIcon-1024.png" "$ROOT/Sources/AetherRouteApp/Assets.xcassets/AetherSapphireEmblem.imageset/AetherSapphireEmblem.png"
EMBLEM="Sources/AetherRouteApp/Assets.xcassets/AetherSapphireEmblem.imageset"
cmp "$ROOT/$EMBLEM/AetherSapphireEmblem-Dark.png" "$RENDER_DIRECTORY/$EMBLEM/AetherSapphireEmblem-Dark.png"
jq -e '.images | any(.filename == "AetherSapphireEmblem-Dark.png" and .appearances == [{"appearance":"luminosity","value":"dark"}])' "$ROOT/$EMBLEM/Contents.json" >/dev/null
swift "$ROOT/scripts/generate_app_icon.swift" \
  --output-directory "$GENERATED_DIRECTORY" >/dev/null
swift "$ROOT/scripts/generate_icon_composer_assets.swift" \
  --output-directory "$GENERATED_COMPOSER_DIRECTORY" >/dev/null

for SIZE in 16 32 64 128 256 512 1024; do
  SOURCE="$ICON_DIRECTORY/AppIcon-$SIZE.png"
  GENERATED="$GENERATED_DIRECTORY/AppIcon-$SIZE.png"
  test -f "$SOURCE" || {
    echo "App icon verification failed: missing AppIcon-$SIZE.png" >&2
    exit 1
  }
  WIDTH=$(sips -g pixelWidth "$SOURCE" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')
  HEIGHT=$(sips -g pixelHeight "$SOURCE" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')
  test "$WIDTH" = "$SIZE" && test "$HEIGHT" = "$SIZE" || {
    echo "App icon verification failed: AppIcon-$SIZE.png is ${WIDTH}x${HEIGHT}" >&2
    exit 1
  }
  SOURCE_PIXELS="$RENDER_DIRECTORY/AppIcon-$SIZE-source.tiff"
  GENERATED_PIXELS="$RENDER_DIRECTORY/AppIcon-$SIZE-generated.tiff"
  sips -s format tiff "$SOURCE" --out "$SOURCE_PIXELS" >/dev/null
  sips -s format tiff "$GENERATED" --out "$GENERATED_PIXELS" >/dev/null
  cmp -s "$SOURCE_PIXELS" "$GENERATED_PIXELS" || {
    echo "App icon verification failed: AppIcon-$SIZE.png pixels are not reproducible" >&2
    exit 1
  }
done

for ASSET in SilverFlight.png; do
  SOURCE="$COMPOSER_DIRECTORY/Assets/$ASSET"
  GENERATED="$GENERATED_COMPOSER_DIRECTORY/$ASSET"
  test -f "$SOURCE" || {
    echo "App icon verification failed: missing Icon Composer $ASSET" >&2
    exit 1
  }
  WIDTH=$(sips -g pixelWidth "$SOURCE" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')
  HEIGHT=$(sips -g pixelHeight "$SOURCE" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')
  ALPHA=$(sips -g hasAlpha "$SOURCE" 2>/dev/null | awk '/hasAlpha:/ { print $2 }')
  test "$WIDTH" = 1024 && test "$HEIGHT" = 1024 && test "$ALPHA" = yes || {
    echo "App icon verification failed: invalid Icon Composer $ASSET" >&2
    exit 1
  }
  SOURCE_PIXELS="$RENDER_DIRECTORY/$ASSET-source.tiff"
  GENERATED_PIXELS="$RENDER_DIRECTORY/$ASSET-generated.tiff"
  sips -s format tiff "$SOURCE" --out "$SOURCE_PIXELS" >/dev/null
  sips -s format tiff "$GENERATED" --out "$GENERATED_PIXELS" >/dev/null
  cmp -s "$SOURCE_PIXELS" "$GENERATED_PIXELS" || {
    echo "App icon verification failed: Icon Composer $ASSET pixels are not reproducible" >&2
    exit 1
  }
done

for RENDITION in Default Dark Mono TintedLight TintedDark ClearLight ClearDark; do
  for SIZE in 16 32 1024; do
    OUTPUT="$RENDER_DIRECTORY/${RENDITION}-${SIZE}.png"
    "$ICTOOL" "$COMPOSER_DIRECTORY" \
      --export-image \
      --output-file "$OUTPUT" \
      --platform macOS \
      --rendition "$RENDITION" \
      --width "$SIZE" \
      --height "$SIZE" \
      --scale 1 >/dev/null
    WIDTH=$(sips -g pixelWidth "$OUTPUT" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')
    HEIGHT=$(sips -g pixelHeight "$OUTPUT" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')
    test "$WIDTH" = "$SIZE" && test "$HEIGHT" = "$SIZE" || {
      echo "App icon verification failed: $RENDITION ${SIZE}px export is invalid" >&2
      exit 1
    }
  done
done

echo "App icon assets verified: Silver Flight, 7 renditions, 16-1024 px"
