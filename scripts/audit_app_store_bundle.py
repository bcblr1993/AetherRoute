#!/usr/bin/env python3
"""Verify exact Store bundle signatures, profiles, extensions and updater exclusion."""
import argparse
import fnmatch
import hashlib
import json
import pathlib
import plistlib
import subprocess
import tempfile
from datetime import datetime, timezone


def validate_profile(profile, bundle_id, team, certificate):
    ent = profile['Entitlements']
    expiry = profile['ExpirationDate'].replace(tzinfo=timezone.utc)
    app_id = ent.get('com.apple.application-identifier', ent.get('application-identifier'))
    if (profile.get('TeamIdentifier') != [team] or profile.get('Platform') != ['OSX']
            or profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices')
            or app_id != team + '.' + bundle_id or expiry <= datetime.now(timezone.utc)
            or ent.get('get-task-allow') or ent.get('com.apple.security.get-task-allow')
            or certificate.upper() not in {hashlib.sha1(c).hexdigest().upper()
                                          for c in profile.get('DeveloperCertificates', [])}):
        raise ValueError('Profile does not authorize this exact Store app, team and certificate.')
    return ent


def audit(app, team, certificate):
    app = app.resolve()
    run = lambda *args: subprocess.check_output(args, stderr=subprocess.DEVNULL)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if not info.get('AetherRouteStoreDistribution') or info.get('AetherRouteDistributionMode') != 'free':
        raise ValueError('Not the free Store product.')
    if any(k.startswith('SU') for k in info) or any(info.get(k) for k in
            ('AetherRouteLicenseServiceURL', 'AetherRouteUpdateManifestURL', 'AetherRouteDistributionSigningPublicKey')):
        raise ValueError('Independent update or licensing configuration is present.')
    forbidden = [p.relative_to(app).as_posix() for p in app.rglob('*')
                 if 'sparkle' in p.name.lower() or p.suffix.lower() in ('.aetherroute', '.yaml', '.conf')]
    if forbidden:
        raise ValueError('Forbidden resources: ' + ', '.join(forbidden))
    bundle_id = info['CFBundleIdentifier']
    extensions = app / 'Contents/Library/SystemExtensions'
    roles = [(app, bundle_id, ['app-proxy-provider', 'packet-tunnel-provider']),
             (extensions / (bundle_id + '.tunnel.systemextension'), bundle_id + '.tunnel', ['packet-tunnel-provider']),
             (extensions / (bundle_id + '.transparent-proxy.systemextension'), bundle_id + '.transparent-proxy', ['app-proxy-provider'])]
    checked = []
    for bundle, identifier, network in roles:
        d = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        if d['CFBundleIdentifier'] != identifier or any(d.get(k) != info[k] for k in
                ('CFBundleShortVersionString', 'CFBundleVersion')):
            raise ValueError('Embedded provider identity/version differs from host.')
        profile_path = bundle / 'Contents/embedded.provisionprofile'
        profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(profile_path)))
        grant = validate_profile(profile, identifier, team, certificate)
        ent = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', str(bundle)))
        if (not ent.get('com.apple.security.app-sandbox') or ent.get('get-task-allow')
                or ent.get('com.apple.security.get-task-allow')
                or ent.get('com.apple.developer.networking.networkextension') != network
                or ent.get('com.apple.developer.team-identifier') != team):
            raise ValueError('Invalid sandbox, debug permission, team or provider entitlements.')
        if 'com.apple.security.temporary-exception.mach-lookup.global-name' in ent:
            raise ValueError('Updater Mach lookup exceptions remain.')
        for key, value in ent.items():
            if key.startswith('com.apple.developer.') or key in ('com.apple.application-identifier', 'application-identifier',
                                                               'keychain-access-groups', 'com.apple.security.application-groups'):
                allowed = grant.get(key)
                if isinstance(value, list):
                    if not isinstance(allowed, list) or any(not any(fnmatch.fnmatchcase(v, pattern)
                            for pattern in allowed) for v in value):
                        raise ValueError('Profile does not grant ' + key)
                elif isinstance(value, str):
                    if not isinstance(allowed, str) or not fnmatch.fnmatchcase(value, allowed):
                        raise ValueError('Profile does not grant ' + key)
                elif value != allowed:
                    raise ValueError('Profile does not grant ' + key)
        with tempfile.TemporaryDirectory() as directory:
            prefix = str(pathlib.Path(directory) / 'cert')
            subprocess.run(['codesign', '-d', '--extract-certificates=' + prefix, str(bundle)],
                           check=True, capture_output=True)
            if hashlib.sha1(pathlib.Path(prefix + '0').read_bytes()).hexdigest().upper() != certificate.upper():
                raise ValueError('Actual signature does not use the profile-authorized certificate.')
        executable = bundle / 'Contents/MacOS' / d['CFBundleExecutable']
        subprocess.run(['lipo', '-verify_arch', 'arm64', str(executable)], check=True)
        checked.append({'identifier': identifier, 'profileSHA256': hashlib.sha256(profile_path.read_bytes()).hexdigest(),
                        'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest()})
    return {'status': 'passed', 'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
            'app': str(app), 'bundles': checked, 'scope': 'Technical bundle audit; runtime, upload and review are separate gates.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--team', required=True)
    parser.add_argument('--certificate', required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    report = audit(args.app, args.team, args.certificate)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
