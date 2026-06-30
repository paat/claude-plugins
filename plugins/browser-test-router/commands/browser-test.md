---
allowed-tools: Bash, Read, Write, WebFetch
description: Run browser testing with multi-model delegation for token efficiency
argument-hint: "[url_or_module] [--evidence] [--out docs/qa/browser-test/<run>]"
---

# /browser-test-router:browser-test

Activate the browser-test-orchestration skill with multi-model delegation via opencode CLI and Kimi K2.5.

## What to do

1. **Load the orchestration skill** from this plugin's `skills/browser-test-orchestration/SKILL.md`

   If arguments include `--evidence`, also load `skills/browser-test-orchestration/references/evidence-reporting.md`.

2. **Run pre-flight checks** (MUST pass before any delegation):
   ```bash
   # Check opencode is installed
   if ! command -v opencode &> /dev/null; then
     echo "CRITICAL: opencode CLI not found"
     echo "Install from: https://opencode.ai"
     exit 1
   fi

   # Check chrome-devtools MCP is connected
   MCP_STATUS=$(opencode mcp list 2>&1 | grep chrome-devtools | grep connected || echo "NOT_CONNECTED")

   if [[ "$MCP_STATUS" == "NOT_CONNECTED" ]]; then
     echo "CRITICAL: chrome-devtools MCP is not connected."
     echo "Run: opencode mcp list"
     echo "Ensure chrome-devtools MCP shows 'connected' status"
     exit 1
   fi

   # Create screenshot directory (optional for lightweight mode, mandatory for --evidence)
   mkdir -p /tmp/screenshots
   ```
   - If NOT connected: print error and **stop**
   - If connected: run L1 health check against target URL (if URL provided)
   - Report: `"Pre-flight: opencode ✓, chrome-devtools MCP ✓, screenshots dir ✓. Target {url} is L1 reachable (HTTP {status})."`

3. **Determine target**:
   - If `$ARGUMENTS` contains a URL → single-page test mode
   - If `$ARGUMENTS` contains a module name → module test mode (requires acceptance-test skill)
   - If `$ARGUMENTS` contains `--evidence` → evidence QA report mode, with persistent artifacts
   - If no arguments → prompt user for target

4. **Evidence QA mode** (`--evidence`):
   - Create the output directory from `--out` or default to `docs/qa/browser-test/<timestamp>/`.
   - Capture desktop and mobile browser observations.
   - Capture mandatory desktop and mobile screenshots under `screenshots/`.
   - For safe discovered/supplied interactions, capture before/after observations and screenshots.
   - Write `test-results.json` and `report.md`.
   - Verdict must be `FAILED`, `NEEDS_WORK`, or `READY`. Default to `NEEDS_WORK` unless evidence is complete and no critical/high issues are found.

5. **Single-page lightweight mode** (URL provided and no `--evidence`):
   ```bash
   URL="$1"
   opencode run -m opencode/kimi-k2.5-free --format json "
   CRITICAL: Use chrome-devtools MCP tools only.
   Navigate to $URL, report status/title/elements as JSON
   " 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text'
   ```
   - Review results inline as Opus
   - If a second URL is provided for comparison:
     ```bash
     # Parallel navigation
     (opencode run -m opencode/kimi-k2.5-free "Navigate to $URL1..." > /tmp/page1.json) &
     (opencode run -m opencode/kimi-k2.5-free "Navigate to $URL2..." > /tmp/page2.json) &
     wait
     # Opus compares results inline
     ```

6. **Module test mode** (module name provided):
   - Activate the project's acceptance-test skill with model routing enabled
   - Follow the delegation protocol from the orchestration skill
   - Pass all test data and credentials explicitly in each opencode run call

7. **Report model usage** at the end:
   ```
   Pre-flight: opencode ✓, chrome-devtools MCP ✓, L1 ✓, L2 ✓
   Model Usage:
   - Kimi K2.5 (opencode run): {N} calls ({description}) [{W} wasted]
   - Opus: inline (analysis, classification)

   Estimated savings: ~{X}% vs all-Opus
   ```
   A call is "wasted" if it returned no useful data (empty page, MCP failure, timeout).

   In evidence mode, also print:
   ```
   Evidence artifacts: docs/qa/browser-test/<timestamp>/
   - report.md
   - test-results.json
   - screenshots/<files>
   Verdict: FAILED | NEEDS_WORK | READY
   ```
