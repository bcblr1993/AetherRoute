"""No SSH/VM/app operations: exercise release policy with subprocess fixtures."""
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "scripts/verify_parallel_acceptance.py"
APP = "AetherRoute.app/Contents"
BINARIES = [f"{APP}/MacOS/AetherRoute"] + [
    f"{APP}/Library/SystemExtensions/com.aetherroute.desktop.{suffix}.systemextension"
    f"/Contents/MacOS/com.aetherroute.desktop.{suffix}" for suffix in ("tunnel", "transparent-proxy")
]


class AcceptancePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aether-acceptance-policy-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.evidence = self.base / "evidence"
        self.evidence.mkdir()
        self.identity = {"build": "2026101701", "host": "chenxu@100.64.0.3",
                         "candidate_sha256": "a" * 64}
        self.records = {}
        for engine in ("tun", "transparent"):
            checks = {}
            for name, output in {
                "idle": "idle keep-alive reuse: both requests answered after 50s idle\n",
                "upload": "large upload: 2097152 bytes delivered in 1s\n",
                "switch": "\n".join(
                    f"cycle {cycle}: service off -> en{dev} recovered in 2s"
                    for cycle in range(1, 4) for dev in (0, 1)
                ) + "\nPASS: interface switch recovered (3 cycles, deadline 15s)\n",
            }.items():
                path = self.evidence / f"{engine}-{name}.log"
                path.write_text(output)
                checks[name] = {"exit_status": 0, "log": path.name,
                                "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            self.records[engine] = {**self.identity, "schema": 1, "engine": engine,
                                    "checks": checks}
        self.save()

    def save(self):
        for engine, record in self.records.items():
            (self.evidence / f"{engine}.json").write_text(json.dumps(record))

    def run_policy(self, mode="settings", overrides=None):
        env = {k: v for k, v in os.environ.items() if not k.startswith("AETHERROUTE_")}
        env.update(overrides or {})
        args = ["python3", str(POLICY), mode]
        if mode == "evidence":
            args += [str(self.evidence), self.identity["build"], self.identity["host"],
                     self.identity["candidate_sha256"]]
        return subprocess.run(args, env=env, capture_output=True, text=True)

    def test_full_defaults_pass(self):
        result = self.run_policy()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_short_or_partial_runs_cannot_qualify(self):
        for key, value in [("AETHERROUTE_PERF_SECONDS", "120"),
                           ("AETHERROUTE_RUN_REMOTE_ARM64", "NO"),
                           ("AETHERROUTE_PERF_PROFILES", "large"),
                           ("AETHERROUTE_MATRIX_ENGINES", "tun"),
                           ("AETHERROUTE_MATRIX_ROUTING", "rule"),
                           ("AETHERROUTE_PERF_SECONDS", "invalid")]:
            with self.subTest(key=key):
                result = self.run_policy(overrides={key: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("BLOCKED", result.stderr)

    def test_orchestrator_rejects_short_run_before_any_side_effect(self):
        output = self.base / "must-not-be-created"
        env = dict(os.environ, AETHERROUTE_PERF_SECONDS="120",
                   AETHERROUTE_SIGNING_CONFIG=str(self.base / "missing-signing.json"))
        result = subprocess.run(["sh", str(ROOT / "scripts/run_release_acceptance_parallel.sh"),
                                 "1.8.4", "2026101701", str(output)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BLOCKED", result.stderr)
        self.assertFalse(output.exists())

    def fake_dmg(self, build="2026101701", binaries=BINARIES):
        """A real (tiny) DMG laid out like the notarized candidate."""
        source = self.base / f"dmg-src-{build}-{len(binaries)}"
        info = source / APP / "Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleVersion": build}))
        for name in binaries:
            (source / name).parent.mkdir(parents=True, exist_ok=True)
            (source / name).write_bytes(name.encode())
        path = self.base / f"candidate-{build}-{len(binaries)}.dmg"
        subprocess.run(["hdiutil", "create", "-quiet", "-fs", "HFS+", "-format", "UDZO",
                        "-srcfolder", str(source), str(path)], check=True)
        return path

    def test_candidate_dmg_identity(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        self.addCleanup(sys.path.remove, str(ROOT / "scripts"))
        from verify_parallel_acceptance import read_candidate
        build, hashes = read_candidate(self.fake_dmg())
        self.assertEqual(build, "2026101701")
        self.assertEqual(hashes, {name: hashlib.sha256(name.encode()).hexdigest() for name in BINARIES})
        for path in (self.fake_dmg(binaries=BINARIES[:2]), self.base / "missing.dmg"):
            with self.subTest(path=path.name), self.assertRaises(ValueError):
                read_candidate(path)
        # The QA ZIP never runs on the Mac mini; it cannot stand in.
        (self.base / "qa.zip").write_bytes(b"zip")
        with self.assertRaises(ValueError):
            read_candidate(self.base / "qa.zip")

    def run_package(self, source, evidence=None):
        signing = self.base / "Signing.json"
        signing.write_text("{}")
        output = self.base / "must-not-be-created"
        env = {k: v for k, v in os.environ.items() if not k.startswith("AETHERROUTE_")}
        env["AETHERROUTE_PHYSICAL_RUNTIME_EVIDENCE"] = str(evidence or self.base / "no-evidence")
        result = subprocess.run(["sh", str(ROOT / "scripts/package_release_dmg.sh"), str(source),
                                 str(signing), "profile", "1.8.4", self.identity["build"], str(output)],
                                env=env, capture_output=True, text=True)
        self.assertFalse(output.exists())
        return result

    def test_packaging_requires_evidence_for_this_dmg(self):
        dmg = self.base / "candidate.dmg"
        dmg.write_bytes(b"notarized candidate")
        missing = self.run_package(dmg)
        self.assertEqual(missing.returncode, 1)
        self.assertIn("BLOCKED", missing.stderr)
        # Complete evidence for another candidate SHA-256 must not qualify.
        other = self.run_package(dmg, self.evidence)
        self.assertEqual(other.returncode, 1)
        self.assertIn("another candidate", other.stderr)
        app = self.base / "AetherRoute.app"
        app.mkdir()
        self.assertEqual(self.run_package(app).returncode, 64)
        # Matching evidence passes the gate; the empty signing config then stops
        # the script before any signing or notarization.
        for record in self.records.values():
            record["candidate_sha256"] = hashlib.sha256(dmg.read_bytes()).hexdigest()
        self.save()
        bound = self.run_package(dmg, self.evidence)
        self.assertNotIn("BLOCKED", bound.stderr)
        self.assertIn("developerIDIdentitySHA1", bound.stderr)

    def test_collector_requires_explicit_dedicated_hardware_opt_in(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("AETHERROUTE_")}
        result = subprocess.run(["python3", str(ROOT / "scripts/collect_physical_runtime_evidence.py"),
                                 "candidate.dmg", "chenxu@100.64.0.3", "tun", str(self.evidence)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES", result.stderr)

    def test_complete_candidate_bound_evidence_passes(self):
        result = self.run_policy("evidence")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_engine_rejected(self):
        (self.evidence / "transparent.json").unlink()
        self.assertNotEqual(self.run_policy("evidence").returncode, 0)

    def test_mismatched_identity_or_failed_gate_rejected(self):
        original = copy.deepcopy(self.records)
        for field, value in [("build", "old"), ("host", "other"),
                             ("candidate_sha256", "b" * 64), ("engine", "tun")]:
            with self.subTest(field=field):
                self.records = copy.deepcopy(original)
                self.records["transparent"][field] = value
                self.save()
                self.assertNotEqual(self.run_policy("evidence").returncode, 0)
        self.records = copy.deepcopy(original)
        self.records["tun"]["checks"]["switch"]["exit_status"] = 2
        self.save()
        self.assertNotEqual(self.run_policy("evidence").returncode, 0)

    def rewrite_log(self, engine, name, output):
        path = self.evidence / f"{engine}-{name}.log"
        path.write_text(output)
        self.records[engine]["checks"][name]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.save()

    def test_verdict_words_only_count_at_line_start(self):
        passing = (self.evidence / "tun-switch.log").read_text()
        self.rewrite_log("tun", "switch", "probe note: curl reported no FAIL\n" + passing)
        self.assertEqual(self.run_policy("evidence").returncode, 0)
        for verdict in ("FAIL: cycle 2: en0 off -> en1 did not recover within 15s",
                        "INCONCLUSIVE: needs two active physical uplinks", "SKIP: direct mode"):
            with self.subTest(verdict=verdict):
                self.rewrite_log("tun", "switch", verdict + "\n" + passing)
                self.assertNotEqual(self.run_policy("evidence").returncode, 0)

    def test_log_tampering_rejected(self):
        (self.evidence / "tun-upload.log").write_text("PASS")
        self.assertNotEqual(self.run_policy("evidence").returncode, 0)

    def test_short_probe_and_incomplete_switch_rejected(self):
        original = copy.deepcopy(self.records)
        original_logs = {path.name: path.read_text() for path in self.evidence.glob("*.log")}
        for name, output in [("idle", "both requests answered after 30s idle"),
                             ("upload", "large upload: 1048576 bytes delivered in 1s"),
                             ("switch", "PASS: interface switch recovered (3 cycles, deadline 15s)")]:
            with self.subTest(name=name):
                self.records = copy.deepcopy(original)
                for filename, content in original_logs.items():
                    (self.evidence / filename).write_text(content)
                path = self.evidence / f"tun-{name}.log"
                path.write_text(output)
                self.records["tun"]["checks"][name]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
                self.save()
                self.assertNotEqual(self.run_policy("evidence").returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
