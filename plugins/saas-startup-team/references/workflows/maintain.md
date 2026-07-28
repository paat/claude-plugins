---
name: maintain
description: "Bounded maintain tick — maintain-v3 only. Usage: /maintain [--once] [--shadow|--mutate]"
user_invocable: true
---

# Maintain

Canonical path is **maintain-v3** (`scripts/maintain-v3.sh`,
`skills/maintain/SKILL.md`, `references/workflows/maintain-v3.md`).

## Tick

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-v3.sh" tick --shadow \
  --repo-root "$(git rev-parse --show-toplevel)" --allow-linked-worktrees
# Opt-in mutation:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-v3.sh" tick --mutate \
  --repo-root "$(git rev-parse --show-toplevel)" --allow-linked-worktrees
```

Rules:

1. Short locks only: scheduler (≤120s), issue (isolation bind), release (merge/deploy/close).
2. WIP-first: dirty → resume PR/branch → delete leftovers → one queue issue → no-op.
3. Native worktrees preferred; never silent primary-checkout mutation.
4. No claims, `maintain:claimed`, compatibility receipts, whole-pass leases, guardians, or ptrace.
5. Release facts via `maintain-v3.sh release-facts` (immutable terminal fields only).
6. Human park: `maintain-human-gate.sh evaluate`; unresolved human work → `docs/human-tasks.md`.
7. Independent product verdicts: `skills/product-acceptance` when a product signoff is required.
8. Optional hygiene: `memory-gc.sh` when the tick reports memory pressure; UX design review leg
   `design-review-leg.md` only when a UI design audit is in scope.

Probe (model-free readiness):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/workflow-probe.sh" maintain --root "$(git rev-parse --show-toplevel)"
# exit 0 work available; 3 no-op; 4 blocked host
```

`--once` launches at most one child tick. `--dry-run` maps to `--shadow`.
exit 3 is `no-op`. `--once` launches at most one child.

## Resume authority (no claim receipts)

Open PR/branch WIP from `maintain-wip.sh` / GitHub is ownership. `release-facts`
persists `pr_number`, `head_sha`, `merge_sha`, `deploy_run_id`, `recovery_step` once
a unit is selected or advanced. Between PR open and first release-facts record,
resume via the open PR on the issue — never open a replacement PR.

## Legacy drain (explicit, isolated)

Do **not** invent new claims. On first post-upgrade maintain when the probe reports
legacy receipts, inventory and drain leftover receipts:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/legacy-drain.sh" inventory --repo-root "$(git rev-parse --show-toplevel)" --json
bash "${CLAUDE_PLUGIN_ROOT}/scripts/legacy-drain.sh" drain --repo-root "$(git rev-parse --show-toplevel)" --apply --json
bash "${CLAUDE_PLUGIN_ROOT}/scripts/legacy-drain.sh" verify --repo-root "$(git rev-parse --show-toplevel)" --json
```

Source `.startup` / maintain-runtime receipt files stay intact until verify.
Recoverable abandoned claims get drain markers; unresolved cases append sanitized
lines under `docs/human-tasks.md` (no secrets/PII).

Historical primary-only protocol (read-only archive):
`docs/legacy/maintain-protocol.md`. Not loaded on the normal path.
