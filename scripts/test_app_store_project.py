#!/usr/bin/env python3
"""Store channel regressions: keep routing, exclude updater, reject test archives."""
import json
import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock
import audit_app_store_bundle
from generate_app_store_project import ROOT, XCODEGEN, derive


class StoreProjectTests(unittest.TestCase):
    def test_store_channel_preserves_routing_without_modifying_original(self):
        original = json.loads(subprocess.check_output(
            [XCODEGEN, 'dump', '--spec', str(ROOT / 'project.yml'), '--type', 'json', '--no-env']))
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
            self.assertNotIn('com.apple.security.temporary-exception.files.absolute-path.read-write', ent)
            self.assertNotIn('com.apple.security.temporary-exception.apple-events', ent)
            self.assertFalse(any(k.startswith('com.apple.security.temporary-exception.') for k in ent))
            self.assertEqual(ent['com.apple.developer.networking.networkextension'],
                             ['app-proxy-provider', 'packet-tunnel-provider'])
            self.assertNotEqual(pathlib.Path(host['info']['path']).parent, ROOT / 'Config')
        self.assertEqual(json.dumps(original, sort_keys=True), before)

    def test_base_host_entitlements_exclude_applications_rw_and_finder_apple_events(self):
        ent = plistlib.loads((ROOT / 'Config/AetherRoute.entitlements').read_bytes())
        self.assertNotIn('com.apple.security.temporary-exception.files.absolute-path.read-write', ent)
        self.assertNotIn('com.apple.security.temporary-exception.apple-events', ent)

    def test_audit_app_store_bundle_rejects_temporary_exceptions(self):
        for forbidden_key, forbidden_val in [
            ('com.apple.security.temporary-exception.files.absolute-path.read-write', ['/Applications/']),
            ('com.apple.security.temporary-exception.apple-events', ['com.apple.finder']),
            ('com.apple.security.temporary-exception.mach-lookup.global-name', ['com.aetherroute.desktop-spks']),
        ]:
            with self.subTest(key=forbidden_key), tempfile.TemporaryDirectory() as tmp:
                app = pathlib.Path(tmp) / 'AetherRoute.app'
                host_contents = app / 'Contents'
                (host_contents / 'MacOS').mkdir(parents=True)
                (host_contents / 'MacOS/AetherRoute').write_bytes(b'bin')
                (host_contents / 'embedded.provisionprofile').write_bytes(b'cms')
                (host_contents / 'Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleIdentifier': 'com.aetherroute.desktop',
                    'CFBundleExecutable': 'AetherRoute',
                    'CFBundleShortVersionString': '3.0.2',
                    'CFBundleVersion': '2026111702',
                    'AetherRouteStoreDistribution': True,
                    'AetherRouteDistributionMode': 'free',
                }))
                for suffix in ('tunnel', 'transparent-proxy'):
                    ext = host_contents / f'Library/SystemExtensions/com.aetherroute.desktop.{suffix}.systemextension/Contents'
                    (ext / 'MacOS').mkdir(parents=True)
                    (ext / f'MacOS/com.aetherroute.desktop.{suffix}').write_bytes(b'bin')
                    (ext / 'embedded.provisionprofile').write_bytes(b'cms')
                    (ext / 'Info.plist').write_bytes(plistlib.dumps({
                        'CFBundleIdentifier': f'com.aetherroute.desktop.{suffix}',
                        'CFBundleExecutable': f'com.aetherroute.desktop.{suffix}',
                        'CFBundleShortVersionString': '3.0.2',
                        'CFBundleVersion': '2026111702',
                    }))

                cert_bytes = b'test-store-cert'
                cert_sha1 = audit_app_store_bundle.hashlib.sha1(cert_bytes).hexdigest().upper()
                entitlements_blob = plistlib.dumps({
                    'com.apple.security.app-sandbox': True,
                    'com.apple.developer.networking.networkextension': ['app-proxy-provider', 'packet-tunnel-provider'],
                    'com.apple.developer.team-identifier': '5984KQD4D7',
                    forbidden_key: forbidden_val,
                })
                profile_blob = plistlib.dumps({
                    'TeamIdentifier': ['5984KQD4D7'],
                    'Platform': ['OSX'],
                    'ExpirationDate': audit_app_store_bundle.datetime(2030, 1, 1, tzinfo=audit_app_store_bundle.timezone.utc),
                    'DeveloperCertificates': [cert_bytes],
                    'Entitlements': {
                        'com.apple.application-identifier': '5984KQD4D7.com.aetherroute.desktop',
                        'com.apple.developer.networking.networkextension': ['app-proxy-provider', 'packet-tunnel-provider'],
                        'com.apple.developer.team-identifier': '5984KQD4D7',
                    },
                })

                def fake_check_output(args, **kwargs):
                    if args[0] == 'security':
                        return profile_blob
                    if args[0] == 'codesign':
                        return entitlements_blob
                    raise AssertionError(args)

                def fake_run(args, **kwargs):
                    for arg in args:
                        if isinstance(arg, str) and arg.startswith('--extract-certificates='):
                            prefix = arg.split('=', 1)[1]
                            pathlib.Path(prefix + '0').write_bytes(cert_bytes)

                with mock.patch.object(audit_app_store_bundle.subprocess, 'run', side_effect=fake_run), \
                     mock.patch.object(audit_app_store_bundle.subprocess, 'check_output', side_effect=fake_check_output):
                    with self.assertRaisesRegex(ValueError, 'temporary-exception'):
                        audit_app_store_bundle.audit(app, '5984KQD4D7', cert_sha1)

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

    def test_developer_id_guard_rejects_store_edition(self):
        guard = str(ROOT / 'scripts/guard_developer_id_network_extension_build.sh')
        env = dict(os.environ, CONFIGURATION='Release',
                   SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) AETHERROUTE_INDEPENDENT AETHERROUTE_APP_STORE')
        result = subprocess.run(['sh', guard], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('AETHERROUTE_APP_STORE', result.stderr)


if __name__ == '__main__':
    unittest.main()
