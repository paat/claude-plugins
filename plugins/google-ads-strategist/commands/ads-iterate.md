---
name: ads-iterate
description: Run the core iteration loop — read the current iteration state, verify it, diagnose gaps, and produce the next hypothesis + spec. Delegates to the ads-strategist agent. Works for both pre-launch and post-launch loops. Usage: /ads-iterate [campaign-name]
user_invocable: true
allowed-tools: Task, Read, Glob, Bash
argument-hint: [campaign-name]
---

# /ads-iterate — Run one iteration of a campaign

This command delegates the iteration loop to the **ads-strategist** agent. The agent reads the current state, runs verification, diagnoses, and proposes the next iteration. You (the user) then confirm or redirect before the next iteration is committed.

## Step 0: Determine the campaign

If the user passed a campaign argument, use it. Otherwise, list `docs/ads/*/brief.md` and ask which campaign to iterate on. If there's only one, use it.

If no brief exists for the specified campaign, STOP and direct the user to run `/ads-brief` first.

## Step 1: Detect the loop (pre-launch or post-launch)

Check for the marker file `docs/ads/<campaign>/launched_at`:

```bash
[ -f "docs/ads/<campaign>/launched_at" ] && echo post-launch || echo pre-launch
```

- **Marker absent** → pre-launch loop
- **Marker present** → post-launch loop

The marker file is plain text with an ISO timestamp as its contents. Written either manually by the human on launch, or automatically by `/ads-metrics` on the first successful post-launch metric read.

## Step 2: Dispatch the ads-strategist

Kill any stale ads-strategist agents first:

```bash
pkill -f 'agent-type ads-strategist' 2>/dev/null || true
```

Spawn the ads-strategist via Task tool with `subagent_type: "general-purpose"`:

### For pre-launch iteration:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/ads-strategist.md` for your identity, tools, and hard rules.
>
> **Task: Run one pre-launch iteration on campaign `<campaign>`.**
>
> Load skills in this order:
> 1. `google-ads-strategist:buyer-intent-targeting`
> 2. `google-ads-strategist:iterative-campaign-design`
> 3. `google-ads-strategist:hypothesis-journaling`
> 4. `google-ads-strategist:browser-verification`
> 5. `google-ads-strategist:competitor-intel`
> 6. `google-ads-strategist:clickable-copy`
>
> Read in order:
> - `docs/ads/<campaign>/brief.md` — campaign context
> - `docs/ads/<campaign>/learnings.md` — prior patterns
> - `docs/ads/<campaign>/hypothesis-log.md` — prior iterations
> - `docs/ads/<campaign>/current/spec.md` if it exists — the active iteration
>
> **If no current iteration exists**: generate v1 — but STOP after hypothesis.md for user approval (same checkpoint discipline as v_{n+1}).
>
> **1. Seed the candidate keyword list.** You do NOT have Google Ads API access. Source candidates from, in priority order:
>    a. The `buyer_modifier_keywords` list + product category term from `brief.md`
>    b. WebFetch of the commercial landing pages listed in `brief.md` — extract recurring nouns and value-prop phrases from H1, H2, CTA buttons, pricing labels
>    c. Competitor ad headlines — run the Transparency Center pull for the top 3 competitors in brief.md first, then harvest terms from their RSAs
>    d. Google Suggest via Chrome: navigate to `google.com`, type the seed term + space, capture the autocomplete suggestions via `get_page_text`. Repeat with commercial modifiers ("pricing", "service", "hire", "buy", "near me")
>    e. Only after a-d, optionally use Google Trends via Chrome for volume signal (not forecasting — just relative interest)
>
> **2. Classify EACH candidate by buyer intent** per the `buyer-intent-targeting` skill. Drop every informational query. Separate commercial investigation from transactional into different ad groups. Record the classification in a keyword table.
>
> **3. Verify each candidate in the real SERP** via Chrome incognito — take a screenshot to `iterations/v1/verification/serp-<keyword>.png`. Confirm commercial signals (paid ads above fold, shopping widgets, absence of dominant People Also Ask). Any keyword whose SERP is informational-dominant gets dropped and added to the negatives list. **This is mandatory — keywords without a SERP screenshot cannot enter the spec.**
>
> **4. Pull competitor ads** from the Transparency Center for the top 3 competitors. Save structured matrix to `iterations/v1/verification/transparency-*.md`. Build the differentiation matrix per the `competitor-intel` skill.
>
> **5. Auto-generate the defensive branded ad group.** If `brand_name` is set in brief.md, v1 MUST include an ad group named `AG_branded_defensive` containing:
>    - Brand name on `[exact]` match
>    - Every brand variant from brief.md on `[exact]` match
>    - Brand + category combos on `"phrase"` match (e.g., `"aruannik service"`, `"aruannik pricing"`)
>    - One RSA with H1 = `"<Brand> — Official Site"`, H2 = product category, H3 = primary CTA
>    - Final URL = the official site URL from brief.md + full UTM tagging
>    - Bidding = manual CPC capped at `brand_defensive_bid_cap` from brief.md
>    This is non-negotiable when a brand exists — competitor brand-conquesting costs more than the defensive cost.
>
> **6. Apply UTMs to every final URL in the spec.** Read the `final_url_template` from brief.md and substitute `{campaign_slug}`, `{iteration}=v1`, `{adgroup}=<ad group slug>`. Keep Google's `{keyword}` ValueTrack parameter literal — Google substitutes it at click time. Every row in every ad group's keyword table gets a fully-formed final URL with UTMs. No UTMs = the hook will refuse the spec write.
>
> **7. Forecast a sanity check BEFORE writing the hypothesis.** Estimate:
>    - Average CPC from SERP competitive pressure (rough: look at competitor ad count + keyword commerciality)
>    - Daily click volume = daily_budget / avg_CPC
>    - Expected conversions/day = daily_clicks × CVR baseline
>    If daily_clicks < 10, the campaign cannot produce statistically significant signal in a reasonable window — STOP and report back asking to either raise budget, expand keywords, or acknowledge slow-learning mode.
>    Write the forecast into `iterations/v1/forecast.md` — this is part of the v1 artifact set.
>
> **8. Preload aggressive Day-1 negatives.** Write `iterations/v1/negatives.md` with:
>    - The full informational-modifier list (English + target-language variants) from `buyer-intent-targeting`
>    - Any negatives from brief.md `exclusions`
>    - Any keywords dropped in step 3 (informational-dominant SERP) with their root term
>    - Brand terms of your own competitors if the user wants to avoid competing for them
>
> **9. Write `iterations/v1/hypothesis.md`** — v1 hypothesis typically: "Initial commercial-intent targeting with a defensive branded ad group, forecast-validated budget, and aggressive day-1 negatives will produce top-3 preview position on ≥ 80% of target non-branded keywords plus 100% coverage on branded." Declare `**Variable class**: keywords`. Include the forecast summary (expected daily clicks + spend + conversions).
>
> **10. STOP.** Report the proposed keyword list (with intent classifications), competitor matrix, SERP verification count, defensive branded ad group summary, forecast sanity check results, preloaded negatives count, and the v1 hypothesis. Do NOT write `spec.md` in this call — the user approves the hypothesis first.
>
> On approval in a follow-up call: write `spec.md` per the approved hypothesis (all final URLs UTM-tagged, branded defensive AG included, negatives attached), run Ad Preview Tool verification for every keyword, write `result.md`, update the `current` symlink (`ln -sfn iterations/v1 docs/ads/<campaign>/current`).
>
> **If a current iteration exists**: verify it, diagnose, propose v_{n+1}.
> 1. Read `current/spec.md` and `current/hypothesis.md`
> 2. Run Ad Preview Tool for every keyword → compare to the current verification/ state
> 3. Diagnose any gaps per the `iterative-campaign-design` decision tree
> 4. If stop conditions are met → write `current/result.md` with "READY TO LAUNCH" and STOP
> 5. If not met → write `iterations/v_{n+1}/hypothesis.md` with ONE variable-class change, then STOP without writing spec.md yet
>
> **Do NOT write v_{n+1}/spec.md in the same call** — stop after the hypothesis is written, so the user can review and approve before the spec is produced. This is the checkpoint.
>
> After writing, report to the team lead:
> - Current iteration version
> - Whether stop conditions are met (yes/no/partial with details)
> - The proposed next hypothesis (or "READY TO LAUNCH")
> - Artifacts written (list)

### For post-launch iteration:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/ads-strategist.md`.
>
> **Task: Run one post-launch iteration on campaign `<campaign>`.**
>
> Load skills:
> 1. `google-ads-strategist:iterative-optimization`
> 2. `google-ads-strategist:hypothesis-journaling`
> 3. `google-ads-strategist:browser-verification`
> 4. `google-ads-strategist:buyer-intent-targeting`
> 5. `google-ads-strategist:clickable-copy` (if copy hypothesis)
> 6. `google-ads-strategist:competitor-intel` (if competitive pressure hypothesis)
>
> Check the wait gate first:
> - Read `current/applied_at` (plain text ISO timestamp marker file)
> - Compare to `docs/ads/<campaign>/wait_days` (default 7)
> - If gate is closed, STOP and report when it opens — do NOT attempt to write a hypothesis yet
>
> If gate is open:
> 1. Pull metrics via `browser-verification` Tool 5 (Google Ads UI)
> 2. Compare to baseline (brief.md targets) + previous iteration result.md
> 3. Run the decision tree in `iterative-optimization` to identify the dominant symptom
> 4. Write `iterations/v_{n+1}/hypothesis.md` with a single-variable change
> 5. STOP before writing spec.md — user confirms hypothesis first
>
> After writing, report:
> - Current metrics vs targets
> - Dominant symptom identified
> - Proposed next hypothesis
> - Wait gate status for next iteration

## Step 3: Present the agent's report to the user

Show the user what the agent produced and ask:

> **Next hypothesis for `<campaign>` v_{n+1}**:
>
> [summary from agent]
>
> - Approve this hypothesis? I'll delegate spec.md writing + verification next.
> - Redirect? Tell me what to change.
> - Stop here?

On approval, dispatch the agent again with:

> Write `iterations/v_{n+1}/spec.md` based on the approved hypothesis in `iterations/v_{n+1}/hypothesis.md`. Then update the `current` symlink, run verification, and write `result.md`.

## Notes

- The iteration is NEVER auto-applied to a live account. The ads-strategist is design-only. After `result.md` says "READY TO LAUNCH", the human (or `growth-hacker` from saas-startup-team) handles the actual launch.
- If the agent gets stuck (e.g., Chrome failure, auth failure, missing browser MCP), it MUST stop and report — do not let it fabricate results.
