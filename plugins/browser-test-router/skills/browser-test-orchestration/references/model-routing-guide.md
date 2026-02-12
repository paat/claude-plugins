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

Visual property descriptions add ~60% to delegation cost vs text-only. Screenshots add more but are used sparingly (<10% of operations).

**Key insight**: Visual testing adds modest overhead while catching 90% of visual issues.

## Visual Testing Strategy

### Mental Model: Blind Guide + Sighted Assistant

**Opus = Blind person** (can't see the page directly)
**Kimi = Sighted assistant** (can see the page via chrome-devtools MCP)

### Primary: Visual Properties as Text (90% of cases)

Kimi extracts visual properties using `evaluate_script` and describes them as text:

```json
{
  "type": "button",
  "text": "Submit",
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

Opus compares these text descriptions to detect:
- ✅ CSS regressions (color, sizing changes)
- ✅ Visual error states (red borders, error indicators)
- ✅ Layout shifts (position changes)
- ✅ Button states (enabled vs disabled)
- ✅ Element visibility changes

**Cost**: Adds ~60% tokens vs text-only, but catches 90% of visual issues.

### Fallback: Screenshots (10% of cases)

Only when text descriptions are insufficient:
- Complex layout issues (columns misaligned, grid broken)
- Visual bugs hard to describe in words
- Page-wide design comparisons
- Overlapping elements (z-index issues)

**Cost**: Adds 100%+ tokens, used sparingly.

### Decision Flow

```
1. Kimi always provides visual property descriptions (text)
2. Opus analyzes text descriptions
3. If text is insufficient → Opus requests screenshot
4. Kimi captures screenshot only when explicitly asked
```

**Key principle**: Start cheap (text descriptions), escalate only when needed (screenshots).

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

For a typical browser testing session:

| Phase | Operations | Without Routing | With Routing (Text-Only) | With Visual Testing |
|-------|-----------|-----------------|--------------------------|---------------------|
| Health checks | 3-5 curl calls | Opus | Kimi K2.5 (85% saved) | Kimi K2.5 (85% saved) |
| Navigation | 10-20 page loads | Opus | Kimi K2.5 (85% saved) | Kimi K2.5 (76% saved) |
| Form operations | 5-15 form fills | Opus | Kimi K2.5 (85% saved) | Kimi K2.5 (85% saved) |
| Page comparisons | 5-10 diffs | Opus | Kimi K2.5 (85% saved) | Kimi K2.5 (77% saved) |
| Analysis & issues | 10-20 evaluations | Opus | Opus (0% saved) | Opus (0% saved) |

**Estimated overall savings:**
- Text-only delegation: 45-60% vs all-Opus
- With visual testing: 40-55% vs all-Opus (includes 60% visual overhead)

**Key insight**: Visual testing reduces savings by only 5-10 percentage points while catching 90% of visual bugs. The trade-off is strongly favorable.
