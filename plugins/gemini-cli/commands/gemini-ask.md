---
allowed-tools: Bash(gemini:*)
description: Ask Gemini a question and get a response
argument-hint: <question or prompt>
---

Send a question or prompt to Google's Gemini AI and return the response.

## Instructions

The user wants to ask Gemini the following:

**Prompt:** $ARGUMENTS

## Steps

1. Determine the model to use:
   - Default: `-m gemini-3-flash-preview` (fast for general queries)
   - If the user included `--pro` in their arguments, use `-m gemini-3-pro-preview` instead and remove `--pro` from the prompt
   - If the user included `--flash` in their arguments, use `-m gemini-3-flash-preview` explicitly and remove `--flash` from the prompt

2. Run the Gemini command:
   ```bash
   timeout 60 gemini [-m model] -p "USER_PROMPT" -o text 2>/dev/null
   ```

3. Present Gemini's response clearly, prefixed with a note that this comes from Gemini.

4. If the response is empty or an error occurs, retry once. If it still fails, inform the user that Gemini is unavailable and offer to answer the question yourself.
