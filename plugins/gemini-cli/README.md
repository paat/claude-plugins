# gemini-cli

Integrate Google's Gemini CLI into Claude Code for second opinions, dual code reviews, and AI-assisted explanations. Get two AI perspectives on your code and technical decisions.

## Prerequisites

1. **Install Gemini CLI:**
   ```bash
   npm install -g @google/gemini-cli
   ```

2. **Authenticate:** Run `gemini` once interactively to complete OAuth login.

3. **Enable Gemini 3 preview models (recommended):** Add the following to `~/.gemini/settings.json`:
   ```json
   {
     "general": {
       "previewFeatures": true
     }
   }
   ```
   This unlocks `gemini-3-flash-preview` and `gemini-3-pro-preview`, which the commands use by default. Without this setting, commands will fall back to `gemini-2.5-flash` / `gemini-2.5-pro`.

## Commands

| Command | Description | Default Model |
|---------|-------------|---------------|
| `/gemini-ask <question>` | Ask Gemini any question | `gemini-3-flash-preview` |
| `/gemini-review <file>` | Dual AI code review (Gemini + Claude) | `gemini-3-pro-preview` |
| `/gemini-second-opinion <topic>` | Get Gemini's take on an approach or decision | `gemini-3-pro-preview` |
| `/gemini-explain <file or concept>` | Get Gemini to explain code or a concept | `gemini-3-flash-preview` |

### Model Override

Every command accepts `--pro` or `--flash` to override the default model:

```
/gemini-ask --pro what is the most efficient sorting algorithm for nearly-sorted data
/gemini-review --flash src/utils.py
```

## Skill

The plugin also includes a `using-gemini` skill that teaches Claude Code when and how to call Gemini autonomously. Claude Code will consult Gemini on its own when it encounters tasks that benefit from a second perspective (complex code reviews, architecture decisions, debugging).

## How It Works

All commands invoke Gemini CLI in non-interactive mode:

```bash
gemini [-m model] -p "prompt" -o text 2>/dev/null
```

- `-o text` produces clean output
- `2>/dev/null` suppresses OAuth and hook noise
- `@file` syntax injects file contents directly into Gemini's context
- `timeout` prevents hanging on large prompts

## Available Models

| Model | Speed | Best For | Notes |
|-------|-------|----------|-------|
| `gemini-2.5-flash` | Fast | Quick queries, explanations | Stable |
| `gemini-2.5-pro` | Moderate | Complex analysis, code review | Stable |
| `gemini-3-flash-preview` | Fast | Quick queries, explanations | Requires `previewFeatures: true` |
| `gemini-3-pro-preview` | Slower | Deep reasoning, thorough review | Requires `previewFeatures: true` |
