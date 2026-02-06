---
allowed-tools: Bash(gemini:*), Read, Grep
description: Get a dual AI code review — Gemini + Claude analyze code together
argument-hint: <file or directory path>
---

Perform a dual code review: get Gemini's analysis of the code, then do your own review, and present a unified report.

## Instructions

The user wants a code review of:

**Target:** $ARGUMENTS

## Steps

1. Determine what to review:
   - If `$ARGUMENTS` contains file paths, review those files
   - If `$ARGUMENTS` contains a directory, review key files in it
   - If unclear, ask the user what to review

2. Determine the model to use:
   - Default: `-m gemini-3-pro-preview` (thorough analysis for code review)
   - If the user included `--flash` in their arguments, use `-m gemini-3-flash-preview` instead
   - If the user included `--pro` in their arguments, use `-m gemini-3-pro-preview` explicitly
   - Remove the model flag from the file path arguments

3. Read the file(s) yourself first to understand the code.

4. Send the file(s) to Gemini for review using `@file` injection:
   ```bash
   timeout 120 gemini @path/to/file [-m model] -p "Review this code thoroughly. Look for: bugs, security vulnerabilities, performance issues, code quality problems, error handling gaps, and suggest improvements. Be specific with line references." -o text 2>/dev/null
   ```
   For multiple files:
   ```bash
   timeout 180 gemini @file1 @file2 [-m model] -p "Review these files..." -o text 2>/dev/null
   ```

5. Perform your own independent code review of the same file(s).

6. Present a unified report in this format:

   ## Code Review: [filename(s)]

   ### Gemini's Findings
   [Summarize Gemini's key findings — bugs, issues, suggestions]

   ### My Findings
   [Your own code review findings]

   ### Where We Agree
   [Issues both identified — higher confidence these are real problems]

   ### Where We Differ
   [Any disagreements, with your reasoning]

   ### Recommendations
   [Prioritized list of suggested changes, combining both analyses]

7. If Gemini is unavailable, proceed with your own review and note that Gemini was unavailable.
