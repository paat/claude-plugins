---
name: reddit-research
description: "Use to research Reddit opinions, recommendations, troubleshooting, product feedback, and real user experiences."
---

# Reddit Research via Antigravity CLI

Research any topic using Reddit by delegating web searches to Antigravity CLI (`agy`), which has
web access and can reach Reddit content that Claude's WebFetch cannot.

This skill routes to reddit-fetch's prompt templates, bounded runner contract, output
format, verification protocol, and SaaS demand-bridge rules. `/reddit-fetch` and
the `reddit-researcher` agent both read `references/protocol.md` instead of duplicating it —
read it in full before running research or filing any issue.

## Prerequisites

`agy` must be installed and signed in with a Google AI Pro/Ultra account, or `GEMINI_API_KEY` must be set, as documented in the plugin README. A GNU-compatible `timeout` command (`timeout` or macOS coreutils `gtimeout`) is also required.

`gh` (authenticated) is required if you intend to file GitHub issues from research findings.

## How It Works

1. Apply the protocol's host adapter and safe shell transport to invoke the bounded runner once.
2. Present findings using the protocol's output format.
3. Run the verification protocol in `references/protocol.md` first — never comment on or file
   an issue for a pain point without at least two independent supporting threads each verified
   via a non-Gemini source.
4. Only for pain points that passed that threshold: follow SaaS demand bridge step 2 in
   `references/protocol.md` before any comment or `gh issue create`.

Read `references/protocol.md` now for the full prompt patterns, bounded-run contract, output
format, error handling, verification protocol, and SaaS demand bridge rules.
