#!/usr/bin/env python3
"""Validate marketplace and plugin catalog consistency."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
MARKETPLACE_PATH = REPO_ROOT / ".claude-plugin" / "marketplace.json"
PLUGINS_DIR = REPO_ROOT / "plugins"

REQUIRED_MANIFEST_FIELDS = ("name", "version", "description", "author", "license")
INSTALLATION_SCOPE_PHRASES = (
    "Install for you",
    "Install for all collaborators on this repository",
    "Install for you, in this repo only",
)

NON_POSIX_DEPS = {
    "codex": ("codex", "codex cli"),
    "curl": ("curl",),
    "ffmpeg": ("ffmpeg",),
    "gemini": ("gemini", "gemini cli"),
    "gh": ("gh", "github cli"),
    "jq": ("jq",),
    "node": ("node", "node.js"),
    "npm": ("npm",),
    "npx": ("npx",),
    "opencode": ("opencode",),
    "python3": ("python3", "python"),
    "qwen": ("qwen", "qwen code"),
}


def main() -> int:
    errors: list[str] = []

    marketplace = load_json(MARKETPLACE_PATH, errors)
    entries = marketplace.get("plugins") if isinstance(marketplace, dict) else None
    if not isinstance(entries, list):
        errors.append(f"{rel(MARKETPLACE_PATH)}: field 'plugins' must be an array")
        entries = []

    marketplace_by_name: dict[str, dict[str, Any]] = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(f"{rel(MARKETPLACE_PATH)}: plugins[{index}] must be an object")
            continue
        name = entry.get("name")
        if not isinstance(name, str) or not name.strip():
            errors.append(f"{rel(MARKETPLACE_PATH)}: plugins[{index}].name is required")
            continue
        if name in marketplace_by_name:
            errors.append(f"{rel(MARKETPLACE_PATH)}: duplicate plugin entry {name!r}")
        marketplace_by_name[name] = entry

    manifest_by_name: dict[str, Path] = {}
    for plugin_dir in sorted(path for path in PLUGINS_DIR.iterdir() if path.is_dir()):
        manifest_path = plugin_dir / ".claude-plugin" / "plugin.json"
        if not manifest_path.is_file():
            continue
        manifest = load_json(manifest_path, errors)
        if not isinstance(manifest, dict):
            continue

        plugin_name = manifest.get("name")
        if not isinstance(plugin_name, str) or not plugin_name.strip():
            errors.append(f"{rel(manifest_path)}: field 'name' must be a non-empty string")
            continue
        plugin_name = plugin_name.strip()
        manifest_by_name[plugin_name] = manifest_path

        if plugin_dir.name != plugin_name:
            errors.append(
                f"{rel(manifest_path)}: manifest name {plugin_name!r} must match directory {plugin_dir.name!r}"
            )

        for field in REQUIRED_MANIFEST_FIELDS:
            if field not in manifest:
                errors.append(f"{rel(manifest_path)}: missing required field {field!r}")
            elif field == "author":
                author = manifest[field]
                if not (
                    isinstance(author, dict)
                    and isinstance(author.get("name"), str)
                    and author["name"].strip()
                ):
                    errors.append(f"{rel(manifest_path)}: author.name must be a non-empty string")
            elif not isinstance(manifest[field], str) or not manifest[field].strip():
                errors.append(f"{rel(manifest_path)}: field {field!r} must be a non-empty string")

        marketplace_entry = marketplace_by_name.get(plugin_name)
        if marketplace_entry is None:
            errors.append(f"{plugin_dir.name}: missing entry in {rel(MARKETPLACE_PATH)}")
        else:
            version = manifest.get("version")
            marketplace_version = marketplace_entry.get("version")
            if version != marketplace_version:
                errors.append(
                    f"{plugin_name}: version mismatch: {rel(manifest_path)}={version!r}, "
                    f"{rel(MARKETPLACE_PATH)}={marketplace_version!r}"
                )
            source = marketplace_entry.get("source")
            expected_source = f"./plugins/{plugin_name}"
            if source != expected_source:
                errors.append(
                    f"{plugin_name}: marketplace source must be {expected_source!r}, got {source!r}"
                )

        readme_path = plugin_dir / "README.md"
        if not readme_path.is_file():
            errors.append(f"{plugin_dir.name}: missing README.md")
        else:
            check_installation_section(plugin_name, readme_path, errors)
            check_documented_dependencies(plugin_name, plugin_dir, readme_path, errors)

    for name in sorted(marketplace_by_name):
        if name not in manifest_by_name:
            errors.append(f"{rel(MARKETPLACE_PATH)}: entry {name!r} has no plugin manifest")

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"Checked {len(manifest_by_name)} plugin manifests against {rel(MARKETPLACE_PATH)}.")
    return 0


def load_json(path: Path, errors: list[str]) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        errors.append(f"{rel(path)}: missing file")
    except json.JSONDecodeError as exc:
        errors.append(f"{rel(path)}: invalid JSON: {exc}")
    return None


def check_installation_section(plugin_name: str, readme_path: Path, errors: list[str]) -> None:
    text = readme_path.read_text(encoding="utf-8")
    match = re.search(r"^## Installation\s*$", text, flags=re.MULTILINE)
    if match is None:
        errors.append(f"{rel(readme_path)}: missing ## Installation section")
        return

    next_header = re.search(r"^##\s+", text[match.end() :], flags=re.MULTILINE)
    section = text[match.end() : match.end() + next_header.start()] if next_header else text[match.end() :]
    for phrase in INSTALLATION_SCOPE_PHRASES:
        if phrase not in section:
            errors.append(f"{rel(readme_path)}: Installation section missing {phrase!r}")


def check_documented_dependencies(
    plugin_name: str,
    plugin_dir: Path,
    readme_path: Path,
    errors: list[str],
) -> None:
    dependency_sources: list[Path] = []
    for subdir in ("scripts", "hooks"):
        path = plugin_dir / subdir
        if path.is_dir():
            dependency_sources.extend(
                child
                for child in path.rglob("*")
                if child.is_file() and child.suffix in {".sh", ".js", ".json"}
            )

    if not dependency_sources:
        return

    haystack = "\n".join(
        path.read_text(encoding="utf-8", errors="ignore") for path in dependency_sources
    ).lower()
    readme = readme_path.read_text(encoding="utf-8").lower()

    for dep, aliases in sorted(NON_POSIX_DEPS.items()):
        if not re.search(rf"(?<![a-z0-9_-]){re.escape(dep)}(?![a-z0-9_-])", haystack):
            continue
        if not any(alias in readme for alias in aliases):
            errors.append(
                f"{plugin_name}: dependency {dep!r} is referenced by scripts/hooks but "
                f"not documented in {rel(readme_path)}"
            )


def rel(path: Path) -> str:
    try:
        return path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


if __name__ == "__main__":
    raise SystemExit(main())
