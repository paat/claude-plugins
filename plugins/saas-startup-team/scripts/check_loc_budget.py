#!/usr/bin/env python3
"""Ratcheting LOC budget gate for saas-startup-team (issue #382).

Modes:
  default / pre-1.0  — fail if any metric > current_ratchet
  --release 1.0.0    — fail if any metric > release_target
  post-1.0 phase     — fail if any metric > current_ratchet (even under hard_ceiling)
  --compare-base F   — reject weakening of targets/ceilings/ratchets/exclusions/rules

Exit codes: 0 pass, 1 budget/policy failure, 2 usage/config error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

SCRIPT_PATH = Path(__file__).resolve()
PLUGIN_ROOT = SCRIPT_PATH.parents[1]
DEFAULT_BUDGET = PLUGIN_ROOT / "integrity" / "loc-budget.json"

METRIC_IDS = (
    "scripts_sh_loc",
    "wrapper_skills_hand_maintained",
    "wrapper_skills_hand_maintained_loc",
    "agents_md_loc",
    "runtime_prompt_surface_loc",
    "total_md_sh_excl_tests_docs",
)

WRAPPER_GLOB = "saas-startup-team-*-workflow"
# Generated thin aliases (issue #383) carry this marker and are not hand-maintained.
GENERATED_ALIAS_MARKER = "GENERATED-ALIAS: do not edit"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--plugin-root",
        type=Path,
        default=PLUGIN_ROOT,
        help="Plugin root to measure (default: this plugin)",
    )
    parser.add_argument(
        "--budget",
        type=Path,
        default=None,
        help="Path to loc-budget.json (default: <plugin-root>/integrity/loc-budget.json)",
    )
    parser.add_argument(
        "--release",
        metavar="VERSION",
        default=None,
        help="Release gate (e.g. 1.0.0): require every metric <= release_target",
    )
    parser.add_argument(
        "--compare-base",
        type=Path,
        default=None,
        help="Merge-base loc-budget.json; reject weakening relative to it",
    )
    parser.add_argument(
        "--git-base",
        default=None,
        help="Git commit/ref for undeclared extraction detection (use merge-base SHA)",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="Monorepo root (required with --git-base)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable measurement + verdict",
    )
    parser.add_argument(
        "--measure-only",
        action="store_true",
        help="Print measurements and exit 0 (no budget enforcement)",
    )
    args = parser.parse_args(argv)

    plugin_root = args.plugin_root.resolve()
    budget_path = (args.budget or (plugin_root / "integrity" / "loc-budget.json")).resolve()

    try:
        budget = load_budget(budget_path)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"error: cannot load budget {budget_path}: {exc}", file=sys.stderr)
        return 2

    errors: list[str] = []
    if args.compare_base is not None:
        try:
            base = load_budget(args.compare_base.resolve())
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            print(f"error: cannot load compare-base: {exc}", file=sys.stderr)
            return 2
        errors.extend(anti_weaken(base, budget))

    if args.git_base is not None:
        if args.repo_root is None:
            print("error: --repo-root is required with --git-base", file=sys.stderr)
            return 2
        try:
            errors.extend(
                detect_undeclared_extractions(
                    repo_root=args.repo_root.resolve(),
                    plugin_root=plugin_root,
                    git_base=args.git_base,
                    budget=budget,
                )
            )
        except (OSError, ValueError, subprocess.CalledProcessError) as exc:
            print(f"error: extraction scan failed: {exc}", file=sys.stderr)
            return 2

    try:
        measured = measure(plugin_root, budget)
    except (OSError, ValueError) as exc:
        # Still report anti-weaken findings when measurement cannot run
        # (e.g. head budget softens generated_files.policy).
        if errors:
            for err in errors:
                print(f"error: {err}", file=sys.stderr)
            print(f"error: measurement failed: {exc}", file=sys.stderr)
            return 1
        print(f"error: measurement failed: {exc}", file=sys.stderr)
        return 2

    if args.measure_only:
        emit(measured, budget, errors, args.json)
        return 1 if errors else 0

    errors.extend(enforce(budget, measured, release=args.release))
    emit(measured, budget, errors, args.json)
    return 1 if errors else 0


def load_budget(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("budget root must be an object")
    metrics = payload.get("metrics")
    if not isinstance(metrics, dict):
        raise ValueError("budget.metrics must be an object")
    for mid in METRIC_IDS:
        if mid not in metrics:
            raise ValueError(f"budget.metrics missing {mid}")
        entry = metrics[mid]
        if not isinstance(entry, dict):
            raise ValueError(f"budget.metrics.{mid} must be an object")
        for key in ("baseline", "release_target", "hard_ceiling", "current_ratchet"):
            if key not in entry or not isinstance(entry[key], int):
                raise ValueError(f"budget.metrics.{mid}.{key} must be an int")
    return payload


def is_regular_file(path: Path) -> bool:
    try:
        return path.is_file() and not path.is_symlink()
    except OSError:
        return False


def is_hand_maintained_wrapper(wrapper_dir: Path) -> bool:
    """True when skills/saas-startup-team-*-workflow lacks the generated-alias marker.

    Baseline 0.90.11 wrappers had no marker, so they still measure as hand-maintained.
    Thin generated aliases (#383) include GENERATED_ALIAS_MARKER and count as 0.
    """
    skill = wrapper_dir / "SKILL.md"
    if not is_regular_file(skill):
        # Empty/malformed wrapper dir still counts as hand-maintained surface.
        return True
    try:
        # Read a small prefix first; marker is on line 5 of generated aliases.
        text = skill.read_text(encoding="utf-8")
    except OSError:
        return True
    return GENERATED_ALIAS_MARKER not in text


def line_count(path: Path) -> int:
    """Match `wc -l`: number of newline bytes in the file."""
    data = path.read_bytes()
    if not data:
        return 0
    return data.count(b"\n")


def sum_lines(paths: list[Path]) -> int:
    return sum(line_count(p) for p in paths)


def measure(plugin_root: Path, budget: dict[str, Any]) -> dict[str, int]:
    if not plugin_root.is_dir():
        raise ValueError(f"plugin root not a directory: {plugin_root}")

    scripts = [
        p
        for p in (plugin_root / "scripts").rglob("*.sh")
        if is_regular_file(p)
    ]
    wrappers = sorted(
        p
        for p in (plugin_root / "skills").glob(WRAPPER_GLOB)
        if p.is_dir()
        and not p.is_symlink()
        and is_hand_maintained_wrapper(p)
    )
    wrapper_skills = [
        p / "SKILL.md" for p in wrappers if is_regular_file(p / "SKILL.md")
    ]
    agents = [
        p
        for p in (plugin_root / "agents").rglob("*.md")
        if is_regular_file(p)
    ]
    runtime_dirs = ("agents", "commands", "skills")
    runtime: list[Path] = []
    for name in runtime_dirs:
        base = plugin_root / name
        if base.is_dir():
            runtime.extend(p for p in base.rglob("*.md") if is_regular_file(p))

    total_excl = budget.get("exclusions", {}).get("total_md_sh_excl_tests_docs", {})
    excl = total_excl.get("exclude_top_level_dirs", ["tests", "docs"])
    if not isinstance(excl, list) or not all(isinstance(x, str) for x in excl):
        raise ValueError("exclusions.total_md_sh_excl_tests_docs.exclude_top_level_dirs invalid")
    exclude_set = set(excl)
    exclude_root_files = total_excl.get("exclude_root_files", ["CLAUDE.md", "AGENTS.md"])
    if not isinstance(exclude_root_files, list) or not all(
        isinstance(x, str) for x in exclude_root_files
    ):
        raise ValueError("exclusions.total_md_sh_excl_tests_docs.exclude_root_files invalid")
    exclude_root_set = set(exclude_root_files)

    total_files: list[Path] = []
    for p in plugin_root.rglob("*"):
        if not is_regular_file(p):
            continue
        if p.suffix not in {".md", ".sh"}:
            continue
        rel = p.relative_to(plugin_root)
        if rel.parts and rel.parts[0] in exclude_set:
            continue
        if len(rel.parts) == 1 and rel.name in exclude_root_set:
            continue
        total_files.append(p)

    measured = {
        "scripts_sh_loc": sum_lines(scripts),
        "wrapper_skills_hand_maintained": len(wrappers),
        "wrapper_skills_hand_maintained_loc": sum_lines(wrapper_skills),
        "agents_md_loc": sum_lines(agents),
        "runtime_prompt_surface_loc": sum_lines(runtime),
        "total_md_sh_excl_tests_docs": sum_lines(total_files),
    }

    # Declared sibling package LOC is added so extraction cannot hide runtime cost.
    siblings = budget.get("extracted_packages", {}).get("declared_siblings") or []
    if not isinstance(siblings, list):
        raise ValueError("extracted_packages.declared_siblings must be a list")
    for item in siblings:
        if not isinstance(item, dict):
            raise ValueError("declared_siblings entries must be objects")
        mid = item.get("metric_id")
        loc = item.get("loc")
        if mid not in measured or not isinstance(loc, int) or loc < 0:
            raise ValueError(f"invalid declared_sibling: {item!r}")
        measured[mid] += loc

    # Generated paths are still counted via normal walks; policy is enforced separately.
    gen = budget.get("generated_files", {})
    if isinstance(gen, dict) and gen.get("policy") not in (None, "counted"):
        raise ValueError(
            "generated_files.policy must be 'counted' "
            "(generation is not an escape hatch)"
        )

    return measured


def enforce(
    budget: dict[str, Any],
    measured: dict[str, int],
    release: str | None,
) -> list[str]:
    errors: list[str] = []
    phase = str(budget.get("phase") or "pre-1.0")
    metrics: dict[str, Any] = budget["metrics"]
    post = phase.startswith("post-1") or phase == "post-1.0"

    if release is not None:
        target_ver = str(budget.get("release_target_version") or "1.0.0")
        if release != target_ver:
            errors.append(
                f"--release {release} is not the configured release_target_version {target_ver}"
            )
            return errors
        for mid in METRIC_IDS:
            entry = metrics[mid]
            value = measured[mid]
            limit = entry["release_target"]
            if value > limit:
                errors.append(
                    f"{mid}: {value} exceeds release_target {limit} for {release}"
                )
        return errors

    for mid in METRIC_IDS:
        entry = metrics[mid]
        value = measured[mid]
        ratchet = entry["current_ratchet"]
        ceiling = entry["hard_ceiling"]
        if value > ratchet:
            errors.append(
                f"{mid}: {value} exceeds current_ratchet {ratchet} "
                f"(phase={phase}; lower the metric or refuse the growth)"
            )
        # hard_ceiling is the post-1.0 absolute cap. Pre-1.0 thinning intentionally
        # sits above it while ratcheting down toward release_target.
        if post and value > ceiling:
            errors.append(
                f"{mid}: {value} exceeds hard_ceiling {ceiling}"
            )
        if post and ratchet > ceiling:
            errors.append(
                f"{mid}: current_ratchet {ratchet} exceeds hard_ceiling {ceiling} "
                f"(budget file is inconsistent for post-1.0)"
            )
    return errors


def _git_stdout(repo_root: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo_root), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return proc.stdout


def _git_show_bytes(repo_root: Path, rev: str, path: str) -> bytes | None:
    proc = subprocess.run(
        ["git", "-C", str(repo_root), "show", f"{rev}:{path}"],
        capture_output=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def _metrics_for_plugin_rel(
    rel_plugin: str, path: str, content: bytes | None = None
) -> list[str]:
    """Map a former plugin path to the metrics it contributed to."""
    # path is repo-relative like plugins/saas-startup-team/scripts/x.sh
    prefix = rel_plugin.rstrip("/") + "/"
    if not path.startswith(prefix):
        return []
    inner = path[len(prefix) :]
    metrics: list[str] = ["total_md_sh_excl_tests_docs"]
    if inner.startswith("scripts/") and inner.endswith(".sh"):
        metrics.append("scripts_sh_loc")
    if inner.startswith("agents/") and inner.endswith(".md"):
        metrics.append("agents_md_loc")
    if (
        inner.startswith("agents/")
        or inner.startswith("commands/")
        or inner.startswith("skills/")
    ) and inner.endswith(".md"):
        metrics.append("runtime_prompt_surface_loc")
    if (
        "/saas-startup-team-" in inner
        and inner.endswith("-workflow/SKILL.md")
        and inner.startswith("skills/")
    ):
        # Generated aliases are not hand-maintained (issue #383).
        text = content.decode("utf-8", errors="replace") if content is not None else ""
        if GENERATED_ALIAS_MARKER not in text:
            metrics.append("wrapper_skills_hand_maintained_loc")
    return metrics


def detect_undeclared_extractions(
    repo_root: Path,
    plugin_root: Path,
    git_base: str,
    budget: dict[str, Any],
) -> list[str]:
    """Fail when runtime .md/.sh leave the plugin tree without declared_siblings.

    Uses git rename detection (-M) plus content-hash matching so lightly edited
    moves still count. Declared sibling LOC must cover each affected metric_id
    separately (no cross-metric pooling).
    """
    errors: list[str] = []
    try:
        rel_plugin = plugin_root.resolve().relative_to(repo_root.resolve()).as_posix()
    except ValueError as exc:
        raise ValueError("plugin-root must be inside repo-root") from exc

    prefix = rel_plugin.rstrip("/") + "/"

    # git rename detection: R100 old new, also catch pure deletes that reappear outside.
    status = _git_stdout(
        repo_root,
        "diff",
        "-M",
        "--name-status",
        "--diff-filter=R",
        git_base,
        "HEAD",
    ).splitlines()
    renamed_out: list[tuple[str, str]] = []
    for line in status:
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        _code, old, new = parts
        if old.startswith(prefix) and not new.startswith(prefix):
            if old.endswith((".md", ".sh")):
                renamed_out.append((old, new))

    base_list = _git_stdout(
        repo_root, "ls-tree", "-r", "--name-only", git_base, rel_plugin
    ).splitlines()
    head_list = _git_stdout(
        repo_root, "ls-tree", "-r", "--name-only", "HEAD", rel_plugin
    ).splitlines()
    base_set = {p for p in base_list if p.endswith((".md", ".sh"))}
    head_set = {p for p in head_list if p.endswith((".md", ".sh"))}
    removed = sorted(base_set - head_set)

    head_plugin_hashes: set[str] = set()
    for path in head_set:
        data = _git_show_bytes(repo_root, "HEAD", path)
        if data is not None:
            head_plugin_hashes.add(hashlib.sha256(data).hexdigest())

    all_head = _git_stdout(repo_root, "ls-tree", "-r", "--name-only", "HEAD").splitlines()
    outside_by_hash: dict[str, list[str]] = {}
    outside_by_basename: dict[str, list[str]] = {}
    for path in all_head:
        if not path.endswith((".md", ".sh")):
            continue
        if path == rel_plugin or path.startswith(prefix):
            continue
        data = _git_show_bytes(repo_root, "HEAD", path)
        if data is None:
            continue
        digest = hashlib.sha256(data).hexdigest()
        outside_by_hash.setdefault(digest, []).append(path)
        outside_by_basename.setdefault(Path(path).name, []).append(path)

    siblings = budget.get("extracted_packages", {}).get("declared_siblings") or []
    if not isinstance(siblings, list):
        siblings = []
    declared_by_metric: dict[str, int] = {mid: 0 for mid in METRIC_IDS}
    for item in siblings:
        if not isinstance(item, dict):
            continue
        mid = item.get("metric_id")
        loc = item.get("loc")
        if mid in declared_by_metric and isinstance(loc, int) and loc >= 0:
            declared_by_metric[mid] += loc

    needed_by_metric: dict[str, int] = {mid: 0 for mid in METRIC_IDS}
    extracted_paths: list[str] = []
    seen_old: set[str] = set()

    def charge(old: str, new: str, data: bytes) -> None:
        if old in seen_old:
            return
        seen_old.add(old)
        loc = data.count(b"\n") if data else 0
        for mid in _metrics_for_plugin_rel(rel_plugin, old, data):
            needed_by_metric[mid] += loc
        extracted_paths.append(f"{old} -> {new} ({loc} loc)")

    for old, new in renamed_out:
        data = _git_show_bytes(repo_root, git_base, old)
        if data is None:
            continue
        charge(old, new, data)

    for path in removed:
        if path in seen_old:
            continue
        data = _git_show_bytes(repo_root, git_base, path)
        if data is None:
            continue
        digest = hashlib.sha256(data).hexdigest()
        if digest in head_plugin_hashes:
            continue  # still inside plugin under another name
        outside = outside_by_hash.get(digest) or []
        if not outside:
            # Lightly edited move: same basename outside plugin.
            outside = outside_by_basename.get(Path(path).name) or []
        if not outside:
            continue
        charge(path, outside[0], data)

    for mid, needed in needed_by_metric.items():
        if needed <= 0:
            continue
        declared = declared_by_metric.get(mid, 0)
        if needed > declared:
            detail = "; ".join(extracted_paths[:8])
            more = (
                ""
                if len(extracted_paths) <= 8
                else f" (+{len(extracted_paths) - 8} more)"
            )
            errors.append(
                f"undeclared extraction for {mid}: need {needed} LOC in "
                f"declared_siblings but only {declared} declared "
                f"[{detail}{more}]"
            )
    return errors


def anti_weaken(base: dict[str, Any], head: dict[str, Any]) -> list[str]:
    """Reject changes that weaken budget policy relative to merge base."""
    errors: list[str] = []
    base_m = base["metrics"]
    head_m = head["metrics"]

    for mid in METRIC_IDS:
        b = base_m[mid]
        h = head_m[mid]
        for key, label in (
            ("release_target", "release_target"),
            ("hard_ceiling", "hard_ceiling"),
            ("current_ratchet", "current_ratchet"),
        ):
            if h[key] > b[key]:
                errors.append(
                    f"anti-weaken: metrics.{mid}.{label} rose "
                    f"{b[key]} -> {h[key]}"
                )
        # Baselines are historical pins; changing them is weakening auditability.
        if h["baseline"] != b["baseline"]:
            errors.append(
                f"anti-weaken: metrics.{mid}.baseline changed "
                f"{b['baseline']} -> {h['baseline']}"
            )

    base_excl = (
        base.get("exclusions", {})
        .get("total_md_sh_excl_tests_docs", {})
        .get("exclude_top_level_dirs", [])
    )
    head_excl = (
        head.get("exclusions", {})
        .get("total_md_sh_excl_tests_docs", {})
        .get("exclude_top_level_dirs", [])
    )
    if not isinstance(base_excl, list):
        base_excl = []
    if not isinstance(head_excl, list):
        head_excl = []
    if set(head_excl) - set(base_excl):
        errors.append(
            f"anti-weaken: exclusions grew {sorted(base_excl)} -> {sorted(head_excl)}"
        )

    base_root_excl = (
        base.get("exclusions", {})
        .get("total_md_sh_excl_tests_docs", {})
        .get("exclude_root_files", [])
    )
    head_root_excl = (
        head.get("exclusions", {})
        .get("total_md_sh_excl_tests_docs", {})
        .get("exclude_root_files", [])
    )
    if not isinstance(base_root_excl, list):
        base_root_excl = []
    if not isinstance(head_root_excl, list):
        head_root_excl = []
    if set(head_root_excl) - set(base_root_excl):
        errors.append(
            "anti-weaken: exclude_root_files grew "
            f"{sorted(base_root_excl)} -> {sorted(head_root_excl)}"
        )

    base_rules = base.get("counting_rules") or {}
    head_rules = head.get("counting_rules") or {}
    allow_raw = head.get("counting_rules_allow_change") or {}
    allowed_keys: set[str] = set()
    if isinstance(allow_raw, dict):
        keys = allow_raw.get("keys") or []
        if isinstance(keys, list):
            allowed_keys = {k for k in keys if isinstance(k, str)}
    if isinstance(base_rules, dict) and isinstance(head_rules, dict):
        for key, base_val in base_rules.items():
            if key not in head_rules:
                errors.append(f"anti-weaken: counting_rules.{key} removed")
            elif head_rules[key] != base_val and key not in allowed_keys:
                errors.append(f"anti-weaken: counting_rules.{key} changed")

    base_gen = (base.get("generated_files") or {}).get("policy")
    head_gen = (head.get("generated_files") or {}).get("policy")
    if base_gen == "counted" and head_gen != "counted":
        errors.append("anti-weaken: generated_files.policy no longer 'counted'")

    base_ext = (base.get("extracted_packages") or {}).get("policy")
    head_ext = (head.get("extracted_packages") or {}).get("policy")
    if base_ext and head_ext != base_ext:
        # Softening declare_or_count is a weaken; identical policy required.
        errors.append(
            f"anti-weaken: extracted_packages.policy changed {base_ext!r} -> {head_ext!r}"
        )

    return errors


def emit(
    measured: dict[str, int],
    budget: dict[str, Any],
    errors: list[str],
    as_json: bool,
) -> None:
    metrics = budget["metrics"]
    if as_json:
        payload = {
            "measured": measured,
            "phase": budget.get("phase"),
            "ok": not errors,
            "errors": errors,
            "limits": {
                mid: {
                    "current_ratchet": metrics[mid]["current_ratchet"],
                    "release_target": metrics[mid]["release_target"],
                    "hard_ceiling": metrics[mid]["hard_ceiling"],
                    "baseline": metrics[mid]["baseline"],
                }
                for mid in METRIC_IDS
            },
        }
        print(json.dumps(payload, indent=2, sort_keys=True))
        return

    print("LOC budget measurement:")
    for mid in METRIC_IDS:
        entry = metrics[mid]
        value = measured[mid]
        print(
            f"  {mid}: {value} "
            f"(ratchet={entry['current_ratchet']} "
            f"target={entry['release_target']} "
            f"ceiling={entry['hard_ceiling']} "
            f"baseline={entry['baseline']})"
        )
    if errors:
        print("LOC budget FAILED:", file=sys.stderr)
        for err in errors:
            print(f"  error: {err}", file=sys.stderr)
    else:
        print("LOC budget OK.")


if __name__ == "__main__":
    sys.exit(main())
