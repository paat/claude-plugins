---
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/run-agy.sh:*)
description: Ask Gemini a question and get a response
argument-hint: "[--model <id>] <question or prompt>"
---

Send a question to Gemini through Antigravity CLI (`agy`) and return the response.

**Prompt:** $ARGUMENTS

## Steps

1. If the arguments contain `--model <id>`, remove it from the prompt and pass it to the runner (`agy models` lists IDs). Otherwise use agy's default model.

2. Run (Bash tool `timeout: 120000`):
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-agy.sh" [--model ID] --timeout 90 -- "USER_PROMPT"
   ```

3. Present the response, labeled as coming from Gemini.

4. On a non-zero exit, show the runner's one-line stderr reason and offer to answer yourself. Exit 4 means agy is missing or not signed in; do not retry it.
