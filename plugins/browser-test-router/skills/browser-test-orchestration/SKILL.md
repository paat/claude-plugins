---
name: browser-test-orchestration
description: Multi-model delegation protocol for browser testing — Haiku for mechanics, Sonnet for comparison, Opus for analysis
---

# Browser Test Orchestration

Delegation protocol that routes browser testing work to the cheapest capable model. Opus orchestrates, Haiku executes mechanical operations, Sonnet compares pages.

**Token savings**: 45-60% reduction on browser-heavy testing sessions by offloading zero-reasoning work to Haiku (15x cheaper) and moderate-reasoning work to Sonnet (5x cheaper).

---

## Pre-flight (before any delegation)

Run these checks before delegating ANY work. Abort on failure.

### Step 1: Verify Chrome Extension MCP

Check if Chrome extension MCP tools are available in this session. Test by attempting a simple tool call (e.g., list tabs).

**If Chrome MCP is NOT available:**
```
CRITICAL: Chrome extension is not connected.

This plugin requires Chrome extension MCP for browser interaction.
All browser testing requires a live Chrome instance with the MCP extension.

To fix:
1. Open Chrome with the Claude MCP extension installed
2. Ensure the extension is connected to this session
3. Re-run /browser-test-router:browser-test
```
**Abort immediately. Do not fall back to curl/WebFetch.**

### Step 2: Health Check (multi-level)

Once Chrome MCP is confirmed, run health checks against the target URL(s):

| Level | Check | Method | Pass Criteria |
|-------|-------|--------|---------------|
| L1 | HTTP reachable | `curl -s -o /dev/null -w "%{http_code}" {url}` | Status 200-399 |
| L2 | Content renders | Chrome MCP: navigate to URL, check visible text length | Visible text > 20 chars |
| L3 | App functional | Chrome MCP: attempt login if credentials provided | Redirects to authenticated page |

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
| URL navigation, health checks | Haiku | Mechanical, zero reasoning, 15x cheaper | `Task(model:"haiku")` |
| Screenshots, element inventory | Haiku | Observation only, no judgment needed | `Task(model:"haiku")` |
| Form filling, button clicking | Haiku | Mechanical input, zero reasoning | `Task(model:"haiku")` |
| Login/logout session management | Haiku | Mechanical credential entry | `Task(model:"haiku")` |
| Side-by-side page comparison | Sonnet | Moderate reasoning for structural alignment, 5x cheaper | `Task(model:"sonnet")` |
| Spec parsing, test criteria extraction | Opus | Complex comprehension | Inline (main session) |
| Gap classification, severity assessment | Opus | Deep judgment needed | Inline (main session) |
| Issue drafting with implementation reqs | Opus | Architectural reasoning | Inline (main session) |
| Permission testing strategy | Opus | Security reasoning | Inline (main session) |
| Cost tracking, session summary | Opus | Synthesis | Inline (main session) |

---

## Delegation Protocol

### Navigation Delegation

When you need to navigate to a URL and observe the page:

```
Task(model:"haiku", subagent_type:"general-purpose", prompt:"
Navigate to {url}.
Report as JSON: {url, status, title, elements[], visible_text_summary, errors[]}
- elements: list every button, link, form, and table with text/selector
- visible_text_summary: first 500 chars of visible text
- errors: any load errors, missing resources, console errors
Do NOT analyze or interpret — just report raw observations.
")
```

### Form Operation Delegation

When you need to fill a form or click buttons:

```
Task(model:"haiku", subagent_type:"general-purpose", prompt:"
On {url}:
1. {action_description}
2. Fill fields: {field_name}={value}, {field_name}={value}
3. Click '{button_text}'
Report as JSON: {action, url, fields_filled[], response_code, messages[], errors[], page_state_after}
Do NOT judge whether the response is correct — just report what happened.
")
```

### Comparison Delegation

When you have two page snapshots to compare:

```
Task(model:"sonnet", subagent_type:"general-purpose", prompt:"
Compare these two page snapshots:

LEGACY (source of truth):
{legacy_snapshot_json}

NEW (being tested):
{new_snapshot_json}

Report as JSON: {legacy_url, new_url, matches[], differences[], legacy_only[], new_only[], summary}
- differences: include severity_hint (high/medium/low) but NOT final classification
- Compare: data values, columns, record counts, sorting, buttons, filters
Do NOT create issues or recommend actions — just report structural differences.
")
```

---

## Parallel Navigation Pattern

When testing two systems side-by-side, navigate both in parallel:

```
# TWO PARALLEL Task calls — both model:"haiku"

Task 1: Task(model:"haiku", prompt:"Navigate to {legacy_url}. Report JSON: {url, status, title, elements[], visible_text_summary, errors[]}")

Task 2: Task(model:"haiku", prompt:"Navigate to {new_url}. Report JSON: {url, status, title, elements[], visible_text_summary, errors[]}")

# THEN one Task call — model:"sonnet"

Task 3: Task(model:"sonnet", prompt:"Compare snapshots: {task1_result} vs {task2_result}. Report structured diff as JSON.")

# THEN inline Opus analysis of the comparison results
```

This pattern mirrors tribunal-review's parallel Bash execution — two independent operations run simultaneously, then results are synthesized.

---

## CRUD Testing Delegation

For each entity's CRUD lifecycle, split mechanical vs analytical work:

### CREATE Test

1. **Opus inline**: Design test data from spec (field values, constraints to test)
2. **Haiku Task**: Navigate to create form, inventory fields
   ```
   Task(model:"haiku", prompt:"Navigate to {create_url}. List all form fields as JSON: {fields[{name, type, required, current_value}]}")
   ```
3. **Haiku Task**: Fill form with test data, submit
   ```
   Task(model:"haiku", prompt:"On {create_url}, fill: {field1}={val1}, {field2}={val2}. Click '{submit_button}'. Report: {action, fields_filled[], response_code, messages[], errors[]}")
   ```
4. **Opus inline**: Evaluate response — was creation successful? Does it match spec expectations?

### READ Test

1. **Opus inline**: Identify columns, filters, sort expectations from spec
2. **Two parallel Haiku Tasks**: Navigate to list page in both systems
3. **Sonnet Task**: Compare the two list pages (columns, record count, data values)
4. **Opus inline**: Classify differences, assess severity

### UPDATE Test

1. **Opus inline**: Choose record and field to modify from spec
2. **Haiku Task**: Navigate to edit form, modify field, submit
3. **Haiku Task**: Navigate back to verify change persisted
4. **Opus inline**: Evaluate — did update work correctly?

### DELETE Test

1. **Opus inline**: Identify delete rules from spec (cascade, soft-delete, restrictions)
2. **Haiku Task**: Find and click delete button, report confirmation dialog
3. **Haiku Task**: Confirm or cancel delete, report result
4. **Opus inline**: Evaluate against spec rules

---

## Business Rule Testing Delegation

For each numbered rule in the spec:

1. **Opus inline**: Parse rule, design positive and negative test cases
2. **Haiku Task**: Execute positive test (violate rule → expect error)
   ```
   Task(model:"haiku", prompt:"On {url}, enter {invalid_data} that violates: '{rule_text}'. Submit. Report: {response_code, messages[], errors[]}")
   ```
3. **Haiku Task**: Execute negative test (valid input → expect success)
   ```
   Task(model:"haiku", prompt:"On {url}, enter {valid_data}. Submit. Report: {response_code, messages[], errors[]}")
   ```
4. **Opus inline**: Classify — ENFORCED / NOT ENFORCED / PARTIALLY ENFORCED

---

## Validation Rule Testing Delegation

For each field/rule row in the spec's validation table:

1. **Opus inline**: Determine invalid input for the rule type
2. **Haiku Task**: Enter invalid input, submit, report response
   ```
   Task(model:"haiku", prompt:"On {form_url}, leave '{field}' empty (or enter '{invalid_value}'). Click submit. Report: {response_code, messages[], errors[], field_highlighted: bool}")
   ```
3. **Opus inline**: Compare reported message to spec's expected message, classify result

---

## Workflow Testing Delegation

For each multi-step workflow in the spec:

1. **Opus inline**: Parse all steps, prepare test data for the full sequence
2. **Haiku Tasks** (sequential): Execute each mechanical step
   ```
   Step 1: Task(model:"haiku", prompt:"Navigate to {url}. Report page state.")
   Step 2: Task(model:"haiku", prompt:"Click '{button}'. Report response.")
   Step 3: Task(model:"haiku", prompt:"Fill {fields}. Submit. Report result.")
   ...
   ```
3. **Opus inline**: Evaluate each step's result against spec, track workflow completeness

---

## Permission Testing Delegation

For each permission level in the spec's matrix:

1. **Opus inline**: Design positive/negative test cases per role
2. **Haiku Task**: Log out current session
3. **Haiku Task**: Log in as target test account
4. **Haiku Task**: Navigate to restricted page, inventory visible elements
5. **Opus inline**: Evaluate — correct elements visible/hidden for this role?

---

## Health Check Delegation

Before testing begins, delegate service health checks to Haiku:

```
# Two parallel Haiku Tasks

Task 1: Task(model:"haiku", prompt:"
Run health check with retries:
  URL: {legacy_url}
  Max retries: 3, delay: 2s
Report: {url, status, attempt, errors[]}
")

Task 2: Task(model:"haiku", prompt:"
Run health check with retries:
  URL: {new_url}
  Also check: {backend_health_url}
  Max retries: 6, delay: 5s
Report: {url, status, attempt, errors[]}
")
```

---

## Cost Tracking

After each testing session, report model usage breakdown:

```
## Model Usage Summary

| Model | Calls | Purpose |
|-------|-------|---------|
| Haiku | {N} | Navigation ({a}), forms ({b}), health checks ({c}), login/logout ({d}) |
| Sonnet | {M} | Page comparisons ({e}) |
| Opus | inline | Spec parsing, gap classification, issue drafting, session orchestration |

Estimated token savings: ~{X}% vs all-Opus execution
- Haiku calls saved ~{Y} Opus tokens (navigation + form mechanics)
- Sonnet calls saved ~{Z} Opus tokens (page comparisons)
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

---

## Integration with Project Skills

This plugin provides the generic delegation pattern. Project-specific testing skills
(like acceptance-test) reference this pattern and map their domain-specific variables:

```
# In project's acceptance-test skill:
# "Navigate to legacy system" becomes:
Task(model:"haiku", prompt:"Navigate to ${LEGACY_URL}/#${legacy_route}. Report JSON...")

# "Navigate to new system" becomes:
Task(model:"haiku", prompt:"Navigate to ${NEW_URL}/${new_route}. Report JSON...")

# "Compare both systems" becomes:
Task(model:"sonnet", prompt:"Compare: ${legacy_snapshot} vs ${new_snapshot}. Structured diff...")
```

Project skills map their specific URLs, routes, and test accounts to this generic protocol.
