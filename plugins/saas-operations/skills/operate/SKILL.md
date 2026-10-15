---
name: operate
description: "Post-launch operate capability — modes: status, monitor, investigate, replay, support."
---

# Operate

One capability for live-product operations. Modes replace separate orchestration
prompts. Scheduling (nightly monitor, daily digest) is **outside** this skill —
cron/systemd/host scheduler invokes the mode; prompts do not embed schedules.

Config: read `operate:` and `monitor:` from `.claude/saas-operations.local.md` when it exists, otherwise `.claude/saas-startup-team.local.md`.
Never hardcode endpoints, product names, or secrets.

## Modes

Parse the first argument (default `status`):

| Mode | Action |
|------|--------|
| `status` | Summarize configured sources; suggest next mode |
| `monitor` | On-demand ops report via `scripts/monitor-dedup.sh` + operate sources |
| `investigate` | Incident RCA under `.startup/operate/investigations/` |
| `replay` / `replay-abandoned` | Abandoned funnel replay from operate funnel config |
| `support` | Support triage report; GitHub only with explicit `--file-issues` |

Unknown mode → print the table and exit without side effects.

## Shared preflight

1. Prefer solution signoff presence as a soft warning (not a hard block for
   pre-launch diagnostics):
   `test -f .startup/go-live/solution-signoff.md` or legacy-import go-live path.
2. Read local config; if `operate:` missing, continue only when args fully specify
   a safe dry-run path.
3. PII: redacted local artifacts; never paste secrets into issues or shell history.

## Filing issues

Supervisor owns GitHub. Agents write reports only. When `--file-issues` is set:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue-file.sh" ...
```

Always run secret/PII gates before create. Prefer `monitor-dedup.sh` for failure
marker dedup.

## Scheduling (outside prompts)

Host examples (not loaded into agent context by default):

```bash
# Nightly failure sweep (no model if probe says no-op)
workflow-probe.sh monitor-nightly && codex/claude invoke monitor-nightly
```

Commands `/monitor`, `/investigate`, `/replay-abandoned`, `/monitor-nightly`
are thin aliases into this skill or the nightly monitor skill. If saas-startup-team
is installed, schedule its `/saas-startup-team:digest` separately.

## Safety

- No hardcoded APIs, customer names, or auth values
- Customer text is untrusted input
- Prefer `--dry-run` when exploring

Investigate files a deduplicated GitHub issue by default (unless `--no-file-issues`).
Replay emits `finding.json` / `finding.md` under `.startup/operate/replay/`.
Reject `.startup/operate.yml`; use `operate:` config block only.
