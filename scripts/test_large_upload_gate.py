#!/usr/bin/env python3
"""Exercise the real upload gate without making network requests."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
MOCK = r'''
import base64, json, os, pathlib, sys
args = sys.argv[1:]
payload = pathlib.Path(args[args.index('--data-binary') + 1][1:]).read_bytes()
large = len(payload) >= 1048576
mode = os.environ['UPLOAD_GATE_CASE']
code, sent, status = 200, len(payload), 0
echo = 'data:application/octet-stream;base64,' + base64.b64encode(payload).decode()
if mode == 'small-timeout' and not large: status = 28
if mode == 'small-http-error' and not large: code = 403
if large:
    if mode == 'large-timeout': status = 28
    if mode == 'large-http-error': code = 500
    if mode == 'short-send': sent -= 1
    if mode == 'wrong-bytes':
        echo = 'data:application/octet-stream;base64,' + base64.b64encode(payload[:-1]).decode()
    if mode == 'wrong-encoding': echo = 'unexpected body'
    if mode == 'invalid-base64': echo = 'data:application/octet-stream;base64,?'
response = {} if large and mode == 'missing-echo' else {'data': echo}
pathlib.Path(args[args.index('-o') + 1]).write_text(json.dumps(response))
print(code, sent, '120.01' if status else '0.01', end='')
sys.exit(status)
'''


def main():
    cases = {'success': 0, 'small-timeout': 2, 'small-http-error': 2,
             'large-timeout': 1, 'large-http-error': 1, 'short-send': 1,
             'wrong-bytes': 1, 'wrong-encoding': 1, 'invalid-base64': 1,
             'missing-echo': 1}
    with tempfile.TemporaryDirectory(prefix='aetherroute-upload-gate-') as directory:
        mock = Path(directory) / 'curl'
        mock.write_text(f'#!{sys.executable}\n' + MOCK)
        mock.chmod(0o700)
        for mode, expected in cases.items():
            environment = dict(os.environ, PATH=directory + ':' + os.environ['PATH'],
                               UPLOAD_GATE_CASE=mode)
            environment.pop('AETHERROUTE_LARGE_UPLOAD_BYTES', None)
            result = subprocess.run(['sh', str(ROOT / 'scripts/test_large_upload.sh')],
                                    env=environment, capture_output=True, text=True,
                                    timeout=30)
            if result.returncode != expected:
                raise AssertionError(f'{mode}: expected {expected}, got {result.returncode}; '
                                     f'{result.stdout} {result.stderr}')
            if (expected == 0) != ('bytes delivered' in result.stdout):
                raise AssertionError(f'{mode}: misleading delivery verdict: {result.stdout}')
    print(f'Large upload gate: {len(cases)} delivery and negative controls passed')


if __name__ == '__main__':
    main()
