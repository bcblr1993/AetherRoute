#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-matrix-lifecycle-test.XXXXXX")
trap 'find "$TEMP" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

python3 - "$ROOT" "$TEMP" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

root, temporary = map(Path, sys.argv[1:])
helper = root / 'scripts/vm_matrix_lifecycle.sh'
bin_dir = temporary / 'bin'
bin_dir.mkdir()
mock = bin_dir / 'fixture'
mock.write_text(r'''#!/usr/bin/env python3
import json,os,pathlib,sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
base=pathlib.Path(os.environ['MOCK_ROOT'])
path=base/'state.json'
s=json.loads(path.read_text())
def save(): path.write_text(json.dumps(s))
case=s['case']
if name=='defaults': print('2026090501')
elif name=='pgrep':
    assert args[0]=='-x'
    if args[1]=='AetherRoute': ids=['101'] if s['app'] else []
    else: ids=s['providers'].get(args[1].removeprefix('com.aetherroute.desktop.'),[])
    if ids: print('\n'.join(ids))
    else: raise SystemExit(1)
elif name=='ps':
    pid=args[args.index('-p')+1]
    if args[-1]=='lstart=':
        print('Sat Sep  5 02:00:00 2026' if pid=='101' else 'Sat Sep  5 02:01:00 2026')
    else:
        extension='tunnel' if pid=='201' else 'transparent-proxy'
        print(base/('resident-'+extension))
elif name=='date':
    if args==['+%s']:
        print(s['ticks']); s['ticks']+=1; save()
    else:
        assert args[0]=='-j'
        print('2026-09-05 02:00:00' if '02:00:00' in args[3] else '2026-09-05 02:01:00')
elif name=='osascript':
    assert 'with timeout of 5 seconds' in args
    s['quit']=True
    s['app']=case=='app-stuck'
    if case=='process-exited': s['providers']={}
    save()
elif name=='scutil':
    if args==['--proxy']:
        print('<dictionary> {\n  HTTPEnable : '+('1' if s['quit'] and case=='proxy-changed' else '0')+'\n}')
    else:
        assert args==['--nc','status','AetherRoute']
        print('Connected' if case=='still-connected' and s['quit'] else 'Disconnected')
elif name=='netstat':
    if case=='observation-failed' and s['quit']: raise SystemExit(2)
    if '-f' in args:
        print('Destination Gateway Flags Netif Expire')
        print('default fe80::%utun0 UGcIg utun0')
        if case=='ipv6-route-left' and s['quit']: print('default fe80::%utun4 UGcIg utun4')
    else:
        print('Proto Recv-Q Send-Q Local Address Foreign Address (state)')
        if case=='listener-left' and s['quit']:
            print('tcp4 0 0 127.0.0.1.7890 *.* LISTEN')
        if case=='ipv6-listener-left' and s['quit']:
            print('tcp6 0 0 ::1.7891 *.* LISTEN')
elif name=='route':
    bad=s['quit'] and (case=='route-left' or (case=='stub-route-left' and args[-1]=='198.18.0.2'))
    print('gateway: 192.168.64.1\ninterface: '+('utun4' if bad else 'en0'))
elif name=='log':
    assert '--info' in args and '--start' in args
    predicate=args[-1]
    if 'applicationTermination' in predicate:
        assert args[args.index('--start')+1]=='2026-09-05 02:00:00'
        if case!='missing-app-stop':
            print('stage=applicationTermination disconnect complete stopped='+('false' if case=='app-stop-false' else 'true'))
    else:
        assert args[args.index('--start')+1]=='2026-09-05 02:01:00'
        extension='tunnel' if '== 201 ' in predicate else 'transparent-proxy'
        if extension in s.get('unstarted',[]): raise SystemExit(0)
        # A stale event belongs to an earlier process lifetime and is not
        # returned for the --start boundary the real helper must supply.
        if case=='stale-lifetime': raise SystemExit(0)
        if extension=='tunnel':
            print('stage=startTunnel requested\nstage=startCore success')
            if s['quit'] and case!='missing-provider-stop':
                print('stage=stopTunnel requested')
                if case!='incomplete-stop': print('stage=stopTunnel complete')
            if s['quit'] and case=='restarted-after-stop': print('stage=startTunnel requested')
        else:
            print('stage=startProxy requested\nstage=startProxy success')
            if s['quit'] or case=='idle-readiness': print('stage=stopProxy requested\nstage=stopProxy success')
elif name=='sleep': raise SystemExit('one-attempt fixture must not sleep')
else: raise SystemExit('unexpected command '+name)
''')
mock.chmod(0o755)
for name in ['defaults','pgrep','ps','date','osascript','scutil','netstat','route','log','sleep']:
    (bin_dir/name).symlink_to(mock.name)

cases = [
    ('resident-stopped','tun',True), ('resident-transparent','transparent',True),
    ('process-exited','tun',True), ('unstarted-other','tun',True),
    ('app-stuck','tun',False), ('still-connected','tun',False),
    ('listener-left','tun',False), ('ipv6-listener-left','tun',False),
    ('route-left','tun',False), ('stub-route-left','tun',False),
    ('ipv6-route-left','tun',False), ('proxy-changed','tun',False),
    ('missing-app-stop','transparent',False), ('app-stop-false','tun',False),
    ('missing-provider-stop','tun',False), ('incomplete-stop','tun',False),
    ('restarted-after-stop','tun',False), ('stale-lifetime','tun',False),
    ('wrong-candidate','tun',False), ('duplicate-provider','tun',False),
    ('observation-failed','tun',False), ('exercised-unstarted','tun',False),
]
for case, engine, passes in cases:
    base=temporary/case
    base.mkdir()
    app=base/'AetherRoute.app'
    for ext in ['tunnel','transparent-proxy']:
        bundled=app/'Contents/Library/SystemExtensions'/('com.aetherroute.desktop.'+ext+'.systemextension')/'Contents/MacOS'/('com.aetherroute.desktop.'+ext)
        bundled.parent.mkdir(parents=True)
        bundled.write_text('candidate-'+ext)
        (base/('resident-'+ext)).write_text('candidate-'+ext)
    env=dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],
             MOCK_ROOT=str(base), AETHERROUTE_APP_PATH=str(app),
             AETHERROUTE_MATRIX_QUIT_TIMEOUT_SECONDS='1', TMPDIR=str(base))
    state={'case':case,'app':False,'quit':False,'providers':{},'ticks':0}
    if case=='unstarted-other':
        state.update(providers={'transparent-proxy':['202']},unstarted=['transparent-proxy'])
    path=base/'state.json'
    path.write_text(json.dumps(state))
    baseline=base/'baseline.txt'
    result=subprocess.run([str(helper),'baseline','2026090501',str(baseline)],env=env,capture_output=True,text=True)
    assert result.returncode==0, (case,result.stdout,result.stderr)
    state=json.loads(path.read_text())
    state['app']=True
    exercised='tunnel' if engine=='tun' else 'transparent-proxy'
    state['providers'][exercised]=['201' if engine=='tun' else '202']
    if case=='duplicate-provider': state['providers'][exercised].append('203')
    if case=='wrong-candidate': (base/'resident-tunnel').write_text('different-build')
    if case=='exercised-unstarted': state['unstarted']=['tunnel']
    path.write_text(json.dumps(state))
    result=subprocess.run([str(helper),'quit','2026090501',str(baseline),engine],env=env,capture_output=True,text=True,timeout=15)
    assert (result.returncode==0)==passes, (case,result.stdout,result.stderr)
    assert not list(base.glob('aetherroute-matrix-lifecycle.*')), case
    if passes: assert 'quit verified:' in result.stdout
    print('PASS: '+case)

for case, passes in [('active-readiness',True),('idle-readiness',False),('stale-lifetime',False)]:
    # Reuse the already verified transparent candidate fixture, with a live
    # App and an unchanged resident process, varying only current lifecycle.
    base=temporary/'resident-transparent'
    state={'case':case,'app':True,'quit':False,'providers':{'transparent-proxy':['202']},'ticks':0}
    (base/'state.json').write_text(json.dumps(state))
    env=dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],
             MOCK_ROOT=str(base), AETHERROUTE_APP_PATH=str(base/'AetherRoute.app'),TMPDIR=str(base))
    result=subprocess.run([str(helper),'ready','2026090501','transparent'],env=env,capture_output=True,text=True)
    assert (result.returncode==0)==passes, (case,result.stdout,result.stderr)
    assert not list(base.glob('aetherroute-matrix-lifecycle.*'))
    print('PASS: '+case)
print('VM matrix lifecycle regressions passed: 25 cases; candidate-bound resident stop, network restoration and active readiness.')
PY
