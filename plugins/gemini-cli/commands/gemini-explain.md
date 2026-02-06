---
allowed-tools: Bash(gemini:*), Read
description: Get Gemini to explain code or a concept
argument-hint: <file path or concept>
---

Ask Gemini to explain code from a file or a freeform concept, and present the explanation.

## Instructions

The user wants an explanation of:

**Target:** $ARGUMENTS

## Steps

1. Determine the model to use:
   - Default: `-m gemini-3-flash-preview` (fast for explanations)
   - If the user included `--pro` in their arguments, use `-m gemini-3-pro-preview` instead
   - Remove the model flag from the arguments

2. Determine if the target is a file or a concept:
   - **File path** (contains `/` or common extensions like `.py`, `.js`, `.ts`, `.go`, `.rs`, etc.): Use `@file` injection
   - **Concept/question** (freeform text): Send as a prompt directly

3. For files:
   ```bash
   timeout 90 gemini @path/to/file [-m model] -p "Explain this code clearly. Cover: what it does, how it works, key design decisions, dependencies, and any non-obvious behavior. Use simple language." -o text 2>/dev/null
   ```

4. For concepts:
   ```bash
   timeout 60 gemini [-m model] -p "Explain the following clearly and concisely, with examples where helpful: CONCEPT" -o text 2>/dev/null
   ```

5. Present Gemini's explanation. If it's particularly good, present it directly. If it misses important points, supplement with your own additions.

6. If Gemini is unavailable, provide the explanation yourself and note Gemini was unavailable.
