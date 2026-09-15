#!/usr/bin/env python3
"""Watches the proxied data path for the intermittent slowdown seen on 1.0.5.

The failure does not announce itself: during the degraded window the app logs
nothing at all, so a periodic log scrape finds no trace of it. This probes the
data path often enough to catch the window while it is open, and the moment it
sees one it runs collect_105_failure_evidence.sh so the evidence is captured
mid-failure rather than reconstructed afterwards.

Every sample measures two paths at once:

  proxied  https://www.google.com/generate_204   goes through the proxy
  direct   https://www.baidu.com                 matches a DIRECT rule

The direct probe is the control. If both degrade together the problem is the
host or its uplink, not the proxy path, and the sample is marked accordingly
instead of blamed on the tunnel.

  python3 scripts/watch_proxy_degradation.py                 # until Ctrl-C
  python3 scripts/watch_proxy_degradation.py --hours 8

Results land in outputs/105-diagnosis/watch-<timestamp>/: samples.csv for every
probe, plus one evidence directory per incident.
"""

import argparse
import datetime
import os
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
COLLECTOR = os.path.join(ROOT, "scripts", "collect_105_failure_evidence.sh")

PROXIED_URL = "https://www.google.com/generate_204"
DIRECT_URL = "https://www.baidu.com"

# Healthy on this machine is tls~0.19s / total~0.27s for the proxied probe, and
# the observed bad window ran 2.4-18s. Anything past these is unambiguous.
TLS_LIMIT = 1.5
TOTAL_LIMIT = 3.0
# Two in a row, so a single scheduling hiccup does not trigger a collection.
STRIKES = 2
# An incident lasts a while; do not re-collect for the same one.
COOLDOWN_SECONDS = 600


def probe(url, timeout=25):
    """Returns (ok, connect, tls, total, code). Never raises."""
    try:
        proc = subprocess.run(
            ["curl", "--noproxy", "*", "-sS", "-o", "/dev/null", "-w",
             "%{time_connect} %{time_appconnect} %{time_total} %{http_code}",
             "--max-time", str(timeout), url],
            capture_output=True, text=True, timeout=timeout + 10,
        )
        parts = proc.stdout.strip().split()
        if len(parts) != 4:
            return False, 0.0, 0.0, float(timeout), "000"
        conn, tls, total, code = parts
        return code in ("200", "204"), float(conn), float(tls), float(total), code
    except Exception:
        return False, 0.0, 0.0, float(timeout), "err"


def degraded(ok, tls, total):
    return (not ok) or tls > TLS_LIMIT or total > TOTAL_LIMIT


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--interval", type=int, default=20,
                    help="seconds between samples (default: 20)")
    ap.add_argument("--hours", type=float, default=0,
                    help="stop after this many hours (default: run until Ctrl-C)")
    args = ap.parse_args()

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    outdir = os.path.join(ROOT, "outputs", "105-diagnosis", f"watch-{stamp}")
    os.makedirs(outdir, exist_ok=True)
    csv_path = os.path.join(outdir, "samples.csv")
    with open(csv_path, "w") as fh:
        fh.write("utc,proxied_ok,proxied_tls,proxied_total,proxied_code,"
                 "direct_ok,direct_total,verdict\n")

    print(f"watching every {args.interval}s -> {outdir}")
    print(f"degraded when tls>{TLS_LIMIT}s or total>{TOTAL_LIMIT}s; "
          f"collecting after {STRIKES} in a row\n")

    deadline = time.time() + args.hours * 3600 if args.hours else None
    strikes = 0
    last_collection = 0.0
    incidents = 0

    try:
        while deadline is None or time.time() < deadline:
            now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            p_ok, _, p_tls, p_total, p_code = probe(PROXIED_URL)
            d_ok, _, _, d_total, _ = probe(DIRECT_URL, timeout=10)

            bad = degraded(p_ok, p_tls, p_total)
            if bad and not d_ok:
                verdict = "both-degraded"   # host/uplink, not the proxy path
            elif bad:
                verdict = "proxy-degraded"
            else:
                verdict = "ok"

            with open(csv_path, "a") as fh:
                fh.write(f"{now},{p_ok},{p_tls:.3f},{p_total:.3f},{p_code},"
                         f"{d_ok},{d_total:.3f},{verdict}\n")

            line = (f"{now}  proxied tls={p_tls:6.3f}s total={p_total:6.3f}s "
                    f"code={p_code}  direct={'ok' if d_ok else 'FAIL'}  {verdict}")
            print(line, flush=True)

            # Only a proxy-specific degradation is worth a collection.
            strikes = strikes + 1 if verdict == "proxy-degraded" else 0

            if strikes >= STRIKES and time.time() - last_collection > COOLDOWN_SECONDS:
                incidents += 1
                dest = os.path.join(outdir, f"incident-{incidents:02d}-{stamp}")
                print(f"\n  >>> degradation confirmed - collecting to {dest}\n",
                      flush=True)
                try:
                    subprocess.run(["sh", COLLECTOR, dest], timeout=300)
                except Exception as exc:
                    print(f"  collection failed: {exc!r}", flush=True)
                last_collection = time.time()
                strikes = 0

            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\nstopped")

    print(f"\nsamples: {csv_path}")
    print(f"incidents collected: {incidents}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
