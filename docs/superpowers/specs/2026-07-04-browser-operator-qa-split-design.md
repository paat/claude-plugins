# Browser Operator / QA Orchestrator Split — Design

**Date:** 2026-07-04
**Plugin:** saas-startup-team
**Status:** Approved, implementation in progress

## Problem

`business-founder` and `ux-tester` are both `model: opus` and both carry the full
Playwright toolbelt. Each does two jobs at Opus rates:

1. **Mechanical browser driving** — navigate, click, fill forms, resize, wait,
   retry, extract computed styles. No judgment.
2. **QA judgment** — is this a defect, what severity, does field↔step semantics
   hold, does the rendered element look placed or pasted.

This is expensive (token cost), slow, and duplicated across the two agents.
**Quality is priority #1** — cost/speed/dedup wins must come entirely from
offloading judgment-free work, never from cutting corners on judging.

## Principle

**No judgment call ever happens on the cheap model.** The operator drives and
gathers; every "is this a defect / what severity / does this look right" verdict
stays on Opus.

## Seam (chosen: Seam B — orchestrator plans and judges live)

The Opus orchestrator (`business-founder` or `ux-tester`) owns the test plan and
the browser for judgment moments. It hands the operator self-contained mechanical
errands and takes the wheel itself for visual-judgment captures.

This works with **zero session-sharing plumbing** because the Playwright MCP
(`.mcp.json`: `npx @playwright/mcp`) is a single stdio process holding **one**
browser context for the whole Claude Code session. Claude Code subagents inherit
the parent session's MCP tools and share its server connection, so an inherited
stdio Playwright server preserves browser state across the parent↔subagent
handoff. When the operator subagent returns, the browser is still in the state it
left it in — the orchestrator takes its own screenshot with no handoff.

This is a Claude-internals assumption, so **implementation step 1 is a smoke
test**: operator navigates → returns → parent confirms the same URL without
re-navigating. If it fails, fall back to Seam A.

Rejected: **Seam A** (operator runs the whole session, Opus reviews a bundle) —
puts capture-timing, a quality decision, on the cheap model.

## Components

Two thin agent files sharing one skill (mirrors the `tech-founder-claude`
variant pattern — model differs, brain is shared):

- **`agents/browser-operator.md`** — `model: haiku`, explicit driving+extraction
  tool allowlist (see below), never a `mcp__...__*` wildcard. Default operator.
- **`agents/browser-operator-pro.md`** — identical, `model: sonnet`. Escalation
  operator, spawned by orchestrator judgment for a fiddly leg.

**Operator tool allowlist** (explicit, not wildcard): `browser_navigate`,
`browser_navigate_back`, `browser_snapshot`, `browser_click`, `browser_type`,
`browser_fill_form`, `browser_select_option`, `browser_hover`, `browser_press_key`,
`browser_resize`, `browser_wait_for`, `browser_evaluate` (needed for computed-style
extraction), `browser_console_messages`, `browser_network_requests`,
`browser_take_screenshot`, `browser_tabs`. Excludes any destructive/unsafe
capability the MCP may expose. `model:` is a **request**, not a guarantee — session
config/allowlists can override it.
- **`skills/browser-operator/SKILL.md`** — shared brain: driving playbook + the
  return contract. Both agents defer to this skill so there is no duplicated
  prompt.

The orchestrator selects the tier by `subagent_type` (`browser-operator` vs
`browser-operator-pro`) — no per-call model override, portable across hosts.

## Return contract — the actual quality safeguard

The operator is **forbidden from returning conclusions.** No "done", "looks
good", "success", no severity, no defect calls. It returns only *raw verifiable
state* for the leg it ran:

- final URL
- **raw network request list** for the leg (from `browser_network_requests`) — the
  operator does **not** pick which request is "key" or judge its status; it dumps
  the list and Opus interprets. (In SPAs the final-URL status is meaningless, so
  operator-judged status would smuggle judgment onto the cheap model.)
- current **viewport size and active tab** — so a resize/tab-switch inside the leg
  can't silently point the parent's next screenshot at the wrong state
- `browser_snapshot` (accessibility tree) — only when the errand asks for it; for
  pure setup legs, just URL + console
- console messages
- a mechanical outcome enum: `navigated | element-not-found | form-submitted | timed-out`
- screenshot path(s) **only** when the orchestrator explicitly requested a *mechanical*
  capture; the operator never decides *when* to capture and never captures for a
  judgment or timing purpose (those are always Opus — see Delegation boundary)

The operator performs **only the actions the errand enumerates** — it must not do
unrequested cleanup, close tabs, reset viewport, or take irreversible/destructive
actions (submitting a payment, deleting data). Irreversible actions require the
errand to explicitly authorize them, and errands prefer seeded test data/accounts.

Because nothing the operator says is taken on faith, a botched leg is visible to
Opus for near-zero cost ("expected `/checkout`, got `/login?error=1`"). Reliability
comes from the interface, not the model tier — but the interface guards *evidence
integrity*, not *side effects*, which is why the enumerated-actions guardrail above
is a separate, necessary safeguard.

## Delegation boundary

**Delegated to the operator (judgment-free):** login/auth, navigation to a target
state, form filling with given data, `browser_resize`, waits/retries, repetitive
setup, deterministic data extraction (computed-style JSON, contrast numbers via
`browser_evaluate`).

**Stays on Opus (never delegated):** coherence-pass screenshots, watching the
loading→result transition in-flight, field↔step semantics, "placed or pasted"
rendered judgment, severity, sign-off. Opus captures its own evidence from the
shared browser.

## Model tier and escalation

- **Default: Haiku** (`browser-operator`). Cheapest; safe because of the raw-state
  return contract.
- **Escalation: Sonnet** (`browser-operator-pro`), spawned by **orchestrator
  judgment** — when the orchestrator expects a leg to be fiddly (multi-page
  wizard, ambiguous snapshot with many similar refs). Not a mechanical retry
  fallback; the orchestrator decides up front.

Rejected: Kimi/Minimax operator — a non-Claude external engine cannot reach the
Claude-Code-hosted Playwright singleton, which breaks the free shared session and
forces Seam A. Dropped by decision.

## Concurrency (the one hard constraint)

The shared browser is a single stateful process, so only one agent may drive it
at a time. The orchestrator needs the operator's returned state to judge, so it
blocks on the result inherently — but the operator skill states **invoke blocking,
never backgrounded** explicitly, as belt-and-suspenders against a race.

## Edits to existing agents

`business-founder.md` and `ux-tester.md` keep their Playwright tools (they still
capture judgment screenshots). Their **mechanical browser step-lists move into the
operator skill** and are replaced with: "delegate mechanical legs to
`browser-operator`; you judge the evidence it returns and the screenshots you take
yourself." Net: shorter prompts, and the browser-driving guidance duplicated
across the two agents collapses into one shared operator playbook.

## Dual-surface (Codex) note

This optimization leans on Claude Code's MCP-singleton + Task-subagent model. The
Codex surface may not share a browser session the same way. Per repo rule, this is
documented as a **host-specific difference** — the Codex manifest keeps the
current single-agent browser flow unless/until the same seam is confirmed there.

## Success criteria

- Mechanical browser legs are delegated to an operator that *requests* Haiku
  (`model: haiku`; resolved model may differ if session config overrides it), not
  Opus, in `business-founder` and `ux-tester` flows.
- Every defect/severity/sign-off verdict is still produced by Opus.
- Smoke test confirms browser state persists across the parent↔operator handoff
  (else fall back to Seam A).
- Operator calls are invoked synchronously; no two browser-driving agents run
  concurrently.
- No new session-sharing code — the split relies only on the existing MCP
  singleton.
- `business-founder.md` and `ux-tester.md` no longer duplicate mechanical
  browser-driving instructions; those live once in the operator skill.
- Both plugin surfaces evaluated; Codex difference documented.
