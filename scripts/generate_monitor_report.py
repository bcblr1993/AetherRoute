#!/usr/bin/env python3
"""Generates a structured stability and performance audit report from monitoring metrics."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import sys
from typing import Any, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT_DIR = ROOT / "reports" / "monitoring"


def percentile(data: List[float], p: float) -> float:
    if not data:
        return 0.0
    sorted_d = sorted(data)
    idx = (len(sorted_d) - 1) * (p / 100.0)
    floor_idx = math.floor(idx)
    ceil_idx = math.ceil(idx)
    if floor_idx == ceil_idx:
        return sorted_d[int(idx)]
    d0 = sorted_d[floor_idx] * (ceil_idx - idx)
    d1 = sorted_d[ceil_idx] * (idx - floor_idx)
    return d0 + d1


def safe_float(v: Any, default: float = 0.0) -> float:
    try:
        if v is None or v == "":
            return default
        return float(v)
    except (ValueError, TypeError):
        return default


def safe_int(v: Any, default: int = 0) -> int:
    try:
        if v is None or v == "":
            return default
        return int(float(v))
    except (ValueError, TypeError):
        return default


def parse_metrics_csv(csv_path: Path) -> List[Dict[str, Any]]:
    if not csv_path.exists():
        return []
    rows = []
    with open(csv_path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append(r)
    return rows


def parse_incidents(incidents_path: Path) -> List[Dict[str, Any]]:
    if not incidents_path.exists():
        return []
    incidents = []
    with open(incidents_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    incidents.append(json.loads(line))
                except Exception:
                    pass
    return incidents


def analyze_metrics(rows: List[Dict[str, Any]], incidents: List[Dict[str, Any]]) -> Dict[str, Any]:
    if not rows:
        return {"total_samples": 0}

    total_samples = len(rows)
    start_time = rows[0].get("timestamp_iso", "")
    end_time = rows[-1].get("timestamp_iso", "")

    start_epoch = safe_int(rows[0].get("epoch"))
    end_epoch = safe_int(rows[-1].get("epoch"))
    duration_hours = max(0.016, (end_epoch - start_epoch) / 3600.0)

    # CPU
    app_cpus = [safe_float(r.get("app_cpu")) for r in rows if r.get("app_cpu") != ""]
    tun_cpus = [safe_float(r.get("tunnel_cpu")) for r in rows if r.get("tunnel_cpu") != ""]

    # Memory
    app_fps = [safe_float(r.get("app_footprint_mb")) for r in rows if r.get("app_footprint_mb") != ""]
    app_rss = [safe_float(r.get("app_rss_mb")) for r in rows if r.get("app_rss_mb") != ""]
    tun_rss = [safe_float(r.get("tunnel_rss_mb")) for r in rows if r.get("tunnel_rss_mb") != ""]

    # Target mem for app: footprint if present, else rss
    app_mems = app_fps if app_fps else app_rss
    app_mem_type = "Physical Footprint" if app_fps else "RSS"
    app_mem_start = app_mems[0] if app_mems else 0.0
    app_mem_end = app_mems[-1] if app_mems else 0.0
    app_mem_delta = app_mem_end - app_mem_start
    app_mem_rate = app_mem_delta / duration_hours if duration_hours > 0 else 0.0

    tun_rss_start = tun_rss[0] if tun_rss else 0.0
    tun_rss_end = tun_rss[-1] if tun_rss else 0.0
    tun_rss_delta = tun_rss_end - tun_rss_start
    tun_rss_rate = tun_rss_delta / duration_hours if duration_hours > 0 else 0.0

    # Sockets & FDs
    app_fds = [safe_int(r.get("app_fds")) for r in rows if r.get("app_fds") != ""]
    app_cws = [safe_int(r.get("app_close_wait")) for r in rows if r.get("app_close_wait") != ""]
    tcp_est = [safe_int(r.get("tcp_established")) for r in rows]

    # Probes
    proxy_oks = [r.get("proxy_ok") in ("True", "true", "1") for r in rows]
    proxy_avail_pct = (sum(proxy_oks) / total_samples) * 100.0 if total_samples else 0.0
    proxy_totals = [safe_float(r.get("proxy_total_s")) for r in rows if safe_float(r.get("proxy_total_s")) > 0]
    proxy_tls = [safe_float(r.get("proxy_tls_s")) for r in rows if safe_float(r.get("proxy_tls_s")) > 0]

    direct_totals = [safe_float(r.get("direct_total_s")) for r in rows if safe_float(r.get("direct_total_s")) > 0]

    # DNS
    dns_oks = [r.get("dns_ok") in ("True", "true", "1") for r in rows]
    dns_fakes = [r.get("dns_is_fake_ip") in ("True", "true", "1") for r in rows]
    dns_avail_pct = (sum(dns_oks) / total_samples) * 100.0 if total_samples else 0.0
    dns_fake_pct = (sum(dns_fakes) / total_samples) * 100.0 if total_samples else 0.0
    dns_lats = [safe_float(r.get("dns_latency_ms")) for r in rows if safe_float(r.get("dns_latency_ms")) > 0]

    # Logs
    log_errors = sum(safe_int(r.get("log_errors_1m")) for r in rows)
    log_faults = sum(safe_int(r.get("log_faults_1m")) for r in rows)
    log_unconn = sum(safe_int(r.get("log_unconnected_calls")) for r in rows)
    log_tcp_copy = sum(safe_int(r.get("log_tcp_copy_errs")) for r in rows)

    # Worst verdict
    verdicts = [r.get("verdict", "HEALTHY") for r in rows]
    overall_verdict = "HEALTHY"
    if "CRITICAL" in verdicts or incidents:
        overall_verdict = "CRITICAL"
    elif "WARNING" in verdicts:
        overall_verdict = "WARNING"

    return {
        "start_time": start_time,
        "end_time": end_time,
        "duration_hours": round(duration_hours, 2),
        "total_samples": total_samples,
        "overall_verdict": overall_verdict,
        "cpu": {
            "app_mean": round(sum(app_cpus) / len(app_cpus), 2) if app_cpus else 0.0,
            "app_p95": round(percentile(app_cpus, 95), 2),
            "app_max": round(max(app_cpus), 2) if app_cpus else 0.0,
            "tun_mean": round(sum(tun_cpus) / len(tun_cpus), 2) if tun_cpus else 0.0,
            "tun_p95": round(percentile(tun_cpus, 95), 2),
            "tun_max": round(max(tun_cpus), 2) if tun_cpus else 0.0,
        },
        "memory": {
            "app_type": app_mem_type,
            "app_start": round(app_mem_start, 2),
            "app_end": round(app_mem_end, 2),
            "app_delta": round(app_mem_delta, 2),
            "app_rate_mb_hr": round(app_mem_rate, 2),
            "app_max": round(max(app_mems), 2) if app_mems else 0.0,
            "tun_start": round(tun_rss_start, 2),
            "tun_end": round(tun_rss_end, 2),
            "tun_delta": round(tun_rss_delta, 2),
            "tun_rate_mb_hr": round(tun_rss_rate, 2),
            "tun_max": round(max(tun_rss), 2) if tun_rss else 0.0,
        },
        "sockets": {
            "app_close_wait_max": max(app_cws) if app_cws else 0,
            "app_fds_max": max(app_fds) if app_fds else 0,
            "tcp_est_mean": round(sum(tcp_est) / len(tcp_est), 1) if tcp_est else 0,
            "tcp_est_max": max(tcp_est) if tcp_est else 0,
        },
        "network": {
            "proxy_avail_pct": round(proxy_avail_pct, 1),
            "proxy_p50": round(percentile(proxy_totals, 50), 3),
            "proxy_p95": round(percentile(proxy_totals, 95), 3),
            "proxy_max": round(max(proxy_totals), 3) if proxy_totals else 0.0,
            "proxy_tls_p50": round(percentile(proxy_tls, 50), 3),
            "proxy_tls_p95": round(percentile(proxy_tls, 95), 3),
            "direct_p50": round(percentile(direct_totals, 50), 3),
            "direct_p95": round(percentile(direct_totals, 95), 3),
            "dns_avail_pct": round(dns_avail_pct, 1),
            "dns_fake_pct": round(dns_fake_pct, 1),
            "dns_mean_ms": round(sum(dns_lats) / len(dns_lats), 1) if dns_lats else 0.0,
            "dns_max_ms": round(max(dns_lats), 1) if dns_lats else 0.0,
        },
        "logs": {
            "total_errors": log_errors,
            "total_faults": log_faults,
            "unconnected_calls": log_unconn,
            "tcp_copy_failures": log_tcp_copy,
        },
        "incidents": incidents,
    }


def generate_markdown(analysis: Dict[str, Any]) -> str:
    if analysis.get("total_samples", 0) == 0:
        return "# AetherRoute Monitoring Report\n\nNo metric data available.\n"

    cpu = analysis["cpu"]
    mem = analysis["memory"]
    soc = analysis["sockets"]
    net = analysis["network"]
    log = analysis["logs"]
    incs = analysis["incidents"]
    v = analysis["overall_verdict"]

    color_emoji = "🟢" if v == "HEALTHY" else ("🟡" if v == "WARNING" else "🔴")

    lines = [
        f"# AetherRoute 稳定性与运行时性能分析报告",
        f"",
        f"**总体裁定**：{color_emoji} **{v}**  ",
        f"**监控周期**：`{analysis['start_time']}` ~ `{analysis['end_time']}` ({analysis['duration_hours']} 小时)  ",
        f"**采样总数**：`{analysis['total_samples']}` 周期 (1 分钟/次)  ",
        f"**事件告警**：`{len(incs)}` 起  ",
        f"",
        f"---",
        f"",
        f"## 1. 核心资源开销 (CPU & 内存趋势)",
        f"",
        f"| 指标项 | App (UI) | Tunnel (网络扩展) | 状态评估 |",
        f"| :--- | :--- | :--- | :--- |",
        f"| **CPU 平均占用** | `{cpu['app_mean']}%` | `{cpu['tun_mean']}%` | {'✅ 正常' if cpu['app_mean'] < 10 else '⚠️ 偏高'} |",
        f"| **CPU 95 分位 / 峰值** | `{cpu['app_p95']}%` / `{cpu['app_max']}%` | `{cpu['tun_p95']}%` / `{cpu['tun_max']}%` | {'✅ 正常' if cpu['app_max'] < 50 else '⚠️ 存在突刺'} |",
        f"| **内存指标类型** | {mem['app_type']} | Resident Set Size (RSS) | - |",
        f"| **内存 起始 -> 结束** | `{mem['app_start']} MB` -> `{mem['app_end']} MB` | `{mem['tun_start']} MB` -> `{mem['tun_end']} MB` | - |",
        f"| **内存 净增长 / 速率** | `{mem['app_delta']:+} MB` (`{mem['app_rate_mb_hr']:+.2f} MB/h`) | `{mem['tun_delta']:+} MB` (`{mem['tun_rate_mb_hr']:+.2f} MB/h`) | {'✅ 无明显泄漏' if abs(mem['app_rate_mb_hr']) < 10 else '⚠️ 存在内存递增趋势'} |",
        f"| **内存 峰值** | `{mem['app_max']} MB` | `{mem['tun_max']} MB` | {'✅ 远低于 Jetsam 边界' if mem['tun_max'] < 250 else '⚠️ 需关注'} |",
        f"",
        f"---",
        f"",
        f"## 2. 网络通道与数据面延迟表现",
        f"",
        f"| 探测指标 | 代理通道 (Google 204) | 直连对照组 (Baidu) | 差异与稳定性分析 |",
        f"| :--- | :--- | :--- | :--- |",
        f"| **可用性 (SLA)** | `{net['proxy_avail_pct']}%` | - | {'✅ 高可用' if net['proxy_avail_pct'] >= 99.0 else '⚠️ 出现丢包/中断'} |",
        f"| **总延迟 p50 (中位数)** | `{net['proxy_p50']}s` | `{net['direct_p50']}s` | 代理开销约为 `{(net['proxy_p50'] - net['direct_p50']):.3f}s` |",
        f"| **总延迟 p95 / 峰值** | `{net['proxy_p95']}s` / `{net['proxy_max']}s` | `{net['direct_p95']}s` | 握手与转发波动评估 |",
        f"| **TLS 握手耗时 p50 / p95**| `{net['proxy_tls_p50']}s` / `{net['proxy_tls_p95']}s` | - | TLS 1.3 远端加速指标 |",
        f"| **DNS 解析成功率 / 时延**| `{net['dns_avail_pct']}%` (`{net['dns_mean_ms']}ms`) | Fake-IP 覆盖率: `{net['dns_fake_pct']}%` | {'✅ Fake-IP 映射正常' if net['dns_fake_pct'] == 100 else '⚠️ 存在直连回退'} |",
        f"",
        f"---",
        f"",
        f"## 3. 文件句柄与套接字健康度",
        f"",
        f"- **App CLOSE_WAIT 套接字峰值**：`{soc['app_close_wait_max']}` ({'✅ 无孤儿套接字泄漏' if soc['app_close_wait_max'] < 3 else '⚠️ 检测到 CLOSE_WAIT 堆积'})",
        f"- **App 打开文件描述符 (FD) 峰值**：`{soc['app_fds_max']}` ({'✅ 远低于系统上限' if soc['app_fds_max'] < 150 else '⚠️ 句柄偏高'})",
        f"- **系统全局 ESTABLISHED 连接均值**：`{soc['tcp_est_mean']}` (峰值: `{soc['tcp_est_max']}`)",
        f"",
        f"---",
        f"",
        f"## 4. 统一日志与错误统计 (macOS Unified Log)",
        f"",
        f"- **系统错误 (Errors)**：`{log['total_errors']}` 次",
        f"- **系统故障 (Faults)**：`{log['total_faults']}` 次",
        f"- **未连接 NWConnection 调用**：`{log['unconnected_calls']}` 次",
        f"- **TCP Copy 失败次数**：`{log['tcp_copy_failures']}` 次",
        f"",
        f"---",
        f"",
        f"## 5. 异常事件记录 (Incidents Forensic Log)",
        f"",
    ]

    if not incs:
        lines.append("🎉 **监控期间未捕获任何异常事件，系统运行稳定！**\n")
    else:
        lines.append("| 触发时间 | 告警标签 | 严重等级 | 发现的主要问题 | 现场取证快照目录 |")
        lines.append("| :--- | :--- | :--- | :--- | :--- |")
        for inc in incs:
            issues_str = "<br>".join(inc.get("issues", []))
            inc_dir = inc.get("incident_dir", "N/A")
            lines.append(f"| `{inc.get('timestamp')}` | `{inc.get('flag')}` | `{inc.get('verdict')}` | {issues_str} | [`{Path(inc_dir).name}`]({inc_dir}) |")
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate AetherRoute monitoring analysis report.")
    parser.add_argument("--dir", type=str, default=str(DEFAULT_OUT_DIR), help="Path containing metrics_minute.csv")
    parser.add_argument("--out", type=str, default=None, help="Path to write Markdown report (default: <dir>/REPORT.md)")
    args = parser.parse_args()

    out_dir = Path(args.dir)
    csv_path = out_dir / "metrics_minute.csv"
    inc_path = out_dir / "incidents.jsonl"
    report_path = Path(args.out) if args.out else (out_dir / "REPORT.md")

    rows = parse_metrics_csv(csv_path)
    incidents = parse_incidents(inc_path)
    analysis = analyze_metrics(rows, incidents)
    md_content = generate_markdown(analysis)

    report_path.write_text(md_content, encoding="utf-8")
    print(f"Report successfully written to: {report_path}")

    # Also print summary to stdout
    print("\n" + "=" * 70)
    print(f" AetherRoute Monitor Summary [{analysis.get('start_time')} ~ {analysis.get('end_time')}]")
    print(f" Verdict: {analysis.get('overall_verdict')} | Duration: {analysis.get('duration_hours')}h | Samples: {analysis.get('total_samples')}")
    print("=" * 70)
    if "cpu" in analysis:
        print(f" CPU: App avg {analysis['cpu']['app_mean']}% (max {analysis['cpu']['app_max']}%) | Tun avg {analysis['cpu']['tun_mean']}% (max {analysis['cpu']['tun_max']}%)")
        print(f" Memory: App {analysis['memory']['app_start']}MB -> {analysis['memory']['app_end']}MB ({analysis['memory']['app_rate_mb_hr']:+.2f} MB/h) | Tun {analysis['memory']['tun_start']}MB -> {analysis['memory']['tun_end']}MB")
        print(f" Probes: Proxy Avail {analysis['network']['proxy_avail_pct']}% (p50: {analysis['network']['proxy_p50']}s) | DNS Fake-IP {analysis['network']['dns_fake_pct']}% ({analysis['network']['dns_mean_ms']}ms)")
        print(f" Sockets: App Close-Wait max {analysis['sockets']['app_close_wait_max']} | Open FDs max {analysis['sockets']['app_fds_max']}")
        print(f" Incidents: {len(analysis['incidents'])} logged")
    print("=" * 70 + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
