---
name: epic
description: "Serial multi-issue GitHub epic train — one branch/PR, deliver per child, tribunal, merge, deploy+live verify, close. Usage: /epic <n> | /epic --plan <n>"
---

# Epic

Thin conductor for a **single** GitHub epic with a child checklist. Does not
replace `deliver`, `maintain`, or tribunal-review. **Serial only** (`concurrency=1`).

Full invariants: `../../docs/legacy/epic-invariants.md`.

## Activation

```text
/epic <n>           # plan + execute (mutation)
/epic --plan <n>    # plan only (no mutation; tribunal optional)
```

`$ARGUMENTS` = epic issue number and optional flags. Repo = current `gh` remote
unless `--repo OWNER/REPO`.

## Preflight (before mutation)

1. Health: `scripts/health-preflight.sh --require-gh --check-sync` (Codex: add `--require-codex`).
2. Fetch body: `gh issue view <n> --json body,title,labels,state`.
3. Plan: `gh issue view <n> --json body -q .body | python3 scripts/epic_plan.py`  
   Zero children or parse errors → **stop** (no silent decompose in Phase 1).
4. Body hash: `sha256` of raw body; children list from plan JSON.
5. Active guard: `python3 scripts/epic_active.py check --repo …`  
   Exit 3 → **blocked** (another epic train open). Exit 0 required.
6. **Execution only:** tribunal-review must be available (plugin/skill present).  
   Missing → **blocked** before any write. `--plan` may continue without it.
7. Branch `epic/<n>-<slug>` from default branch; one **draft** PR whose body
   includes marker from `epic_active.py marker --epic n --body-sha … --children …`.

## Serial control flow

For each **unchecked** child in plan order (never parallel writers):

1. Set epic mode for deliver: land commits **only** on the epic branch/PR  
   (`SAAS_EPIC_MODE=1`, `SAAS_EPIC_PR=<pr>`; **no merge to main**, no new PR).
2. `base_sha=$(git rev-parse HEAD)` → load `skills/deliver/SKILL.md` for that issue.
3. Tribunal on `base_sha..HEAD` (child range only). Fix **critical/high** same run;
   re-tribunal until clean or **blocked**.
4. Record reviewed head SHA on the PR. **Do not** close the GitHub child yet.
5. On epic body drift (hash mismatch) or child-list change → **halt**.

## Close (once children landed)

1. Closing-tribunal on **full** epic PR diff; required **PR** CI green.
2. Merge **only** via the epic PR (branch protection / exact-head as project requires).
3. **Post-merge CI/deploy (same turn):** pin `merge_sha`; poll
   `gate.sh release poll --deploy-sha "$merge_sha" --branch "$default"`
   (or `poll-gate.sh --deploy-sha`) until green/red. Never treat "latest run" as
   proof. Sustained pending past the poll budget → **incomplete** (resume later),
   not `complete`.
4. **Live verify after deploy green:** re-run
   `scripts/ui-touch.sh --range <pre-merge>..$merge_sha`; if `ui`, run post-deploy
   visual smoke (`references/ux-review/design-review-leg.md`). Non-UI: hit
   project smoke/health on `SAAS_LIVE_URL` (or architecture-doc live URL) when
   configured. Deploy red or merge-attributable live break → **blocked** (do not
   close children as done).
5. **Only after** merge + deploy green + required live verify: close children,
   tick checklist, file residuals via `issue-file`, close epic.

UI/browser-facing children also trigger `ux-review` during the train when
acceptance requires it; that does not replace post-deploy smoke.

## Stop / results

| Result | Meaning |
|--------|---------|
| `complete` | Merged; deploy green on `merge_sha`; live verify done when required; children closed |
| `blocked` | Guard, tribunal missing, drift, human gate, deploy red, live regression |
| `incomplete` | Partial work, CI/deploy still pending, or merge without close-out |
| `cancelled` | Human abort |

Never claim success without merge + deploy/live evidence. No `.startup` state machine.
