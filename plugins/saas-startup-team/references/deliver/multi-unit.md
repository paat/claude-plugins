# Multi-unit delivery (goal-deliver)

Load only for `SAAS_DELIVER_ENTRYPOINT=goal-deliver`.

## Plan into PR-sized chunks

Break work into coherent PR-sized units (~15–30 min implementation each). Order so
dependencies merge first. Track with an in-context todo list — no ordering engine or
state file.

For every chunk, attach acceptance packs from
`scripts/acceptance-packs.sh --render <pack ids>`. When a candidate has no packs, run
`--select --category <category> --text <need>`.

Optional specialist planning (business/tech feasibility) only when an evidence gap can
change `Done`. On Claude, optional registered maintain agents; on Codex,
`product-discovery` / `tech-founder` skill or `codex-run-role.sh`. Supervisor owns the
final chunk list.

## Per-chunk delivery

For each ready chunk (dependencies merged):

0. **Claim work unit** (standalone):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
     --acquire "goal-deliver:${chunk_slug}" \
     --state-dir .startup/leases \
     --owner-file ".startup/leases/.owners/goal-deliver-${chunk_slug}.owner" \
     --ttl-seconds 1800
   ```
   Embedded skips this second delivery-scope lease acquisition.

1. **Build** via the deliver graph (`SKILL.md` Plan→Build→Review) in new-branch mode off
   the default branch. Embedded uses the receipt adapter for its source transaction, one
   bound PR, and persisted recovery while applying the same acceptance and quality
   requirements.

2. **Close the tribunal loop** on the open PR. Load and follow
   `tribunal-review:closing-tribunal-loop` (PR-only; each round is a PR comment). Run
   `tribunal-review:tribunal-loop`. When the PR uses `Closes`/`Fixes`/`Resolves`, include:
   **Does this PR satisfy every material promise in the full issue body and comments it
   closes, or only a subset?**

   Gate closed only when the arbiter returns **zero critical and zero high** (leftover
   medium/low → YAGNI triage in the closing round PR comment). While critical/high remain:

   - **Rounds 1–2:** post round comment, then fix, push, re-run.
   - **Round 3+:** step-back — simplify, descope, or down-rate; never guard-pile.
   - **Round 3:** PR checkpoint comment + notify investor without stopping.
   - **Round 5:** PR ceiling comment, stop, escalate. Round numbers are cumulative from
     existing `<!-- tribunal-round:N -->` markers (resume-safe).

   On ceiling: skip dependent chunks; continue independent ones.

3. **Issue-closure audit, then merge** (standalone). Before merging any PR with closing
   keywords:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue-closure-audit.sh" --pr "<pr url>"
   ```
   On audit fail: implement missing surface, add `## Closure audit` with follow-up, or
   change to `Refs #<n>`. Then re-run.

   Merge per `templates/merge-policy.md` only after audit passes. Update from current
   default, rerun complete **latest-HEAD gates**, bind `BOUND_SHA` to local HEAD, require
   freshly fetched PR `headRefOid` equals it:

   ```bash
   gh pr merge "<pr url>" --match-head-commit "$BOUND_SHA" --squash --delete-branch
   ```

   Any default/head advance restarts final validation. Close chunk issues
   (`gh issue close <n> --comment "Delivered in <pr url>"`) and
   `git checkout "${default}" && git pull --ff-only`.

   Incident-labeled issues (`bug`/`monitor`/`customer-issue`): merge blocked by the
   regression-test gate unless the PR adds a test or records
   `Regression-Test: none — <reason>`.

   Embedded path records the same current-head gates and delegates pinned merge,
   post-deploy release, delayed close, and crash recovery to the receipt adapter.

## Deploy watch

After the last chunk merges (at least one merged), watch runs for the **exact final merge
commit** — never "the latest run":

```bash
merge_sha=$(gh pr view "<final pr url>" --json mergeCommit -q .mergeCommit.oid)
```

If local config has `deploy.workflow`, pass `--workflow "<name>"`. Poll with backoff:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/poll-gate.sh" --deploy-sha \
  "$merge_sha" --branch "${default}" [--workflow "<name>"]
```

`green`/`red`/`pending`; sleep 60s doubling to 480s cap; 30-minute total budget. Without
pinned workflow, on first green sleep 60s and re-poll once for chained deployments.

On failure: find the failing matching run (`gh run list` filtered to `headSha ==
$merge_sha`), read logs (`gh run view --log-failed`) → fix on `deploy-fix/<slug>` →
tribunal → merge → refresh `merge_sha` → re-watch. Repeat until green or investor needed.

Embedded: classify deploy failure; code regression eligible only for the receipt adapter's
one causal safe rollback; infra/flaky/external/credential/migration-data/low-confidence →
`deploy-blocked`. Never revert another actor's commit.

After green, when `ui-touch.sh --range <pre-run SHA>..HEAD` is not `no-ui`, run
post-deploy visual smoke per `design-review-leg.md`. Attributable render regression →
rollback; ambiguous → escalate.

## Terminal and lease release

Standalone: after final verified green (or handled blocked/cancelled), append terminal
events and release `$GOAL_LEASE_KEY` with `$GOAL_OWNER_FILE`. Embedded: adapter records
live/release evidence, delayed close when eligible; heartbeats but never releases the
caller's lease.

Do not release while a PR, merge-state query, rollback, or deployment action is still
running. If cleanup cannot be verified, record blocked and preserve evidence.
