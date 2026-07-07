---
name: maintain-loop
description: Codex-first GitHub issue delivery loop. For each eligible issue, launch a fresh Codex context from the latest default branch, implement the issue, run Playwright acceptance QA, close the tribunal review/fix loop, merge to main, watch deploy, and verify the live app. Flags: --once, --dry-run, --issue N, --label LABEL, --max-issues N, --max-merges N, --max-run-minutes N. Usage: /maintain-loop [--once] [--issue N] [--max-issues N] [--max-merges N]
user_invocable: true
---

# /maintain-loop - Fresh-Context Issue Delivery

Use this for deliverable GitHub issue backlogs where each issue must ship through
an isolated implementation context. Use `/maintain` for triage/splitting first.

The current session is only the supervisor. It may inspect queue metadata, create
the dedicated worktree, start fresh workers, and read their final artifacts. It
must not carry issue bodies, code diffs, QA traces, tribunal transcripts, or deploy
logs between issues. If a fresh worker cannot be started, stop instead of
implementing in the supervisor context.

## Flags

- `--dry-run`: read-only; list the queue and planned worker prompts only.
- `--once`: deliver at most one issue, then stop.
- `--issue N`: deliver only that issue.
- `--label LABEL`: include only issues with this label.
- `--max-issues N`: cap delivered issues this pass; default unset, meaning no
  issue-count cap.
- `--max-merges N`: cap issue and deploy-fix merges this pass; default `5`.
  Emergency rollback may exceed this only to restore production, then the pass
  stops.
- `--max-run-minutes N`: total wall-clock cap; default `120`, `0` means unlimited.

## Preflight

1. Parse flags before doing anything that writes. Before the per-issue loop, set
   `ONCE=1` when `--once` is passed, set `MAX_MERGES` from `--max-merges` or
   default `5`, and initialize `MERGES_USED=0`. If `--max-issues` is set,
   initialize `MAX_ISSUES`; if `--once` is set, override `MAX_ISSUES=1`.
   Initialize `ISSUES_DELIVERED=0`, and mint one `RUN_ID` for all worker
   artifacts in this pass.
2. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/health-preflight.sh" --require-gh --require-codex --check-sync`.
   This must pass the `codex:worker-shell` smoke check before queue selection.
3. Confirm `tribunal-review:closing-tribunal-loop` and `tribunal-review:tribunal-loop` are available.
4. Confirm Playwright browser QA is available through the plugin MCP tools or the
   project already has a Playwright runner. Do not install Playwright ad hoc.
5. Resolve the default branch and create a dedicated detached worktree:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
default=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)
WT="$REPO_ROOT/.worktrees/maintain-loop"
grep -qxF '.worktrees/' "$REPO_ROOT/.git/info/exclude" 2>/dev/null \
  || echo '.worktrees/' >> "$REPO_ROOT/.git/info/exclude"
git -C "$REPO_ROOT" fetch origin "$default" --quiet
if ! git -C "$REPO_ROOT" worktree list --porcelain | grep -qx "worktree $WT"; then
  git -C "$REPO_ROOT" worktree add --detach "$WT" "origin/$default"
fi
```

Under `--dry-run`, skip the worktree create/update and print what would run.

## Queue

Build the queue from GitHub, not local memory. Use the plugin-owned queue
builder; do not hand-roll dependency parsing with ad hoc `jq scan(...)`.

- `--issue N` means only that issue.
- Otherwise list open issues, optionally filtered by `--label`.
- Exclude issues labelled `needs-human`, `maintain:blocked`, `epic`, or already
  linked to an open PR.
- Honor explicit `depends on #N` / `blocked by #N` dependencies; do not infer edges.
- Order dependency-ready issues by severity labels `critical`, `high`, `medium`,
  `low`, then oldest first.

```bash
queue_args=()
[ -n "${ISSUE:-}" ] && queue_args+=(--issue "$ISSUE")
[ -n "${LABEL:-}" ] && queue_args+=(--label "$LABEL")
[ -f .startup/maintain/blocked.jsonl ] && queue_args+=(--blocked-file .startup/maintain/blocked.jsonl)
if ! QUEUE_JSON="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/maintain-queue.sh" "${queue_args[@]}")"; then
  exit 1
fi
mapfile -t QUEUE < <(printf '%s\n' "$QUEUE_JSON" | jq -r '.queue[].number')
```

If the builder exits non-zero, stop the pass and report its stderr. A zero
eligible queue is acceptable only when the JSON report accounts for every open
issue under `excluded`; otherwise the builder fails loudly.

For each queued issue, generate or rewrite a small prompt file immediately before
worker launch, after computing the current remaining merge budget. Write it under
`.startup/maintain-loop/prompts/issue-<N>.md` containing only the issue number,
default branch, assigned worktree path, remaining merge budget, required protocol
below, and the run id. The prompt must explicitly tell the worker that every
shell command touching the repo starts with `cd <assigned worktree> &&`; the
worker must not rely on tool `workdir` / `--cd` alone. The worker must fetch the
issue body/comments itself in its fresh context.

## Fresh Worker Launch

Reset the worktree before every issue:

```bash
MAX_MERGES="${MAX_MERGES:-5}"
MERGES_USED="${MERGES_USED:-0}"
ONCE="${ONCE:-0}"
MAX_ISSUES="${MAX_ISSUES:-}"
if [ "$ONCE" = 1 ]; then
  MAX_ISSUES=1
fi
ISSUES_DELIVERED="${ISSUES_DELIVERED:-0}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
SANDBOX="${CODEX_SANDBOX:-workspace-write}"
for N in "${QUEUE[@]}"; do
  if [ -n "$MAX_ISSUES" ] && [ "$ISSUES_DELIVERED" -ge "$MAX_ISSUES" ]; then
    break
  fi
  REMAINING_MERGES=$((MAX_MERGES - MERGES_USED))
  [ "$REMAINING_MERGES" -gt 0 ] || break
  PROMPT="$REPO_ROOT/.startup/maintain-loop/prompts/issue-$N.md"
  # Generate/rewrite "$PROMPT" here, including REMAINING_MERGES.
  git -C "$WT" fetch origin "$default" --quiet
  git -C "$WT" checkout --detach "origin/$default"
  git -C "$WT" reset --hard "origin/$default"
  git -C "$WT" clean -fd
  (cd "$WT" && codex exec --ephemeral -s "$SANDBOX" --cd "$WT" - < "$PROMPT")
  ARTIFACT="$WT/.startup/maintain-loop/runs/$RUN_ID/issue-$N.md"
  [ -f "$ARTIFACT" ] || { echo "missing worker artifact: $ARTIFACT" >&2; break; }
  merge_count="$(awk -F: '/^merge_count:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' "$ARTIFACT")"
  case "$merge_count" in ''|*[!0-9]*) echo "malformed merge_count in $ARTIFACT" >&2; break ;; esac
  overage_reason="$(awk -F: '/^merge_budget_overage:/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' "$ARTIFACT")"
  if [ "$merge_count" -gt "$REMAINING_MERGES" ] &&
     { [ "$overage_reason" != "rollback" ] || [ "$merge_count" -gt $((REMAINING_MERGES + 1)) ]; }; then
    echo "over-budget merge_count in $ARTIFACT" >&2
    break
  fi
  MERGES_USED=$((MERGES_USED + merge_count))
  if [ "$overage_reason" = "rollback" ]; then
    break
  fi
  grep -q '^fixed:' "$ARTIFACT" && ISSUES_DELIVERED=$((ISSUES_DELIVERED + 1))
done
```

The default `-s workspace-write` is the normal worker sandbox. If that sandbox
cannot execute commands in a disposable dev container, set
`CODEX_SANDBOX=danger-full-access`; preflight blocks that mode unless container isolation is detected. `read-only` is not valid for implementation workers. Do not use
`--dangerously-bypass-approvals-and-sandbox`. Each `codex exec --ephemeral`
invocation is the required fresh Codex context for exactly one issue.

## Per-Issue Worker Protocol

The fresh worker owns the whole issue delivery. At the start, verify `pwd` and
`git rev-parse --show-toplevel` both point at the assigned worktree. Prefix every
repo-touching shell command with `cd <assigned worktree> &&` even when the Codex
tool call has a workdir. Stop if a command runs in any other checkout.

1. Fetch the issue with `gh issue view N --json number,title,body,labels,comments,updatedAt`
   and linked PR state. Stop if closed, parked, already claimed by an open PR, or
   materially ambiguous.
2. Create one branch from `origin/<default>` named `issue/<N>-<slug>`.
3. Identify the root cause / recurrence class and write objective acceptance
   criteria. Fix the class, not only the observed instance.
4. Implement the minimal scoped change. No drive-by refactors.
5. For bug, monitor, customer, accounting, replay, incident, production, payment,
   auth, data, and migration issues, add a regression test, contract test, monitor
   assertion, invariant, fixture, or equivalent guard that fails on the old behavior.
6. Run the relevant project checks and start the documented local dev server.
7. Run Playwright acceptance QA before tribunal:
   - Exercise the affected customer-visible flow at desktop width and 375px mobile.
   - Capture screenshot/snapshot evidence and console errors.
   - Test the specific acceptance criteria, not only page load.
   - Prefer the plugin Playwright MCP tools. If the project has Playwright tests,
     a focused test may also be added/run. Do not use curl/wget as browser QA.
   - If no browser-visible surface changed, record
     `Business-founder Playwright QA: not applicable - <reason>` in the PR body.
8. Open a PR with `Closes #N` only when every material issue promise is satisfied.
   The PR body must include the root-cause class, red-before/green-after proof,
   guard path or not-applicable reason, Playwright acceptance evidence, and risk notes.
9. Resolve and run the closure audit in the worker at execution time; do not
   paste a previously resolved versioned plugin-cache path into the prompt:
   ```bash
   PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
   if [ -n "$PLUGIN_ROOT" ] && [ -f "$PLUGIN_ROOT/scripts/issue-closure-audit.sh" ]; then
     AUDIT_SCRIPT="$PLUGIN_ROOT/scripts/issue-closure-audit.sh"
   else
     CACHE_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/cache"
     AUDIT_SCRIPT="$(
       find "$CACHE_ROOT" -path '*/saas-startup-team/*/scripts/issue-closure-audit.sh' -type f 2>/dev/null |
         awk '
           BEGIN { best = "" }
           function version_key(path, rest, parts, segs, i, out) {
             split(path, rest, "/saas-startup-team/")
             split(rest[2], parts, "/")
             split(parts[1], segs, ".")
             out = "v"
             for (i = 1; i <= 4; i++) out = out sprintf("%09d", segs[i] + 0)
             return out
           }
           { key = version_key($0); if (key >= best) { best = key; selected = $0 } }
           END { print selected }
         '
     )"
   fi
   [ -f "$AUDIT_SCRIPT" ] || { echo "issue-closure-audit.sh not found" >&2; exit 1; }
   bash "$AUDIT_SCRIPT" --pr "<pr url>"
   ```
   Fix any mismatch or switch the PR to `Refs #N`.
10. Load and follow `tribunal-review:closing-tribunal-loop`. Iterate review/fix
    cycles until the latest arbiter verdict covers the current PR HEAD and latest
    diff with zero critical/high findings. Any code diff, validation-changing PR
    body edit, rebase, update-from-main, or HEAD change reopens the closing loop.
11. Final merge gate: update from default, rerun required checks, re-run closure
    audit if closing metadata changed, then check the remaining merge budget.
    Maintain `worker_merges_used`, initially `0`; before each issue or
    deploy-fix merge, require `worker_merges_used < remaining merge budget`. If
    no budget remains, stop before merging and write
    `blocked:merge-budget-exhausted`; otherwise merge immediately on green:
    `gh pr merge "<pr url>" --squash --delete-branch`. After each merge,
    increment `worker_merges_used` and record the merged PR in `merged_prs`. If
    default moves, restart final validation.
12. Watch the default-branch deploy:
    `gh run list --branch "$default" --limit 1 --json databaseId -q '.[0].databaseId'`
    then `gh run watch "$run_id" --exit-status`.
13. Ensure live working after deploy. Determine the live URL from `SAAS_LIVE_URL`,
    the deployment output, or repo docs/config. Run a safe Playwright smoke or the
    issue acceptance flow against that live URL. "Done" requires both deploy green
    and live Playwright pass. If no live URL can be determined, mark the issue
    blocked; do not report it as live working.
14. On deploy/live failure, classify from concrete logs. If the merged diff is
    implicated and forward merge budget remains, open `deploy-fix/<slug>` and
    repeat checks, Playwright QA, closing tribunal loop, merge-budget check,
    merge, deploy watch, and live verification. If the merged diff is implicated
    and no forward merge budget remains, or production is clearly broken and not
    quickly fixable, revert only this loop's own merge even when the merge budget
    is exhausted, record `merge_budget_overage:rollback`, verify the rollback
    deploy, and stop the pass. For infra, credentials, external dependency,
    migration-data, or low-confidence failure, stop further merges and mark
    `maintain:blocked`.
15. Write `.startup/maintain-loop/runs/<run-id>/issue-<N>.md` with final state:
    `fixed:PR#`, `blocked:<reason>`, `skipped:<reason>`, or `needs-human:<reason>`,
    plus PR link, `merge_count:<N>`, `merged_prs:<list>`, any
    `merge_budget_overage:<reason>`, commit SHA, tribunal verdict, check URLs,
    deploy URL, live QA evidence, and elapsed time. The artifact schema is
    line-oriented; `fixed:`, `merge_count:`, `merged_prs:`, and
    `merge_budget_overage:` markers must start at column 1.

The supervisor counts an issue as delivered only when the worker artifact records
`fixed:PR#`, deploy green, live Playwright verification passed, and a
`merge_count` that keeps forward merges within `--max-merges`. After each
worker, add `merge_count` to `MERGES_USED`; stop before launching another worker
when the remaining merge budget is less than 1, or whenever an emergency
rollback overage was recorded.

## Stop Rules

Stop the pass when no eligible issues remain, an explicit `--max-issues` cap is
reached, the `--max-merges` cap is reached, `--max-run-minutes` is reached, a
required dependency is missing, a tribunal loop reaches its hard ceiling, or any
deploy/live failure is not confidently fixed. Under `--once`, stop after one
issue and report the pass summary.
Final report: queue size, issue final states, PR links, deploy/live status, and
blockers requiring human action. Keep implementation details in the worker artifact.
