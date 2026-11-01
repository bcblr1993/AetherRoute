#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
from pathlib import Path
import os,subprocess,sys,tempfile
root=Path(sys.argv[1]);policy=root/'scripts/test_engine_dependency_security.py'
# Exercise the real checker under the VM's missing-tomllib condition on every
# machine, even when the host happens to provide Python 3.11 or newer.
runner='''import builtins,runpy,sys
original=builtins.__import__
def portable_import(name,*args,**kwargs):
    if name=="tomllib": raise ModuleNotFoundError("VM has no tomllib")
    return original(name,*args,**kwargs)
builtins.__import__=portable_import
sys.argv=[sys.argv[1],sys.argv[2]]
runpy.run_path(sys.argv[0],run_name="__main__")
'''
def entry(name,version):return '\n[[package]]\nname = "'+name+'"\nversion = "'+version+'"\n'
base=entry('hickory-resolver','0.26.3')+entry('russh','0.64.1')
cases=[('actual-lock',(root/'Core/Engine/Cargo.lock').read_text(),True),
       ('optional-agent-absent',base,True),
       ('unsafe-resolver',base+entry('hickory-resolver','0.26.1'),False),
       ('unsafe-ssh',entry('hickory-resolver','0.26.3')+entry('russh','0.62.5'),False),
       ('unsafe-agent',base+entry('pageant','0.2.0'),False),
       ('prerelease',entry('hickory-resolver','0.26.3')+entry('russh','0.64.1-rc.1'),False),
       ('missing-required',entry('hickory-resolver','0.26.3'),False),
       ('duplicate-field',base+'\n[[package]]\nname = "russh"\nname = "other"\nversion = "0.64.1"\n',False)]
with tempfile.TemporaryDirectory(prefix='aetherroute-security-policy.') as work:
    for label,content,success in cases:
        path=Path(work)/(label+'.lock');path.write_text(content)
        result=subprocess.run([sys.executable,'-I','-c',runner,str(policy),str(path)],capture_output=True,text=True)
        assert (result.returncode==0)==success,(label,result.stdout,result.stderr)
        if not success:assert 'Unsafe engine dependency lockfile:' in result.stderr,(label,result.stderr)
        print('PASS: dependency-policy '+label)
print('Engine dependency policy is portable without tomllib and rejects unsafe locks')
PY
