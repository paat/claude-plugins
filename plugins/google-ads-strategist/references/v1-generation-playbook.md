# Pre-Launch v1 Generation Playbook

On-demand playbook for `/ads-iterate` when no `current/` iteration exists yet. Follow steps 1–10 in order, then **STOP after `iterations/v1/hypothesis.md` for user approval** (never write `spec.md` in the same call).

## Steps 1–10 (Hypothesis Checkpoint)

1. **Seed the candidate keyword list** (no Google Ads API access), in priority order:
   - a. `buyer_modifier_keywords` + product category term from `brief.md`.
   - b. `WebFetch` of commercial landing pages in `brief.md` — extract recurring nouns and value-prop phrases from H1, H2, CTA buttons, pricing labels.
   - c. Competitor ad headlines — pull Transparency Center ads for the top 3 competitors first, then harvest terms from their RSAs.
   - d. Google Suggest via Chrome: open `google.com`, type seed term + space, capture autocomplete via `get_page_text`; repeat with commercial modifiers (`"pricing"`, `"service"`, `"hire"`, `"buy"`, `"near me"`).
   - e. Optionally Google Trends via Chrome for relative interest signal (not volume forecasting).
2. **Classify EACH candidate by buyer intent** per `buyer-intent-targeting`: drop every informational query, separate commercial investigation from transactional into different ad groups, and record classifications in a keyword table.
3. **Run the product-value gate on each ad group**: confirm the product delivers paid-worthy value that converts rather than losing to a free alternative. Record per-ad-group decisions in `iterations/v1/hypothesis.md` under `## Product-value gate`; drop failing ad groups before `spec.md` and log them under `## Dropped keywords` with reason `"product-value gate: [explanation]"`.
4. **Verify each candidate in the real SERP** via Chrome incognito — save `iterations/v1/verification/serp-<keyword>.png` or structured `serp-<keyword>.md`. Confirm commercial signals (paid ads above fold, shopping widgets, no dominant People Also Ask). Drop informational-dominant keywords and add their roots to negatives. **Mandatory: keywords without SERP evidence (`.png` or `.md`) cannot enter the spec.**
5. **Pull competitor ads** from Google Ads Transparency Center for the top 3 competitors → `iterations/v1/verification/transparency-*.md` and build the differentiation matrix per `competitor-intel`.
6. **Auto-generate the defensive branded ad group** (`AG_branded_defensive`) whenever `brand_name` is set in `brief.md` (non-negotiable):
   - Brand name + every brand variant from `brief.md` on `[exact]` match; brand + category combos on `"phrase"` match (`"<brand> service"`, `"<brand> pricing"`).
   - One RSA: H1 = `"<Brand> — Official Site"`, H2 = product category, H3 = primary CTA.
   - Final URL = official site URL + full UTM tagging; bidding = Manual CPC capped at `brand_defensive_bid_cap`.
7. **Apply UTMs to every final URL** from `brief.md`'s `final_url_template` (`{campaign_slug}`, `{iteration}=v1`, `{adgroup}=<slug>`, keeping Google's `{keyword}` ValueTrack literal). Missing UTMs fail the spec hook.
8. **Forecast sanity check BEFORE writing the hypothesis**: estimate avg CPC from SERP pressure, `daily_clicks = daily_budget / avg_CPC`, `expected_conversions/day = daily_clicks × CVR baseline`. If `daily_clicks < 10`, **STOP** and ask the user to raise budget, expand keywords, or acknowledge slow-learning mode. Write `iterations/v1/forecast.md`.
9. **Preload aggressive Day-1 negatives** in `iterations/v1/negatives.md`: full informational-modifier lists (EN + target languages) from `buyer-intent-targeting`, `brief.md` exclusions, root terms of SERP-dropped keywords, and competitor brands if excluded.
10. **Write `iterations/v1/hypothesis.md`** (`**Variable class**: keywords`, forecast summary, and target: top-3 preview position on ≥ 80% of target non-branded keywords + 100% branded coverage), then **STOP** and report proposed keywords + intent classifications, product-value gate results, competitor matrix, SERP evidence count, `AG_branded_defensive` summary, forecast, negatives count, and v1 hypothesis.

## After User Approval (Follow-Up Call)

- Write `iterations/v1/spec.md` per the approved hypothesis (all final URLs UTM-tagged, `AG_branded_defensive` included, negatives attached, extensions per ad group).
- Reconcile all dropped exploration keywords (product-value gate failures, SERP reclassification, duplicates) in a `## Dropped keywords` section at the end of `spec.md`.
- Write `iterations/v1/flags-for-investor.md` from `${CLAUDE_PLUGIN_ROOT}/templates/flags-for-investor.md`.
- Run Ad Preview Tool verification for every keyword, write `result.md`, and update symlink `ln -sfn iterations/v1 docs/ads/<campaign>/current`.
