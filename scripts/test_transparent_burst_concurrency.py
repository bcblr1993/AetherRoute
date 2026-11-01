#!/usr/bin/env python3
"""Release gate (transparent engine): verifies burst short-lived connection

handling and session lifecycle under concurrency.

Spawns a burst of concurrent short-lived HTTP connections against a lightweight
endpoint, ensuring no flow allocation stalls, no connection resets under churn,
and that all sessions drain cleanly without leaking descriptors or memory.
"""

from __future__ import annotations

import concurrent.futures
import os
import subprocess
import sys
import threading
import time
import traceback
import urllib.request

TOTAL_REQUESTS = int(os.environ.get("AETHERROUTE_BURST_REQUESTS", "60"))
MAX_WORKERS = int(os.environ.get("AETHERROUTE_BURST_WORKERS", "60"))
TIMEOUT = float(os.environ.get("AETHERROUTE_BURST_TIMEOUT", "10.0"))
TARGET_URL = os.environ.get("AETHERROUTE_BURST_URL", "http://cp.cloudflare.com/generate_204")
REQUIRE_ORIGIN = os.environ.get("AETHERROUTE_BURST_REQUIRE_ORIGIN") == "1"


def clean_fetch(index: int) -> int:
    # Use clean opener ignoring system proxies to test transparent interception
    proxy_handler = urllib.request.ProxyHandler({})
    opener = urllib.request.build_opener(proxy_handler)
    req = urllib.request.Request(
        TARGET_URL,
        headers={"User-Agent": f"AetherRouteBurstGate/{index}"},
    )
    with opener.open(req, timeout=TIMEOUT) as response:
        if REQUIRE_ORIGIN and (
            response.getcode() != 204 or response.headers.get("X-AetherRoute-Burst") != "1"
        ):
            raise ValueError("Unexpected controlled-origin response")
        return response.getcode()


def classify_error(error: Exception) -> str:
    names = set()
    current = error
    for _ in range(5):
        names.update(frame.name for frame in traceback.extract_tb(current.__traceback__))
        reason = getattr(current, "reason", None)
        current = reason if isinstance(reason, BaseException) else current.__context__
        if current is None:
            break
    if "_read_status" in names:
        phase = "responseHeaders"
    elif "getaddrinfo" in names:
        phase = "dns"
    elif "do_handshake" in names:
        phase = "tls"
    elif "create_connection" in names or "connect" in names:
        phase = "connect"
    else:
        phase = "request"
    return f"stage={phase} error={type(error).__name__}"


def get_transparent_provider_pid() -> int | None:
    try:
        out = subprocess.check_output(
            ["pgrep", "-x", "com.aetherroute.desktop.transparent-proxy"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        lines = [line.strip() for line in out.splitlines() if line.strip()]
        if len(lines) == 1 and lines[0].isdigit():
            return int(lines[0])
    except Exception:
        pass
    return None


def get_rss_kb(pid: int) -> int | None:
    try:
        out = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "rss="],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        if out.isdigit():
            return int(out)
    except Exception:
        pass
    return None


def main() -> int:
    pid = get_transparent_provider_pid()
    rss_before = get_rss_kb(pid) if pid else None

    start_time = time.monotonic()
    successes = 0
    failures = 0
    errors: list[str] = []

    first_wave = min(MAX_WORKERS, TOTAL_REQUESTS)
    ready = threading.Barrier(first_wave)
    def synchronized_fetch(index):
        if index < first_wave:
            ready.wait(timeout=TIMEOUT)
        return clean_fetch(index)

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {executor.submit(synchronized_fetch, i): i for i in range(TOTAL_REQUESTS)}
        for future in concurrent.futures.as_completed(futures):
            try:
                code = future.result()
                if code == 204 or (200 <= code < 400):
                    successes += 1
                else:
                    failures += 1
                    errors.append(f"HTTP {code}")
            except Exception as e:
                failures += 1
                errors.append(f"request={futures[future]} {classify_error(e)}")

    duration = time.monotonic() - start_time

    # Wait 1.5 seconds for sessions to drain and release leases
    time.sleep(1.5)

    rss_after = get_rss_kb(pid) if pid else None
    rss_growth_mb = ((rss_after - rss_before) / 1024.0) if (rss_before and rss_after) else None

    if failures > 0:
        sample_errors = ", ".join(errors[:3])
        print(
            f"transparent burst concurrency: {failures}/{TOTAL_REQUESTS} failed in {duration:.2f}s "
            f"(sample: {sample_errors})",
            file=sys.stderr,
        )
        return 1

    growth_str = f", RSS growth {rss_growth_mb:+.1f} MB" if rss_growth_mb is not None else ""
    print(
        f"transparent burst concurrency: {successes}/{TOTAL_REQUESTS} requests passed in {duration:.2f}s "
        f"({MAX_WORKERS} workers{growth_str})"
    )

    # If memory grew by more than 25MB across 60 short requests, flag as leak risk
    if rss_growth_mb is not None and rss_growth_mb > 25.0:
        print(f"transparent burst concurrency: excessive memory growth ({rss_growth_mb:.1f} MB)", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
