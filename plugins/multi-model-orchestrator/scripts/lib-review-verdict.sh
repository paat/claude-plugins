#!/usr/bin/env bash
# Shared helpers for the runners and pool.sh:
# - review terminal-verdict check
# - provider failure classification (plan limit or transient → 75, auth → 77)
# - repository write detection
# - leg secret isolation (untracked .env* refusal, scrubbed environment)
#
# Verdict check: case-insensitive. A line must be either a bare APPROVE/APPROVED or
# NEEDS_WORK / NEEDS WORK token, or the same token prefixed by VERDICT:.
# Markdown headings and bold decoration around the prefix or token are
# tolerated, as is one trailing period (`**VERDICT: APPROVE.**`). Empty output
# and prose containing those words are rejected (`I approve.`).
mmo_has_review_verdict() {
  grep -Eiq '^[[:space:]]*#*[[:space:]]*\**(VERDICT\**[[:space:]]*:[[:space:]]*\**[[:space:]]*)?(APPROVE[D]?|NEEDS[ _]WORK)\**\.?\**[[:space:]]*$' "$1"
}

# Print APPROVE or NEEDS_WORK from the LAST verdict-shaped line: the reviewer's
# final word is the verdict, so a bullet quoting the two options earlier in the
# prose cannot decide it. Same line shape as mmo_has_review_verdict.
mmo_terminal_verdict() {
  local last
  last="$(grep -Ei '^[[:space:]]*#*[[:space:]]*\**(VERDICT\**[[:space:]]*:[[:space:]]*\**[[:space:]]*)?(APPROVE[D]?|NEEDS[ _]WORK)\**\.?\**[[:space:]]*$' "$1" | tail -n 1)"
  case "$(printf '%s' "$last" | tr '[:lower:]' '[:upper:]')" in
    *NEEDS*) printf 'NEEDS_WORK\n' ;;
    *APPROVE*) printf 'APPROVE\n' ;;
  esac
}

# Plain Grok output concatenates assistant messages with no separator, so a
# terminal verdict can sit mid-line (`worktree.VERDICT: NEEDS_WORK` or
# `worktree.**VERDICT: APPROVE**`). Split only when that trailing token,
# optionally **-decorated, is glued to a non-whitespace, non-* character.
# Match on tolower (POSIX awk has no IGNORECASE) and cut the original line at
# the same offset. A space or * before the token, or trailing prose, stays one
# line so the gate still rejects ordinary sentences.
mmo_separate_glued_verdict() {
  local src="$1" tmp
  [ -s "$src" ] || return 0
  tmp="$(mktemp)"
  awk '
    {
      if (match(tolower($0), /[^[:space:]*]((\*\*)?verdict(\*\*)?[[:space:]]*:[[:space:]]*(\*\*)?[[:space:]]*(approve[d]?|needs[ _]work)\**\.?\**[[:space:]]*)$/)) {
        print substr($0, 1, RSTART)
        print substr($0, RSTART + 1)
        next
      }
      print
    }
  ' "$src" > "$tmp"
  mv "$tmp" "$src"
}

# Classify provider failure text from a single error-text file the runner built
# (Codex last ERROR: line, Claude api_error_status / API Error line, Grok stderr).
# Prints "limit" (plan window or balance used up), "transient", "auth", or nothing.
# Callers must not pass model stdout bodies.
mmo_classify_provider_failure() {
  local f="${1:-}"
  [ -n "$f" ] && [ -s "$f" ] || return 0
  if grep -Eiq '\b402\b|usage[[:space:]_-]?limit|quota|(resource|balance|credits?)[[:space:]_-]?exhausted' "$f"; then
    printf 'limit\n'
    return 0
  fi
  if grep -Eiq '\b(429|529|503)\b|overloaded|rate[[:space:]_-]?limit|temporarily[[:space:]]+unavailable' "$f"; then
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
        limit|transient) rc=75 ;;
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
# tell whether a leg wrote to the repository. The optional absolute OUT path (a leg's
# --out) and the runner files written beside it (.stream, .stderr, .stream.stderr, .exit)
# do not count. Prints one cksum line; never fails.
mmo_tree_state() {  # mmo_tree_state REPO [OUT]
  local repo="$1" spec=(.) rel suffix
  case "${2:-}" in
    "$repo"/*)
      rel="${2#"$repo"/}"
      for suffix in '' .stream .stderr .stream.stderr .exit; do
        spec+=(":(exclude,literal)$rel$suffix")
      done
      ;;
  esac
  {
    git -C "$repo" rev-parse --verify -q HEAD || true
    git -C "$repo" status --porcelain=v1 --untracked-files=all -- "${spec[@]}" || true
    git -C "$repo" diff --no-ext-diff --binary --cached -- "${spec[@]}" || true
    git -C "$repo" diff --no-ext-diff --binary -- "${spec[@]}" || true
    git -C "$repo" ls-files -z --others --exclude-standard -- "${spec[@]}" | (cd "$repo" && xargs -0 -r cksum) || true
  } 2>/dev/null | cksum
}

# A leg's tools are not bound by the host's deny rules, so a leg working in REPO could read an
# untracked .env* file (ignored or not) and send its values to the provider. Fails with a
# message unless REPO holds none or MMO_ALLOW_ENV_FILES=1. Ignored directories are not entered.
mmo_guard_env_files() {  # mmo_guard_env_files RUNNER REPO
  local found
  [ "${MMO_ALLOW_ENV_FILES:-0}" != 1 ] || return 0
  found="$( { git -C "$2" ls-files -z --others --exclude-standard
    git -C "$2" ls-files -z --others --ignored --exclude-standard --directory; } \
    | tr '\0' '\n' | grep -E '(^|/)\.env[^/]*$' | paste -sd ' ' -)" || true
  [ -n "$found" ] || return 0
  printf '%s: %s holds untracked env files a leg could send to its provider: %s\n' "$1" "$2" "$found" >&2
  printf '%s: run from a git worktree without them, or set MMO_ALLOW_ENV_FILES=1\n' "$1" >&2
  return 1
}

# Run a provider CLI with a scrubbed environment: a base allowlist, the provider's own
# variables (names, or PREFIX* patterns, before --), and the names listed in MMO_LEG_ENV.
mmo_leg_env() {  # mmo_leg_env [NAME|PREFIX*]... -- COMMAND [ARG]...
  local keep=(PATH HOME USER LOGNAME SHELL LANG LC_ALL TERM TMPDIR
    HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy SSL_CERT_FILE NODE_EXTRA_CA_CERTS)
  local pass=() names=() extra=() name
  while [ "$1" != -- ]; do keep+=("$1"); shift; done
  shift
  read -r -a extra <<< "${MMO_LEG_ENV:-}"
  for name in "${keep[@]}" ${extra[@]+"${extra[@]}"}; do
    case "$name" in
      *'*') mapfile -t -O "${#names[@]}" names < <(compgen -e -- "${name%\*}") ;;
      *) names+=("$name") ;;
    esac
  done
  for name in "${names[@]}"; do
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'mmo: invalid MMO_LEG_ENV name: %s\n' "$name" >&2; return 2; }
    [ -z "${!name+x}" ] || pass+=("$name=${!name}")
  done
  env -i ${pass[@]+"${pass[@]}"} "$@"
}
