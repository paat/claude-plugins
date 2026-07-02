---
name: using-gemini
description: "Use to consult Gemini CLI for second opinions on code, architecture, reviews, debugging, or alternative technical perspectives."
---

# Using Gemini CLI

Use Google's Gemini CLI (`gemini`) to get second opinions, alternative perspectives, and additional analysis during development work. Gemini CLI must be installed and authenticated via OAuth before use.

## Prerequisites

Gemini CLI must be installed (`npm install -g @google/gemini-cli`) and authenticated. The user must have run `gemini` interactively at least once to complete OAuth login.

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

Always use `-o text` for clean output and `2>/dev/null` to suppress OAuth/hook noise:

```bash
gemini -p "Your prompt here" -o text 2>/dev/null
```

Inject files with `@file` syntax inside the `-p` string, or pipe content when you need computed/filtered output instead:

```bash
gemini -p "Review this code for bugs and security issues. @src/main.py" -o text 2>/dev/null
cat src/utils.py | gemini -p "Explain what this code does" -o text 2>/dev/null
```

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

If Gemini is unavailable, don't block the user's workflow — proceed with your own analysis and note that Gemini was unavailable.

For model selection, timeouts, `@file`/piping details, and the full error-handling table, see `references/gemini-cli-reference.md`.
