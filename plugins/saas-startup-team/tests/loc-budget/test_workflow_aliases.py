#!/usr/bin/env python3
"""Tests for thin workflow alias generation (issue #383)."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[2]
GENERATOR = PLUGIN_ROOT / "scripts" / "generate_workflow_aliases.py"
MANIFEST = PLUGIN_ROOT / "integrity" / "entrypoints.json"
REPO_ROOT = PLUGIN_ROOT.parents[1]

sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
import generate_workflow_aliases as gen  # noqa: E402


class EntrypointsManifest(unittest.TestCase):
    def test_manifest_lists_all_commands_and_27_aliases(self) -> None:
        payload = json.loads(MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(payload["version"], 1)
        self.assertEqual(payload["plugin"], "saas-startup-team")
        entries = payload["entrypoints"]
        self.assertEqual(len(entries), 28)
        generated = [e for e in entries if e.get("generate_alias") is True]
        self.assertEqual(len(generated), 27)
        names = {e["name"] for e in entries}
        for cmd in (PLUGIN_ROOT / "commands").glob("*.md"):
            self.assertIn(cmd.stem, names, f"command {cmd.name} missing from entrypoints")

    def test_generated_aliases_on_disk_match_manifest(self) -> None:
        proc = subprocess.run(
            [sys.executable, str(GENERATOR), "--plugin-root", str(PLUGIN_ROOT), "--check"],
            cwd=str(REPO_ROOT),
            text=True,
            capture_output=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)

    def test_each_generated_alias_is_thin_and_marked(self) -> None:
        payload = json.loads(MANIFEST.read_text(encoding="utf-8"))
        for entry in payload["entrypoints"]:
            if not entry.get("generate_alias"):
                continue
            skill = PLUGIN_ROOT / "skills" / entry["codex_skill"] / "SKILL.md"
            self.assertTrue(skill.is_file(), entry["codex_skill"])
            text = skill.read_text(encoding="utf-8")
            self.assertIn(gen.GENERATED_MARKER, text)
            self.assertIn(f"../../{entry['command_file']}", text)
            self.assertNotIn("## Run Protocol", text)
            self.assertNotIn("## SaaS Startup Codex Rules", text)
            self.assertNotIn("gpt-5", text)
            self.assertNotIn("AskUserQuestion", text)
            self.assertNotIn("codex-run-role.sh", text)
            # Thin: keep alias body small (frontmatter + marker + 3-4 lines).
            self.assertLessEqual(text.count("\n"), 12, entry["codex_skill"])


class GeneratorDeterminism(unittest.TestCase):
    def test_render_is_stable(self) -> None:
        a = gen.render_alias(
            skill_name="saas-startup-team-demo-workflow",
            aliases=["/saas-startup-team:demo", "/demo"],
            command_file="commands/demo.md",
        )
        b = gen.render_alias(
            skill_name="saas-startup-team-demo-workflow",
            aliases=["/saas-startup-team:demo", "/demo"],
            command_file="commands/demo.md",
        )
        self.assertEqual(a, b)
        self.assertIn(gen.GENERATED_MARKER, a)
        self.assertIn("../../commands/demo.md", a)

    def test_check_detects_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            (root / "commands").mkdir(parents=True)
            (root / "skills").mkdir(parents=True)
            (root / "integrity").mkdir(parents=True)
            (root / "commands" / "demo.md").write_text(
                "---\nname: demo\ndescription: d\n---\n# /demo\n",
                encoding="utf-8",
            )
            manifest = {
                "version": 1,
                "plugin": "saas-startup-team",
                "entrypoints": [
                    {
                        "name": "demo",
                        "command_file": "commands/demo.md",
                        "aliases": ["/saas-startup-team:demo", "/demo"],
                        "codex_skill": "saas-startup-team-demo-workflow",
                        "generate_alias": True,
                    }
                ],
            }
            (root / "integrity" / "entrypoints.json").write_text(
                json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
            )
            # Missing file => check fails
            rc = gen.main(["--plugin-root", str(root), "--check"])
            self.assertEqual(rc, 1)
            # Write then check passes
            self.assertEqual(gen.main(["--plugin-root", str(root)]), 0)
            self.assertEqual(gen.main(["--plugin-root", str(root), "--check"]), 0)
            # Dirty body fails check
            skill = root / "skills" / "saas-startup-team-demo-workflow" / "SKILL.md"
            skill.write_text(skill.read_text(encoding="utf-8") + "\nextra\n", encoding="utf-8")
            self.assertEqual(gen.main(["--plugin-root", str(root), "--check"]), 1)


class TransitionalCommands(unittest.TestCase):
    def test_all_commands_marked_transitional(self) -> None:
        for path in sorted((PLUGIN_ROOT / "commands").glob("*.md")):
            text = path.read_text(encoding="utf-8")
            self.assertIn("transitional: true", text, path.name)


if __name__ == "__main__":
    unittest.main()
