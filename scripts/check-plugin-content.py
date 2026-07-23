#!/usr/bin/env python3
"""Lightweight structural linting for plugin skills, commands, agents, and hooks."""

from __future__ import annotations

import json
import re
import sys
import unicodedata
from pathlib import Path
from typing import Any

try:
    import yaml
except ModuleNotFoundError as exc:
    raise SystemExit(
        "PyYAML is required; install development dependencies with "
        "python3 -m pip install -r requirements-dev.txt"
    ) from exc


REPO_ROOT = Path(__file__).resolve().parents[1]
PLUGINS_DIR = REPO_ROOT / "plugins"


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []

    for plugin_dir in sorted(path for path in PLUGINS_DIR.iterdir() if path.is_dir()):
        lint_plugin(plugin_dir, errors, warnings)

    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    print("Plugin content lint passed.")
    return 0


# Multi-line normalized block must appear in only one markdown file per plugin.
DUPLICATE_BLOCK_MIN_LINES = 10


def lint_plugin(plugin_dir: Path, errors: list[str], warnings: list[str]) -> None:
    plugin_name = plugin_dir.name
    lint_prompt_content(plugin_dir, errors)
    lint_skills(plugin_dir, errors)
    lint_commands(plugin_dir, errors)
    lint_agents(plugin_dir, errors)
    lint_hooks(plugin_dir, errors)
    lint_markdown_duplication(plugin_dir, errors)
    lint_prompt_budgets(plugin_dir, errors)
    warn_duplicate_skill_bodies(plugin_name, plugin_dir, warnings)



def lint_prompt_content(plugin_dir: Path, errors: list[str]) -> None:
    """Keep terminal sentinels out of prompt text that may be copied to logs."""
    paths: set[Path] = set()
    for directory in ("commands", "agents", "skills", "references"):
        root = plugin_dir / directory
        if root.is_dir():
            paths.update(root.rglob("*.md"))

    sentinel = re.compile(r"^PASS-BLOCKED(?:[ \t].*)?$", re.MULTILINE)
    for path in sorted(paths):
        body = path.read_text(encoding="utf-8")
        if sentinel.search(body):
            errors.append(
                f"{rel(path)}: standalone PASS-BLOCKED line can be copied into dispatch logs; "
                "keep the runtime emission instruction inline"
            )


def lint_skills(plugin_dir: Path, errors: list[str]) -> None:
    skills_dir = plugin_dir / "skills"
    if not skills_dir.is_dir():
        return
    for skill_path in sorted(skills_dir.glob("*/SKILL.md")):
        metadata, body = parse_frontmatter(skill_path, errors)
        name = metadata.get("name")
        description = metadata.get("description")
        if not isinstance(name, str) or not name.strip():
            errors.append(f"{rel(skill_path)}: skill frontmatter missing non-empty name")
        elif name != skill_path.parent.name:
            errors.append(
                f"{rel(skill_path)}: skill name {name!r} must match folder {skill_path.parent.name!r}"
            )
        if not isinstance(description, str) or not description.strip():
            errors.append(f"{rel(skill_path)}: skill frontmatter missing non-empty description")
        lint_reference_links(skill_path, body, errors)


def lint_reference_links(skill_path: Path, body: str, errors: list[str]) -> None:
    patterns = (
        r"`(references/[^`]+)`",
        r"\((references/[^)]+)\)",
        r"['\"](references/[^'\"]+)['\"]",
    )
    for pattern in patterns:
        for raw_ref in re.findall(pattern, body):
            target = raw_ref.split("#", 1)[0].strip()
            if not target or any(ch in target for ch in "*?"):
                continue
            ref_path = (skill_path.parent / target).resolve()
            try:
                ref_path.relative_to(skill_path.parent.resolve())
            except ValueError:
                errors.append(f"{rel(skill_path)}: reference escapes skill folder: {raw_ref}")
                continue
            if not ref_path.is_file():
                errors.append(f"{rel(skill_path)}: missing referenced file {raw_ref}")


def lint_commands(plugin_dir: Path, errors: list[str]) -> None:
    commands_dir = plugin_dir / "commands"
    if not commands_dir.is_dir():
        return
    for command_path in sorted(commands_dir.glob("*.md")):
        metadata, _body = parse_frontmatter(command_path, errors, require=False)
        raw_name = metadata.get("name")
        command_name = slugify(raw_name if isinstance(raw_name, str) else command_path.stem)
        command_name = command_name or command_path.stem
        raw_skill_name = metadata.get("codex-skill-name")
        skill_name = slugify(raw_skill_name) if isinstance(raw_skill_name, str) else ""
        skill_name = skill_name or slugify(f"{plugin_dir.name}-{command_name}-workflow")
        expected_skill = (
            plugin_dir
            / "skills"
            / skill_name
            / "SKILL.md"
        )
        if not expected_skill.is_file():
            errors.append(
                f"{rel(command_path)}: missing generated Codex workflow skill {rel(expected_skill)}"
            )


def lint_agents(plugin_dir: Path, errors: list[str]) -> None:
    agents_dir = plugin_dir / "agents"
    if not agents_dir.is_dir():
        return
    for agent_path in sorted(agents_dir.glob("*.md")):
        metadata, _body = parse_frontmatter(agent_path, errors)
        name = metadata.get("name")
        description = metadata.get("description")
        if not isinstance(name, str) or not name.strip():
            errors.append(f"{rel(agent_path)}: agent frontmatter missing non-empty name")
        elif name != agent_path.stem:
            errors.append(
                f"{rel(agent_path)}: agent name {name!r} must match filename {agent_path.stem!r}"
            )
        if not isinstance(description, str) or not description.strip():
            errors.append(f"{rel(agent_path)}: agent frontmatter missing non-empty description")


def lint_hooks(plugin_dir: Path, errors: list[str]) -> None:
    hook_path = plugin_dir / "hooks" / "hooks.json"
    if not hook_path.is_file():
        return
    try:
        payload = json.loads(hook_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        errors.append(f"{rel(hook_path)}: invalid JSON: {exc}")
        return
    if not isinstance(payload, dict) or not isinstance(payload.get("hooks"), dict):
        errors.append(f"{rel(hook_path)}: expected object with hooks object")
        return

    for command in hook_commands(payload):
        if "${CLAUDE_PLUGIN_ROOT}/" in command or "$CLAUDE_PLUGIN_ROOT/" in command:
            errors.append(
                f"{rel(hook_path)}: hook command directly depends on CLAUDE_PLUGIN_ROOT; "
                "use a Codex-compatible resolver fallback"
            )
        for target in re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/([A-Za-z0-9_./-]+)", command):
            target_path = plugin_dir / target
            if not target_path.is_file():
                errors.append(
                    f"{rel(hook_path)}: hook command references missing file "
                    f"${{CLAUDE_PLUGIN_ROOT}}/{target}"
                )
        for target in re.findall(r"(?:^|[ ;])p=([A-Za-z0-9_./-]+)", command):
            target_path = plugin_dir / target
            if not target_path.is_file():
                errors.append(f"{rel(hook_path)}: hook resolver target is missing: {target}")
        for target in re.findall(r"(?:^|[ \"'])(\./[A-Za-z0-9_./-]+)", command):
            target_path = plugin_dir / target[2:]
            if not target_path.is_file():
                errors.append(f"{rel(hook_path)}: relative hook target is missing: {target}")


def hook_commands(payload: dict[str, Any]) -> list[str]:
    output: list[str] = []
    hooks = payload.get("hooks")
    if not isinstance(hooks, dict):
        return output
    for entries in hooks.values():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            nested = entry.get("hooks")
            if not isinstance(nested, list):
                continue
            for hook in nested:
                if not isinstance(hook, dict):
                    continue
                command = hook.get("command")
                if isinstance(command, str) and command.strip():
                    output.append(command)
    return output


def plugin_markdown_paths(plugin_dir: Path) -> list[Path]:
    """Prompt-loaded markdown that must not re-paste multi-line guidance clusters.

    Scans agents/, commands/, plugin-level references/, templates/, and each
    skill's SKILL.md only. Nested skill reference docs (often code samples) and
    generated *-workflow skills are excluded so JSON/code examples do not false-positive.
    """
    paths: list[Path] = []
    for directory in ("agents", "commands", "templates", "references"):
        root = plugin_dir / directory
        if root.is_dir():
            paths.extend(root.rglob("*.md"))
    skills_dir = plugin_dir / "skills"
    if skills_dir.is_dir():
        for skill_md in skills_dir.glob("*/SKILL.md"):
            if skill_md.parent.name.endswith("-workflow"):
                continue
            paths.append(skill_md)
    return sorted(paths)


def normalize_markdown_lines(text: str) -> list[str]:
    """Strip frontmatter; collapse whitespace; drop empty lines; lowercase."""
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            text = text[end + 4 :]
    lines: list[str] = []
    for raw in text.splitlines():
        collapsed = re.sub(r"\s+", " ", raw.strip())
        if collapsed:
            lines.append(collapsed.lower())
    return lines


def find_duplicate_blocks(
    plugin_dir: Path,
    *,
    min_lines: int = DUPLICATE_BLOCK_MIN_LINES,
) -> list[tuple[tuple[str, ...], list[Path]]]:
    """Return normalized blocks of min_lines that appear in 2+ files."""
    index: dict[tuple[str, ...], set[Path]] = {}
    for path in plugin_markdown_paths(plugin_dir):
        lines = normalize_markdown_lines(path.read_text(encoding="utf-8", errors="replace"))
        if len(lines) < min_lines:
            continue
        seen_in_file: set[tuple[str, ...]] = set()
        for i in range(len(lines) - min_lines + 1):
            block = tuple(lines[i : i + min_lines])
            if block in seen_in_file:
                continue
            seen_in_file.add(block)
            index.setdefault(block, set()).add(path)

    duplicates: list[tuple[tuple[str, ...], list[Path]]] = []
    for block, paths in index.items():
        if len(paths) >= 2:
            duplicates.append((block, sorted(paths)))
    duplicates.sort(key=lambda item: (-len(item[1]), item[0][0]))
    return duplicates


def lint_markdown_duplication(plugin_dir: Path, errors: list[str]) -> None:
    duplicates = find_duplicate_blocks(plugin_dir)
    # Collapse overlapping windows: report at most one error per file-pair + first line.
    reported: set[tuple[tuple[str, ...], str]] = set()
    for block, paths in duplicates:
        file_key = tuple(rel(path) for path in paths)
        pair_key = (file_key, block[0])
        if pair_key in reported:
            continue
        reported.add(pair_key)
        preview = block[0][:80]
        joined = ", ".join(file_key)
        errors.append(
            f"{plugin_dir.name}: duplicated >= {DUPLICATE_BLOCK_MIN_LINES}-line normalized "
            f"block across {joined} (starts: {preview!r}); keep one canonical body "
            f"and short pointers elsewhere"
        )


def lint_prompt_budgets(plugin_dir: Path, errors: list[str]) -> None:
    budget_path = plugin_dir / "integrity" / "prompt-budgets.json"
    if not budget_path.is_file():
        # Only enforce when a baseline is committed (saas-startup-team and peers opt in).
        return
    try:
        payload = json.loads(budget_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        errors.append(f"{rel(budget_path)}: invalid JSON: {exc}")
        return
    files = payload.get("files") if isinstance(payload, dict) else None
    if not isinstance(files, dict):
        errors.append(f"{rel(budget_path)}: expected object with files mapping")
        return

    for relative, max_bytes in sorted(files.items()):
        if not isinstance(relative, str) or not isinstance(max_bytes, int):
            errors.append(f"{rel(budget_path)}: invalid budget entry {relative!r}")
            continue
        path = plugin_dir / relative
        if not path.is_file():
            errors.append(
                f"{rel(budget_path)}: budgeted file missing: {relative}"
            )
            continue
        size = path.stat().st_size
        if size > max_bytes:
            errors.append(
                f"{rel(path)}: {size} bytes exceeds prompt budget {max_bytes} "
                f"(committed in integrity/prompt-budgets.json); extract guidance "
                f"or raise the baseline deliberately"
            )


def warn_duplicate_skill_bodies(
    plugin_name: str,
    plugin_dir: Path,
    warnings: list[str],
) -> None:
    skill_paths = sorted((plugin_dir / "skills").glob("*/SKILL.md")) if (plugin_dir / "skills").is_dir() else []
    vectors: list[tuple[Path, set[str]]] = []
    for path in skill_paths:
        if path.parent.name.endswith("-workflow"):
            continue
        _metadata, body = parse_frontmatter(path, [])
        words = set(re.findall(r"[a-z0-9]{4,}", body.lower()))
        if len(words) >= 80:
            vectors.append((path, words))

    for index, (left_path, left_words) in enumerate(vectors):
        for right_path, right_words in vectors[index + 1 :]:
            union = left_words | right_words
            if not union:
                continue
            score = len(left_words & right_words) / len(union)
            if score >= 0.92:
                warnings.append(
                    f"{plugin_name}: high-overlap skill bodies: {rel(left_path)} and "
                    f"{rel(right_path)} ({score:.0%}); warning only"
                )


def parse_frontmatter(
    path: Path,
    errors: list[str],
    *,
    require: bool = True,
) -> tuple[dict[str, Any], str]:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        if require:
            errors.append(f"{rel(path)}: missing YAML frontmatter")
        return {}, text
    end = text.find("\n---", 4)
    if end == -1:
        errors.append(f"{rel(path)}: frontmatter is not closed")
        return {}, text

    frontmatter = text[4:end]
    try:
        loaded = yaml.load(frontmatter, Loader=yaml.BaseLoader)
        metadata = {} if loaded is None else loaded
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        line_number = mark.line + 2 if mark is not None else 2
        problem = getattr(exc, "problem", None) or str(exc).splitlines()[0]
        errors.append(f"{rel(path)}:{line_number}: invalid YAML frontmatter: {problem}")
        return {}, text[end + 4 :]
    if not isinstance(metadata, dict):
        errors.append(f"{rel(path)}: YAML frontmatter must be a mapping")
        return {}, text[end + 4 :]

    lines = frontmatter.splitlines()
    for index, line in enumerate(lines):
        if not line.startswith("description:"):
            continue
        raw_value = line.split(":", 1)[1].strip()
        if raw_value[:1] in "\"'|>[{":
            continue
        span = [raw_value]
        cursor = index + 1
        while cursor < len(lines) and (
            not lines[cursor].strip() or lines[cursor][0].isspace()
        ):
            span.append(lines[cursor].strip())
            cursor += 1
        if re.search(r"(?:^|\s)#(?:N|[0-9]+)\b", " ".join(span)):
            errors.append(
                f"{rel(path)}:{index + 2}: description must quote an issue placeholder"
            )
    return metadata, text[end + 4 :]


def slugify(value: str) -> str:
    value = sanitize_description(value).lower()
    value = re.sub(r"[^a-z0-9]+", "-", value).strip("-")
    return value


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
    return re.sub(r"\s+", " ", value).strip()


def rel(path: Path) -> str:
    try:
        return path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


if __name__ == "__main__":
    raise SystemExit(main())
