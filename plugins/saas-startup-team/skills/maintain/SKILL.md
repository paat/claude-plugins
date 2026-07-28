---
name: maintain
description: "Bounded maintain tick — maintain-v3 only. Usage: /maintain [--once] [--shadow|--mutate]"
---

# Maintain

Follow `../../references/workflows/maintain-policy.md` (sole maintenance policy).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-v3.sh" tick --shadow \
  --repo-root "$(git rev-parse --show-toplevel)" --allow-linked-worktrees
```

**Active epic guard:** before `--mutate`, run `python3 scripts/epic_active.py check`.
Exit 3 → refuse mutation (shadow/inventory may continue). Do not double-deliver
children owned by an open epic train.

Delivery uses `skills/deliver/SKILL.md` inside isolation. Human park via
`maintain-human-gate.sh`. Stranded receipts: `scripts/legacy-drain.sh`.

No claims, whole-pass leases, or primary hard-reset.
