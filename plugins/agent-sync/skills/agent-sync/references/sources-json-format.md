# sources.json Format Reference

## Schema

```jsonc
{
  "version": 2,
  "variables": {
    "project_name": "My Project",
    "stack": ".NET 9 + React 19",
    "primary_agent": "Claude Code"
  },
  "files": {
    "claude": "CLAUDE.md",
    "architecture": ".claude/rules/architecture.md",
    "codeStyle": ".claude/rules/code-style.md",
    "settings": ".claude/settings.json",
    "hookLint": ".claude/hooks/post-edit-lint.sh"
  },
  "outputs": [
    {
      "path": "AGENTS.md",
      "sections": [
        { "id": "arch", "title": "Architecture", "source": "architecture", "type": "full-body" },
        { "id": "style", "title": "Code Style", "source": "codeStyle", "type": "full-body" },
        { "id": "workflow", "title": "Workflow", "source": "claude", "type": "extract", "headings": ["Development Workflow", "Commands"] },
        { "id": "settings", "title": "Claude Settings and Hooks", "source": "settings", "type": "settings" }
      ]
    }
  ]
}
```

## Top-Level Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `version` | number | Yes | Config version. Use `2`. Version `1` is auto-converted. |
| `variables` | object | No | Template variables substituted in the generated header |
| `files` | object | Yes | Map of source key → relative file path from project root |
| `outputs` | array | Yes | Array of output file configurations |

## Variables

Template variables are substituted as `{{variable_name}}` in the generated header.

| Variable | Used in |
|---|---|
| `project_name` | Title: `# AGENTS.md - {{project_name}}` |
| `stack` | Meta line: `**Stack:** {{stack}}` |
| `primary_agent` | Meta line: `**Primary Agent:** {{primary_agent}}` |

Custom variables are also supported and substituted throughout the output.

## Files

Keys are arbitrary identifiers referenced by section `source` fields. Values are paths relative to the project root.

```json
{
  "architecture": ".claude/rules/architecture.md",
  "settings": ".claude/settings.json"
}
```

## Outputs

Each output defines a generated file with its own sections.

| Field | Type | Required | Description |
|---|---|---|---|
| `path` | string | Yes | Output file path relative to project root |
| `parent` | string | No | Relative path to parent AGENTS.md (adds back-reference link) |
| `sections` | array | Yes | Sections to include in this output |

### Subdirectory Outputs

```json
{
  "outputs": [
    { "path": "AGENTS.md", "sections": [...] },
    {
      "path": "src/frontend/AGENTS.md",
      "parent": "../../AGENTS.md",
      "sections": [
        { "id": "fe-design", "title": "Frontend Design", "source": "frontendDesign", "type": "full-body" }
      ]
    }
  ]
}
```

## Section Types

### `full-body`

Includes the entire source file. Processing:
1. YAML frontmatter is stripped
2. Title heading (first `# ...`) is removed
3. All headings are shifted +1 level (`##` → `###`, etc.)
4. Section gets a `## Title` heading

```json
{ "id": "arch", "title": "Architecture", "source": "architecture", "type": "full-body" }
```

### `extract`

Pulls specific heading sections from a source file.

```json
{
  "id": "workflow",
  "title": "Workflow",
  "source": "claude",
  "type": "extract",
  "headings": ["Development Workflow", "Commands"]
}
```

- Each heading is matched case-insensitively
- Content is extracted from the heading to the next heading of equal or higher level
- If a single heading matches the section title, no sub-heading is added
- If multiple headings, each gets a `### Heading` wrapper

### `settings`

Renders `.claude/settings.json` as markdown tables showing enabled plugins, PostToolUse hooks, and hook script summaries.

```json
{ "id": "settings", "title": "Claude Settings and Hooks", "source": "settings", "type": "settings" }
```

## v1 Compatibility

Version 1 configs with `outputPath` + `sections` at the top level are automatically converted to version 2 format:

```json
{
  "version": 1,
  "outputPath": "AGENTS.md",
  "files": { ... },
  "sections": [ ... ]
}
```

This is equivalent to a v2 config with a single output.
