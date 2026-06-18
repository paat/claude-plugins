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

# Analyse the command. Sets: IS_COMMIT (0/1), HAS_ACK (0/1), WORKDIR.
# A segment is "<env-assignments> <wrappers> git <global-opts> <subcommand> …".
# We honor the ACK only as a leading, non-empty SILENT_FAILURE_ACK= on the commit
# segment, and require `commit` to be the git SUBCOMMAND (not any later word), so
# `git help commit` / `git branch commit` / `git log --grep commit` are not gated.
analyze_command() {
  local cmd="$1" cwd="$2" seg pending_cd=""
  IS_COMMIT=0; HAS_ACK=0; WORKDIR="$cwd"
  # normalise separators (; && || | &) to newlines, then walk each segment in order
  while IFS= read -r seg; do
    [[ -z "${seg//[[:space:]]/}" ]] && continue
    seg="${seg#"${seg%%[![:space:]]*}"}"   # ltrim
    seg="${seg#\(}"                          # strip a leading subshell/group paren
    local -a toks=(); read -ra toks <<<"$seg"
    local n=${#toks[@]} i=0 seg_ack=0 t
    # leading env-assignments + simple wrappers / shell keywords (interleaved)
    while (( i < n )); do
      t="${toks[i]}"
      if [[ "$t" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        [[ "$t" =~ ^SILENT_FAILURE_ACK=.+ ]] && seg_ack=1
        ((i++)); continue
      fi
      case "$t" in
        env|command|time|nice|nohup|builtin|exec|sudo|if|then|elif|else|while|until|do|"!") ((i++)); continue ;;
      esac
      break
    done
    (( i >= n )) && continue
    t="${toks[i]}"
    # `cd <dir>` sets the directory for a later `git commit` in a following segment
    if [[ "$t" == "cd" && $((i+1)) -lt n ]]; then pending_cd="${toks[i+1]}"; continue; fi
    # the executable must be git (bare or a path ending in /git)
    [[ "$t" == "git" || "$t" == */git ]] || continue
    ((i++))
    local git_C=""
    while (( i < n )); do
      t="${toks[i]}"
      case "$t" in
        -C)                         git_C="${toks[i+1]:-}"; ((i+=2)) ;;
        -c|--git-dir|--work-tree|--namespace|--super-prefix) ((i+=2)) ;;
        --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|-C=*) ((i++)) ;;
        -*)                         ((i++)) ;;
        *)                          break ;;
      esac
    done
    [[ "${toks[i]:-}" == "commit" ]] || continue
    IS_COMMIT=1; HAS_ACK=$seg_ack
    local base="$cwd"
    if [[ -n "$pending_cd" ]]; then [[ "$pending_cd" == /* ]] && base="$pending_cd" || base="$cwd/$pending_cd"; fi
    if [[ -n "$git_C" ]]; then [[ "$git_C" == /* ]] && WORKDIR="$git_C" || WORKDIR="$base/$git_C"
    else WORKDIR="$base"; fi
    return
  done < <(printf '%s\n' "$cmd" | tr ';&|' '\n')
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
