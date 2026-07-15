#!/usr/bin/env bash
# codex-run.sh — drive the OpenAI Codex CLI (`codex exec`) as a subagent from
# Claude Code. Encodes the hard-won operational gotchas:
#
#   1. Every Codex subprocess uses
#      `--dangerously-bypass-approvals-and-sandbox`. The development container is
#      the security boundary; review-only behavior is enforced by the prompt.
#   2. Model and reasoning effort are pinned explicitly so unattended calls do
#      not inherit surprising cost or behavior from ~/.codex/config.toml.
#   3. Canonical invocation: codex exec
#      --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -C <dir>.
#   4. Dual timeouts — the inner `timeout` here AND the Claude Code Bash-tool
#      `timeout` parameter must both be generous, or the tool SIGTERMs codex
#      mid-task (exit 143) leaving uncommitted partial edits.
#   5. Output is huge and the final answer is duplicated; capture the clean final
#      message via codex's `-o/--output-last-message`, fall back to tail-parsing.
#
# Usage:
#   codex-run.sh [options] [PROMPT]
#   <build prompt> | codex-run.sh [options]      # prompt on stdin
#
# Options:
#   -C, --dir DIR        Repo/working dir codex runs in (default: $PWD).
#   -m, --model MODEL    Codex model (default: gpt-5.6-sol).
#   -e, --effort LEVEL   Reasoning effort (default: high).
#   -t, --timeout SECS   Inner timeout for the codex run (default: 600).
#   -f, --prompt-file F  Read the prompt from file F instead of argv/stdin.
#   -o, --out FILE       Where to keep the full captured stream (default: temp).
#       --print-cmd      Print the codex command that would run, then exit.
#   -h, --help           Show this help and exit.
#
# Output: the script prints ONLY codex's final answer on stdout, then a short
# footer (exit code + log path) on stderr. On a partial run (exit 143) it prints
# a remediation block instead.
set -euo pipefail

CS_DEFAULT_TIMEOUT="600"
CS_DEFAULT_MODEL="${CODEX_SUBAGENT_MODEL:-gpt-5.6-sol}"
CS_DEFAULT_EFFORT="${CODEX_SUBAGENT_EFFORT:-high}"

cs_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
    "${BASH_SOURCE[0]}"
}

# cs_extract_final_answer — fallback extractor. codex streams reasoning + file
# reads, then a `tokens used: N` marker, then repeats its final answer verbatim.
# Print everything after the LAST line containing "tokens used"; if no marker is
# present, print the whole input unchanged.
cs_extract_final_answer() {
  awk '
    { lines[NR] = $0; total = NR }
    /tokens used/ { last = NR }
    END {
      start = (last > 0) ? last + 1 : 1
      for (i = start; i <= total; i++) print lines[i]
    }
  '
}

# cs_build_cmd — print, one argument per line, the codex command for the given
# dir/model/effort. Kept separate so it is unit-testable and so
# --print-cmd can show exactly what will run. The prompt itself is fed on stdin,
# never as argv, to dodge the MAX_ARG_STRLEN "Argument list too long" trap.
cs_build_cmd() {
  local dir="$1" model="$2" effort="$3"
  printf '%s\n' codex exec --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check -C "$dir"
  printf '%s\n' -m "$model" -c "model_reasoning_effort=\"$effort\""
  printf '%s\n' -
}

cs_main() {
  local dir="$PWD" model="$CS_DEFAULT_MODEL" effort="$CS_DEFAULT_EFFORT"
  local timeout_secs="$CS_DEFAULT_TIMEOUT" prompt_file="" out="" print_cmd=0
  local prompt=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -C|--dir)        dir="$2"; shift 2 ;;
      -m|--model)      model="$2"; shift 2 ;;
      -e|--effort)     effort="$2"; shift 2 ;;
      -t|--timeout)    timeout_secs="$2"; shift 2 ;;
      -f|--prompt-file) prompt_file="$2"; shift 2 ;;
      -o|--out)        out="$2"; shift 2 ;;
      --print-cmd)     print_cmd=1; shift ;;
      -h|--help)       cs_usage; return 0 ;;
      --)              shift; break ;;
      -*)              printf 'codex-run: unknown option: %s\n' "$1" >&2; return 2 ;;
      *)               break ;;
    esac
  done

  if [ "$print_cmd" -eq 1 ]; then
    cs_build_cmd "$dir" "$model" "$effort"
    return 0
  fi

  # Resolve the prompt: explicit file > remaining argv > stdin.
  if [ -n "$prompt_file" ]; then
    [ -r "$prompt_file" ] || { printf 'codex-run: cannot read prompt file: %s\n' "$prompt_file" >&2; return 2; }
    prompt="$(cat "$prompt_file")"
  elif [ $# -gt 0 ]; then
    prompt="$*"
  elif [ ! -t 0 ]; then
    prompt="$(cat)"
  fi

  if [ -z "${prompt//[[:space:]]/}" ]; then
    printf 'codex-run: empty prompt (pass as argument, --prompt-file, or stdin)\n' >&2
    return 2
  fi

  command -v codex >/dev/null 2>&1 || {
    printf 'codex-run: codex CLI not found. Install with: npm install -g @openai/codex\n' >&2
    return 127
  }

  local log final errlog
  log="${out:-$(mktemp -t codex-run-log.XXXXXX)}"
  final="$(mktemp -t codex-run-final.XXXXXX)"
  # errlog is a PERSISTED sibling of the log (not in the trap), so the remedy/footer
  # messages that reference it point at a file that still exists after we return.
  errlog="${log}.stderr"
  # shellcheck disable=SC2064
  trap "rm -f '$final'" RETURN
  : > "$log"
  : > "$errlog"

  # Build argv from cs_build_cmd, then run under a hard timeout. -k 10 sends
  # SIGKILL 10s after SIGTERM if codex ignores the term.
  local -a cmd=()
  while IFS= read -r arg; do cmd+=("$arg"); done < <(cs_build_cmd "$dir" "$model" "$effort")

  # Keep stdout (codex's streamed content — diffs, file dumps, the answer) and
  # stderr (codex's own diagnostics) in separate files for inspection.
  set +e
  printf '%s' "$prompt" | timeout -k 10 "$timeout_secs" \
    "${cmd[@]}" -o "$final" >"$log" 2>"$errlog"
  local rc=$?
  set -e

  # Exit 124 (timeout) / 143 (128+SIGTERM) => the run was killed mid-flight.
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then
    cat >&2 <<EOF
codex-run: TIMEOUT after ${timeout_secs}s (exit $rc). codex was killed mid-task.
  Partial, UNCOMMITTED edits may be in the working tree. To recover:
    git -C "$dir" status            # see what changed
    git -C "$dir" checkout -- .     # discard tracked-file edits
    # remove any newly-created files codex left behind, then retry with:
    #   a larger --timeout AND a larger Claude Code Bash-tool timeout.
  Full log: $log (stderr: $errlog)
EOF
    return "$rc"
  fi

  # Prefer codex's clean final message; fall back to tail-parsing the stream.
  if [ -s "$final" ]; then
    cat "$final"
  else
    cs_extract_final_answer < "$log"
  fi

  # stdout is in $log, stderr in $errlog — both persist for inspection.
  printf 'codex-run: exit %d, model=%s, effort=%s, full log: %s (stderr: %s)\n' \
    "$rc" "$model" "$effort" "$log" "$errlog" >&2
  return "$rc"
}

# Run main only when executed directly, so tests can source and unit-test the
# cs_* helpers without triggering a codex run.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cs_main "$@"
fi
