---
name: merge-guard
description: Use immediately after merging a PR to the default branch (or when asked to verify a recent merge) — post-merge verification tail that catches junk files leaked by squash merges, unintended file changes, violated business invariants, and self-inflicted regressions adjacent to the touched code. Complements pre-merge review; it does not repeat it.
---

# Merge guard — post-merge verification tail

Pre-merge review gates the diff; the post-merge tail is where squash-merge
leaks, dropped parameters, and "cleanup" that reset working behavior slip
through. Run this right after a merge lands on the default branch.

## Steps

1. **Capture the range.** `base` = the default-branch commit before the merge
   (`git rev-parse 'HEAD^'` right after a squash merge, or the PR's
   `baseRefOid`); `head` = the merge commit.
2. **Deterministic check:**
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-guard.sh" check --base <base> --head <head>
   ```
   Add `--intended-file <file>` (one glob per line, e.g. the PR's changed-file
   list) to flag any path the merge touched that the PR did not intend.
   Exit 3 = findings, printed one per line.
3. **Junk findings** → open the cleanup PR instead of leaving it on main:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-guard.sh" cleanup --base <base> --head <head> --apply
   ```
   (Without `--apply` it only prints. The PR gets normal review; never push
   the removal straight to the default branch.)
4. **Invariant findings** → each configured invariant carries a message saying
   why it matters (e.g. "ad-click attribution parameter must survive checkout
   changes"). Read the violation, locate the regressing commit in the range,
   and fix forward or revert — do not silence the invariant.
5. **Adjacent regression spot-check** (the self-inflicted-regression class):
   identify user-facing behavior adjacent to the touched code — options,
   settings, tracking, recurring flows the diff did not mean to change — and
   verify one or two of them still work (run the relevant test, or exercise
   the flow). "Cleanup" commits that reset previously-working options are
   exactly what this catches; check what the diff *removed*, not only what it
   added.

## Configuration

`.claude/merge-guard.json` in the target repo:

```json
{
  "extra_junk": ["scratch-*", "*.local.yml"],
  "not_junk": ["docs/decisions/*.log"],
  "invariants": [
    {"id": "attribution-param", "path_glob": "src/checkout/*",
     "pattern": "utm_source|click_id", "must": "present",
     "message": "conversion attribution must survive checkout changes"}
  ]
}
```

`must: present` fails when the pattern is missing from the globbed paths at
`head`; `must: absent` fails when a forbidden pattern appears. Path globs use
git pathspec matching.
