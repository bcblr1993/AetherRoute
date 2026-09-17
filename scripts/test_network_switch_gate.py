#!/usr/bin/env python3
"""Execute the real gate against fake SSH/Tart; no VM or network changes."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SSH = r'''#!/usr/bin/env python3
import os, pathlib, sys
command=sys.argv[-1]
state=pathlib.Path(os.environ['STUB_STATE'])
with (state/'commands').open('a') as out: out.write(command+'\n')
scenario=os.environ['SCENARIO']
if command == 'pgrep -x AetherRoute': print('100')
elif command == 'pgrep -f com.aetherroute.desktop.tunnel': print('200')
elif command == 'ifconfig en0':
    print('inet 192.168.64.166 netmask 0xffffff00' if scenario == 'existing' else 'inet 192.168.64.6')
elif command.startswith('date '):
    marker=state/'date'
    n=int(marker.read_text())+1 if marker.exists() else 1
    marker.write_text(str(n))
    print(f'2026-09-17 12:00:0{n}')
elif command.startswith('/usr/bin/log'):
    assert "processID == 200" in command
    if scenario != 'no_events': print('stage=physicalUplinkChanged scheduling recovery')
    if scenario not in ('no_events','no_reset') and not (scenario == 'no_removal_reset' and '12:00:02' in command):
        print('stage=networkRecovery coreReset success')
elif command.startswith('curl '):
    print('000' if '--interface en0' in command and scenario != 'direct' else '204')
elif command.startswith('sudo ifconfig'): pass
else: raise SystemExit('unexpected command '+command)
'''

class GateTests(unittest.TestCase):
    def run_gate(self, scenario):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            for name, body in [('ssh', SSH), ('tart', '#!/bin/sh\necho 192.168.64.6\n'), ('sleep', '#!/bin/sh\nexit 0\n')]:
                file = base / name
                file.write_text(body)
                file.chmod(0o700)
            env = dict(os.environ, PATH=str(base)+os.pathsep+os.environ['PATH'], STUB_STATE=str(base), SCENARIO=scenario,
                       AETHERROUTE_SWITCH_PROXY_CANARY_URL='https://canary.invalid/check')
            run = subprocess.run(['sh', str(ROOT/'scripts/test_vm_network_switch.sh')], env=env, capture_output=True, text=True, timeout=30)
            return run, (base/'commands').read_text()

    def test_current_events_and_canary_pass(self):
        result, commands = self.run_gate('ok')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--start '2026-09-17 12:00:02'", commands)

    def test_missing_events_reset_or_removal_evidence_fail(self):
        for scenario in ['no_events', 'no_reset', 'no_removal_reset']:
            with self.subTest(scenario=scenario):
                result, commands = self.run_gate(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('sudo ifconfig en0 -alias 192.168.64.166', commands)

    def test_direct_canary_and_existing_alias_fail_before_mutation(self):
        for scenario in ['direct', 'existing']:
            result, commands = self.run_gate(scenario)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('sudo ifconfig', commands)

if __name__ == '__main__':
    unittest.main()
