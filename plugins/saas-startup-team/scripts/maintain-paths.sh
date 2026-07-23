#!/usr/bin/env bash
# Single source of truth (SSOT) for maintain repository absolute paths.
#
# THE absolute repo path is MAINTAIN_PRIMARY — physical main worktree (pwd -P).
# Every maintain script must resolve identity through this file or the thin CLI
# `maintain-leases.sh primary-root` (which sources this). Do not invent alternate
# `pwd` without -P, raw `git rev-parse --show-toplevel`, or string-equal checks
# against symlink aliases such as /workspace.
#
# Accepted input: any path that realpaths into the same worktree.
# Stored/compared identity: always MAINTAIN_PRIMARY (physical absolute path).
# Self-heal rewrites controller.worktree onto MAINTAIN_PRIMARY in place — never
# quarantine delivery dirs for path alias drift.
#
# After maintain_paths_resolve SUPPLIED:
#   MAINTAIN_ROOT     — physical path of SUPPLIED (must equal primary for mutate)
#   MAINTAIN_PRIMARY  — SSOT absolute primary checkout path
#   MAINTAIN_COMMON   — physical git common directory
#
# shellcheck shell=bash
# This file is sourced; it does not execute on its own.

maintain_paths_canon() {
  # Resolve an existing directory to a physical absolute path.
  local path=$1
  [ -n "$path" ] || return 1
  (cd -- "$path" && pwd -P)
}

maintain_paths_same() {
  # True when both paths exist and realpath-equal.
  local a b
  a=$(maintain_paths_canon "$1") || return 1
  b=$(maintain_paths_canon "$2") || return 1
  [ "$a" = "$b" ]
}

maintain_paths_resolve() {
  local supplied=$1 raw record candidate candidate_common worktree_rows
  MAINTAIN_ROOT=""
  MAINTAIN_PRIMARY=""
  MAINTAIN_COMMON=""
  [ -n "$supplied" ] || return 1
  MAINTAIN_ROOT=$(maintain_paths_canon "$supplied") || return 1
  git -C "$MAINTAIN_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  raw="$(git -C "$MAINTAIN_ROOT" rev-parse --git-common-dir)" || return 1
  case "$raw" in /*) MAINTAIN_COMMON=$raw ;; *) MAINTAIN_COMMON="$MAINTAIN_ROOT/$raw" ;; esac
  MAINTAIN_COMMON=$(maintain_paths_canon "$MAINTAIN_COMMON") || return 1

  worktree_rows=$(mktemp) || return 1
  if ! git -C "$MAINTAIN_ROOT" worktree list --porcelain -z > "$worktree_rows"; then
    rm -f -- "$worktree_rows"
    return 1
  fi
  MAINTAIN_PRIMARY=""
  while IFS= read -r -d '' record; do
    case "$record" in
      'worktree '*)
        candidate=${record#worktree }
        if ! candidate=$(maintain_paths_canon "$candidate"); then
          continue
        fi
        raw="$(git -C "$candidate" rev-parse --git-common-dir 2>/dev/null)" || continue
        case "$raw" in /*) candidate_common=$raw ;; *) candidate_common="$candidate/$raw" ;; esac
        candidate_common=$(maintain_paths_canon "$candidate_common") || continue
        [ "$candidate_common" = "$MAINTAIN_COMMON" ] || continue
        # First worktree entry that shares this common dir is the main checkout.
        MAINTAIN_PRIMARY=$candidate
        break
        ;;
    esac
  done < "$worktree_rows"
  rm -f -- "$worktree_rows"
  [ -n "$MAINTAIN_PRIMARY" ] || return 1
  return 0
}

# Require caller is on the SSOT primary (physical). Symlink cwd is ok if realpath matches.
maintain_paths_require_primary() {
  local supplied=${1:-}
  if [ -n "$supplied" ]; then
    maintain_paths_resolve "$supplied" || return 1
  fi
  [ -n "${MAINTAIN_PRIMARY:-}" ] && [ -n "${MAINTAIN_ROOT:-}" ] || return 1
  [ "$MAINTAIN_ROOT" = "$MAINTAIN_PRIMARY" ]
}
