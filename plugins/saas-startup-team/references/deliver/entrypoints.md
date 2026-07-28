# Deliver entrypoint configuration

Select one entrypoint. All share `skills/deliver/SKILL.md` graph phases. This file is
configuration only — it does not redefine gates.

## Common

```bash
export SAAS_DELIVER_ENTRYPOINT=<improve|goal-deliver|tweak|startup-impl>
export SAAS_COMMAND="$SAAS_DELIVER_ENTRYPOINT"   # except startup-impl → startup
```

Mint/export `SAAS_RUN_ID` after classification (`agent-events.sh new-run-id`). Load
`routing-telemetry.md` for privacy-safe events.

---

## `improve` — single improvement cycle

**Args:** free-text description (or market-scout top candidate if empty).

**Modes:**

```bash
current=$(git rev-parse --abbrev-ref HEAD)
default=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/default-branch.sh")
pr_url=$(gh pr list --head "$current" --state open --json url --jq '.[0].url' 2>/dev/null)
```

1. `current == default` → **new-branch** (`improve/<slug>`), open PR, return to parent.
2. `current != default` AND open PR → **stay** (append commits; do not open a new PR).
3. Else ask stay vs branch-off.

### Work unit identity

Before branch mutation, record identity (no whole-pass lease — #389):

```bash
ORIGINAL_BRANCH=$(git branch --show-current)
ORIGINAL_HEAD=$(git rev-parse HEAD)
```

Delivery does not require `.startup/state.json`. Prefer isolated worktrees for build;
never hard-reset the primary on cancel.

### Establish Branch

**`stay` mode:** no branch operation. **`new-branch` mode:** create `improve/${slug}`.
On cancel, leave the primary clean; do not `reset --hard` or `clean` the primary.

**Preflight extras:** architecture doc `docs/architecture/architecture.md` should exist
for stack/URLs; warn if missing.

**Build:** host-native implementation worker + capability skills. Load
`skills/tech-founder` standards under deliver Build. Optional discovery/acceptance:
`skills/product-discovery`, `skills/product-acceptance` (independent of implementer).
Claude: Task/Agent. Codex: `scripts/codex-cast.sh --worktree … --mode implement` with
explicit model/effort/timeout (no nested `tech-founder-codex*` controllers).

**Commit:**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/supervisor-commit.sh" \
  --message "improve: ${slug}" --check ./check.sh
```

**Finish:** push; `new-branch` creates PR with What/Changes/Regression test/Closure
audit/QA sections; `stay` reports existing PR. Never merge.

**Scope guard (advisory):** 3+ distinct features → suggest `/startup`; proceed if confirmed.

---

## `goal-deliver` — multi-unit delivery to production

**Args:** `#N` issues, `--milestone <name>`, markdown spec path, free text, or
`--full` (force deep; skip light path). Strip `--full` before resolving input form.

**Invocation identity** (`SAAS_INVOCATION_ID` matches `^run-[0-9a-f]{32}$`):

- Standalone: reuse canonical inherited value or mint once; default
  `SAAS_INVOCATION_COMMAND=goal-deliver`.
- Embedded from maintain-v3: isolation path from `maintain-v3.sh isolate` (worktree/clone);
  set `SAAS_EMBEDDED_CALLER=maintain` and `SAAS_EMBEDDED_WORKTREE` to that path. No claim
  markers, lease state files, or `maintain:claimed` labels. Missing worktree path →
  `blocked/context_binding_violation`. Terminal release facts use
  `maintain-v3.sh release-facts` (not compatibility receipts).

Mint `SAAS_RUN_ID` per attempt (`agent-events.sh new-run-id`). Optional
`--parent-run-id` for telemetry only — not ownership.

**Preflight extras:** `tribunal-review:tribunal-loop` skill required. Prefer isolated
worktree for build; never hard-reset primary on cancel.

**Plan:** load `multi-unit.md` — PR-sized chunks, dependency order, acceptance packs.

### Autonomous Light Fast Path

**Light fast path:** single GitHub issue, no `--full`, `profile=light` and
`ui_touch=false` only. See `light-path.md`. Mechanical profile runs the exact named
script with supervisor-commit gates. Contaminated light failure requires verified cleanup
before one deep retry — never launch a deep worker from a contaminated branch, open PR,
remote branch, or dirty worktree.

Optional `/goal` pairing for autonomous looping: the investor may arm `/goal ` with a
completion condition and re-invoke `/goal-deliver` until it holds.

**Per chunk:** build via deliver graph (same as improve new-branch) → tribunal →
closure audit → SHA-pinned merge → close issues. Then deploy watch (`multi-unit.md`).

**Embedded safety:** non-closing issue reference such as `Refs #N`; never
`Closes`/`Fixes`/`Resolves` from isolation unless release-facts authorize close.
Resume only the bound existing PR; never open a replacement PR. Merge/deploy/close
use short `maintain-v3` release locks and immutable release-facts.

---

## `tweak` — bounded light fast-path only

Trapped shortcut for typos, copy, literal links, small CSS. No founder, no browser QA,
no tribunal, no merge.

**Route mode:** `interactive-tweak` when the user supplied a description (or answered a
prompt); `autonomous` only for internal demand candidates. Classify with
`delivery-route.sh classify --mode "$route_mode"` (interactive-tweak or
`--mode autonomous` for demand candidates). Exit 20, non-`light` profile, or 3+
distinct changes → route to `/improve`. Sensitive/behavioral/ambiguous work cannot be
confirmed back into `/tweak`.

**Branch mode:** on default → `tweak/<slug>` new-branch + PR; else on-branch commit/push,
reuse or create PR, never merge.

**Mutation:** only via `tweak-run.sh` — see `light-path.md`. Preserve helper status:

```bash
helper_rc=0
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tweak-run.sh" \
  --routing-mode "$route_mode" --patch "$patch_file" \
  --message "tweak: ${description}" ... || helper_rc=$?
case "$helper_rc" in
  0) ;;
  20) helper_outcome=escalated ;;  # route to /improve
  *) helper_outcome=failure ;;
esac
```

Never let temporary-file cleanup replace the helper status. Reviewable PR evidence is
completion (`pr=open`); local commit without PR is not success.

**Does not:** browser QA, retry loops, dev server, Task dispatch, writes to handoffs/
reviews/signoffs/go-live.

---

## `startup-impl` — implementation unit inside `/startup`

Invoked by startup orchestration for one handoff/unit of implementation. Same Plan
(from existing handoff) → Build → Independent Review gates as improve. Skips
solution-signoff and PR/merge (startup loop owns iteration and solution signoff).
Still requires `check.sh`, triggered SaaS gates, mutation-ownership, supervisor-commit,
and honest PASS/FAIL review artifacts.
