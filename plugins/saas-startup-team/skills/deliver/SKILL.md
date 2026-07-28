---
name: deliver
description: "Host-neutral Plan → isolated Build → Independent Review → Release. Entrypoints: improve, goal-deliver, tweak, startup-impl."
---

# Deliver

Canonical delivery. `/improve`, `/goal-deliver`, `/tweak`, and startup implementation
resolve here. Commands are generated aliases only.

Host-neutral — does **not** require founder personas, `.startup/state.json`, or
`active_role`. Never write `active_role: "team-lead"`.

Follow `../../references/delivery-playbook.md` (sole delivery playbook). Set
`SAAS_DELIVER_ENTRYPOINT` to `improve` | `goal-deliver` | `tweak` | `startup-impl`.

**Conductor vs worker:** parent does not edit product source (standard/deep: `isolated-build-assert.py` preflight → cast → post; no parent-patch then cast-as-validation). Light: `tweak-run.sh`; mechanical: scripts.

**Active epic guard:** before mutation outside an epic train, run
`python3 scripts/epic_active.py check`. Exit 3 → refuse (another epic PR open).
When `SAAS_EPIC_MODE=1`, deliver only to the existing epic branch/PR — **no merge
to main**, no second PR; child GitHub close happens after epic merge only.

Gates (deterministic):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" release signoff --source-root "$(git rev-parse --show-toplevel)"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" acceptance --render <packs>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" legal --validate docs/legal/*.md
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" release poll --deploy-sha "$merge_sha"
```

Maintain embed: same graph inside maintain-v3 isolation; release facts via
`maintain-v3.sh release-facts` only.

This skill is the sole delivery contract; commands are aliases only.
