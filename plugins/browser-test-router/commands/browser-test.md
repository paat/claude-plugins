---
allowed-tools: Bash, Read, WebFetch
description: Run browser testing with multi-model delegation for token efficiency
argument-hint: "[url_or_module] (optional - URL to test or module name)"
---

# /browser-test-router:browser-test

Activate the browser-test-orchestration skill with multi-model delegation via opencode CLI and Kimi K2.5.

## What to do

1. **Load the orchestration skill** from this plugin's `skills/browser-test-orchestration/SKILL.md`

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
   ```
   - If NOT connected: print error and **stop**
   - If connected: run L1 health check against target URL (if URL provided)
   - Report: `"Pre-flight: opencode ✓, chrome-devtools MCP ✓. Target {url} is L1 reachable (HTTP {status})."`

3. **Determine target**:
   - If `$ARGUMENTS` contains a URL → single-page test mode
   - If `$ARGUMENTS` contains a module name → module test mode (requires acceptance-test skill)
   - If no arguments → prompt user for target

4. **Single-page test mode** (URL provided):
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

5. **Module test mode** (module name provided):
   - Activate the project's acceptance-test skill with model routing enabled
   - Follow the delegation protocol from the orchestration skill
   - Pass all test data and credentials explicitly in each opencode run call

6. **Report model usage** at the end:
   ```
   Pre-flight: opencode ✓, chrome-devtools MCP ✓, L1 ✓, L2 ✓
   Model Usage:
   - Kimi K2.5 (opencode run): {N} calls ({description}) [{W} wasted]
   - Opus: inline (analysis, classification)

   Estimated savings: ~{X}% vs all-Opus
   ```
   A call is "wasted" if it returned no useful data (empty page, MCP failure, timeout).
