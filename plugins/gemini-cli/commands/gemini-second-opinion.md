---
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/run-agy.sh:*), Read
description: Get Gemini's second opinion on an approach or decision
argument-hint: "[--model <id>] <topic, approach, or decision to evaluate>"
---

Get Gemini's perspective (via `agy`) on a technical approach, architecture decision, or implementation strategy, then synthesize both views.

**Topic:** $ARGUMENTS

## Steps

1. If the arguments contain `--model <id>`, remove it and pass it to the runner. Otherwise use agy's default model.

2. If the topic references specific files, read them to build context.

3. Write a prompt that states the decision being considered, the constraints and requirements, and asks for pros and cons, alternatives, and a recommendation.

4. Run it, attaching relevant files with `--file` (Bash tool `timeout: 210000`):
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-agy.sh" [--model ID] --timeout 180 [--file path] -- "CONTEXT AND QUESTION"
   ```

5. Form your own independent opinion.

6. Present:

   ## Second Opinion: [topic summary]

   ### Gemini's Perspective
   ### My Perspective
   ### Consensus
   ### Different Takes
   [Reasoning from each side]
   ### Recommendation
   [Your synthesized recommendation]

7. If the runner exits non-zero, give your own analysis and note that Gemini was unavailable (give the stderr reason).
