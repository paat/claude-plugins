# Worker reliability rules

- **No linked product worktrees (hard).** Primary working directory only.
  `assert-primary-only` ignores leftover `/tmp/tribunal-*` review trees; any
  other extra worktree fails closed (never auto-deleted). Never set
  `core.worktree` or `git worktree add` for product isolation — use a plain
  `git clone`. `/improve`, `/tweak`, and one-shots run on the primary only.
- **Re-resolve paths after any checkout/branch/worktree switch.** Before further
  file operations, re-run `git rev-parse --show-toplevel` and rebuild absolute
  paths from it — cwd and relative paths go stale across a switch, which is how
  edits land in the wrong tree.
- **Retry a stale read once.** If an Edit is rejected because the file changed on
  disk, re-Read the target once and retry the edit once. If it still fails, stop
  and report — do not loop.
