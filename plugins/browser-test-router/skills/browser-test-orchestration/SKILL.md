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

## Mental Model: Blind Guide + Sighted Assistant

**Opus = Blind person** (can't see the page directly)
**Kimi = Sighted assistant** (can see the page, uses chrome-devtools MCP)

**Primary approach: Kimi describes what it sees**
- Element colors, sizes, positions, states → as TEXT
- Rich visual property descriptions (borderColor: "rgb(220, 53, 69)")
- Cheap: adds ~60% tokens vs text-only (not 100%+)
- Sufficient for 90% of visual testing

**Fallback: Screenshots only when words aren't enough**
- Complex layouts hard to describe in words
- Visual bugs that need visual evidence (misalignment, overlap)
- Page comparisons where layout differences matter
- Expensive: 100-500KB per screenshot + Opus reading time
- Use sparingly, only when Opus says "show me"

---

## Visual Property Extraction

Kimi describes visual properties using `evaluate_script` to extract computed styles:

```javascript
// JavaScript helper for visual property extraction
function describeElementVisually(selector) {
  const elem = document.querySelector(selector);
  if (!elem) return null;

  const rect = elem.getBoundingClientRect();
  const computed = window.getComputedStyle(elem);

  return {
    selector: selector,
    visual: {
      // Colors (most important for validation errors)
      color: computed.color,
      backgroundColor: computed.backgroundColor,
      borderColor: computed.borderColor,

      // Sizing
      fontSize: computed.fontSize,
      fontWeight: computed.fontWeight,
      borderWidth: computed.borderWidth,

      // Position and layout
      position: {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height)
      },

      // State
      state: {
        visible: computed.display !== 'none' && computed.visibility !== 'hidden',
        enabled: !elem.disabled && !elem.hasAttribute('aria-disabled'),
        focused: document.activeElement === elem,
        opacity: computed.opacity,
        hasError: elem.classList.contains('error') ||
                  elem.classList.contains('invalid') ||
                  elem.getAttribute('aria-invalid') === 'true'
      }
    }
  };
}
```

**IMPORTANT: Visual properties are OPTIONAL based on testing goals**

**Skip visual properties when** (most page comparisons):
- ✅ Comparing content/behavior only (text, data, functionality)
- ✅ Design is expected to be different
- ✅ Testing functional equivalence, not visual equivalence
- ✅ Verifying business logic, not UI styling

**Capture visual properties when** (visual testing scenarios):
- 🎨 Visual regression testing (CSS changes, layout verification)
- 🎨 Validation error styling (border color, error indicators)
- 🎨 Button states (enabled vs disabled appearance)
- 🎨 Accessibility testing (visual indicators, color contrast)
- 🎨 Responsive design testing (layout at different viewports)

**Use screenshots when** (rarely needed, <10% of cases):
- 🖼️ Complex layout issues (columns misaligned, grid broken)
- 🖼️ Visual bugs hard to describe ("something looks wrong")
- 🖼️ Page-wide design comparisons (before/after, variant A vs B)
- 🖼️ Overlapping elements (z-index issues)
- 🖼️ Responsive design testing (entire layout changes)

**Decision rule:** Kimi always provides text descriptions. Opus requests screenshot only if:
- Text description is insufficient to make judgment
- Visual evidence needed for bug report
- Complex layout issue suspected

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

#### Default: Content/Behavior Focus (No Visual Properties)

When comparing content/behavior (most use cases):

```bash
#!/bin/bash
URL="$1"

PROMPT="CRITICAL: Use chrome-devtools MCP tools only.

You have NO prior context. Navigate to $URL

After page loads:
1. List all buttons, links, forms, tables with their text/labels
2. Extract data from tables, lists, forms
3. Report functional states (visible, enabled, disabled)
4. DO NOT extract visual properties (colors, positions, fonts)

Report as JSON:
{
  \"url\": \"$URL\",
  \"status\": 200,
  \"title\": \"...\",
  \"elements\": [
    {\"type\": \"button\", \"text\": \"...\", \"selector\": \"...\", \"enabled\": true}
  ],
  \"data\": [...],
  \"visible_text_summary\": \"first 500 chars\",
  \"errors\": []
}

DO NOT analyze - just describe what you see."

RESULT=$(opencode run -m opencode/kimi-k2.5-free --format json "$PROMPT" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text' || echo "PARSE_FAILED")

echo "$RESULT"
```

#### Optional: Visual Testing Mode (With Visual Properties)

Only when testing visual aspects (CSS, layout, styling):

```bash
#!/bin/bash
URL="$1"

PROMPT="CRITICAL: Use chrome-devtools MCP tools only.

You have NO prior context. Navigate to $URL

After page loads, extract visual properties using evaluate_script:
1. List all buttons, links, forms, tables
2. For EACH element, extract:
   - Colors: color, backgroundColor, borderColor
   - Sizing: fontSize, fontWeight, borderWidth
   - Position: x, y, width, height (bounding box)
   - State: visible, enabled, focused, opacity, hasError

Use this JavaScript via evaluate_script:
function describeElementVisually(selector) {
  const elem = document.querySelector(selector);
  if (!elem) return null;
  const rect = elem.getBoundingClientRect();
  const computed = window.getComputedStyle(elem);
  return {
    selector: selector,
    visual: {
      color: computed.color,
      backgroundColor: computed.backgroundColor,
      borderColor: computed.borderColor,
      fontSize: computed.fontSize,
      fontWeight: computed.fontWeight,
      borderWidth: computed.borderWidth,
      position: {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height)
      },
      state: {
        visible: computed.display !== 'none' && computed.visibility !== 'hidden',
        enabled: !elem.disabled && !elem.hasAttribute('aria-disabled'),
        focused: document.activeElement === elem,
        opacity: computed.opacity,
        hasError: elem.classList.contains('error') ||
                  elem.classList.contains('invalid') ||
                  elem.getAttribute('aria-invalid') === 'true'
      }
    }
  };
}

Report as JSON:
{
  \"url\": \"$URL\",
  \"status\": 200,
  \"title\": \"...\",
  \"elements\": [
    {
      \"type\": \"button\",
      \"text\": \"...\",
      \"selector\": \"...\",
      \"visual\": {
        \"color\": \"rgb(...)\",
        \"backgroundColor\": \"rgb(...)\",
        \"borderColor\": \"rgb(...)\",
        \"fontSize\": \"16px\",
        \"fontWeight\": \"600\",
        \"borderWidth\": \"2px\",
        \"position\": {\"x\": 100, \"y\": 200, \"width\": 120, \"height\": 40},
        \"state\": {\"visible\": true, \"enabled\": true, \"focused\": false, \"opacity\": \"1\", \"hasError\": false}
      }
    }
  ],
  \"visible_text_summary\": \"first 500 chars\",
  \"errors\": []
}

DO NOT take screenshots unless I explicitly ask.
DO NOT analyze - just describe what you see."

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
URL_A="$1"
URL_B="$2"
# Could be: legacy vs new, before vs after, variant A vs B, mobile vs desktop, etc.

# Step 1: Navigate first URL with visual properties (Opus delegates to opencode)
RESULT_A=$(opencode run -m opencode/kimi-k2.5-free --format json "
CRITICAL: Use chrome-devtools MCP tools only.

You have NO prior context. Navigate to $URL_A
Extract visual properties for all buttons, forms, tables
Report JSON: {url, status, elements[{text, selector, visual{color, backgroundColor, fontSize, position{x,y,width,height}, state{}}}], data[]}
" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text')

# Step 2: Navigate second URL with visual properties (Opus delegates to opencode)
RESULT_B=$(opencode run -m opencode/kimi-k2.5-free --format json "
CRITICAL: Use chrome-devtools MCP tools only.

You have NO prior context. Navigate to $URL_B
Extract visual properties for all buttons, forms, tables
Report JSON: {url, status, elements[{text, selector, visual{color, backgroundColor, fontSize, position{x,y,width,height}, state{}}}], data[]}
" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text')

# Step 3: Opus compares visual properties INLINE (primary approach)
# Opus analyzes $RESULT_A vs $RESULT_B directly
# Example differences detected from text:
# - Submit button backgroundColor: rgb(0,123,255) → rgb(0,128,255) (shade changed)
# - Submit button position.y: 200 → 210 (moved down 10px)
# - Login form width: 400 → 350 (narrower)

# Step 4: If text comparison reveals suspicious layout issues, request screenshot:
# if [[ complex_layout_detected ]]; then
#   echo "Layout differences detected. Requesting visual evidence..."
#
#   SCREENSHOT_RESULT=$(opencode run -m opencode/kimi-k2.5-free --format json "
#   CRITICAL: Use chrome-devtools MCP tools only.
#
#   You have NO prior context. Navigate to $URL_B
#   Take screenshot: /tmp/screenshots/page-b-layout-$(date +%s).png
#   Report: {screenshot_path}
#   " 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text')
#
#   SCREENSHOT_PATH=$(echo "$SCREENSHOT_RESULT" | jq -r '.screenshot_path')
#   echo "Screenshot saved: $SCREENSHOT_PATH"
#   echo "Opus can now read this screenshot for visual analysis"
# fi
```

**Key insight**: Start with text-based visual comparison (cheap, 90% sufficient). Only request screenshot if text reveals layout issues that need visual evidence.

---

## Parallel Navigation Pattern

**REQUIRES**: chrome-devtools MCP configured with `--isolated` flag in opencode.json to enable concurrent browser instances.

When comparing two pages side-by-side, navigate both in parallel using background jobs:

```bash
#!/bin/bash
URL_A="$1"
URL_B="$2"

# Navigate first page in background
(opencode run -m opencode/kimi-k2.5-free --format json "
CRITICAL: Use chrome-devtools MCP tools only.
Navigate to $URL_A. Report JSON: {url, status, title, elements[], data[]}
" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text' > /tmp/snapshot_a.json) &
PID_A=$!

# Navigate second page in background (runs simultaneously with above)
(opencode run -m opencode/kimi-k2.5-free --format json "
CRITICAL: Use chrome-devtools MCP tools only.
Navigate to $URL_B. Report JSON: {url, status, title, elements[], data[]}
" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text' > /tmp/snapshot_b.json) &
PID_B=$!

# Wait for both to complete
wait $PID_A $PID_B

# Load results
SNAPSHOT_A=$(cat /tmp/snapshot_a.json)
SNAPSHOT_B=$(cat /tmp/snapshot_b.json)

# Opus analyzes comparison inline (no delegation)
# Compare $SNAPSHOT_A vs $SNAPSHOT_B based on user's goals...
```

**How it works**: The `--isolated` flag creates temporary browser profiles for each opencode session, allowing multiple browser instances to run simultaneously without conflicts.

---

## Screenshot Delegation (Fallback Only)

**Use screenshots sparingly** - only when text-based visual descriptions are insufficient.

### When to Request Screenshots

1. **After text comparison reveals layout issues**:
   ```
   Opus: "The form width decreased from 400px to 350px, and the submit button moved down 10px.
          These changes suggest possible layout breakage. Kimi, show me a screenshot of the new page."
   ```

2. **Complex layout issues hard to describe**:
   - Columns misaligned, grid broken
   - Overlapping elements (z-index issues)
   - Responsive design testing (entire layout changes)

3. **Visual evidence needed for bug report**:
   - To include in issue documentation
   - For visual regression testing baseline

### Screenshot Request Pattern

```bash
#!/bin/bash
URL="$1"
REASON="$2"  # Why screenshot is needed

PROMPT="CRITICAL: Use chrome-devtools MCP tools only.

You have NO prior context. Navigate to $URL

Take a screenshot because: $REASON
- Save to: /tmp/screenshots/$(date +%s)-screenshot.png

Report: {screenshot_path, viewport_size}
"

RESULT=$(opencode run -m opencode/kimi-k2.5-free --format json "$PROMPT" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text')

SCREENSHOT_PATH=$(echo "$RESULT" | jq -r '.screenshot_path')

echo "Screenshot saved: $SCREENSHOT_PATH"
echo "Opus can now read this screenshot for visual analysis"
```

**Important**: Opus must explicitly request screenshots. Kimi should NOT take screenshots by default - always prefer text-based visual descriptions.

---

## Visual Comparison Analysis (Opus as Blind Guide)

### Level 1: Text-Based Visual Analysis (Primary)

Opus analyzes visual properties from text descriptions (no screenshots needed):

```
# Example: Opus compares text descriptions

button_before = {
  "backgroundColor": "rgb(0, 123, 255)",
  "fontSize": "16px",
  "position": {"x": 100, "y": 200, "width": 120, "height": 40}
}

button_after = {
  "backgroundColor": "rgb(0, 128, 255)",
  "fontSize": "14px",
  "position": {"x": 100, "y": 210, "width": 120, "height": 40}
}

# Opus identifies differences:
differences = [
  {"property": "backgroundColor", "change": "rgb(0,123,255) → rgb(0,128,255)", "type": "color_shade"},
  {"property": "fontSize", "change": "16px → 14px", "delta": -2, "type": "sizing"},
  {"property": "y", "change": "200 → 210", "delta": 10, "type": "position"}
]

# No screenshot needed for simple property changes
```

### Level 2: Screenshot-Based Analysis (Fallback)

Only when text comparison reveals issues that need visual evidence:

```
Opus: "The form width decreased from 400px to 350px, and the submit button moved down 10px.
       These changes suggest possible layout breakage. Kimi, show me a screenshot of page B."

Kimi: Takes screenshot, saves to /tmp/screenshots/page-b-layout-1707749234.png

Opus: Reads screenshot via Read tool
      Analyzes: "The narrower form causes text wrapping in the email field label, which then
                 pushes the submit button down. This appears to be a layout issue."

Visual evidence: Screenshot confirms layout breakage from form width change
```

### Common Visual Checks (No Assumptions About Meaning)

Opus can detect these visual changes from text properties alone:

| Visual Change | Text Description | Screenshot? |
|---------------|------------------|-------------|
| Element visibility changed | visible: false, opacity: "0" | Optional |
| Border color changed | borderColor: rgb(X) → rgb(Y) | No |
| Layout shifted | multiple elements position changed | Yes (evidence) |
| Element moved | position.y: 200 → 210 | No |
| Color shade changed | backgroundColor: rgb(0,123,255) → rgb(0,128,255) | No |
| Font size changed | fontSize: "16px" → "14px" | No |

**90% of visual changes don't need screenshots** - text descriptions are sufficient!

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

## Capture Visual State After Interaction

For any interaction that causes visual changes (form submissions, clicks, hovers, etc.):

1. **Opus inline**: Determine what action to perform and what visual changes to observe
2. **Kimi via opencode**: Perform action, wait for changes, report visual state
   ```bash
   #!/bin/bash
   FORM_URL="$1"
   ACTION="$2"  # e.g., "fill field 'email' with 'test@example.com', click 'Submit'"

   PROMPT="CRITICAL: Use chrome-devtools MCP tools only.

   You have NO prior context. I am providing ALL information needed.

   Perform action on $FORM_URL:
   1. Navigate to page
   2. Perform: $ACTION
   3. Wait 2 seconds for any visual changes

   Describe the visual state of affected elements:
   - Extract computed styles: borderColor, backgroundColor, color
   - Check for new elements (messages, icons, indicators)
   - Check for state changes (error classes, aria attributes)
   - Measure positions and sizes

   Report as JSON:
   {
     \"action_performed\": \"$ACTION\",
     \"url\": \"$FORM_URL\",
     \"affected_elements\": [
       {
         \"selector\": \"...\",
         \"type\": \"...\",
         \"text\": \"...\",
         \"visual\": {
           \"borderColor\": \"rgb(...)\",
           \"backgroundColor\": \"rgb(...)\",
           \"color\": \"rgb(...)\",
           \"position\": {\"x\": 100, \"y\": 200, \"width\": 120, \"height\": 40},
           \"state\": {\"visible\": true, \"enabled\": true, \"hasError\": false}
         }
       }
     ],
     \"new_elements\": [...],
     \"visual_changes\": \"description of what changed\"
   }

   DO NOT take screenshot - describe in words what you see."

   RESULT=$(opencode run -m opencode/kimi-k2.5-free --format json "$PROMPT" 2>&1 | grep '"type":"text"' | tail -1 | jq -r '.part.text' || echo "PARSE_FAILED")

   echo "$RESULT"
   ```
3. **Opus inline**: Analyze visual state changes based on user's goals:
   - Identify what visual changes occurred (colors, visibility, new elements)
   - Compare to expected behavior (if validating against spec)
   - Determine if the interaction produced the desired visual outcome
   - Use visual evidence for bug reports, QA verification, or documentation

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
| Kimi K2.5 | {N} | Navigation ({a}), forms ({b}), comparisons ({c}), screenshots ({d}) |
| Opus | inline | Spec parsing, gap classification, issue drafting |

Estimated token savings: ~{X}% vs all-Opus execution
- Kimi calls via opencode run
- chrome-devtools MCP for browser automation
```

### Cost Impact (Visual Testing)

Visual property descriptions add ~60% tokens vs text-only. Screenshots add more but are used sparingly (<10% of operations).

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
