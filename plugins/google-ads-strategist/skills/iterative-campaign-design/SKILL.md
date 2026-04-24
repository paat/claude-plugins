---
name: iterative-campaign-design
description: Use when entering the pre-launch iteration loop of a Google Ads campaign — guides hypothesis-driven, single-variable campaign design with browser verification between iterations. Load before writing any iteration spec, when entering a new campaign, or when diagnosing why a pre-launch ad is not appearing or not differentiating on target SERPs.
---

# Iterative Campaign Design (Pre-Launch Loop)

The pre-launch iteration loop exists to squeeze every wasted click out of a campaign *before* a cent is spent. No real traffic, no real money, just rapid hypothesis → Ad Preview Tool → diagnose → revise cycles.

## Prerequisite: Buyer-Intent Classification

**Before v1 is even designed**, run the `buyer-intent-targeting` skill on every candidate keyword. Drop everything informational. Route navigational to branded-only. Keep only commercial-investigation and transactional queries. This is the first filter and it is non-negotiable — content relevance is not buyer intent, and the strategist must not spend budget on queries where searchers want free help rather than a paid service.

## The Loop

```
brief.md present
    │
    ▼
Is there a current iteration?
    │       │
    │ no    │ yes
    │       │
    │       ▼
    │   Run /ads-verify on current/
    │       │
    │       ▼
    │   All stop conditions met?
    │       │        │
    │       │ yes    │ no
    │       │        │
    │       │        ▼
    │       │   Diagnose gap → one hypothesis
    │       │        │
    │       │        ▼
    │       │   Write iterations/v_{n+1}/hypothesis.md
    │       │        │
    │       │        ▼
    │       │   Write iterations/v_{n+1}/spec.md (single-variable diff from v_n)
    │       │        │
    │       │        ▼
    │       │   Update current symlink → v_{n+1}
    │       │        │
    │       │        ▼
    │       │   Verify in Ad Preview Tool → screenshots → result.md
    │       │        │
    │       │        └──── loop back ────┘
    │       ▼
    │   READY TO LAUNCH → hand off to human/launcher
    ▼
Run /ads-brief first
```

## Variable Classes (one change per iteration)

Exactly one of these may change between consecutive iterations. Anything else is `--multivariate` and requires written justification:

| Class | Examples of changes |
|---|---|
| **Keywords** | Add/remove seed keywords, split into ad groups, change match types |
| **Copy** | Rewrite headlines, rewrite descriptions, reorder pins, swap CTA |
| **Targeting** | Location radius, device split, language, audience segment |
| **Landing page** | Switch LP URL, change LP variant (A/B) |
| **Bidding** | Strategy change (max clicks → tCPA), budget level |
| **Extensions** | Sitelinks, callouts, structured snippets, price extensions |

Changing 2 variable classes at once means you cannot attribute the next result to either change — the whole point of the discipline is clean attribution.

## Stop Conditions (ready-to-launch gate)

The current iteration is ready to launch when **all** of the following are true. The `/ads-ready` command audits this checklist:

1. **Trigger coverage** — every target keyword in `spec.md` triggers the ad in the Anonymous Ad Preview Tool for the target location + device. Screenshots are in `verification/preview-<keyword>.png`.
2. **Position ≤ 3** — average position across target keywords is ≤ 3 in the preview.
3. **Copy differentiation** — for each target keyword, a real SERP capture exists in `verification/serp-<keyword>` (.png screenshot or .md structured extraction), and the ad copy shows visible differentiation from at least 80% of the competing ads visible on that SERP (headline angle, value prop, CTA, or extension mix).
4. **LP alignment** — the landing page contains the primary keyword(s) in H1/H2 or above-the-fold copy, CTA is ≤ 1 scroll away, page loads in < 3 seconds on mobile (check PageSpeed Insights).
5. **Message match** — ad copy promise matches LP first impression (same value prop, same audience framing).
6. **Budget + tracking** — `brief.md` has an approved budget line and a `tracking_configured: true` flag.
7. **Hypothesis closed** — `current/result.md` exists and states "READY" plus the reasoning.

Partial passes stay in the loop. Do not declare readiness on a subset.

## Diagnosis Patterns (for the "no" branch)

When `/ads-verify` fails the stop conditions, the diagnosis maps a symptom to a single-variable hypothesis:

| Symptom | Likely variable class | Example next hypothesis |
|---|---|---|
| Ad does not appear at all for keyword X | Keywords (match type too narrow, or keyword too exotic) | "Changing match type from [exact] to phrase will trigger the ad for X" |
| Ad appears but at position 6+ | Bidding (bid too low) OR Copy (Ad Strength poor) — check Ad Strength in Ads UI first | "Raising max CPC to €Y will move position to ≤ 3" |
| Ad appears but copy looks identical to 3+ competitors | Copy | "Rewriting H1 to lead with [specific benefit] will differentiate against competitors A/B/C" |
| Ad appears but LP feels disconnected on click | Landing page OR Copy | "Switching LP to the `/pricing` variant will improve message match for commercial-intent keywords" |
| Ad shows on desktop but not mobile | Targeting (device) | "Lowering mobile bid adjustment from -50% to 0 will restore mobile triggering" |

Never stack multiple hypotheses into one iteration. If the diagnosis suggests 3 problems, pick the one with the **highest expected impact × highest confidence** and defer the others to later iterations.

## Writing a Hypothesis

Every `hypothesis.md` must contain:

```markdown
# Iteration vN hypothesis

**Variable class**: [keywords | copy | targeting | landing-page | bidding | extensions]

**Change from v{N-1}**:
- [specific, diffable description — what exactly is different]

**Prediction**:
- [what observable outcome you expect — falsifiable, measurable in Ad Preview Tool or SERP capture]

**Reasoning**:
- [why you think this will work — link to competitor observation, learning, or principle]

**Evidence needed to confirm**:
- [exact artifacts that must land in verification/ for this to be called "held"]
```

If you cannot fill every section, you are not ready to write the iteration. Go back to diagnosis.

## Branching and Backtracking

If an iteration's hypothesis does not hold, do not layer another change on top. Either:

- **Revert**: Copy v_{n-1}/spec.md forward to v_{n+1}/spec.md, write a new hypothesis branching in a different direction, and note in `hypothesis-log.md` that v_n was a dead end.
- **Refine**: If partial, write v_{n+1} that narrows the same hypothesis (e.g., applied only to keyword group A where v_n did show improvement).

Do NOT pretend a failed iteration partially worked. Honest logs compound into useful learnings; dishonest ones poison future decisions.

## Cross-Language Campaigns

For multilingual products, each iteration has per-language subfolders (`et/`, `en/`, `ru/`, etc.). Each language runs its own pre-launch loop independently — different keywords, different copy, different competitors. Hypotheses for one language DO NOT automatically apply to others. Track them as separate lines in `hypothesis-log.md`, tagged with language.

## What NOT to do

- Do not write v1 that is "everything we might want" — v1 is a minimal single-ad-group starting point
- Do not skip verification because "the copy looks obviously good" — you are not the target audience, the SERP is
- Do not write iterations in parallel folders ("v2a", "v2b") as a shortcut to testing two hypotheses at once — run them sequentially
- Do not promote an iteration to READY without the `verification/` folder populated
- Do not graduate learnings (`learnings.md`) before there is a pattern across ≥ 3 iterations or ≥ 2 campaigns

## Related Skills

- `hypothesis-journaling` — how to write the hypothesis file and keep the log clean
- `browser-verification` — the exact Chrome playbook for Ad Preview Tool + SERP captures
- `competitor-intel` — Transparency Center workflow for diagnosing the "identical to competitors" symptom
- `clickable-copy` — copy formulas and Quality Score alignment for the rewrite-copy hypothesis path
