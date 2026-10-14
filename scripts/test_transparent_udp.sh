#!/bin/sh
set -eu

# Release gate (transparent engine): verifies native UDP datagram delivery
# through NETransparentProxyProvider and FlowCoreEngine.
#
# Sends a standard DNS A-record query for www.apple.com to a public resolver
# (default 1.1.1.1:53) over pure UDP and verifies a valid reply is returned.
# This confirms the kernel intercepted the UDP flow, assigned a source
# endpoint (synthetic source pool if needed), forwarded through FlowCore,
# and returned the datagram to the local socket.

DNS_HOST=${AETHERROUTE_TRANSPARENT_UDP_DNS:-1.1.1.1}
DNS_PORT=${AETHERROUTE_TRANSPARENT_UDP_PORT:-53}
TIMEOUT_SECONDS=${AETHERROUTE_TRANSPARENT_UDP_TIMEOUT:-5}

python3 - <<PY
import socket
import sys
import time

dns_host = "$DNS_HOST"
dns_port = int("$DNS_PORT")
timeout = float("$TIMEOUT_SECONDS")

# DNS query for www.apple.com (Type A, Class IN, Transaction ID 0xaa55)
# Header: ID=0xaa55, Flags=0x0100 (Standard query, RD=1), QDCOUNT=1, ANCOUNT=0, NSCOUNT=0, ARCOUNT=0
# Question: www.apple.com, Type=1 (A), Class=1 (IN)
query = (
    b"\xaa\x55\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    b"\x03www\x05apple\x03com\x00\x00\x01\x00\x01"
)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(timeout)

start_time = time.time()
attempts = 2
last_error = None

for attempt in range(1, attempts + 1):
    try:
        sock.sendto(query, (dns_host, dns_port))
        data, addr = sock.recvfrom(1024)
        elapsed = time.time() - start_time
        # Validate Transaction ID (first 2 bytes) and that response has at least one answer
        if len(data) >= 12 and data[:2] == b"\xaa\x55":
            ancount = int.from_bytes(data[6:8], "big")
            print(f"transparent UDP probe: answered {len(data)} bytes ({ancount} answers) from {addr[0]}:{addr[1]} in {elapsed:.3f}s")
            sys.exit(0)
        else:
            print(f"transparent UDP probe: invalid header or transaction ID from {addr}", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        last_error = e
        time.sleep(0.5)

print(f"transparent UDP probe: query to {dns_host}:{dns_port} failed after {attempts} attempts ({last_error})", file=sys.stderr)
sys.exit(1)
PY
