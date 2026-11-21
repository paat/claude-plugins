#!/usr/bin/env bash
# Shared helpers for the runners and pool.sh:
# - review terminal-verdict check
# - provider failure classification (plan limit or transient → 75, auth → 77)
# - repository write detection and the review diff
# - leg secret isolation (untracked .env* refusal, scrubbed environment)
# - shared prompts and harness-adjustments.tsv lines
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

# Prompt of a --mode probe leg: a reviewer that verifies by execution. It keeps its shell,
# so the runner checks the verdict line and that the repository is unchanged afterwards.
mmo_probe_prompt() {  # mmo_probe_prompt REQUEST_FILE [EXTRA_LINE]
  printf '%s\n' 'You are an independent reviewer who verifies by execution: run the probes and suites the task names.'
  printf '%s\n' 'Leave the repository as you found it: no edits or new files in it, no commit, branch, index or stash change. Write scratch files outside it.'
  [ -z "${2:-}" ] || printf '%s\n' "$2"
  printf '%s\n' 'Report observed against expected for each probe. End with one terminal line: APPROVE or NEEDS_WORK.'
  printf '\n## Review task\n'
  cat "$1"
}

# Print why one harness-adjustments row is malformed, or nothing.
mmo_adjustment_row_error() {  # mmo_adjustment_row_error ROW
  local rest="$1" f=() i names=(provider model_glob mode line evidence as_of)
  while [[ "$rest" == *$'\t'* ]]; do f+=("${rest%%$'\t'*}"); rest="${rest#*$'\t'}"; done
  f+=("$rest")
  [ "${#f[@]}" -eq 6 ] || { printf 'want 6 tab-separated columns, got %s\n' "${#f[@]}"; return 0; }
  for i in 0 1 2 3 4 5; do
    [[ "${f[$i]}" =~ [^[:space:]] ]] || { printf 'missing %s\n' "${names[$i]}"; return 0; }
  done
  case "${f[2]}" in implement|review|research|advise|'*') ;; *) printf 'bad mode %s\n' "${f[2]}"; return 0 ;; esac
  # The runners and the modes they accept; a row outside them could never apply.
  case "${f[0]}:${f[2]}" in
    claude:*|grok:*|muse:*|codex:implement|codex:review|codex:research|codex:'*') ;;
    vibe:implement|vibe:review|vibe:advise|vibe:'*') ;;
    agy:implement|agy:review|agy:'*'|opencode:implement|opencode:review|opencode:'*'|qwen:implement|qwen:review|qwen:'*') ;;
    *) printf 'no runner %s takes mode %s\n' "${f[0]}" "${f[2]}"; return 0 ;;
  esac
  # Only Grok, Muse and Vibe always have a turn or step budget (Claude with --max-turns).
  if [[ "${f[3]}" == *'{budget}'* ]]; then
    case "${f[0]}" in claude|grok|muse|vibe) ;; *) printf '%s has no turn or step budget for {budget}\n' "${f[0]}"; return 0 ;; esac
  fi
  # Only a Grok review leg passes a short wall-clock timeout for {timeout}.
  if [[ "${f[3]}" == *'{timeout}'* ]]; then
    case "${f[0]}:${f[2]}" in grok:review|grok:'*') ;; *) printf '%s %s passes no short timeout for {timeout}\n' "${f[0]}" "${f[2]}"; return 0 ;; esac
  fi
  [[ "${f[5]}" =~ ^([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]] || { printf 'as_of %s is not an ISO date\n' "${f[5]}"; return 0; }
  local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]})) last=31
  case "$m" in 4|6|9|11) last=30 ;; 2) last=$(( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28 )) ;; esac
  [ "$d" -le "$last" ] || printf 'as_of %s is not a calendar date\n' "${f[5]}"
}

# Rows of the harness-adjustments table (MMO_HARNESS_ADJUSTMENTS replaces the shipped file), skipping
# comments and blank lines. With CHECK, print each malformed row and return 1 if there was one.
mmo_adjustment_rows() {  # mmo_adjustment_rows [check]
  local file="${MMO_HARNESS_ADJUSTMENTS:-$(dirname -- "${BASH_SOURCE[0]}")/harness-adjustments.tsv}" row err n=0 bad=0
  if [ ! -r "$file" ]; then
    printf 'harness-adjustments: cannot read %s\n' "$file" >&2
    [ -z "${1:-}" ]; return
  fi
  while IFS= read -r row || [ -n "$row" ]; do
    n=$((n + 1))
    [[ "$row" =~ ^[[:space:]]*(#|$) ]] && continue
    err="$(mmo_adjustment_row_error "$row")"
    if [ -n "$err" ]; then
      printf 'harness-adjustments: %s:%s: %s\n' "$file" "$n" "$err" >&2
      bad=1
    elif [ -z "${1:-}" ]; then
      printf '%s\n' "$row"
    fi
  done < "$file"
  [ -z "${1:-}" ] || return "$bad"
}

# Prompt lines for PROVIDER, exact MODEL id and MODE, from the matching table rows in order.
# A malformed row is reported on stderr and skipped. {budget} becomes BUDGET, the leg's turn or step
# cap; a {budget} row is skipped with a warning when the leg has none (Claude without --max-turns).
# {timeout} becomes SHORT_TIMEOUT, a wall-clock limit below the runner default; a {timeout} row is
# skipped silently without one, so it only reaches short-timeout legs.
mmo_adjustment_lines() {  # mmo_adjustment_lines PROVIDER MODEL MODE [BUDGET] [SHORT_TIMEOUT]
  local row f
  while IFS= read -r row; do
    IFS=$'\t' read -r -a f <<< "$row"
    [ "${f[0]}" = "$1" ] && [[ "$2" == ${f[1]} ]] || continue
    [ "${f[2]}" = '*' ] || [ "${f[2]}" = "$3" ] || continue
    if [[ "${f[3]}" == *'{budget}'* ]] && [ -z "${4:-}" ]; then
      printf 'harness-adjustments: skipped a {budget} line: this %s %s leg has no turn or step budget\n' "$1" "$3" >&2
      continue
    fi
    [[ "${f[3]}" != *'{timeout}'* ]] || [ -n "${5:-}" ] || continue
    f[3]="${f[3]//\{budget\}/${4:-}}"
    printf '%s\n' "${f[3]//\{timeout\}/${5:-}}"
  done < <(mmo_adjustment_rows)
}

# Prompt of an implement leg, shared by every runner; adds the provider's harness adjustments.
mmo_implement_prompt() {  # mmo_implement_prompt REQUEST_FILE [BUDGET]
  printf '%s\n' 'You are one fresh, bounded implementation worker.'
  printf '%s\n' 'Obey the task acceptance, allowed files, and test exactly. Do not broaden scope or commit.'
  mmo_adjustment_lines "${mmo_outcome_provider:-}" "${model:-}" implement "${2:-}"
  printf '%s\n' 'Inspect your diff, run the named test, and stop when acceptance passes.'
  printf '%s\n' 'Make reasonable assumptions, state them in your final message, and finish the task; do not stop to ask questions or propose next steps.'
  printf '%s\n' 'Never weaken, skip or special-case a test to make it pass; if a requirement cannot be met, say so in your final message.'
  printf '\n## Task packet\n'
  cat "$1"
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
# (Codex last ERROR: line, Claude failed result / terminal error line, Grok stderr,
# Muse failed-run reason and stderr).
# Prints "limit" (plan window or balance used up), "transient", "auth", or nothing.
# Callers must not pass model stdout bodies.
mmo_classify_provider_failure() {
  local f="${1:-}" text
  [ -n "$f" ] && [ -s "$f" ] || return 0
  # Some runners pass a whole stderr: a stack-frame position (file.js:503:12) is not a status.
  text="$(sed -E 's/:[0-9]+:[0-9]+//g' "$f")"
  if grep -Eiq '\b402\b|usage[[:space:]_-]?limit|hit your .*limit\b|quota|(resource|balance|credits?)[[:space:]_-]?exhausted|credit balance (is )?too low|billing_error' <<< "$text"; then
    printf 'limit\n'
    return 0
  fi
  if grep -Eiq '\b(429|529|503)\b|overloaded|rate[[:space:]_-]?limit|temporarily[[:space:]]+unavailable' <<< "$text"; then
    printf 'transient\n'
    return 0
  fi
  if grep -Eiq '\b401\b|unauthorized|not[[:space:]]+signed[[:space:]]+in|not[[:space:]]+logged[[:space:]]+in|login[[:space:]]+required|missing[[:space:]]+([[:alnum:]_-]+[[:space:]]+)?credentials|(expired|invalid)[[:space:]]+(api[[:space:]]*key|token)|(api[[:space:]]*key|token).*(expired|invalid)' <<< "$text"; then
    printf 'auth\n'
    return 0
  fi
}

# Provider exits must not impersonate runner validation codes; KILL/TERM mean timeout.
mmo_provider_rc() { case "$1" in 0|124) echo "$1" ;; 137|143) echo 124 ;; *) echo 1 ;; esac; }

# Reclassify a provider failure exit and print the runner exit line, then exit.
# Usage: mmo_finish <runner-name> <rc> <failure-text-file> [key=value ...]
mmo_finish() {
  local name="$1" rc="$2" errf="$3"
  shift 3
  local failure_kind=""
  case "$rc" in
    0|2|3|4|5|6|7|55|76|78|124) ;;
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

# Pathspec for REPO without each leg output path under it and the runner files written
# beside it (.stream, .stderr, .stream.stderr, .exit). Sets the array mmo_spec.
mmo_out_spec() {  # mmo_out_spec REPO [OUT]...
  local repo="$1" out form suffix
  shift
  mmo_spec=(.)
  for out in "$@"; do
    [ -n "$out" ] || continue
    # As given and resolved: --out may be a symlink inside REPO, or reached through one.
    for form in "$(realpath -ms -- "$out" 2>/dev/null || true)" "$(realpath -m -- "$out" 2>/dev/null || true)"; do
      case "$form" in
        "$repo"/*)
          for suffix in '' .stream .stderr .stream.stderr .exit; do
            mmo_spec+=(":(exclude,literal)${form#"$repo"/}$suffix")
          done
          ;;
      esac
    done
  done
}

# A leg that fails must not leave an earlier run's report (a verdict) at its --out.
# A symlink is emptied in place so it keeps pointing at its target.
mmo_clear_out() {  # mmo_clear_out PATH
  case "$1" in ''|/dev/*) return 0 ;; esac
  if [ -L "$1" ]; then : > "$1"; else rm -f -- "$1"; fi 2>/dev/null || true
}

# Fingerprint HEAD (commit and checked-out branch), index, working tree, and untracked file
# contents, so a caller can tell whether a leg wrote to the repository. Other branches and the
# stash are left out: worktrees share them, so another session would trip the check. The absolute OUT paths (a leg's --out and
# --stream-log) do not count, as in mmo_out_spec. Prints one cksum line; never fails.
mmo_tree_state() {  # mmo_tree_state REPO [OUT]...
  local repo="$1"
  local -a mmo_spec
  mmo_out_spec "$@"
  {
    git -C "$repo" rev-parse --verify -q HEAD || true
    git -C "$repo" symbolic-ref -q HEAD || true
    git -C "$repo" status --porcelain=v1 --untracked-files=all -- "${mmo_spec[@]}" || true
    git -C "$repo" diff --no-ext-diff --binary --cached -- "${mmo_spec[@]}" || true
    git -C "$repo" diff --no-ext-diff --binary -- "${mmo_spec[@]}" || true
    git -C "$repo" ls-files -z --others --exclude-standard -- "${mmo_spec[@]}" | (cd "$repo" && xargs -0 -r cksum) || true
  } 2>/dev/null | cksum
}

# Write the review diff of REPO against BASE to DIFF, without the leg outputs, then close it (below).
# Exits 2 on an invalid ref.
mmo_review_diff() {  # mmo_review_diff RUNNER REPO BASE DIFF [OUT]...
  git -C "$2" rev-parse --verify "$3^{commit}" >/dev/null || {
    printf '%s: invalid base ref: %s\n' "$1" "$3" >&2
    exit 2
  }
  local -a mmo_spec
  mmo_out_spec "$2" "${@:5}"
  git -C "$2" diff --no-ext-diff --binary "$3" -- "${mmo_spec[@]}" > "$4"
  mmo_review_diff_close "$1" "$2" "$4" "${@:5}"
}

# Append untracked files to DIFF (a new file is part of the change), without the leg
# outputs mmo_out_spec leaves out: an earlier attempt's report is not under review.
# Exits 3 with nothing to review and 4 over MMO_REVIEW_DIFF_MAX_BYTES.
mmo_review_diff_close() {  # mmo_review_diff_close RUNNER REPO DIFF [OUT]...
  local name="$1" repo="$2" diff="$3" untracked rc max_bytes diff_bytes
  local -a mmo_spec
  mmo_out_spec "$repo" "${@:4}"
  while IFS= read -r -d '' untracked; do
    # --no-index exits 1 when files differ (expected); 2+ is a real failure.
    rc=0
    git -C "$repo" diff --no-ext-diff --no-index --binary -- /dev/null "$untracked" >> "$diff" 2>/dev/null || rc=$?
    if [ "$rc" -gt 1 ]; then
      printf '%s: failed to include untracked file in review diff: %s\n' "$name" "$untracked" >&2
      exit "$rc"
    fi
  done < <(git -C "$repo" ls-files -z --others --exclude-standard -- "${mmo_spec[@]}")
  [ -s "$diff" ] || { printf '%s: no diff to review\n' "$name" >&2; exit 3; }
  max_bytes="${MMO_REVIEW_DIFF_MAX_BYTES:-1048576}"
  [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || { printf '%s: MMO_REVIEW_DIFF_MAX_BYTES must be positive\n' "$name" >&2; exit 2; }
  diff_bytes="$(wc -c < "$diff" | tr -d ' ')"
  [ "$diff_bytes" -le "$max_bytes" ] || {
    printf '%s: diff is %s bytes; split or raise MMO_REVIEW_DIFF_MAX_BYTES=%s explicitly\n' "$name" "$diff_bytes" "$max_bytes" >&2
    exit 4
  }
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

# Exec a provider CLI inside mmo_run so its published PID remains the watchdog PID.
# Use a scrubbed environment: a base allowlist, the provider's own
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
  exec env -i ${pass[@]+"${pass[@]}"} "$@"
}
