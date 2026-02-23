# Gemini CLI Reference

## Installation

```bash
npm install -g @google/gemini-cli
```

After installation, run `gemini` once interactively to complete OAuth authentication.

### Enable Gemini 3 Preview Models

To access `gemini-3-flash-preview` and `gemini-3-pro-preview`, enable experimental features in `~/.gemini/settings.json`:

```json
{
  "general": {
    "previewFeatures": true
  }
}
```

## Command Syntax

```
gemini [options] -p "prompt [@file ...]" [-o format]
```

## Core Flags

| Flag | Description | Example |
|---|---|---|
| `-p "prompt"` | Non-interactive prompt (required for scripted use) | `gemini -p "explain this"` |
| `-o format` | Output format: `text`, `json`, `stream-json` | `gemini -p "hi" -o text` |
| `-m model` | Model selection | `gemini -m gemini-3-pro-preview -p "..."` |
| `@file` | Inject file contents into context (inside `-p` string) | `gemini -p "review @main.py"` |
| `--sandbox` | Run code execution in sandbox | `gemini --sandbox -p "..."` |
| `--debug` | Enable debug output | `gemini --debug -p "..."` |

## Output Formats

| Format | Use Case |
|---|---|
| `text` | Clean text output — **always use this for scripted calls** |
| `json` | Structured JSON response |
| `stream-json` | Streaming JSON chunks |

**Always use `-o text 2>/dev/null`** for clean output in automated/scripted contexts.

## Models

| Model | Speed | Reasoning | Best For | Notes |
|---|---|---|---|---|
| `gemini-2.5-flash-lite` | Fastest | Basic | Simple queries, quick checks | Stable |
| `gemini-2.5-flash` | Fast | Good | General queries, explanations, quick reviews | Stable |
| `gemini-2.5-pro` | Moderate | Deep | Complex code review, architecture decisions, security analysis | Stable |
| `gemini-3-flash-preview` | Fast | Good+ | Next-gen fast model | Requires `previewFeatures: true` |
| `gemini-3-pro-preview` | Slower | Deepest | Next-gen deep reasoning | Requires `previewFeatures: true` |

Default (no `-m` flag) uses the configured default model.

### Model Selection Guide

- **Quick question or explanation** → `gemini-3-flash-preview`
- **Code review** → `gemini-3-pro-preview` (thorough analysis benefits from deeper reasoning)
- **Architecture decision** → `gemini-3-pro-preview`
- **Security review** → `gemini-3-pro-preview`
- **Simple code explanation** → `gemini-3-flash-preview`
- **Debugging help** → Start with `gemini-3-flash-preview`, escalate to `gemini-3-pro-preview` if needed

## File Injection

### `@file` Syntax

Place `@file` references inside the `-p` string — Gemini reads the file contents automatically:

```bash
# Single file
gemini -p "Review this code. @src/main.py" -o text 2>/dev/null

# Multiple files
gemini -p "Check integration between these files. @src/auth.py @src/session.py" -o text 2>/dev/null

# Glob patterns (shell expands)
gemini -p "Review all Python files. @src/*.py" -o text 2>/dev/null
```

**Important:** Do NOT use `@file` as a separate positional argument with `-p`. The `@file` reference must be inside the `-p` string.

### Piping

```bash
# Pipe file content
cat complex_file.py | gemini -p "Explain this" -o text 2>/dev/null

# Pipe command output
git diff HEAD~1 | gemini -p "Review these changes" -o text 2>/dev/null

# Pipe filtered content
grep -n "TODO" src/*.py | gemini -p "Prioritize these TODOs" -o text 2>/dev/null
```

## Timeout Recommendations

| Task Type | Timeout | Command |
|---|---|---|
| Quick question | 30s | `timeout 30 gemini -p "..." -o text 2>/dev/null` |
| Code explanation | 60s | `timeout 60 gemini -p "explain @file" -o text 2>/dev/null` |
| Code review | 120s | `timeout 120 gemini -p "review @file" -o text 2>/dev/null` |
| Large file analysis | 180s | `timeout 180 gemini -p "analyze @file" -o text 2>/dev/null` |
| Multi-file analysis | 240s | `timeout 240 gemini -p "... @f1 @f2" -o text 2>/dev/null` |

## Common Error Patterns

| Error | Cause | Solution |
|---|---|---|
| OAuth/auth errors | Token expired | Run `gemini` interactively to re-auth |
| `ENOTFOUND` / network errors | No internet | Check connectivity |
| Timeout | Large prompt or rate limit | Increase timeout or reduce prompt size |
| `model not found` | Invalid model ID or preview not enabled | Use stable model names, or enable `previewFeatures` in `~/.gemini/settings.json` |
| Empty response | Vague prompt | Add more context and retry |
| `rate limit exceeded` | Too many requests | Wait 30-60s and retry |

## Usage Patterns for Claude Code

### Get a Second Opinion

```bash
gemini -p "I think the bug is in the error handling on line 45. Do you agree? What else might cause the issue? @problematic_file.py" -o text 2>/dev/null
```

### Architecture Review

```bash
gemini -m gemini-3-pro-preview -p "Review this API structure. Are there any design pattern violations or scalability concerns? @src/api/" -o text 2>/dev/null
```

### Diff Review

```bash
git diff main...HEAD | gemini -p "Review these changes for bugs, security issues, and code quality" -m gemini-3-pro-preview -o text 2>/dev/null
```

### Explain Unfamiliar Code

```bash
gemini -p "Explain what this code does, its dependencies, and any potential issues. @legacy_module.py" -o text 2>/dev/null
```
