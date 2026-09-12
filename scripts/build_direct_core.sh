#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_SOURCE=${AETHERROUTE_CORE_SOURCE:-"$ROOT/Core/Engine"}
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT/.build/core"}
export CARGO_TARGET_DIR
TARGET=aarch64-apple-darwin
DESTINATION="$ROOT/Core/Artifacts/macos-arm64"
FEATURES=${AETHERROUTE_DIRECT_CORE_FEATURES:-aether-embedded}
ARTIFACT=libclashrs-direct.a
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-mmacosx-version-min=14.0"
case "$CORE_SOURCE:$CARGO_TARGET_DIR" in
  *[[:space:]]*)
    echo "Core source and Cargo target paths must not contain whitespace" >&2
    exit 1
    ;;
esac
export RUSTFLAGS="${RUSTFLAGS:--D warnings} --remap-path-prefix=$CORE_SOURCE=/aetherroute-core --remap-path-prefix=$CARGO_TARGET_DIR=/aetherroute-target"

if [ ! -f "$CORE_SOURCE/Cargo.lock" ]; then
  echo "Pinned core source not found: $CORE_SOURCE" >&2
  exit 1
fi

(
  cd "$CORE_SOURCE"

  RELEASE_TREE=$(cargo tree \
    --locked \
    -p clash-ffi \
    --no-default-features \
    --features "$FEATURES" \
    --edges normal \
    --target "$TARGET" \
    --format '{p}|{l}|{r}')

  NORMALIZED_TREE=$(printf '%s\n' "$RELEASE_TREE" | sed -E 's/^[│├└─ ]+//')
  printf '%s\n' "$NORMALIZED_TREE" \
    | grep -Eiq '^(dirs|dirs-sys|option-ext|sock2proc|rust-embed|tuic-core) v|^[^|]+\|[^|]*(GPL|AGPL|LGPL|MPL)-[0-9]' && {
      echo "Refusing to build: forbidden capability or license in Direct release graph." >&2
      exit 1
    }

  UNLICENSED=$(printf '%s\n' "$RELEASE_TREE" \
    | sed -E 's/^[│├└─ ]+//' \
    | grep '||' \
    | grep -Ev '^clash-(ffi|lib) ' || true)
  if [ -n "$UNLICENSED" ]; then
    echo "Refusing to build: dependency without declared license:" >&2
    printf '%s\n' "$UNLICENSED" >&2
    exit 1
  fi

  cargo build \
    --locked \
    -p clash-ffi \
    --no-default-features \
    --features "$FEATURES" \
    --release \
    --target "$TARGET"
)

mkdir -p "$DESTINATION"
CANDIDATE=$(mktemp "$DESTINATION/.$ARTIFACT.XXXXXX")
case "$CANDIDATE" in
  "$DESTINATION"/.$ARTIFACT.*) ;;
  *)
    echo "Refusing unexpected candidate path: $CANDIDATE" >&2
    exit 1
    ;;
esac
trap 'rm -f -- "$CANDIDATE"' EXIT HUP INT TERM
cp "$CARGO_TARGET_DIR/$TARGET/release/libclashrs.a" "$CANDIDATE"

ARCHS=$(lipo -archs "$CANDIDATE")
if [ "$ARCHS" != arm64 ]; then
  echo "Refusing core artifact with unexpected architectures: $ARCHS" >&2
  exit 1
fi

CORE_OBJECT=$(ar -t "$CANDIDATE" \
  | awk '/^clashrs\.clashrs\..*\.rcgu\.o$/ { object = $0; count++ }
         END { if (count == 1) print object; else exit 1 }') || {
    echo "Refusing core artifact without exactly one clashrs codegen object." >&2
    exit 1
  }
SYMBOL_DIR=$(mktemp -d /tmp/aetherroute-direct-core-symbols.XXXXXX)
case "$SYMBOL_DIR" in
  /tmp/aetherroute-direct-core-symbols.*) ;;
  *)
    echo "Refusing unexpected symbol-check directory: $SYMBOL_DIR" >&2
    exit 1
    ;;
esac
cleanup_symbols_and_candidate() {
  find "$SYMBOL_DIR" -depth -delete 2>/dev/null || true
  rm -f -- "$CANDIDATE"
}
trap cleanup_symbols_and_candidate EXIT HUP INT TERM
(
  cd "$SYMBOL_DIR"
  ar -x "$CANDIDATE" "$CORE_OBJECT"
)
DEFINED_SYMBOLS=$(nm -gU "$SYMBOL_DIR/$CORE_OBJECT" | awk '{print $NF}')
UNDEFINED_SYMBOLS=$(nm -u "$SYMBOL_DIR/$CORE_OBJECT" | awk '{print $NF}')

for SYMBOL in \
  clash_start_packet_flow \
  clash_start_packet_flow_with_mode \
  clash_start_packet_flow_with_policy_v1 \
  clash_start_packet_flow_with_policy_and_local_proxy_v1 \
  clash_shutdown \
  clash_free_string \
  clash_install_packet_flow \
  clash_packet_input \
  clash_packet_flow_ready \
  clash_packet_selector_snapshot_v1 \
  clash_packet_selector_select_v1 \
  clash_packet_selector_latency_v1 \
  clash_packet_selector_active_latency_v1 \
  clash_packet_telemetry_snapshot_v1 \
  clash_packet_reset_network_state_v1 \
  clash_uninstall_packet_flow
do
  if ! printf '%s\n' "$DEFINED_SYMBOLS" | grep -qx "_$SYMBOL"; then
    echo "Refusing Direct core without required PacketFlow ABI symbol: $SYMBOL" >&2
    exit 1
  fi
done

if printf '%s\n' "$UNDEFINED_SYMBOLS" \
  | grep -Eq '^_(fork|execv|execve|execvp|posix_spawn|posix_spawnp|dlsym)$'; then
  echo "Refusing Direct core entry object referencing process launch or dynamic loading." >&2
  exit 1
fi

if ! otool -l "$SYMBOL_DIR/$CORE_OBJECT" \
  | awk '$1 == "minos" && $2 >= 14.0 { found = 1 } END { exit !found }'; then
  echo "Refusing Direct core without a macOS 14.0-or-newer deployment target." >&2
  exit 1
fi

find "$SYMBOL_DIR" -depth -delete
trap 'rm -f -- "$CANDIDATE"' EXIT HUP INT TERM

HASH=$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')
mv -f -- "$CANDIDATE" "$DESTINATION/$ARTIFACT"
trap - EXIT HUP INT TERM
printf '%s  %s\n' "$HASH" "$DESTINATION/$ARTIFACT"
