---
name: status
description: "Show project lifecycle status from Git artifacts and legacy import. Usage: /status"
user_invocable: true
transitional: true
---

# /status

Show current SaaS project status without reviving the delivery state machine.

## Actions

1. Run the status helper (summarizes docs, signoffs, handoffs if present):
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/status.sh
   ```

2. Surface legacy brief/workflow/signoff paths (read-only):
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/legacy-import.sh --json
   ```

3. Summarize for the human:
   - Goal/brief path if present
   - Solution signoff presence
   - Open human tasks in `docs/human-tasks.md`
   - Git/PR facts when available (`gh pr list`, branch tip)
   - If legacy `.startup/state.json` exists, report its fields as **historical
     context only** — new lifecycle runs do not update `active_role` or iteration

`--compact` / state migration is removed (issue #386). Existing archive files are left untouched.
