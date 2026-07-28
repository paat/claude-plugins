#!/usr/bin/env python3
"""Fixture and unit tests for scripts/check_loc_budget.py (issue #382)."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[2]
CHECKER = PLUGIN_ROOT / "scripts" / "check_loc_budget.py"
BUDGET = PLUGIN_ROOT / "integrity" / "loc-budget.json"
REPO_ROOT = PLUGIN_ROOT.parents[1]

# Import checker helpers
sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
import check_loc_budget as loc  # noqa: E402


METRIC_IDS = list(loc.METRIC_IDS)


def run_checker(args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECKER), *args],
        cwd=str(cwd or REPO_ROOT),
        text=True,
        capture_output=True,
    )


def write_budget(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def base_budget(**metric_overrides: dict) -> dict:
    metrics = {}
    for mid in METRIC_IDS:
        metrics[mid] = {
            "baseline": 0,
            "release_target": 0,
            "hard_ceiling": 100000,
            "current_ratchet": 100000,
            "unit": "loc" if mid != "wrapper_skills_hand_maintained" else "count",
        }
    for mid, patch in metric_overrides.items():
        metrics[mid].update(patch)
    return {
        "version": 1,
        "phase": "pre-1.0",
        "release_target_version": "1.0.0",
        "metrics": metrics,
        "exclusions": {
            "total_md_sh_excl_tests_docs": {
                "exclude_top_level_dirs": ["tests", "docs"],
                "exclude_root_files": ["CLAUDE.md", "AGENTS.md"],
                "extensions": [".md", ".sh"],
                "follow_symlinks": False,
            }
        },
        "counting_rules": {
            "scripts_sh_loc": "Sum LOC of all regular files matching scripts/**/*.sh",
            "wrapper_skills_hand_maintained": (
                "Count of directories skills/saas-startup-team-*-workflow "
                "whose SKILL.md lacks the GENERATED-ALIAS marker"
            ),
            "wrapper_skills_hand_maintained_loc": (
                "Sum LOC of SKILL.md in hand-maintained wrapper directories "
                "(no GENERATED-ALIAS marker)"
            ),
            "agents_md_loc": "Sum LOC of all regular files matching agents/**/*.md",
            "runtime_prompt_surface_loc": "Sum LOC of all regular *.md under agents/, commands/, and skills/",
            "total_md_sh_excl_tests_docs": "Sum LOC of all regular *.md and *.sh excluding top-level tests/ and docs/",
        },
        "generated_files": {"policy": "counted", "patterns": ["**/generated/**"]},
        "extracted_packages": {"policy": "declare_or_count", "declared_siblings": []},
    }


def make_plugin(root: Path) -> None:
    """Minimal plugin tree with zero LOC of interest."""
    for d in ("scripts", "agents", "commands", "skills", "tests", "docs", "integrity"):
        (root / d).mkdir(parents=True, exist_ok=True)


def write_lines(path: Path, n: int, prefix: str = "x") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(("\n".join(f"{prefix}{i}" for i in range(n)) + "\n"), encoding="utf-8")


class MeasureRealPlugin(unittest.TestCase):
    def test_measure_current_plugin_matches_budget_shape(self) -> None:
        budget = loc.load_budget(BUDGET)
        measured = loc.measure(PLUGIN_ROOT, budget)
        for mid in METRIC_IDS:
            self.assertIn(mid, measured)
            self.assertIsInstance(measured[mid], int)
            self.assertGreaterEqual(measured[mid], 0)

    def test_cli_passes_on_current_plugin(self) -> None:
        proc = run_checker(["--plugin-root", str(PLUGIN_ROOT)])
        self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
        self.assertIn("LOC budget OK", proc.stdout)

    def test_release_1_0_0_passes_on_current_tree(self) -> None:
        # After #392 budget recalibration + prompt surface move, all release targets pass.
        proc = run_checker(["--plugin-root", str(PLUGIN_ROOT), "--release", "1.0.0"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("LOC budget OK", proc.stdout)

    def test_hand_maintained_wrappers_are_zero_on_current_tree(self) -> None:
        budget = loc.load_budget(BUDGET)
        measured = loc.measure(PLUGIN_ROOT, budget)
        self.assertEqual(measured["wrapper_skills_hand_maintained"], 0)
        self.assertEqual(measured["wrapper_skills_hand_maintained_loc"], 0)


class BaselineReproduction(unittest.TestCase):
    """Measurement reproduces 0.90.11 goldens from the historical commit tree."""

    BASELINE_COMMIT = "7e02df66642fe7621ffa44ed4deca82fd42538c9"
    GOLDEN = {
        "scripts_sh_loc": 20461,
        "wrapper_skills_hand_maintained": 27,
        "wrapper_skills_hand_maintained_loc": 1188,
        "agents_md_loc": 1532,
        "runtime_prompt_surface_loc": 10137,
        # Clean tree; epic table listed 36612 (+untracked CLAUDE.md).
        "total_md_sh_excl_tests_docs": 36599,
    }

    def test_budget_json_contains_epic_baselines(self) -> None:
        budget = json.loads(BUDGET.read_text(encoding="utf-8"))
        expected = {
            "scripts_sh_loc": 20461,
            "wrapper_skills_hand_maintained": 27,
            "wrapper_skills_hand_maintained_loc": 1188,
            "agents_md_loc": 1532,
            "runtime_prompt_surface_loc": 10137,
            "total_md_sh_excl_tests_docs": 36612,
        }
        for mid, base in expected.items():
            self.assertEqual(budget["metrics"][mid]["baseline"], base, mid)
            self.assertIn("release_target", budget["metrics"][mid])
            self.assertIn("hard_ceiling", budget["metrics"][mid])
            self.assertIn("current_ratchet", budget["metrics"][mid])
        self.assertEqual(
            budget["metrics"]["total_md_sh_excl_tests_docs"]["baseline_clean_tree"],
            36599,
        )
        self.assertEqual(budget["exclusions"]["total_md_sh_excl_tests_docs"]["exclude_top_level_dirs"], ["tests", "docs"])

    def test_measure_0_90_11_tree(self) -> None:
        if not (REPO_ROOT / ".git").exists() and not (REPO_ROOT / ".git").is_file():
            self.skipTest("not a git checkout")
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp)
            proc = subprocess.run(
                ["git", "archive", self.BASELINE_COMMIT, "plugins/saas-startup-team"],
                cwd=str(REPO_ROOT),
                stdout=subprocess.PIPE,
                check=False,
            )
            if proc.returncode != 0:
                self.skipTest(f"git archive {self.BASELINE_COMMIT} unavailable")
            subprocess.run(
                ["tar", "-x", "-C", str(dest)],
                input=proc.stdout,
                check=True,
            )
            root = dest / "plugins" / "saas-startup-team"
            budget = loc.load_budget(BUDGET)
            measured = loc.measure(root, budget)
            for mid, golden in self.GOLDEN.items():
                self.assertEqual(
                    measured[mid],
                    golden,
                    f"{mid}: measured {measured[mid]} != golden {golden}",
                )


class FixtureExceedEachMetric(unittest.TestCase):
    """Independently exceed every metric and prove CI failure."""

    def _run_with_metric(self, mid: str, setup) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            make_plugin(root)
            # Tight ratchet so only the inflated metric fails.
            overrides = {
                m: {"current_ratchet": 0, "hard_ceiling": 0, "release_target": 0, "baseline": 0}
                for m in METRIC_IDS
            }
            # Give non-targeted metrics headroom for unavoidable zeros vs empty tree...
            # Empty tree measures 0 for all; setup inflates one metric above 0.
            for m in METRIC_IDS:
                overrides[m]["current_ratchet"] = 0
                overrides[m]["hard_ceiling"] = 10**9
            overrides[mid]["current_ratchet"] = 0
            overrides[mid]["hard_ceiling"] = 10**9
            setup(root)
            budget_path = root / "integrity" / "loc-budget.json"
            write_budget(budget_path, base_budget(**overrides))
            return run_checker(["--plugin-root", str(root), "--budget", str(budget_path)])

    def test_exceed_scripts_sh_loc(self) -> None:
        def setup(root: Path) -> None:
            write_lines(root / "scripts" / "big.sh", 5)

        proc = self._run_with_metric("scripts_sh_loc", setup)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("scripts_sh_loc", proc.stderr)

    def test_exceed_wrapper_count(self) -> None:
        def setup(root: Path) -> None:
            d = root / "skills" / "saas-startup-team-demo-workflow"
            d.mkdir(parents=True)
            # No GENERATED-ALIAS marker => hand-maintained.
            write_lines(d / "SKILL.md", 1)

        proc = self._run_with_metric("wrapper_skills_hand_maintained", setup)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("wrapper_skills_hand_maintained", proc.stderr)

    def test_exceed_wrapper_loc(self) -> None:
        def setup(root: Path) -> None:
            d = root / "skills" / "saas-startup-team-demo-workflow"
            d.mkdir(parents=True)
            write_lines(d / "SKILL.md", 9)

        proc = self._run_with_metric("wrapper_skills_hand_maintained_loc", setup)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("wrapper_skills_hand_maintained_loc", proc.stderr)

    def test_generated_alias_marker_excluded_from_hand_maintained(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            make_plugin(root)
            d = root / "skills" / "saas-startup-team-demo-workflow"
            d.mkdir(parents=True)
            (d / "SKILL.md").write_text(
                "---\nname: saas-startup-team-demo-workflow\n"
                'description: "demo"\n---\n'
                f"<!-- {loc.GENERATED_ALIAS_MARKER}; test -->\n"
                "Alias body\n",
                encoding="utf-8",
            )
            budget = base_budget(
                **{
                    m: {
                        "current_ratchet": 0,
                        "hard_ceiling": 0,
                        "release_target": 0,
                        "baseline": 0,
                    }
                    for m in METRIC_IDS
                }
            )
            # Generated aliases still count toward runtime/total surfaces.
            budget["metrics"]["runtime_prompt_surface_loc"]["current_ratchet"] = 100
            budget["metrics"]["runtime_prompt_surface_loc"]["hard_ceiling"] = 100
            budget["metrics"]["total_md_sh_excl_tests_docs"]["current_ratchet"] = 100
            budget["metrics"]["total_md_sh_excl_tests_docs"]["hard_ceiling"] = 100
            write_budget(root / "integrity" / "loc-budget.json", budget)
            measured = loc.measure(root, budget)
            self.assertEqual(measured["wrapper_skills_hand_maintained"], 0)
            self.assertEqual(measured["wrapper_skills_hand_maintained_loc"], 0)
            self.assertGreater(measured["runtime_prompt_surface_loc"], 0)

            # Extra file beside a marked SKILL.md re-enters hand-maintained.
            write_lines(d / "notes.md", 3)
            measured = loc.measure(root, budget)
            self.assertEqual(measured["wrapper_skills_hand_maintained"], 1)
            self.assertGreater(measured["wrapper_skills_hand_maintained_loc"], 0)

    def test_exceed_agents_md_loc(self) -> None:
        def setup(root: Path) -> None:
            write_lines(root / "agents" / "a.md", 4)

        proc = self._run_with_metric("agents_md_loc", setup)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("agents_md_loc", proc.stderr)

    def test_exceed_runtime_prompt_surface_loc(self) -> None:
        def setup(root: Path) -> None:
            write_lines(root / "commands" / "c.md", 6)

        proc = self._run_with_metric("runtime_prompt_surface_loc", setup)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("runtime_prompt_surface_loc", proc.stderr)

    def test_exceed_total_md_sh(self) -> None:
        def setup(root: Path) -> None:
            write_lines(root / "README.md", 3)
            # tests/ and docs/ must not count
            write_lines(root / "tests" / "t.sh", 50)
            write_lines(root / "docs" / "d.md", 50)

        proc = self._run_with_metric("total_md_sh_excl_tests_docs", setup)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("total_md_sh_excl_tests_docs", proc.stderr)

    def test_top_level_tests_docs_excluded_from_total(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            make_plugin(root)
            write_lines(root / "tests" / "t.sh", 20)
            write_lines(root / "docs" / "d.md", 20)
            write_lines(root / "keep.md", 2)
            budget = base_budget(
                **{
                    m: {"current_ratchet": 100, "hard_ceiling": 100, "release_target": 0, "baseline": 0}
                    for m in METRIC_IDS
                }
            )
            write_budget(root / "integrity" / "loc-budget.json", budget)
            measured = loc.measure(root, budget)
            self.assertEqual(measured["total_md_sh_excl_tests_docs"], 2)
            self.assertEqual(measured["scripts_sh_loc"], 0)


class RatchetModes(unittest.TestCase):
    def test_pre_1_0_allows_decrease_rejects_increase(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            make_plugin(root)
            write_lines(root / "scripts" / "a.sh", 5)
            budget = base_budget(
                scripts_sh_loc={
                    "baseline": 10,
                    "release_target": 1,
                    "hard_ceiling": 20,
                    "current_ratchet": 5,
                },
                total_md_sh_excl_tests_docs={
                    "baseline": 10,
                    "release_target": 1,
                    "hard_ceiling": 20,
                    "current_ratchet": 10,
                },
                **{
                    m: {"current_ratchet": 0, "hard_ceiling": 0, "release_target": 0, "baseline": 0}
                    for m in METRIC_IDS
                    if m not in {"scripts_sh_loc", "total_md_sh_excl_tests_docs"}
                },
            )
            bpath = root / "integrity" / "loc-budget.json"
            write_budget(bpath, budget)
            proc = run_checker(["--plugin-root", str(root), "--budget", str(bpath)])
            self.assertEqual(proc.returncode, 0, proc.stderr)

            write_lines(root / "scripts" / "a.sh", 6)
            proc = run_checker(["--plugin-root", str(root), "--budget", str(bpath)])
            self.assertEqual(proc.returncode, 1)
            self.assertIn("scripts_sh_loc", proc.stderr)

    def test_post_1_0_rejects_increase_under_ceiling_headroom(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            make_plugin(root)
            write_lines(root / "scripts" / "a.sh", 4)
            budget = base_budget(
                scripts_sh_loc={
                    "baseline": 10,
                    "release_target": 3,
                    "hard_ceiling": 100,
                    "current_ratchet": 3,
                },
                **{
                    m: {"current_ratchet": 0, "hard_ceiling": 0, "release_target": 0, "baseline": 0}
                    for m in METRIC_IDS
                    if m != "scripts_sh_loc"
                },
            )
            budget["phase"] = "post-1.0"
            bpath = root / "integrity" / "loc-budget.json"
            write_budget(bpath, budget)
            # 4 > ratchet 3 even though 4 << hard_ceiling 100
            proc = run_checker(["--plugin-root", str(root), "--budget", str(bpath)])
            self.assertEqual(proc.returncode, 1)
            self.assertIn("current_ratchet", proc.stderr)

    def test_release_mode_requires_all_targets(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            make_plugin(root)
            write_lines(root / "scripts" / "a.sh", 2)
            budget = base_budget(
                scripts_sh_loc={
                    "baseline": 10,
                    "release_target": 1,
                    "hard_ceiling": 10,
                    "current_ratchet": 10,
                },
                **{
                    m: {"current_ratchet": 0, "hard_ceiling": 0, "release_target": 0, "baseline": 0}
                    for m in METRIC_IDS
                    if m != "scripts_sh_loc"
                },
            )
            bpath = root / "integrity" / "loc-budget.json"
            write_budget(bpath, budget)
            proc = run_checker(
                ["--plugin-root", str(root), "--budget", str(bpath), "--release", "1.0.0"]
            )
            self.assertEqual(proc.returncode, 1)
            self.assertIn("release_target", proc.stderr)


class AntiWeaken(unittest.TestCase):
    def test_rejects_raised_ratchet_target_ceiling_and_exclusions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            base = base_budget(
                scripts_sh_loc={
                    "baseline": 100,
                    "release_target": 10,
                    "hard_ceiling": 20,
                    "current_ratchet": 15,
                }
            )
            head = json.loads(json.dumps(base))
            head["metrics"]["scripts_sh_loc"]["current_ratchet"] = 16
            head["metrics"]["scripts_sh_loc"]["release_target"] = 11
            head["metrics"]["scripts_sh_loc"]["hard_ceiling"] = 21
            head["exclusions"]["total_md_sh_excl_tests_docs"]["exclude_top_level_dirs"] = [
                "tests",
                "docs",
                "references",
            ]
            head["generated_files"]["policy"] = "ignored"
            head["counting_rules"]["scripts_sh_loc"] = "changed rule"

            base_path = tmp_path / "base.json"
            head_path = tmp_path / "head.json"
            write_budget(base_path, base)
            write_budget(head_path, head)

            root = tmp_path / "plugin"
            make_plugin(root)
            # Keep head measurable so enforce + anti-weaken both run; policy
            # soften is still reported via anti-weaken.
            head_meas = json.loads(json.dumps(head))
            head_meas["generated_files"]["policy"] = "counted"
            write_budget(root / "integrity" / "loc-budget.json", head_meas)

            proc = run_checker(
                [
                    "--plugin-root",
                    str(root),
                    "--budget",
                    str(head_path),
                    "--compare-base",
                    str(base_path),
                    "--measure-only",
                ]
            )
            # measure-only still applies anti-weaken errors
            self.assertEqual(proc.returncode, 1, proc.stderr + proc.stdout)
            err = proc.stderr + proc.stdout
            self.assertIn("current_ratchet", err)
            self.assertIn("release_target", err)
            self.assertIn("hard_ceiling", err)
            self.assertIn("exclusions grew", err)
            self.assertIn("generated_files.policy", err)
            self.assertIn("counting_rules.scripts_sh_loc", err)

            # Softened generated policy on a measurable tree is also rejected
            # at measure time when not only comparing.
            soft = json.loads(json.dumps(base))
            soft["generated_files"]["policy"] = "ignored"
            soft_path = tmp_path / "soft.json"
            write_budget(soft_path, soft)
            write_budget(root / "integrity" / "loc-budget.json", soft)
            proc = run_checker(
                [
                    "--plugin-root",
                    str(root),
                    "--budget",
                    str(soft_path),
                    "--compare-base",
                    str(base_path),
                ]
            )
            self.assertEqual(proc.returncode, 1)
            self.assertIn("generated_files.policy", proc.stderr)

    def test_counting_rules_allow_change_keys_skip_anti_weaken(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            base = base_budget()
            head = json.loads(json.dumps(base))
            head["counting_rules"]["wrapper_skills_hand_maintained"] = "clarified rule"
            head["counting_rules_allow_change"] = {
                "issue": 383,
                "keys": ["wrapper_skills_hand_maintained"],
            }
            base_path = tmp_path / "base.json"
            head_path = tmp_path / "head.json"
            write_budget(base_path, base)
            write_budget(head_path, head)
            root = tmp_path / "plugin"
            make_plugin(root)
            write_budget(root / "integrity" / "loc-budget.json", head)
            proc = run_checker(
                [
                    "--plugin-root",
                    str(root),
                    "--budget",
                    str(head_path),
                    "--compare-base",
                    str(base_path),
                    "--measure-only",
                ]
            )
            self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
            self.assertNotIn("counting_rules.wrapper_skills_hand_maintained", proc.stderr)

            # One-shot only: once base already carries the allow key, further
            # rule edits for that key fail anti-weaken again.
            base2 = json.loads(json.dumps(head))
            head2 = json.loads(json.dumps(head))
            head2["counting_rules"]["wrapper_skills_hand_maintained"] = "second edit"
            base2_path = tmp_path / "base2.json"
            head2_path = tmp_path / "head2.json"
            write_budget(base2_path, base2)
            write_budget(head2_path, head2)
            write_budget(root / "integrity" / "loc-budget.json", head2)
            proc = run_checker(
                [
                    "--plugin-root",
                    str(root),
                    "--budget",
                    str(head2_path),
                    "--compare-base",
                    str(base2_path),
                    "--measure-only",
                ]
            )
            self.assertEqual(proc.returncode, 1, proc.stderr + proc.stdout)
            self.assertIn("counting_rules.wrapper_skills_hand_maintained", proc.stderr)

    def test_allows_ratchet_decrease(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            base = base_budget(
                scripts_sh_loc={
                    "baseline": 100,
                    "release_target": 10,
                    "hard_ceiling": 20,
                    "current_ratchet": 15,
                }
            )
            head = json.loads(json.dumps(base))
            head["metrics"]["scripts_sh_loc"]["current_ratchet"] = 12
            base_path = tmp_path / "base.json"
            head_path = tmp_path / "head.json"
            write_budget(base_path, base)
            write_budget(head_path, head)
            root = tmp_path / "plugin"
            make_plugin(root)
            write_budget(root / "integrity" / "loc-budget.json", head)
            proc = run_checker(
                [
                    "--plugin-root",
                    str(root),
                    "--budget",
                    str(root / "integrity" / "loc-budget.json"),
                    "--compare-base",
                    str(base_path),
                ]
            )
            self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)

    def test_release_target_allow_raise_oneshot(self) -> None:
        """#392: epic-justified release_target/hard_ceiling raise is one-shot."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            base = base_budget(
                scripts_sh_loc={
                    "baseline": 100,
                    "release_target": 10,
                    "hard_ceiling": 20,
                    "current_ratchet": 15,
                }
            )
            head = json.loads(json.dumps(base))
            head["metrics"]["scripts_sh_loc"]["release_target"] = 30
            head["metrics"]["scripts_sh_loc"]["hard_ceiling"] = 40
            head["release_target_allow_raise"] = {
                "issue": 392,
                "metrics": ["scripts_sh_loc"],
                "keys": ["release_target", "hard_ceiling"],
            }
            base_path = tmp_path / "base.json"
            head_path = tmp_path / "head.json"
            write_budget(base_path, base)
            write_budget(head_path, head)
            root = tmp_path / "plugin"
            make_plugin(root)
            write_budget(root / "integrity" / "loc-budget.json", head)
            proc = run_checker(
                [
                    "--plugin-root",
                    str(root),
                    "--budget",
                    str(head_path),
                    "--compare-base",
                    str(base_path),
                    "--measure-only",
                ]
            )
            self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
            self.assertNotIn("release_target rose", proc.stderr)

            # One-shot only: once base carries the allow metric, further raises fail.
            base2 = json.loads(json.dumps(head))
            head2 = json.loads(json.dumps(head))
            head2["metrics"]["scripts_sh_loc"]["release_target"] = 50
            base2_path = tmp_path / "base2.json"
            head2_path = tmp_path / "head2.json"
            write_budget(base2_path, base2)
            write_budget(head2_path, head2)
            write_budget(root / "integrity" / "loc-budget.json", head2)
            proc = run_checker(
                [
                    "--plugin-root",
                    str(root),
                    "--budget",
                    str(head2_path),
                    "--compare-base",
                    str(base2_path),
                    "--measure-only",
                ]
            )
            self.assertEqual(proc.returncode, 1, proc.stderr + proc.stdout)
            self.assertIn("release_target rose", proc.stderr)

            # current_ratchet may never rise even with the allow block.
            head3 = json.loads(json.dumps(head))
            head3["metrics"]["scripts_sh_loc"]["current_ratchet"] = 99
            head3_path = tmp_path / "head3.json"
            write_budget(head3_path, head3)
            proc = run_checker(
                [
                    "--plugin-root",
                    str(root),
                    "--budget",
                    str(head3_path),
                    "--compare-base",
                    str(base_path),
                    "--measure-only",
                ]
            )
            self.assertEqual(proc.returncode, 1, proc.stderr + proc.stdout)
            self.assertIn("current_ratchet rose", proc.stderr)


class GeneratedAndExtracted(unittest.TestCase):
    def test_generated_dir_counts_toward_total(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            make_plugin(root)
            write_lines(root / "generated" / "out.md", 7)
            budget = base_budget()
            measured = loc.measure(root, budget)
            self.assertEqual(measured["total_md_sh_excl_tests_docs"], 7)
            self.assertEqual(measured["runtime_prompt_surface_loc"], 0)

    def test_declared_sibling_adds_to_metric(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            make_plugin(root)
            budget = base_budget(
                scripts_sh_loc={
                    "baseline": 0,
                    "release_target": 0,
                    "hard_ceiling": 100,
                    "current_ratchet": 5,
                }
            )
            budget["extracted_packages"]["declared_siblings"] = [
                {"metric_id": "scripts_sh_loc", "loc": 6, "path": "../sibling-pkg"}
            ]
            measured = loc.measure(root, budget)
            self.assertEqual(measured["scripts_sh_loc"], 6)
            errors = loc.enforce(budget, measured, release=None)
            self.assertTrue(any("scripts_sh_loc" in e for e in errors))

    def test_non_counted_generated_policy_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            make_plugin(root)
            budget = base_budget()
            budget["generated_files"]["policy"] = "ignored"
            with self.assertRaises(ValueError):
                loc.measure(root, budget)


class UndeclaredExtraction(unittest.TestCase):
    def test_detects_file_moved_outside_plugin_without_declaration(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            plugin = repo / "plugins" / "saas-startup-team"
            sibling = repo / "plugins" / "extracted-bits"
            make_plugin(plugin)
            write_lines(plugin / "scripts" / "moved.sh", 4)
            sibling.mkdir(parents=True)
            subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True)
            subprocess.run(
                ["git", "config", "user.email", "t@t.t"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "t"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            subprocess.run(["git", "add", "."], cwd=repo, check=True, capture_output=True)
            subprocess.run(
                ["git", "commit", "-m", "base"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            base = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repo, text=True
            ).strip()
            # Move runtime shell outside plugin without declaration.
            content = (plugin / "scripts" / "moved.sh").read_text(encoding="utf-8")
            (plugin / "scripts" / "moved.sh").unlink()
            (sibling / "moved.sh").write_text(content, encoding="utf-8")
            subprocess.run(["git", "add", "-A"], cwd=repo, check=True, capture_output=True)
            subprocess.run(
                ["git", "commit", "-m", "extract"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            budget = base_budget()
            write_budget(plugin / "integrity" / "loc-budget.json", budget)
            errors = loc.detect_undeclared_extractions(
                repo_root=repo,
                plugin_root=plugin,
                git_base=base,
                budget=budget,
            )
            self.assertTrue(errors)
            self.assertIn("undeclared extraction", errors[0])

            # Wrong metric declaration must not pool-cover the extraction.
            budget["extracted_packages"]["declared_siblings"] = [
                {
                    "metric_id": "agents_md_loc",
                    "loc": 4,
                    "path": "plugins/extracted-bits",
                }
            ]
            errors = loc.detect_undeclared_extractions(
                repo_root=repo,
                plugin_root=plugin,
                git_base=base,
                budget=budget,
            )
            self.assertTrue(any("scripts_sh_loc" in e for e in errors), errors)

            # Correct metric declarations clear the failure.
            budget["extracted_packages"]["declared_siblings"] = [
                {
                    "metric_id": "scripts_sh_loc",
                    "loc": 4,
                    "path": "plugins/extracted-bits",
                },
                {
                    "metric_id": "total_md_sh_excl_tests_docs",
                    "loc": 4,
                    "path": "plugins/extracted-bits",
                },
            ]
            errors = loc.detect_undeclared_extractions(
                repo_root=repo,
                plugin_root=plugin,
                git_base=base,
                budget=budget,
            )
            self.assertEqual(errors, [])

    def test_detects_edited_move_by_basename(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            plugin = repo / "plugins" / "saas-startup-team"
            sibling = repo / "plugins" / "extracted-bits"
            make_plugin(plugin)
            write_lines(plugin / "scripts" / "moved.sh", 4)
            sibling.mkdir(parents=True)
            subprocess.run(["git", "init"], cwd=repo, check=True, capture_output=True)
            subprocess.run(
                ["git", "config", "user.email", "t@t.t"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "t"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            subprocess.run(["git", "add", "."], cwd=repo, check=True, capture_output=True)
            subprocess.run(
                ["git", "commit", "-m", "base"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            base = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repo, text=True
            ).strip()
            (plugin / "scripts" / "moved.sh").unlink()
            write_lines(sibling / "moved.sh", 5)  # edited in same move
            subprocess.run(["git", "add", "-A"], cwd=repo, check=True, capture_output=True)
            subprocess.run(
                ["git", "commit", "-m", "extract-edit"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            budget = base_budget()
            errors = loc.detect_undeclared_extractions(
                repo_root=repo,
                plugin_root=plugin,
                git_base=base,
                budget=budget,
            )
            self.assertTrue(any("undeclared extraction" in e for e in errors), errors)

    def test_anti_weaken_rejects_removed_counting_rule(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            base = base_budget()
            head = json.loads(json.dumps(base))
            del head["counting_rules"]["scripts_sh_loc"]
            write_budget(tmp_path / "base.json", base)
            write_budget(tmp_path / "head.json", head)
            errors = loc.anti_weaken(base, head)
            self.assertTrue(any("counting_rules.scripts_sh_loc removed" in e for e in errors))


class SymlinkSafety(unittest.TestCase):
    def test_symlinks_not_double_counted(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            make_plugin(root)
            write_lines(root / "README.md", 5)
            (root / "README.link.md").symlink_to("README.md")
            budget = base_budget()
            measured = loc.measure(root, budget)
            self.assertEqual(measured["total_md_sh_excl_tests_docs"], 5)

    def test_root_claude_agents_excluded_from_total(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "plugin"
            make_plugin(root)
            write_lines(root / "CLAUDE.md", 5)
            write_lines(root / "keep.md", 2)
            budget = base_budget()
            measured = loc.measure(root, budget)
            self.assertEqual(measured["total_md_sh_excl_tests_docs"], 2)


if __name__ == "__main__":
    unittest.main()
