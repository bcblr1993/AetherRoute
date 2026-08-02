#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=${1:?usage: build.sh /absolute/output/path}
EXPECTED_VERSION=v0.0.0-20250521234502-f333402bd9cb

case $OUTPUT in
  /*) ;;
  *)
    echo "output path must be absolute: $OUTPUT" >&2
    exit 1
    ;;
esac

actual_version=$(
  cd "$ROOT"
  GOWORK=off GOFLAGS= go list -mod=readonly -m -f '{{.Version}}' golang.zx2c4.com/wireguard
)
if [ "$actual_version" != "$EXPECTED_VERSION" ]; then
  echo "unexpected wireguard-go version: $actual_version" >&2
  exit 1
fi

(
  cd "$ROOT"
  GOWORK=off GOFLAGS= go mod verify
  GOWORK=off GOFLAGS= go test -mod=readonly ./...
  GOWORK=off GOFLAGS= CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
    go build -mod=readonly -trimpath -buildvcs=false -ldflags=-buildid= -o "$OUTPUT" .
)
go version -m "$OUTPUT" | awk -v expected="$EXPECTED_VERSION" '
  $1 == "dep" && $2 == "golang.zx2c4.com/wireguard" && $3 == expected {
    found = 1
  }
  END { exit found ? 0 : 1 }
'
"$OUTPUT" -version | grep -F "wireguard-go $EXPECTED_VERSION revision f333402bd9cbe0f3eeb02507bd14e23d7d639280" >/dev/null
shasum -a 256 "$OUTPUT"
