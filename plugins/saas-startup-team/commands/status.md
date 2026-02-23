---
name: status
description: Show current state of the SaaS startup loop — iteration count, active roles, handoff history, human tasks, and blockers
user_invocable: true
---

# /status — Startup Loop Status

Show the current state of the SaaS startup project.

## Actions

1. **Run the status script**:
   ```bash
   bash plugins/saas-startup-team/scripts/status.sh
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
