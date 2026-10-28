#!/usr/bin/env python3
"""Compare a subscription on Mihomo (the reference) and on our engine.

Both engines load a profile, then every leaf node is probed through the
Clash-compatible `/proxies/<name>/delay` API they share. A node Mihomo can
use and we cannot ("ours_fail"), or one our engine never loaded
("ours_missing"), is a compatibility finding.

Mihomo gets the raw subscription. Our engine gets what the app would load:
the caller passes the app-normalized profile (see
scripts/compare_subscription_with_mihomo.sh). The node list on our side comes
from the engine's own `/proxies` answer, so nodes the engine drops are caught
too.

Reports name protocols and options, never servers, ports, passwords, UUIDs
or keys. Subscriptions and engine configs stay in the caller's private work
directory.
"""
import argparse
import copy
from concurrent.futures import ThreadPoolExecutor
import gzip
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
ROUTING_RESOURCES = ROOT / "Config/RoutingResources"

FINDINGS = ("ours_missing", "ours_fail")
CLASS_ORDER = ("ours_missing", "ours_fail", "mihomo_fail", "both_fail",
               "both_ok", "mihomo_missing")
# Groups and built-ins: probing them says nothing about a protocol.
NON_LEAF_TYPES = {
    "selector", "urltest", "fallback", "loadbalance", "relay", "smart",
    "direct", "reject", "rejectdrop", "compatible", "pass", "dns",
}
LISTENER_KEYS = ("port", "socks-port", "redir-port", "tproxy-port",
                 "mixed-port", "external-ui", "external-ui-url",
                 "external-controller-tls", "secret", "tun", "listeners",
                 "interface-name")


def delay_result(answer):
    """Reads a successful `/delay` answer. Both engines report failures as
    HTTP errors; our engine's `delay` is the round trip after the handshake,
    which is 0 ms on loopback, so 0 is still an answer."""
    delay = answer.get("delay")
    if isinstance(delay, int) and not isinstance(delay, bool) and delay >= 0:
        return {"ok": True, "delay": delay}
    return {"ok": False, "error": json.dumps(answer)[:120]}


def classify(mihomo, ours):
    """Outcome of one node; each argument is a result dict or None (absent)."""
    if ours is None:
        return "ours_missing" if mihomo is not None else "absent"
    if mihomo is None:
        return "mihomo_missing"
    if mihomo["ok"] and ours["ok"]:
        return "both_ok"
    if mihomo["ok"]:
        return "ours_fail"
    if ours["ok"]:
        return "mihomo_fail"
    return "both_fail"


def is_finding(name):
    return name in FINDINGS


def node_summary(proxy):
    """Protocol and options of a node, with every secret left out."""
    summary = {"type": str(proxy.get("type", "?")).lower()}
    for key in ("network", "cipher", "flow", "plugin", "client-fingerprint",
                "congestion-controller", "udp-relay-mode", "packet-encoding",
                "obfs", "version", "alpn"):
        if key in proxy and proxy[key] not in (None, "", []):
            value = proxy[key]
            summary[key] = value if isinstance(value, (str, int, bool, list)) else True
    if proxy.get("tls") is True or summary["type"] in ("trojan", "hysteria2", "tuic", "anytls"):
        summary["tls"] = True
    if "reality-opts" in proxy:
        summary["reality"] = True
    if any(key in proxy for key in ("smux", "mux", "multiplex")):
        mux = proxy.get("smux") or proxy.get("mux") or proxy.get("multiplex")
        summary["mux"] = bool(mux.get("enabled", True)) if isinstance(mux, dict) else bool(mux)
    if "ech-opts" in proxy:
        summary["ech"] = True
    if proxy.get("plugin") and isinstance(proxy.get("plugin-opts"), dict):
        mode = proxy["plugin-opts"].get("mode")
        if isinstance(mode, str):
            summary["plugin-mode"] = mode
    if isinstance(proxy.get("ws-opts"), dict) and proxy["ws-opts"].get("max-early-data"):
        summary["ws-early-data"] = True
    return summary


def build_report(raw_proxies, ours_proxy_names, mihomo_results, ours_results,
                 meta, redact_names=False):
    nodes = []
    for index, proxy in enumerate(raw_proxies, start=1):
        name = str(proxy.get("name", f"#{index}"))
        mihomo = mihomo_results.get(name)
        ours = ours_results.get(name) if name in ours_proxy_names else None
        outcome = classify(mihomo, ours)
        if outcome == "absent":
            continue
        nodes.append({
            "index": index,
            "name": f"node-{index}" if redact_names else name,
            "class": outcome,
            "options": node_summary(proxy),
            "mihomo": _result_view(mihomo),
            "ours": _result_view(ours),
        })
    counts = {name: 0 for name in CLASS_ORDER}
    for node in nodes:
        counts[node["class"]] = counts.get(node["class"], 0) + 1
    findings = [node for node in nodes if is_finding(node["class"])]
    findings.sort(key=lambda node: (CLASS_ORDER.index(node["class"]), node["index"]))
    return {
        "schema": 1,
        "meta": meta,
        "counts": counts,
        "findings": findings,
        "nodes": nodes,
        "by_option": _group_findings(findings),
    }


def _result_view(result):
    if result is None:
        return None
    view = {"ok": bool(result["ok"])}
    if result["ok"]:
        view["delay"] = result.get("delay")
    else:
        view["error"] = str(result.get("error", ""))[:120]
    return view


def _group_findings(findings):
    """Which protocol/option combinations the findings concentrate on."""
    groups = {}
    for node in findings:
        options = node["options"]
        key = " ".join(f"{k}={options[k]}" for k in sorted(options))
        groups.setdefault(key, {"class": {}, "count": 0})
        groups[key]["count"] += 1
        groups[key]["class"][node["class"]] = groups[key]["class"].get(node["class"], 0) + 1
    return dict(sorted(groups.items(), key=lambda item: -item[1]["count"]))


def render_markdown(report):
    counts = report["counts"]
    lines = [
        "# Subscription differential: Mihomo vs AetherRoute",
        "",
        f"Source: {report['meta'].get('source', '?')}  ",
        f"Probe: {report['meta'].get('probe_url', '?')} "
        f"(timeout {report['meta'].get('timeout_ms', '?')} ms, "
        f"attempts {report['meta'].get('attempts', '?')})",
        "",
        "| class | nodes |",
        "|---|---|",
    ]
    lines += [f"| {name} | {counts.get(name, 0)} |" for name in CLASS_ORDER]
    lines += ["", "## Findings (Mihomo works or loads it, we do not)", ""]
    if not report["findings"]:
        lines.append("None.")
    else:
        lines += ["| # | node | class | options | Mihomo | ours |", "|---|---|---|---|---|---|"]
        for node in report["findings"]:
            lines.append(
                f"| {node['index']} | {node['name']} | {node['class']} | "
                f"{_options_text(node['options'])} | {_result_text(node['mihomo'])} | "
                f"{_result_text(node['ours'])} |"
            )
        lines += ["", "## Findings by protocol and options", "",
                  "| options | count | classes |", "|---|---|---|"]
        for key, group in report["by_option"].items():
            classes = ", ".join(f"{k} {v}" for k, v in group["class"].items())
            lines.append(f"| {key} | {group['count']} | {classes} |")
    return "\n".join(lines) + "\n"


def _options_text(options):
    return " ".join(f"{k}={v}" for k, v in options.items())


def _result_text(result):
    if result is None:
        return "not loaded"
    if result["ok"]:
        return f"{result.get('delay')} ms"
    return f"fail: {result.get('error', '')}"


def prepare_config(profile, mixed_port, api_port):
    """The profile with its listeners replaced by the harness's own ports."""
    prepared = copy.deepcopy(profile)
    for key in LISTENER_KEYS:
        prepared.pop(key, None)
    prepared["mixed-port"] = mixed_port
    prepared["allow-lan"] = False
    prepared["external-controller"] = f"127.0.0.1:{api_port}"
    prepared["log-level"] = "warning"
    dns = prepared.get("dns")
    if isinstance(dns, dict):
        dns.pop("listen", None)
    return prepared


def load_profile(path):
    """A profile from JSON (as prepared for a remote run) or YAML."""
    if str(path).endswith(".json"):
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("profile is not a mapping")
        return data
    return load_yaml(path)


def load_yaml(path):
    """Parses YAML with the system Ruby (Psych); Python has no YAML module here."""
    script = (
        "require 'yaml'; require 'json'; "
        "data = YAML.safe_load(File.read(ARGV[0], encoding: 'UTF-8'), aliases: true); "
        "STDOUT.write(JSON.generate(data))"
    )
    result = subprocess.run(["/usr/bin/ruby", "-e", script, str(path)],
                            capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        raise ValueError("profile is not valid YAML: " + result.stderr.strip()[-200:])
    data = json.loads(result.stdout)
    if not isinstance(data, dict):
        raise ValueError("profile is not a mapping")
    return data


def unpack_mihomo(archive, work):
    target = Path(work) / "mihomo"
    with gzip.open(archive, "rb") as source, open(target, "wb") as output:
        shutil.copyfileobj(source, output)
    target.chmod(0o700)
    return target


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for_port(port, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket() as sock:
            sock.settimeout(0.5)
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.2)
    raise TimeoutError(f"port {port} did not open")


_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _api(api_port, path, timeout):
    with _OPENER.open(f"http://127.0.0.1:{api_port}{path}", timeout=timeout) as response:
        return json.load(response)


def measure(binary, kind, profile, work, probe_url, timeout_ms, attempts, parallel=8):
    """Starts one engine on `profile`; returns ({leaf names}, {name: result})."""
    directory = Path(work) / f"engine-{kind}"
    directory.mkdir(mode=0o700, exist_ok=True)
    for resource in ("Country.mmdb", "GeoSite.dat"):
        source = ROUTING_RESOURCES / resource
        if source.exists():
            shutil.copyfile(source, directory / resource)
    mixed_port, api_port = free_port(), free_port()
    config = prepare_config(profile, mixed_port, api_port)
    if kind == "ours":
        config.setdefault("mmdb", "Country.mmdb")
        config.setdefault("geosite", "GeoSite.dat")
    config_path = directory / "config.yaml"
    # JSON is valid YAML for both engines and keeps the rewrite lossless.
    config_path.write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")
    config_path.chmod(0o600)
    log = open(directory / "engine.log", "wb")
    # The engine runs with its own directory as cwd.
    binary = Path(binary).resolve()
    if kind == "mihomo":
        command = [str(binary), "-d", str(directory), "-f", str(config_path)]
    else:
        command = [str(binary), "-d", str(directory), "-c", str(config_path)]
    process = subprocess.Popen(command, cwd=directory, stdout=log, stderr=subprocess.STDOUT)
    try:
        try:
            wait_for_port(api_port, timeout=30)
        except TimeoutError:
            if process.poll() is not None:
                tail = (directory / "engine.log").read_text(errors="replace")[-400:]
                raise RuntimeError(f"{kind} engine exited: {tail}") from None
            raise
        proxies = _api(api_port, "/proxies", timeout=15)["proxies"]
        leaves = sorted(
            name for name, info in proxies.items()
            if str(info.get("type", "")).lower() not in NON_LEAF_TYPES
        )

        def probe(name):
            last = None
            for _ in range(max(1, attempts)):
                query = urllib.parse.urlencode({"url": probe_url, "timeout": timeout_ms})
                path = f"/proxies/{urllib.parse.quote(name, safe='')}/delay?{query}"
                try:
                    answer = _api(api_port, path, timeout=timeout_ms / 1000 + 5)
                    last = delay_result(answer)
                    if last["ok"]:
                        return name, last
                except urllib.error.HTTPError as error:
                    body = error.read().decode(errors="replace")[:80]
                    last = {"ok": False, "error": f"HTTP {error.code} {body}"}
                except (urllib.error.URLError, OSError) as error:
                    last = {"ok": False, "error": type(error).__name__}
            return name, last

        with ThreadPoolExecutor(max_workers=parallel) as pool:
            results = dict(pool.map(probe, leaves))
        return set(leaves), results
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        log.close()


def compare(raw_profile, ours_profile, mihomo_binary, ours_binary, work,
            probe_url, timeout_ms, attempts, meta, redact_names=False):
    raw_proxies = [p for p in raw_profile.get("proxies") or [] if isinstance(p, dict)]
    mihomo_names, mihomo_results = measure(
        mihomo_binary, "mihomo", raw_profile, work, probe_url, timeout_ms, attempts)
    ours_names, ours_results = measure(
        ours_binary, "ours", ours_profile, work, probe_url, timeout_ms, attempts)
    meta = dict(meta, probe_url=probe_url, timeout_ms=timeout_ms, attempts=attempts,
                mihomo_loaded=len(mihomo_names), ours_loaded=len(ours_names),
                subscription_nodes=len(raw_proxies))
    return build_report(raw_proxies, ours_names, mihomo_results, ours_results,
                        meta, redact_names=redact_names)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--raw", required=True, type=Path, help="subscription as served (YAML)")
    parser.add_argument("--ours", required=True, type=Path, help="app-normalized profile (YAML)")
    parser.add_argument("--mihomo", required=True, type=Path)
    parser.add_argument("--engine", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--probe-url", default="https://www.gstatic.com/generate_204")
    parser.add_argument("--timeout-ms", type=int, default=5000)
    parser.add_argument("--attempts", type=int, default=2)
    parser.add_argument("--source", default="subscription")
    parser.add_argument("--redact-names", action="store_true")
    parser.add_argument("--to-json", action="store_true",
                        help="only convert --raw and --ours YAML to .json beside them")
    args = parser.parse_args(argv)
    if args.to_json:
        for path in (args.raw, args.ours):
            target = path.with_suffix(".json")
            target.write_text(json.dumps(load_yaml(path), ensure_ascii=False), encoding="utf-8")
            target.chmod(0o600)
        return 0

    report = compare(
        raw_profile=load_profile(args.raw),
        ours_profile=load_profile(args.ours),
        mihomo_binary=args.mihomo,
        ours_binary=args.engine,
        work=args.work,
        probe_url=args.probe_url,
        timeout_ms=args.timeout_ms,
        attempts=args.attempts,
        meta={"source": args.source},
        redact_names=args.redact_names,
    )
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    (args.out / "report.md").write_text(render_markdown(report))
    counts = report["counts"]
    print(" ".join(f"{name}={counts.get(name, 0)}" for name in CLASS_ORDER))
    print(f"report: {args.out / 'report.md'}")
    return 1 if report["findings"] else 0


if __name__ == "__main__":
    sys.exit(main())
