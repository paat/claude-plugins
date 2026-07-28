# Delivery playbook

Sole short delivery policy. Canonical skill: `skills/deliver/SKILL.md`.
Commands `/improve`, `/goal-deliver`, `/tweak`, and startup implementation are aliases.

## Graph (mandatory order)

```
Preflight → Plan → Isolated Build → Independent Review → Release → Report
```

```bash
export SAAS_DELIVER_ENTRYPOINT=<improve|goal-deliver|tweak|startup-impl>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/health-preflight.sh" --require-gh --check-sync
# Post-completion entrypoints require solution signoff:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" release signoff \
  --source-root "$(git rev-parse --show-toplevel)"
# Equivalent: scripts/solution-signoff-gate.sh
```

`startup-impl` skips solution signoff. Prefer isolated worktrees; Never hard-reset the primary. no whole-pass lease (#389).
Default branch only via `scripts/default-branch.sh`.

## Plan

Before reading product or research docs, read and apply
`templates/delivery-scope-planning.md` and `templates/delivery-scope-contract.md`.
Derive **Done**, **Preserve**, **Out of Scope** before architecture. Expand only when
evidence causally blocks Done.

**Do not dispatch a planning role by default.** Add exactly one specialist only when an
independent business, legal, or technical evidence gap can materially change `Done`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-route.sh" classify \
  --mode "$route_mode" --task-file "$task_file"
# exit 20 → profile=deep; exit 0 → standard (or mechanical empty post-diff)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" acceptance --select --category X --text Y
bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" acceptance --render <pack-ids>
# Equivalent surface: scripts/acceptance-packs.sh --render / --select
```

When no arguments: run `market-scout.sh` and take the top candidate; if none, ask once.
A new public/indexable route must include `public_route_discoverability`.

## Isolated Build

**Conductor must not implement.** Workers edit product source, tests, and workflow
specs but **do not commit**. Parent-patch then cast-as-validation is forbidden.
Standard/deep: `BASE_SHA` → classify → `isolated-build-assert.py preflight` → worker
→ `isolated-build-assert.py post --receipt` (`codex-cast --json-out`: implement /
success / `commit_sha=$BASE_SHA`) → `check-diff` → `supervisor-commit.sh` → assert.

| Profile | Path |
|---------|------|
| mechanical | Named script only; no model worker |
| light | `tweak-run.sh` containment (≤3 files, ≤15 lines, no sensitive paths); exit 20 escalates |
| standard/deep | Host-native worker only. Codex: `codex-cast.sh` (`--worktree`, `--mode implement`, `--model`, `--effort`, `--timeout`, `--json-out`). No founder personas or nested controllers. |

Conductor-only: `.codex-cast-*.{md,json}`, `.epic-*.md`, `.epic-compose-draft.md`,
`.epic-pr-body.md`. Worker does red/green + `./check.sh`. Honor
`references/triggered-saas-gates.md`. When `.startup/workflows/registry.md` applies,
the worker updates `WORKFLOW-*.md`.

## Independent Review

Independent of the implementer (`product-acceptance`, `ux-review`). Review-only artifacts.

- UI: `scripts/ui-touch.sh --range`; unless `no-ui`, design-review leg PASS in PR body
- Public routes: `gate.sh acceptance --verify-public-route "$QA_REVIEW"` (or
  `acceptance-packs.sh --verify-public-route "$QA_REVIEW"`); destination-only cannot PASS
- Hedged legal: `gate.sh legal --validate` / `legal-verdict-gate.sh` — never state hedged claims as fact
- Merge paths: tribunal **zero critical and zero high**; **Round 5:** ceiling
  (`tribunal-review:closing-tribunal-loop`). Include the **material promise** question when
  the PR uses `Closes`/`Fixes`/`Resolves`.

## Release (merge entrypoints only)

1. `issue-closure-audit.sh --pr` when closing keywords present
2. **Fresh check revalidation** on latest HEAD after updating from current default.
3. **Exact PR/head binding:** bind `BOUND_SHA` to local HEAD; require freshly fetched PR
   `headRefOid` equals it. **latest-HEAD gates** must pass.
4. **SHA-pinned merge:** `gh pr merge … --match-head-commit "$BOUND_SHA"`
5. **Deployment/live proof:** pin `merge_sha`; poll with
   `gate.sh release poll --deploy-sha "$merge_sha" --branch "$default"`
   (or `poll-gate.sh --deploy-sha`). Never treat "latest run" as proof.
6. **Close observation:** close issues only after verified merge/deploy.
7. **Idempotent post-merge recovery:** crash between merge/deploy/close resumes from
   immutable receipt/PR facts; never fabricate success.

`improve`/`tweak` open PR evidence only — never merge. Standing green-gate:
`templates/merge-policy.md`.

## Entrypoints

| Entrypoint | Units | Merge | Deploy | Notes |
|------------|-------|-------|--------|-------|
| improve | one | no | no | new-branch or stay on open PR |
| goal-deliver | many | yes | yes | PR-sized chunks; tribunal; optional light single-issue |
| tweak | one light | no | no | escalate non-light to improve |
| startup-impl | one | no | no | no solution-signoff |

**goal-deliver chunks:** dependencies first; per chunk build→tribunal→audit→merge→deploy.
**Light:** `tweak-run.sh`; exit 20 escalates once after verified cleanup. Poll CI with
`poll-gate.sh --pr` / `gate.sh release poll --pr`. Never treat absent checks as green.

## Outcomes

`success` | `blocked` | `failure` | `escalated` | `cancelled` | `no-op` — never leave an
interrupted run looking successful. Every completed run includes a **completion artifact**:
need addressed, what changed, how verified, acceptance packs, remaining risks, follow-ups.

Ask the investor only for true blockers (secrets, spend, legal judgment, destructive
production, pricing/promise ambiguity).

Pairs with built-in `/goal` for autonomy. Monitors GitHub Actions deploy via `gh run` /
`gate.sh release poll`. Design-review: `references/ux-review/design-review-leg.md`.
Maintain embed may set `SAAS_EMBEDDED_WORKTREE` via `maintain-v3.sh isolate` and record
`release-facts`.

Every entrypoint uses this same phase order

`goal-deliver`

Never merge

solution-signoff and PR/merge

All share `skills/deliver/SKILL.md` graph phases

bounded light fast-path only

single improvement cycle

multi-unit delivery

/goal 
