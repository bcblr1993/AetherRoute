#!/usr/bin/env python3
"""Guard the App wiring that the isolated latency model cannot exercise."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def body(source, name):
    start = source.index('func ' + name + '(')
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[brace + 1:end - 1]


class LatencyWiringTests(unittest.TestCase):
    def test_health_results_cannot_publish_display_readings(self):
        source = (ROOT / 'Sources/AetherRouteApp/TunnelManager+Latency.swift').read_text()
        adopted = body(source, 'adoptProviderLatency')
        self.assertIn('recordRouteHealth', adopted)
        for forbidden in ['.merge(', 'recordLatency(', 'publishLatency(', 'proxyLatencies[']:
            self.assertNotIn(forbidden, adopted)

    def test_direct_and_groups_use_same_protocol_probe(self):
        source = (ROOT / 'Sources/AetherRouteApp/TunnelManager+Latency.swift').read_text()
        probe = body(source, 'probeVerifiedMemberLatency')
        self.assertIn('client.displayLatency(', probe)
        self.assertNotIn('return .verified(1)', source)
        sweep = body(source, 'measureVerifiedLatency')
        self.assertNotIn('probeTargets.contains', sweep)
        self.assertNotIn('upper != "DIRECT"', sweep)

    def test_both_menu_openings_use_freshness_policy(self):
        source = (ROOT / 'Sources/AetherRouteApp/AetherRouteApp.swift').read_text()
        self.assertGreaterEqual(source.count('await tunnel.refreshProxyLatencyIfNeeded(group: group.name)'), 2)
        self.assertNotRegex(source, r'proxyLatencies\[group.name\] == nil')


if __name__ == '__main__':
    unittest.main()
