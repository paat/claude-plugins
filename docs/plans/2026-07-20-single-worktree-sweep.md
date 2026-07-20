# Single-Worktree Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish aligning `plugins/saas-startup-team` with the single-worktree investor contract by deleting the remaining dual-tree code, tests, and protocol prose left over after PR #330 (`c7c003a`, "primary-only — ban linked git worktrees").

**Architecture:** No new code paths, no feature flags. Four small PRs: (1) finish the primary-only collapse of the supervisor base-check and prove it green with real deps, (2) fix the protocol-doc residue including one live section-routing bug, (3) delete the vestigial `--worktree`/lease/receipt dual-tree plumbing, (4) delete tests whose premise is a coexisting linked worktree.

**Tech stack:** bash 4+, jq, the plugin's own `tests/run-tests.sh` harness.

## Global constraints

- Every PR bumps the version in BOTH `plugins/saas-startup-team/.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, AND root `.claude-plugin/marketplace.json` (pre-push hook enforces this). **Right now the working tree is inconsistent: plugin.jsons are staged at 0.89.65 but marketplace.json is still 0.89.64 — PR 1 must fix this.**
- Keep Claude and Codex plugin surfaces equivalent (repo rule); this sweep touches shared scripts/references, so no per-surface divergence is expected.
- Prefer deletion. Any "compat" retention below is for *persisted on-disk state* (lease keys, receipts) on live products, not for alternate runtime modes.
- Line numbers marked `~` come from the inventory pass and may drift a few lines; anchor edits on the quoted code, not the number.

---

## 1. Contract restatement

**Single worktree = primary only.** `/maintain` (and all delivery one-shots) run on the product's primary checkout — the same tree the human investor uses. No linked git worktrees, ever (`assert-primary-only` is the hard gate). Human vs. loop coordination is temporal, not spatial: pause the portfolio when the human develops; the loop owns the tree otherwise (signals: `guard-active.sh` `*.active` markers stand background hooks down; a dirty tree stops the loop). Clean-base verification and deterministic checks must behave exactly as they would for the investor on the primary — same deps path (`node_modules`/`venv` visible), no deps-blind shadow evaluation.

## 2. Current state (what already landed)

- PR #330 (0.89.61–0.89.64) removed linked-worktree create/repair/recreate, added `assert-primary-only` gates on probe/lease/reset/preflight, and rewrote most protocol docs. **No script runs `git worktree add` anymore.**
- Uncommitted in the working tree (fold into PR 1): `supervisor-commit.sh` `discover_primary_checkout` no longer rejects `GIT_DIR == COMMON_DIR` / `candidate == ROOT`, so runtime discovery finds the primary's `node_modules`/`venv` again; plugin.jsons bumped to 0.89.65. Reason: under primary-only the old rejects made discovery always fail, the sealed-runtimes list came back empty, and the hermetic base-check ran deps-blind — `tsc` failed on missing frontend types while the investor's `tsc` was green.
- No env vars or config flags control worktree behavior (verified: no `MAINTAIN_WORKTREE`, `*_WORKTREE_*`, `ISOLATION`). The residue is CLI args, lease-key strings, receipt fields, one retired path literal, error-message vocabulary, docs, and tests.

## 3. Inventory

### 3a. DELETE (dead or vestigial once worktree ≡ primary)

| Surface | What | Where |
|---|---|---|
| `scripts/maintain-leases.sh` | `foreign_worktree_leases_available()` (~L317-335); every `"$PRIMARY/.worktrees/maintain"` literal branch (~L34, ~L324, ~L430, ~L466); `[worktree]=900` TTL kind if unused after collapse (~L86); `--worktree` arg + `WORKTREE_BINDING` plumbing (~L253-266, ~L397, ~L463-471) | PR 3 |
| `scripts/maintain-delivery.sh` | `.worktrees/maintain` branch of `normalize_controller_worktree()` (~L399); separate-tree verification inside `disprove_source_state()` (~L711-774: "claimed worktree is a real git worktree / common-dir equality" — identity-true on primary) | PR 3 |
| `scripts/maintain-attempt.sh`, `maintain-wip.sh`, `maintain-escalation.sh` | `--worktree` CLI args and the redundant `worktree == PRIMARY == ROOT` assertion chains; dedicated-worktree cleanup narration in escalation (~L282-290, ~L321-334) | PR 3 |
| `scripts/supervisor-commit.sh` | The generic parent-primary resolution inside `discover_primary_checkout` (L348-364) — collapse to `PRIMARY_CHECKOUT=$ROOT`; "linked-worktree" error strings (L524, L777, L1432) | PR 1 |
| `references/workflows/maintain.md` | Router entry `` `Workspace — Dedicated Worktree` `` (~L174) — **live bug**, heading no longer exists; "or choosing a worktree" (~L86) | PR 2 |
| `references/workflows/maintain-protocol.md` | "cross-worktree" failure vocabulary (~L71, ~L115) | PR 2 |
| `references/workflows/goal-deliver-maintain-receipts.md` | "/worktree selection" (~L52) | PR 2 |
| `tests/runtime-safety.tests.sh` | RS14i12a-e (~L378-416, sibling-worktree concurrency vs base-check); RS19x8 (~L1002-1050) and RS19zj (~L2038-2095) sibling-worktree branch-advance guards; RS19znu/znw (~L1993-2024) linked-worktree control-file identity | PR 4 |
| `tests/agent-events.tests.sh` | EV59 (~L512-513, "linked worktree has no shadow default event store"); linked-repo fixture in EV55-EV60 block (~L482-518) | PR 4 |

### 3b. REWRITE primary-only (behavior survives; fixture/wording changes)

| Surface | What | Where |
|---|---|---|
| `scripts/supervisor-commit.sh` | `discover_primary_checkout` body → validate-and-pin `ROOT` (code in §6, PR 1) | PR 1 |
| `tests/runtime-safety.tests.sh` | RS19zkr1..N (~L1159-1346): runtime-seal suite currently fixtures a *linked* delivery tree; rewrite to a primary checkout that seals its **own** `node_modules`/`venv` — this becomes the regression proof for the whole sweep. RS19s2/s3/s5 shadow-commit assertions: retarget wording; mechanism stays | PR 1 |
| `references/workflows/maintain.md` | ~L174 → `` `Workspace — primary only` ``; ~L178, ~L192-194 ("maintain worktree, investor on main repo only" → "primary checkout only; pause portfolio before investor work"), ~L203-205, ~L245 | PR 2 |
| `references/workflows/maintain-protocol.md` | ~L68, ~L81, ~L87-89 ("create/reset a worktree" → "reset the primary tree") | PR 2 |
| `references/workflows/maintain-v2-contract.md` | ~L30 "Dirty maintain worktree" → "Dirty primary tree"; ~L35 "checkout in maintain worktree" → "checkout on the primary tree"; expand Actors table (~L8-11) with the concrete pause/resume signals (see §5) | PR 2 |
| `references/workflows/goal-deliver-maintain-receipts.md` | ~L226-228 "dedicated worktree" → "primary tree"; ~L65-70 "bound worktree" → "bound primary tree" | PR 2 |
| `docs/design/lessons-deliver.md` | ~L43: "/maintain's safety skeleton (… dedicated worktree …)" → "primary-checkout delivery" (stale description) | PR 2 |
| `tests/workflow-lifecycle.tests.sh` | WL6/WL6a (~L60-63) pin the removed `Workspace — Dedicated Worktree` heading — retarget to `Workspace — primary only` in the same PR as the doc fix | PR 2 |
| `tests/maintain-runtime.tests.sh`, `maintain-delivery.tests.sh` | Label-only rewrites: MR21bind-a/b, MR24b ("leased dedicated worktree" → "primary checkout"), MD1b1 ("dirty legacy worktree"), MD1c ("branch-attached worktree") | PR 3 |
| `tests/agent-events.tests.sh` | EV55-EV58, EV60: re-fixture guard-buffer→publish + explicit override in a single primary repo | PR 4 |
| `tests/solution-signoff.tests.sh` | SG10 (~L68-69): update `--target-root "$WT"` spelling if `$WT` is dropped from protocol snippets | PR 3 |
| `scripts/workflow-probe.sh` | `pending_worktree == primary` assertion (~L186-199) simplifies once the receipt field is a pinned constant | PR 3 |

### 3c. KEEP (with reason)

- **`maintain-leases.sh` `assert_primary_only` (~L37-81), `resolve_repo`, `primary-root`** — the contract's enforcement gate. Also MR15/MR15aa1/aa2 and SG7 tests that create a linked worktree *only as a negative fixture* to prove the gate rejects it.
- **`guard-active.sh` + `*.active` markers + consumers (`auto-commit.sh`, `auto-commit-growth.sh`, `index-handoff.sh`, `compact-state.sh`, `auto-learn.sh`)** — this IS the single-tree pause/resume ownership mechanism. No dual-tree assumption.
- **`health-preflight.sh`** — `assert-primary-only` reporting, `git worktree prune` maintenance, and the `git:worktree` dirty check (the human-work detector). Exactly the contract.
- **`supervisor-commit.sh` shadow clone (`SHADOW`, L956-966) and the runtime seal/mount machinery (`discover_check_runtimes`, `load_check_runtime_receipt`, `--runtime`/`--checkout-alias`)** — deliberate decision, see §5. The shadow is a temp `git clone --no-local` (not a linked worktree) serving as the tamper-isolation boundary for trusted commits, and after PR 1 it mounts the primary's real deps at the primary's own path (`CHECKOUT_ALIAS=$PRIMARY_CHECKOUT=$ROOT`, L1415-1424) — same deps path as investor. The contract's "no deps-blind shadow path" is satisfied by making it deps-true, not by deleting the trust boundary.
- **`standard-medium-eval.sh`** — verified first-hand: uses `git clone --local --shared` (comment at L134: "not `git worktree add` — so product worktree list stays single") and re-asserts `assert-primary-only` on the product after setup (L152-155). Eval replay isolation, not the maintain runtime; contract-compliant. The whole SM test suite stays.
- **`delivery-mutation-guard.sh`** — its "worktree" vocabulary means git's working-tree diff kind (vs index/untracked), not a linked tree.
- **`agent-events.sh` `primary_worktree_root()`** — degenerates to `--show-toplevel` under primary-only but is harmless defensive resolution; optional simplification, not required (leave unless touched for other reasons).
- **Lease-key spelling `maintain:worktree:<cksum>`** — on-disk format of live lease state; MR6/MR21bind-f pin it deliberately. Renaming would break running products for zero behavior gain.
- **`controller_route.worktree` / `controller.worktree` receipt fields** — persisted receipt schema; keep the field, always written as the primary path. Schema stability beats a field rename across live receipts.
- **`SAAS_EMBEDDED_WORKTREE` envelope var** — value is the primary path; "worktree" here means working tree. Renaming is churn across goal-deliver.md, receipts doc, and WI24 for no behavior change.
- **`commands/lessons-deliver.md` worktree language** — plugin-repo flow (different repo), already primary-only, and its "never create a side worktree" lines enforce the ban.
- **`run-tests.sh` guardrails M26/M27/M27a/M27b/L52/L52b** — they assert the *absence* of worktree machinery; they are the sweep's permanent regression net.
- **Incidental "current git worktree" = working tree** mentions across skills/agents/README (`lawyer-operations.md`, `growth-hacker.md`, workflow-skill boilerplate, `README.md:441`, etc.) — correct usage, leave alone.
- **`maintain-protocol.md` ~L292 "legacy worktree ledger" read-until-empty** — upgrade-compat for pre-#330 blocked rows; retire in a later release once ledgers are drained on live projects (out of this sweep).

## 4. Root-cause map — how primary-only + leftover isolation still fails

1. **Base-check shadow went deps-blind (the shipped breakage).** Pre-fix `discover_primary_checkout` required `GIT_DIR != COMMON_DIR` and `candidate != ROOT` — impossible on a primary checkout — so `discover_check_runtimes` returned `[]`, the trust receipt sealed zero runtimes, and the shadow clone (`git clone --no-local` never copies ignored `node_modules`/`venv`) ran checks with no deps: frontend `tsc` failed on missing types while the investor's `tsc` on the primary was green. The staged fix restores discovery; what's missing is (a) collapsing the function so it *only* resolves ROOT (the staged version still quietly supports a linked-worktree parent — a dual-tree remnant), and (b) a primary-fixture regression test (the only seal test, RS19zkr, still fixtures a linked tree).
2. **Runtime bind messaging lies about the architecture.** `load_check_runtime_receipt` (~L777) and `snapshot_trust` (~L524) fail with "linked-worktree runtime source…" — on a primary-only product every such failure will send an operator (or a model agent reading logs) hunting for a linked worktree that cannot exist.
3. **Protocol docs still route and narrate dual-tree.** `maintain.md:~174` points the section loader at `Workspace — Dedicated Worktree`, a heading renamed to `Workspace — primary only` in #330 — the "Locate a requested `##` heading" instruction cannot match, so normal runs lose their workspace-protocol section. Residual vocabulary ("maintain worktree vs investor on main repo", "choosing a worktree", "cross-worktree") actively steers model agents toward the deleted model.
4. **Tests pin the old model.** WL6/WL6a assert the removed heading literal; RS19zkr's linked-tree fixture will break the moment PR 1 collapses discovery; five test blocks exist solely to exercise sibling-linked-worktree scenarios the gate now bans.
5. **Ownership plumbing carries a vestigial degree of freedom.** `--worktree` args, `WORKTREE_BINDING`, the `worktree` lease iteration over `"$PRIMARY" "$PRIMARY/.worktrees/maintain"`, and `disprove_source_state`'s claimed-tree verification all model "which tree?" — a question with exactly one answer. Dead flexibility is where the next regression hides.

## 5. Deletion-first design

**Order: fix the live breakage first, then docs, then delete plumbing, then delete tests.** Rationale: PR 1 unbreaks maintain on real products and locks the contract with a regression test; PR 2 fixes a live doc-routing bug and stops prompting agents into the old model; PRs 3-4 are pure shrinkage that the PR 1 test net makes safe.

Two deliberate **non-deletions** (decisions, not oversights):

- **Keep the supervisor shadow clone.** The scripts inventory suggested running checks in place on the primary and deleting the clone. Rejected for this sweep: the shadow is the *trusted-commit* isolation boundary (candidate diff verified byte-exact, checks cannot mutate the real tree or git metadata, commit built from sealed state). It is not a linked worktree, and after PR 1 it is not deps-blind — the primary's real `node_modules`/`venv` are digest-sealed and mounted read-only at the primary's own path inside the container. The contract ("checks work like investor on primary, same deps path") is met. In-place checking would be a security-architecture rewrite with real tamper-window risk — wrong trade for a cleanup sweep. Recorded in §9.
- **Keep the eval harness's separate clone.** Verified contract-compliant (clone, not worktree; product tree untouched and re-asserted primary-only). The entire SM suite stays.

**Pause/resume needs 5 lines of documentation, not code.** The mechanism exists (`guard-active.sh` markers gate background hooks; `health-preflight.sh` flags dirty trees; maintain stops on dirty primary; "pause the portfolio before human work" one-liners). No doc names the marker mechanism. PR 2 expands the `maintain-v2-contract.md` Actors table to state: loop owns the tree while `*.active` guard markers exist; human work = pause portfolio, tree may be dirty; loop resumes only on a clean primary. No new scripts, no state fields.

## 6. File-by-file change list (PR-ordered)

### PR 1 — supervisor base-check on primary, deps-true (version 0.89.65)

Includes the currently uncommitted changes.

**`plugins/saas-startup-team/scripts/supervisor-commit.sh`**
- [ ] Replace `discover_primary_checkout` (L348-364) with the ROOT-pinned form; a linked-worktree ROOT now yields no sealed runtimes instead of reaching over to a parent tree (upstream `assert-primary-only` gates already refuse linked trees before delivery reaches this script):

```bash
discover_primary_checkout() {
  # Single-worktree contract: the primary checkout IS this checkout. Runtime
  # deps (node_modules/venv) are discovered here or not at all.
  [ "$(basename -- "$COMMON_DIR")" = .git ] || return 1
  [ "$(cd "$(dirname -- "$COMMON_DIR")" && pwd -P)" = "$ROOT" ] || return 1
  PRIMARY_CHECKOUT=$ROOT
}
```

- [ ] Rename the three legacy error strings (behavior unchanged):
  - L524: `could not seal linked-worktree check runtimes` → `could not seal primary-checkout check runtimes`
  - L777: `linked-worktree runtime source is no longer available` → `primary-checkout runtime source is no longer available`
  - L1432: `linked check runtime changed during deterministic checks` → `sealed check runtime changed during deterministic checks`

**`plugins/saas-startup-team/tests/runtime-safety.tests.sh`**
- [ ] Rewrite the RS19zkr block (~L1159-1346): drop the `git worktree add -b runtime-check "$linked"` fixture; the fixture repo's **primary** tree gets an ignored, untracked `node_modules/` with a real `.bin/` marker and a `venv/bin/python` executable, plus a tracked `package-lock.json` (so `manifest_json_for_tree` is non-empty). Keep the existing assertions, now against the primary: trust receipt `check_runtimes` length ≥ 1; check script sees `node_modules` inside the sandbox; digest-drift and escape cases still fail closed. Preserve RS19s2/s3/s5 with wording that no longer implies a linked source.

**Version + docs**
- [ ] `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json` — already 0.89.65 (staged).
- [ ] Root `.claude-plugin/marketplace.json` — bump saas-startup-team `0.89.64` → `0.89.65` (currently missing; pre-push hook will reject without it).

**Verify**
- [ ] `bash plugins/saas-startup-team/tests/run-tests.sh` — green.
- [ ] Live proof on aruannik-dev (see §7).

### PR 2 — protocol docs + heading-pin tests (version 0.89.66)

- [ ] `references/workflows/maintain.md` — ~L174 `` `Workspace — Dedicated Worktree` `` → `` `Workspace — primary only` `` (the live routing bug); ~L86 drop "or choosing a worktree"; ~L178 "worktree reset" → "primary-tree reset"; ~L192-194 contract summary → "…auto-merge, primary checkout only, pause portfolio before investor work"; ~L203-205 "local maintain-worktree branch" → "local branch"; ~L245 "uncommitted maintain-worktree dirt" → "uncommitted primary-tree dirt".
- [ ] `references/workflows/maintain-protocol.md` — ~L68 "the persistent worktree" → "the primary working tree"; ~L71 and ~L115 drop "cross-worktree" (→ "concurrent-run overlap" at ~L115); ~L81 "the selected worktree" → "the primary worktree"; ~L87-89 "create/reset a worktree" → "reset the primary tree", "after worktree setup" → "after workspace setup".
- [ ] `references/workflows/maintain-v2-contract.md` — ~L30, ~L35 rewrites per §3b; expand the Actors table with the pause/resume signal sentences from §5.
- [ ] `references/workflows/goal-deliver-maintain-receipts.md` — ~L52 drop "/worktree selection"; ~L226-228 "dedicated worktree" → "primary tree"; ~L65-70 "bound worktree" → "bound primary tree".
- [ ] `docs/design/lessons-deliver.md` ~L43 — "dedicated worktree" → "primary-checkout delivery".
- [ ] `tests/workflow-lifecycle.tests.sh` — WL6/WL6a (~L60-63): retarget the heading literal to `Workspace — primary only` and the router-entry literal to match the maintain.md edit.
- [ ] Version bump all three manifests → 0.89.66. `run-tests.sh` green (WL suite validates the doc edits).

### PR 3 — delete the `--worktree`/lease/receipt dual-tree plumbing (version 0.89.67)

Cross-cutting; keep it one PR so scripts, protocol snippets, and tests move together.

- [ ] `scripts/maintain-leases.sh` — delete `foreign_worktree_leases_available` and all `"$PRIMARY/.worktrees/maintain"` branches (`allowed_controller_tree` collapses to `[ tree = PRIMARY ]`; `available`/reap loop over `"$PRIMARY"` only). Remove the `--worktree` argument: `acquire`/`controller-binding` derive the tree from `primary-root` internally; state-file `.worktree` field remains, always written as `$PRIMARY` (persisted-schema stability). Keep `worktree_lease_key`, key spelling, `assert_primary_only`, `resolve_repo` untouched.
- [ ] `scripts/maintain-attempt.sh` — drop `--worktree` (operate on `$ROOT`); delete the now-tautological `worktree == PRIMARY == ROOT` assertion chains (keep the single `ROOT == PRIMARY` gate). `_reset-held` interface updated in lockstep with its one caller (`maintain-escalation.sh`).
- [ ] `scripts/maintain-wip.sh` — drop the `--worktree` compat arg (~L49, ~L59-63); keep the JSON `worktree` output field as the primary path (receipts consume it).
- [ ] `scripts/maintain-escalation.sh` — drop `--worktree` pass-through; rewrite the "dedicated worktree" cleanup narration (~L282-290, ~L321-334) as primary-tree cleanup. Keep the stale-attempt `branch -D` where it deletes a failed delivery branch on the primary — that is live cleanup, not tree teardown; verify against script behavior while editing.
- [ ] `scripts/maintain-delivery.sh` — `normalize_controller_worktree`: delete the `.worktrees/maintain` branch (rollout preflight in §8 confirms no live receipts need it); `disprove_source_state` (~L711-774): delete the separate-tree verification (real-worktree check, common-dir equality), keeping "primary tree is clean/detached at the recorded base"; internal `maintain-leases.sh` calls lose `--worktree`.
- [ ] `scripts/workflow-probe.sh` — simplify the `pending_worktree == primary` check (~L186-199) to a schema assertion that the recorded value equals `primary-root` output (field stays; selection logic goes).
- [ ] Protocol docs — update the exact invocation snippets that pass `--worktree "$WT"` (`maintain-protocol.md` ~L39/43/45, `maintain.md` ~L223, `goal-deliver-maintain-receipts.md` ~L115-116/121/125/166-169, `goal-deliver.md` ~L49). `$WT` disappears or is defined once as `$REPO_ROOT` where prose still needs a name.
- [ ] Tests — `run-tests.sh` M45a3a (asserts `--worktree "$WT"` in protocol): retarget to the new snippet; `workflow-lifecycle` WL7f4/f5 (`--repo-root "$WT"` count): update spelling; `solution-signoff` SG10 `--target-root` spelling; `maintain-runtime`/`maintain-delivery`: update every `--worktree "$repo"` invocation and rewrite the stale labels (MR21bind-a/b, MR24b, MD1b1, MD1c); `workflow-context` stub's `worktree` field follows the receipt decision (stays).
- [ ] Version bump all three manifests → 0.89.67. `run-tests.sh` green.

### PR 4 — delete linked-worktree-premise tests (version 0.89.68)

- [ ] `tests/runtime-safety.tests.sh` — delete RS14i12a-e (sibling-worktree concurrency vs base-check; the ban plus `primary_boundary_fingerprint`/`metadata_fingerprint` fail-closed checks cover metadata drift on primary), RS19x8 and RS19zj (sibling-worktree branch advance vs role guard — same premise twice), RS19znu/znw (linked-worktree control-file identity). Keep RS19zo/zp (per-worktree hooks config on the lone primary — a git feature, still reachable).
- [ ] `tests/agent-events.tests.sh` — delete EV59 and the `linked_repo` fixture; re-fixture EV55-EV58/EV60 as guard-buffer→publish + explicit-override in a single primary repo.
- [ ] Confirm intentionally-kept negative fixtures still pass: MR15, MR15aa1/aa2, SG7 (create a linked tree only to prove rejection).
- [ ] Version bump all three manifests → 0.89.68. `run-tests.sh` green.

## 7. Test strategy

**Delete vs rewrite rule applied:** a test dies only when its *premise* is a coexisting linked worktree (RS14i12, RS19x8, RS19zj, RS19znu/znw, EV59). A test survives rewritten when it verifies behavior the contract keeps but its fixture or label is dual-tree (RS19zkr → primary-runtime seal; EV55-60 → single-repo; WL6/WL6a → new heading; MR/MD label edits). Negative fixtures that *prove the ban* (MR15aa1/aa2, SG7, M26/M27, L52b) are permanent keeps.

**Proving base-check green on primary with real deps:**
1. *Harness (PR 1):* the rewritten RS19zkr asserts, on a primary-only fixture repo with ignored `node_modules/.bin` + `venv/bin/python` and tracked manifests: trust receipt seals ≥1 runtime; the deterministic check observes the deps inside the sandbox; digest drift between snapshot and check fails closed.
2. *Live (PR 1 rollout):* on aruannik-dev after cache refresh, from the product primary checkout run the maintain probe (`workflow-probe.sh`) and a supervisor `--check-only` pass on a clean base; expected: no "could not seal" error, receipt `check_runtimes` lists the real `node_modules`, check log shows `tsc` green — matching the investor's `tsc` on the same tree.
3. *Regression net:* `run-tests.sh` M26/M27 (no `worktree add`, no `.worktrees/maintain` in generated commands) guard the whole sweep permanently.

## 8. Rollout

- **Sequence:** merge PRs 1→4 in order, each with its version bump (pre-push hook enforces plugin.json + marketplace.json sync; note the hook compares against the remote tip — bump after rebasing, per the epic-192 lesson).
- **Live projects (aruannik-dev, varustame):** before upgrading, confirm no maintain run is active (`guard-active.sh` exits 1, no `*.active` markers) and no pending receipt is mid-flight (`workflow-probe.sh` clean). Refresh the plugin cache (marketplace update + plugin reinstall in the dev container), then run `health-preflight.sh` and the §7 live proof.
- **PR 3 preflight:** before deleting the `.worktrees/maintain` normalization branch, grep live products' `<common-git-dir>/saas-startup-team/` receipts/state for `.worktrees/maintain`; expected empty (path retired since 0.89.61). If found, archive those receipts first.
- **Risk/rollback:** PR 1 is behavior-restoring (deps-visible checks) and low risk; worst case is a sealing failure surfacing as the renamed "could not seal" error, blocking commits but corrupting nothing (fail-closed). PRs 2/4 are docs/tests only. PR 3 is the widest interface change; its blast radius is contained by keeping on-disk lease-key spelling and receipt schema unchanged, so rollback = `git revert` + patch version bump + cache refresh, with no state migration in either direction.

## 9. Out of scope (explicit non-goals)

- **Removing the supervisor shadow clone / redesigning the trusted-commit boundary.** Contract is satisfied by deps-true sealing (§5). Revisit only as its own security-reviewed project.
- **`standard-medium-eval.sh` and the SM test suite.** Clone-based eval isolation is contract-compliant and out of the maintain runtime.
- **`/lessons-deliver` plugin-repo flow.** Different repository; already primary-only.
- **Renaming persisted formats:** lease-key `worktree:` spelling, receipt `controller_route.worktree`/`controller.worktree` fields, `SAAS_EMBEDDED_WORKTREE` env var, `worktree_clean` receipt field.
- **New pause/resume machinery.** Only documenting the existing guard-marker/dirty-tree mechanism (PR 2); no new commands, hooks, or state.
- **Retiring the legacy worktree ledger read (`maintain-protocol.md` ~L292)** — separate follow-up once live ledgers drain.
- **`agent-events.sh` `primary_worktree_root` simplification** — harmless as-is; do not touch just to shrink it.

## Ready-for-implementer checklist

- [ ] Working tree still holds the uncommitted `supervisor-commit.sh` + plugin.json changes (fold into PR 1; do not commit separately).
- [ ] PR 1: `discover_primary_checkout` collapsed to ROOT; 3 error strings renamed; RS19zkr re-fixtured to primary; marketplace.json bumped to 0.89.65; `run-tests.sh` green.
- [ ] PR 1 live proof on aruannik-dev: sealed runtimes non-empty, check `tsc` green on primary.
- [ ] PR 2: `maintain.md:~174` heading fix + WL6/WL6a retarget land together; vocabulary edits per §6; Actors table documents pause/resume signals; 0.89.66.
- [ ] PR 3 preflight ran (no `.worktrees/maintain` in live receipts); `--worktree` args deleted from scripts + docs + tests in one PR; on-disk key/receipt formats untouched; 0.89.67.
- [ ] PR 4: linked-premise tests deleted, negative-fixture ban tests still green; 0.89.68.
- [ ] After each merge: plugin cache refreshed on live dev containers before the next maintain cycle.
