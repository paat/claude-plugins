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


class TerminalSentinelTests(unittest.TestCase):
    def lint(self, relative_path: str, content: str) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            plugin = Path(directory) / "fixture"
            path = plugin / relative_path
            path.parent.mkdir(parents=True)
            path.write_text(content, encoding="utf-8")
            errors: list[str] = []
            CHECKER.lint_prompt_content(plugin, errors)
            return errors

    def test_rejects_standalone_sentinel_in_producer_content(self) -> None:
        for path in (
            "commands/maintain-loop.md",
            "agents/operator.md",
            "skills/operator/SKILL.md",
            "references/protocol.md",
        ):
            with self.subTest(path=path):
                errors = self.lint(path, "Before\nMC-BLOCKED reason=<reason>\nAfter\n")
                self.assertEqual(len(errors), 1)

    def test_accepts_inline_runtime_emission_instruction(self) -> None:
        errors = self.lint(
            "commands/maintain-loop.md",
            "Return one standalone `MC-BLOCKED reason=<reason>` line.\n",
        )
        self.assertEqual(errors, [])


class DuplicationAndBudgetTests(unittest.TestCase):
    def _write_plugin(self, root: Path, files: dict[str, str]) -> Path:
        plugin = root / "fixture"
        for relative, content in files.items():
            path = plugin / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        return plugin

    def test_flags_re_pasted_multiline_block_across_two_files(self) -> None:
        shared = "\n".join(f"shared guidance line {i} with enough text" for i in range(12))
        with tempfile.TemporaryDirectory() as directory:
            plugin = self._write_plugin(
                Path(directory),
                {
                    "agents/alpha.md": f"---\nname: alpha\ndescription: A\n---\n{shared}\n",
                    "agents/beta.md": f"---\nname: beta\ndescription: B\n---\n{shared}\n",
                },
            )
            errors: list[str] = []
            CHECKER.lint_markdown_duplication(plugin, errors)
            self.assertTrue(errors, "expected duplication error")
            self.assertTrue(any("duplicated" in err for err in errors))

    def test_accepts_unique_bodies(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            plugin = self._write_plugin(
                Path(directory),
                {
                    "agents/alpha.md": "---\nname: alpha\ndescription: A\n---\n"
                    + "\n".join(f"alpha only line {i}" for i in range(12))
                    + "\n",
                    "agents/beta.md": "---\nname: beta\ndescription: B\n---\n"
                    + "\n".join(f"beta only line {i}" for i in range(12))
                    + "\n",
                },
            )
            errors: list[str] = []
            CHECKER.lint_markdown_duplication(plugin, errors)
            self.assertEqual(errors, [])

    def test_budget_fails_when_file_grows_past_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            plugin = self._write_plugin(
                Path(directory),
                {
                    "agents/alpha.md": "---\nname: alpha\ndescription: A\n---\nshort\n",
                    "integrity/prompt-budgets.json": (
                        '{\n  "version": 1,\n  "files": {\n'
                        '    "agents/alpha.md": 20\n  }\n}\n'
                    ),
                },
            )
            # Grow past budget
            (plugin / "agents" / "alpha.md").write_text(
                "---\nname: alpha\ndescription: A\n---\n" + ("x" * 200) + "\n",
                encoding="utf-8",
            )
            errors: list[str] = []
            CHECKER.lint_prompt_budgets(plugin, errors)
            self.assertTrue(errors)
            self.assertTrue(any("exceeds prompt budget" in err for err in errors))

    def test_budget_passes_at_or_under_baseline(self) -> None:
        content = "---\nname: alpha\ndescription: A\n---\nbody\n"
        with tempfile.TemporaryDirectory() as directory:
            plugin = self._write_plugin(
                Path(directory),
                {"agents/alpha.md": content},
            )
            size = (plugin / "agents" / "alpha.md").stat().st_size
            (plugin / "integrity").mkdir(parents=True, exist_ok=True)
            (plugin / "integrity" / "prompt-budgets.json").write_text(
                '{\n  "version": 1,\n  "files": {\n'
                f'    "agents/alpha.md": {size}\n  }}\n}}\n',
                encoding="utf-8",
            )
            errors: list[str] = []
            CHECKER.lint_prompt_budgets(plugin, errors)
            self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
