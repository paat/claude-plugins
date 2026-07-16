#!/usr/bin/env bash
# merge-guard.sh — deterministic post-merge verification.
#
# Usage:
#   merge-guard.sh check --base <pre-merge-ref> [--head <ref>] [--intended-file F]
#   merge-guard.sh cleanup --base <pre-merge-ref> [--head <ref>] --apply
#
# check: diff base..head; flag junk/stray files and unintended paths; run the
#   configured grep-based business invariants. Exit 0 clean, 3 findings,
#   1 failure, 2 usage.
# cleanup: with --apply, create a cleanup/<short-sha> branch that removes the
#   flagged junk files, push it, and open a PR (requires gh). Without --apply,
#   print what would be removed. Exit 3 when there is nothing to clean.
#
# Config (optional): .claude/merge-guard.json
#   { "extra_junk": ["glob", ...],
#     "not_junk": ["glob", ...],
#     "invariants": [ {"id": "...", "path_glob": "src/**",
#                      "pattern": "regex", "must": "present|absent",
#                      "message": "why this matters"} ] }
set -uo pipefail

MODE="${1:-}"; [ "$#" -gt 0 ] && shift || { echo "merge-guard: mode required (check|cleanup)" >&2; exit 2; }
BASE=""; HEAD="HEAD"; INTENDED=""; APPLY=0
need() { [ "$#" -ge 2 ] || { echo "merge-guard: $1 needs a value" >&2; exit 2; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)          need "$@"; BASE="$2"; shift 2 ;;
    --head)          need "$@"; HEAD="$2"; shift 2 ;;
    --intended-file) need "$@"; INTENDED="$2"; shift 2 ;;
    --apply)         APPLY=1; shift ;;
    *) echo "merge-guard: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BASE" ] || { echo "merge-guard: --base <pre-merge-ref> required" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "merge-guard: not a git repository" >&2; exit 1; }
git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "merge-guard: unknown base ref: $BASE" >&2; exit 2; }
git rev-parse --verify --quiet "$HEAD^{commit}" >/dev/null || { echo "merge-guard: unknown head ref: $HEAD" >&2; exit 2; }
CONFIG="$ROOT/.claude/merge-guard.json"
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
# A present-but-unreadable config must fail loudly, never silently skip the
# invariants it was supposed to enforce.
if [ -f "$CONFIG" ]; then
  [ "$HAVE_JQ" -eq 1 ] || { echo "merge-guard: $CONFIG exists but jq is missing" >&2; exit 1; }
  jq -e . "$CONFIG" >/dev/null 2>&1 || { echo "merge-guard: malformed config: $CONFIG" >&2; exit 1; }
fi

cfg_list() { # <jq filter> — config values, empty when config absent
  [ "$HAVE_JQ" -eq 1 ] && [ -f "$CONFIG" ] || return 0
  jq -r "$1" "$CONFIG"
}

# Editor droppings, temp files, and agent-session artifacts that leak onto
# main through squash merges.
BUILTIN_JUNK='.DS_Store
Thumbs.db
*.orig
*.rej
*~
*.swp
*.swo
*.tmp
*.bak
*.log
npm-debug.log*
yarn-error.log*
__pycache__/*
*.pyc
.idea/*
.vscode/*
nohup.out
core.[0-9]*
.claude/settings.local.json'

glob_match() { # <path> <glob> — ** treated as *
  case "$1" in ${2//\*\*/\*}) return 0 ;; *) return 1 ;; esac
}

is_junk() { # <path>
  local p="$1" g base
  base="$(basename "$p")"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if glob_match "$p" "$g" || glob_match "$base" "$g"; then
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        glob_match "$p" "$n" && return 1
      done <<< "$(cfg_list '(.not_junk // [])[]')"
      return 0
    fi
  done <<< "$BUILTIN_JUNK
$(cfg_list '(.extra_junk // [])[]')"
  return 1
}

# quotePath=false keeps non-ASCII names literal so junk globs still match.
# Filenames containing newlines are unsupported (documented).
changed_files() { git -c core.quotePath=false diff --name-only "$BASE..$HEAD" --; }
added_files()   { git -c core.quotePath=false diff --name-only --diff-filter=A "$BASE..$HEAD" --; }

find_junk() { # junk among files ADDED in the range (pre-existing files are not the merge's leak)
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_junk "$f" && printf '%s\n' "$f"
  done < <(added_files)
  return 0
}

case "$MODE" in
  check)
    findings=0
    junk="$(find_junk)"
    if [ -n "$junk" ]; then
      findings=1
      echo "JUNK files leaked into $BASE..$HEAD (run 'merge-guard.sh cleanup --base $BASE --apply'):"
      printf '%s\n' "$junk" | sed 's/^/  /'
    fi
    if [ -n "$INTENDED" ]; then
      [ -f "$INTENDED" ] || { echo "merge-guard: intended file not found: $INTENDED" >&2; exit 2; }
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        ok=0
        while IFS= read -r g; do
          [ -n "$g" ] || continue
          if glob_match "$f" "$g"; then ok=1; break; fi
        done < "$INTENDED"
        if [ "$ok" -eq 0 ]; then
          [ "$findings" -eq 1 ] || { findings=1; }
          echo "UNINTENDED change: $f (not matched by $INTENDED)"
        fi
      done < <(changed_files)
    fi
    if [ "$HAVE_JQ" -eq 1 ] && [ -f "$CONFIG" ]; then
      US=$'\x1f'
      while IFS="$US" read -r id pglob pattern must message; do
        [ -n "$id" ] && [ -n "$pattern" ] || continue
        hit=0; grc=0
        git --no-pager grep -qE "$pattern" "$HEAD" -- "${pglob:-*}" 2>/dev/null || grc=$?
        if [ "$grc" -eq 0 ]; then hit=1
        elif [ "$grc" -gt 1 ]; then
          # Invalid regex/pathspec or a git failure must not read as clean.
          echo "merge-guard: invariant $id failed to evaluate (git grep rc=$grc; check pattern/path_glob)" >&2
          exit 1
        fi
        case "$must" in
          present) [ "$hit" -eq 1 ] || { findings=1; echo "INVARIANT $id VIOLATED: pattern absent from ${pglob:-repo} — ${message:-}"; } ;;
          absent)  [ "$hit" -eq 0 ] || { findings=1; echo "INVARIANT $id VIOLATED: forbidden pattern present in ${pglob:-repo} — ${message:-}"; } ;;
          *) echo "merge-guard: invariant $id has invalid must='$must' (present|absent)" >&2; exit 2 ;;
        esac
      done < <(jq -r '(.invariants // [])[] | [(.id // ""), (.path_glob // ""), (.pattern // ""), (.must // ""), (.message // "")] | join("\u001f")' "$CONFIG")
    fi
    if [ "$findings" -eq 0 ]; then
      echo "merge-guard: clean — no junk, no unintended files, invariants hold ($BASE..$HEAD)"
      exit 0
    fi
    exit 3 ;;
  cleanup)
    junk="$(find_junk)"
    [ -n "$junk" ] || { echo "merge-guard: nothing to clean in $BASE..$HEAD"; exit 3; }
    if [ "$APPLY" -eq 0 ]; then
      echo "merge-guard: would remove (re-run with --apply):"
      printf '%s\n' "$junk" | sed 's/^/  /'
      exit 0
    fi
    command -v gh >/dev/null 2>&1 || { echo "merge-guard: gh required for --apply" >&2; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "merge-guard: working tree not clean" >&2; exit 1; }
    orig="$(git rev-parse --abbrev-ref HEAD)"
    short="$(git rev-parse --short "$HEAD")"
    branch="cleanup/merge-guard-$short"
    restore() { # failure never strands the caller on a half-built cleanup branch
      git checkout -qf "$orig" 2>/dev/null
      git branch -qD "$branch" 2>/dev/null
      echo "merge-guard: $1 — restored $orig" >&2
      exit 1
    }
    git checkout -b "$branch" "$HEAD" >/dev/null 2>&1 || { echo "merge-guard: cannot create $branch" >&2; exit 1; }
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      git rm -q -- "$f" || restore "git rm failed for $f"
    done <<< "$junk"
    git commit -q -m "chore: remove junk files leaked by merge ($short)" || restore "commit failed"
    git push -u origin "$branch" >/dev/null 2>&1 || restore "push failed"
    body="$(printf 'merge-guard post-merge tail: these files leaked onto the default branch in %s..%s and match junk signatures:\n\n%s\n' \
      "$BASE" "$HEAD" "$(printf '%s\n' "$junk" | sed 's/^/- /')")"
    gh pr create --title "chore: remove junk files leaked by merge ($short)" --body "$body" \
      || { echo "merge-guard: PR creation failed (branch $branch is pushed)" >&2; exit 1; }
    ;;
  *) echo "merge-guard: unknown mode: $MODE (check|cleanup)" >&2; exit 2 ;;
esac
