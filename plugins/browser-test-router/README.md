# browser-test-router

Multi-model delegation plugin for browser testing. Routes mechanical browser work to Kimi K2.5 (via opencode CLI), saving 40-55% tokens on browser-heavy testing sessions.

## Problem

Claude Max subscriptions deplete quickly when Opus handles everything — including zero-reasoning browser work like navigation and form filling.

## Solution

Delegate mechanical browser operations to Kimi K2.5 (open-weight model) via opencode CLI:

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
         "command": ["npx", "-y", "chrome-devtools-mcp@latest"]
       }
     }
   }
   ```

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
- **Opus Orchestrates**: Determines which .env file to use and which variables contain credentials
- **Kimi Executes**: Reads credentials from .env file, runs browser operations via chrome-devtools MCP, returns JSON observations (without credential values)
- **Parallelism**: Bash background jobs enable parallel navigation (similar to parallel Task calls)
- **Credential Security**: Credentials stay in .env files and are read by Kimi subprocess, never logged in Opus session

## Cost Tracking

Plugin tracks "wasted calls" where opencode returned no useful data (empty page, MCP failure, timeout). This helps identify pre-flight check failures and unreliable test environments.
