# reddit-fetch

Research any topic using Reddit via Gemini CLI's web access capabilities.

Claude's WebFetch cannot access Reddit content. This plugin delegates Reddit research to Gemini CLI, which has full web access and can search, read, and summarize Reddit discussions.

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

1. **Gemini CLI** must be installed and authenticated:
   ```bash
   npm install -g @google/gemini-cli
   gemini  # Run once interactively to complete OAuth
   ```

2. **Enable preview features** in `~/.gemini/settings.json`:
   ```json
   {
     "general": {
       "previewFeatures": true
     }
   }
   ```
   This is required to use the `gemini-3-flash-preview` model.

3. **`gh` CLI**, authenticated (`gh auth status`), required by `--file-issue`.

> **Note:** This plugin does not install Gemini CLI or `gh`. Both must already be available in your PATH.

## Components

### Command: `/reddit-fetch <topic>`

Quick slash command to research any topic on Reddit.

```
/reddit-fetch best static site generators 2025
/reddit-fetch NixOS vs Arch Linux for development
/reddit-fetch fix Docker compose networking issues
```

### Skill: reddit-research

Automatically activates when you ask about community opinions, real-world experiences, or Reddit discussions. Provides prompt patterns and result formatting guidance.

### Agent: reddit-researcher

Triggers proactively when your question would benefit from Reddit community insights — tool comparisons, troubleshooting, community recommendations, etc.

## How It Works

1. Constructs a Reddit-focused prompt for Gemini CLI
2. Calls `gemini -m gemini-3-flash-preview -p "..." -o text 2>/dev/null`
3. Parses and presents Reddit findings in a structured format
4. Adds caveats about anecdotal nature of Reddit opinions

## Fabrication Risk

Gemini CLI has fabricated Reddit thread titles, subreddits, quotes, and consensus in
production use. All three surfaces (command, skill, agent) treat Gemini's output as a
directional lead, not verified fact, and require independently confirming that a thread
actually exists (fetching the URL, e.g. via `old.reddit.com`, or a narrow follow-up search)
before it can support a filed issue. `--file-issue` is hard-blocked for any pain point whose
supporting threads cannot be confirmed. See `skills/reddit-research/references/protocol.md`
for the full verification protocol.

## SaaS Demand Bridge

In SaaS projects, use Reddit findings as evidence, not as instructions. Save durable
research under `docs/research/` and only file GitHub issues when a repeated pain point is
specific, objectively checkable, backed by multiple independent threads, and verified per the
protocol above. Issues filed from Reddit should carry labels such as `market-signal` and
`customer-issue` so `saas-startup-team` `/maintain` can triage the fixable parts while parking
judgment calls.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Empty response | Gemini may not find Reddit results — try more specific terms or subreddits |
| Auth error | Run `gemini` interactively to re-authenticate OAuth |
| Model not found | Enable `previewFeatures` in `~/.gemini/settings.json`, or fall back to `gemini-2.5-flash` |
| Command not found | Install Gemini CLI: `npm install -g @google/gemini-cli` |
| Timeout | Increase timeout or narrow the search scope |
