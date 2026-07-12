#!/usr/bin/env bash
# Exit 0 while a supervisor-authenticated role guard is active in this worktree.
set -euo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
git_dir=$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null) || exit 1
guard_dir="$git_dir/saas-startup-team"
[ -d "$guard_dir" ] || exit 1
compgen -G "$guard_dir/*.active" >/dev/null
