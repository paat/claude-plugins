#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(__file__).with_name("sync-codex-marketplace.py")
PRE_PUSH_HOOK = REPO_ROOT / ".githooks" / "pre-push"

SPEC = importlib.util.spec_from_file_location("sync_codex_marketplace", SCRIPT)
assert SPEC and SPEC.loader
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


def write_json(path: Path, payload: dict[str, Any], *, ensure_ascii: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=ensure_ascii) + "\n", encoding="utf-8")


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def run_sync(
    root: Path,
    *,
    check: bool = False,
    antigravity_plugins: tuple[str, ...] | None = None,
) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        rc = SYNC.sync_marketplace(root, check=check, antigravity_plugins=antigravity_plugins)
    return rc, stdout.getvalue(), stderr.getvalue()


def make_fixture_repo(
    root: Path,
    *,
    plugins: list[dict[str, Any]],
    marketplace_entries: list[dict[str, Any]],
) -> None:
    write_json(
        root / ".claude-plugin" / "marketplace.json",
        {
            "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
            "name": "test-plugins",
            "description": "Test marketplace — fixture",
            "owner": {"name": "Test Owner"},
            "plugins": marketplace_entries,
        },
        ensure_ascii=False,
    )
    for plugin in plugins:
        name = plugin["name"]
        plugin_dir = root / "plugins" / name
        write_json(plugin_dir / ".claude-plugin" / "plugin.json", plugin)


class SyncCodexMarketplaceTests(unittest.TestCase):
    def test_syncs_marketplace_version_and_author_while_preserving_custom_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            custom_description = "Custom marketplace description — Plan → Build"
            make_fixture_repo(
                root,
                plugins=[
                    {
                        "name": "demo-plugin",
                        "version": "1.4.0",
                        "description": "Plugin manifest description",
                        "author": {"name": "Jane Doe", "email": "jane@example.com"},
                        "license": "MIT",
                    }
                ],
                marketplace_entries=[
                    {
                        "name": "demo-plugin",
                        "description": custom_description,
                        "version": "1.3.0",
                        "author": {"name": "Old Author"},
                        "source": "./plugins/demo-plugin",
                        "category": "testing",
                        "homepage": "https://example.com/demo-plugin",
                    }
                ],
            )

            rc, stdout, stderr = run_sync(root, check=False, antigravity_plugins=())
            self.assertEqual(rc, 0, stderr)
            self.assertIn("Synced 1 Codex plugin entries.", stdout)

            marketplace_path = root / ".claude-plugin" / "marketplace.json"
            raw_text = marketplace_path.read_text(encoding="utf-8")
            self.assertIn("— Plan → Build", raw_text)

            marketplace = json.loads(raw_text)
            self.assertEqual(marketplace["owner"], {"name": "Test Owner"})
            entry = marketplace["plugins"][0]
            self.assertEqual(entry["version"], "1.4.0")
            self.assertEqual(entry["author"], {"name": "Jane Doe", "email": "jane@example.com"})
            self.assertEqual(entry["description"], custom_description)
            self.assertEqual(entry["category"], "testing")
            self.assertEqual(entry["homepage"], "https://example.com/demo-plugin")
            self.assertEqual(entry["source"], "./plugins/demo-plugin")
            self.assertEqual(
                list(entry.keys()),
                ["name", "description", "version", "author", "source", "category", "homepage"],
            )

    def test_preserves_marketplace_author_when_plugin_manifest_omits_author(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_fixture_repo(
                root,
                plugins=[
                    {
                        "name": "demo-plugin",
                        "version": "2.0.0",
                        "description": "Plugin description",
                        "license": "MIT",
                    }
                ],
                marketplace_entries=[
                    {
                        "name": "demo-plugin",
                        "description": "Marketplace description",
                        "version": "1.0.0",
                        "author": {"name": "Existing Marketplace Author"},
                        "source": "./plugins/demo-plugin",
                        "category": "development",
                    }
                ],
            )

            rc, _, stderr = run_sync(root, check=False, antigravity_plugins=())
            self.assertEqual(rc, 0, stderr)

            entry = read_json(root / ".claude-plugin" / "marketplace.json")["plugins"][0]
            self.assertEqual(entry["version"], "2.0.0")
            self.assertEqual(entry["author"], {"name": "Existing Marketplace Author"})

    def test_check_fails_on_claude_marketplace_version_drift_and_passes_after_sync(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_fixture_repo(
                root,
                plugins=[
                    {
                        "name": "demo-plugin",
                        "version": "0.2.0",
                        "description": "Plugin description",
                        "author": {"name": "Andre Paat"},
                        "license": "MIT",
                    }
                ],
                marketplace_entries=[
                    {
                        "name": "demo-plugin",
                        "description": "Custom description",
                        "version": "0.2.0",
                        "author": {"name": "Andre Paat"},
                        "source": "./plugins/demo-plugin",
                        "category": "development",
                        "homepage": "https://example.com/demo",
                    }
                ],
            )

            rc, _, stderr = run_sync(root, check=False, antigravity_plugins=())
            self.assertEqual(rc, 0, stderr)

            # Introduce drift exclusively in .claude-plugin/marketplace.json.
            marketplace_path = root / ".claude-plugin" / "marketplace.json"
            drifted = read_json(marketplace_path)
            drifted["plugins"][0]["version"] = "0.1.9"
            write_json(marketplace_path, drifted)

            rc, stdout, _ = run_sync(root, check=True, antigravity_plugins=())
            self.assertEqual(rc, 1)
            self.assertIn("out of date: .claude-plugin/marketplace.json", stdout)
            # --check must not modify files.
            self.assertEqual(read_json(marketplace_path)["plugins"][0]["version"], "0.1.9")

            rc, _, stderr = run_sync(root, check=False, antigravity_plugins=())
            self.assertEqual(rc, 0, stderr)
            self.assertEqual(read_json(marketplace_path)["plugins"][0]["version"], "0.2.0")

            rc, stdout, stderr = run_sync(root, check=True, antigravity_plugins=())
            self.assertEqual(rc, 0, stderr)
            self.assertIn("Checked 1 Codex plugin entries.", stdout)

    def test_syncs_codex_antigravity_and_agent_manifests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_fixture_repo(
                root,
                plugins=[
                    {
                        "name": "tribunal-review",
                        "version": "1.2.3",
                        "description": "Review plugin",
                        "author": {"name": "Andre Paat"},
                        "repository": "https://github.com/example/plugins",
                        "license": "MIT",
                    },
                    {
                        "name": "demo-plugin",
                        "version": "0.5.0",
                        "description": "Demo plugin",
                        "author": {"name": "Andre Paat"},
                        "license": "MIT",
                    },
                ],
                marketplace_entries=[
                    {
                        "name": "tribunal-review",
                        "description": "Review marketplace entry",
                        "version": "1.2.0",
                        "author": {"name": "Andre Paat"},
                        "source": "./plugins/tribunal-review",
                        "category": "development",
                        "homepage": "https://github.com/example/plugins",
                    },
                    {
                        "name": "demo-plugin",
                        "description": "Demo marketplace entry",
                        "version": "0.4.9",
                        "author": {"name": "Andre Paat"},
                        "source": "./plugins/demo-plugin",
                        "category": "code-quality",
                        "homepage": "https://github.com/example/plugins",
                    },
                ],
            )

            # Give tribunal-review a hook and skill, and demo-plugin a skill.
            hooks_path = root / "plugins" / "tribunal-review" / "hooks" / "hooks.json"
            write_json(hooks_path, {"hooks": {}})
            skill_path = root / "plugins" / "demo-plugin" / "skills" / "demo" / "SKILL.md"
            skill_path.parent.mkdir(parents=True, exist_ok=True)
            skill_path.write_text("---\nname: demo\ndescription: Demo\n---\n", encoding="utf-8")

            rc, _, stderr = run_sync(root, check=False)
            self.assertEqual(rc, 0, stderr)

            # .claude-plugin/marketplace.json synced versions for both plugins.
            claude_mp = read_json(root / ".claude-plugin" / "marketplace.json")
            self.assertEqual(
                {entry["name"]: entry["version"] for entry in claude_mp["plugins"]},
                {"tribunal-review": "1.2.3", "demo-plugin": "0.5.0"},
            )

            # .codex-plugin/plugin.json synced for both plugins.
            codex_tribunal = read_json(
                root / "plugins" / "tribunal-review" / ".codex-plugin" / "plugin.json"
            )
            self.assertEqual(codex_tribunal["version"], "1.2.3")
            self.assertEqual(codex_tribunal["author"], {"name": "Andre Paat"})
            self.assertIn("Lifecycle Hooks", codex_tribunal["interface"]["capabilities"])

            codex_demo = read_json(
                root / "plugins" / "demo-plugin" / ".codex-plugin" / "plugin.json"
            )
            self.assertEqual(codex_demo["version"], "0.5.0")
            self.assertEqual(codex_demo["skills"], "./skills/")
            self.assertEqual(codex_demo["interface"]["category"], "Code Quality")

            # .antigravity-plugin/plugin.json generated only for ANTIGRAVITY_PLUGINS.
            agy_tribunal_path = (
                root / "plugins" / "tribunal-review" / ".antigravity-plugin" / "plugin.json"
            )
            agy_demo_path = (
                root / "plugins" / "demo-plugin" / ".antigravity-plugin" / "plugin.json"
            )
            self.assertTrue(agy_tribunal_path.is_file())
            self.assertFalse(agy_demo_path.exists())
            agy_tribunal = read_json(agy_tribunal_path)
            self.assertEqual(agy_tribunal["version"], "1.2.3")
            self.assertEqual(agy_tribunal["repository"], "https://github.com/example/plugins")
            self.assertEqual(agy_tribunal["homepage"], "https://github.com/example/plugins")

            # .agents/plugins/marketplace.json synced.
            codex_mp = read_json(root / ".agents" / "plugins" / "marketplace.json")
            self.assertEqual(codex_mp["name"], "test-plugins")
            self.assertEqual(
                [(p["name"], p["category"]) for p in codex_mp["plugins"]],
                [("tribunal-review", "Development"), ("demo-plugin", "Code Quality")],
            )

            # .agents/plugins.json synced.
            agy_cfg = read_json(root / ".agents" / "plugins.json")
            self.assertEqual(
                agy_cfg,
                {
                    "entries": [
                        {
                            "path": "plugins",
                            "include_only": list(SYNC.ANTIGRAVITY_PLUGINS),
                        }
                    ]
                },
            )

            # --check fails whenever any generated manifest drifts.
            for rel_target in (
                "plugins/tribunal-review/.codex-plugin/plugin.json",
                "plugins/tribunal-review/.antigravity-plugin/plugin.json",
                ".agents/plugins/marketplace.json",
                ".agents/plugins.json",
            ):
                target = root / rel_target
                original = target.read_text(encoding="utf-8")
                target.write_text("{}\n", encoding="utf-8")
                rc, stdout, _ = run_sync(root, check=True)
                self.assertEqual(rc, 1, f"expected --check to fail on {rel_target}")
                self.assertIn(f"out of date: {rel_target}", stdout)
                target.write_text(original, encoding="utf-8")

            rc, _, stderr = run_sync(root, check=True)
            self.assertEqual(rc, 0, stderr)


class PrePushHookTests(unittest.TestCase):
    def _git(self, cwd: Path, *args: str) -> str:
        proc = subprocess.run(
            ["git", *args],
            cwd=cwd,
            check=True,
            capture_output=True,
            text=True,
        )
        return proc.stdout.strip()

    def _run_hook(self, repo: Path, remote_oid: str, local_oid: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(PRE_PUSH_HOOK), "origin", "file://local"],
            cwd=repo,
            input=f"refs/heads/feat {local_oid} refs/heads/feat {remote_oid}\n",
            capture_output=True,
            text=True,
        )

    def _init_repo(self, root: Path) -> str:
        self._git(root, "init", "-b", "main")
        self._git(root, "config", "user.name", "Test")
        self._git(root, "config", "user.email", "test@example.com")
        make_fixture_repo(
            root,
            plugins=[
                {
                    "name": "tribunal-review",
                    "version": "1.0.0",
                    "description": "Review plugin",
                    "author": {"name": "Andre Paat"},
                    "license": "MIT",
                }
            ],
            marketplace_entries=[
                {
                    "name": "tribunal-review",
                    "description": "Review plugin",
                    "version": "1.0.0",
                    "author": {"name": "Andre Paat"},
                    "source": "./plugins/tribunal-review",
                    "category": "development",
                }
            ],
        )
        rc, _, stderr = run_sync(root, check=False)
        self.assertEqual(rc, 0, stderr)
        self._git(root, "add", ".")
        self._git(root, "commit", "-m", "initial")
        return self._git(root, "rev-parse", "HEAD")

    def test_ignores_antigravity_and_codex_manifest_only_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base_oid = self._init_repo(root)

            # Touch only .antigravity-plugin/plugin.json
            agy_manifest = root / "plugins" / "tribunal-review" / ".antigravity-plugin" / "plugin.json"
            data = read_json(agy_manifest)
            data["description"] = "Synced description"
            write_json(agy_manifest, data)
            self._git(root, "add", ".")
            self._git(root, "commit", "-m", "sync antigravity manifest only")
            agy_oid = self._git(root, "rev-parse", "HEAD")

            res = self._run_hook(root, base_oid, agy_oid)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

            # Touch only .codex-plugin/plugin.json
            codex_manifest = root / "plugins" / "tribunal-review" / ".codex-plugin" / "plugin.json"
            codex_data = read_json(codex_manifest)
            codex_data["description"] = "Synced codex description"
            write_json(codex_manifest, codex_data)
            self._git(root, "add", ".")
            self._git(root, "commit", "-m", "sync codex manifest only")
            codex_oid = self._git(root, "rev-parse", "HEAD")

            res = self._run_hook(root, agy_oid, codex_oid)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

    def test_rejects_unbumped_plugin_change_and_mismatch_with_sync_guidance(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base_oid = self._init_repo(root)

            readme = root / "plugins" / "tribunal-review" / "README.md"
            readme.write_text("# Updated\n", encoding="utf-8")
            self._git(root, "add", ".")
            self._git(root, "commit", "-m", "edit plugin without bump")
            unbumped_oid = self._git(root, "rev-parse", "HEAD")

            res = self._run_hook(root, base_oid, unbumped_oid)
            self.assertEqual(res.returncode, 1)
            self.assertIn("plugins/tribunal-review/.claude-plugin/plugin.json", res.stdout)
            self.assertIn("python3 scripts/sync-codex-marketplace.py", res.stdout)

            # Bump plugin.json without syncing marketplace.json
            pj_path = root / "plugins" / "tribunal-review" / ".claude-plugin" / "plugin.json"
            pj = read_json(pj_path)
            pj["version"] = "1.0.1"
            write_json(pj_path, pj)
            self._git(root, "add", ".")
            self._git(root, "commit", "-m", "bump plugin.json only")
            mismatched_oid = self._git(root, "rev-parse", "HEAD")

            res = self._run_hook(root, base_oid, mismatched_oid)
            self.assertEqual(res.returncode, 1)
            self.assertIn("Version mismatch", res.stdout)
            self.assertIn("python3 scripts/sync-codex-marketplace.py", res.stdout)

            # Run sync -> pre-push now passes
            rc, _, stderr = run_sync(root, check=False)
            self.assertEqual(rc, 0, stderr)
            self._git(root, "add", ".")
            self._git(root, "commit", "-m", "sync manifests")
            synced_oid = self._git(root, "rev-parse", "HEAD")

            res = self._run_hook(root, base_oid, synced_oid)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

    def test_requires_bump_when_antigravity_manifest_and_plugin_file_both_change(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base_oid = self._init_repo(root)

            agy_manifest = root / "plugins" / "tribunal-review" / ".antigravity-plugin" / "plugin.json"
            data = read_json(agy_manifest)
            data["description"] = "Updated generated description"
            write_json(agy_manifest, data)
            (root / "plugins" / "tribunal-review" / "README.md").write_text(
                "# Real plugin edit\n", encoding="utf-8"
            )
            self._git(root, "add", ".")
            self._git(root, "commit", "-m", "edit antigravity manifest and README without bump")
            head_oid = self._git(root, "rev-parse", "HEAD")

            res = self._run_hook(root, base_oid, head_oid)
            self.assertEqual(res.returncode, 1)
            self.assertIn("plugins/tribunal-review/.claude-plugin/plugin.json", res.stdout)
            self.assertIn("python3 scripts/sync-codex-marketplace.py", res.stdout)

    def test_new_branch_push_diffs_against_origin_main(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base_oid = self._init_repo(root)
            self._git(root, "update-ref", "refs/remotes/origin/main", base_oid)
            self._git(root, "checkout", "-b", "feat/new-branch")

            (root / "plugins" / "tribunal-review" / "README.md").write_text(
                "# New branch change\n", encoding="utf-8"
            )
            self._git(root, "add", ".")
            self._git(root, "commit", "-m", "unbumped change on new branch")
            unbumped_oid = self._git(root, "rev-parse", "HEAD")

            zero_oid = "0" * 40
            res = self._run_hook(root, zero_oid, unbumped_oid)
            self.assertEqual(res.returncode, 1)
            self.assertIn("plugins/tribunal-review/.claude-plugin/plugin.json", res.stdout)

            pj_path = root / "plugins" / "tribunal-review" / ".claude-plugin" / "plugin.json"
            pj = read_json(pj_path)
            pj["version"] = "1.0.1"
            write_json(pj_path, pj)
            rc, _, stderr = run_sync(root, check=False)
            self.assertEqual(rc, 0, stderr)
            self._git(root, "add", ".")
            self._git(root, "commit", "-m", "bump and sync on new branch")
            synced_oid = self._git(root, "rev-parse", "HEAD")

            res = self._run_hook(root, zero_oid, synced_oid)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

    def test_uncommitted_working_tree_sync_does_not_bypass_committed_check(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base_oid = self._init_repo(root)

            pj_path = root / "plugins" / "tribunal-review" / ".claude-plugin" / "plugin.json"
            pj = read_json(pj_path)
            pj["version"] = "1.0.1"
            write_json(pj_path, pj)
            self._git(root, "add", str(pj_path))
            self._git(root, "commit", "-m", "bump plugin.json without committing marketplace sync")
            committed_oid = self._git(root, "rev-parse", "HEAD")

            # Sync only in the working tree (uncommitted).
            rc, _, stderr = run_sync(root, check=False)
            self.assertEqual(rc, 0, stderr)
            self.assertEqual(
                read_json(root / ".claude-plugin" / "marketplace.json")["plugins"][0]["version"],
                "1.0.1",
            )

            res = self._run_hook(root, base_oid, committed_oid)
            self.assertEqual(res.returncode, 1)
            self.assertIn("Version mismatch", res.stdout)
            self.assertIn("plugin.json:      1.0.1", res.stdout)
            self.assertIn("marketplace.json: 1.0.0", res.stdout)

    def test_missing_marketplace_entry_reports_missing_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base_oid = self._init_repo(root)

            # Remove the plugin from marketplace.json while bumping plugin.json.
            pj_path = root / "plugins" / "tribunal-review" / ".claude-plugin" / "plugin.json"
            pj = read_json(pj_path)
            pj["version"] = "1.0.1"
            write_json(pj_path, pj)
            mp_path = root / ".claude-plugin" / "marketplace.json"
            mp = read_json(mp_path)
            mp["plugins"] = []
            write_json(mp_path, mp)
            self._git(root, "add", ".")
            self._git(root, "commit", "-m", "drop marketplace entry")
            head_oid = self._git(root, "rev-parse", "HEAD")

            res = self._run_hook(root, base_oid, head_oid)
            self.assertEqual(res.returncode, 1)
            self.assertIn("plugin.json:      1.0.1", res.stdout)
            self.assertIn("marketplace.json: <missing>", res.stdout)


if __name__ == "__main__":
    unittest.main()
