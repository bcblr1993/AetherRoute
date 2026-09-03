#!/bin/zsh
set -euo pipefail
umask 077

OUTPUT=${1:-}
VM_HOST=${2:-192.168.64.6}
FIXTURE_PORT=${3:-17922}
SAMPLES=${4:-12}
INTERVAL_SECONDS=${5:-2}

fail() { print -u2 "fixture/VM correlation capture failed: $*"; exit 1; }
[[ "$OUTPUT" == /* ]] || fail "output must be an absolute path"
[[ ! -e "$OUTPUT" ]] || fail "refusing to overwrite evidence"
[[ "$VM_HOST" == 192.168.64.6 ]] || fail "unexpected VM host"
[[ "$FIXTURE_PORT" == <1-65535> ]] || fail "invalid fixture port"
[[ "$SAMPLES" == <1-100> ]] || fail "invalid sample count"
[[ "$INTERVAL_SECONDS" == <1-30> ]] || fail "invalid interval"
lsof -nP -iTCP@127.0.0.1:"$FIXTURE_PORT" -sTCP:LISTEN >/dev/null \
  || fail "fixture listener is missing"
ssh -o BatchMode=yes -o ConnectTimeout=5 chenxu@"$VM_HOST" \
  'test "$(scutil --nc status AetherRoute 2>/dev/null | sed -n "1p")" = Connected' \
  || fail "VM TUN is not Connected"

mkdir -m 700 "$OUTPUT"
cp "$0" "$OUTPUT/runner.sh"
chmod 400 "$OUTPUT/runner.sh"
print 'sample\tutc\thost_b_gstatic\thost_b_google\thost_b_cloudflare\tvm_tun_gstatic\tvm_tun_google\tvm_tun_cloudflare\tvm_vpn\tvm_stub' > "$OUTPUT/samples.tsv"

probe_host() {
  local url=$1
  curl -4 --silent --show-error --output /dev/null --connect-timeout 3 --max-time 10 \
    --proxy "socks5h://127.0.0.1:$FIXTURE_PORT" --write-out '%{http_code}' "$url" \
    2>/dev/null || print -n 000
}

sample=1
while (( sample <= SAMPLES )); do
  work=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-fixture-vm-correlation.XXXXXX")
  probe_host https://www.gstatic.com/generate_204 > "$work/host-gstatic" & p1=$!
  probe_host https://www.google.com/generate_204 > "$work/host-google" & p2=$!
  probe_host https://cp.cloudflare.com/generate_204 > "$work/host-cloudflare" & p3=$!
  ssh -o BatchMode=yes -o ConnectTimeout=5 chenxu@"$VM_HOST" 'zsh -s' > "$work/vm" <<'REMOTE' &
probe() {
  curl -4 --silent --show-error --output /dev/null --connect-timeout 3 --max-time 10 \
    --write-out '%{http_code}' "$1" 2>/dev/null || print -n 000
}
gstatic=$(probe https://www.gstatic.com/generate_204)
google=$(probe https://www.google.com/generate_204)
cloudflare=$(probe https://cp.cloudflare.com/generate_204)
vpn=$(scutil --nc status AetherRoute 2>/dev/null | sed -n '1p')
stub=$(route -n get 198.18.0.1 2>/dev/null | awk '$1=="interface:"{print $2; exit}')
print "$gstatic\t$google\t$cloudflare\t${vpn:--}\t${stub:--}"
REMOTE
  p4=$!
  wait $p1 || true; wait $p2 || true; wait $p3 || true; wait $p4 || true
  vm_line=$(tail -n 1 "$work/vm" 2>/dev/null || print -- '-\t-\t-\t-\t-')
  print "$sample\t$(date -u '+%Y-%m-%dT%H:%M:%SZ')\t$(cat "$work/host-gstatic")\t$(cat "$work/host-google")\t$(cat "$work/host-cloudflare")\t$vm_line" >> "$OUTPUT/samples.tsv"
  find "$work" -depth -delete
  sleep "$INTERVAL_SECONDS"
  (( sample++ ))
done

awk -F '\t' 'NR > 1 {
  host_failed = ($3 != 204 || $4 != 204 || $5 != 204)
  vm_failed = ($6 != 204 || $7 != 204 || $8 != 204)
  host_fail += host_failed; vm_fail += vm_failed
  shared += (host_failed && vm_failed)
  vm_only += (!host_failed && vm_failed)
  disconnected += ($9 != "Connected" || $10 == "-")
} END {
  print "schema=fixture-vm-https-correlation-v1"
  print "samples=" NR-1
  print "host_fixture_failure_samples=" host_fail+0
  print "vm_tun_failure_samples=" vm_fail+0
  print "shared_failure_samples=" shared+0
  print "vm_only_failure_samples=" vm_only+0
  print "vm_disconnected_samples=" disconnected+0
  print "network_state_mutation=none"
}' "$OUTPUT/samples.tsv" > "$OUTPUT/result.txt"
{
  print "captured_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  print "fixture_port=$FIXTURE_PORT"
  print "vm_host=$VM_HOST"
  print "runner_sha256=$(shasum -a 256 "$OUTPUT/runner.sh" | awk '{print $1}')"
} > "$OUTPUT/metadata.txt"
(cd "$OUTPUT" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort \
  | while IFS= read -r file; do shasum -a 256 "${file#./}"; done > SHA256SUMS)
chmod 400 "$OUTPUT"/*
print "fixture/VM correlation captured: $OUTPUT"
