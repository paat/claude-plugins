# gemini-cli

Integrate Google's Gemini (via Antigravity CLI) into Claude Code for second opinions, dual code reviews, and AI-assisted explanations. Get two AI perspectives on your code and technical decisions.

## Mission Fit

`gemini-cli` is a supporting review and research utility. It is not a demand source by
itself, but it can improve SaaS delivery by adding an independent perspective for
architecture, debugging, and code-review decisions.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install gemini-cli@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in `.claude/settings.local.json`.

## Prerequisites

1. **Install Antigravity CLI** (`agy`): see https://antigravity.google/docs/cli/install/
2. **Authenticate:** run `agy` once and sign in with a Google AI Pro/Ultra account, or set `GEMINI_API_KEY`.
3. `jq` and GNU `timeout` on `PATH`.

Gemini CLI stopped serving personal Google accounts on 2026-06-18 (`IneligibleTierError`), so this plugin now drives `agy`. The plugin name is kept for compatibility.

## Commands

| Command | Description |
|---------|-------------|
| `/gemini-ask <question>` | Ask Gemini any question |
| `/gemini-review <file>` | Dual AI code review (Gemini + Claude) |
| `/gemini-second-opinion <topic>` | Get Gemini's take on an approach or decision |
| `/gemini-explain <file or concept>` | Get Gemini to explain code or a concept |

### Model Override

Every command uses agy's default model and accepts `--model <id>` (IDs from `agy models`):

```
/gemini-review --model gemini-3.1-pro-high src/utils.py
```

## Skill

The plugin also includes a `using-gemini` skill that teaches Claude Code when and how to call Gemini autonomously. Claude Code will consult Gemini on its own when it encounters tasks that benefit from a second perspective (complex code reviews, architecture decisions, debugging).

## How It Works

Every command calls `scripts/run-agy.sh`, which:

- runs `agy` from an empty temporary home and work directory, copying only your sign-in token (or passing `GEMINI_API_KEY`)
- denies agy file reads, writes, commands, URL fetches, and MCP; web search stays available
- inlines `--file` contents into the prompt over stdin, so file size is not limited by argv
- prints only the response; on failure it exits non-zero with a one-line reason on stderr
