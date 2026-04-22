---
name: iterative-optimization
description: Use when the campaign is live and real metrics exist — guides hypothesis-driven post-launch optimization with a strict wait gate, single-variable changes, and symptom → root-cause → single-hypothesis decision tree. Load before pulling metrics, before proposing any live-account change, or when diagnosing CPA / CTR / CVR / impression share problems on a running campaign.
---

# Iterative Optimization (Post-Launch Loop)

Post-launch iteration is scientific method applied to PPC. One hypothesis per iteration. Wait for statistical significance. Measure. Learn. Repeat. The enemy is "panic tuning" — changing five things at once because a number looked bad this morning.

## The Loop

```
Campaign has been live ≥ wait_days since last apply
    │
    ▼
/ads-metrics → pull current numbers, compare to baseline + previous iteration
    │
    ▼
Which stop condition?
    │        │       │
    │ met    │ not   │
    │        │ met   │
    ▼        │       ▼
DONE         │    Diagnose: what is the dominant symptom?
             │       │
             │       ▼
             │    Single-hypothesis branch (see decision tree below)
             │       │
             │       ▼
             │    Write iterations/v_{n+1}/hypothesis.md + spec.md
             │       │
             │       ▼
             │    Hand spec to human/launcher → apply → record applied_at
             │       │
             │       ▼
             │    Wait for wait_days OR M conversions
             │       │
             │       ▼
             │    /ads-metrics → did hypothesis hold?
             │       │
             │       ▼
             │    Write result.md → update hypothesis-log.md → update learnings.md
             │       │
             └───────┘
```

## The Wait Gate (non-negotiable)

Never judge a post-launch iteration before enough signal has accumulated. The `/ads-iterate` command enforces:

- **Minimum wait**: 7 days OR 30 conversions, whichever comes first
- **For bid changes**: 3 days minimum (bid signal is faster)
- **For copy A/B**: 100 impressions per variant minimum before declaring a winner
- **For budget changes**: wait for one full daily cycle before reassessing

The hook `check-wait-gate.sh` blocks new iteration specs that violate the gate. Override only with `--force-wait-override` plus a written reason in the hypothesis (e.g., "Obvious tracking breakage, no wait needed to confirm zero conversions are tracking-related not demand-related").

## The Decision Tree (symptom → root cause → hypothesis)

Diagnosis is symptom-driven. Pick the **dominant** symptom — the one whose improvement would unlock the biggest CPA/ROAS delta. Ignore minor symptoms until later iterations.

### High impressions + low CTR → **Copy problem**
- **Root causes**: undifferentiated headlines, wrong intent match, weak CTA, poor Ad Strength
- **Hypotheses to test**:
  - "Rewriting H1 to lead with [specific benefit] will lift CTR by ≥ X%"
  - "Adding a price/urgency element in description 1 will lift CTR"
  - "Pinning the brand+category headline to position 1 will stabilize CTR"
- **Never** touch bids or keywords in the same iteration

### High CTR + low CVR → **Landing page or intent mismatch**
- **Root causes**: click-bait copy that doesn't match LP, wrong LP for the keyword, LP friction (slow, confusing, no CTA above fold)
- **Hypotheses**:
  - "Switching to the `/pricing` LP for commercial-intent keywords will lift CVR"
  - "Removing the email-gate on the LP will lift CVR"
  - "Matching H1 of LP to primary ad headline will lift CVR by ≥ X%"
- **Never** rewrite ad copy in the same iteration — you'll confound LP vs copy attribution

### Low impression share + low position → **Bidding or budget**
- **Root causes**: bid too low for competitive keywords, daily budget exhausting mid-day, Ad Rank dragged down by Quality Score
- **Hypotheses**:
  - "Raising max CPC to €X on keyword group Y will raise impression share to ≥ 60%"
  - "Doubling daily budget on high-intent group will eliminate mid-day pauses"
  - "Switching bid strategy from max-clicks to tCPA-€X will stabilize position"
- **Check QS first** — if expected CTR / ad relevance / LP experience are "Below average", bid fixes are a treadmill

### High CPA on specific keywords/groups → **Negatives or match type**
- **Root causes**: broad/phrase keywords pulling irrelevant queries
- **Hypotheses**:
  - "Adding negatives [list] will drop CPA on group X by ≥ Y%"
  - "Changing match type on keyword K from phrase to [exact] will drop CPA"
- **Pull the Search Terms report first** — every negative must be justified from a real search term

### Good CTR + good CVR + still losing money → **Pricing, LP value prop, or channel fit**
- This is outside Google Ads' control. Do not optimize further — escalate to business founder / human with a growth report.

### Declining performance on previously-working campaign → **Auction pressure or seasonality**
- **First**: check Auction Insights for new competitors
- **Second**: check Google Trends for the seed keyword
- **Then** hypothesize — often the answer is "defend position with a bid increase" or "add differentiating extension against new entrant"

## Budget and blast-radius rails

These are hook-enforced, not agent-enforced:

- Bid changes > 30% from prior iteration require confirmation (`check-blast-radius.sh`)
- Pausing > 20% of keywords at once requires confirmation
- Budget increases > 50% in one iteration require confirmation
- Any change that would touch a keyword with > 30% of the campaign's spend requires confirmation

Override only with explicit justification in the hypothesis.

## Budget Depletion Handling

When the campaign hits its monthly hard cap (from brief.md `monthly_cap`):

1. **STOP all iterations immediately** — do not propose new hypotheses or spec changes
2. **Pull final metrics** via `/ads-metrics` for the period
3. **Write a budget-depletion result.md** in the current iteration:
   - Metrics at time of cap hit
   - CPA vs target
   - Which ad groups consumed the most budget (top 3)
   - Whether the campaign was profitable at the cap point
4. **Recommend one of**:
   - **Raise cap**: if CPA < target and ROAS > 1, the campaign is working — recommend a specific higher cap with projected additional conversions
   - **Reallocate**: if some ad groups are profitable and others are burning, propose pausing losers and concentrating budget
   - **Hold**: if CPA > target, the campaign needs optimization before more budget, not more budget before optimization
5. **Wait for investor decision** — do not auto-resume or auto-raise budget

The daily budget check happens in `/ads-metrics`. If `spend_this_month ≥ monthly_cap × 0.9`, flag "approaching monthly cap" in the metrics report. At `≥ 1.0`, trigger the depletion protocol above.

## Stop Conditions (done optimizing)

Declare the campaign done when any of these hold:

1. **Target met**: CPA ≤ target for N consecutive days AND impression share ≥ 60%
2. **Diminishing returns**: Last 3 iterations each produced < 5% improvement on the primary metric
3. **Budget exhausted**: Daily budget cap reached consistently; further optimization needs more money, not more iteration
4. **Channel unfit**: After 5+ iterations, fundamentals (CPA vs LTV, niche demand) make the channel uneconomic — escalate, do not keep iterating

At stop, run `/ads-distill` to roll `hypothesis-log.md` into `learnings.md` and promote patterns to project memory.

## Cross-campaign learnings

Patterns that hold across ≥ 2 campaigns graduate from `learnings.md` to the project auto-memory. Examples worth graduating:
- "This advertiser's audience converts on urgency-framed headlines, not feature-framed"
- "Mobile CVR is systematically 40% of desktop CVR across all campaigns → default -40% mobile bid"
- "Competitor X always outbids on brand + category keywords → defensive campaign required"
- "LP variant with testimonial above fold consistently beats hero-image variant"

Single-campaign quirks stay in `learnings.md` — do not pollute project memory with campaign-specific trivia.

## Related Skills

- `hypothesis-journaling` — how to write falsifiable post-launch hypotheses
- `browser-verification` — for reading metrics from the Google Ads UI when the API is not available
- `clickable-copy` — copy formulas for the rewrite-copy branch
- `iterative-campaign-design` — if optimization reveals a fundamental design flaw, branch back to pre-launch discipline
