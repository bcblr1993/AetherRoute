#!/bin/sh
set -eu

# Execute the complete matrix driver and its real remote prepare helper using
# local command fixtures. No VM, app, system extension or network is started.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-vm-priming-test.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

python3 - "$ROOT" "$TEMP" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

root, temporary = map(Path, sys.argv[1:])
fixture = temporary / 'fixture'
(fixture / 'scripts').mkdir(parents=True)
driver = fixture / 'scripts/test_vm_acceptance_matrix.sh'
shutil.copy2(root / 'scripts/test_vm_acceptance_matrix.sh', driver)
(fixture / 'scripts/test_runtime_acceptance.sh').write_text('#!/bin/sh\nexit 99\n')
candidate = temporary / 'candidate.zip'
with zipfile.ZipFile(candidate, 'w') as archive:
    archive.writestr('AetherRoute.app/Contents/Info.plist', 'fixture')
mock_bin = temporary / 'bin'
mock_bin.mkdir()
mock = mock_bin / 'command-fixture'
mock.write_text(r'''#!/usr/bin/env python3
import hashlib,json,os,pathlib,shutil,subprocess,sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
base=pathlib.Path(os.environ['MOCK_STATE_ROOT'])
state_path=base/'state.json'
state=json.loads(state_path.read_text())
def save(): state_path.write_text(json.dumps(state))
def event(kind, **values):
    state['events'].append(dict(kind=kind,**values)); save()
def shell(command):
    raise SystemExit(subprocess.run(['sh','-c',command],env=os.environ).returncode)
if name=='tart':
    if args==['list']: print('local mock-vm running')
    elif args==['ip','mock-vm']: print('127.0.0.1')
    else: raise SystemExit('unexpected real-VM action')
elif name=='scp':
    source=args[-2]; destination=args[-1].split(':',1)[1]
    shutil.copy2(source,base/'remote'/pathlib.Path(destination).name)
elif name=='ssh':
    cmd=args[-1]
    if cmd=='true': pass
    elif cmd.startswith('df -Pk /Applications'): print('999999999')
    elif cmd.startswith('mktemp -d /tmp/aetherroute-vm-matrix.'): print('/tmp/aetherroute-vm-matrix.fixture')
    elif cmd.startswith('shasum -a 256 '):
        print(hashlib.sha256((base/'remote/candidate.zip').read_bytes()).hexdigest()+'  candidate.zip')
    elif cmd.startswith('set -e\n  cd '): event('install')
    elif cmd.startswith('/usr/libexec/PlistBuddy '): print('2026090501')
    elif cmd.startswith('grep -aq "qaAutomation autoConnect"'): pass
    elif cmd.startswith('sh ') and 'prime-extensions.sh' in cmd:
        raise SystemExit(subprocess.run(['sh',str(base/'remote/prime-extensions.sh'),'2026090501'],env=os.environ).returncode)
    elif cmd.startswith('for path in /tmp/candidate.zip'): pass
    elif cmd.startswith("find '/tmp/aetherroute-vm-matrix."):
        for child in (base/'remote').iterdir(): child.unlink()
        event('remote-cleanup')
    elif cmd.startswith('AETHERROUTE_ACCEPTANCE_PRIVILEGED_OBSERVATION=YES '):
        assert state['versions']=={'tun':'2026090501','transparent':'2026090501'}
        assert [e['engine'] for e in state['events'] if e['kind']=='prepare']==['tun','transparent']
        event('score'); print('0 failed')
    elif cmd.startswith('set -e\n      PREF='):
        event('scoring-setup'); shell(cmd)
    elif cmd.startswith('for i in $(seq 1 30); do'): pass
    elif cmd.startswith('PREF='): shell(cmd)
    else: raise SystemExit('unexpected SSH command: '+cmd)
elif name=='osascript':
    state['app']=False; state['provider']=False; save()
elif name=='pgrep':
    running=state['app'] if '-x' in args else state['provider']
    if running: print('123')
    else: raise SystemExit(1)
elif name=='sleep': pass
elif name=='open':
    assert args[:2]==['-a','/Applications/AetherRoute.app']
    flag=args[-1]
    assert flag in ('AETHERROUTE_QA_AUTOCONNECT=0','AETHERROUTE_QA_AUTOCONNECT=1')
    engine=state.get('engine','tun'); state['app']=True
    if flag.endswith('=0'):
        assert not state['provider']
        event('prepare',engine=engine,autoConnect=False)
        if not (state['case']=='stale' and engine=='transparent'):
            state['versions'][engine]='2026090501'
        if state['case']=='regresses' and engine=='transparent': state['versions']['tun']='2026081469'
    else:
        assert state['versions']=={'tun':'2026090501','transparent':'2026090501'}
        event('connect',engine=engine); state['provider']=True
    save()
elif name=='defaults':
    action,key=args[0],args[2]
    if key=='AetherRoute.NetworkEngineMode':
        if action=='read':
            if 'engine' not in state: raise SystemExit(1)
            print(state['engine'])
        elif action=='write':
            prepared=sum(e['kind']=='prepare' for e in state['events'])
            if state['case']=='restore-fails' and prepared==2 and not state['app'] and args[-1]=='transparent':
                event('restore-failed'); raise SystemExit(1)
            state['engine']=args[-1]; event('engine-write',value=args[-1])
        elif action=='delete':
            state.pop('engine',None); event('engine-delete')
        else: raise SystemExit(99)
    elif key in ('defaultRoutingMode','AetherRoute.LocalProxySettings'):
        if action=='write':
            state[key]=args[-1]; event('other-preference-write',key=key)
        elif action=='read': print(state[key])
        else: raise SystemExit(99)
    else: raise SystemExit('unexpected preference '+key)
elif name=='systemextensionsctl':
    assert args==['list']
    for engine,extension in [('tun','tunnel'),('transparent','transparent-proxy')]:
        print('* * TEAM com.aetherroute.desktop.'+extension+' (1.0.0/'+state['versions'][engine]+') AetherRoute [activated enabled]')
        print('TEAM com.aetherroute.desktop.'+extension+' (1.0.0/1) AetherRoute [terminated waiting to uninstall on reboot]')
    if state['case']=='duplicate' and state['versions']['transparent']=='2026090501':
        print('* * TEAM com.aetherroute.desktop.transparent-proxy (1.0.0/2026090501) AetherRoute [activated enabled]')
else: raise SystemExit('unexpected mock command '+name)
''')
mock.chmod(0o755)
for name in ['tart','scp','ssh','osascript','pgrep','sleep','open','defaults','systemextensionsctl']:
    (mock_bin / name).symlink_to(mock.name)

for case, original, should_pass in [
    ('healthy', 'transparent', True),
    ('absent', None, True),
    ('stale', 'transparent', False),
    ('duplicate', 'transparent', False),
    ('regresses', 'transparent', False),
    ('restore-fails', 'transparent', False),
]:
    state_root = temporary / case
    (state_root / 'remote').mkdir(parents=True)
    (state_root / 'home').mkdir()
    state = {'case':case, 'versions':{'tun':'2026081469','transparent':'2026081469'},
             'app':False,'provider':False,'events':[],
             'defaultRoutingMode':'global','AetherRoute.LocalProxySettings':'original-proxy-data'}
    if original is not None: state['engine']=original
    (state_root / 'state.json').write_text(json.dumps(state))
    env = dict(os.environ, PATH=str(mock_bin)+os.pathsep+os.environ['PATH'],
               HOME=str(state_root/'home'), MOCK_STATE_ROOT=str(state_root),
               AETHERROUTE_MATRIX_ENGINES='tun', AETHERROUTE_MATRIX_ROUTING='rule')
    args=[str(driver),str(candidate),'mock-vm']
    if case!='stale': args.append(str(state_root/'report'))
    completed = subprocess.run(args, env=env, capture_output=True, text=True, timeout=30)
    if (completed.returncode==0)!=should_pass:
        raise AssertionError(case+': '+completed.stdout+completed.stderr)
    final=json.loads((state_root/'state.json').read_text())
    events=final['events']
    prepares=[e for e in events if e['kind']=='prepare']
    assert [e['engine'] for e in prepares]==['tun','transparent'], (case,events)
    assert all(e['autoConnect'] is False for e in prepares)
    if should_pass:
        assert sum(e['kind']=='score' for e in events)==1
        scoring=next(i for i,e in enumerate(events) if e['kind']=='scoring-setup')
        prepared=max(i for i,e in enumerate(events[:scoring]) if e['kind']=='prepare')
        restoration=[e for e in events[prepared+1:scoring] if e['kind'] in ('engine-write','engine-delete')]
        assert restoration==([{'kind':'engine-write','value':original}] if original is not None
                             else [{'kind':'engine-delete'}]), (case,restoration)
    else:
        assert not any(e['kind'] in ('score','scoring-setup','connect','other-preference-write') for e in events)
        assert final.get('engine')==original
        assert final['defaultRoutingMode']=='global'
        assert final['AetherRoute.LocalProxySettings']=='original-proxy-data'
    if case=='stale':
        reports=list((fixture/'outputs/vm-acceptance').glob('matrix.*'))
        assert len(reports)==1
        report=reports[0]
    else: report=state_root/'report'
    assert report.is_dir() and (report/'extension-priming.txt').is_file()
    result=(report/'result.txt').read_text()
    assert ('stage=matrix' if should_pass else 'stage=extension-priming') in result
    assert ('exit_status=0' in result)==should_pass
    subprocess.run(['shasum','-a','256','-c','SHA256SUMS'],cwd=report,check=True,capture_output=True)
    assert not list((state_root/'remote').iterdir())
    print('PASS: '+case)
print('VM extension priming regressions passed: two-engine prepare, strict registrations, restoration, failed-score exclusion and persistent evidence.')
PY
