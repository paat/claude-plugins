---
name: validate-experiment
description: "Run a demand-validation experiment from a plan file — build + deploy a fake-door waitlist landing page, optionally run a capped ad smoke-test, and collect MEASURED signals into a results file for the idea pipeline's confidence scoring. Usage: /validate-experiment <plan-file> [--collect]"
user_invocable: true
argument-hint: <plan-file> [--collect]
---

# /validate-experiment — Demand-Validation Experiment

You (the Team Lead) turn a demand hypothesis into a live, measured experiment: a
fake-door waitlist page and an optional capped ad smoke-test. **Confidence must come
from measured results only — never estimate, self-inflate, or fill an unmeasured metric
with a guess.** An absent metric stays `null`. This is the single statement of that rule;
`scripts/validate-experiment.sh` enforces it in the results writer.

The plugin stays generic. Which idea-pipeline consumer reads the results file is that
project's config, not this command.

## Plan file (JSON)

```json
{"idea_id":"...","value_prop":"...","audience":"...","cta":"...",
 "signup_endpoint":null,"signup_fallback":"static-host form URL",
 "cap_eur":20,"duration_days":7,"consent":"optional override wording"}
```

`signup_endpoint` posts the waitlist form; when `null`, the plan **must** name a
`signup_fallback` (a static-host-compatible form URL). Never invent hosting.

## Step 1: Validate (fail before any side effect)

```bash
S="${CLAUDE_PLUGIN_ROOT}/scripts/validate-experiment.sh"
"$S" validate "$PLAN"   # non-zero + precise error on any missing/invalid field
```

Stop and report the error if this fails — no page is built on a bad plan.

## Step 2: Fake-door leg

```bash
"$S" render "$PLAN" --out-dir docs/experiments/<idea_id>
```

Renders `docs/experiments/<idea_id>/index.html` from `templates/fake-door/`: value
prop, CTA, and a waitlist form targeting the signup endpoint/fallback. **Honesty
(Estonian SaaS):** the page never takes payment; the email field is opt-in with consent
wording. Deploy it via the **target project's existing deploy config**. If the project
configures no hosting, stop with **needs-human** — do not invent a host.

## Step 3: Ad smoke-test leg (optional)

Only when the plan asks for paid amplification. The leg **refuses without a valid,
unexpired spend envelope** (`docs/growth/envelope.json`; schema + buyer-intent rule in
`/growth`):

```bash
"$S" ad-smoke "$PLAN" --landing-url "<live experiment URL>"
```

It fails closed (non-zero + reason) when the envelope is absent, invalid, expired, lacks
the `ads` channel, or the remaining budget is below `cap_eur`. On success, delegate to
`/ads` with the experiment landing URL and `cap_eur` — spend stays inside the envelope's
caps; anything beyond them remains an owner carve-out.

## Step 4: Collect measured results

After `duration_days`, or on `--collect`, gather the real signals your deploy/analytics
target recorded into a signals JSON (`{"visits":N,"signups":N,"ad_spend_eur":N}`; omit
any metric you did not measure), then:

```bash
"$S" results "$PLAN" --signals <signals.json> \
  --out .startup/demand/experiments/<idea_id>-results.json
```

The writer emits `{idea_id, generated_at, duration_days, cap_eur, evidence:"measured-only",
measured:{visits, signups, ad_spend_eur, conversion}}` — any unmeasured metric is `null`;
`conversion` is `signups/visits` only when both are measured, else `null`.

## Step 5: Report (English)

Summarize: plan validated, page rendered + deploy status (live URL or needs-human),
ad-smoke authorized/refused (+ reason), and the results-file path. The idea pipeline
reads `.startup/demand/experiments/<idea_id>-results.json` for confidence scoring.
