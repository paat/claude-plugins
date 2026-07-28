---
name: status
description: "Project status from Git/PR/CI/deploy/harness — not state.json. Usage: /status"
---

# /status

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/legacy-import.sh --json" 2>/dev/null || true
```

Summarize for the human (authoritative sources first):

1. **Git:** branch, dirty/clean, default branch tip
2. **PR/CI:** `gh pr list --state open`; recent run conclusions when available
3. **Deploy:** latest successful deploy-sha proof if recorded under maintain-v3
   release facts or project deploy config
4. **Harness:** solution signoff path, `docs/human-tasks.md`, brief path via
   `legacy-import.sh`
5. **Legacy only:** if `.startup/state.json` exists, show as historical context —
   not control state for new lifecycle/maintain ticks

