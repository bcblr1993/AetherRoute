#!/bin/sh
set -eu

# Release gate: a multi-megabyte upload must cross the proxy intact.
#
# When a client writes faster than the node's uplink drains, the relay hands
# the outbound full 64 KiB buffers. The VLESS Vision frame header stores its
# length in a u16, so a 65536-byte frame was sent with length 0 and the
# server dropped the connection about two seconds in. Small requests and
# rate-limited uploads passed; Claude Code requests, which carry the whole
# conversation, failed on every retry with ECONNRESET.
#
# Exit status: 0 delivered, 1 the upload was cut off, 2 inconclusive (even a
# small request did not get through, so the path under test was not reached).
#
# Delivery is proved by the server, never by curl's own write counter: the
# default Cloudflare endpoint reports the bytes it read in
# `cf-meta-upload-bytes`, and an httpbin-compatible URL echoes the body back
# for a byte-for-byte compare. Either way the request is end-to-end HTTPS, so
# a relay that corrupts or drops bytes fails the TLS record check rather than
# reaching a 200. httpbin.org stopped accepting bodies over 64 KiB in October
# 2026, which is why it is no longer the default.

URL=${AETHERROUTE_LARGE_UPLOAD_URL:-https://speed.cloudflare.com/__up}
BYTES=${AETHERROUTE_LARGE_UPLOAD_BYTES:-2097152}

case "$BYTES" in
  ''|*[!0-9]*) echo "upload size must be a positive integer" >&2; exit 64 ;;
esac
test "$BYTES" -ge 1048576 || {
  echo "upload size must be at least 1 MiB to cover the regression" >&2
  exit 64
}
case "$URL" in
  https://*) ;;
  *) echo "upload URL must be https" >&2; exit 64 ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-large-upload.XXXXXX")
trap 'find "$WORK" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

post() {
  curl --proxy '' -sS -o "$WORK/response" -D "$WORK/headers" \
    -w '%{http_code} %{size_upload} %{time_total}' \
    -H 'content-type: application/octet-stream' \
    -X POST --data-binary "@$1" --max-time 120 "$URL" 2>/dev/null
}

printf 'probe' >"$WORK/small"
if ! small=$(post "$WORK/small"); then
  echo "large upload: inconclusive, small request did not complete (${small:-no response})"
  exit 2
fi
case "$small" in
  200\ *) ;;
  *) echo "large upload: inconclusive, small request not answered (${small:-no response})"; exit 2 ;;
esac

# Random bytes do not compress, so every byte crosses the uplink.
head -c "$BYTES" /dev/urandom >"$WORK/payload"
transfer_completed=0
if result=$(post "$WORK/payload"); then
  transfer_completed=1
fi
set -- $result
code=${1:-000}
sent=${2:-0}
seconds=${3:-0}
if [ "$transfer_completed" -eq 1 ] && [ "$code" = 200 ] && [ "$sent" = "$BYTES" ]; then
  # The upload counter measures client writes, not bytes received by the peer.
  received=$(tr -d '\r' <"$WORK/headers" 2>/dev/null \
    | awk -F': *' 'tolower($1) == "cf-meta-upload-bytes" { value = $2 } END { print value }')
  if [ -n "$received" ]; then
    if [ "$received" != "$BYTES" ]; then
      echo "large upload: server received $received of $BYTES bytes"
      exit 1
    fi
  else
    # httpbin echoes binary request bodies as a base64 data URL; compare that
    # echo with the original payload before accepting delivery.
    if ! echoed=$(/usr/bin/plutil -extract data raw -o - "$WORK/response" 2>/dev/null); then
      echo "large upload: response did not report or echo the request body"
      exit 1
    fi
    case "$echoed" in
      data:application/octet-stream\;base64,*)
        encoded=${echoed#data:application/octet-stream;base64,} ;;
      *) echo "large upload: unexpected request-body echo encoding"; exit 1 ;;
    esac
    if ! printf '%s' "$encoded" | /usr/bin/base64 -D >"$WORK/echoed" \
      || ! cmp -s "$WORK/payload" "$WORK/echoed"; then
      echo "large upload: echoed bytes differ from the uploaded payload"
      exit 1
    fi
  fi
  echo "large upload: $BYTES bytes delivered in ${seconds}s"
  exit 0
fi
echo "large upload: cut off (HTTP $code after $sent of $BYTES bytes, ${seconds}s)"
exit 1
