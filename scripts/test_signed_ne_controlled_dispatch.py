#!/usr/bin/env python3
"""Offline real shell/plutil/ZIP dispatch tests; signatures are explicit stubs."""
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import uuid

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / 'signed_ne_prebuilt_runner.sh'
SOURCE = SCRIPT.read_text().split('\ncommand=${1:-}\n')[0]
SWIFT = (HERE.parent / 'Tests/AetherRouteUITests/SignedNEProbe.swift').read_text()
HELPER = HERE / 'validation/controlled_probe.py'
HAS_OFFLINE_RUNTIME = (
    'AETHERROUTE_OFFLINE_RUNTIME_RECORD' in os.environ and
    'AETHERROUTE_OFFLINE_ARTIFACTS' in os.environ and
    'AETHERROUTE_OFFLINE_CONSUMER' in os.environ
)

if HAS_OFFLINE_RUNTIME:
    RUNTIME_RAW = Path(os.environ['AETHERROUTE_OFFLINE_RUNTIME_RECORD']).read_bytes()
    PYTHON = json.loads(RUNTIME_RAW)['pythonPath']
    ARTIFACTS = Path(os.environ['AETHERROUTE_OFFLINE_ARTIFACTS'])
    CONSUMER = Path(os.environ['AETHERROUTE_OFFLINE_CONSUMER'])
else:
    RUNTIME_RAW = b'{}'
    PYTHON = 'python3'
    ARTIFACTS = Path('/tmp')
    CONSUMER = Path('/tmp')
KIND = 'AETHERROUTE_SIGNED_PROBE_KIND'
URL = 'AETHERROUTE_SIGNED_PROBE_URL'
SHA = 'AETHERROUTE_SIGNED_PROBE_SHA256'
BINDINGS = 'AETHERROUTE_SIGNED_PROBE_BINDINGS'
BINDINGS_SHA = 'AETHERROUTE_SIGNED_PROBE_BINDINGS_SHA256'
RUN = 'AETHERROUTE_SIGNED_NE_RUN_ID'
CANDIDATE = 'AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST_SHA256'
CYCLES = 'AETHERROUTE_SIGNED_NE_CYCLES'


def digest(raw): return hashlib.sha256(raw).hexdigest()
def canonical(obj): return json.dumps(obj, sort_keys=True, separators=(',', ':')).encode()
def private_file(path, raw):
    path.write_bytes(raw)
    path.chmod(0o600)


@unittest.skipUnless(HAS_OFFLINE_RUNTIME, "AetherRoute offline runtime environment not configured")
class DispatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='aether-dispatch-fixture.')
        cls.root = Path(cls.temporary.name).resolve()
        cls.run_id = uuid.uuid4().hex
        cls.session = Path('/private/tmp/aether-ne-session.' + cls.run_id)
        cls.session.mkdir(mode=0o700)
        cls.stages = [Path('/private/tmp/aether-ne-probe.' + uuid.uuid4().hex) for _ in range(3)]
        for stage in cls.stages: stage.mkdir(mode=0o700)
        cls.helper = cls.session / 'controlled_probe.py'
        cls.binding_file = cls.session / 'cycle-bindings.json'
        cls.dns = cls.root / 'dns.sh'
        cls.dns.write_text('#!/bin/sh\nexit 0\n'); cls.dns.chmod(0o700)
        cls.bin = cls.root / 'bin'; cls.bin.mkdir()
        for name, body in {
            'codesign': '''#!/bin/sh
case "$1" in --verify) exit 0;; esac
for last do :; done
case "$last" in
 *AetherRouteUITests-Runner.app) id=com.aetherroute.app.ui-tests.xctrunner; authority='Apple Development: fixture'; hash=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;;
 *AetherRouteUITests.xctest) id=com.aetherroute.app.ui-tests; authority='Apple Development: fixture'; hash=cccccccccccccccccccccccccccccccccccccccc;;
 *) id=com.aetherroute.app; authority='Developer ID Application: fixture'; hash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;;
esac
printf 'Identifier=%s\nAuthority=%s\nTeamIdentifier=TESTTEAM00\nCDHash=%s\n' "$id" "$authority" "$hash" >&2
''', 'spctl': '#!/bin/sh\nexit 0\n'
        }.items():
            file = cls.bin/name; file.write_text(body); file.chmod(0o700)
        cls.app = cls.root / 'AetherRoute.app'
        (cls.app/'Contents').mkdir(parents=True)
        with (cls.app/'Contents/Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier':'com.aetherroute.app','CFBundleShortVersionString':'1.0.0','CFBundleVersion':'2026090503'},stream)
        cls.signing = cls.root/'signing.json'
        cls.signing.write_text(json.dumps({'schemaVersion':2,'teamID':'TESTTEAM00','profiles':[
            {'role':'direct-host','bundleID':'com.aetherroute.app'},
            {'role':'packet-tunnel','bundleID':'com.aetherroute.app.tunnel'},
            {'role':'transparent-proxy','bundleID':'com.aetherroute.app.transparent-proxy'}]}))
        ui = cls.root/'Tests/AetherRouteUITests';ui.mkdir(parents=True)
        (ui/'AetherRouteUITests.swift').write_text('frozen UI fixture\n')
        (ui/'SignedNEProbe.swift').write_text('frozen helper fixture\n')
        rows=''.join(digest(p.read_bytes())+'  '+str(p.relative_to(cls.root))+'\n' for p in sorted(ui.iterdir()))
        cls.source_manifest=cls.root/'source.txt'; cls.source_manifest.write_text(rows+'MANIFEST_SHA256  '+digest(rows.encode())+'\n')
        cls.candidate=cls.root/'candidate.json'
        cls.candidate.write_text(json.dumps({'schemaVersion':1,'product':'AetherRoute','architecture':'arm64',
            'releaseStatus':'notarized-test-candidate','sourceManifestSHA256':digest(rows.encode()),'version':'1.0.0','build':'2026090503'}))
        cls.candidate_sha=digest(cls.candidate.read_bytes())
        cls.products=cls.root/'Products'
        test_bundle=cls.products/'Debug/AetherRouteUITests-Runner.app/Contents/PlugIns/AetherRouteUITests.xctest'
        test_bundle.mkdir(parents=True); (test_bundle/'fixture').write_text('native-test-bundle-fixture')
        cls.original=cls.products/'Fixture.xctestrun'
        cls.original_data={'AetherRouteUITests':{'TestHostPath':'__TESTROOT__/Debug/AetherRouteUITests-Runner.app',
            'TestBundlePath':'__TESTHOST__/Contents/PlugIns/AetherRouteUITests.xctest',
            'UITargetAppPath':'__TESTROOT__/Debug/AetherRoute.app',
            'DependentProductPaths':['__TESTROOT__/Debug/Other.framework','__TESTROOT__/Debug/AetherRoute.app'],
            'EnvironmentVariables':{'KEEP':'runner'},'TestingEnvironmentVariables':{'KEEP':'framework'},
            'UITargetAppEnvironmentVariables':{'KEEP':'target'}}}
        with cls.original.open('wb') as stream:plistlib.dump(cls.original_data,stream)
        cls.archive=cls.root/'runner.zip'
        env=cls.base_environment()
        p=cls.invoke('package_runner',str(cls.signing),str(cls.products),str(cls.candidate),str(cls.source_manifest),str(cls.archive),env=env)
        if p.returncode: raise AssertionError(p.stderr.decode())

    @classmethod
    def tearDownClass(cls):
        for path in [cls.session]+cls.stages:
            if path.is_symlink():path.unlink()
            elif path.exists():shutil.rmtree(path)
        cls.temporary.cleanup()

    @classmethod
    def base_environment(cls):
        env={k:v for k,v in os.environ.items() if not k.startswith('AETHERROUTE_')}
        env.update({'PATH':str(cls.bin)+':'+env.get('PATH','/usr/bin:/bin'), 'TMPDIR':str(cls.root),
                    'FIXTURE_ROOT':str(cls.root),'FIXTURE_APP':str(cls.app),'FIXTURE_CANDIDATE':str(cls.candidate),
                    CYCLES:'3','AETHERROUTE_SIGNED_DNS_PROBE_SCRIPT':str(cls.dns),
                    'AETHERROUTE_SIGNED_DNS_PROBE_SHA256':digest(cls.dns.read_bytes())})
        return env

    @classmethod
    def invoke(cls,*arguments,env):
        tail='''
ROOT="$FIXTURE_ROOT"
INSTALLED_APP="$FIXTURE_APP"
validate_candidate_manifest "$FIXTURE_CANDIDATE"
case "$1" in
  roundtrip)
    file=$2; validate_prepare_environment tun
    inject_environment_value "$file" AETHERROUTE_SIGNED_NE_ENGINE tun
    inject_environment_value "$file" AETHERROUTE_SIGNED_NE_CYCLES "$CYCLES"
    inject_environment_value "$file" AETHERROUTE_SIGNED_DNS_PROBE_SCRIPT "$DNS_PROBE"
    inject_environment_value "$file" AETHERROUTE_SIGNED_DNS_PROBE_SHA256 "$DNS_SHA"
    inject_probe_environment "$file"; verify_probe_environment "$file";;
  verify)
    validate_prepare_environment tun; verify_probe_environment "$2";;
  *) "$@";;
esac
'''
        return subprocess.run(['/bin/sh','-s','--',*arguments],input=(SOURCE+tail).encode(),capture_output=True,env=env,timeout=30)

    def setUp(self):
        self.env=self.base_environment()
        self.env.update({KIND:'controlled-relay-v1',BINDINGS:str(self.binding_file),RUN:self.run_id,CANDIDATE:self.candidate_sha})
        for path in [self.session]+self.stages:path.chmod(0o700)
        if self.helper.exists() or self.helper.is_symlink(): self.helper.unlink()
        private_file(self.helper,HELPER.read_bytes())
        private_file(self.session/'python-runtime.json', RUNTIME_RAW)
        self.plans=[];bindings=[]
        for i,stage in enumerate(self.stages,1):
            for name in ['plan.json','server-cert.pem']:
                f=stage/name
                if f.exists() or f.is_symlink():f.unlink()
            certificate=b'offline placeholder certificate; never used for HTTPS'
            private_file(stage/'server-cert.pem',certificate)
            plan={'schemaVersion':1,'runID':self.run_id,'engine':'tun','cycle':i,'candidateManifestSHA256':self.candidate_sha,
                  'peerID':'c'*64,'peerSourceSHA256':'d'*64,'hostname':'aether-performance.test','port':62116,
                  'controlAddress':'192.168.64.1','dataAddress':'203.0.113.123','requestID':format(i,'032x'),
                  'token':'fixture-token-'+('x'*32),'certificateSHA256':digest(certificate)}
            self.plans.append(plan)
            private_file(stage/'plan.json',canonical(plan))
            response=json.dumps({'requestID':plan['requestID'],'peerID':plan['peerID'],'accessPath':'relay'},separators=(',',':')).encode()
            bindings.append({'cycle':i,'stagePath':str(stage),'planSHA256':digest(canonical(plan)),
                'requestIdentitySHA256':digest(plan['requestID'].encode()),'peerIdentitySHA256':digest(plan['peerID'].encode()),
                'expectedResponseSHA256':digest(response)})
        self.bindings={'schema':1,'runID':self.run_id,'engine':'tun','cycles':3,'candidateManifestSHA256':self.candidate_sha,
                       'pythonPath':PYTHON,'helperPath':str(self.helper),'runtimeRecordSHA256':digest(RUNTIME_RAW),'bindings':bindings}
        self.write_bindings()

    def write_bindings(self,raw=None):
        if self.binding_file.exists() or self.binding_file.is_symlink():self.binding_file.unlink()
        raw=canonical(self.bindings) if raw is None else raw
        private_file(self.binding_file,raw); self.env[BINDINGS_SHA]=digest(raw)

    def write_plan(self,index):
        raw=canonical(self.plans[index]); private_file(self.stages[index]/'plan.json',raw)
        self.bindings['bindings'][index]['planSHA256']=digest(raw);self.write_bindings()

    def validate(self,success=False):
        p=self.invoke('validate_prepare_environment','tun',env=self.env)
        if success:self.assertEqual(p.returncode,0,p.stderr.decode())
        else:self.assertNotEqual(p.returncode,0)
        self.assertNotIn(b'fixture-token-',p.stdout+p.stderr)
        return p

    def public(self):
        self.env=self.base_environment();self.env.update({URL:'https://owner.example/canary',SHA:'b'*64})

    def roundtrip(self):
        target=self.root/(uuid.uuid4().hex+'.xctestrun')
        with target.open('wb') as stream:plistlib.dump(self.original_data,stream)
        p=self.invoke('roundtrip',str(target),env=self.env)
        self.assertEqual(p.returncode,0,p.stderr.decode())
        return target

    def test_controlled_inputs_pin_real_swift_helper_and_runtime(self):
        self.assertIn('"'+digest(HELPER.read_bytes())+'"',SWIFT)
        self.assertEqual(digest(Path(PYTHON).read_bytes()), json.loads(RUNTIME_RAW)['pythonSHA256'])
        self.assertIn('try runtime.validate()',SWIFT)
        self.validate(True)

    def test_schema_strings_are_rejected_by_actual_prepare_functions(self):
        self.bindings['schema']='1'; self.write_bindings(); self.validate()
        self.bindings['schema']=1
        self.plans[0]['schemaVersion']='1'; self.write_plan(0); self.validate()

    def test_runtime_record_tamper_missing_and_untrusted_source_rejected(self):
        path=self.session/'python-runtime.json'
        for key, value in [('policy','trust-any-hash'), ('requirement','anchor trusted'),
                           ('pythonSHA256','f'*64), ('frameworkSHA256','f'*64),
                           ('resourcesSHA256','f'*64), ('pythonCDHash','f'*40), ('frameworkCDHash','f'*40),
                           ('pythonVersion','3.9.999'), ('schema','1')]:
            with self.subTest(key=key):
                record=json.loads(RUNTIME_RAW);record[key]=value
                raw=canonical(record);private_file(path,raw)
                self.bindings['runtimeRecordSHA256']=digest(raw);self.write_bindings();self.validate()
        path.unlink();self.validate()
        private_file(path,RUNTIME_RAW);path.chmod(0o644)
        self.bindings['runtimeRecordSHA256']=digest(RUNTIME_RAW);self.write_bindings();self.validate()

    def test_public_legacy_default_and_explicit_keep_old_contract(self):
        self.public();self.validate(True)
        self.env[KIND]='public-https';self.validate(True)
        for key,value in [(URL,''),(URL,'http://owner.example/c'),(URL,'https://u:p@owner.example/c'),
                          (URL,'https://owner.example/c?token=x'),(URL,'https://owner.example/c#fragment'),
                          (URL,'https://owner.example/space here'),(SHA,'B'*64),(SHA,'b'*63)]:
            with self.subTest(key=key,value=value):
                before=self.env[key];self.env[key]=value;self.validate();self.env[key]=before

    def test_public_rejects_each_controlled_field_even_empty(self):
        self.public()
        for key in [BINDINGS,BINDINGS_SHA,RUN,CANDIDATE]:
            self.env[key]='';self.validate();del self.env[key]

    def test_controlled_requires_explicit_kind_and_no_public_fields(self):
        for value in [None,'','unknown']:
            if value is None:self.env.pop(KIND,None)
            else:self.env[KIND]=value
            self.validate()
        self.env[KIND]='controlled-relay-v1'
        for key in [URL,SHA]:self.env[key]='';self.validate();del self.env[key]

    def test_missing_binding_values_and_candidate_engine_mismatch_rejected(self):
        for key in [BINDINGS,BINDINGS_SHA,RUN,CANDIDATE]:
            value=self.env.pop(key);self.validate();self.env[key]=value
        self.env[CANDIDATE]='f'*64;self.validate();self.env[CANDIDATE]=self.candidate_sha
        self.bindings['engine']='transparent';self.write_bindings();self.validate()

    def test_missing_unknown_or_duplicate_json_fields_rejected(self):
        original=copy.deepcopy(self.bindings)
        for key in original:
            self.bindings=copy.deepcopy(original);self.bindings.pop(key);self.write_bindings();self.validate()
        self.bindings=copy.deepcopy(original);self.bindings['skip']=True;self.write_bindings();self.validate()
        raw=canonical(original).replace(b'"schema":1',b'"schema":1,"schema":1')
        self.write_bindings(raw);self.validate()

    def test_cycle_order_reuse_peer_and_numeric_types_rejected(self):
        original=copy.deepcopy(self.bindings)
        for field in ['cycle','stagePath','planSHA256','requestIdentitySHA256','expectedResponseSHA256']:
            self.bindings=copy.deepcopy(original);self.bindings['bindings'][1][field]=original['bindings'][0][field]
            self.write_bindings();self.validate()
        self.bindings=copy.deepcopy(original);self.bindings['bindings'][1]['peerIdentitySHA256']='e'*64
        self.write_bindings();self.validate()
        for key in ['schema','cycles']:
            for value in [True,1.0,3.0,'3',None]:
                self.bindings=copy.deepcopy(original);self.bindings[key]=value;self.write_bindings();self.validate()
        self.bindings=original;self.write_bindings();self.env[CYCLES]='2';self.validate()

    def test_illegal_paths_symlinks_permissions_and_oversize_rejected(self):
        self.env[BINDINGS]='/tmp/arbitrary.json';self.validate();self.env[BINDINGS]=str(self.binding_file)
        self.binding_file.chmod(0o644);self.validate();self.binding_file.chmod(0o600)
        self.session.chmod(0o755);self.validate();self.session.chmod(0o700)
        saved=self.binding_file.read_bytes();self.binding_file.unlink();self.binding_file.symlink_to(self.candidate)
        self.validate();self.write_bindings(saved)
        hardlink=self.root/'binding-hardlink';os.link(self.binding_file,hardlink);self.validate();hardlink.unlink()
        self.bindings['bindings'][0]['stagePath']=str(self.stages[0])+'/../escaped';self.write_bindings();self.validate()
        self.write_bindings(b' '*32769);self.validate()

    def test_helper_tamper_and_private_certificate_tamper_rejected(self):
        self.helper.write_bytes(HELPER.read_bytes()+b'\n');self.validate()
        self.helper.write_bytes(HELPER.read_bytes())
        (self.stages[0]/'server-cert.pem').write_bytes(b'wrong');self.validate()

    def test_plan_tuple_port_run_nonce_and_shape_are_checked(self):
        original=copy.deepcopy(self.plans[0])
        for key,value in [('runID','e'*32),('engine','transparent'),('cycle',True),('port',62116.0),
                          ('port',22),('hostname','other.test'),('controlAddress','8.8.8.8'),
                          ('controlAddress','192.168.000.1'),('dataAddress','192.168.64.1'),
                          ('requestID','f'*32),('token','bad'),('token','x'*32+'\n')]:
            self.plans[0]=copy.deepcopy(original);self.plans[0][key]=value;self.write_plan(0);self.validate()
        self.plans[0]=copy.deepcopy(original);self.plans[0]['extra']='x';self.write_plan(0);self.validate()

    def test_actual_controlled_plist_has_exact_runner_dispatch_and_preserves_target(self):
        target=self.roundtrip()
        obj=plistlib.loads(target.read_bytes())['AetherRouteUITests']
        for name in ['EnvironmentVariables','TestingEnvironmentVariables']:
            self.assertEqual(obj[name][KIND],'controlled-relay-v1');self.assertEqual(obj[name][RUN],self.run_id)
            self.assertEqual(obj[name][BINDINGS],str(self.binding_file));self.assertEqual(obj[name][CANDIDATE],self.candidate_sha)
            self.assertNotIn(URL,obj[name]);self.assertNotIn(SHA,obj[name]);self.assertIn('KEEP',obj[name])
        self.assertEqual(obj['UITargetAppEnvironmentVariables'],{'KEEP':'target'})
        self.assertEqual(obj['UITargetAppPath'],'__TESTROOT__/Debug/AetherRoute.app')

    def test_actual_public_plist_uses_explicit_public_and_no_controlled_fields(self):
        self.public();target=self.roundtrip();obj=plistlib.loads(target.read_bytes())['AetherRouteUITests']
        for name in ['EnvironmentVariables','TestingEnvironmentVariables']:
            self.assertEqual(obj[name][KIND],'public-https');self.assertEqual(obj[name][URL],'https://owner.example/canary')
            for key in [RUN,BINDINGS,BINDINGS_SHA,CANDIDATE]:self.assertNotIn(key,obj[name])

    def test_readback_rejects_changed_dictionary_mixed_controls_and_target_leak(self):
        target=self.roundtrip();original=plistlib.loads(target.read_bytes())
        for dictionary,key,value in [('TestingEnvironmentVariables',RUN,'0'*32),('EnvironmentVariables',URL,''),
                                      ('EnvironmentVariables','AETHERROUTE_SIGNED_PROBE_EXTRA','x'),
                                      ('UITargetAppEnvironmentVariables',RUN,self.run_id),
                                      ('TestingEnvironmentVariables',CYCLES,'4')]:
            obj=copy.deepcopy(original);obj['AetherRouteUITests'][dictionary][key]=value
            with target.open('wb') as stream:plistlib.dump(obj,stream)
            p=self.invoke('verify',str(target),env=self.env);self.assertNotEqual(p.returncode,0)

    def test_actual_package_prepare_controlled_and_public(self):
        for kind in ['controlled-relay-v1','public-https']:
            if kind=='public-https':self.public()
            dest=self.root/('aetherroute-prebuilt-runner.'+uuid.uuid4().hex)
            p=self.invoke('prepare_runner',str(self.archive),digest(self.archive.read_bytes()),str(self.signing),
                str(self.candidate),str(self.source_manifest),'a'*40,str(dest),'tun','--',env=self.env)
            self.assertEqual(p.returncode,0,p.stderr.decode())
            effective=dest/'AetherRouteSignedNERunner/Products/AetherRoute-tun-effective.xctestrun'
            obj=plistlib.loads(effective.read_bytes())['AetherRouteUITests']
            self.assertEqual(obj['UITargetAppPath'],str(self.app))
            self.assertEqual(obj['DependentProductPaths'],['__TESTROOT__/Debug/Other.framework',str(self.app)])
            (ARTIFACTS/('effective-fixture-'+kind+'.xctestrun')).write_bytes(effective.read_bytes())
            self.assertEqual(obj['EnvironmentVariables'][KIND],kind)
            if kind=='controlled-relay-v1':
                native_env=self.base_environment();native_env.update(obj['EnvironmentVariables'])
                consumer=subprocess.run([str(CONSUMER)],env=native_env,capture_output=True,timeout=15)
                self.assertEqual(consumer.returncode,0,consumer.stderr.decode())
                self.assertEqual(consumer.stdout,b'controlled_swift_bindings=3\n')
                runtime_file=self.session/'python-runtime.json'
                changed=json.loads(RUNTIME_RAW);changed['resourcesSHA256']='f'*64
                private_file(runtime_file,canonical(changed))
                rejected=subprocess.run([str(CONSUMER)],env=native_env,capture_output=True,timeout=15)
                self.assertNotEqual(rejected.returncode,0)
                private_file(runtime_file,RUNTIME_RAW)

            manifest=effective.parent.parent/'manifest.json'
            p=self.invoke('validate_effective_probe_environment',str(effective),'tun',str(manifest),env=self.base_environment())
            self.assertEqual(p.returncode,0,p.stderr.decode())
            if kind=='controlled-relay-v1':
                self.helper.write_bytes(HELPER.read_bytes()+b'changed')
                p=self.invoke('validate_effective_probe_environment',str(effective),'tun',str(manifest),env=self.base_environment())
                self.assertNotEqual(p.returncode,0)
                self.helper.write_bytes(HELPER.read_bytes())
            # Only fixture directories; restore package-created read-only modes.
            for path in dest.rglob('*'):
                if not path.is_symlink():path.chmod(0o700 if path.is_dir() else 0o600)
            shutil.rmtree(dest)


if __name__=='__main__':unittest.main(verbosity=2)
