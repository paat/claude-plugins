# Light / tweak fast path

Used by entrypoint `tweak` and by `goal-deliver` autonomous light (single issue,
`profile=light`, `ui_touch=false`, no `--full`).

## Shared containment

Prepare one minimal unified diff in a temporary file outside the repository. Do not edit
product files directly. Apply through:

```bash
helper_rc=0
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tweak-run.sh" \
  --routing-mode "$route_mode" \
  --patch "$patch_file" \
  --message "tweak: <summary>" \
  --mode new-branch|current \
  [--branch "tweak/${slug}" --parent "$default"] \
  --push || helper_rc=$?
```

The helper:

- Sets a short mutation role window and restores the prior value via EXIT/signal trap
- Stages the patch; runs staged-size and shared post-diff containment
  (≤3 files, ≤15 changed lines, no sensitive paths)
- Commits with project hooks enabled; pushes when requested
- Exit 20 → scope exceeded: escalate (tweak → `/improve`; goal light → deep after cleanup)
- Any other nonzero → failure; stop before PR handling

Preserve `helper_rc` across cleanup:

```bash
helper_rc=0
bash ... || helper_rc=$?
case "$helper_rc" in
  0) ;;
  20) helper_outcome=escalated ;;
  *) helper_outcome=failure ;;
esac
```

## Goal-deliver light (standalone only)

1. `LIGHT_BRANCH="tweak/<slug>"`; record `LIGHT_BASE_SHA` from `origin/$default`.
2. Invoke `tweak-run.sh` with `--routing-mode autonomous` / `--mode autonomous`
   classification upstream.
3. Open non-draft PR with `Fixes #<n>`. Require at least one CI check; poll with
   `poll-gate.sh --pr "$pr_num"`. Never treat absent checks as green.
4. On push/PR/check failure: **verified cleanup**, then one deep retry only if every
   postcondition passes. Otherwise stop and release the goal lease —
   releases `$GOAL_LEASE_KEY` with `$GOAL_OWNER_FILE`.
5. On green checks: supervisor may squash-merge and delete the branch, close the issue,
   continue to deployment watch. If the merge command fails, query that exact PR before doing anything else. A confirmed merged PR continues by syncing `$default`; unmerged
   follows cleanup; unknown stops.

**Verified light/mechanical cleanup:** close every open PR for that exact attempt head
and verify empty list; delete exact remote branch and verify
`git ls-remote --heads origin "refs/heads/$LIGHT_BRANCH"` empty; return to `$default`,
`git pull --ff-only`; delete only the exact local attempt branch; require current branch
is `$default` and empty `git status --porcelain`. No broad clean/reset. Unknown/failed
query → blocked terminal, release lease, stop.

Under `SAAS_EMBEDDED_CALLER=maintain`, light uses the receipt adapter's
`maintain-attempt.sh` transaction — not standalone `tweak-run.sh` merge/close.

## Mechanical profile

Run only the exact existing repository script named by the issue/request on a dedicated
branch. Shared post-diff containment, deterministic checks, `supervisor-commit.sh`,
PR/CI, and (for goal-deliver) deploy gates. Record `surface=script`,
`profile=mechanical`. If the script or expected output is not objective, set
`PROFILE=standard` and leave the light path; never improvise under mechanical.
