# Model Routing Guide

Reference document for multi-model delegation in browser testing workflows.

## The Problem

Claude Max subscriptions deplete tokens quickly when Opus handles everything, including
mechanical browser work that requires zero reasoning. Browser testing is particularly
expensive because navigation, form filling, and screenshot capture generate large
tool-use contexts that Opus processes at full cost.

## The Solution: Model-Appropriate Routing

Route each task to the cheapest model that can handle it correctly:

```
┌─────────────────────────────────────────────────┐
│                 OPUS (Orchestrator)              │
│  Spec parsing, test design, gap classification, │
│  severity assessment, issue drafting             │
│                                                  │
│  ┌──────────────┐    ┌───────────────────────┐   │
│  │ HAIKU Tasks  │    │   SONNET Tasks        │   │
│  │              │    │                       │   │
│  │ • Navigate   │    │ • Compare two pages   │   │
│  │ • Screenshot │    │ • Structural diff     │   │
│  │ • Fill forms │    │ • Severity hints      │   │
│  │ • Click btns │    │                       │   │
│  │ • Health chk │    │                       │   │
│  │ • Login/out  │    │                       │   │
│  └──────────────┘    └───────────────────────┘   │
│                                                  │
│  Results flow back to Opus for analysis          │
└─────────────────────────────────────────────────┘
```

## Cost Comparison

| Operation | Opus Cost | Delegated Cost | Savings |
|-----------|-----------|----------------|---------|
| Navigate URL, report elements | 1x | 0.07x (Haiku) | 93% |
| Fill form, submit, report | 1x | 0.07x (Haiku) | 93% |
| Health check with retries | 1x | 0.07x (Haiku) | 93% |
| Compare two page snapshots | 1x | 0.20x (Sonnet) | 80% |
| Analyze results, classify gaps | 1x | 1x (Opus inline) | 0% |

## When to Delegate vs Stay Inline

### Delegate to Haiku (mechanical, zero reasoning)

- Loading a URL and reporting what's on the page
- Filling form fields with provided values
- Clicking buttons and reporting the response
- Running curl commands and reporting status codes
- Logging in/out with provided credentials
- Taking screenshots
- Listing DOM elements on a page

### Delegate to Sonnet (moderate reasoning)

- Comparing two page snapshots structurally
- Identifying matching/different/missing elements between pages
- Providing severity hints for differences
- Aligning columns and data between different layouts

### Keep as Opus inline (deep reasoning)

- Reading and interpreting module specifications
- Designing test cases and choosing test data
- Classifying gaps by category and severity
- Drafting implementation-ready issues
- Making architectural judgments
- Permission testing strategy
- Deciding what to test next

## Structured JSON Contract

All delegated agents return structured JSON. This is critical for:

1. **Predictable parsing** — Opus can reliably extract results
2. **No wasted tokens** — agents don't produce analysis Opus will redo
3. **Clean separation** — observations (Haiku/Sonnet) vs analysis (Opus)

### page-navigator output
```json
{"url": "", "status": 0, "title": "", "elements": [], "visible_text_summary": "", "errors": []}
```

### form-operator output
```json
{"action": "", "url": "", "fields_filled": [], "response_code": 0, "messages": [], "errors": []}
```

### page-comparator output
```json
{"legacy_url": "", "new_url": "", "matches": [], "differences": [], "legacy_only": [], "new_only": [], "summary": {}}
```

## Parallel Execution Patterns

### Pattern 1: Dual System Navigation
```
Task(haiku) → legacy page    ┐
                              ├→ Task(sonnet) → comparison → Opus analysis
Task(haiku) → new page       ┘
```

### Pattern 2: Sequential Form Operations
```
Task(haiku) → navigate → Task(haiku) → fill form → Task(haiku) → verify → Opus analysis
```

### Pattern 3: Permission Sweep
```
Task(haiku) → logout → Task(haiku) → login(role1) → Task(haiku) → check page → Opus classify
Task(haiku) → logout → Task(haiku) → login(role2) → Task(haiku) → check page → Opus classify
...
```

## Anti-Patterns

| Anti-Pattern | Why It's Wrong | Correct Approach |
|-------------|----------------|------------------|
| Haiku analyzes gaps | Haiku lacks judgment for severity | Haiku reports, Opus classifies |
| Sonnet drafts issues | Issue drafting needs architectural context | Sonnet compares, Opus drafts |
| Opus navigates URLs | 15x more expensive for zero-reasoning work | Delegate to Haiku |
| Opus fills forms | Mechanical task, no reasoning needed | Delegate to Haiku |
| Skipping delegation for "just one URL" | Adds up across a testing session | Always delegate mechanical work |
| Running without pre-flight | Chrome may not be connected | Always run pre-flight checks first |
| Using curl/WebFetch for SPA content | Returns empty `<div id="root">` | Chrome MCP renders JS — always use it for content |

## Wasted Call Tracking

A call is "wasted" when a delegated agent returns no useful data. Track and report these separately.

| Wasted Call Type | Cause | Prevention |
|-----------------|-------|------------|
| Empty page content | Chrome MCP disconnected mid-session | Re-check Chrome before each batch |
| MCP tool failure | Extension crashed or tab closed | Retry once, then abort batch |
| Timeout | Service went down during testing | L1 health check between batches |
| Login redirect | Page requires auth, session expired | Re-login before continuing |

### Cost Report Format

```
| Model | Total | Useful | Wasted | Waste Reason |
|-------|-------|--------|--------|--------------|
| Haiku | 12 | 10 | 2 | 1x empty content, 1x timeout |
| Sonnet | 3 | 3 | 0 | — |
```

Wasted Haiku calls cost ~0.07x each. Still cheap, but they add latency and noise. Pre-flight eliminates the most common waste (missing Chrome MCP).

---

## Session-Level Savings Estimate

For a typical acceptance testing session on one module:

| Phase | Operations | Without Routing | With Routing |
|-------|-----------|-----------------|--------------|
| Health checks | 3-5 curl calls | Opus | Haiku (93% saved) |
| Navigation | 10-20 page loads | Opus | Haiku (93% saved) |
| Form operations | 5-15 form fills | Opus | Haiku (93% saved) |
| Page comparisons | 5-10 diffs | Opus | Sonnet (80% saved) |
| Analysis & issues | 10-20 evaluations | Opus | Opus (0% saved) |

**Estimated overall savings: 45-60%** of total token consumption.
