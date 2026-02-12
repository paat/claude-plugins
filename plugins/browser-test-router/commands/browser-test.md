---
allowed-tools: Bash, Read, WebFetch, Task
description: Run browser testing with multi-model delegation for token efficiency
argument-hint: "[url_or_module] (optional - URL to test or module name)"
---

# /browser-test-router:browser-test

Activate the browser-test-orchestration skill with multi-model delegation.

## What to do

1. **Load the orchestration skill** from this plugin's `skills/browser-test-orchestration/SKILL.md`

2. **Determine target**:
   - If `$ARGUMENTS` contains a URL → single-page test mode
   - If `$ARGUMENTS` contains a module name → module test mode (requires acceptance-test skill)
   - If no arguments → prompt user for target

3. **Single-page test mode** (URL provided):
   - Delegate navigation to Haiku: `Task(model:"haiku", prompt:"Navigate to {url}, report status/title/elements as JSON")`
   - Review results inline as Opus
   - If a second URL is provided for comparison, delegate both navigations to Haiku, then comparison to Sonnet

4. **Module test mode** (module name provided):
   - Activate the project's acceptance-test skill with model routing enabled
   - Follow the delegation protocol from the orchestration skill

5. **Report model usage** at the end:
   ```
   Model Usage:
   - Haiku:  {N} calls ({description})
   - Sonnet: {M} calls ({description})
   - Opus:   inline (analysis, classification)
   ```
