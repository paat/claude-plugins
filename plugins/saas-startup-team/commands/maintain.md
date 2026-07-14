---
name: maintain
description: "Autonomous maintenance supervisor. Probe model-free, then load the delivery playbook only when work exists. Usage: /maintain [--once] [--dry-run] [limits]"
user_invocable: true
---

# /maintain

Parse only probe-relevant flags from `$ARGUMENTS`, then run
`${CLAUDE_PLUGIN_ROOT}/scripts/workflow-probe.sh maintain` with them. Exit 3 is a
clean no-op: stop without loading another file or launching a worker. Exit 4 is a
blocked environment: report the probe's diagnosis and remedy, then stop the same
way (a `--dry-run` planning pass is never blocked). Any other nonzero exit is a
real failure. On exit 0, read
`${CLAUDE_PLUGIN_ROOT}/references/workflows/maintain.md` once and follow it. Do not
duplicate its gates in this entrypoint.
