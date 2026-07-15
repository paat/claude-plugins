---
name: maintain
description: "Autonomous maintenance supervisor. Probe model-free, then load the delivery playbook only when work exists. Usage: /maintain [--once] [--dry-run] [limits]"
user_invocable: true
---

# /maintain

Parse probe flags from `$ARGUMENTS`. Accept one internal `--lease-run-id ID`, validate
it against `^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`, retain it as
`MAINTAIN_LEASE_RUN_ID`, and never forward it to the probe. Run
`${CLAUDE_PLUGIN_ROOT}/scripts/workflow-probe.sh maintain` with the probe flags. Exit 3
is a clean no-op. Exit 4 is blocked: report the diagnosis and stop (`--dry-run` is
never blocked). Other nonzero exits fail. On exit 0, read
`${CLAUDE_PLUGIN_ROOT}/references/workflows/maintain.md` once and follow it. Do not
duplicate its gates in this entrypoint.
