#!/usr/bin/env bash
# silent-failure-scanner PreToolUse commit gate.
#
# Fires before a Bash tool call. When the command is a `git commit`, it scans the
# STAGED diff of the repo being committed for silent-failure signatures and, if any
# are found, DENIES the commit and hands the findings back to Claude to arbitrate.
# Claude must then fix the real swallowed errors, or re-run the SAME commit prefixed
# with SILENT_FAILURE_ACK="reason" to record a justification and proceed. Everything
# else is allowed silently.
#
# Scope: this gates commands Claude constructs in-session (a cooperative caller), not a
# hostile committer — intentional bypass already has documented routes (terminal commit,
# vendored hook with --no-verify). So command parsing is a focused tokenizer for the
# realistic shapes, and it FAILS OPEN on anything ambiguous: it only ever gates a command
# it can confidently identify as a `git commit`. It never wrongly blocks.
#
# Deterministic finder (scan.sh) + in-session LLM arbiter (Claude). No network, no cost.
# Dependencies: bash 4+, awk, git, jq.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$HOOK_DIR/../scripts/scan.sh"

allow() { exit 0; }   # no output ⇒ default-allow

# jq is a runtime dependency: without it the gate cannot parse tool input or emit a
# deny, so it fails open. Warn once (per TMPDIR) so the silent no-op is at least loud —
# this hook fires on every Bash call, so a per-invocation warning would spam.
if ! command -v jq >/dev/null 2>&1; then
  warn_marker="${TMPDIR:-/tmp}/.silent-failure-scanner-jq-missing"
  [[ -e "$warn_marker" ]] || {
    echo "[silent-failure-scanner] jq not found — commit gate disabled (fail-open). Install jq to re-enable silent-failure blocking on commits." >&2
    : > "$warn_marker" 2>/dev/null || true
  }
  allow
fi

# Quote-aware lexer: split a command into whitespace-separated words per segment,
# where segments are delimited by UNQUOTED ; & | or newline. Quotes are stripped and
# backslash escapes honored, so separators or the ACK token inside a quoted string
# (e.g. echo "x && git commit") are NOT treated as shell structure → no false deny.
# Each finished segment is handed to process_segment via the _WORDS global array.
# Globals set across the analysis: IS_COMMIT, HAS_ACK, WORKDIR, plus _CWD/_PENDING_CD.
analyze_command() {
  local cmd="$1" c nextc q="" buf="" in_word=0 k len
  IS_COMMIT=0; HAS_ACK=0; WORKDIR="$2"; _CWD="$2"; _PENDING_CD=""; _WORDS=()
  len=${#cmd}
  for (( k = 0; k < len; k++ )); do
    c="${cmd:k:1}"
    if [[ -n "$q" ]]; then
      if [[ "$c" == "$q" ]]; then q=""; else buf+="$c"; in_word=1; fi
      continue
    fi
    case "$c" in
      '"'|"'") q="$c"; in_word=1 ;;
      '\') (( k++ )); buf+="${cmd:k:1}"; in_word=1 ;;
      ' '|$'\t') (( in_word )) && { _WORDS+=("$buf"); buf=""; in_word=0; } ;;
      ';'|'&'|'|'|$'\n')
        (( in_word )) && { _WORDS+=("$buf"); buf=""; in_word=0; }
        process_segment; (( IS_COMMIT )) && return ;;
      *) buf+="$c"; in_word=1 ;;
    esac
  done
  (( in_word )) && _WORDS+=("$buf")
  process_segment
}

# Inspect _WORDS as "<env-assignments> <wrappers> git <global-opts> <subcommand> …".
# ACK is honored only as a leading, non-empty SILENT_FAILURE_ACK= assignment; `commit`
# must be the git SUBCOMMAND (so `git help commit` etc. are not gated); the work dir is
# resolved from a preceding `cd` and chained `git -C` (each relative -C after the prior).
process_segment() {
  local n=${#_WORDS[@]} i=0 seg_ack=0 t v
  (( n == 0 )) && return
  while (( i < n )); do
    t="${_WORDS[i]}"
    if [[ "$t" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      [[ "$t" == SILENT_FAILURE_ACK=?* ]] && seg_ack=1
      (( i++ )); continue
    fi
    case "$t" in
      env|command|time|nice|nohup|builtin|exec|sudo|if|then|elif|else|while|until|do|"!") (( i++ )); continue ;;
    esac
    break
  done
  (( i >= n )) && { _WORDS=(); return; }
  t="${_WORDS[i]}"
  if [[ "$t" == "cd" && $((i+1)) -lt n ]]; then _PENDING_CD="${_WORDS[i+1]}"; _WORDS=(); return; fi
  if [[ "$t" != "git" && "$t" != */git ]]; then _WORDS=(); return; fi
  (( i++ ))
  # base directory for relative -C resolution
  local gitloc="$_CWD"
  if [[ -n "$_PENDING_CD" ]]; then [[ "$_PENDING_CD" == /* ]] && gitloc="$_PENDING_CD" || gitloc="$_CWD/$_PENDING_CD"; fi
  while (( i < n )); do
    t="${_WORDS[i]}"
    case "$t" in
      -C)  v="${_WORDS[i+1]:-}"; (( i += 2 )); [[ "$v" == /* ]] && gitloc="$v" || gitloc="$gitloc/$v" ;;
      -C?*) v="${t#-C}";          (( i++ ));    [[ "$v" == /* ]] && gitloc="$v" || gitloc="$gitloc/$v" ;;
      -c|--git-dir|--work-tree|--namespace|--super-prefix) (( i += 2 )) ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*) (( i++ )) ;;
      -*)  (( i++ )) ;;
      *)   break ;;
    esac
  done
  if [[ "${_WORDS[i]:-}" == "commit" ]]; then
    IS_COMMIT=1; HAS_ACK=$seg_ack; WORKDIR="$gitloc"
  fi
  _WORDS=()
}

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -z "$command" ]] && allow

analyze_command "$command" "$cwd"
[[ "$IS_COMMIT" -eq 1 ]] || allow          # not a confidently-identified git commit
[[ "$HAS_ACK" -eq 1 ]] && allow            # explicit, reasoned acknowledgement

# Scan the staged diff of the target repo. On any trouble, fail open (allow).
# scan.sh exits 0 = clean, 1 = findings, >1 = usage/internal error → only >1 fails open.
[[ -n "$WORKDIR" ]] && { cd "$WORKDIR" 2>/dev/null || allow; }
report="$(bash "$SCAN" --staged --format json 2>/dev/null)"; rc=$?
[[ "$rc" -gt 1 ]] && allow
total="$(printf '%s' "$report" | jq -r '.summary.total // 0' 2>/dev/null)"
[[ "${total:-0}" =~ ^[0-9]+$ ]] || allow
[[ "$total" -eq 0 ]] && allow

# Findings → list them and DENY with arbitration instructions.
findings="$(printf '%s' "$report" | jq -r '(.findings // [])[] | "  - \(.file):\(.line) [\(.severity)] \(.code): \(.snippet)"' 2>/dev/null)"
[[ -z "$findings" ]] && findings="  - (see scan.sh --staged for details)"
reason="silent-failure-scanner blocked this commit — ${total} finding(s) in the staged diff:
${findings}

Arbitrate each finding before committing:
  • Real swallowed error / ghost transaction → FIX it (rethrow or handle the error,
    restore the removed await, surface the dropped response), then commit again.
  • Genuinely benign → re-run the SAME commit prefixed with
    SILENT_FAILURE_ACK=\"<one-line reason>\" to record the justification and proceed.
Do not bypass with --no-verify."

jq -nc --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  },
  systemMessage: $r
}'
exit 0
