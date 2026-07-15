#!/usr/bin/env python3
"""Sync Codex plugin metadata from the Claude marketplace in this repo."""

from __future__ import annotations

import argparse
import json
import re
import sys
import textwrap
import unicodedata
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
    "saas-startup-team": (
        "Codex-native SaaS startup orchestration using file-based founder handoffs, business "
        "research, implementation, growth, legal, UX, and review loops for Estonian SaaS projects."
    ),
    "silent-failure-scanner": (
        "Deterministic diff-time detector for swallowed errors and ghost transactions, with a "
        "global PreToolUse commit gate that hands findings to the current Codex session to review."
    ),
}


def main() -> int:
    args = parse_args()

    claude_marketplace = load_json(CLAUDE_MARKETPLACE_PATH)
    marketplace_name = read_required_string(claude_marketplace, "name", CLAUDE_MARKETPLACE_PATH)
    entries = read_required_list(claude_marketplace, "plugins", CLAUDE_MARKETPLACE_PATH)

    planned_files: dict[Path, str] = {}
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
        planned_files[plugin_dir / ".codex-plugin" / "plugin.json"] = render_json(codex_manifest)
        planned_files.update(build_command_skill_files(plugin_dir, plugin_name))
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
    planned_files[CODEX_MARKETPLACE_PATH] = render_json(codex_marketplace)

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
    has_existing_skill = skills_dir.is_dir() and any(path.is_file() for path in skills_dir.glob("*/SKILL.md"))
    return has_existing_skill or has_command_files(plugin_dir)


def has_command_files(plugin_dir: Path) -> bool:
    commands_dir = plugin_dir / "commands"
    return commands_dir.is_dir() and any(commands_dir.glob("*.md"))


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


def build_command_skill_files(plugin_dir: Path, plugin_name: str) -> dict[Path, str]:
    commands_dir = plugin_dir / "commands"
    if not commands_dir.is_dir():
        return {}

    planned: dict[Path, str] = {}
    for command_path in sorted(commands_dir.glob("*.md")):
        metadata = read_command_metadata(command_path)
        command_name = command_metadata_name(command_path, metadata)
        skill_name = command_skill_name(plugin_name, command_name, metadata)
        skill_path = plugin_dir / "skills" / skill_name / "SKILL.md"
        planned[skill_path] = render_command_skill(
            plugin_name=plugin_name,
            command_name=command_name,
            command_path=command_path,
            metadata=metadata,
            skill_name=skill_name,
        )
    return planned


def read_command_metadata(command_path: Path) -> dict[str, str]:
    contents = command_path.read_text(encoding="utf-8")
    if not contents.startswith("---\n"):
        return {}
    frontmatter_end = contents.find("\n---", 4)
    if frontmatter_end == -1:
        return {}

    metadata: dict[str, str] = {}
    for raw_line in contents[4:frontmatter_end].splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip().strip("\"'")
        if key and value:
            metadata[key] = value
    return metadata


def command_metadata_name(command_path: Path, metadata: dict[str, str]) -> str:
    raw_name = metadata.get("name") or command_path.stem
    return slugify(raw_name) or command_path.stem


def command_skill_name(
    plugin_name: str, command_name: str, metadata: dict[str, str]
) -> str:
    override = metadata.get("codex-skill-name")
    if override:
        normalized = slugify(override)
        if not normalized:
            raise SystemExit(f"{plugin_name}:{command_name}: invalid codex-skill-name")
        return normalized
    return slugify(f"{plugin_name}-{command_name}-workflow")


def render_command_skill(
    *,
    plugin_name: str,
    command_name: str,
    command_path: Path,
    metadata: dict[str, str],
    skill_name: str,
) -> str:
    aliases = command_aliases(plugin_name, command_name, command_path)
    source_path = f"../../commands/{command_path.name}"
    source_description = sanitize_command_description(
        metadata.get("description", "Run this plugin workflow."),
        plugin_name=plugin_name,
    )
    description = command_skill_description(plugin_name, aliases)
    plugin_notes = command_plugin_notes(plugin_name, command_name)
    command_notes = command_specific_notes(plugin_name, command_name)
    read_only = metadata.get("codex-sandbox") == "read-only"
    if read_only:
        execution_instruction = (
            "Execute the workflow only in a Codex `read-only` sandbox. Do not use a "
            "write-capable current session; if the required browser/integration is unavailable "
            "inside the read-only boundary, stop and report that limitation."
        )
        dispatch_replacement = (
            "Claude `Task` / `Agent` / `TeamCreate` dispatch -> use Codex-native multi-agent "
            "tooling or `codex exec` only with a `read-only` sandbox. A current-session role is "
            "allowed only when that session is already read-only."
        )
    elif plugin_name == "saas-startup-team" and command_name == "maintain-loop":
        execution_instruction = (
            "Execute only as a thin coordinator using fresh Codex subagents. Never run the "
            "delegated maintain pass in the current session."
        )
        dispatch_replacement = (
            "Claude `Task` / `Agent` / `TeamCreate` dispatch -> spawn exactly one fresh "
            "Codex subagent, wait for it to terminate, and fail closed if isolated dispatch "
            "is unavailable; never substitute current-session execution"
        )
    elif plugin_name == "saas-startup-team":
        execution_instruction = (
            "Execute the workflow through Codex-native mechanisms: Codex skills, direct task "
            "sequencing in the current session, the Codex CLI, or Codex-supported multi-agent "
            "tooling when available."
        )
        dispatch_replacement = (
            "Claude `Task` / `Agent` / `TeamCreate` dispatch -> use Codex-native multi-agent "
            "tooling when available, the bundled `scripts/codex-run-role.sh` with an explicit "
            "role/profile and task file for a separate process, or a fresh role phase in the "
            "current Codex session."
        )
    else:
        execution_instruction = (
            "Execute the workflow through Codex-native mechanisms: Codex skills, direct task "
            "sequencing in the current session, the Codex CLI, or Codex-supported multi-agent "
            "tooling when available."
        )
        dispatch_replacement = (
            "Claude `Task` / `Agent` / `TeamCreate` dispatch -> use Codex-native multi-agent "
            "tooling if available, `codex exec` when a separate Codex process is useful, or a "
            "fresh role phase in the current Codex session."
        )

    sections = [
        textwrap.dedent(
            f"""\
            ---
            name: {skill_name}
            description: {json.dumps(description)}
            ---

            # {aliases[0]} Codex Workflow

            This generated skill is the Codex-native plugin surface for `{aliases[0]}`.
            Also use it when the user invokes {format_alias_list(aliases[1:])} or asks for the same workflow by name.

            Source command: `{source_path}`

            ## Run Protocol

            1. Treat the user text after the command name as `$ARGUMENTS`.
            2. Read the source command file before executing. It is the workflow checklist after applying the Codex replacements in this skill.
            3. {execution_instruction}
            4. Do not create user-local `~/.codex/prompts` wrappers. This skill is the reusable plugin-bundled workflow surface.
            5. When the source command says `Skill('plugin:skill')`, load the named plugin skill normally.
            6. When the source command references `${{CLAUDE_PLUGIN_ROOT}}/path`, resolve it to this installed plugin root and use `path` under that root. Do not require the environment variable to exist.
            7. When the source command contains a Claude-only primitive, use the Codex replacement:
               - `AskUserQuestion` -> ask the user directly; in non-interactive runs, stop and report the exact required input.
               - Claude slash-command execution -> invoke this skill or the corresponding plugin skill.
               - {dispatch_replacement}
               - `ScheduleWakeup` -> use Codex session continuation or an explicit user-visible status checkpoint; do not depend on a Claude lifecycle hook.
            """
        ).rstrip(),
        plugin_notes,
        command_notes,
        textwrap.dedent(
            f"""\
            ## Command Metadata

            - Plugin: `{plugin_name}`
            - Command aliases: {format_alias_list(aliases)}
            - Source description: {source_description}
            """
        ).rstrip(),
    ]
    return "\n\n".join(section for section in sections if section.strip()) + "\n"


def command_aliases(plugin_name: str, command_name: str, command_path: Path) -> list[str]:
    aliases = [f"/{plugin_name}:{command_name}"]
    heading_alias = read_heading_alias(command_path)
    if heading_alias is not None:
        aliases.append(heading_alias)
    else:
        aliases.append(f"/{command_name}")
    return dedupe(aliases)


def command_skill_description(plugin_name: str, aliases: list[str]) -> str:
    primary_alias = aliases[-1]
    if len(aliases) == 1:
        return sanitize_description(f"Run {primary_alias} workflow from {plugin_name}.")
    return sanitize_description(
        f"Run {primary_alias} workflow from {plugin_name}; alias {aliases[0]}."
    )


def read_heading_alias(command_path: Path) -> str | None:
    contents = command_path.read_text(encoding="utf-8")
    match = re.search(r"^#\s+(/[A-Za-z0-9:_-]+)\b", contents, flags=re.MULTILINE)
    if match is None:
        return None
    return match.group(1)


def dedupe(values: list[str]) -> list[str]:
    output: list[str] = []
    seen: set[str] = set()
    for value in values:
        if value in seen:
            continue
        output.append(value)
        seen.add(value)
    return output


def format_alias_list(aliases: list[str]) -> str:
    if not aliases:
        return "that command"
    return ", ".join(f"`{alias}`" for alias in aliases)


def command_plugin_notes(plugin_name: str, command_name: str) -> str:
    if plugin_name != "saas-startup-team" or command_name == "maintain-loop":
        return ""
    return textwrap.dedent(
        """\
        ## SaaS Startup Codex Rules

        For `saas-startup-team` workflows in Codex:

        - Use Codex as the primary and only coding agent.
        - Do not invoke `claude`, `claude-code`, Claude Code, TeamCreate, or Claude subagent workflows.
        - Do not route implementation to `tech-founder-claude` or `tech-founder-claude-maintain`; use the `tech-founder` skill, direct Codex implementation, or the bundled `scripts/codex-run-role.sh` for a separate process.
        - Every separate Codex role launch uses `scripts/codex-run-role.sh` with an explicit semantic profile. The adapter stays model-neutral; the launcher owns model and effort pinning.
        - Treat business-founder, tech-founder, growth-hacker, lawyer, UX tester, and review loops as Codex role phases backed by `.startup/` files.
        - Keep the file-based handoff protocol intact: every role phase reads the relevant handoff/state files and writes its expected deliverable before the next phase starts.
        - If a multi-agent dispatch fails or returns an unknown/missing thread, do not wait or poll that handle. Check its expected artifact once and verify it belongs to the current handoff/run and current HEAD when repository-bound; a stale or unproven artifact counts as absent. Continue without relaunching only when that artifact is complete; otherwise establish that the original dispatch is terminal, then run the role exactly once in the current session or through `scripts/codex-run-role.sh`. Never let an original and fallback worker write the same artifact concurrently.
        - Resolve commands and handoff paths from the current Git worktree. Never emit a hardcoded checkout root such as `/workspace`; use repository-relative paths or `git rev-parse --show-toplevel`.
        """
    ).rstrip()


def command_specific_notes(plugin_name: str, command_name: str) -> str:
    if plugin_name != "saas-startup-team" or command_name != "maintain":
        return ""
    command_alias = f"/{command_name}"
    return textwrap.dedent(
        f"""\
        ## Codex Maintain Hard Gates

        During each Codex `{command_alias}` issue-delivery cycle, enforce these merge predicates directly:

        - Before implementation, identify the root cause / recurrence class; fix the class, not only the observed instance.
        - For bug, monitor, customer, accounting, replay, and incident-class issues, add a locking regression test, durable contract test, monitor assertion, or equivalent guard that would fail on the old behavior.
        - The PR body must state the red-before/green-after proof and why the same issue should not recur. If a durable guard is genuinely impossible, split or file a follow-up, or mark the issue human/blocked with the reason.
        - Before starting `tribunal-review:closing-tribunal-loop`, run the Codex business-founder QA phase with Playwright on affected browser-visible flows and record the checked flows/evidence in the PR body. If no browser-visible surface changed, record `Business-founder Playwright QA: not applicable - <reason>` before tribunal.
        - Browser transport loss is `tool-unavailable`, never a product verdict. Follow `skills/ux-tester/references/design-review-leg.md`: retry once in a fresh installed browser session, discard partial evidence, and on a second failure keep the PR resumable with issue-local `browser-tool-unavailable`; never waive QA.
        - For every code PR, `tribunal-review:closing-tribunal-loop` is the main merge prerequisite: it runs `tribunal-review:tribunal-loop`, triages findings, applies fixes or follow-ups, and revalidates until the arbiter clears the gate.
        - Any code diff, PR body edit that changes validation facts, rebase/update-from-main, or HEAD change invalidates the prior tribunal result and reopens the closing loop.
        - Merge is forbidden unless the closing loop's latest arbiter verdict covers the current PR HEAD and latest diff, has zero critical/high findings, and recurrence proof is present when required. Medium/low findings may be triaged per the tribunal plugin.
        """
    ).rstrip()


def sanitize_description(value: str) -> str:
    replacements = {
        "—": "-",
        "–": "-",
        "→": "->",
        "≤": "<=",
        "≥": ">=",
        "×": "x",
        "“": '"',
        "”": '"',
        "’": "'",
    }
    for old, new in replacements.items():
        value = value.replace(old, new)
    value = unicodedata.normalize("NFKD", value)
    value = value.encode("ascii", "ignore").decode("ascii")
    value = re.sub(r"\s+", " ", value).strip()
    return value


def sanitize_command_description(value: str, *, plugin_name: str) -> str:
    value = value.replace("Gemini + Claude", "Gemini + the current Codex agent")
    if plugin_name == "saas-startup-team":
        value = value.replace(
            "spawns business founder and tech founder agent team",
            "starts business-founder and tech-founder role phases",
        )
        value = value.replace("spawn agent team", "start founder role phases")
        value = value.replace("Spawn ", "Run ")
        value = value.replace("spawns ", "runs ")
    return sanitize_description(value)


def slugify(value: str) -> str:
    value = sanitize_description(value).lower()
    value = re.sub(r"[^a-z0-9]+", "-", value).strip("-")
    return value


def render_json(payload: dict[str, Any]) -> str:
    return json.dumps(payload, indent=2, ensure_ascii=True) + "\n"


def write_or_check(planned_files: dict[Path, str], *, check: bool) -> bool:
    changed = False
    for path, payload in sorted(planned_files.items(), key=lambda item: item[0].as_posix()):
        current = path.read_text(encoding="utf-8") if path.is_file() else None
        if current == payload:
            continue

        changed = True
        if check:
            print(f"out of date: {path.relative_to(REPO_ROOT)}")
            continue

        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(payload, encoding="utf-8")

    return changed


if __name__ == "__main__":
    raise SystemExit(main())
