---
name: maintain-loop
description: Codex-first GitHub issue delivery loop. For each eligible issue, launch a fresh Codex context from the latest default branch, implement the issue, run Playwright acceptance QA, close the tribunal review/fix loop, merge to main, watch deploy, and verify the live app. Flags: --once, --dry-run, --issue N, --label LABEL, --max-issues N, --max-run-minutes N. Usage: /maintain-loop [--once] [--issue N] [--max-issues N]
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
- `--once`: run one pass, then stop.
- `--issue N`: deliver only that issue.
- `--label LABEL`: include only issues with this label.
- `--max-issues N`: cap delivered issues this pass; default `1`.
- `--max-run-minutes N`: total wall-clock cap; default `120`, `0` means unlimited.

## Preflight

1. Parse flags before doing anything that writes.
2. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/health-preflight.sh" --require-gh --require-codex --check-sync`.
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

Build the queue from GitHub, not local memory:

- `--issue N` means only that issue.
- Otherwise list open issues, optionally filtered by `--label`.
- Exclude issues labelled `needs-human`, `maintain:blocked`, `epic`, or already
  linked to an open PR.
- Honor explicit `depends on #N` / `blocked by #N` dependencies; do not infer edges.
- Order dependency-ready issues by severity labels `critical`, `high`, `medium`,
  `low`, then oldest first.

For each queued issue, write a small prompt file under
`.startup/maintain-loop/prompts/issue-<N>.md` containing only the issue number,
default branch, required protocol below, and the run id. The worker must fetch the
issue body/comments itself in its fresh context.

## Fresh Worker Launch

Reset the worktree before every issue:

```bash
git -C "$WT" fetch origin "$default" --quiet
git -C "$WT" checkout --detach "origin/$default"
git -C "$WT" reset --hard "origin/$default"
git -C "$WT" clean -fd
codex exec --ephemeral --cd "$WT" - < ".startup/maintain-loop/prompts/issue-$N.md"
```

Trusted automation may add `--dangerously-bypass-approvals-and-sandbox` only when
externally sandboxed; otherwise use the configured approval policy. Each
`codex exec --ephemeral` invocation is the required fresh Codex context for
exactly one issue.

## Per-Issue Worker Protocol

The fresh worker owns the whole issue delivery:

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
9. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/issue-closure-audit.sh" --pr "<pr url>"`
   for closing PRs and fix any mismatch or switch the PR to `Refs #N`.
10. Load and follow `tribunal-review:closing-tribunal-loop`. Iterate review/fix
    cycles until the latest arbiter verdict covers the current PR HEAD and latest
    diff with zero critical/high findings. Any code diff, validation-changing PR
    body edit, rebase, update-from-main, or HEAD change reopens the closing loop.
11. Final merge gate: update from default, rerun required checks, re-run closure
    audit if closing metadata changed, then merge immediately on green:
    `gh pr merge "<pr url>" --squash --delete-branch`. If default moves, restart
    final validation.
12. Watch the default-branch deploy:
    `gh run list --branch "$default" --limit 1 --json databaseId -q '.[0].databaseId'`
    then `gh run watch "$run_id" --exit-status`.
13. Ensure live working after deploy. Determine the live URL from `SAAS_LIVE_URL`,
    the deployment output, or repo docs/config. Run a safe Playwright smoke or the
    issue acceptance flow against that live URL. "Done" requires both deploy green
    and live Playwright pass. If no live URL can be determined, mark the issue
    blocked; do not report it as live working.
14. On deploy/live failure, classify from concrete logs. If the merged diff is
    implicated, open `deploy-fix/<slug>` and repeat checks, Playwright QA,
    closing tribunal loop, merge, deploy watch, and live verification. For infra,
    credentials, external dependency, migration-data, or low-confidence failure,
    stop further merges and mark `maintain:blocked`. If production is clearly
    broken and not quickly fixable, revert only this loop's own merge and verify
    the rollback deploy.
15. Write `.startup/maintain-loop/runs/<run-id>/issue-<N>.md` with final state:
    `fixed:PR#`, `blocked:<reason>`, `skipped:<reason>`, or `needs-human:<reason>`,
    plus PR link, commit SHA, tribunal verdict, check URLs, deploy URL, live QA
    evidence, and elapsed time.

The supervisor counts an issue as delivered only when the worker artifact records
`fixed:PR#`, deploy green, and live Playwright verification passed.

## Stop Rules

Stop the pass when `--max-issues`, `--max-run-minutes`, a required dependency is
missing, a tribunal loop reaches its hard ceiling, or any deploy/live failure is
not confidently fixed. Under `--once`, report the pass summary and exit.
Final report: queue size, issue final states, PR links, deploy/live status, and
blockers requiring human action. Keep implementation details in the worker artifact.
