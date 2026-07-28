---
name: epic
description: "Serial multi-issue GitHub epic train — meta-orchestrator conducts; workers implement. Usage: /epic <n> | /epic --plan <n>"
---

# Epic

**Meta-orchestrator** for one GitHub epic checklist. Serial only (`concurrency=1`).
Does not replace `deliver`, `maintain`, or tribunal-review.

Full invariants: `../../docs/legacy/epic-invariants.md`.

## Conductor contract (hard)

Parent is conductor — not implementer. Never edit product source, product tests, or
`.startup/workflows/**`. Standard/deep: `isolated-build-assert.py preflight` →
`codex-cast.sh` (cast is the implementer) → `post --receipt`. No parent-patch then
cast-as-validation. Parent may write cast prompts / epic drafts only.

## Activation

```text
/epic <n>           # plan + execute (mutation)
/epic --plan <n>    # plan only (no mutation; tribunal optional)
```

`$ARGUMENTS` = epic issue number and optional flags. Repo = current `gh` remote
unless `--repo OWNER/REPO`.

## Preflight (before mutation)

1. Health: `scripts/health-preflight.sh --require-gh --check-sync` (Codex: `--require-codex`).
2. Fetch body: `gh issue view <n> --json body,title,labels,state`.
3. Plan: `gh issue view <n> --json body -q .body | python3 scripts/epic_plan.py`  
   Zero children or parse errors → **stop**.
4. Body hash: `sha256` of raw body; children list from plan JSON.
5. Active guard: `python3 scripts/epic_active.py check --repo …`  
   Exit 3 → **blocked**. Exit 0 required.
6. **Execution only:** tribunal-review must be available. Missing → **blocked**.
7. Branch `epic/<n>-<slug>`; one **draft** PR with marker from
   `epic_active.py marker --epic n --body-sha … --children …`.

## Serial control flow

For each **unchecked** child (never parallel writers):

1. Epic mode: `SAAS_EPIC_MODE=1`, `SAAS_EPIC_PR=<pr>` — **no merge to main**, no new PR.
2. `base_sha=$(git rev-parse HEAD)` → `skills/deliver/SKILL.md` (conductor contract).
3. Tribunal on `base_sha..HEAD`. Fix **critical/high** via worker + re-tribunal.
4. Record reviewed head SHA on the PR. **Do not** close the GitHub child yet.
5. Body drift or child-list change → **halt**.

## Close (once children landed)

1. Closing-tribunal on **full** epic PR diff; required **PR** CI green.
2. Merge **only** via the epic PR (exact-head as required).
3. **Post-merge CI/deploy (same turn):** pin `merge_sha`; poll
   `gate.sh release poll --deploy-sha "$merge_sha" --branch "$default"`.
   Never treat "latest run" as proof. Sustained pending → **incomplete**.
4. **Live verify after deploy green:** `ui-touch.sh` / smoke as required.
   Deploy red or live break → **blocked**.
5. **Only after** merge + deploy green + required live verify: close children,
   tick checklist, file residuals, close epic.

## Stop / results

| Result | Meaning |
|--------|---------|
| `complete` | Merged; deploy green on `merge_sha`; live verify done when required; children closed |
| `blocked` | Guard, tribunal missing, drift, human gate, deploy red, live regression |
| `incomplete` | Partial work, CI/deploy still pending, or merge without close-out |
| `cancelled` | Human abort |

Never claim success without merge + deploy/live evidence. No `.startup` state machine.
