#!/bin/sh
# Collects evidence for the 1.0.5 "proxy-dependent desktop apps stop working"
# report, at the moment the failure is happening.
#
# Run this on the affected Mac while 1.0.5 is connected in TUN mode and the
# failure is reproducible. It needs no network of its own and writes everything
# under a timestamped directory, so it can be read back after rolling to 1.0.4.
#
#   sudo -v                                   # cache credentials first
#   sh scripts/collect_105_failure_evidence.sh
#
# sudo is used only for packet captures and a process sample; without it those
# two sections are skipped and the rest still runs.

umask 077
OUT=${1:-$HOME/Desktop/aetherroute-105-evidence-$(date '+%Y%m%d-%H%M%S')}
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 1; }

PROVIDER=com.aetherroute.desktop.tunnel
say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
run() { # run <file> <description> <command...>
  file=$1; shift
  desc=$1; shift
  say "$desc"
  { printf '$ %s\n\n' "$*"; "$@" 2>&1; } >"$OUT/$file"
}

say "writing evidence to $OUT"

# ---------------------------------------------------------------- identity ---
{
  printf 'collected=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf 'macos=%s\n' "$(sw_vers -productVersion)"
  printf 'app_version=%s\n' \
    "$(defaults read /Applications/AetherRoute.app/Contents/Info.plist \
      CFBundleShortVersionString 2>/dev/null)"
  printf 'app_build=%s\n' \
    "$(defaults read /Applications/AetherRoute.app/Contents/Info.plist \
      CFBundleVersion 2>/dev/null)"
  printf 'engine_mode=%s\n' \
    "$(defaults read "$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop" \
      AetherRoute.NetworkEngineMode 2>/dev/null)"
  printf 'routing_mode=%s\n' \
    "$(defaults read "$HOME/Library/Containers/com.aetherroute.desktop/Data/Library/Preferences/com.aetherroute.desktop" \
      defaultRoutingMode 2>/dev/null)"
  printf 'vpn_status=%s\n' "$(scutil --nc status AetherRoute 2>/dev/null | head -1)"
  printf 'default_interface=%s\n' \
    "$(route -n get default 2>/dev/null | awk '/interface:/{print $2;exit}')"
  printf 'provider_pid=%s\n' "$(pgrep -x "$PROVIDER" 2>/dev/null | head -1)"
} >"$OUT/00-identity.txt"
cat "$OUT/00-identity.txt"

run 01-sysext.txt        "system extensions"   systemextensionsctl list
run 02-scutil-dns.txt    "resolver config"     scutil --dns
run 03-scutil-proxy.txt  "system proxy"        scutil --proxy
run 04-routes-v4.txt     "IPv4 routes"         netstat -rn -f inet
run 05-routes-v6.txt     "IPv6 routes"         netstat -rn -f inet6
run 06-interfaces.txt    "interfaces"          ifconfig
run 07-connections.txt   "TCP table"           netstat -an -p tcp
run 08-nc-status.txt     "tunnel detail"       scutil --nc status AetherRoute

# --------------------------------------------------------------- app logs ---
say "AetherRoute logs (last 30m) - this takes a moment"
log show --last 30m --style compact --info --debug \
  --predicate 'subsystem BEGINSWITH "com.aetherroute"' \
  >"$OUT/10-aetherroute-log.txt" 2>&1

# The signals that separate 1.0.5's new recovery path from 1.0.4's.
grep -E \
  'physicalUplinkChanged|networkRecovery|waitingForPhysicalUplink|reassert|coreUnavailable|providerMessage|connectionReadiness|selectedRoute|degradedTraffic|stage=stopTunnel|stage=startTunnel|engineWorker|readiness' \
  "$OUT/10-aetherroute-log.txt" >"$OUT/11-key-events.txt" 2>&1

{
  printf 'event counts over the captured window\n\n'
  for pattern in physicalUplinkChanged networkRecovery providerMessageTimedOut \
    'connectionReadiness activeProbe' 'selectedRoute preserved' \
    coreUnavailable reassert waitingForPhysicalUplink; do
    printf '%-40s %s\n' "$pattern" \
      "$(grep -c "$pattern" "$OUT/10-aetherroute-log.txt" 2>/dev/null)"
  done
} >"$OUT/12-event-counts.txt"
cat "$OUT/12-event-counts.txt"

# ------------------------------------------------------------ live probes ---
# Four paths that fail differently depending on where the break is:
#   A  system resolver  -> is the engine's DNS answering at all
#   B  TCP + system DNS -> the ordinary desktop-app path
#   C  TCP + fixed IP   -> same, minus DNS
#   D  UDP/QUIC         -> the path Chrome prefers
say "probes"
{
  printf '=== A. system resolver (what every native app uses) ===\n'
  for host in www.google.com github.com www.apple.com www.baidu.com; do
    printf '%-18s ' "$host"
    start=$(date '+%s')
    result=$(dscacheutil -q host -a name "$host" 2>/dev/null |
      awk '/ip_address/{printf "%s ", $2}')
    printf '%s (%ss)\n' "${result:-<FAILED>}" "$(( $(date '+%s') - start ))"
  done

  printf '\n=== B. TCP via system DNS (desktop-app path) ===\n'
  for url in https://www.google.com/generate_204 https://github.com \
    https://www.apple.com; do
    printf '%-42s ' "$url"
    curl --noproxy '*' -sS -o /dev/null \
      -w 'code=%{http_code} dns=%{time_namelookup}s conn=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s\n' \
      --max-time 20 "$url" 2>&1 | tail -1
  done

  # NOTE: this one fails on a healthy 1.0.4 too. Under fake-ip the engine routes
  # by reverse-mapping the synthetic address, so handing it a real IP falls
  # through to IP rules. Read it only against the 1.0.4 baseline, never alone.
  printf '\n=== C. TCP with DNS bypassed (CONTROL - fails on 1.0.4 as well) ===\n'
  printf '%-42s ' 'google 204 via --resolve'
  curl --noproxy '*' -sS -o /dev/null \
    -w 'code=%{http_code} conn=%{time_connect}s total=%{time_total}s\n' \
    --max-time 20 --resolve www.google.com:443:142.250.196.100 \
    https://www.google.com/generate_204 2>&1 | tail -1

  printf '\n=== D. direct DNS query to the tunnel resolver ===\n'
  for host in www.google.com github.com; do
    printf -- '--- %s ---\n' "$host"
    dig +time=5 +tries=2 @198.18.0.2 "$host" A 2>&1 |
      grep -E 'status:|ANSWER SECTION|^[a-z]|timed out' | head -6
  done

  printf '\n=== E. what Chrome currently has open ===\n'
  lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null |
    grep -iE 'chrome|Google' | head -20 || printf '(none)\n'
} >"$OUT/20-probes.txt" 2>&1
cat "$OUT/20-probes.txt"

# ------------------------------------------------------- captures + sample ---
if sudo -n true 2>/dev/null; then
  TUN=$(route -n get default 2>/dev/null | awk '/interface:/{print $2;exit}')
  PHYS=$(netstat -rn -f inet 2>/dev/null |
    awk '$1=="default" && $NF !~ /^utun/ {print $NF; exit}')
  say "capturing on ${TUN:-utun?} and ${PHYS:-en?} for 25s"
  [ -n "$TUN" ]  && sudo tcpdump -i "$TUN"  -n -s 128 -w "$OUT/30-$TUN.pcap"  >/dev/null 2>&1 &
  [ -n "$PHYS" ] && sudo tcpdump -i "$PHYS" -n -s 128 -w "$OUT/31-$PHYS.pcap" >/dev/null 2>&1 &
  sleep 3
  # Generate traffic while the capture runs.
  curl --noproxy '*' -sS -o /dev/null --max-time 12 \
    https://www.google.com/generate_204 >/dev/null 2>&1
  dig +time=3 +tries=1 @198.18.0.2 www.apple.com A >/dev/null 2>&1
  sleep 10
  sudo pkill -f 'tcpdump -i' 2>/dev/null
  sleep 2
  for f in "$OUT"/3*.pcap; do
    [ -f "$f" ] || continue
    sudo tcpdump -nr "$f" >"${f%.pcap}.txt" 2>&1
    sudo chown "$(id -u):$(id -g)" "$f" "${f%.pcap}.txt" 2>/dev/null
  done

  PID=$(pgrep -x "$PROVIDER" 2>/dev/null | head -1)
  if [ -n "$PID" ]; then
    say "sampling provider $PID"
    sudo sample "$PID" 5 -file "$OUT/40-provider-sample.txt" >/dev/null 2>&1
    sudo chown "$(id -u):$(id -g)" "$OUT/40-provider-sample.txt" 2>/dev/null
  fi
else
  say "no cached sudo - skipping captures and sample (run 'sudo -v' then retry)"
  printf 'skipped: sudo was not available\n' >"$OUT/30-captures-skipped.txt"
fi

say "done"
printf '\nEvidence directory:\n  %s\n\n' "$OUT"
printf 'Roll back to 1.0.4 when you are done; the directory can be read later.\n'
