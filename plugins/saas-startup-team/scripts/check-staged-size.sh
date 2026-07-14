#!/bin/bash
# check-staged-size.sh — guard against committing oversized files or dependency/package stores.
#
# Catches the failure mode where an in-repo package store (.pnpm-store/, node_modules/, …) or a
# large prebuilt binary gets swept into a broad `git add`, producing a commit GitHub rejects
# (>100 MB/file) that only a destructive history rewrite can undo. Run it AFTER staging and
# BEFORE committing.
#
# Exit 0: staged tree is clean (or not a git repo — nothing to guard).
# Exit 1: an oversized file or a known dependency/store path is staged — prints remediation.
#
# Tunable: STARTUP_MAX_STAGED_MB (default 50). GitHub's hard per-file limit is 100 MB; 50 leaves
# headroom and flags bloat early.

set -euo pipefail

max_mb="${STARTUP_MAX_STAGED_MB:-50}"
max_bytes=$((max_mb * 1024 * 1024))

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$repo_root"

# Dependency trees and package stores that must never be committed, anchored to a path segment so
# we match `node_modules/`, `a/.pnpm-store/x`, `.yarn/cache/…` but not an unrelated `my-node_modules-notes.md`.
bad_re='(^|/)(node_modules|\.pnpm-store|\.pnpm|\.yarn/cache|\.yarn/unplugged|bower_components)(/|$)'

violations=""
inventory=$(mktemp) || exit 1
trap 'rm -f -- "$inventory"' EXIT
if ! git diff --cached --name-only -z > "$inventory"; then
  echo "[saas-startup-team] Cannot inspect the staged path inventory." >&2
  exit 1
fi

while IFS= read -r -d '' f; do
  # Flag dependency/store paths by name regardless of size (catches staged deletions too).
  if printf '%s' "$f" | grep -qE "$bad_re"; then
    violations+="  [dependency/store] $f"$'\n'
    continue
  fi
  # Measure the staged blob, not the working-tree copy. A staged deletion has
  # no blob; any other lookup failure is unsafe to interpret as size zero.
  if ! size=$(git cat-file -s ":$f" 2>/dev/null); then
    deletion_rc=0
    git diff --cached --quiet --diff-filter=D -- "$f" || deletion_rc=$?
    if [ "$deletion_rc" -eq 1 ]; then continue; fi
    echo "[saas-startup-team] Cannot inspect staged blob: $f" >&2
    exit 1
  fi
  [[ "$size" =~ ^[0-9]+$ ]] || {
    echo "[saas-startup-team] Invalid staged blob size: $f" >&2
    exit 1
  }
  if [ "$size" -gt "$max_bytes" ]; then
    mb=$((size / 1024 / 1024))
    violations+="  [${mb} MB > ${max_mb} MB limit] $f"$'\n'
  fi
done < "$inventory"

if [ -n "$violations" ]; then
  {
    echo "[saas-startup-team] Refusing to commit: the staged tree contains files that will break the push."
    echo "GitHub rejects any file >100 MB, and an in-repo package store bloats history irreversibly."
    echo ""
    printf '%s' "$violations"
    echo "Fix:"
    echo "  1. Add the offending paths to .gitignore (node_modules/, .pnpm-store/, .pnpm/, .yarn/, etc.)."
    echo "  2. Unstage them:  git rm -r --cached <path>"
    echo "  3. Re-run the commit."
    echo "If a large file is genuinely intended, raise the limit for this run: STARTUP_MAX_STAGED_MB=<n>."
  } >&2
  exit 1
fi

exit 0
