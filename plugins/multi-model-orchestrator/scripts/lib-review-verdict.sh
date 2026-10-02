#!/usr/bin/env bash
# Shared helpers for the runners and pool.sh:
# - review terminal-verdict check
# - provider failure classification (transient or plan limit → 75, auth → 77)
# - repository write detection
#
# Verdict check: case-insensitive. A line must be either a bare APPROVE/APPROVED or
# NEEDS_WORK / NEEDS WORK token, or the same token prefixed by VERDICT:.
# Markdown headings and bold decoration around the prefix or token are
# tolerated; empty output and prose containing those words are rejected.
mmo_has_review_verdict() {
  grep -Eiq '^[[:space:]]*#*[[:space:]]*\**(VERDICT\**[[:space:]]*:[[:space:]]*\**[[:space:]]*)?(APPROVE[D]?|NEEDS[ _]WORK)\**[[:space:]]*$' "$1"
}

# Print APPROVE or NEEDS_WORK from the LAST verdict-shaped line: the reviewer's
# final word is the verdict, so a bullet quoting the two options earlier in the
# prose cannot decide it. Same line shape as mmo_has_review_verdict.
mmo_terminal_verdict() {
  local last
  last="$(grep -Ei '^[[:space:]]*#*[[:space:]]*\**(VERDICT\**[[:space:]]*:[[:space:]]*\**[[:space:]]*)?(APPROVE[D]?|NEEDS[ _]WORK)\**[[:space:]]*$' "$1" | tail -n 1)"
  case "$(printf '%s' "$last" | tr '[:lower:]' '[:upper:]')" in
    *NEEDS*) printf 'NEEDS_WORK\n' ;;
    *APPROVE*) printf 'APPROVE\n' ;;
  esac
}

# Classify provider failure text from a single error-text file the runner built
# (Codex last ERROR: line, Claude api_error_status / API Error line, Grok stderr).
# Prints "transient", "auth", or nothing. Callers must not pass model stdout bodies.
mmo_classify_provider_failure() {
  local f="${1:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 0
  if grep -Eiq '\b(429|529|503)\b|overloaded|rate[[:space:]_-]?limit|usage[[:space:]_-]?limit|quota|resource[[:space:]_-]?exhausted|temporarily[[:space:]]+unavailable' "$f"; then
    printf 'transient\n'
    return 0
  fi
  if grep -Eiq '\b401\b|unauthorized|not[[:space:]]+signed[[:space:]]+in|not[[:space:]]+logged[[:space:]]+in|login[[:space:]]+required|(expired|invalid)[[:space:]]+(api[[:space:]]*key|token)|(api[[:space:]]*key|token).*(expired|invalid)' "$f"; then
    printf 'auth\n'
    return 0
  fi
}

# Reclassify a provider failure exit and print the runner exit line, then exit.
# Usage: mmo_finish <runner-name> <rc> <failure-text-file> [key=value ...]
mmo_finish() {
  local name="$1" rc="$2" errf="$3"
  shift 3
  local failure_kind=""
  case "$rc" in
    0|2|3|4|5|6|7|55|124) ;;
    *)
      failure_kind="$(mmo_classify_provider_failure "$errf")"
      case "$failure_kind" in
        transient) rc=75 ;;
        auth) rc=77 ;;
        *) failure_kind="" ;;
      esac
      ;;
  esac
  {
    printf '%s: exit=%s' "$name" "$rc"
    [ -z "$failure_kind" ] || printf ' failure=%s' "$failure_kind"
    local kv
    for kv in "$@"; do
      printf ' %s' "$kv"
    done
    printf '\n'
  } >&2
  exit "$rc"
}

# Fingerprint HEAD, index, working tree, and untracked file contents, so a caller can
# tell whether a leg wrote to the repository. Files whose path starts with the optional
# absolute IGNORE_PREFIX (a leg's --out and its .stream/.stderr/.exit siblings) do not
# count. Prints one cksum line; never fails.
mmo_tree_state() {  # mmo_tree_state REPO [IGNORE_PREFIX]
  local repo="$1" spec=(.)
  case "${2:-}" in "$repo"/*) spec+=(":(exclude)${2#"$repo"/}*") ;; esac
  {
    git -C "$repo" rev-parse --verify -q HEAD || true
    git -C "$repo" status --porcelain=v1 --untracked-files=all -- "${spec[@]}" || true
    git -C "$repo" diff --no-ext-diff --binary HEAD -- "${spec[@]}" || true
    git -C "$repo" ls-files -z --others --exclude-standard -- "${spec[@]}" | (cd "$repo" && xargs -0 -r cksum) || true
  } 2>/dev/null | cksum
}
