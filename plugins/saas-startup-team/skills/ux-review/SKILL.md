---
name: ux-review
description: "Independent UX review — usability, WCAG 2.2 AA, visual consistency, responsive design, design-review leg."
---

# UX Review

Host-neutral capability. Independent of the implementation worker when triggered.
Not a founder persona. No colors, dialogue scripts, model pins, or role-owned state.

## Triggers

1. `/ux-test` or explicit UX audit request with a reachable URL.
2. Pre-merge **design-review leg** when delivery/`ui-touch.sh` classifies UI.
3. Post-deploy visual smoke when maintain/delivery policy requires it.

Non-triggers: implementing fixes (deliver Build), product strategy, legal Tier A claims.

## Inputs

- Target URL; `docs/business/brief.md` and architecture for context
- Diff/pages under test for design-review; locale list when multi-locale
- `../../references/ux-review/design-review-leg.md`, severity/heuristic/WCAG refs as needed
- `../../references/triggered-saas-gates.md` (UX rows), `../../references/coherence-pass.md`

## Mutation boundary

| May write | Must not write |
|-----------|----------------|
| `docs/ux/ux-*.md` audit artifacts | Product source, tests, handoffs, workflow registry |
| Design-review verdict block for PR body when requested | Commits, merges, deploys, `active_role` |
| Screenshots under `.startup/reviews/` for evidence | Product acceptance solution-signoff (product-acceptance skill) |

## Outputs

- Severity-rated findings with concrete evidence (Critical/Major/Minor/Enhancement)
- Minimum breakpoints: 375px and 1280px; keyboard + contrast checks
- `## Design-review: PASS|FAIL` with Pages/Shots when pre-merge leg runs
- `tool-unavailable` after one fresh-session transport retry — never PASS from partial sessions

## Browser Evidence Contract

- Real uploads via `browser_file_upload`; never fabricate via `browser_evaluate`
- Literal tool output; for snapshots call `browser_snapshot` with unique
  `/tmp/saas-startup-team-snapshot-<run-id>-<checkpoint>.md` and keep the tool path only
- Missing/pending/zero browser tools → `tool-unavailable` for that leg
- Use host browser capability when available; **verdict stays here**

## Audit workflow (judgment retained)

Navigate core flows + coherence pass; triggered UX gates; styles/keyboard/forms/responsive;
code pattern scan as supplement; write `docs/ux/ux-audit.md`.

## References (on demand)

- `../../references/ux-review/design-review-leg.md`
- `../../references/ux-review/nielsen-heuristics.md`
- `../../references/ux-review/wcag-checklist.md`
- `../../references/ux-review/visual-testing.md`
- `../../references/ux-review/severity-matrix.md`

## Entrypoint (/ux-test)

Require a reachable URL. Use host browser capability when available (no pinned
unconditional Playwright MCP load). Write `docs/ux/ux-*.md`. Never implement product fixes
in this skill — file findings for deliver.

