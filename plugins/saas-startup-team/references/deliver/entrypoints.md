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

### Claim Work Unit

Before branch mutation, claim the work unit:

```bash
ORIGINAL_BRANCH=$(git branch --show-current)
ORIGINAL_HEAD=$(git rev-parse HEAD)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --acquire "improve:${slug}" --state-dir .startup/leases \
  --owner-file ".startup/leases/.owners/improve-${slug}.owner" --ttl-seconds 1800
```

If acquisition refuses, leave branch and tree untouched. Delivery does not require
`.startup/state.json`; if that file happens to exist, a host may snapshot it as
`state.before` for exact refusal restoration only — it is not delivery authority.

### Establish Branch

**`stay` mode:** no branch operation. **`new-branch` mode:** create `improve/${slug}`
only after the lease is held. On refusal to proceed, restore with
`git checkout "$ORIGINAL_BRANCH"` after verifying
`test -z "$(git status --porcelain)"` and `HEAD == $ORIGINAL_HEAD`; delete only the
unmutated `improve/${slug}` branch; release the lease.

**Preflight extras:** architecture doc `docs/architecture/architecture.md` should exist
for stack/URLs; warn if missing.

**Build:** standard founder-optional path. Prefer host-native workers over personas.
If the host still registers maintain agents, optional types are
`saas-startup-team:business-founder-maintain` (brief/QA) and
`saas-startup-team:tech-founder-claude-maintain` /
`saas-startup-team:tech-founder-codex-maintain` (implement). Codex uses
`codex-run-role.sh --role tech-founder --profile "$PROFILE"`.

**Commit:**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/supervisor-commit.sh" \
  --message "improve: ${slug}" --check ./check.sh
```

**Finish:** push; `new-branch` creates PR with What/Changes/Regression test/Closure
audit/QA sections; `stay` reports existing PR. Never merge. Release lease after terminal.

**Scope guard (advisory):** 3+ distinct features → suggest `/startup`; proceed if confirmed.

---

## `goal-deliver` — multi-unit delivery to production

**Args:** `#N` issues, `--milestone <name>`, markdown spec path, free text, or
`--full` (force deep; skip light path). Strip `--full` before resolving input form.

**Invocation identity** (`SAAS_INVOCATION_ID` matches `^run-[0-9a-f]{32}$`):

- Standalone: reuse canonical inherited value or mint once; defaults an absent value to `goal-deliver` for `SAAS_INVOCATION_COMMAND`; reject other values.
- Embedded: only `SAAS_EMBEDDED_CALLER=maintain` with inherited canonical
  `SAAS_INVOCATION_ID` and all four bindings nonempty:
  `SAAS_EMBEDDED_WORKTREE`, `SAAS_EMBEDDED_CLAIM`,
  `SAAS_EMBEDDED_LEASE_STATE`, `SAAS_EMBEDDED_REMAINING_SECONDS`.
  Embedded **must inherit an already** canonical root. Current worktree must equal
  embedded worktree. Invocation command must be `maintain` or `maintain-loop`. Claim
  matches `<!-- maintain:claim:ID -->`. This accepts a prior canonical run ID and the
  bounded legacy-promoted compatibility ID; it does not require the
  **marker ID to equal** the current invocation. Heartbeat lease with
  `maintain-leases.sh heartbeat --run-id "$SAAS_INVOCATION_ID"`. Missing/invalid binding →
  `blocked/context_binding_violation`. Load
  `goal-deliver-maintain-receipts.md` only after bindings pass.
  Embedded: `/goal-deliver` never writes a root pass outcome; `/maintain` alone does.
  Standalone: standalone `/goal-deliver` is the sole writer for its root.

For each delivery attempt, including a retry, mint a fresh child ID and export it as
`SAAS_RUN_ID`; every goal work event appends with
`--parent-run-id "$SAAS_INVOCATION_ID"`. Root totals are never computed from child events.

**Preflight extras:** `tribunal-review:tribunal-loop` skill required. Standalone must be
on default branch with clean tree; **skip this standalone primary-checkout gate** under
maintain embed.

### Claim the Delivery Scope

**Claim delivery scope** before route/build and before every light or deep path
(standalone only):

```bash
goal_fingerprint=$(printf '%s' "$resolved_scope_identity" | git hash-object --stdin)
GOAL_LEASE_KEY="goal-deliver:${goal_fingerprint}"
GOAL_OWNER_FILE=".startup/leases/.owners/goal-deliver-${goal_fingerprint}.owner"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --acquire "$GOAL_LEASE_KEY" --state-dir .startup/leases \
  --owner-file "$GOAL_OWNER_FILE" --ttl-seconds 1800
```

Embedded skips this acquisition (and skips this second delivery-scope lease acquisition
for chunks); heartbeats `SAAS_EMBEDDED_LEASE_STATE` instead. Release on success and
every handled terminal failure with `$GOAL_LEASE_KEY` / `$GOAL_OWNER_FILE` (standalone).

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
`Closes`/`Fixes`/`Resolves`. Resume only the one freshly bound existing PR; never open a
replacement PR. Marker ID need not equal the current root. Receipt adapter owns
helper-authorized merge, release/live proof, delayed issue close, crash recovery,
rollback-or-stop, and canonical finalization.

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
