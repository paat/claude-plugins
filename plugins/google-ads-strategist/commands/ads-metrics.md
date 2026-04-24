---
name: ads-metrics
description: Pull current metrics for a live campaign via the Google Ads UI (Chrome). Compares to baseline + previous iteration. Post-launch only. Delegates to ads-strategist. Usage: /ads-metrics [campaign] [--range 7d|30d]
user_invocable: true
allowed-tools: Task, Read, Bash, Glob
argument-hint: [campaign] [--range 7d|30d]
---

# /ads-metrics — Pull live campaign metrics

Delegates to ads-strategist to read metrics from the Google Ads UI via Chrome. Post-launch command — requires `launched_at` to be set in brief.md.

## Step 0: Validate

Check for the launch marker file:

```bash
[ -f "docs/ads/<campaign>/launched_at" ]
```

If the marker file does not exist, ask the user:

> Campaign `<campaign>` has no launch marker (`docs/ads/<campaign>/launched_at`). Did you just launch it? If yes, I'll create the marker file with the current timestamp. If not, use `/ads-verify` for pre-launch verification.

On "yes": create the marker file with the current ISO timestamp:

```bash
date -Iseconds > "docs/ads/<campaign>/launched_at"
```

Also create the applied_at marker for the iteration currently active at launch time:

```bash
date -Iseconds > "docs/ads/<campaign>/current/applied_at"
```

## Step 1: Parse arguments

- Default range: `7d`
- If `--range 30d` is passed, use 30 days

## Step 2: Dispatch

```bash
pkill -f 'agent-type ads-strategist' 2>/dev/null || true
```

Spawn ads-strategist via Task tool:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/ads-strategist.md`.
>
> **Task: Pull metrics for campaign `<campaign>` via the Google Ads UI.**
>
> Load skill: `google-ads-strategist:browser-verification` (Tool 5 section).
>
> Steps:
> 1. `mcp__claude-in-chrome__tabs_context_mcp` to check state
> 2. Navigate to `https://ads.google.com/aw`
> 3. If not logged in, STOP and ask the user to log in manually — do not attempt auto-login
> 4. Select the correct account (match `ads_account_id` from brief.md if present)
> 5. Navigate to the campaign by name (match `campaign_id` from brief.md if present)
> 6. Set date range to <range>
> 7. Capture screenshot of the campaign overview → `iterations/<current>/verification/metrics-<date>-<range>.png`
> 8. Extract structured metrics:
>    - Impressions
>    - Clicks
>    - CTR
>    - Avg CPC
>    - Cost
>    - Conversions
>    - CPA (= cost / conversions)
>    - Conversion rate
>    - Impression share (if visible in the default view — may require column customization)
>    - Search impression share lost (budget) + (rank) if visible
> 9. For each major ad group, also capture drill-down metrics
> 10. Pull the Search Terms report (Keywords → Search terms tab)
> 11. Pull Auction Insights
> 12. Write a structured `iterations/<current>/verification/metrics-<date>.md`:
>     - Date range
>     - All metrics
>     - Delta from baseline (brief.md targets)
>     - Delta from previous iteration result.md
>     - Top 10 search terms driving spend
>     - Top 5 competitors by impression share
> 13. Identify the dominant symptom per `iterative-optimization` decision tree
>
> 14. If this is the first post-launch metrics run for this iteration (i.e., the iteration has a spec but no `applied_at` marker), write the marker:
>     ```bash
>     date -Iseconds > "docs/ads/<campaign>/current/applied_at"
>     ```
>     This starts the wait-gate clock for the next iteration.
>
> Report to team lead:
> - Current metrics
> - Deltas vs baseline + previous
> - Dominant symptom
> - Wait gate status (have we waited long enough for statistical significance since last apply?)

## Step 3: Relay the report

Show the user:

```markdown
## Metrics for <campaign> — last <range>

| Metric | Current | Baseline | Δ | Prev iter | Δ |
|--------|---------|----------|---|-----------|---|
| CTR | ... | ... | ... | ... | ... |
| CPA | ... | ... | ... | ... | ... |
| ... | ... | ... | ... | ... | ... |

**Dominant symptom**: [one-line diagnosis]
**Wait gate**: [OPEN after YYYY-MM-DD | CLOSED — wait N more days]

**Next step**: run `/ads-hypothesize` to see candidate fixes, or `/ads-iterate` to propose the next hypothesis directly.
```

## Notes

- NEVER fabricate metrics — if Chrome can't read the UI, say so and stop
- NEVER write to a live account from this command — it's read-only
- If the wait gate is CLOSED, don't even propose a hypothesis — just report and exit
