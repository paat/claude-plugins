---
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/run-agy.sh:*), Read, Grep
description: Get a dual AI code review — Gemini + Claude analyze code together
argument-hint: "[--model <id>] <file or directory path>"
---

Perform a dual code review: get Gemini's analysis of the code (via `agy`), do your own review, and present a unified report.

**Target:** $ARGUMENTS

## Steps

1. Determine what to review:
   - File paths: review those files
   - A directory: pick its key files, at most ~10, skipping generated or vendored paths (`node_modules/`, `dist/`, `build/`, lockfiles, minified assets)
   - Unclear: ask the user

2. If the arguments contain `--model <id>`, remove it and pass it to the runner. Otherwise use agy's default model.

3. Read the files yourself first. Stay frugal: for large files, read targeted ranges.

4. Send the files to Gemini, one `--file` per file (Bash tool `timeout: 270000`):
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-agy.sh" [--model ID] --timeout 240 --file path/one --file path/two -- "Review these files thoroughly for bugs, security vulnerabilities, performance issues, error-handling gaps, and code quality. Cite file and line for every finding."
   ```

5. Do your own independent review of the same files.

6. Present a unified report:

   ## Code Review: [filename(s)]

   ### Gemini's Findings
   ### My Findings
   ### Where We Agree
   [Higher confidence these are real problems]
   ### Where We Differ
   [Disagreements, with your reasoning]
   ### Recommendations
   [Prioritized changes combining both analyses]

7. If the runner exits non-zero, do your own review and note that Gemini was unavailable (give the stderr reason).
