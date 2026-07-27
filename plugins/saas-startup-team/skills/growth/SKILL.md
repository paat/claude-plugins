---
name: growth
description: "Post-launch growth execution — channels, outreach, spend envelope, metrics. Optional Google Ads via google-ads-strategist."
---

# Growth

Host-neutral capability. Not a founder persona. Execute acquisition work allowed by
lifecycle and spend policy; no dialogue scripts, colors, model pins, or role-owned state.

## Triggers

1. `/growth` or explicit growth objective after product exists (or prelive staging only).
2. Lifecycle-gated channel work when `docs/growth/` strategy assets exist.
3. Optional **Google Ads** request when envelope + final URL allow — via
   `google-ads-strategist:ads-strategist`, not a local `/ads` command.

Non-triggers: product implementation, legal analysis, unconditional research before a product exists without a growth track request.

## Inputs

- `docs/growth/product-brief.md`, `strategy.md`, `brand/approved-voice.md`, channel logs
- `.startup/growth-lifecycle` or flags: `prelive` | `live` | `postlive` | `paused`
- `docs/growth/envelope.json` for paid spend (fail closed if missing/expired when spending)
- Spend schema and buyer-intent rules as stated in the `/growth` command (single source)

## Mutation boundary

| May write | Must not write |
|-----------|----------------|
| `docs/growth/**` channel logs, metrics, templates, pipeline, ads index lines | Product source, tests, workflow specs |
| Growth reports in task-designated handoff paths | Commits/PRs/merges; enabling Google Ads campaigns |
| `## Google Ads request` block for supervisor → ads-strategist | Designing/creating Google Ads inline |

## Outputs

- Actions taken (URLs, timestamps, counts) — not plans-only sessions when lifecycle allows execution
- Updated channel docs and metrics
- Growth report with recommendations and any Google Ads request block
- Owner authorization gates recorded when authority is missing

## Lifecycle contract

**prelive** stage only; **live** inbound/controlled first; **postlive** execute within policy;
**paused** diagnostics only.

## Spend and ads

- Never exceed `daily_cap_eur` / `monthly_cap_eur` or unlisted channels in an active envelope
- **Google Ads:** write a `## Google Ads request` (product, ICP, goals, envelope cap, brand,
  final-URL template, campaign slug). The orchestrator loads the optional
  **google-ads-strategist** plugin agent `ads-strategist` (campaigns always **PAUSED**).
  If that plugin is absent, stop with an install instruction — no inline fallback.
  There is no /ads command; growth owns the optional ads link.
NEVER design, create, or spawn Google Ads campaigns yourself.
- Meta/LinkedIn ads: within envelope via authenticated browser when available

## Metrics that matter

Paying customers, MRR, funnel, CAC, LTV:CAC (>3:1), reply rate, trial-to-paid — not vanity signups.

## References (on demand)

- `references/sales-playbook.md`
- `references/linkedin-safety.md`
- `references/cold-email.md`
- `references/competitor-poaching.md`


NEVER put a fixed checkout root such as `/workspace` in a handoff or command.
