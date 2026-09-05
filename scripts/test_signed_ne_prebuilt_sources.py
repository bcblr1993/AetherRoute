#!/usr/bin/env python3
"""Exercise the prebuilt runner's actual frozen UI source validation offline."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / "scripts/signed_ne_prebuilt_runner.sh").read_text()
FUNCTIONS = SOURCE[SOURCE.index("sha256() {"):SOURCE.index("\nwrite_product_manifests() {")]


class FrozenUISourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aether-ui-source-binding.")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sources = self.root / "Tests/AetherRouteUITests"
        self.sources.mkdir(parents=True)
        self.main = self.sources / "AetherRouteUITests.swift"
        self.helper = self.sources / "SignedNEProbe.swift"
        self.main.write_text("main fixture\n")
        self.helper.write_text("helper fixture\n")
        self.manifest = self.root / "manifest.txt"
        self.freeze()

    def freeze(self):
        rows = "".join(hashlib.sha256(path.read_bytes()).hexdigest() + "  " +
                       str(path.relative_to(self.root)) + "\n" for path in sorted(self.sources.iterdir()))
        self.marker = hashlib.sha256(rows.encode()).hexdigest()
        self.manifest.write_text(rows + "MANIFEST_SHA256  " + self.marker + "\n")

    def validate(self):
        harness = ('#!/bin/sh\nset -eu\nfail() { echo "$*" >&2; exit 1; }\n'
                   'ROOT="$1"\nCANDIDATE_SOURCE_SHA256="$2"\n' + FUNCTIONS +
                   '\nvalidate_candidate_source_manifest "$3"\n')
        return subprocess.run(["/bin/sh", "-s", "--", str(self.root), self.marker, str(self.manifest)],
                              input=harness.encode(), capture_output=True, timeout=15)

    def test_exact_multi_file_source_passes(self):
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_changed_helper_requires_a_new_frozen_candidate(self):
        self.helper.write_text("changed helper\n")
        result = self.validate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"current UI source set differs", result.stderr)

    def test_added_or_removed_helper_is_not_hidden_by_unchanged_entry_point(self):
        extra = self.sources / "Extra.swift"
        extra.write_text("extra helper\n")
        self.assertNotEqual(self.validate().returncode, 0)
        extra.unlink()
        self.helper.unlink()
        self.assertNotEqual(self.validate().returncode, 0)

    def test_symbolic_links_cannot_introduce_unbound_compiled_sources(self):
        # Even an additional symlink that find -type f omits must be rejected.
        link = self.sources / "Linked.swift"
        link.symlink_to(self.main)
        result = self.validate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"UI source set cannot be read safely", result.stderr)

    def test_duplicate_source_row_or_corrupt_manifest_is_rejected(self):
        rows = self.manifest.read_text().splitlines(keepends=True)[:-1]
        duplicate = "".join(rows + [rows[1]])
        self.marker = hashlib.sha256(duplicate.encode()).hexdigest()
        self.manifest.write_text(duplicate + "MANIFEST_SHA256  " + self.marker + "\n")
        self.assertNotEqual(self.validate().returncode, 0)
        self.freeze()
        self.manifest.write_text(self.manifest.read_text() + "extra\n")
        self.assertNotEqual(self.validate().returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
