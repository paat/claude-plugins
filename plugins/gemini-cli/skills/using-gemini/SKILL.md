---
name: using-gemini
description: This skill should be used when consulting Gemini CLI for second opinions on code, architecture decisions, code reviews, debugging help, or when the user asks to "ask gemini", "get gemini's opinion", "consult gemini", "what does gemini think", or "use gemini". Also applies when the user wants a "second opinion", "alternative perspective", or "another AI's take" on technical decisions.
---

# Using Gemini CLI

Use Google's Gemini CLI (`gemini`) to get second opinions, alternative perspectives, and additional analysis during development work. Gemini CLI must be installed and authenticated via OAuth before use.

## Prerequisites

Gemini CLI must be installed (`npm install -g @google/gemini-cli`) and authenticated. The user must have run `gemini` interactively at least once to complete OAuth login.

To use Gemini 3 preview models, the user must enable experimental features in `~/.gemini/settings.json`:

```json
{
  "general": {
    "previewFeatures": true
  }
}
```

## When to Use Gemini

**Good candidates for Gemini consultation:**
- Complex code reviews where a second perspective adds value
- Architecture decisions with multiple valid approaches
- Debugging difficult issues — fresh eyes can spot what you miss
- Reviewing security-sensitive code
- When the user explicitly asks for a second opinion or alternative perspective
- Explaining unfamiliar codebases or complex algorithms

**Don't use Gemini for:**
- Simple, routine tasks (formatting, renaming, trivial fixes)
- Tasks where you're already confident in the answer
- Every single code change — use judgment about when a second opinion adds value
- When speed is critical and the task is straightforward

## How to Call Gemini

### Basic Usage

Always use `-o text` for clean output and `2>/dev/null` to suppress OAuth/hook noise:

```bash
gemini -p "Your prompt here" -o text 2>/dev/null
```

### With File Context

Inject files using `@file` syntax (Gemini reads the file directly):

```bash
gemini @src/main.py -p "Review this code for bugs and security issues" -o text 2>/dev/null
```

Multiple files:

```bash
gemini @src/auth.py @src/middleware.py -p "Do these components integrate correctly?" -o text 2>/dev/null
```

### Piping Content

Pipe content when you need to send computed/filtered output:

```bash
cat src/utils.py | gemini -p "Explain what this code does" -o text 2>/dev/null
```

### Model Selection

Available models (fastest to most capable):
- **`gemini-2.5-flash`** — Stable fast model
- **`gemini-2.5-pro`** — Stable deep reasoning
- **`gemini-3-flash-preview`** — Fast, good for general queries, explanations, quick reviews (default for speed tasks). Requires `previewFeatures: true`.
- **`gemini-3-pro-preview`** — Deep reasoning, thorough code review, architecture decisions (default for depth tasks). Requires `previewFeatures: true`.

Select model with `-m`:

```bash
gemini -m gemini-3-pro-preview -p "Analyze this architecture decision..." -o text 2>/dev/null
```

**Guidelines:**
- Use `-m gemini-3-flash-preview` for speed: general queries, explanations, quick checks
- Use `-m gemini-3-pro-preview` when the task requires deep reasoning: complex code review, architecture analysis, security audit
- Fall back to `gemini-2.5-flash` / `gemini-2.5-pro` if the preview models return errors
- When in doubt, start with flash; escalate to pro if the response lacks depth

### Timeout

Use `timeout` for safety on large prompts:

```bash
timeout 120 gemini -p "..." -o text 2>/dev/null
```

Recommended timeouts:
- Quick questions: 30s
- Code review: 120s
- Large file analysis: 180s

## Presenting Results

When you consult Gemini, always:

1. **Label the source** — Make it clear which insights come from Gemini vs your own analysis
2. **Synthesize, don't just relay** — Add your own assessment of Gemini's response
3. **Highlight agreements** — When both AIs agree, that increases confidence
4. **Flag disagreements** — When you disagree with Gemini, explain why and give your recommendation
5. **Give a unified conclusion** — Don't leave the user to reconcile two separate analyses

Example format:

```
## Analysis

**Gemini's perspective:** [summary of Gemini's key points]

**My analysis:** [your own assessment]

**Where we agree:** [shared conclusions — higher confidence]

**Where we differ:** [disagreements with your reasoning]

**Recommendation:** [your synthesized recommendation]
```

## Error Handling

| Error Pattern | Cause | Action |
|---|---|---|
| `OAuth token expired` or auth errors | Token needs refresh | Tell user to run `gemini` interactively to re-authenticate |
| Timeout / no response | Network or rate limit | Retry once with longer timeout; if still fails, proceed without Gemini |
| `model not found` | Invalid model name | Fall back to `gemini-2.5-flash` (stable). If preview models fail, the user may need to enable `previewFeatures` in `~/.gemini/settings.json` |
| Empty response | Prompt too vague or API issue | Rephrase with more context and retry once |

If Gemini is unavailable, don't block the user's workflow — proceed with your own analysis and note that Gemini was unavailable.

For the complete CLI reference (all flags, models, error patterns, and usage examples), see `references/gemini-cli-reference.md`.
