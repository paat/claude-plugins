---
name: ads-metrics
description: Pull and persist current metrics for a live campaign via the Google Ads UI (Chrome). Compares to baseline + previous iteration. Post-launch only. Usage: /ads-metrics [campaign] [--range 7d|30d]
user_invocable: true
allowed-tools: Task, Read, Bash, Glob
argument-hint: [campaign] [--range 7d|30d]
---

# /ads-metrics — Pull live campaign metrics

Reads metrics from Google Ads and persists evidence under the active iteration. Use `/ads-monitor` for a zero-repository-write pass.

## Step 0: Parse and validate

- Default range: `7d`; accept only `7d` or `30d`.
- If no campaign is supplied, detect one from `docs/ads/*/brief.md`; if ambiguous, ask.
- Reject unexpected arguments.

Before any campaign path access or marker write, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-campaign-path.sh" --require-current "docs/ads/<campaign>"
```

Check `docs/ads/<campaign>/launched_at`. If absent, ask whether the campaign was just launched. On yes, create only `launched_at` with `date -Iseconds`; otherwise direct the user to `/ads-verify`. `current/applied_at` is written only after a successful metrics read in Step 1.

Then run the identity/timestamp preflight and capture its normalized IDs without `eval`:

```bash
identity="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-metrics-preflight.sh" --require-read-only "docs/ads/<campaign>")" || exit $?
ads_account_id="$(printf '%s\n' "$identity" | sed -n 's/^ads_account_id=//p')"
campaign_id="$(printf '%s\n' "$identity" | sed -n 's/^campaign_id=//p')"
```

On any diagnostic, STOP before opening Google Ads. The preflight accepts one unambiguous legacy or current identity field, rejects missing/duplicate/conflicting/malformed values, and requires `Google Ads metrics access: read-only`.

## Step 1: Dispatch

Spawn `google-ads-strategist:ads-strategist`:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/ads-strategist.md`.
>
> **Task: Pull and persist metrics for `<campaign>`.**
> Expected customer ID: `<ads_account_id>`. Expected campaign ID: `<campaign_id>`.
>
> Load `google-ads-strategist:browser-verification` (Tool 5).
>
> 1. Check Chrome state, navigate to `https://ads.google.com/aw`, and stop if login is required. Before campaign navigation, verify the signed-in user is visibly **Read only** for the expected customer ID; stop if the role is unverifiable or Standard/Admin.
> 2. Enter only the exact customer and campaign IDs above; use campaign name only as a secondary display check. Reverify both from the UI/URL and stop on mismatch.
> 3. Set the requested date range.
> 4. Capture `current/verification/metrics-<date>-<range>.png`.
> 5. Extract impressions, clicks, CTR, avg CPC, cost, conversions, CPA, conversion rate, visible impression-share/lost-share fields, major ad-group metrics, top 10 spend-driving search terms, and top 5 visible Auction Insights competitors. Mark unavailable fields; never infer them.
> 6. Write `current/verification/metrics-<date>.md` with the range, metrics, baseline/prior deltas, search terms, competitors, dominant symptom, and wait-gate status.
> 7. If this iteration has a spec but no `current/applied_at`, write the current ISO timestamp there after the successful metrics read.
>
> Do not change any live-account setting, status, budget, bid, ad, keyword, audience, conversion, or billing item.

## Step 2: Relay

Only render the metrics table and next step when the role confirms read-only access and both IDs, the required overview metrics were read, and the expected screenshot plus metrics Markdown exist under the active `current/verification/`. Read back the report and, when newly required, `current/applied_at`; a missing, empty, symlinked, or mismatched artifact is failure. If the role stopped or persistence verification fails, relay that gap only and do not render a success table or recommend iteration.

On success show current/baseline/previous deltas, dominant symptom, wait-gate status, and the next eligible `/ads-hypothesize` or `/ads-iterate` action. If the wait gate is closed, report and exit without proposing a hypothesis.

Never fabricate metrics. This workflow writes repository evidence; server-enforced Google Ads read-only access prevents live-account mutation.
