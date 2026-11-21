#!/usr/bin/env bash
# leg-preflight.sh — implement-leg gates called by pool.sh.
#
#   leg-preflight.sh --repo DIR [--task ID] [--prompt FILE]
#   leg-preflight.sh --after --repo DIR [--prompt FILE] [--out FILE]...
#
# Before dispatch: a dirty tree (git status --porcelain, so .gitignore and
# info/exclude stay out) exits 56 check=preflight unless MMO_ALLOW_DIRTY=<reason>.
# A --task that is an issue number whose GitHub issue is CLOSED exits 56
# check=preflight unless MMO_ALLOW_REDO=<reason>. No GitHub remote: allow.
# gh missing or failing: warn and allow.
#
# After a worker exit 0: a still-dirty tree exits 56 check=uncommitted unless
# MMO_ALLOW_UNCOMMITTED=<reason>, or the prompt bars committing. The bar is the
# worker contract: "the orchestrator commits", "leave the tree uncommitted",
# "Do not edit any other path or commit", or "Do not broaden scope or commit",
# unless a line also orders "Commit on" without "when your leg's contract permits".
# Leg --out files and the outcome/check records are not worker dirt.
# Escape reasons are printed on stderr. Exit 0 allows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"

mode=before
repo=""
task=""
prompt=""
outs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --after) mode=after; shift ;;
    --repo) [ "$#" -ge 2 ] || exit 2; repo="$2"; shift 2 ;;
    --task) [ "$#" -ge 2 ] || exit 2; task="$2"; shift 2 ;;
    --prompt) [ "$#" -ge 2 ] || exit 2; prompt="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || exit 2; outs+=("$2"); shift 2 ;;
    *) printf 'leg-preflight: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$repo" ] || { printf 'leg-preflight: --repo is required\n' >&2; exit 2; }
repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'leg-preflight: warning: not a git repository; allowing\n' >&2
  exit 0
}

escape_reason() { # escape_reason VAR
  local name="$1" raw=""
  [ -n "${!name+x}" ] && raw="${!name}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  printf '%s' "$raw"
}

# 0 when the prompt tells the worker not to commit (the orchestrator commits).
commit_barred() {
  local file="$1" line unconditional=0
  [ -n "$file" ] && [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'Commit on '*)
        case "$line" in
          *'when your leg'"'"'s contract permits'*) ;;
          *) unconditional=1 ;;
        esac
        ;;
    esac
  done < "$file"
  [ "$unconditional" -eq 0 ] || return 1
  grep -Eq 'the orchestrator commits|leave the tree uncommitted|Do not edit any other path or commit|Do not broaden scope or commit' "$file"
}

worktree_status() { # prints porcelain; fails when git cannot answer
  local -a mmo_spec
  mmo_out_spec "$repo" ${outs[@]+"${outs[@]}"} \
    "${MMO_OUTCOMES_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator/outcomes.tsv}" \
    "${MMO_LEG_CHECKS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator/leg-checks.tsv}"
  git -C "$repo" status --porcelain=v1 --untracked-files=all -- "${mmo_spec[@]}"
}

parse_github_slug() {
  local url="$1" slug=""
  case "$url" in
    git@github.com:*) slug="${url#git@github.com:}" ;;
    ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
    https://github.com/*) slug="${url#https://github.com/}" ;;
    http://github.com/*) slug="${url#http://github.com/}" ;;
    *) return 1 ;;
  esac
  slug="${slug%.git}"
  slug="${slug%/}"
  [[ "$slug" =~ ^[^/]+/[^/]+$ ]] || return 1
  printf '%s' "$slug"
}

github_slug() {
  local name url slug=""
  url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  slug="$(parse_github_slug "$url" 2>/dev/null || true)"
  if [ -z "$slug" ]; then
    while read -r name; do
      [ "$name" = origin ] && continue
      url="$(git -C "$repo" remote get-url "$name" 2>/dev/null || true)"
      slug="$(parse_github_slug "$url" 2>/dev/null || true)"
      [ -n "$slug" ] && break
    done < <(git -C "$repo" remote 2>/dev/null || true)
  fi
  [ -n "$slug" ] || return 1
  printf '%s' "$slug"
}

dirty=""
if ! dirty="$(worktree_status)"; then
  printf 'leg-preflight: warning: cannot read worktree status; allowing\n' >&2
  dirty=""
fi

if [ "$mode" = after ]; then
  [ -n "$dirty" ] || exit 0
  if commit_barred "$prompt"; then
    exit 0
  fi
  reason="$(escape_reason MMO_ALLOW_UNCOMMITTED)"
  if [ -n "$reason" ]; then
    printf 'leg-preflight: MMO_ALLOW_UNCOMMITTED=%s\n' "$reason" >&2
    exit 0
  fi
  printf 'leg-preflight: exit=56 check=uncommitted dirty worktree after a worker exit 0\n' >&2
  exit 56
fi

if [ -n "$dirty" ]; then
  reason="$(escape_reason MMO_ALLOW_DIRTY)"
  if [ -n "$reason" ]; then
    printf 'leg-preflight: MMO_ALLOW_DIRTY=%s\n' "$reason" >&2
  else
    printf 'leg-preflight: exit=56 check=preflight dirty worktree\n' >&2
    exit 56
  fi
fi

issue="${task#\#}"
[[ "$issue" =~ ^[0-9]+$ ]] || exit 0
slug="$(github_slug || true)"
[ -n "$slug" ] || exit 0
if ! command -v gh >/dev/null 2>&1; then
  printf 'leg-preflight: warning: gh not found; not checking issue %s\n' "$issue" >&2
  exit 0
fi
gh_err="$(mktemp)"
trap 'rm -f "$gh_err"' EXIT
if ! gh_json="$(gh issue view "$issue" --repo "$slug" --json state 2>"$gh_err")"; then
  printf 'leg-preflight: warning: gh could not read issue %s; allowing\n' "$issue" >&2
  exit 0
fi
state="$(printf '%s' "$gh_json" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
state="$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
[ "$state" = CLOSED ] || exit 0
reason="$(escape_reason MMO_ALLOW_REDO)"
if [ -n "$reason" ]; then
  printf 'leg-preflight: MMO_ALLOW_REDO=%s\n' "$reason" >&2
  exit 0
fi
printf 'leg-preflight: exit=56 check=preflight issue %s is CLOSED\n' "$issue" >&2
exit 56
