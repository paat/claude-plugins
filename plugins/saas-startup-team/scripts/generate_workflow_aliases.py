#!/usr/bin/env python3
"""Generate thin command + Codex discovery aliases from integrity/entrypoints.json.

Thin aliases are name-resolution surfaces only. They must not carry workflow
policy, safety policy, model selection, or host-translation prose.

Every retained commands/*.md is generated (#391). Codex workflow skills remain
generated discovery aliases (#383).

Modes:
  default  — write planned alias files
  --check  — exit 1 if any generated file would differ (CI dirty-diff gate)
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

SCRIPT_PATH = Path(__file__).resolve()
PLUGIN_ROOT = SCRIPT_PATH.parents[1]
DEFAULT_MANIFEST = PLUGIN_ROOT / "integrity" / "entrypoints.json"

# Stable marker required by loc-budget hand-maintained exclusion and CI.
GENERATED_MARKER = "GENERATED-ALIAS: do not edit"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--plugin-root",
        type=Path,
        default=PLUGIN_ROOT,
        help="Plugin root (default: this plugin)",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=None,
        help="Path to entrypoints.json (default: <plugin-root>/integrity/entrypoints.json)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Fail if generated aliases differ from files on disk",
    )
    args = parser.parse_args(argv)

    plugin_root = args.plugin_root.resolve()
    manifest_path = (args.manifest or (plugin_root / "integrity" / "entrypoints.json")).resolve()

    try:
        manifest = load_manifest(manifest_path)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"error: cannot load manifest {manifest_path}: {exc}", file=sys.stderr)
        return 2

    try:
        planned = plan_aliases(plugin_root, manifest)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    dirty: list[str] = []
    written = 0
    for path, content in sorted(planned.items(), key=lambda item: str(item[0])):
        rel = path.relative_to(plugin_root).as_posix()
        if path.is_file():
            existing = path.read_text(encoding="utf-8")
            if existing == content:
                continue
            dirty.append(rel)
        else:
            dirty.append(rel)
        if not args.check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
            written += 1

    # Orphan generated Codex alias dirs no longer in the manifest.
    expected_dirs = {p.parent for p in planned if p.name == "SKILL.md"}
    skills_dir = plugin_root / "skills"
    if skills_dir.is_dir():
        for skill_md in sorted(skills_dir.glob("saas-startup-team-*-workflow/SKILL.md")):
            if skill_md.parent in expected_dirs:
                continue
            body = skill_md.read_text(encoding="utf-8") if skill_md.is_file() else ""
            if GENERATED_MARKER in body:
                rel = skill_md.relative_to(plugin_root).as_posix()
                dirty.append(f"{rel} (orphan generated alias)")
                if not args.check:
                    skill_md.unlink()
                    try:
                        skill_md.parent.rmdir()
                    except OSError:
                        pass

    # Orphan generated commands/*.md no longer in the manifest.
    expected_commands = {
        p for p in planned if p.parts and p.parts[0] == "commands" or p.parent.name == "commands"
    }
    # planned keys are absolute paths
    expected_command_paths = {p for p in planned if p.parent.name == "commands"}
    commands_dir = plugin_root / "commands"
    if commands_dir.is_dir():
        for cmd in sorted(commands_dir.glob("*.md")):
            if cmd in expected_command_paths:
                continue
            body = cmd.read_text(encoding="utf-8") if cmd.is_file() else ""
            if GENERATED_MARKER in body:
                rel = cmd.relative_to(plugin_root).as_posix()
                dirty.append(f"{rel} (orphan generated command alias)")
                if not args.check:
                    cmd.unlink()

    if args.check and dirty:
        print("Workflow aliases are out of date:", file=sys.stderr)
        for rel in dirty:
            print(f"  {rel}", file=sys.stderr)
        print(
            "Run: python3 plugins/saas-startup-team/scripts/generate_workflow_aliases.py",
            file=sys.stderr,
        )
        return 1

    action = "Checked" if args.check else "Wrote"
    print(f"{action} {len(planned)} workflow aliases ({written} updated).")
    return 0


def load_manifest(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("manifest root must be an object")
    if payload.get("version") != 1:
        raise ValueError("manifest.version must be 1")
    entries = payload.get("entrypoints")
    if not isinstance(entries, list) or not entries:
        raise ValueError("manifest.entrypoints must be a non-empty array")
    return payload


def plan_aliases(plugin_root: Path, manifest: dict[str, Any]) -> dict[Path, str]:
    planned: dict[Path, str] = {}
    seen_skills: set[str] = set()
    seen_names: set[str] = set()

    for raw in manifest["entrypoints"]:
        if not isinstance(raw, dict):
            raise ValueError("each entrypoint must be an object")
        name = require_str(raw, "name")
        command_file = require_str(raw, "command_file")
        codex_skill = require_str(raw, "codex_skill")
        canonical = require_str(raw, "canonical")
        description = require_str(raw, "description")
        aliases = raw.get("aliases")
        generate = raw.get("generate_alias")
        generate_command = raw.get("generate_command_alias", True)
        if not isinstance(generate, bool):
            raise ValueError(f"{name}: generate_alias must be a boolean")
        if not isinstance(generate_command, bool):
            raise ValueError(f"{name}: generate_command_alias must be a boolean")
        if not isinstance(aliases, list) or not aliases or not all(
            isinstance(a, str) and a.startswith("/") for a in aliases
        ):
            raise ValueError(f"{name}: aliases must be a non-empty list of /slash names")
        if name in seen_names:
            raise ValueError(f"duplicate entrypoint name: {name}")
        seen_names.add(name)
        if codex_skill in seen_skills:
            raise ValueError(f"duplicate codex_skill: {codex_skill}")
        seen_skills.add(codex_skill)

        canonical_path = plugin_root / canonical
        if not canonical_path.is_file():
            raise ValueError(f"{name}: missing canonical skill {canonical}")

        primary = aliases[-1] if len(aliases) > 1 else aliases[0]

        if generate_command:
            cmd_path = plugin_root / command_file
            planned[cmd_path] = render_command_alias(
                name=name,
                description=description,
                primary=primary,
                canonical=canonical,
                aliases=list(aliases),
            )

        if not generate:
            continue

        if not (
            codex_skill.startswith("saas-startup-team-")
            and codex_skill.endswith("-workflow")
        ):
            raise ValueError(
                f"{name}: generate_alias requires codex_skill "
                f"saas-startup-team-*-workflow, got {codex_skill!r}"
            )

        skill_path = plugin_root / "skills" / codex_skill / "SKILL.md"
        planned[skill_path] = render_codex_alias(
            skill_name=codex_skill,
            aliases=list(aliases),
            canonical=canonical,
        )

    return planned


def render_command_alias(
    *,
    name: str,
    description: str,
    primary: str,
    canonical: str,
    aliases: list[str],
) -> str:
    """Claude slash-command thin alias → capability skill."""
    alias_list = ", ".join(f"`{a}`" for a in aliases)
    return (
        f"---\n"
        f"name: {name}\n"
        f'description: "{_escape_desc(description)}"\n'
        f"user_invocable: true\n"
        f"transitional: true\n"
        f"---\n"
        f"<!-- {GENERATED_MARKER}; regenerate via scripts/generate_workflow_aliases.py "
        f"from integrity/entrypoints.json -->\n"
        f"\n"
        f"# Alias: {primary}\n"
        f"\n"
        f"Generated alias for {alias_list}. No workflow policy here.\n"
        f"Load and execute `{canonical}`. Treat trailing user text as `$ARGUMENTS`.\n"
    )


def render_codex_alias(*, skill_name: str, aliases: list[str], canonical: str) -> str:
    """Codex discovery alias → capability skill (not commands/)."""
    primary = aliases[-1] if len(aliases) > 1 else aliases[0]
    secondary = aliases[0] if len(aliases) > 1 and aliases[0] != primary else None
    if secondary:
        description = f"Run {primary} workflow from saas-startup-team; alias {secondary}."
    else:
        description = f"Run {primary} workflow from saas-startup-team."

    # Relative path from skills/<codex>/SKILL.md -> skills/...
    # skills/saas-startup-team-X-workflow/SKILL.md -> ../../canonical
    source_rel = f"../../{canonical}"
    alias_list = ", ".join(f"`{a}`" for a in aliases)

    return (
        f"---\n"
        f"name: {skill_name}\n"
        f'description: "{_escape_desc(description)}"\n'
        f"---\n"
        f"<!-- {GENERATED_MARKER}; regenerate via scripts/generate_workflow_aliases.py "
        f"from integrity/entrypoints.json -->\n"
        f"\n"
        f"# Alias: {primary}\n"
        f"\n"
        f"Discovery alias for {alias_list}.\n"
        f"Load and execute `{source_rel}`. Treat trailing user text as `$ARGUMENTS`.\n"
    )


def _escape_desc(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def require_str(obj: dict[str, Any], key: str) -> str:
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"entrypoint field {key!r} must be a non-empty string")
    return value.strip()


if __name__ == "__main__":
    sys.exit(main())
