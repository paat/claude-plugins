# Worker reliability rules

- **No worktrees except maintain (hard).** Linked worktrees are disallowed
  except `.worktrees/maintain` (autonomous `/maintain` / `/maintain-loop` only).
  Never create `.worktrees/maintain-loop`, `.worktrees/improve-*`, per-issue
  trees, or preserve copies. Never set `core.worktree` on the primary checkout.
  `/improve`, `/tweak`, and other one-shots run on the primary checkout (main
  repo dir) only.
- **Re-resolve paths after any checkout/branch/worktree switch.** Before further
  file operations, re-run `git rev-parse --show-toplevel` and rebuild absolute
  paths from it — cwd and relative paths go stale across a switch, which is how
  edits land in the wrong tree.
- **Retry a stale read once.** If an Edit is rejected because the file changed on
  disk, re-Read the target once and retry the edit once. If it still fails, stop
  and report — do not loop.
