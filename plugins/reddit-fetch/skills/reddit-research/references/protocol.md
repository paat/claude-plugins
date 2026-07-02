# Reddit Research Protocol (canonical)

This is the single source of truth for reddit-fetch's Gemini prompting, retries, output
format, and issue-filing safeguards. The `/reddit-fetch` command and `reddit-researcher`
agent both point here instead of duplicating it — update behavior in this file only.

## Fabrication risk

Gemini CLI has genuinely fabricated thread titles, subreddits, quotes, and consensus in
production use. Treat every Gemini research result as a **directional lead, not a verified
fact**. Never present Gemini's output as confirmed Reddit content, and never let it enter an
automated pipeline (e.g. `saas-startup-team` `/maintain`) without the verification step below.

## Prompt templates

Always ask Gemini for the thread URL alongside subreddit and title — verification in the next
step depends on it.

**Basic:**
```bash
timeout 120 gemini -m gemini-3-flash-preview -p "Search Reddit for discussions about [TOPIC]. Find the most relevant and recent threads. For each thread, provide: the subreddit, thread title, full thread URL, key opinions and advice from top comments, and any consensus or disagreements. Focus on practical, experience-based insights." -o text 2>/dev/null
```

**Targeted subreddit:**
```bash
timeout 120 gemini -m gemini-3-flash-preview -p "Search r/[SUBREDDIT] for discussions about [TOPIC]. For each thread cited, include its full URL. Summarize the top threads, common recommendations, and community consensus." -o text 2>/dev/null
```

**Comparison/recommendation:**
```bash
timeout 120 gemini -m gemini-3-flash-preview -p "Search Reddit for comparisons of [X] vs [Y]. Find threads where users share real-world experience with both, and include each thread's full URL. Summarize: which one users prefer and why, common pros/cons mentioned, and any dealbreakers people report." -o text 2>/dev/null
```

**Troubleshooting:**
```bash
timeout 120 gemini -m gemini-3-flash-preview -p "Search Reddit for people who experienced [PROBLEM/ERROR]. Find threads with solutions that worked, and include each thread's full URL. Summarize: what caused the issue, which solutions were confirmed working, and any workarounds." -o text 2>/dev/null
```

Guidelines: always include "Search Reddit" explicitly; request "recent" threads when freshness
matters; name subreddits when the domain is clear (e.g. r/programming, r/selfhosted); ask for
"experience-based" or "practical" insights to filter out speculation.

## Model and timeout

- **Model**: `-m gemini-3-flash-preview`. If "model not found", fall back to `-m gemini-2.5-flash` (stable).
- **Timeout**: `timeout 120` for standard research, `timeout 180` for broad or multi-topic queries.
- **Output**: `-o text 2>/dev/null` for clean output; drop `2>/dev/null` when troubleshooting.

## Retry / fallback ladder

1. Empty or vague response → retry once with a rephrased or more specific query (narrower
   scope, explicit subreddit).
2. "Model not found" → retry with `-m gemini-2.5-flash`.
3. Still unavailable → do not block the workflow. Report the limitation and suggest
   alternatives (WebSearch, manual browsing).

## Output format

```
## Reddit Research: [Topic]

*Sourced from Reddit via Gemini CLI — directional, unverified unless noted*

### Key Findings
[Organized summary of what Reddit discussions reveal]

### Popular Recommendations
[Bullet points of common advice/recommendations]

### Common Concerns
[Issues or caveats people mention]

### Notable Threads
- r/subreddit: "[thread title]" — [URL] — [key takeaway]

### Caveats
- Gemini can fabricate thread titles, subreddits, quotes, and consensus — treat findings as
  directional leads, not verified fact, until independently checked
- Reddit opinions, even when verified, are anecdotal and may not reflect current state
```

After presenting findings, add your own analysis or synthesis — note agreements or
disagreements with the Reddit consensus.

## Error handling

| Error | Action |
|---|---|
| Empty response | Retry with more specific subreddit or rephrased query |
| Auth errors | Tell user to run `gemini` interactively to re-authenticate |
| Timeout | Increase to 180s; if still fails, narrow the search scope |
| Model not found | Fall back to `gemini-2.5-flash`. User may need `previewFeatures` in `~/.gemini/settings.json` |
| Gemini unavailable | Inform user; suggest WebSearch or manual Reddit browsing; do not block the workflow |

## Verification protocol (mandatory before `--file-issue`)

Gemini's citations are leads, not proof. Before any thread is used to justify a filed GitHub
issue:

1. Collect the thread URL(s) Gemini cited for the pain point.
2. Attempt to independently confirm each thread exists:
   - Fetch the URL with WebFetch. If `www.reddit.com` fails or is blocked, retry with the
     `old.reddit.com` equivalent (swap the host, keep the path) — it renders as plain HTML and
     is more likely to succeed.
   - If WebFetch cannot confirm it, run one narrow follow-up Gemini query asking it to fetch
     that exact URL and quote the real title and subreddit back verbatim. Only accept this as
     confirmation if the returned subreddit and title match what was originally cited — a
     Gemini response that "confirms" a thread it cannot actually fetch is worthless.
3. A pain point is **verified** only if at least one of its supporting threads resolves to a
   real, matching thread by step 2. A pain point resting solely on threads that fail
   verification is **unverified**.
4. **Hard block:** never run `--file-issue` behavior (never call `gh issue create`) for an
   unverified pain point. List unverified findings as research notes instead, explicitly
   flagged as "unverified — could not confirm this thread exists."

## SaaS demand bridge

Convert Reddit research into durable evidence before it becomes work — and never let
unverified, possibly-fabricated threads reach `saas-startup-team` `/maintain` triage.

1. Save a concise research artifact under `docs/research/reddit-<topic>.md` when the finding
   will influence requirements, positioning, or product prioritization. Mark each cited thread
   as verified or unverified.
2. File GitHub issues only for pain points that are (a) verified per the protocol above, (b)
   repeated across at least two independent threads or subreddits, and (c) objectively
   checkable as a specific piece of product work.
3. Use `gh issue create --body-file`, never inline `--body`.
4. Label issues `market-signal` and `customer-issue` unless project conventions indicate
   different labels, so `saas-startup-team` `/maintain` can triage them.
5. Do not file issues for broad positioning, legal/compliance judgment, or pricing strategy;
   route those to research notes or `docs/human-tasks.md` instead.
6. Always state plainly that Reddit — even verified Reddit — is anecdotal public evidence, not
   validated customer proof.
