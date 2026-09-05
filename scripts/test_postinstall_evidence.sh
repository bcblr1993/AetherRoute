#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-postinstall-evidence.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
python3 - "$ROOT" "$TEMP" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, temporary = map(Path, sys.argv[1:])
fixture = temporary / 'repository'
(fixture / 'scripts').mkdir(parents=True)
(fixture / 'Config').mkdir()
for name in ['verify_postinstall_evidence.sh', 'verify_installed_ne_performance_evidence.sh', 'verify_installed_ne_performance_evidence.py']:
    shutil.copy2(root / 'scripts' / name, fixture / 'scripts' / name)
policy_path = fixture / 'Config/InstalledNEPerformanceBudget.json'
policy = json.loads((root / 'Config/InstalledNEPerformanceBudget.json').read_text())
# Test-only calibration and synthetic samples. Never release evidence.
policy.update(status='calibrated', minimumThroughputRatioBasisPoints=9000,
              maximumAddedP95LatencyMicroseconds=2000, maximumBaselineSpreadBasisPoints=1000,
              calibrationEvidenceSHA256='c' * 64)
collector_text = '# regression-only collector fixture; does not collect or use network\n'
for source in policy['collectorSources']:
    (fixture / source).write_text(collector_text)
evidence = temporary / 'evidence'
performance = evidence / 'installed-ne-performance'
performance.mkdir(parents=True)
candidate_path = temporary / 'candidate.json'
candidate = dict(schemaVersion=1, releaseStatus='notarized-candidate', architecture='arm64',
                 productID='org.aetherroute.client', version='1.0.0', build=123,
                 dmg=dict(sha256='a' * 64), source=dict(manifestSHA256='b' * 64))
def write_json(path, value): path.write_text(json.dumps(value, sort_keys=True) + '\n')
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
write_json(candidate_path, candidate)
write_json(policy_path, policy)
data = dict(schemaVersion=1, collectionStatus='complete', surface='installed-network-extension',
            candidate=dict(dmgSHA256=candidate['dmg']['sha256'], manifestSHA256=sha(candidate_path),
                           sourceManifestSHA256=candidate['source']['manifestSHA256'],
                           productID=candidate['productID'], version=candidate['version'], build=candidate['build']),
            collectorSources={s: sha(fixture / s) for s in policy['collectorSources']}, budgetSHA256=sha(policy_path),
            machine=dict(architecture='arm64', model='TestFixture', macOSBuild='Fixture26', hostNameSHA256='d' * 64),
            topology=dict(kind='controlled-peer', transport='tcp', baseline='same-peer-provider-disconnected',
                          peerIdentitySHA256='e' * 64, internetPath=False), providers={}, samples=[])
clock = 1_000_000_000
for engine in ['tun', 'transparent']:
    provider = dict(bundleID=candidate['productID'] + ('.tunnel' if engine == 'tun' else '.transparent-proxy'),
                    version='1.0.0', build=123, teamID='TESTTEAM01',
                    archivedExecutableSHA256='f' * 64, installedExecutableSHA256='f' * 64,
                    archivedCDHash='a' * 40, installedCDHash='a' * 40)
    data['providers'][engine] = provider
    for direction in ['upload', 'download']:
        for index in range(5):
            pair = dict(engine=engine, direction=direction, pairIndex=index)
            for role in ['baseline', 'candidate']:
                # Stable 1 MiB/s controlled peer: the core's 1 GiB/s floor is
                # deliberately not reapplied to installed NE measurements.
                size = 12 * 1024 * 1024
                m = dict(bytesSent=size, bytesReceived=size, sentPayloadSHA256='1' * 64,
                         receivedPayloadSHA256='1' * 64, startedMonotonicNanoseconds=clock,
                         endedMonotonicNanoseconds=clock + 12_000_000_000,
                         latencyNanoseconds=[1_000_000 if role == 'baseline' else 2_000_000] * 200,
                         providerActive=role == 'candidate', peerIdentitySHA256='e' * 64)
                clock += 13_000_000_000
                if role == 'candidate':
                    m.update(providerPID=321, providerStartedAt='2026-09-05T01:00:00Z',
                             providerBundleID=provider['bundleID'], providerCDHash=provider['installedCDHash'],
                             providerObservedBytesBefore=100, providerObservedBytesAfter=size + 100,
                             counterSource='nettop-process', pathAttribution='provider-flow-observed',
                             providerFlowObservationSHA256='2' * 64)
                pair[role] = m
            data['samples'].append(pair)
metadata = dict(schema='2', machine='arm64', os='Fixture26', candidate_dmg_sha256=candidate['dmg']['sha256'],
                candidate_manifest_sha256=sha(candidate_path), application_signature='Developer ID Application')
result = {key: 'passed' for key in ['notarization', 'stapler', 'gatekeeper', 'clean_install', 'upgrade', 'rollback',
          'tun_canary', 'transparent_canary', 'ipv4_canary', 'ipv6_canary', 'dns_leak', 'bypass', 'recursion',
          'disconnect_restore', 'sleep_wake', 'path_change', 'crash_recovery', 'network_control_restored', 'status']}
result.update(tun_cycles='3', transparent_cycles='3', connected_cpu_p95_basis_points='400',
              combined_resident_memory_bytes='200000000', ui_action_p95_milliseconds='100',
              main_thread_stalls_250ms_or_more='0', raw_xcresult_retained='no', endpoint_data_retained='no')
def write_fields(path, values): path.write_text(''.join(k + '=' + str(v) + '\n' for k, v in values.items()))
def write_evidence(current=data, current_policy=policy, current_result=result):
    write_json(policy_path, current_policy)
    current = copy.deepcopy(current)
    current['budgetSHA256'] = sha(policy_path)
    write_json(performance / 'performance.json', current)
    (performance / 'SHA256SUMS').write_text(sha(performance / 'performance.json') + '  performance.json\n')
    write_fields(evidence / 'metadata.txt', metadata)
    write_fields(evidence / 'result.txt', dict(current_result, installed_ne_performance_evidence_sha256=sha(performance / 'SHA256SUMS')))
    (evidence / 'SHA256SUMS').write_text(''.join(sha(evidence / n) + '  ' + n + '\n' for n in ['metadata.txt', 'result.txt']))
passed = []
def run(name, success=False, extra_env=None):
    r = subprocess.run([str(fixture / 'scripts/verify_postinstall_evidence.sh'), str(evidence),
                        candidate['dmg']['sha256'], sha(candidate_path), str(candidate_path)],
                       text=True, capture_output=True, env=dict(os.environ, **(extra_env or {})))
    assert (r.returncode == 0) == success, (name, r.stdout, r.stderr)
    passed.append(name)
def mutate(name, path, value):
    changed = copy.deepcopy(data)
    target = changed
    for key in path[:-1]: target = target[key]
    target[path[-1]] = value
    write_evidence(changed)
    run(name)
write_evidence()
run('accept-bound-paired-measurements-below-isolated-core-floor', True)
metadata['schema'] = '1'
write_evidence()
run('reject-obsolete-postinstall-schema')
metadata['schema'] = '2'
for key, value in [('dns_leak', 'failed'), ('connected_cpu_p95_basis_points', '501')]:
    write_evidence(current_result=dict(result, **{key: value}))
    run('reject-' + key)
write_evidence(current_result=dict(result, tun_throughput_mib_per_second='1200', transparent_throughput_mib_per_second='1200'))
run('reject-legacy-two-hand-entered-throughput-numbers')
write_evidence(current_policy=dict(policy, status='pending-calibration'))
run('reject-pending-calibration-even-with-complete-samples', extra_env={'AETHERROUTE_ALLOW_UNCALIBRATED_PERFORMANCE': 'YES'})
write_evidence(current_policy=dict(policy, calibrationEvidenceSHA256=None))
run('reject-missing-calibration-evidence')
write_evidence()
saved = performance.rename(temporary / 'saved-performance')
run('reject-missing-measurements')
saved.rename(performance)
write_evidence()
collector = fixture / policy['collectorSources'][0]
collector.write_text('# changed collector\n')
run('reject-stale-collector-hash')
collector.unlink()
run('reject-missing-real-collector')
collector.write_text(collector_text)
for name, path, value in [
    ('incomplete-collection', ['collectionStatus'], 'incomplete'),
    ('isolated-core-surface', ['surface'], 'isolated-core'),
    ('candidate-dmg-drift', ['candidate', 'dmgSHA256'], '3' * 64),
    ('candidate-manifest-drift', ['candidate', 'manifestSHA256'], '3' * 64),
    ('candidate-source-drift', ['candidate', 'sourceManifestSHA256'], '3' * 64),
    ('internet-baseline', ['topology', 'internetPath'], True),
    ('wrong-provider-build', ['providers', 'tun', 'build'], 122),
    ('wrong-provider-signature', ['providers', 'tun', 'installedCDHash'], '3' * 40),
    ('wrong-provider-executable', ['providers', 'tun', 'installedExecutableSHA256'], '3' * 64),
    ('missing-direction-samples', ['samples'], data['samples'][:-1]),
    ('duplicate-pair', ['samples', 1, 'pairIndex'], 0),
    ('different-peer', ['samples', 0, 'candidate', 'peerIdentitySHA256'], '3' * 64),
    ('baseline-provider-still-active', ['samples', 0, 'baseline', 'providerActive'], True),
    ('mismatched-actual-bytes', ['samples', 0, 'candidate', 'bytesReceived'], 1),
    ('payload-integrity', ['samples', 0, 'candidate', 'receivedPayloadSHA256'], '3' * 64),
    ('short-transfer', ['samples', 0, 'candidate', 'endedMonotonicNanoseconds'], 14_000_000_001),
    ('noninteger-byte-count', ['samples', 0, 'candidate', 'bytesSent'], 12582912.0),
    ('insufficient-latency-samples', ['samples', 0, 'candidate', 'latencyNanoseconds'], [1]),
    ('wrong-sample-provider', ['samples', 0, 'candidate', 'providerBundleID'], 'org.unrelated.tunnel'),
    ('missing-process-lifetime', ['samples', 0, 'candidate', 'providerStartedAt'], ''),
    ('boolean-provider-pid', ['samples', 0, 'candidate', 'providerPID'], True),
    ('idle-provider-counter', ['samples', 0, 'candidate', 'providerObservedBytesAfter'], 100),
    ('aggregate-only-attribution', ['samples', 0, 'candidate', 'pathAttribution'], 'pid-present'),
    ('wrong-counter-source', ['samples', 0, 'candidate', 'counterSource'], 'core-invented'),
    ('caller-written-rate', ['samples', 0, 'candidate', 'throughput'], 1200),
]: mutate('reject-' + name, path, value)
changed = copy.deepcopy(data)
changed['samples'][1]['baseline'] = copy.deepcopy(changed['samples'][0]['baseline'])
write_evidence(changed)
run('reject-reused-measurement-interval')
for name, role, ratio, latency in [('measured-throughput-regression', 'candidate', 0.5, None),
                                  ('unstable-baseline', 'baseline', 2, None),
                                  ('measured-added-latency', 'candidate', 1, 20_000_000)]:
    changed = copy.deepcopy(data)
    for pair in changed['samples'][:5]:
        m = pair[role]
        if name == 'unstable-baseline' and pair['pairIndex'] != 0: continue
        m['bytesSent'] = m['bytesReceived'] = int(m['bytesReceived'] * ratio)
        if latency: m['latencyNanoseconds'] = [latency] * 200
    write_evidence(changed)
    run('reject-' + name)
write_evidence()
(performance / 'performance.json').write_text('{}\n')
run('reject-altered-checksummed-measurements')
write_evidence()
(performance / 'raw-network.log').write_text('fixture\n')
run('reject-extra-raw-performance-log')
(performance / 'raw-network.log').unlink()
write_evidence()
(evidence / 'raw-network.log').write_text('fixture\n')
run('reject-extra-raw-postinstall-log')
(evidence / 'raw-network.log').unlink()
write_evidence()
run('accept-restored-complete-fixture', True)
for status in ['notarized-test-candidate', 'signed-local-test-candidate']:
    write_json(candidate_path, dict(candidate, releaseStatus=status))
    r = subprocess.run([str(fixture / 'scripts/verify_installed_ne_performance_evidence.sh'),
                        str(performance), str(candidate_path)], text=True, capture_output=True)
    assert r.returncode != 0 and 'production notarized candidate manifest' in r.stderr
    passed.append('reject-production-approval-for-' + status)
write_json(candidate_path, candidate)
for name in passed: print('PASS: ' + name)
print('Post-install performance contract passed: ' + str(len(passed)) + ' controlled cases; no real network or product mutation.')
PY
