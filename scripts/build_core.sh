#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_SOURCE=${AETHERROUTE_CORE_SOURCE:-"$ROOT/Core/Engine"}
CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$ROOT/.build/core"}
export CARGO_TARGET_DIR
TARGET=aarch64-apple-darwin
DESTINATION="$ROOT/Core/Artifacts/macos-arm64"
FEATURES=${AETHERROUTE_CORE_FEATURES:-aether-flow-only}
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
    | grep -Eiq '^(tun-rs|watfaq-netstack|dirs|dirs-sys|option-ext|sock2proc|rust-embed|tuic-core) v|^[^|]+\|[^|]*(GPL|AGPL|LGPL|MPL)-[0-9]' && {
      echo "Refusing to build: forbidden capability or license in independent release graph." >&2
      exit 1
    }

  # Cargo renders a missing SPDX license as two adjacent separators. The two
  # locally audited workspace crates inherit the repository's Apache-2.0 file;
  # every external release dependency must declare its own license metadata.
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
CANDIDATE=$(mktemp "$DESTINATION/.libclashrs.a.XXXXXX")
case "$CANDIDATE" in
  "$DESTINATION"/.libclashrs.a.*) ;;
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

# Apple nm cannot read the LLVM 22 attributes in some Rust 1.96
# compiler_builtins members. Extract this crate's single Mach-O codegen object
# so an unrelated archive member cannot turn a valid ABI check into a failure.
CORE_OBJECT=$(ar -t "$CANDIDATE" \
  | awk '/^clashrs\.clashrs\..*\.rcgu\.o$/ { object = $0; count++ }
         END { if (count == 1) print object; else exit 1 }') || {
    echo "Refusing core artifact without exactly one clashrs codegen object." >&2
    exit 1
  }
SYMBOL_DIR=$(mktemp -d /tmp/aetherroute-core-symbols.XXXXXX)
case "$SYMBOL_DIR" in
  /tmp/aetherroute-core-symbols.*) ;;
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
FLOW_SYMBOLS=$(nm -gU "$SYMBOL_DIR/$CORE_OBJECT" | awk '{print $NF}')
UNDEFINED_SYMBOLS=$(nm -u "$SYMBOL_DIR/$CORE_OBJECT" | awk '{print $NF}')

# Keep the native Swift wrapper and the Rust static library from drifting. The
# provider is not embedded until this complete flow-only surface is present.
for SYMBOL in \
  clash_flow_status_message \
  clash_flow_engine_create \
  clash_flow_engine_set_routing_mode_v1 \
  clash_flow_engine_destroy \
  clash_flow_selector_snapshot_v1 \
  clash_flow_selector_select_v1 \
  clash_flow_selector_latency_v1 \
  clash_flow_selector_active_latency_v1 \
  clash_flow_telemetry_snapshot_v1 \
  clash_flow_tcp_create \
  clash_flow_udp_create \
  clash_flow_activate \
  clash_flow_tcp_write \
  clash_flow_tcp_finish_write \
  clash_flow_tcp_read \
  clash_flow_udp_write \
  clash_flow_udp_read \
  clash_flow_cancel \
  clash_flow_destroy
do
  if ! printf '%s\n' "$FLOW_SYMBOLS" | grep -qx "_$SYMBOL"; then
    echo "Refusing core artifact without required ABI symbol: $SYMBOL" >&2
    exit 1
  fi
done

# 20 since the flow engine gained clash_flow_diagnostics_snapshot_v1. This
# count is a deliberate ceiling on the ABI surface: raising it should be a
# decision, not a side effect of adding an export.
FLOW_ABI_COUNT=$(printf '%s\n' "$FLOW_SYMBOLS" | grep -Ec '^_clash_flow_' || true)
if [ "$FLOW_ABI_COUNT" -ne 20 ]; then
  echo "Refusing core artifact with unexpected Flow ABI count: $FLOW_ABI_COUNT" >&2
  exit 1
fi

if printf '%s\n' "$FLOW_SYMBOLS" \
  | grep -Eq '^_clash_(start|shutdown|packet_|push_packet_|install_packet_|uninstall_packet_|is_packet_)'; then
  echo "Refusing core artifact containing legacy process or packet-flow ABI." >&2
  exit 1
fi

if printf '%s\n' "$UNDEFINED_SYMBOLS" \
  | grep -Eq '^_(fork|execv|execve|execvp|posix_spawn|posix_spawnp|dlsym)$'; then
  echo "Refusing core entry object referencing process launch or dynamic loading." >&2
  exit 1
fi

find "$SYMBOL_DIR" -depth -delete
trap 'rm -f -- "$CANDIDATE"' EXIT HUP INT TERM

HASH=$(shasum -a 256 "$CANDIDATE" | awk '{print $1}')
mv -f -- "$CANDIDATE" "$DESTINATION/libclashrs.a"
trap - EXIT HUP INT TERM
printf '%s  %s\n' "$HASH" "$DESTINATION/libclashrs.a"
