---
name: maintain-loop
description: Fresh-context issue delivery. Probe model-free, then load the Codex worker playbook only when an eligible issue exists. Usage: /maintain-loop [flags]
user_invocable: true
---

# /maintain-loop

Pass `--issue`, `--label`, and repository context from `$ARGUMENTS` to
`${CLAUDE_PLUGIN_ROOT}/scripts/workflow-probe.sh maintain-loop`. Exit 3 is a clean
no-op: stop without loading another file or launching Codex. Exit 4 is a blocked
environment: report the probe's diagnosis and remedy, then stop the same way.
Any other nonzero exit is a failure. On exit 0, read
`${CLAUDE_PLUGIN_ROOT}/references/workflows/maintain-loop.md` once and follow it.
