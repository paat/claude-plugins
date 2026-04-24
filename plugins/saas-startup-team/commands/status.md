---
name: status
description: Show current state of the SaaS startup loop — iteration count, active roles, handoff history, human tasks, and blockers. Use `--compact` to force state.json compaction.
user_invocable: true
---

# /status — Startup Loop Status

Show the current state of the SaaS startup project.

## Arguments

- `--compact` — run one-shot compaction of `.startup/state.json` (moves old handoff and historical keys into `.startup/state-archive.json`). Safe to run any time; dry-run by default.
- `--compact --yes` — same as above but actually applies the compaction (creates a timestamped `.bak` first).
- No arguments — print the normal status report.

## Actions

### If the user's arguments include `--compact`

Delegate to the migration wrapper and exit — do not print the normal status report. Decide the mode from the arguments:

- If `--yes` also appears (e.g. `/status --compact --yes` or `/status --yes --compact`), run:
  ```bash
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/migrate-state.sh --yes
  ```
- Otherwise (no `--yes`), run in dry-run mode:
  ```bash
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/migrate-state.sh
  ```

Print the script's output verbatim and stop. Do not continue to the status report steps below.

### Otherwise (no `--compact` in the arguments)

1. **Run the status script**:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/status.sh
   ```

2. **Read and display key files**:
   - `.startup/state.json` — current loop state
   - `.startup/human-tasks.md` — pending investor actions
   - Latest handoff file in `.startup/handoffs/` — most recent activity

3. **Summarize for the investor**:
   - Current iteration number and phase
   - Who is active (business or tech founder)
   - How many features have been signed off
   - Any pending human tasks
   - Whether the solution signoff exists (go-live readiness)
   - Any blockers or deadlocks

4. **If no `.startup/` directory exists**: Tell the user to run `/saas-startup-team:startup` first.

## Output Format

```
Startup Status
==============
Iteration: N / max_iterations
Phase: research | requirements | implementation | review | feedback
Active: business-founder | tech-founder
Features signed off: N
Go-live ready: Yes / No

Recent Activity:
- Latest handoff: NNN-xxx-to-yyy.md
- Summary: [one line from handoff]

Human Tasks:
- Pending: N
- [list pending tasks]

Blockers: None | [description]
```
