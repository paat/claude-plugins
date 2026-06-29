#!/usr/bin/env python3
"""Sync Codex plugin metadata from the Claude marketplace in this repo."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
CLAUDE_MARKETPLACE_PATH = REPO_ROOT / ".claude-plugin" / "marketplace.json"
CODEX_MARKETPLACE_PATH = REPO_ROOT / ".agents" / "plugins" / "marketplace.json"

DEFAULT_INSTALL_POLICY = "AVAILABLE"
DEFAULT_AUTH_POLICY = "ON_INSTALL"
DEFAULT_MARKETPLACE_DISPLAY_NAME = "Paat Plugins"

CODEX_DESCRIPTION_OVERRIDES = {
    "agent-sync": (
        "Mirror AGENTS.md to CLAUDE.md for Codex-first projects. In Codex, AGENTS.md is the "
        "source of truth; Claude Code keeps its existing Claude-to-AGENTS generation behavior."
    ),
}


def main() -> int:
    args = parse_args()

    claude_marketplace = load_json(CLAUDE_MARKETPLACE_PATH)
    marketplace_name = read_required_string(claude_marketplace, "name", CLAUDE_MARKETPLACE_PATH)
    entries = read_required_list(claude_marketplace, "plugins", CLAUDE_MARKETPLACE_PATH)

    planned_files: dict[Path, dict[str, Any]] = {}
    codex_entries: list[dict[str, Any]] = []
    errors: list[str] = []

    for raw_entry in entries:
        if not isinstance(raw_entry, dict):
            errors.append(f"{CLAUDE_MARKETPLACE_PATH}: plugins[] entries must be objects")
            continue

        plugin_name = read_required_string(raw_entry, "name", CLAUDE_MARKETPLACE_PATH)
        plugin_dir = REPO_ROOT / "plugins" / plugin_name
        claude_manifest_path = plugin_dir / ".claude-plugin" / "plugin.json"
        if not claude_manifest_path.is_file():
            errors.append(f"{plugin_name}: missing {claude_manifest_path.relative_to(REPO_ROOT)}")
            continue

        claude_manifest = load_json(claude_manifest_path)
        manifest_name = read_required_string(claude_manifest, "name", claude_manifest_path)
        if manifest_name != plugin_name:
            errors.append(
                f"{plugin_name}: marketplace name does not match Claude manifest name {manifest_name!r}"
            )
            continue
        if plugin_dir.name != plugin_name:
            errors.append(f"{plugin_name}: plugin directory name must match plugin name")
            continue

        codex_manifest = build_codex_manifest(plugin_dir, claude_manifest, raw_entry)
        planned_files[plugin_dir / ".codex-plugin" / "plugin.json"] = codex_manifest
        codex_entries.append(build_marketplace_entry(plugin_name, raw_entry))

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    codex_marketplace = {
        "name": marketplace_name,
        "interface": {
            "displayName": DEFAULT_MARKETPLACE_DISPLAY_NAME,
        },
        "plugins": codex_entries,
    }
    planned_files[CODEX_MARKETPLACE_PATH] = codex_marketplace

    changed = write_or_check(planned_files, check=args.check)
    if args.check and changed:
        print("Codex marketplace files are out of date. Run scripts/sync-codex-marketplace.py.")
        return 1

    action = "Checked" if args.check else "Synced"
    print(f"{action} {len(codex_entries)} Codex plugin entries.")
    print(f"Marketplace: {CODEX_MARKETPLACE_PATH.relative_to(REPO_ROOT)}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Codex plugin manifests and marketplace.json from Claude metadata."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit non-zero if generated Codex files differ from the current files.",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"missing required file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(payload, dict):
        raise SystemExit(f"{path} must contain a JSON object")
    return payload


def read_required_string(payload: dict[str, Any], key: str, path: Path) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"{path}: field {key!r} must be a non-empty string")
    return value.strip()


def read_required_list(payload: dict[str, Any], key: str, path: Path) -> list[Any]:
    value = payload.get(key)
    if not isinstance(value, list):
        raise SystemExit(f"{path}: field {key!r} must be an array")
    return value


def build_codex_manifest(
    plugin_dir: Path,
    claude_manifest: dict[str, Any],
    marketplace_entry: dict[str, Any],
) -> dict[str, Any]:
    plugin_name = read_required_string(claude_manifest, "name", plugin_dir)
    description = CODEX_DESCRIPTION_OVERRIDES.get(plugin_name) or read_optional_string(
        claude_manifest, "description"
    ) or read_optional_string(marketplace_entry, "description")
    if description is None:
        raise SystemExit(f"{plugin_name}: description is required")

    manifest: dict[str, Any] = {
        "name": plugin_name,
        "version": read_required_string(claude_manifest, "version", plugin_dir),
        "description": description,
        "author": build_author(claude_manifest),
        "interface": build_interface(plugin_dir, claude_manifest, marketplace_entry, description),
    }

    for key in ("homepage", "repository", "license", "keywords"):
        value = claude_manifest.get(key, marketplace_entry.get(key))
        if value is not None:
            manifest[key] = value

    homepage = marketplace_entry.get("homepage")
    if homepage is not None and "homepage" not in manifest:
        manifest["homepage"] = homepage

    if has_codex_skills(plugin_dir):
        manifest["skills"] = "./skills/"

    if (plugin_dir / ".mcp.json").is_file():
        manifest["mcpServers"] = "./.mcp.json"

    return manifest


def build_author(claude_manifest: dict[str, Any]) -> dict[str, Any]:
    author = claude_manifest.get("author")
    if not isinstance(author, dict):
        return {"name": "Andre Paat"}

    output: dict[str, Any] = {}
    for key in ("name", "email", "url"):
        value = author.get(key)
        if isinstance(value, str) and value.strip():
            output[key] = value.strip()
    if "name" not in output:
        output["name"] = "Andre Paat"
    return output


def build_interface(
    plugin_dir: Path,
    claude_manifest: dict[str, Any],
    marketplace_entry: dict[str, Any],
    description: str,
) -> dict[str, Any]:
    plugin_name = read_required_string(claude_manifest, "name", plugin_dir)
    display_name = humanize_name(plugin_name)
    author = build_author(claude_manifest)
    category = normalize_category(read_optional_string(marketplace_entry, "category"))

    homepage = read_optional_string(marketplace_entry, "homepage") or read_optional_string(
        claude_manifest, "homepage"
    )
    repository = read_optional_string(claude_manifest, "repository")

    interface: dict[str, Any] = {
        "displayName": display_name,
        "shortDescription": description,
        "longDescription": description,
        "developerName": author["name"],
        "category": category,
        "capabilities": infer_capabilities(plugin_dir),
        "defaultPrompt": default_prompt(plugin_name),
    }

    website_url = homepage or repository
    if isinstance(website_url, str) and website_url.startswith("https://"):
        interface["websiteURL"] = website_url

    return interface


def build_marketplace_entry(plugin_name: str, raw_entry: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": plugin_name,
        "source": {
            "source": "local",
            "path": f"./plugins/{plugin_name}",
        },
        "policy": {
            "installation": DEFAULT_INSTALL_POLICY,
            "authentication": DEFAULT_AUTH_POLICY,
        },
        "category": normalize_category(read_optional_string(raw_entry, "category")),
    }


def has_codex_skills(plugin_dir: Path) -> bool:
    skills_dir = plugin_dir / "skills"
    if not skills_dir.is_dir():
        return False
    return any(path.is_file() for path in skills_dir.glob("*/SKILL.md"))


def infer_capabilities(plugin_dir: Path) -> list[str]:
    capabilities: list[str] = []
    if has_codex_skills(plugin_dir):
        capabilities.append("Skills")
    if (plugin_dir / "hooks" / "hooks.json").is_file():
        capabilities.append("Lifecycle Hooks")
    if (plugin_dir / ".mcp.json").is_file():
        capabilities.append("MCP Servers")
    if (plugin_dir / "scripts").is_dir():
        capabilities.append("Scripts")
    if not capabilities:
        capabilities.append("Reusable Workflows")
    return capabilities


def default_prompt(plugin_name: str) -> str:
    return f"Use the {plugin_name} plugin for this task."


def normalize_category(category: str | None) -> str:
    if not category:
        return "Productivity"
    words = re.split(r"[-_\s]+", category.strip())
    return " ".join(word[:1].upper() + word[1:].lower() for word in words if word)


def humanize_name(plugin_name: str) -> str:
    special = {
        "api": "API",
        "cli": "CLI",
        "codex": "Codex",
        "gh": "GitHub",
        "github": "GitHub",
        "mcp": "MCP",
        "ui": "UI",
        "i18n": "i18n",
        "saas": "SaaS",
    }
    parts = []
    for part in plugin_name.split("-"):
        parts.append(special.get(part, part[:1].upper() + part[1:]))
    return " ".join(parts)


def read_optional_string(payload: dict[str, Any], key: str) -> str | None:
    value = payload.get(key)
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def write_or_check(planned_files: dict[Path, dict[str, Any]], *, check: bool) -> bool:
    changed = False
    for path, payload in sorted(planned_files.items(), key=lambda item: item[0].as_posix()):
        rendered = json.dumps(payload, indent=2, ensure_ascii=True) + "\n"
        current = path.read_text(encoding="utf-8") if path.is_file() else None
        if current == rendered:
            continue

        changed = True
        if check:
            print(f"out of date: {path.relative_to(REPO_ROOT)}")
            continue

        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered, encoding="utf-8")

    return changed


if __name__ == "__main__":
    raise SystemExit(main())
