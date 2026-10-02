---
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/run-agy.sh:*), Read
description: Get Gemini to explain code or a concept
argument-hint: "[--model <id>] <file path or concept>"
---

Ask Gemini (via `agy`) to explain code from a file or a freeform concept, and present the explanation.

**Target:** $ARGUMENTS

## Steps

1. If the arguments contain `--model <id>`, remove it and pass it to the runner. Otherwise use agy's default model.

2. Run (Bash tool `timeout: 150000`). For a file, pass it with `--file` (the runner inlines it; Gemini cannot open files itself):
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-agy.sh" [--model ID] --timeout 120 --file path/to/file -- "Explain this code clearly: what it does, how it works, key design decisions, dependencies, and non-obvious behavior."
   ```
   For a concept:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-agy.sh" [--model ID] --timeout 90 -- "Explain the following clearly and concisely, with examples where helpful: CONCEPT"
   ```

3. Present the explanation. If it misses important points, add them and mark them as yours.

4. If the runner exits non-zero, explain it yourself and note that Gemini was unavailable (give the stderr reason).
