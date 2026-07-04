# Browser Operator / QA Orchestrator Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split judgment-free browser driving (cheap Haiku operator) from QA judgment (Opus orchestrator) in the saas-startup-team plugin, cutting token cost/latency/duplication without moving any verdict onto the cheap model.

**Architecture:** Seam B — the Opus orchestrator (`business-founder`/`ux-tester`) owns the plan and judges live; it delegates mechanical legs to a `browser-operator` subagent that returns only raw verifiable state. The shared browser is free via the Playwright MCP stdio singleton. Design spec: `docs/superpowers/specs/2026-07-04-browser-operator-qa-split-design.md`.

**Tech Stack:** Claude Code plugin markdown (self-contained agents), Playwright MCP (`@playwright/mcp@0.0.68`).

## Global Constraints

- Markdown/prompt files, not code. "Test" = structural validation (frontmatter, tool allowlist, cross-references) plus one runtime smoke test. No pytest.
- **Agents are self-contained** — this plugin's convention (verified: ux-tester/growth-hacker/lawyer agents carry knowledge inline and never invoke a paired skill; no agent has a `Skill` tool; no hook injects skills into subagents). The operator contract therefore lives **inline in the operator agent files**, NOT in a skill the subagent cannot load.
- Operator tool allowlist is **explicit**, never a `mcp__...__*` wildcard.
- Operator returns **raw state only**, never a conclusion/verdict/severity.
- Operator is invoked **blocking**, never backgrounded; never two browser-driving agents at once.
- Version bump in ALL THREE: `plugins/saas-startup-team/.claude-plugin/plugin.json`, root `.claude-plugin/marketplace.json`, `plugins/saas-startup-team/.codex-plugin/plugin.json`: 0.73.0 → 0.74.0.
- Both surfaces evaluated: browser-operator is a Claude-Code-surface feature; Codex keeps single-agent browser flow, documented as a host-specific difference. (`.agents/plugins/marketplace.json` carries no version fields — verified no-op, no change.)
- **Run all commands from the repository root** (`/mnt/data/ai/claude-plugins`); the paths below are repo-root-relative and fail from the plugin directory.
- After creating/editing agent files, the running session must **reload plugins (restart or `/reload-plugins`)** before a new agent is spawnable — relevant to the Task 2 smoke test.

---

### Task 1: browser-operator agent (Haiku, self-contained)

The default operator: a self-contained Haiku agent with the full contract inline.

**Files:**
- Create: `plugins/saas-startup-team/agents/browser-operator.md`

**Interfaces:**
- Produces: subagent `browser-operator` (`model: haiku`), spawnable via Task `subagent_type: browser-operator`. Its body (the "OPERATOR CONTRACT" below) is reused verbatim by Task 3.

- [ ] **Step 1: Write the agent file**

````markdown
---
name: browser-operator
description: Mechanical browser driver. Executes judgment-free browser legs (navigate, auth, fill, resize, extract) handed to it by an orchestrator and returns RAW verifiable state only — never a verdict, severity, or "looks good". Not a loop participant; spawned blocking by business-founder / ux-tester.
model: haiku
color: yellow
tools: mcp__plugin_saas-startup-team_playwright__browser_navigate, mcp__plugin_saas-startup-team_playwright__browser_navigate_back, mcp__plugin_saas-startup-team_playwright__browser_snapshot, mcp__plugin_saas-startup-team_playwright__browser_click, mcp__plugin_saas-startup-team_playwright__browser_type, mcp__plugin_saas-startup-team_playwright__browser_fill_form, mcp__plugin_saas-startup-team_playwright__browser_select_option, mcp__plugin_saas-startup-team_playwright__browser_hover, mcp__plugin_saas-startup-team_playwright__browser_press_key, mcp__plugin_saas-startup-team_playwright__browser_resize, mcp__plugin_saas-startup-team_playwright__browser_wait_for, mcp__plugin_saas-startup-team_playwright__browser_evaluate, mcp__plugin_saas-startup-team_playwright__browser_console_messages, mcp__plugin_saas-startup-team_playwright__browser_network_requests, mcp__plugin_saas-startup-team_playwright__browser_take_screenshot, mcp__plugin_saas-startup-team_playwright__browser_tabs
---

# Browser Operator

<!-- OPERATOR CONTRACT (shared verbatim with browser-operator-pro) -->

You drive the browser mechanically for an Opus orchestrator (`business-founder` or `ux-tester`). You execute ONE self-contained errand and hand back evidence. The orchestrator does all judging.

## Hard rules

1. **Never return a conclusion.** No "done", "success", "looks good", "works", no severity, no defect calls, no UX opinions. If you catch yourself evaluating, stop — that is the orchestrator's job.
2. **Only the enumerated actions.** Do exactly what the errand lists. No unrequested cleanup, no closing tabs, no resetting viewport, no exploring.
3. **No irreversible actions unless the errand explicitly authorizes them** — never submit a real payment, delete data, or send real messages unless told; prefer seeded test data/accounts.
4. **You run blocking and alone.** You are the only agent touching the browser while you run. Do not spawn subagents.

## Return contract (raw state only)

Return exactly these fields for the leg you ran:

- **final URL**
- **viewport size and active tab** (so a resize/tab-switch you did can't misdirect the orchestrator's next screenshot)
- **raw network request list** (from `browser_network_requests`) — do NOT pick which request is "key" or judge its status; dump the list, the orchestrator interprets
- **console messages** (from `browser_console_messages`)
- **outcome enum**: one of `navigated | element-not-found | form-submitted | timed-out`
- **accessibility snapshot** (`browser_snapshot`) — ONLY when the errand asks for it; for pure setup legs, omit it and return just URL + console
- **screenshot path(s)** — ONLY when the errand explicitly requests a mechanical capture. You never decide *when* to capture, and never capture for a judgment or timing purpose (the orchestrator takes those itself)

## Driving playbook

- Navigate/auth/fill with `browser_navigate`, `browser_fill_form`, `browser_type`, `browser_click`, `browser_select_option`, `browser_press_key` as the errand specifies.
- Data extraction (when asked): use `browser_evaluate` to return computed styles / measurements / contrast numbers as JSON. Extraction is gathering, not judging — return the numbers, not an assessment of them.
- Responsive legs: `browser_resize` to the requested width; report the resulting viewport.
- If an element isn't found or the page times out, return the `element-not-found` / `timed-out` outcome with the current URL + console — do NOT retry indefinitely or improvise an alternate path unless the errand says so.

## Plugin issue reporting

If the plugin itself misbehaves, see `${CLAUDE_PLUGIN_ROOT}/templates/plugin-issue-reporting.md`.
````

- [ ] **Step 2: Validate structure**

Run: `grep -o 'mcp__plugin_saas-startup-team_playwright__[a-z_]*' plugins/saas-startup-team/agents/browser-operator.md | sort -u | wc -l`
Expected: `16`. Then confirm `model: haiku` present and NO `mcp__...__*` wildcard:
Run: `grep -n 'model: haiku' plugins/saas-startup-team/agents/browser-operator.md && ! grep -q 'playwright__\*\|playwright__"' plugins/saas-startup-team/agents/browser-operator.md && echo OK`
Expected: prints the model line and `OK`.

- [ ] **Step 3: Commit**

```bash
git add plugins/saas-startup-team/agents/browser-operator.md
git commit -m "feat(saas-startup-team): add browser-operator agent (haiku, raw-state contract)"
```

---

### Task 2: Smoke-test the MCP-singleton assumption (GATE)

Prove browser state persists across the parent↔operator handoff. **If this fails, STOP — the design falls back to Seam A and this plan is void.**

**Files:** none (runtime verification).

**Requires:** a live Claude Code session with the saas-startup-team plugin installed and its Playwright MCP available (a scratch/test URL is enough). If this session lacks the plugin MCP, defer this task to a session that has it — do NOT skip it.

- [ ] **Step 1: Parent navigates, records URL**

From the orchestrating session, call `mcp__plugin_saas-startup-team_playwright__browser_navigate` to `https://example.com`, then `browser_snapshot`; note the URL.

- [ ] **Step 2: Spawn operator to navigate elsewhere, blocking**

Spawn `browser-operator` (blocking) with the errand: "navigate to `https://example.org` and return the final URL only." Confirm it returns `https://example.org`.

- [ ] **Step 3: Parent re-checks state WITHOUT navigating**

Back in the parent, call `browser_snapshot` (no navigate).
- PASS: browser is on `https://example.org` — operator's state persisted into the parent. Design holds.
- FAIL: shows `https://example.com` or a blank/fresh context — singleton assumption false. STOP, escalate to the user, do not proceed to Task 3.

- [ ] **Step 4: Record the result in the spec**

Append a dated one-line smoke-test result (PASS/FAIL) to the spec's Success criteria.

```bash
git commit -am "docs(spec): record browser-operator singleton smoke-test result"
```

---

### Task 3: browser-operator-pro agent (Sonnet escalation variant)

Self-contained Sonnet twin, body identical to Task 1, spawned by orchestrator judgment for fiddly legs.

**Files:**
- Create: `plugins/saas-startup-team/agents/browser-operator-pro.md`

**Interfaces:**
- Produces: subagent `browser-operator-pro` (`model: sonnet`), same contract as `browser-operator`.

- [ ] **Step 1: Write the file** — copy `browser-operator.md` VERBATIM, then change only: `name: browser-operator-pro`, `model: sonnet`, the `description` line, and the H1 to `# Browser Operator (Pro)`. Keep the identical `tools:` allowlist and the entire OPERATOR CONTRACT body unchanged.

Frontmatter after edits:

```markdown
---
name: browser-operator-pro
description: Sonnet browser driver — same contract as browser-operator, for legs the orchestrator judges too fiddly for Haiku (multi-page wizards, ambiguous snapshots with many similar refs). Raw state only; never a verdict. Spawned blocking by business-founder / ux-tester.
model: sonnet
color: yellow
tools: mcp__plugin_saas-startup-team_playwright__browser_navigate, mcp__plugin_saas-startup-team_playwright__browser_navigate_back, mcp__plugin_saas-startup-team_playwright__browser_snapshot, mcp__plugin_saas-startup-team_playwright__browser_click, mcp__plugin_saas-startup-team_playwright__browser_type, mcp__plugin_saas-startup-team_playwright__browser_fill_form, mcp__plugin_saas-startup-team_playwright__browser_select_option, mcp__plugin_saas-startup-team_playwright__browser_hover, mcp__plugin_saas-startup-team_playwright__browser_press_key, mcp__plugin_saas-startup-team_playwright__browser_resize, mcp__plugin_saas-startup-team_playwright__browser_wait_for, mcp__plugin_saas-startup-team_playwright__browser_evaluate, mcp__plugin_saas-startup-team_playwright__browser_console_messages, mcp__plugin_saas-startup-team_playwright__browser_network_requests, mcp__plugin_saas-startup-team_playwright__browser_take_screenshot, mcp__plugin_saas-startup-team_playwright__browser_tabs
---
```

- [ ] **Step 2: Validate the two agents differ only where intended**

Run: `diff <(grep -o 'mcp__plugin_saas-startup-team_playwright__[a-z_]*' plugins/saas-startup-team/agents/browser-operator.md | sort) <(grep -o 'mcp__plugin_saas-startup-team_playwright__[a-z_]*' plugins/saas-startup-team/agents/browser-operator-pro.md | sort)`
Expected: no output (identical allowlists — the full regex is required; `mcp__[a-z_]*` collapses every name to `mcp__plugin_saas` and would miss real differences). Confirm `model: sonnet` here vs `model: haiku` in the base.

- [ ] **Step 3: Commit**

```bash
git add plugins/saas-startup-team/agents/browser-operator-pro.md
git commit -m "feat(saas-startup-team): browser-operator-pro (sonnet escalation variant)"
```

---

### Task 4: Rewire business-founder and ux-tester to delegate

Replace the mechanical browser step-lists in the two Opus agents with a short delegation block; keep their browser tools (they still take judgment screenshots) and all judgment prose. This is where the dedup + cost win lands.

**Files:**
- Modify: `plugins/saas-startup-team/agents/business-founder.md` (the "Browser Verification (MUST use Playwright — NEVER curl)" numbered list, ~lines 146-170)
- Modify: `plugins/saas-startup-team/agents/ux-tester.md` ("Track 1: Browser-Based Testing" + mechanical "Audit Workflow" steps)

**Interfaces:**
- Consumes: `browser-operator` / `browser-operator-pro` subagents.

- [ ] **Step 1: business-founder — replace mechanical steps with a delegation block**

In `business-founder.md`, replace the numbered mechanical click-by-click sequence under "Browser Verification" with the block below. KEEP the judgment content that follows it (the Coherence pass, spot-check-values rule, async paid-flow evidence) — that stays on the founder.

```markdown
**Delegate the mechanical legs, keep the judgment.** For judgment-free browser
work — logging in, navigating to a target state, filling forms with given data,
resizing, extracting computed styles — spawn the `browser-operator` subagent
**blocking** with a self-contained errand (enumerate the exact actions; it returns
raw state, never a verdict). Spawn `browser-operator-pro` instead when you judge
the leg fiddly (multi-page wizard, ambiguous snapshot). While an operator leg is
in flight, do not touch the browser yourself. You still drive the browser directly
for every capture you must *judge*: coherence-pass screenshots, the in-flight
loading→result transition, "placed or pasted" rendering. Never delegate a verdict —
the operator returns evidence, you rate it. Still NEVER use curl/wget.
```

- [ ] **Step 2: ux-tester — add `Task` tool, then the same delegation block**

`ux-tester.md` frontmatter has **no `Task` tool**, so it cannot spawn a subagent as written. Add `Task` to its `tools:` list (business-founder already has `Task` — no change there). Then, under "Track 1: Browser-Based Testing (Primary)", insert the same delegation block. Convert the mechanical steps in "Audit Workflow" (navigate, resize, fill) into operator errands in prose; KEEP extraction/judging and the entire Coherence Pass (Competency 8) on ux-tester.

- [ ] **Step 3: Validate**

Run: `grep -rn 'browser-operator' plugins/saas-startup-team/agents/business-founder.md plugins/saas-startup-team/agents/ux-tester.md`
Expected: both reference `browser-operator` and `browser-operator-pro`. Then confirm both can spawn AND still hold judgment screenshots:
Run: `grep -c 'Task' plugins/saas-startup-team/agents/ux-tester.md; grep -c 'playwright__browser_take_screenshot' plugins/saas-startup-team/agents/business-founder.md plugins/saas-startup-team/agents/ux-tester.md`
Expected: ux-tester `Task` count ≥ 1; screenshot tool present (`1`) in each.

- [ ] **Step 4: Commit**

```bash
git add plugins/saas-startup-team/agents/business-founder.md plugins/saas-startup-team/agents/ux-tester.md
git commit -m "refactor(saas-startup-team): founders delegate mechanical browser legs to operator, keep judgment"
```

---

### Task 5: Version bump, surface sync, dual-surface note

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json` (version)
- Modify: `.claude-plugin/marketplace.json` (saas-startup-team version)
- Modify: `plugins/saas-startup-team/.codex-plugin/plugin.json` (version + dual-surface note)
- Modify: `plugins/saas-startup-team/README.md` (document the operator agents in the agents list, note Codex difference)

- [ ] **Step 1: Bump all three manifests 0.73.0 → 0.74.0**

Edit the `"version"` field in each to `0.74.0`.

- [ ] **Step 2: Document the Codex host difference (README only)**

In the README, note: the `browser-operator` subagent split is a Claude-Code-surface optimization; the Codex surface retains the single-agent browser flow until the singleton seam is confirmed there. Do NOT add a JSON comment to `.codex-plugin/plugin.json` — JSON comments break parsing; use the README or a supported string manifest field only.

- [ ] **Step 3: Validate versions in sync**

Run: `grep -h '"version"' plugins/saas-startup-team/.claude-plugin/plugin.json plugins/saas-startup-team/.codex-plugin/plugin.json; grep -A2 saas-startup-team .claude-plugin/marketplace.json | grep version | head -1`
Expected: all three show `0.74.0`.

- [ ] **Step 4: Confirm the pre-push hook will pass**

Run: `git config core.hooksPath` — if `.githooks`, the pre-push hook enforces version sync; the Step 3 check already confirms it.

- [ ] **Step 5: Commit**

```bash
git add plugins/saas-startup-team/.claude-plugin/plugin.json .claude-plugin/marketplace.json plugins/saas-startup-team/.codex-plugin/plugin.json plugins/saas-startup-team/README.md
git commit -m "chore(saas-startup-team): bump to 0.74.0, sync manifests, document Codex surface difference"
```

---

## Self-Review

- **Spec coverage:** Seam B (Tasks 1-4), raw-state contract (Task 1 inline), Haiku default + Sonnet escalation (Tasks 1, 3), explicit allowlist (Tasks 1, 3), blocking/concurrency (Tasks 1, 4), delegation boundary (Task 4), smoke-test GATE (Task 2), dual-surface note + version bump (Task 5). All spec sections map.
- **Architecture correction:** the separate skill was dropped — this plugin's agents are self-contained and cannot rely on subagent skill-loading; the contract is inline in the operator agents (variant-duplicated like tech-founder-claude/codex).
- **Ordering:** operator (1) → smoke-test GATE (2) → pro variant (3) → rewire (4) → bump (5). Gate precedes the rewire that depends on the assumption.
- **Placeholder scan:** frontmatter, allowlists, the full return contract, and the delegation block are verbatim. Task 3 body is an explicit verbatim copy of Task 1's with three named frontmatter changes.
- **Consistency:** both operator agents use the identical 16-tool allowlist and the identical OPERATOR CONTRACT body; return-contract fields match the spec.
