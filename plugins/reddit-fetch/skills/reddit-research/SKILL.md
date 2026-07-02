---
name: reddit-research
description: "Use to research Reddit opinions, recommendations, troubleshooting, product feedback, and real user experiences."
---

# Reddit Research via Gemini CLI

Research any topic using Reddit by delegating web searches to Gemini CLI, which has full web
access and can fetch Reddit content that Claude's WebFetch cannot.

**Gemini CLI has fabricated Reddit thread titles, subreddits, quotes, and consensus in
production.** Treat every result it returns as a directional lead, not a verified fact, and
never file a GitHub issue from an unverified thread.

This skill is the canonical source for reddit-fetch's Gemini prompt templates, retry/fallback
ladder, output format, verification protocol, and SaaS demand-bridge rules. `/reddit-fetch` and
the `reddit-researcher` agent both read `references/protocol.md` instead of duplicating it —
read it in full before running Gemini research or filing any issue.

## Prerequisites

Gemini CLI must be installed (`npm install -g @google/gemini-cli`) and authenticated. Run `gemini` interactively once to complete OAuth login.

Enable preview features in `~/.gemini/settings.json` to use `gemini-3-flash-preview`:

```json
{
  "general": {
    "previewFeatures": true
  }
}
```

`gh` (authenticated) is required if you intend to file GitHub issues from research findings.

## How It Works

1. Search Reddit for the given topic via a Gemini prompt that also requests each thread's URL
   (see `references/protocol.md` for prompt templates).
2. Present structured findings, clearly labeled as directional and unverified.
3. If filing issues, first run the verification protocol in `references/protocol.md` — never
   call `gh issue create` for a pain point without at least two independent supporting threads
   each verified via a non-Gemini source.

Read `references/protocol.md` now for the full prompt patterns, model/timeout guidance, retry
ladder, output format, error handling, verification protocol, and SaaS demand bridge rules.
