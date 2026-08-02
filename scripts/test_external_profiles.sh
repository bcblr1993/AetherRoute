#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -lt 1 ]; then
  echo "usage: $0 /absolute/profile.yaml [...]" >&2
  exit 64
fi

for profile in "$@"; do
  case "$profile" in
    /*) ;;
    *) echo "profile path must be absolute" >&2; exit 64 ;;
  esac
  test -f "$profile" && test -r "$profile" || {
    echo "profile is not a readable regular file" >&2
    exit 66
  }
done

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-external-profiles.XXXXXX")
chmod 700 "$TEMP_DIR"
cleanup() {
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

swiftc -parse-as-library \
  "$ROOT/Sources/AetherRouteKit/ProfileImportValidator.swift" \
  "$ROOT/Sources/AetherRouteKit/ProfileConfigurationSummary.swift" \
  "$ROOT/Sources/AetherRouteKit/AetherNode.swift" \
  "$ROOT/Sources/AetherRouteKit/SubscriptionPayloadNormalizer.swift" \
  "$ROOT/Sources/AetherRouteKit/ProfileSubscription.swift" \
  "$ROOT/Tests/ExternalProfiles/main.swift" \
  -o "$TEMP_DIR/profile_fixture_verifier"
"$TEMP_DIR/profile_fixture_verifier" "$@"

index=1
for profile in "$@"; do
  ruby -r yaml -e '
    source, destination = ARGV
    data = YAML.safe_load(
      File.read(source),
      permitted_classes: [],
      permitted_symbols: [],
      aliases: true
    )
    abort("profile root is not a mapping") unless data.is_a?(Hash)
    %w[port socks-port redir-port tproxy-port mixed-port].each { |key| data[key] = 0 }
    data["allow-lan"] = false
    data["bind-address"] = "127.0.0.1"
    data["external-controller"] = ""
    data.delete("secret")
    data.delete("interface-name")
    data["tun"] = { "enable" => false }
    data["dns"] = { "enable" => false }
    data["profile"] = {
      "store-selected" => false,
      "store-fake-ip" => false
    }
    File.open(destination, File::WRONLY | File::CREAT | File::TRUNC, 0600) do |file|
      file.write(YAML.dump(data))
    end
  ' "$profile" "$TEMP_DIR/profile-$index.yaml"
  index=$((index + 1))
done

mkdir -m 700 "$TEMP_DIR/runtime"
for asset in Country.mmdb GeoSite.dat; do
  first_directory=$(dirname -- "$1")
  if [ -f "$first_directory/$asset" ]; then
    cp "$first_directory/$asset" "$TEMP_DIR/runtime/$asset"
    chmod 600 "$TEMP_DIR/runtime/$asset"
  fi
done

COMMON_FLAGS="-std=c17 -Wall -Wextra -Werror -mmacosx-version-min=14.0"
clang $COMMON_FLAGS \
  -DAETHER_EXTERNAL_FLOW_ONLY \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_profile_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$TEMP_DIR/flow_profile_smoke"

clang $COMMON_FLAGS \
  -DAETHER_EXTERNAL_PACKET \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_profile_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$TEMP_DIR/packet_profile_smoke"

failures=0
index=1
for profile in "$@"; do
  sanitized="$TEMP_DIR/profile-$index.yaml"
  if /usr/bin/sandbox-exec \
    -p '(version 1) (allow default) (deny network*)' \
    "$TEMP_DIR/flow_profile_smoke" "$sanitized" "$TEMP_DIR/runtime"; then
    printf 'profile[%s] flow-only core passed with network denied\n' "$index"
  else
    printf 'profile[%s] flow-only core failed with network denied\n' "$index" >&2
    failures=$((failures + 1))
  fi
  if /usr/bin/sandbox-exec \
    -p '(version 1) (allow default) (deny network*)' \
    "$TEMP_DIR/packet_profile_smoke" "$sanitized" "$TEMP_DIR/runtime"; then
    printf 'profile[%s] packet-tunnel core passed with network denied\n' "$index"
  else
    printf 'profile[%s] packet-tunnel core failed with network denied\n' "$index" >&2
    failures=$((failures + 1))
  fi
  index=$((index + 1))
done

if [ "$failures" -ne 0 ]; then
  printf 'External profile isolation gate failed on %s core surface(s).\n' \
    "$failures" >&2
  exit 1
fi

printf 'External profiles verified in an isolated, network-denied process sandbox.\n'
