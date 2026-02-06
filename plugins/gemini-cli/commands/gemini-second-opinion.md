---
allowed-tools: Bash(gemini:*), Read
description: Get Gemini's second opinion on an approach or decision
argument-hint: <topic, approach, or decision to evaluate>
---

Get Gemini's perspective on a technical approach, architecture decision, or implementation strategy, then synthesize both AI perspectives.

## Instructions

The user wants a second opinion on:

**Topic:** $ARGUMENTS

## Steps

1. Determine the model to use:
   - Default: `-m gemini-3-pro-preview` (deep reasoning for decisions)
   - If the user included `--flash` in their arguments, use `-m gemini-3-flash-preview` instead
   - Remove the model flag from the prompt

2. If the topic references specific files, read them first to build context.

3. Construct a detailed prompt for Gemini that includes:
   - The decision or approach being considered
   - Relevant context (file contents, constraints, requirements)
   - Ask for pros/cons, alternatives, and a recommendation

4. Send to Gemini:
   ```bash
   timeout 120 gemini [@relevant_files] [-m model] -p "CONTEXT AND QUESTION" -o text 2>/dev/null
   ```

5. Form your own independent opinion on the same topic.

6. Present a synthesized analysis:

   ## Second Opinion: [topic summary]

   ### Gemini's Perspective
   [Key points from Gemini's analysis]

   ### My Perspective
   [Your own analysis]

   ### Consensus
   [Points both AIs agree on]

   ### Different Takes
   [Where perspectives differ, with reasoning from each side]

   ### Recommendation
   [Your synthesized recommendation, weighing both perspectives]

7. If Gemini is unavailable, provide your own analysis and note Gemini was unavailable.
