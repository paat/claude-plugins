# browser-test-router

Multi-model delegation plugin for browser testing. Routes mechanical browser work to Kimi K2.5 (via opencode CLI), saving 40-55% tokens on browser-heavy testing sessions.

## Problem

Claude Max subscriptions deplete quickly when Opus handles everything — including zero-reasoning browser work like navigation and form filling. Additionally, text-only browser testing misses visual/design issues like CSS regressions, validation error styling, and layout breakage.

## Solution

Delegate mechanical browser operations to Kimi K2.5 (open-weight model) via opencode CLI, with enhanced visual testing via text-based visual property descriptions:

| Task Type | Model | Cost vs Opus | Savings |
|-----------|-------|--------------|---------|
| Navigation, health checks | Kimi K2.5 (via opencode) | ~15% | 85% |
| Form operations, sessions | Kimi K2.5 (via opencode) | ~15% | 85% |
| Page comparison, structural diff | Kimi K2.5 (via opencode) | ~15% | 85% |
| Spec parsing, gap classification | Opus (inline) | 100% | 0% |

**Overall session savings: 40-55%** of total token consumption.

## Dependencies

- bash 4+
- curl (for L1 health checks)
- jq (for JSON parsing)
- **opencode CLI** with chrome-devtools MCP configured

### Setup

1. **Install opencode**: https://opencode.ai

2. **Configure chrome-devtools MCP** in `opencode.json`:
   ```json
   {
     "mcp": {
       "chrome-devtools": {
         "type": "local",
         "command": ["npx", "-y", "chrome-devtools-mcp@latest", "--isolated"]
       }
     }
   }
   ```

   **IMPORTANT**: The `--isolated` flag is required for parallel browser operations. It creates temporary browser profiles for each opencode session, enabling concurrent testing.

3. **Verify connection**:
   ```bash
   opencode mcp list
   ```
   Should show: `✓ chrome-devtools connected`

4. **Install plugin**:
   ```
   /install browser-test-router
   ```

## How It Works

```
Opus (main session, Claude Code)
  ↓
  Bash tool: opencode run -m opencode/kimi-k2.5-free "prompt with full context"
  ↓
  Kimi K2.5 executes with chrome-devtools MCP access
  ↓
  Returns JSON result to stdout
  ↓
  Opus analyzes results inline
```

**Key insight**: Each opencode run has ZERO context. Opus must pass ALL information (URLs, credentials, test data) in the prompt.

## Visual Testing Capabilities (Optional)

**IMPORTANT:** Visual property extraction is **optional** and should only be used when testing visual aspects. For most page comparisons (content/behavior testing), skip visual properties entirely.

### When to Use Visual Testing

**Skip visual testing when:**
- Comparing content/functionality (text, data, behavior)
- Design is expected to be different between pages
- Testing functional equivalence only

**Use visual testing when:**
- Visual regression testing (CSS changes)
- Validation error styling verification
- Accessibility testing (color contrast, indicators)
- Responsive design testing

### Mental Model: Blind Guide + Sighted Assistant

**Opus = Blind person** (can't see the page directly)
**Kimi = Sighted assistant** (can see the page, uses chrome-devtools MCP)

**Primary approach: Kimi describes what it sees**
- Element colors, sizes, positions, states → as TEXT
- Rich visual property descriptions (borderColor: "rgb(220, 53, 69)")
- Adds ~60% tokens vs text-only
- Sufficient for 90% of visual testing scenarios

**Fallback: Screenshots only when words aren't enough**
- Complex layouts hard to describe in words
- Visual bugs that need visual evidence
- Use sparingly, only when Opus requests

### What Visual Testing Catches (When Enabled)

**With visual property descriptions (text-based):**
- ✅ CSS regressions (color, sizing, positioning changes)
- ✅ Visual error states (red borders, error icons, disabled appearance)
- ✅ Layout shifts (elements moving, size changes)
- ✅ Validation styling (error indicators, focus states)
- ✅ Button states (enabled vs disabled - opacity, color)
- ✅ Element visibility (display: none vs visible)

**Example visual property capture:**
```json
{
  "type": "button",
  "text": "Submit",
  "selector": "#submit-btn",
  "visual": {
    "color": "rgb(255, 255, 255)",
    "backgroundColor": "rgb(0, 123, 255)",
    "fontSize": "16px",
    "borderColor": "rgb(0, 123, 255)",
    "position": {"x": 100, "y": 200, "width": 120, "height": 40},
    "state": {
      "visible": true,
      "enabled": true,
      "focused": false,
      "opacity": "1",
      "hasError": false
    }
  }
}
```

Opus can compare these text descriptions to detect visual issues without seeing the page.

### Cost Impact

Visual property descriptions add ~60% tokens vs text-only. Screenshots add more but are used sparingly (<10% of operations).

**Overall session savings: 40-55%** vs all-Opus execution (including visual testing overhead).

## Usage

### Test single URL

```
/browser-test-router:browser-test https://example.com
```

### Compare two systems

```
/browser-test-router:browser-test https://legacy.app.com/users https://new.app.com/users
```

### With project acceptance-test skill

```
/acceptance-test crm
```

The skill automatically delegates mechanical operations to Kimi K2.5 via opencode.

## Delegation Pattern

**Navigation**:
```bash
opencode run -m opencode/kimi-k2.5-free "
CRITICAL: Use chrome-devtools MCP tools only.
Navigate to https://example.com/page
Report JSON: {url, status, title, elements[]}
"
```

**Form operation with credentials from .env**:
```bash
opencode run -m opencode/kimi-k2.5-free "
CRITICAL: Use chrome-devtools MCP tools only.
Login to https://app.example.com
Credentials: Read from .env file
- Username variable: TEST_USER
- Password variable: TEST_PASS
Report: {action: 'login', success: bool, final_url}
Note: Do NOT include actual credential values in response
"
```

**Parallel navigation**:
```bash
(opencode run -m opencode/kimi-k2.5-free "..." > /tmp/legacy.json) &
(opencode run -m opencode/kimi-k2.5-free "..." > /tmp/new.json) &
wait
# Opus compares results inline
```

## Integration

This plugin provides the generic delegation pattern. Project-specific testing skills reference the pattern and map their domain-specific variables. See `skills/browser-test-orchestration/SKILL.md` for the full protocol.

## Architecture Notes

- **MCP Context**: Uses chrome-devtools MCP (via opencode), not Chrome extension MCP (Claude Code)
- **Zero Context Isolation**: Each opencode run starts fresh with no prior session state
- **Opus Orchestrates**: Determines which .env file to use and which variables contain credentials, analyzes visual properties from text descriptions
- **Kimi Executes**: Reads credentials from .env file, runs browser operations via chrome-devtools MCP, extracts visual properties using evaluate_script, returns JSON observations (without credential values)
- **Visual Testing**: Kimi describes visual properties (colors, sizes, positions, states) as text. Opus compares these descriptions without seeing the page. Screenshots only used when text descriptions are insufficient (<10% of cases)
- **Parallelism**: Bash background jobs enable parallel navigation (requires `--isolated` flag in opencode.json)
- **Credential Security**: Credentials stay in .env files and are read by Kimi subprocess, never logged in Opus session
- **Screenshot Storage**: Optional screenshots saved to /tmp/screenshots/ for complex layout analysis (created by pre-flight checks)

## Cost Tracking

Plugin tracks "wasted calls" where opencode returned no useful data (empty page, MCP failure, timeout). This helps identify pre-flight check failures and unreliable test environments.
