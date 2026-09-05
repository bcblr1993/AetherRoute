#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-core-variant-test.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

python3 - "$ROOT" "$TEMP" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

root, temporary = map(Path,sys.argv[1:])
fixture=temporary/'repository'
(fixture/'scripts').mkdir(parents=True)
(fixture/'Core/Artifacts/macos-arm64').mkdir(parents=True)
(fixture/'Config').mkdir()
(fixture/'Config/ProtocolCoreEvidence.json').write_text('{"fixture":true}\n')
helper=fixture/'scripts/test_candidate_core.sh'
shutil.copy2(root/'scripts/test_candidate_core.sh',helper)
build=r'''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$0" in
  *build_direct_core.sh) role=packet; features=$AETHERROUTE_DIRECT_CORE_FEATURES; archive=libclashrs-direct.a ;;
  *) role=flow; features=$AETHERROUTE_CORE_FEATURES; archive=libclashrs.a ;;
esac
printf '%s:%s\n' "$role" "$features" >>"$MOCK_EVENTS"
case "$role:$features" in
 flow:aether-flow-only|packet:aether-embedded) variant=normal ;;
 flow:aether-flow-only,aether-diagnostics|packet:aether-embedded,aether-diagnostics) variant=diagnostics ;;
 *) exit 98 ;;
esac
printf '%s-%s\n' "$role" "$variant" >"$root/Core/Artifacts/macos-arm64/$archive"
if [ "$variant" = normal ] && [ "${MOCK_CONTAMINATE:-}" = "$role" ]; then
  printf 'aether_%s stage=unexpected\n' "$role" >>"$root/Core/Artifacts/macos-arm64/$archive"
fi
if [ "$variant" = diagnostics ] && [ "${MOCK_MISSING_MARKER:-}" != "$role" ]; then
  printf 'aether_%s stage=fixture\n' "$role" >>"$root/Core/Artifacts/macos-arm64/$archive"
fi
'''
for script in ['build_core.sh','build_direct_core.sh']:
    p=fixture/'scripts'/script;p.write_text(build);p.chmod(0o755)
protocol=fixture/'scripts/verify_protocol_matrix.sh'
protocol.write_text('''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
echo protocol-normal >>"$MOCK_EVENTS"
test "$(cat "$root/Core/Artifacts/macos-arm64/libclashrs.a")" = flow-normal
test "$(cat "$root/Core/Artifacts/macos-arm64/libclashrs-direct.a")" = packet-normal
test "${MOCK_PROTOCOL_REJECT:-0}" = 0
''')
protocol.chmod(0o755)
mock_bin=temporary/'bin';mock_bin.mkdir()
file_tool=mock_bin/'file'
file_tool.write_text('#!/bin/sh\ntest "${MOCK_FILE_FAIL:-0}" = 0 || exit 2\ntest "$1" = -b || exit 2\ncase "$2" in *.text) echo "ASCII text" ;; *) echo "Mach-O 64-bit executable arm64" ;; esac\n')
file_tool.chmod(0o755)
strings_tool=mock_bin/'strings'
strings_tool.write_text('#!/bin/sh\ntest "${MOCK_STRINGS_FAIL:-0}" = 0 || exit 2\nexec "$REAL_STRINGS" "$@"\n')
strings_tool.chmod(0o755)
events=temporary/'events.txt'
env=dict(os.environ,PATH=str(mock_bin)+os.pathsep+os.environ['PATH'],
         MOCK_EVENTS=str(events),REAL_STRINGS=shutil.which('strings'),
         AETHERROUTE_CORE_FEATURES='inherited-invalid-override',
         AETHERROUTE_DIRECT_CORE_FEATURES='inherited-invalid-override')
passed=[]
def run(label,args,success=True,extra=None):
    r=subprocess.run([str(helper),*args],env=dict(env,**(extra or {})),text=True,capture_output=True)
    assert (r.returncode==0)==success,(label,r.stdout,r.stderr)
    passed.append(label)
    return r
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def source_manifest():
    p=temporary/'source.txt'
    p.write_text(''.join(sha(fixture/name)+'  '+name+'\n' for name in [
        'Core/Artifacts/macos-arm64/libclashrs.a',
        'Core/Artifacts/macos-arm64/libclashrs-direct.a',
        'Config/ProtocolCoreEvidence.json']))
    return p

metadata={}
for variant in ['normal','diagnostics']:
    events.write_text('')
    r=run('build-'+variant,['build',variant])
    data=json.loads(r.stdout);metadata[variant]=data
    expected=['flow:aether-flow-only','packet:aether-embedded','protocol-normal']
    if variant=='diagnostics':expected+=['flow:aether-flow-only,aether-diagnostics','packet:aether-embedded,aether-diagnostics']
    assert events.read_text().splitlines()==expected
    assert data['variant']==variant and data['diagnosticsIncluded']==(variant=='diagnostics')
    assert data['protocolReference']['matchesCandidateArtifacts']==(variant=='normal')
    assert data['flow']['artifactSHA256']==sha(fixture/'Core/Artifacts/macos-arm64/libclashrs.a')
    assert data['packet']['artifactSHA256']==sha(fixture/'Core/Artifacts/macos-arm64/libclashrs-direct.a')
    manifest=source_manifest()
    run('bind-'+variant,['bind',variant,str(manifest),json.dumps(data)])
    run('reject-cross-variant-'+variant,['bind','diagnostics' if variant=='normal' else 'normal',str(manifest),json.dumps(data)],False)
    changed=dict(data,flow=dict(data['flow'],artifactSHA256='0'*64))
    run('reject-actual-hash-drift-'+variant,['bind',variant,str(manifest),json.dumps(changed)],False)

for role in ['flow','packet']:
    run('reject-normal-diagnostics-'+role,['build','normal'],False,{'MOCK_CONTAMINATE':role})
    run('reject-missing-diagnostics-'+role,['build','diagnostics'],False,{'MOCK_MISSING_MARKER':role})
for variant in ['normal','diagnostics']:
    events.write_text('')
    run('reject-protocol-mismatch-'+variant,['build',variant],False,{'MOCK_PROTOCOL_REJECT':'1'})
    assert events.read_text().splitlines()==['flow:aether-flow-only','packet:aether-embedded','protocol-normal']
run('reject-string-inspection-failure',['build','normal'],False,{'MOCK_STRINGS_FAIL':'1'})
run('reject-unknown-variant',['build','preview'],False)

app=temporary/'AetherRoute.app'
(app/'Contents/MacOS').mkdir(parents=True)
(app/'Contents/Frameworks').mkdir()
(app/'Contents/MacOS/AetherRoute').write_text('normal app executable\n')
extra=app/'Contents/Frameworks/OtherBridge'
extra.write_text('normal unrelated bridge\n')
run('built-normal',['built','normal',str(app)])
run('reject-file-classification-failure',['built','normal',str(app)],False,{'MOCK_FILE_FAIL':'1'})
for marker in ['flow','packet']:
    extra.write_text('aether_'+marker+' stage=unexpected\n')
    run('reject-diagnostic-marker-in-extra-MachO-'+marker,['built','normal',str(app)],False)
extra.write_text('normal unrelated bridge\n')
bridge=app/'Contents/Frameworks/AetherRouteFlowCoreBridge'
bridge.write_text('aether_flow stage=fixture\n')
run('built-diagnostics',['built','diagnostics',str(app)])
bridge.write_text('normal bridge\n')
run('reject-dropped-built-diagnostics',['built','diagnostics',str(app)],False)

# Execute each builder's actual jq manifest program for both variants, without
# archive, signing, notarization, installing, or mutating real core artifacts.
for builder in ['build_signed_local_test_candidate.sh','build_notarized_test_candidate.sh']:
    source=(root/'scripts'/builder).read_text()
    block=source.split('MANIFEST="$TEMPORARY/$ARTIFACT_NAME.json"',1)[1].split('>"$MANIFEST"',1)[0]
    program=block[block.index("'{schemaVersion")+1:block.rfind("'")]
    parameters=re.findall(r'--(argjson|arg)\s+([A-Za-z0-9_]+)\b',block)
    for variant,data in metadata.items():
        args=['jq','-n']
        for kind,name in parameters:
            value=json.dumps(data) if name=='core' else '1' if kind=='argjson' else 'fixture'
            args+=['--'+kind,name,value]
        result=subprocess.run(args+[program],check=True,capture_output=True,text=True)
        candidate=json.loads(result.stdout)
        assert candidate['schemaVersion']==1
        assert candidate['core']==data
        assert candidate['safety']['diagnosticsIncluded']==(variant=='diagnostics')
        assert not candidate['safety']['productionApproved']
        passed.append('manifest-'+builder+'-'+variant)

for case in passed: print('PASS: '+case)
print('Test candidate core variants passed: '+str(len(passed))+' cases; normal protocol reference, distinct diagnostics, frozen hashes and every packaged Mach-O.')
PY
