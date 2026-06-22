---
name: session-insights
description: Local-only scan of this project's Claude Code session logs for investor interventions (interrupts, /nudge, corrections) and agent friction (tool failures). Emits typed records + a Markdown report under .startup/insights/. No network, no issue filing, no arguments. Usage: /session-insights
allowed-tools: Bash, Read
user_invocable: true
---

# /session-insights — local intervention extractor

Part of the self-improvement loop (see `docs/design/self-improvement-loop.md`). This
is the **v1, local-only** stage: it surfaces *where the investor had to step in* and
where agents hit friction, so those can later become generic plugin-improvement
issues. It does **not** touch the network and does **not** file any issue — review
always precedes filing.

## What it detects (high precision over recall)

- **interrupt** — `[Request interrupted by user]` (the investor stopped the agent)
- **nudge** — a turn beginning with `/nudge`
- **correction** — a short investor turn opening with a correction cue
- **tool_failure** — a tool result flagged `is_error` (agent friction)

Harness-injected command-output wrappers (`<local-command-caveat>`, …) and long
pasted blocks are excluded. Records accumulate across runs via a byte-offset
watermark, so each run only processes new transcript content.

## Run

Runs with safe defaults — outputs are confined to `.startup/insights/` in this
project; no caller-supplied paths.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/session-insights.sh"
```

The script writes:
- `.startup/insights/records.jsonl` — one typed record per signal (append-only, local)
- `.startup/insights/report.md` — counts for this run
- `.startup/insights/watermark.json` — per-file byte offsets

## Then

Read `.startup/insights/report.md` and summarize for the investor: the count of new
**investor interventions** (interrupt + nudge + correction) and **tool failures**
this run, plus any notable recurring `sanitized_summary` values. Flag that these are
**local only** — nothing has been filed anywhere.
