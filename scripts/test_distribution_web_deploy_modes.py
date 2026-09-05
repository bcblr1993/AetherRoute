#!/usr/bin/env python3
"""Run real deployment/preparation locally; replace only remote I/O boundaries.

All release/DMG values are synthetic fixtures. No server, DNS, TLS endpoint,
container, signing identity, or real publication is used by this regression.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class DeployModeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="aetherroute-web-mode-regression-")
        cls.work = Path(cls.temporary.name).resolve()
        cls.repo = cls.work / "repository"
        cls.repo.mkdir()
        for name in [".github", "AetherRoute.xcodeproj", "Artifacts/Validation", "Config", "Core/Headers",
                     "Docs", "Licenses", "Sources", "Tests", "scripts"]:
            (cls.repo / name).mkdir(parents=True, exist_ok=True)
        shutil.copytree(ROOT / "Services/WebDistribution", cls.repo / "Services/WebDistribution")
        for name in ["deploy_distribution_web.sh", "prepare_distribution_web_payload.sh", "source_manifest.sh",
                     "distribution_envelope_tool.swift", "generate_update_envelope.sh"]:
            shutil.copy2(ROOT / "scripts" / name, cls.repo / "scripts" / name)
        # Static/payload checks are run by the caller. Do not recursively start
        # this regression through deploy -> test_distribution_web -> this test.
        cls.script("scripts/test_distribution_web.sh", "#!/bin/sh\nexit 0\n")
        cls.script("scripts/verify_distribution_web.sh", """#!/bin/sh
set -eu
printf 'verify:%s:%s\n' "$3" "$4" >>"$WEB_TEST_OPERATIONS"
test "$4" = "$WEB_TEST_EXPECTED_HTTP"
test "${WEB_TEST_VERIFY_FAILURE:-0}" = 0
""")
        real = cls.repo / "scripts/prepare_distribution_web_payload.sh"
        real.rename(cls.repo / "scripts/real_prepare_distribution_web_payload.sh")
        cls.script("scripts/prepare_distribution_web_payload.sh", """#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$ROOT/scripts/real_prepare_distribution_web_payload.sh" "$@"
for output do :; done
case "${WEB_TEST_TAMPER:-}" in
  wrong-status) jq '.updateHTTPStatus = 200' "$output/metadata.json" >"$output/mutated"; mv "$output/mutated" "$output/metadata.json" ;;
  wrong-mode) jq '.distributionMode = "licensed" | .updateEndpointPresent = true | .updateHTTPStatus = 200' "$output/metadata.json" >"$output/mutated"; mv "$output/mutated" "$output/metadata.json" ;;
  residual-update) printf 'unexpected update' >"$output/payload/updates/current.update.json" ;;
esac
""")
        cls.bin = cls.work / "bin"
        cls.bin.mkdir()
        for name in ["ssh", "scp"]:
            path = cls.bin / name
            # Remote command text is recorded as a hash/category; never execute it.
            path.write_text("#!/bin/sh\nset -eu\n" +
                            "printf '%s\\n' '" + name + "' >>\"$WEB_TEST_OPERATIONS\"\n" +
                            ("case \"$*\" in *'mv -Tf'*) printf 'activate\\n' >>\"$WEB_TEST_OPERATIONS\" ;; *'docker service rollback'*) printf 'remote-rollback-capable\\n' >>\"$WEB_TEST_OPERATIONS\" ;; esac\n" if name == "ssh" else ""))
            path.chmod(0o755)
        cls.base_env = dict(os.environ)
        cls.base_env.pop("AETHERROUTE_DISTRIBUTION_PUBLIC_KEY", None)
        cls.base_env["PATH"] = str(cls.bin) + os.pathsep + os.environ["PATH"]
        for command in [["git", "init", "-q", "-b", "main", str(cls.repo)],
                        ["git", "-C", str(cls.repo), "add", "."],
                        ["git", "-C", str(cls.repo), "-c", "user.name=Local regression fixture",
                         "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                         "commit", "-qm", "Synthetic offline deployment fixture"]]:
            subprocess.run(command, check=True, capture_output=True, timeout=15, env=cls.base_env)
        cls.commit = subprocess.check_output(["git", "-C", str(cls.repo), "rev-parse", "HEAD"], text=True).strip()
        manifest = subprocess.check_output([str(cls.repo / "scripts/source_manifest.sh")], text=True, env=cls.base_env)
        cls.manifest = manifest.splitlines()[-1].split()[-1]
        cls.key = cls.work / "private-key.raw"
        cls.key.write_bytes(b"01234567890123456789012345678901")
        cls.key.chmod(0o600)
        cls.public = cls.work / "public-key.raw"
        subprocess.run(["xcrun", "swift", str(cls.repo / "scripts/distribution_envelope_tool.swift"),
                        "public-key", str(cls.key), str(cls.public)], check=True, capture_output=True, timeout=30)
        import base64
        cls.public64 = base64.b64encode(cls.public.read_bytes()).decode()

    @classmethod
    def script(cls, name, text):
        path = cls.repo / name
        path.write_text(text)
        path.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def invoke(self, mode, *, supply_envelope=None, supply_key=None, tamper="", verify_failure=False):
        folder = self.work / self.id().split(".")[-1]
        folder.mkdir()
        dmg = folder / "AetherRoute-1.0.0-arm64.dmg"
        dmg.write_bytes(b"synthetic payload, not a disk image or release candidate")
        candidate = folder / "AetherRoute-1.0.0-arm64.candidate.json"
        production = folder / "AetherRoute-1.0.0-arm64.production.json"
        envelope = folder / "current.update.json"
        distribution = {"updateSigningPublicKeySHA256": sha(self.public) if mode != "free" else None}
        if mode != "legacy": distribution["mode"] = mode
        value = {"schemaVersion": 1, "releaseStatus": "notarized-candidate", "product": "AetherRoute",
                 "productID": "com.aetherroute.desktop", "version": "1.0.0", "build": 100,
                 "releasedAt": "2026-08-07T08:00:00Z", "minimumSystemVersion": "15.0", "architecture": "arm64",
                 "source": {"gitCommit": self.commit, "manifestSHA256": self.manifest}, "distribution": distribution,
                 "dmg": {"sha256": sha(dmg), "bytes": dmg.stat().st_size}, "notarization": {"status": "Accepted"},
                 "stability": {"schema": 2}, "signedRuntime": {"schema": 1, "engines": ["tun", "transparent"]}}
        candidate.write_text(json.dumps(value) + "\n")
        value["releaseStatus"] = "production-approved"
        value["promotion"] = {"schema": 1, "approvedAt": "2026-08-07T09:00:00Z",
                              "candidateManifestSHA256": sha(candidate), "postInstallEvidenceSHA256": "c" * 64,
                              "exactDMGSHA256": sha(dmg)}
        production.write_text(json.dumps(value) + "\n")
        supplied = mode != "free" if supply_envelope is None else supply_envelope
        key_supplied = mode != "free" if supply_key is None else supply_key
        env = dict(self.base_env)
        operations = folder / "operations"
        env.update(WEB_TEST_OPERATIONS=str(operations), WEB_TEST_EXPECTED_HTTP="404" if mode == "free" else "200",
                   WEB_TEST_TAMPER=tamper, WEB_TEST_VERIFY_FAILURE="1" if verify_failure else "0")
        if key_supplied: env["AETHERROUTE_DISTRIBUTION_PUBLIC_KEY"] = self.public64
        if supplied:
            key_env = dict(env, AETHERROUTE_DISTRIBUTION_PUBLIC_KEY=self.public64)
            subprocess.run([str(self.repo / "scripts/generate_update_envelope.sh"), str(self.key), str(dmg),
                            "com.aetherroute.desktop", "1.0.0", "100", "2026-08-07T09:00:00Z", "15.0",
                            "https://downloads.baizhiedu.xin/releases/1.0.0/AetherRoute-1.0.0-arm64.dmg",
                            "https://aetherroute.baizhiedu.xin/releases/1.0.0/", str(envelope)],
                           check=True, capture_output=True, timeout=30, env=key_env)
        arguments = [str(self.repo / "scripts/deploy_distribution_web.sh"), "fixture@host.invalid", "stable",
                     str(dmg), str(candidate), str(production)]
        if supplied: arguments.append(str(envelope))
        result = subprocess.run(arguments, capture_output=True, timeout=45, env=env, text=True)
        return result, operations.read_text().splitlines() if operations.exists() else []

    def test_free_omits_update_input_and_verifies_404_before_activation(self):
        result, operations = self.invoke("free")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("verify:releases/1.0.0:404", operations)
        self.assertLess(operations.index("verify:releases/1.0.0:404"), operations.index("activate"))

    def test_explicit_licensed_requires_real_signed_envelope_and_verifies_200(self):
        result, operations = self.invoke("licensed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("verify:releases/1.0.0:200", operations)
        self.assertLess(operations.index("verify:releases/1.0.0:200"), operations.index("activate"))

    def test_legacy_licensed_contract_remains_supported(self):
        result, operations = self.invoke("legacy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("verify:releases/1.0.0:200", operations)

    def test_free_rejects_envelope_before_remote_IO(self):
        result, operations = self.invoke("free", supply_envelope=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("free distribution must not supply", result.stderr)
        self.assertEqual(operations, [])

    def test_licensed_rejects_missing_envelope_before_remote_IO(self):
        result, operations = self.invoke("licensed", supply_envelope=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(operations, [])

    def test_licensed_rejects_missing_key_before_remote_IO(self):
        result, operations = self.invoke("licensed", supply_key=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires AETHERROUTE_DISTRIBUTION_PUBLIC_KEY", result.stderr)
        self.assertEqual(operations, [])

    def test_free_rejects_metadata_200_before_remote_IO(self):
        result, operations = self.invoke("free", tamper="wrong-status")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(operations, [])

    def test_metadata_cannot_change_approved_distribution_mode(self):
        result, operations = self.invoke("free", tamper="wrong-mode")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(operations, [])

    def test_free_residual_update_file_is_rejected_before_remote_IO(self):
        result, operations = self.invoke("free", tamper="residual-update")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(operations, [])

    def test_failed_public_404_verification_never_activates(self):
        result, operations = self.invoke("free", verify_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verify:releases/1.0.0:404", operations)
        self.assertNotIn("activate", operations)
        self.assertIn("public verification failed", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
