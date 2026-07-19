# Worker reliability rules

- **No linked git worktrees (hard).** Primary working directory only.
  `assert-primary-only` fails closed if any extra worktree exists. Never set
  `core.worktree`. Pause the portfolio before human work on the tree.
  `/improve`, `/tweak`, and other one-shots run on the primary checkout (main
  repo dir) only.
- **Re-resolve paths after any checkout/branch/worktree switch.** Before further
  file operations, re-run `git rev-parse --show-toplevel` and rebuild absolute
  paths from it — cwd and relative paths go stale across a switch, which is how
  edits land in the wrong tree.
- **Retry a stale read once.** If an Edit is rejected because the file changed on
  disk, re-Read the target once and retry the edit once. If it still fails, stop
  and report — do not loop.
