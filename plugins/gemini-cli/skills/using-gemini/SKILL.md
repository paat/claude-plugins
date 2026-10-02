---
name: using-gemini
description: "Use to consult Gemini (via Antigravity CLI) for second opinions on code, architecture, reviews, debugging, or alternative technical perspectives."
---

# Using Gemini

Consult Google's Gemini through Antigravity CLI (`agy`) for a second opinion. Prerequisite: `agy` installed and signed in once with a Google AI Pro/Ultra account, or `GEMINI_API_KEY` set.

## When to Use

Use for complex reviews, architecture decisions with several valid approaches, hard debugging, security-sensitive code, or when the user asks for a second opinion. Skip it for routine or trivial changes, answers you are already confident in, and time-critical simple tasks.

## How to Call

Always go through the bundled runner. It runs `agy` read-only in an isolated home and sterile directory, inlines `--file` contents (Gemini cannot open files, run commands, or fetch URLs; web search stays available), and prints only the response:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/run-agy.sh" [--model ID] [--timeout SECONDS] [--file PATH]... -- "PROMPT"
```

- Default timeout is 180s. Set the Bash tool timeout about 30s above `--timeout`.
- `--model` takes an ID from `agy models`. Omit it to use agy's default.
- To review a diff, write it to a temp file and pass it with `--file`.
- Exit codes: 0 success; 2 usage or unreadable file; 3 agy failed or timed out (one-line reason on stderr; one retry is reasonable); 4 agy missing or not signed in (do not retry).

## Presenting Results

Label what came from Gemini, add your own assessment, call out agreements (higher confidence) and disagreements (with your reasoning), and end with one unified recommendation. If Gemini is unavailable, continue with your own analysis and say so.
