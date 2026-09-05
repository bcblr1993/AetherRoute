#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-data-notice-test.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

python3 - "$ROOT" "$TEMP" <<'PY'
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

root, fixture = map(Path, sys.argv[1:])
for directory in ('scripts', 'Config/Licenses', 'Config/RoutingResources',
                  'Core/Artifacts/macos-arm64'):
    (fixture / directory).mkdir(parents=True, exist_ok=True)
verifier = fixture / 'scripts/verify_licenses.sh'
shutil.copy2(root / 'scripts/verify_licenses.sh', verifier)
# Resource byte/type verification has its own tests. This fixture isolates the
# combined-notice coverage gate and never needs a real core build or database.
resource_verifier = fixture / 'scripts/verify_bundled_routing_resources.sh'
resource_verifier.write_text('#!/bin/sh\nexit 0\n')
resource_verifier.chmod(0o755)
data = json.loads((root / 'Config/RoutingResources/notices.json').read_text())
(fixture / 'Config/RoutingResources/notices.json').write_text(json.dumps(data))
hashes = {}
for role, name in [('transparentProxy', 'libclashrs.a'),
                   ('packetTunnel', 'libclashrs-direct.a')]:
    content = (role + ' test fixture').encode()
    (fixture / 'Core/Artifacts/macos-arm64' / name).write_bytes(content)
    hashes[role] = hashlib.sha256(content).hexdigest()
report = {
    'schemaVersion': 1, 'surface': 'independent', 'coreArtifacts': hashes,
    'components': [{'name': 'runtime-test', 'version': '1', 'license': 'MIT',
                    'repository': 'https://example.invalid/runtime'}] + data['components'],
    'licenses': [{'id': 'MIT', 'name': 'MIT License', 'text': 'Runtime fixture notice',
                  'components': ['runtime-test@1']}] + data['licenses'],
}
report_path = fixture / 'Config/Licenses/ThirdPartyLicenses.json'

def verify(candidate, should_pass, case):
    report_path.write_text(json.dumps(candidate))
    result = subprocess.run([str(verifier), 'source'], capture_output=True, text=True)
    if (result.returncode == 0) != should_pass:
        raise AssertionError(f'{case}: unexpected verifier result\n{result.stdout}{result.stderr}')
    if not should_pass and 'Bundled routing component or complete notice is missing' not in result.stderr:
        raise AssertionError(f'{case}: failed for an unrelated reason\n{result.stderr}')

verify(report, True, 'complete runtime and data notices')
missing = copy.deepcopy(report)
missing['components'] = missing['components'][:1]
missing['licenses'] = missing['licenses'][:1]
verify(missing, False, 'internally consistent runtime-only report')
for index, component in enumerate(data['components'], start=1):
    modified = copy.deepcopy(report)
    modified['components'][index]['repository'] = 'https://example.invalid/wrong-source'
    verify(modified, False, 'changed bundled provenance')
for index, license_entry in enumerate(data['licenses'], start=1):
    modified = copy.deepcopy(report)
    modified['licenses'][index]['text'] = 'Truncated legal notice'
    verify(modified, False, 'incomplete bundled license or attribution')
print('Bundled routing license coverage passed: complete report accepted; omitted data, changed provenance and truncated notices rejected.')
PY
