---
name: browser-test-orchestration
description: Multi-model delegation protocol for browser testing — Kimi K2.5 (via opencode) for execution, Opus for analysis
---

# Browser Test Orchestration

Delegation protocol that routes browser testing work to open-weight models via opencode CLI. Opus orchestrates, Kimi K2.5 executes mechanical operations through chrome-devtools MCP.

**Token savings**: 40-55% reduction on browser-heavy testing sessions by offloading browser execution work to Kimi K2.5 (85% cheaper) via opencode CLI, while Opus handles analysis and orchestration.

---

## Pre-flight (before any delegation)

Run these checks before delegating ANY work. Abort on failure.

### Step 1: Verify opencode + chrome-devtools MCP

Check if opencode CLI is installed and chrome-devtools MCP is connected:

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
  echo ""
  echo "Run: opencode mcp list"
  echo "Ensure chrome-devtools MCP shows 'connected' status"
  echo ""
  echo "To configure, add to opencode.json:"
  echo '{
  "mcp": {
    "chrome-devtools": {
      "type": "local",
      "command": ["npx", "-y", "chrome-devtools-mcp@latest"]
    }
  }
}'
  exit 1
fi

echo "✓ opencode CLI found"
echo "✓ chrome-devtools MCP connected"
```

**If opencode is NOT installed or MCP is NOT connected: Abort immediately. Do not fall back to curl/WebFetch.**

**Troubleshooting**: If chrome-devtools MCP fails with "browser is already running" error:
```bash
# Clear stale browser profile lock
rm -rf /config/.cache/chrome-devtools-mcp/chrome-profile
# Then retry the operation
```

### Step 2: Health Check (multi-level)

Once opencode + chrome-devtools MCP are confirmed, run health checks against the target URL(s):

| Level | Check | Method | Pass Criteria |
|-------|-------|--------|---------------|
| L1 | HTTP reachable | `curl -s -o /dev/null -w "%{http_code}" {url}` | Status 200-399 |
| L2 | Content renders | opencode run with chrome-devtools: navigate to URL, check visible text length | Visible text > 20 chars |
| L3 | App functional | opencode run with chrome-devtools: attempt login if credentials provided | Redirects to authenticated page |

**If L1 fails:** Service is down. Abort with error.
**If L2 fails:** Page loads but renders empty (broken JS, missing assets). Report warning, continue with caution.
**If L3 fails:** App may have auth issues. Report warning, continue with limited testing.

Report health check results before proceeding:
```json
{
  "url": "{url}",
  "health": {
    "l1_http_reachable": true,
    "l1_status": 200,
    "l2_content_renders": true,
    "l2_visible_text_preview": "First 100 chars...",
    "l3_app_functional": null
  },
  "errors": []
}
```

---

## Model Routing Table

| Task | Model | Why | Delegation |
|------|-------|-----|------------|
| URL navigation, health checks | Kimi K2.5 | Superior tool handling, 15% Opus cost | Bash: `opencode run -m opencode/kimi-k2.5-free` |
| Screenshots, element inventory | Kimi K2.5 | Observation with agent swarm | Bash: `opencode run -m opencode/kimi-k2.5-free` |
| Form filling, button clicking | Kimi K2.5 | Mechanical with better reliability | Bash: `opencode run -m opencode/kimi-k2.5-free` |
| Login/logout session management | Kimi K2.5 | Session management with error recovery | Bash: `opencode run -m opencode/kimi-k2.5-free` |
| Side-by-side page comparison | Kimi K2.5 | Structural diff, 5x cheaper than Sonnet | Bash: `opencode run -m opencode/kimi-k2.5-free` |
| Spec parsing, test criteria | Opus | Complex comprehension | Inline (main session) |
| Gap classification, severity | Opus | Deep judgment | Inline (main session) |
| Issue drafting | Opus | Architectural reasoning | Inline (main session) |

---

## Delegation Protocol

**CRITICAL: Zero Context Isolation**

Each `opencode run` starts with ZERO context from the main Claude Code session.

This means Opus MUST pass ALL necessary information in the prompt:

1. **Credentials**: Path to .env file and variable names (Kimi reads credentials from file)
2. **URLs**: Full URLs with protocol (https://...), not just route names
3. **Test data**: All form field values to fill
4. **Previous results**: Complete JSON from prior opencode calls (for comparisons)
5. **Expected values**: What to verify, what should match

**Do NOT assume**:
- ❌ Session state persists between opencode run calls
- ❌ Variables from main session are available
- ❌ Browser tabs remain open
- ❌ User is already logged in
- ❌ Credentials from .env are pre-loaded

**Always pass explicitly**:
- ✅ Full URLs with protocol (https://...)
- ✅ Path to .env file and variable names for credentials
- ✅ All form data values
- ✅ Complete JSON from previous steps if needed

### Navigation Delegation

When you need to navigate to a URL and observe the page:

```bash
#!/bin/bash
URL="$1"

PROMPT="CRITICAL: Use chrome-devtools MCP tools only.

You have NO prior context. I am providing ALL information needed.

Navigate to $URL using chrome-devtools MCP.
Report as JSON: {url, status, title, elements[], visible_text_summary, errors[]}
- elements: list every button, link, form, and table with text/selector
- visible_text_summary: first 500 chars of visible text
- errors: any load errors, missing resources, console errors

Do NOT analyze or interpret — just report raw observations."

# Execute with Kimi K2.5, capture text output
# Note: --format json outputs JSONL stream, we filter for "type":"text" events
RESULT=$(opencode run -m opencode/kimi-k2.5-free --format json "$PROMPT" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text' || echo "PARSE_FAILED")

echo "$RESULT"
```

### Form Operation Delegation (with Credentials from .env)

When you need to fill a form or click buttons requiring credentials:

```bash
#!/bin/bash
# Opus determines which .env file and variables to use
URL="$1"
ENV_FILE="$2"  # e.g., ".env" or "test/.env.test"
USERNAME_VAR="$3"  # e.g., "LEGACY_TEST_USER"
PASSWORD_VAR="$4"  # e.g., "LEGACY_TEST_PASS"

PROMPT="CRITICAL: Use chrome-devtools MCP tools only.

You have NO prior context. I am providing ALL information needed.

Login to application:
- URL: $URL
- Credentials location: Read from $ENV_FILE
  - Username variable: $USERNAME_VAR
  - Password variable: $PASSWORD_VAR

Steps:
1. Read credentials from $ENV_FILE file
2. Extract values for $USERNAME_VAR and $PASSWORD_VAR
3. Navigate to $URL
4. Fill 'email' or 'username' field with the username value
5. Fill 'password' field with the password value
6. Click 'Sign In' or 'Login' button
7. Wait for redirect (expect: dashboard or home page)

Report as JSON: {action: 'login', url, env_file_read: bool, fields_filled[], final_url, success: bool, messages[], errors[], page_state_after}
Do NOT judge whether the response is correct — just report what happened.
Do NOT include actual credential values in the response."

RESULT=$(opencode run -m opencode/kimi-k2.5-free --format json "$PROMPT" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text' || echo "PARSE_FAILED")

echo "$RESULT"
```

**Security note**: Credentials remain in .env file and are read by Kimi in the subprocess. They never pass through Opus session logs.

### Comparison Delegation (Pass Complete Prior Results)

Opus must pass COMPLETE JSON from previous opencode calls:

```bash
#!/bin/bash
# Step 1: Navigate legacy (Opus delegates to opencode)
LEGACY_RESULT=$(opencode run -m opencode/kimi-k2.5-free --format json "
CRITICAL: Use chrome-devtools MCP tools only.

You have NO prior context. Navigate to https://legacy.app.com/users
Report JSON: {url, status, elements[], data[]}
" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text')

# Step 2: Navigate new (Opus delegates to opencode)
NEW_RESULT=$(opencode run -m opencode/kimi-k2.5-free --format json "
CRITICAL: Use chrome-devtools MCP tools only.

You have NO prior context. Navigate to https://new.app.com/users
Report JSON: {url, status, elements[], data[]}
" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text')

# Step 3: Option A - Opus compares INLINE (no delegation)
# Opus analyzes $LEGACY_RESULT vs $NEW_RESULT directly

# Step 3: Option B - Delegate comparison to Kimi (if complex diff)
COMPARISON=$(opencode run -m opencode/kimi-k2.5-free --format json "
You have NO prior context. I am providing COMPLETE data from two pages.

Compare these two page snapshots:

LEGACY (source of truth):
$LEGACY_RESULT

NEW (being tested):
$NEW_RESULT

Report as JSON: {legacy_url, new_url, matches[], differences[], legacy_only[], new_only[], summary}
- differences: include severity_hint (high/medium/low) but NOT final classification
- Compare: data values, columns, record counts, sorting, buttons, filters

Do NOT create issues or recommend actions — just report structural differences.
" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text')

echo "$COMPARISON"
```

**Key insight**: For simple comparisons, Opus can analyze inline without delegating. Only delegate comparison to Kimi if structural diff is complex and benefits from Kimi's reasoning.

---

## Parallel Navigation Pattern

**REQUIRES**: chrome-devtools MCP configured with `--isolated` flag in opencode.json to enable concurrent browser instances.

When testing two systems side-by-side, navigate both in parallel using background jobs:

```bash
#!/bin/bash
LEGACY_URL="$1"
NEW_URL="$2"

# Navigate legacy in background
(opencode run -m opencode/kimi-k2.5-free --format json "
CRITICAL: Use chrome-devtools MCP tools only.
Navigate to $LEGACY_URL. Report JSON: {url, status, title, elements[], data[]}
" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text' > /tmp/legacy_snapshot.json) &
PID_LEGACY=$!

# Navigate new in background (runs simultaneously with above)
(opencode run -m opencode/kimi-k2.5-free --format json "
CRITICAL: Use chrome-devtools MCP tools only.
Navigate to $NEW_URL. Report JSON: {url, status, title, elements[], data[]}
" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text' > /tmp/new_snapshot.json) &
PID_NEW=$!

# Wait for both to complete
wait $PID_LEGACY $PID_NEW

# Load results
LEGACY_SNAPSHOT=$(cat /tmp/legacy_snapshot.json)
NEW_SNAPSHOT=$(cat /tmp/new_snapshot.json)

# Opus analyzes comparison inline (no delegation)
# Compare $LEGACY_SNAPSHOT vs $NEW_SNAPSHOT and classify gaps...
```

**How it works**: The `--isolated` flag creates temporary browser profiles for each opencode session, allowing multiple browser instances to run simultaneously without conflicts.

---

## CRUD Testing Delegation

For each entity's CRUD lifecycle, split mechanical vs analytical work:

### CREATE Test

1. **Opus inline**: Design test data from spec (field values, constraints to test)
2. **Kimi via opencode**: Navigate to create form, inventory fields
   ```bash
   opencode run -m opencode/kimi-k2.5-free "
   CRITICAL: Use chrome-devtools MCP.
   Navigate to {create_url}. List all form fields as JSON: {fields[{name, type, required, current_value}]}
   "
   ```
3. **Kimi via opencode**: Fill form with test data, submit (Opus passes ALL field values)
   ```bash
   opencode run -m opencode/kimi-k2.5-free "
   CRITICAL: Use chrome-devtools MCP.
   You have NO prior context.
   On {create_url}, fill: name={val1}, reg_nr={val2}, type={val3}. Click 'Save'.
   Report: {action, fields_filled[], response_code, messages[], errors[]}
   "
   ```
4. **Opus inline**: Evaluate response — was creation successful? Does it match spec expectations?

### READ Test

1. **Opus inline**: Identify columns, filters, sort expectations from spec
2. **Two parallel Kimi calls via opencode**: Navigate to list page in both systems
3. **Opus inline or Kimi delegation**: Compare the two list pages (columns, record count, data values)
4. **Opus inline**: Classify differences, assess severity

### UPDATE Test

1. **Opus inline**: Choose record and field to modify from spec
2. **Kimi via opencode**: Navigate to edit form, modify field, submit (Opus passes all data)
3. **Kimi via opencode**: Navigate back to verify change persisted
4. **Opus inline**: Evaluate — did update work correctly?

### DELETE Test

1. **Opus inline**: Identify delete rules from spec (cascade, soft-delete, restrictions)
2. **Kimi via opencode**: Find and click delete button, report confirmation dialog
3. **Kimi via opencode**: Confirm or cancel delete, report result
4. **Opus inline**: Evaluate against spec rules

---

## Business Rule Testing Delegation

For each numbered rule in the spec:

1. **Opus inline**: Parse rule, design positive and negative test cases
2. **Kimi via opencode**: Execute positive test (violate rule → expect error)
   ```bash
   opencode run -m opencode/kimi-k2.5-free "
   CRITICAL: Use chrome-devtools MCP.
   You have NO prior context.
   On {url}, enter {invalid_data} that violates: '{rule_text}'. Submit.
   Report: {response_code, messages[], errors[]}
   "
   ```
3. **Kimi via opencode**: Execute negative test (valid input → expect success)
4. **Opus inline**: Classify — ENFORCED / NOT ENFORCED / PARTIALLY ENFORCED

---

## Validation Rule Testing Delegation

For each field/rule row in the spec's validation table:

1. **Opus inline**: Determine invalid input for the rule type
2. **Kimi via opencode**: Enter invalid input, submit, report response
   ```bash
   opencode run -m opencode/kimi-k2.5-free "
   CRITICAL: Use chrome-devtools MCP.
   You have NO prior context.
   On {form_url}, leave '{field}' empty (or enter '{invalid_value}'). Click submit.
   Report: {response_code, messages[], errors[], field_highlighted: bool}
   "
   ```
3. **Opus inline**: Compare reported message to spec's expected message, classify result

---

## Workflow Testing Delegation

For each multi-step workflow in the spec:

1. **Opus inline**: Parse all steps, prepare test data for the full sequence
2. **Kimi via opencode** (sequential): Execute each mechanical step, passing all context
   ```bash
   # Step 1
   opencode run -m opencode/kimi-k2.5-free "Navigate to {url}. Report page state."

   # Step 2 (Opus passes results from step 1)
   opencode run -m opencode/kimi-k2.5-free "Click '{button}'. Report response."

   # Step 3 (Opus passes all form data)
   opencode run -m opencode/kimi-k2.5-free "Fill fields: {all_field_values}. Submit. Report result."
   ```
3. **Opus inline**: Evaluate each step's result against spec, track workflow completeness

---

## Permission Testing Delegation

For each permission level in the spec's matrix:

1. **Opus inline**: Design positive/negative test cases per role
2. **Kimi via opencode**: Log out current session
3. **Kimi via opencode**: Log in as target test account (Opus passes credentials)
4. **Kimi via opencode**: Navigate to restricted page, inventory visible elements
5. **Opus inline**: Evaluate — correct elements visible/hidden for this role?

---

## Health Check Delegation

Before testing begins, delegate service health checks to Kimi via opencode:

```bash
# Two parallel opencode run calls

(opencode run -m opencode/kimi-k2.5-free "
CRITICAL: Use chrome-devtools MCP.
Run health check with retries:
  URL: {legacy_url}
  Max retries: 3, delay: 2s
Report: {url, status, attempt, errors[]}
" > /tmp/legacy_health.json) &

(opencode run -m opencode/kimi-k2.5-free "
CRITICAL: Use chrome-devtools MCP.
Run health check with retries:
  URL: {new_url}
  Also check: {backend_health_url}
  Max retries: 6, delay: 5s
Report: {url, status, attempt, errors[]}
" > /tmp/new_health.json) &

wait

# Opus analyzes health results inline
```

---

## Cost Tracking

After each testing session, report model usage breakdown:

```
## Model Usage Summary

| Model | Calls | Purpose |
|-------|-------|---------|
| Kimi K2.5 | {N} | Navigation ({a}), forms ({b}), comparisons ({c}) |
| Opus | inline | Spec parsing, gap classification, issue drafting |

Estimated token savings: ~{X}% vs all-Opus execution
- Kimi calls via opencode run
- chrome-devtools MCP for browser automation
```

---

## What Stays Inline (Opus Only)

These tasks require deep reasoning and MUST NOT be delegated:

- Spec parsing and test criteria extraction
- Test case design (choosing what to test, what data to use)
- Gap classification and severity assessment
- Issue drafting with implementation requirements
- Permission testing strategy design
- Session orchestration and decision-making
- Final verdict on whether a feature is working or broken
- Retrieving credentials and test data from config files
- Passing complete context to opencode run calls

---

## Integration with Project Skills

This plugin provides the generic delegation pattern. Project-specific testing skills
(like acceptance-test) reference this pattern and map their domain-specific variables:

```bash
# In project's acceptance-test skill:
# "Navigate to legacy system" becomes:
opencode run -m opencode/kimi-k2.5-free "Navigate to ${LEGACY_URL}/#${legacy_route}. Report JSON..."

# "Navigate to new system" becomes:
opencode run -m opencode/kimi-k2.5-free "Navigate to ${NEW_URL}/${new_route}. Report JSON..."

# "Compare both systems" - Opus compares inline or delegates to Kimi with full context:
opencode run -m opencode/kimi-k2.5-free "Compare: ${legacy_snapshot} vs ${new_snapshot}. Structured diff..."
```

Project skills map their specific URLs, routes, and test accounts to this generic protocol.
