---
allowed-tools: Bash(gemini:*), Bash(gh:*), Bash(mkdir:*), WebFetch, Write, Read
description: Research any topic using Reddit via Gemini CLI
argument-hint: <topic to research on Reddit> [--file-issue] [--repo owner/name]
---

Research a topic by searching Reddit via Gemini CLI. Gemini has web access and can fetch Reddit content that Claude's WebFetch cannot.

## Instructions

The user wants to research the following topic on Reddit:

**Topic:** $ARGUMENTS

Read `${CLAUDE_PLUGIN_ROOT}/skills/reddit-research/references/protocol.md` now. It is the
canonical prompt template, retry ladder, output format, verification protocol, and SaaS
demand-bridge rules for this command — follow it exactly for every step below. Gemini has
fabricated thread titles, subreddits, quotes, and consensus in production, so treat its output
as directional, not verified.

If `$ARGUMENTS` contains `--file-issue`, treat that as an explicit request to file
maintenance-ready GitHub issues for repeated, objectively-checkable SaaS pain points — subject
to the protocol's hard block on filing from unverified threads.
If it contains `--repo owner/name`, use that repo for issue filing; otherwise resolve the
current repo with `gh repo view`.

## Steps

1. Analyze the topic and pick the matching prompt template from the protocol file (targeted
   subreddit, comparison, troubleshooting, or general).
2. Run the Gemini command from the protocol file, substituting the user's actual topic.
3. Follow the protocol's retry/fallback ladder if the response is empty or an error occurs.
4. Present the findings in the protocol's output format, including each notable thread's URL.
5. Add your own analysis or synthesis — note agreements or disagreements with the Reddit consensus.
6. **Optional SaaS demand bridge.** If `--file-issue` is present, run the protocol's
   verification step for every pain point before filing, then follow its SaaS demand bridge
   rules in full (issue labels, `gh issue create --body-file`, what to exclude). Never call
   `gh issue create` for a pain point that verification could not confirm.
