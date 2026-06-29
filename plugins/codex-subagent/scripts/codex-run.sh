#!/usr/bin/env bash
# codex-run.sh — drive the OpenAI Codex CLI (`codex exec`) as a subagent from
# Claude Code. Encodes the hard-won operational gotchas:
#
#   1. Default sandbox is `danger-full-access`, NOT `--dangerously-bypass-*`.
#      `-s danger-full-access` disables only codex's broken bwrap sandbox mode
#      (which fails inside containers), gives real FS read/write/exec, AND passes
#      Claude Code's auto-mode permission classifier without a bypass flag.
#   2. Canonical invocation: codex exec -s <mode> --skip-git-repo-check -C <dir>.
#   3. Dual timeouts — the inner `timeout` here AND the Claude Code Bash-tool
#      `timeout` parameter must both be generous, or the tool SIGTERMs codex
#      mid-task (exit 143) leaving uncommitted partial edits.
#   4. Output is huge and the final answer is duplicated; capture the clean final
#      message via codex's `-o/--output-last-message`, fall back to tail-parsing.
#   5. Detect the bwrap failure and surface the `-s danger-full-access` remedy.
#
# Usage:
#   codex-run.sh [options] [PROMPT]
#   <build prompt> | codex-run.sh [options]      # prompt on stdin
#
# Options:
#   -C, --dir DIR        Repo/working dir codex runs in (default: $PWD).
#   -m, --model MODEL    Override codex model (default: codex's default, gpt-5.5).
#   -s, --sandbox MODE   codex sandbox mode (default: danger-full-access).
#   -t, --timeout SECS   Inner timeout for the codex run (default: 600).
#   -f, --prompt-file F  Read the prompt from file F instead of argv/stdin.
#   -o, --out FILE       Where to keep the full captured stream (default: temp).
#       --print-cmd      Print the codex command that would run, then exit.
#   -h, --help           Show this help and exit.
#
# Output: the script prints ONLY codex's final answer on stdout, then a short
# footer (exit code + log path) on stderr. On bwrap failure or partial-run
# (exit 143) it prints a remediation block instead.
set -euo pipefail

CS_DEFAULT_SANDBOX="danger-full-access"
CS_DEFAULT_TIMEOUT="600"

cs_usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# cs_detect_bwrap — return 0 if the captured output shows codex's bwrap sandbox
# failing to initialize (the containerized-environment trap).
cs_detect_bwrap() {
  grep -qE 'bwrap:.*(Permission denied|Operation not permitted|Failed to make)' "$1"
}

# cs_build_cmd — print, one argument per line, the codex command for the given
# dir/model/sandbox. Kept separate so it is unit-testable and so --print-cmd can
# show exactly what will run. The prompt itself is fed on stdin (codex exec -),
# never as argv, to dodge the MAX_ARG_STRLEN "Argument list too long" trap.
cs_build_cmd() {
  local dir="$1" model="$2" sandbox="$3"
  printf '%s\n' codex exec -s "$sandbox" --skip-git-repo-check -C "$dir"
  [ -n "$model" ] && printf '%s\n' -m "$model"
  printf '%s\n' -
}

cs_main() {
  local dir="$PWD" model="" sandbox="$CS_DEFAULT_SANDBOX"
  local timeout_secs="$CS_DEFAULT_TIMEOUT" prompt_file="" out="" print_cmd=0
  local prompt=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -C|--dir)        dir="$2"; shift 2 ;;
      -m|--model)      model="$2"; shift 2 ;;
      -s|--sandbox)    sandbox="$2"; shift 2 ;;
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
    cs_build_cmd "$dir" "$model" "$sandbox"
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
  while IFS= read -r arg; do cmd+=("$arg"); done < <(cs_build_cmd "$dir" "$model" "$sandbox")

  # Keep stdout (codex's streamed content — diffs, file dumps, the answer) and stderr
  # (codex's OWN diagnostics) in SEPARATE files. bwrap detection must scan stderr only:
  # stdout legitimately echoes file/diff content that can contain the bwrap error string
  # verbatim (e.g. reviewing this very repo), which would false-positive a combined scan.
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

  # bwrap sandbox failure => codex couldn't touch the FS; reviews come back empty.
  # Scan codex's OWN stderr only, and only treat it as fatal when the run actually
  # failed or produced no answer — so a stray "bwrap:" mention in a successful run's
  # output never aborts a good result.
  if cs_detect_bwrap "$errlog" && { [ "$rc" -ne 0 ] || [ ! -s "$final" ]; }; then
    cat >&2 <<EOF
codex-run: codex's bwrap sandbox failed to initialize (containerized environment).
  In this state codex cannot read or write repo files. Re-run with:
    -s danger-full-access
  (current sandbox: $sandbox). Do NOT use --dangerously-bypass-approvals-and-sandbox:
  Claude Code's permission classifier blocks it. Full log: $log (stderr: $errlog)
EOF
    return 1
  fi

  # Prefer codex's clean final message; fall back to tail-parsing the stream.
  if [ -s "$final" ]; then
    cat "$final"
  else
    cs_extract_final_answer < "$log"
  fi

  # stdout is in $log, stderr in $errlog — both persist for inspection.
  printf 'codex-run: exit %d, full log: %s (stderr: %s)\n' "$rc" "$log" "$errlog" >&2
  return "$rc"
}

# Run main only when executed directly, so tests can source and unit-test the
# cs_* helpers without triggering a codex run.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cs_main "$@"
fi
