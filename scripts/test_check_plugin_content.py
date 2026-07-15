#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check-plugin-content.py")
SPEC = importlib.util.spec_from_file_location("check_plugin_content", SCRIPT)
assert SPEC and SPEC.loader
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class FrontmatterSyntaxTests(unittest.TestCase):
    def parse(self, frontmatter: str) -> tuple[dict[str, str], list[str]]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.md"
            path.write_text(f"---\n{frontmatter}\n---\nBody\n", encoding="utf-8")
            errors: list[str] = []
            metadata, _body = CHECKER.parse_frontmatter(path, errors)
            return metadata, errors

    def test_rejects_metadata_that_claude_drops(self) -> None:
        cases = {
            "plain colon": "description: Research. Usage: /research",
            "inline token": "description: Deliver PR with `Closes #N`, then merge",
            "multiline token": (
                "description: Deliver PR\n"
                "  with `Closes #123`, then merge. Usage: /deliver"
            ),
            "spaced flows": "argument-hint: [topic] [--flag]",
            "adjacent flows": "argument-hint: [topic][--flag]",
            "quoted trailing text": 'description: "Research" Usage: /research',
            "invalid escape": 'description: "Research \\q topic"',
            "invalid block header": "description: > garbage",
            "invalid flow": "allowed-tools: [Read,, Write]",
            "invalid nested scalar": "metadata:\n  category: bad: value",
            "nonmapping list": "[]",
            "nonmapping scalar": "false",
        }
        for name, frontmatter in cases.items():
            with self.subTest(name=name):
                _metadata, errors = self.parse(frontmatter)
                self.assertTrue(errors)

    def test_accepts_valid_yaml_forms(self) -> None:
        cases = {
            "quoted hazards": (
                'description: "Research. Usage: /research and Closes #N"\n'
                'argument-hint: "[topic] [--flag]"'
            ),
            "folded scalar": "description: >\n  Research community evidence.",
            "multiline plain": "description: Research community\n  evidence and comparisons.",
            "multiline quoted": 'description: "Research community\n  evidence and comparisons."',
            "multiline flow": "allowed-tools: [Read,\n  Write]",
            "nested metadata": "description: Research\nmetadata:\n  category: research",
            "flow mapping": "description: Research\nmetadata: {category: research}",
            "inline comments": (
                "name: \"fixture\" # canonical\n"
                "description: Research #rationale\n"
                "allowed-tools: [Read, Write] # least privilege"
            ),
        }
        for name, frontmatter in cases.items():
            with self.subTest(name=name):
                _metadata, errors = self.parse(frontmatter)
                self.assertEqual(errors, [])

    def test_parses_quoted_value_before_comment(self) -> None:
        metadata, errors = self.parse('name: "reddit-research" # canonical')
        self.assertEqual(errors, [])
        self.assertEqual(metadata["name"], "reddit-research")

    def test_preserves_yaml_implicit_scalar_text(self) -> None:
        metadata, errors = self.parse("name: yes\ndescription: 2026-07-14")
        self.assertEqual(errors, [])
        self.assertEqual(metadata, {"name": "yes", "description": "2026-07-14"})


class CommandSkillTests(unittest.TestCase):
    def test_accepts_codex_skill_name_override(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            plugin = Path(directory) / "fixture"
            command = plugin / "commands" / "maintain-loop.md"
            skill = plugin / "skills" / "maintain-loop" / "SKILL.md"
            command.parent.mkdir(parents=True)
            skill.parent.mkdir(parents=True)
            command.write_text(
                "---\nname: maintain-loop\ncodex-skill-name: maintain-loop\n---\n",
                encoding="utf-8",
            )
            skill.write_text("---\nname: maintain-loop\ndescription: Test\n---\n", encoding="utf-8")
            errors: list[str] = []

            CHECKER.lint_commands(plugin, errors)

            self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
