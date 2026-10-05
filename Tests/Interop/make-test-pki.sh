#!/bin/sh
# Creates the interop servers' TLS material in DIRECTORY: a one-day test CA
# (ca.pem) and a localhost server certificate it signs (cert.pem, key.pem).
# Prints the server certificate's SHA-256 fingerprint (colon-separated) so the
# tests can pin it. Works with OpenSSL 3 and the LibreSSL shipped with macOS.
# Usage: make-test-pki.sh /absolute/directory
set -eu

DIRECTORY=${1:?usage: make-test-pki.sh /absolute/directory}
cd "$DIRECTORY"

cat >extensions.cnf <<'EOF'
[ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash

[server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost
EOF

openssl req -new -newkey rsa:2048 -nodes -subj "/CN=AetherRoute Interop CA" \
  -keyout ca-key.pem -out ca.csr >/dev/null 2>&1
openssl x509 -req -days 1 -in ca.csr -signkey ca-key.pem \
  -extfile extensions.cnf -extensions ca -out ca.pem >/dev/null 2>&1

openssl req -new -newkey rsa:2048 -nodes -subj /CN=localhost \
  -keyout key.pem -out server.csr >/dev/null 2>&1
openssl x509 -req -days 1 -in server.csr -CA ca.pem -CAkey ca-key.pem \
  -set_serial 2 -extfile extensions.cnf -extensions server \
  -out cert.pem >/dev/null 2>&1

rm -f ca.csr server.csr ca-key.pem extensions.cnf
openssl x509 -in cert.pem -noout -fingerprint -sha256 | cut -d= -f2
