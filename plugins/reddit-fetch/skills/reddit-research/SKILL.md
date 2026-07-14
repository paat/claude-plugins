---
name: reddit-research
description: "Use to research Reddit opinions, recommendations, troubleshooting, product feedback, and real user experiences."
---

# Reddit Research via Gemini CLI

Research any topic using Reddit by delegating web searches to Gemini CLI, which has full web
access and can fetch Reddit content that Claude's WebFetch cannot.

This skill routes to reddit-fetch's Gemini prompt templates, bounded runner contract, output
format, verification protocol, and SaaS demand-bridge rules. `/reddit-fetch` and
the `reddit-researcher` agent both read `references/protocol.md` instead of duplicating it —
read it in full before running Gemini research or filing any issue.

## Prerequisites

Gemini CLI 0.43.0+ must be installed and authenticated with `GEMINI_API_KEY` or file-backed OAuth as documented in the plugin README. A GNU-compatible `timeout` command (`timeout` or macOS coreutils `gtimeout`) is also required.

`gh` (authenticated) is required if you intend to file GitHub issues from research findings.

## How It Works

1. Apply the protocol's host adapter and safe shell transport to invoke the bounded runner once.
2. Present findings using the protocol's output format.
3. If filing issues, first run the verification protocol in `references/protocol.md` — never
   call `gh issue create` for a pain point without at least two independent supporting threads
   each verified via a non-Gemini source.

Read `references/protocol.md` now for the full prompt patterns, bounded-run contract, output
format, error handling, verification protocol, and SaaS demand bridge rules.
