#!/usr/bin/env bash
# Single source of truth (SSOT) for maintain repository absolute paths.
#
# THE absolute repo path is MAINTAIN_PRIMARY — physical main worktree (pwd -P).
# Source this file and call maintain_paths_resolve. Do not invent alternate
# `pwd` without -P or string-equal checks against symlink aliases.
#
# Accepted input: any path that realpaths into the same repository common dir.
# Stored/compared identity: always MAINTAIN_PRIMARY (physical absolute path).
# Linked worktrees coexist (#389); callers must not auto-remove them.
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
