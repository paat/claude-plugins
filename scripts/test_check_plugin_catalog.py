#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check-plugin-catalog.py")
SPEC = importlib.util.spec_from_file_location("check_plugin_catalog", SCRIPT)
assert SPEC and SPEC.loader
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class CodexManifestVersionTests(unittest.TestCase):
    def check_versions(
        self,
        claude_version: str,
        marketplace_version: str,
        codex_version: str | None,
    ) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin = root / "plugins" / "fixture"
            claude_manifest = plugin / ".claude-plugin" / "plugin.json"
            marketplace = root / ".claude-plugin" / "marketplace.json"
            claude_manifest.parent.mkdir(parents=True)
            marketplace.parent.mkdir(parents=True)
            claude_manifest.write_text(json.dumps({"version": claude_version}), encoding="utf-8")
            marketplace.write_text(json.dumps({"plugins": []}), encoding="utf-8")
            if codex_version is not None:
                codex_manifest = plugin / ".codex-plugin" / "plugin.json"
                codex_manifest.parent.mkdir()
                codex_manifest.write_text(json.dumps({"version": codex_version}), encoding="utf-8")

            errors: list[str] = []
            CHECKER.check_manifest_versions(
                "fixture",
                claude_manifest,
                {"version": claude_version},
                marketplace,
                {"version": marketplace_version},
                errors,
            )
            return errors

    def test_rejects_codex_manifest_version_drift(self) -> None:
        errors = self.check_versions("1.2.3", "1.2.3", "1.2.2")
        self.assertEqual(len(errors), 1)
        self.assertIn("fixture: version mismatch", errors[0])
        self.assertIn(".claude-plugin/plugin.json", errors[0])
        self.assertIn(".claude-plugin/marketplace.json", errors[0])
        self.assertIn(".codex-plugin/plugin.json", errors[0])
        self.assertIn("1.2.3", errors[0])
        self.assertIn("1.2.2", errors[0])

    def test_accepts_matching_three_manifest_versions(self) -> None:
        self.assertEqual(self.check_versions("1.2.3", "1.2.3", "1.2.3"), [])

    def test_skips_plugin_without_codex_manifest(self) -> None:
        self.assertEqual(self.check_versions("1.2.3", "1.2.3", None), [])


if __name__ == "__main__":
    unittest.main()
