# Worker reliability rules

- **No linked git worktrees (hard).** Primary working directory only.
  `assert-primary-only` fails closed if any extra worktree exists; it never
  auto-deletes them. Never set `core.worktree` or run `git worktree add`.
  Pause the portfolio and stop — do not sweep foreign trees. Isolated stacks
  (replay, disposable verification) use a plain `git clone` outside the linked
  worktree list. `/improve`, `/tweak`, and other one-shots run on the primary
  checkout (main repo dir) only.
- **Never writable-link primary dependency runtimes.** Do not `ln -s` primary
  `node_modules` / `venv` / `.venv` into a disposable clone. Use
  `scripts/bind-dependency-runtime-view.sh` (private copy) or let the sealed
  supervisor check mount read-only copies.
- **Re-resolve paths after any checkout/branch/worktree switch.** Before further
  file operations, re-run `git rev-parse --show-toplevel` and rebuild absolute
  paths from it — cwd and relative paths go stale across a switch, which is how
  edits land in the wrong tree.
- **Retry a stale read once.** If an Edit is rejected because the file changed on
  disk, re-Read the target once and retry the edit once. If it still fails, stop
  and report — do not loop.
