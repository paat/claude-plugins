# reddit-fetch

Research any topic using Reddit via Antigravity CLI (`agy`) web search.

Claude's WebFetch often cannot access Reddit content. This plugin uses `agy`'s Google web search
for lead discovery, then requires independent verification before durable action.

## Mission Fit

`reddit-fetch` is a public-market signal plugin. It helps SaaS agents extract customer
language, pain points, alternatives, and objections from community discussions before
writing requirements, positioning, or demand-backed issue candidates.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install reddit-fetch@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in `.claude/settings.local.json`.

## Prerequisites

1. **Antigravity CLI (`agy`)** must be installed and authenticated, either signed in with a
   Google AI Pro/Ultra subscription or through a Gemini API key:
   ```bash
   curl -fsSL https://antigravity.google/cli/install.sh | bash
   agy                        # run once and complete the Google sign-in
   export GEMINI_API_KEY=...  # alternative to signing in
   ```
   A sign-in takes precedence over `GEMINI_API_KEY`.

2. **GNU-compatible timeout** must be available as `timeout` (Linux) or `gtimeout` (`brew install coreutils` on macOS).

3. **Bash 4+ and standard POSIX tools**: `awk`, `grep`, `sed`, `sort`, `wc`, `env`,
   `mkdir`, `rm`, `cp`, `chmod`, and `cat`.

4. **`gh` CLI**, authenticated (`gh auth status`), required by `--file-issue`.

> **Note:** This plugin installs none of these dependencies. `agy`, GNU-compatible timeout,
> and `gh` (when filing) must already be available in your PATH.

## Components

### Command: `/reddit-fetch:reddit-fetch <topic>`

Quick Claude Code slash command to research any topic on Reddit. The generated Codex workflow also
accepts `/reddit-fetch`.

```
/reddit-fetch:reddit-fetch best static site generators 2025
/reddit-fetch:reddit-fetch NixOS vs Arch Linux for development
/reddit-fetch:reddit-fetch fix Docker compose networking issues
```

### Skill: reddit-research

Automatically activates when you ask about community opinions, real-world experiences, or Reddit discussions. Provides prompt patterns and result formatting guidance.

### Agent: reddit-researcher

Triggers proactively when your question would benefit from Reddit community insights — tool comparisons, troubleshooting, community recommendations, etc.

## How It Works

1. Constructs a Reddit-focused prompt for `agy`
2. Invokes one bundled runner with a 150-second attempt and at most one 90-second retry
3. Runs `agy` with its default model from an empty private home and work directory, a clean
   environment, and only your sign-in token (or `GEMINI_API_KEY`); permissions allow web search and
   URL reads (search grounding redirects off Reddit) and deny file reads, commands, file writes, URL execution, and MCP
4. Requires a full Reddit comments URL before accepting the output
5. Preserves time for verification and a complete caveated report

## Fabrication Risk

Gemini via `agy` has fabricated Reddit thread titles, subreddits, quotes, and consensus in
production use. All three surfaces (command, skill, agent) treat Gemini's output as a
directional lead, not verified fact. A thread becomes verified only when a non-Gemini fetch
confirms its visible content supports the claimed pain point; unverified leads may still be
reported as such. `--file-issue` is hard-blocked unless at least two independent,
non-crossposted supporting threads from different authors have each been verified. See
`skills/reddit-research/references/protocol.md` for the full verification protocol.

## SaaS Demand Bridge

In SaaS projects, use Reddit findings as evidence, not as instructions. Save durable
research under `docs/research/` and only file GitHub issues when a repeated pain point is
specific, objectively checkable, and backed by at least two independent threads that have each
been verified per the protocol above. Issues filed from Reddit should carry labels such as
`market-signal` and `customer-issue` so `saas-startup-team` `/maintain` can triage the fixable
parts while parking judgment calls.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Empty response | No Reddit results found — try more specific terms or subreddits |
| Auth error | Run `agy` and sign in again, or replace `GEMINI_API_KEY` |
| Quota or rate limit | Wait for the subscription or API quota to reset |
| Command not found | Install `agy` as above and make sure it is on your PATH |
| Timeout | Narrow the topic; the runner keeps its fixed budget and still returns a caveated report |
