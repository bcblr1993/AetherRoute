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
        self.identity = {"build": "2026101701", "host": "vm:macos27",
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

    def plan(self, overrides=None):
        output = self.base / "plan-must-not-be-created"
        env = {k: v for k, v in os.environ.items() if not k.startswith("AETHERROUTE_")}
        # A missing signing config stops a run that ignored plan-only mode in
        # preflight, before it can touch the VM, the Mac mini or a build.
        env.update({"AETHERROUTE_ACCEPTANCE_PLAN_ONLY": "1",
                    "AETHERROUTE_SIGNING_CONFIG": str(self.base / "missing-signing.json"),
                    **(overrides or {})})
        result = subprocess.run(["sh", str(ROOT / "scripts/run_release_acceptance_parallel.sh"),
                                 "1.10.0", "2026102901", str(output)],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(output.exists())
        return [line for line in result.stdout.splitlines() if line.startswith("plan ")]

    def test_default_plan_consolidates_all_guest_gates_on_the_vm(self):
        # All disruptive and GUI gates (matrix, remote source gate, UI
        # performance gate, and notarized candidate runtime receipts) run inside
        # the headless Tart VM while the notarized candidate builds alongside.
        self.assertEqual(self.plan(), [
            "plan track1: vm-matrix macos27 -> remote-arm64 vm fast -> ui-perf vm:macos27 300s",
            "plan track2: notarized-candidate stable AetherRoute-Notary",
            "plan then: physical-runtime vm:macos27 tun transparent",
            "plan then: verify-physical-evidence",
        ])

    def test_plan_can_use_an_explicit_external_host_override(self):
        plan = self.plan({"AETHERROUTE_REMOTE_HOST": "chenxu@remote-test.local",
                          "AETHERROUTE_REMOTE_GATE_HOST": "chenxu@remote-test.local",
                          "AETHERROUTE_NOTARY_PROFILE": "Other-Profile"})
        self.assertEqual(plan[:3], [
            "plan track1: vm-matrix macos27",
            "plan track2: remote-arm64 chenxu@remote-test.local fast -> ui-perf chenxu@remote-test.local 300s",
            "plan track3: notarized-candidate stable Other-Profile",
        ])

    def test_plan_only_still_rejects_shortened_runs(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("AETHERROUTE_")}
        env.update(AETHERROUTE_ACCEPTANCE_PLAN_ONLY="1", AETHERROUTE_PERF_SECONDS="60",
                   AETHERROUTE_SIGNING_CONFIG=str(self.base / "missing-signing.json"))
        result = subprocess.run(["sh", str(ROOT / "scripts/run_release_acceptance_parallel.sh"),
                                 "1.10.0", "2026102901", str(self.base / "x")],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BLOCKED", result.stderr)

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
                                 "candidate.dmg", "vm:macos27", "tun", str(self.evidence)],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AETHERROUTE_ALLOW_PHYSICAL_RUNTIME=YES", result.stderr)

    def test_vm_single_uplink_two_phase_switch_passes(self):
        vm_switch = "\n".join(
            f"cycle {cycle}: Ethernet {phase} off -> en0 recovered in 2s"
            for cycle in range(1, 4) for phase in ("primary", "secondary")
        ) + "\nPASS: interface switch recovered (3 cycles, deadline 15s)\n"
        self.rewrite_log("tun", "switch", vm_switch)
        self.assertEqual(self.run_policy("evidence").returncode, 0)
        duplicate_phase = "\n".join(
            f"cycle {cycle}: Ethernet primary off -> en0 recovered in 2s"
            for cycle in range(1, 4) for _ in (0, 1)
        ) + "\nPASS: interface switch recovered (3 cycles, deadline 15s)\n"
        self.rewrite_log("tun", "switch", duplicate_phase)
        self.assertNotEqual(self.run_policy("evidence").returncode, 0)

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

    def test_package_release_dmg_aborts_after_five_codesign_failures_before_notarization(self):
        src_dir = self.base / "pkg-dmg-src"
        app_contents = src_dir / "AetherRoute.app/Contents"
        (app_contents / "MacOS").mkdir(parents=True)
        (app_contents / "Resources").mkdir(parents=True)
        (app_contents / "MacOS/AetherRoute").write_bytes(b"macho")
        icon_bytes = (ROOT / "Config/App/AppIcon.icns").read_bytes()
        (app_contents / "Resources/AppIcon.icns").write_bytes(icon_bytes)
        (app_contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "3.0.2",
            "CFBundleVersion": self.identity["build"],
            "AetherRouteReleaseChannel": "stable",
        }))
        candidate_dmg = self.base / "notarized-candidate.dmg"
        subprocess.run(["hdiutil", "create", "-quiet", "-fs", "HFS+", "-format", "UDZO",
                        "-srcfolder", str(src_dir), str(candidate_dmg)], check=True)
        dmg_sha = hashlib.sha256(candidate_dmg.read_bytes()).hexdigest()
        for record in self.records.values():
            record["candidate_sha256"] = dmg_sha
        self.save()

        signing = self.base / "Signing.json"
        signing.write_text(json.dumps({"developerIDIdentitySHA1": "0123456789ABCDEF0123456789ABCDEF01234567"}))

        mock_bin = self.base / "mock-bin"
        mock_bin.mkdir()
        attempts_log = self.base / "codesign-attempts.log"
        notary_sentinel = self.base / "notarytool-called"

        def write_exe(name, body):
            p = mock_bin / name
            p.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
            p.chmod(0o755)

        write_exe("codesign", f"""
for arg in "$@"; do
  if [ "$arg" = "--verify" ]; then exit 0; fi
done
echo attempt >> "{attempts_log}"
exit 1
""")
        write_exe("xcrun", f"""
if [ "${{1:-}}" = "notarytool" ]; then
  touch "{notary_sentinel}"
  exit 0
fi
exit 0
""")
        write_exe("spctl", "exit 0")
        write_exe("syspolicy_check", "exit 0")
        write_exe("sleep", "exit 0")

        env = {k: v for k, v in os.environ.items() if not k.startswith("AETHERROUTE_")}
        env["AETHERROUTE_PHYSICAL_RUNTIME_EVIDENCE"] = str(self.evidence)
        env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
        out_dir = self.base / "release-out"
        result = subprocess.run(
            ["sh", str(ROOT / "scripts/package_release_dmg.sh"), str(candidate_dmg),
             str(signing), "AetherRoute-Notary", "3.0.2", self.identity["build"], str(out_dir)],
            env=env, capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0, "package_release_dmg.sh must fail when codesign exhausts 5 retries")
        self.assertTrue(attempts_log.exists())
        self.assertEqual(len(attempts_log.read_text().splitlines()), 5)
        self.assertFalse(notary_sentinel.exists(), "notarytool must not run after codesign fails")

    def test_orchestrator_exit_trap_stops_headless_vm_and_kills_process_tree(self):
        mock_bin = self.base / "mock-vm-bin"
        mock_bin.mkdir()
        tart_log = self.base / "tart-calls.log"
        grandchild_pid_file = self.base / "grandchild.pid"
        signing = self.base / "Signing.json"
        signing.write_text("{}")

        tart_script = mock_bin / "tart"
        tart_script.write_text(f"""#!/bin/sh
echo "$@" >> "{tart_log}"
case "${{1:-}}" in
  list)
    echo "local   macos27   40   stopped"
    exit 0
    ;;
  run)
    # Spawn a grandchild sleep to verify recursive process-tree cleanup
    ( /bin/sleep 120 & echo $! > "{grandchild_pid_file}"; wait ) &
    wait
    exit 0
    ;;
  ip)
    exit 0
    ;;
  stop)
    exit 0
    ;;
esac
exit 0
""")
        tart_script.chmod(0o755)
        fast_sleep = mock_bin / "sleep"
        fast_sleep.write_text("""#!/bin/sh
if [ "${1:-}" = "120" ]; then exec /bin/sleep 120; fi
/bin/sleep 0.05
""")
        fast_sleep.chmod(0o755)

        env = {k: v for k, v in os.environ.items() if not k.startswith("AETHERROUTE_")}
        env["AETHERROUTE_SIGNING_CONFIG"] = str(signing)
        env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
        out_dir = self.base / "orch-out"
        result = subprocess.run(
            ["sh", str(ROOT / "scripts/run_release_acceptance_parallel.sh"),
             "3.0.2", self.identity["build"], str(out_dir)],
            env=env, capture_output=True, text=True, timeout=15,
        )
        self.assertNotEqual(result.returncode, 0)
        calls = tart_log.read_text().splitlines() if tart_log.exists() else []
        self.addCleanup(lambda: grandchild_pid_file.exists() and subprocess.run(
            ["kill", "-9", grandchild_pid_file.read_text().strip()], capture_output=True))
        self.assertTrue(any(c.startswith("stop macos27") for c in calls),
                        f"Expected 'tart stop macos27' in exit trap, got: {calls}")
        if grandchild_pid_file.exists():
            gpid = int(grandchild_pid_file.read_text().strip())
            alive = subprocess.run(["kill", "-0", str(gpid)], capture_output=True).returncode == 0
            self.assertFalse(alive, f"Grandchild PID {gpid} survived orchestrator exit trap")


if __name__ == "__main__":
    unittest.main(verbosity=2)
