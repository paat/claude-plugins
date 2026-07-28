# Worker reliability rules

- **Native worktrees coexist.** Isolation prefers `git worktree` or a disposable
  clone (#389). Never auto-delete foreign worktrees. Never set `core.worktree`.
  Do not hard-reset or `clean` the primary checkout on cancel.
- **Re-resolve paths after any checkout/branch/worktree switch.** Before further
  file operations, re-run `git rev-parse --show-toplevel` and rebuild absolute
  paths from it — cwd and relative paths go stale across a switch, which is how
  edits land in the wrong tree.
- **Retry a stale read once.** If an Edit is rejected because the file changed on
  disk, re-Read the target once and retry the edit once. If it still fails, stop
  and report — do not loop.
