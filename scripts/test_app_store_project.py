#!/usr/bin/env python3
"""Store channel regressions: keep routing, exclude updater, reject test archives."""
import json
import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
from generate_app_store_project import ROOT, derive


class StoreProjectTests(unittest.TestCase):
    def test_store_channel_preserves_routing_without_modifying_original(self):
        original = json.loads(subprocess.check_output(
            ['xcodegen', 'dump', '--spec', str(ROOT / 'project.yml'), '--type', 'json', '--no-env']))
        before = json.dumps(original, sort_keys=True)
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            store = derive(original, output, '5984KQD4D7', '1.1.2', '2026100203',
                           'Store Certificate', {})
            host = store['targets']['AetherRoute']
            self.assertNotIn('packages', store)
            self.assertFalse(any('package' in d for d in host['dependencies']))
            self.assertFalse(any(k.startswith('SU') for k in host['info']['properties']))
            flags = host['settings']['base']['SWIFT_ACTIVE_COMPILATION_CONDITIONS']
            self.assertIn('AETHERROUTE_INDEPENDENT', flags)
            self.assertIn('AETHERROUTE_APP_STORE', flags)
            for name in ('AetherRoutePacketTunnel', 'AetherRouteTransparentProxy'):
                self.assertEqual(store['targets'][name]['type'], 'system-extension')
                self.assertTrue(any(d.get('target') == name and d.get('embed') for d in host['dependencies']))
            ent = plistlib.loads((output / 'AetherRoute.entitlements').read_bytes())
            self.assertTrue(ent['com.apple.security.app-sandbox'])
            self.assertTrue(ent['com.apple.developer.system-extension.install'])
            self.assertNotIn('com.apple.security.temporary-exception.mach-lookup.global-name', ent)
            self.assertEqual(ent['com.apple.developer.networking.networkextension'],
                             ['app-proxy-provider', 'packet-tunnel-provider'])
            self.assertNotEqual(pathlib.Path(host['info']['path']).parent, ROOT / 'Config')
        self.assertEqual(json.dumps(original, sort_keys=True), before)

    def test_unsigned_archive_and_automation_are_rejected(self):
        guard = str(ROOT / 'scripts/guard_app_store_build.sh')
        base = dict(os.environ, CODE_SIGNING_ALLOWED='NO')
        self.assertEqual(subprocess.run(['sh', guard], env=dict(base, ACTION='build'),
                                        capture_output=True).returncode, 0)
        self.assertNotEqual(subprocess.run(['sh', guard], env=dict(base, ACTION='install'),
                                           capture_output=True).returncode, 0)
        self.assertNotEqual(subprocess.run(['sh', guard], env=dict(base, ACTION='build',
                                           SWIFT_ACTIVE_COMPILATION_CONDITIONS='AETHERROUTE_QA_AUTOMATION'),
                                           capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
