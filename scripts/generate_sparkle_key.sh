#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG_DIR="$ROOT/Config"
PRIV_KEY="$CONFIG_DIR/sparkle_ed25519_priv.key"
PUB_KEY="$CONFIG_DIR/sparkle_ed25519_pub.key"

if [ -f "$PRIV_KEY" ] && [ -f "$PUB_KEY" ]; then
  echo "Sparkle Ed25519 keys already exist:"
  echo "  Private: $PRIV_KEY"
  echo "  Public:  $(cat "$PUB_KEY")"
  exit 0
fi

mkdir -p "$CONFIG_DIR"

swift -e '
import Foundation
import CryptoKit

let privateKey = Curve25519.Signing.PrivateKey()
let rawPriv = privateKey.rawRepresentation.base64EncodedString()
let rawPub = privateKey.publicKey.rawRepresentation.base64EncodedString()

let privPath = "'"$PRIV_KEY"'"
let pubPath = "'"$PUB_KEY"'"

try! rawPriv.write(toFile: privPath, atomically: true, encoding: .utf8)
try! rawPub.write(toFile: pubPath, atomically: true, encoding: .utf8)

print("Generated Sparkle Ed25519 Private Key: \(privPath)")
print("Public Key: \(rawPub)")
'

chmod 600 "$PRIV_KEY"
echo "Sparkle signing keys generated successfully."
