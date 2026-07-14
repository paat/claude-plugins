---
name: market-scout
description: "Generate ranked SaaS improvement candidates from external market evidence when configured, with an internal demand-discovery fallback when browsing/source data is unavailable. Usage: /market-scout [category or source guidance]"
allowed-tools: Bash, Read, WebSearch, WebFetch
user_invocable: true
---

# /market-scout — External Demand Discovery

Run the external market-scout stage for the current SaaS category. The output feeds
`/startup`, `/growth`, `/improve`, and `/goal-deliver` when the investor has not given a
fresh task.

## Step 1: Collect Evidence

Use configured source JSON/URLs when present:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/market-scout.sh"
```

If the user supplied category/source guidance, pass it as `--category "<guidance>"` or
prepare a temporary source JSON file and pass `--source-json <file>`.

When web/research tools are available, gather legally and ethically usable public signals
before running the script:

- comparable EU/Estonian products;
- pricing and packaging gaps;
- customer-visible feature gaps;
- regulatory or compliance changes;
- public complaints/reviews/support discussions;
- search demand or content gaps when configured.

Write external evidence as JSON objects with `title`, `url`, `date`, `source_type`, and
`snippet`, then run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/market-scout.sh" \
  --source-json .startup/demand/market-sources.json
```

## Step 2: Use The Output

Read `.startup/demand/market-scout.jsonl` and `.startup/demand/market-scout-report.md`.
Each candidate includes evidence, source links, source dates, confidence, ranking scores,
acceptance criteria, non-goals, and rollout checks.

If no external evidence is configured or fetchable, the script runs internal
`demand-discovery.sh` as a fallback and the report states that limitation. Do not block on
new user feedback merely because web access is unavailable.

## Guardrails

- Convert market signals into generic customer needs; do not copy competitor-specific
  features, wording, screenshots, proprietary content, or private customer data.
- Keep project-specific names, tenant/customer data, local paths, and secrets out of public
  artifacts.
- Attach source links and dates to every externally evidenced candidate.
- Rank by customer pain, willingness to pay, urgency, evidence confidence, implementation
  complexity, and fit for Estonian small businesses, e-residents, and micro-OUs where
  relevant.
