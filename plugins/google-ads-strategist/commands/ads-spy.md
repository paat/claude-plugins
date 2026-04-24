---
name: ads-spy
description: Pull all currently-running ads for a competitor from the Google Ads Transparency Center. Produces a structured competitor matrix for copy differentiation. Delegates to ads-strategist. Usage: /ads-spy <competitor-domain-or-name> [--country X]
user_invocable: true
allowed-tools: Task, Read, Write, Bash
argument-hint: <competitor-domain-or-name> [--country X]
---

# /ads-spy — Competitor ad copy intel via Transparency Center

Delegates to the ads-strategist agent to pull a competitor's ads from Google's public Transparency Center and produce a differentiation matrix.

## Step 0: Validate argument

`<competitor-domain-or-name>` is required. If missing, ask:

> Which competitor should I spy on? Give me a domain (e.g., `competitorads.com`) or an advertiser name exactly as it appears on their ads.

## Step 1: Determine campaign context

If a campaign is active (`docs/ads/<campaign>/` exists), the output goes into that campaign's current iteration `verification/` folder. Otherwise, use `docs/ads/_scratch/spy-<competitor>-<date>.md`.

## Step 2: Dispatch the agent

```bash
pkill -f 'agent-type ads-strategist' 2>/dev/null || true
```

Spawn the ads-strategist via Task tool:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/ads-strategist.md` for your identity.
>
> **Task: Competitor intel pull on `<competitor>` for country `<country>`.**
>
> Load skills:
> - `google-ads-strategist:competitor-intel`
> - `google-ads-strategist:browser-verification`
> - `google-ads-strategist:clickable-copy`
>
> Steps:
> 1. Navigate to `https://adstransparency.google.com/`
> 2. Search for the advertiser — try the domain first, then the name
> 3. Filter by country: `<country>`
> 4. Filter by format: Text (search ads only for now)
> 5. Sort by most recent
> 6. For every ad visible, extract:
>    - All headlines
>    - All descriptions
>    - Display URL
>    - Date last seen
>    - Format
> 7. Screenshot the Transparency Center view → save to `<output-dir>/transparency-<competitor>-<date>.png`
> 8. Write a structured markdown to `<output-dir>/transparency-<competitor>.md` with the full ad inventory
> 9. Build a differentiation matrix per `clickable-copy` skill — identify:
>    - Repeated headline angles (= what's working for them)
>    - Churning headlines (= they're still testing)
>    - Unused angles (= whitespace we can claim)
>    - CTA verbs in use
>    - Extension types visible
>    - Proof points used
>
> Report to the team lead:
> - Number of ads found
> - Top 3 repeated angles
> - Top 3 whitespace opportunities
> - Files written

## Step 3: Relay the report

Show the user the agent's summary plus the path to the structured matrix file.

## Notes

- Transparency Center has no API and no rate limits, but large advertisers may have hundreds of ads — if the pull exceeds 50 ads, stop at 50 and note the truncation
- If the competitor has zero ads visible, this might mean they've paused their campaigns OR the advertiser name doesn't match Google's records — try the domain and alternate spellings
- Never navigate to competitor paid URLs from the SERP — only use the Transparency Center
