#!/usr/bin/env bash
# Shared EXIT hook; runners retain their own cleanup after mmo_outcome_exit.
mmo_outcome_init() {
  mmo_outcome_provider="$1"
  mmo_outcome_started=$SECONDS
  mmo_outcome_served_model=""
  mmo_outcome_tokens=""
  mmo_outcome_head_sha=""
  mmo_outcome_verdict=""
  mmo_signal_init
  trap 'mmo_outcome_exit "$?"' EXIT
}

# During a supervised call, wait may return before the child has stopped. Record
# the requested exit, forward to timeout, then let mmo_run reap the whole pipeline.
mmo_signal_init() {
  trap 'mmo_stop TERM 143' TERM
  trap 'mmo_stop HUP 129' HUP
  trap 'mmo_stop INT 130' INT
}

mmo_stop() {
  if [ "${mmo_running:-0}" = 1 ]; then
    mmo_stop_signal="$1"
    mmo_stop_code="$2"
    [ -z "${mmo_timeout_pid:-}" ] || mmo_forward_stop "$1" "$mmo_timeout_pid"
  else
    exit "$2"
  fi
}

# External wrappers (Claude API and Qwen) start timeout in another process group.
# Forward to those watchdogs first so each retains its existing kill-after grace.
mmo_forward_stop() {
  local sig="$1" pid="$2" nested
  nested="$(ps -eo pid=,ppid=,comm= | awk -v root="$pid" '
    { parent[$1]=$2; command[$1]=$3 }
    END {
      seen[root]=1
      do {
        changed=0
        for (p in parent) if (!(p in seen) && parent[p] in seen) {
          seen[p]=1; changed=1
        }
      } while (changed)
      for (p in seen) if (p != root && command[p] == "timeout") print p
    }')"
  if [ -n "$nested" ]; then
    # ps supplies only numeric PIDs.
    kill -s "$sig" $nested 2>/dev/null || :
  fi
  kill -s "$sig" "$pid" 2>/dev/null || :
}

# Run a command (whose function entrypoint must exec its CLI) with optional tee.
# A control pipe publishes the timeout/wrapper PID even in a pipeline's first
# stage. Statuses cross the background-shell boundary without losing PIPESTATUS.
# Usage: mmo_run direct|tee|append STREAM STDERR COMMAND [ARG...]
mmo_run() {
  local kind="$1" stream="$2" err="$3"
  shift 3
  local state control output_fd job rc=0 read_rc
  local mmo_running=0 mmo_timeout_pid="" mmo_stop_signal="" mmo_stop_code=0
  state="$(mktemp -d)" || return
  exec {output_fd}>&1
  mmo_running=1
  exec {control}< <(
    trap - EXIT TERM HUP INT
    exec {publish}>&1
    launch() {
      printf '%s\n' "$BASHPID" >&"$publish"
      exec {publish}>&- {output_fd}>&-
      if declare -F "$1" >/dev/null; then "$@"; else exec "$@"; fi
    }
    if [ "$kind" = direct ]; then
      (launch "$@") >&"$output_fd"
      printf '%s\n' "$?" > "$state/status"
    else
      tee_args=()
      [ "$kind" != append ] || tee_args=(-a)
      launch "$@" 2> "$err" | (
        exec {publish}>&-
        exec 1>&"$output_fd" {output_fd}>&-
        exec tee "${tee_args[@]}" "$stream"
      )
      printf '%s\n' "${PIPESTATUS[@]}" > "$state/status"
    fi
  )
  job=$!
  exec {output_fd}>&-
  # Signals interrupt read/wait. EOF also handles a group stop before the child
  # publishes its PID; the parent must never hold its own pipe's writer open.
  while [ -z "$mmo_timeout_pid" ]; do
    read_rc=0
    read -r -u "$control" mmo_timeout_pid || read_rc=$?
    [ "$read_rc" -gt 128 ] || break
  done
  exec {control}>&-
  if [ -n "$mmo_stop_signal" ] && [ -n "$mmo_timeout_pid" ]; then
    mmo_forward_stop "$mmo_stop_signal" "$mmo_timeout_pid"
  fi
  while :; do
    wait "$job" && rc=0 || rc=$?
    # An interrupted wait leaves the job alive; a second wait must reap it.
    kill -0 "$job" 2>/dev/null || break
  done
  mmo_pipe_status=()
  [ ! -f "$state/status" ] || mapfile -t mmo_pipe_status < "$state/status"
  rm -rf "$state"
  [ "$mmo_stop_code" -eq 0 ] || exit "$mmo_stop_code"
  [ "${#mmo_pipe_status[@]}" -eq 0 ] || rc="${mmo_pipe_status[0]}"
  return "$rc"
}

mmo_outcome_exit() {
  local exit_code="$1"
  # Isolate append failures (including redirection errors) from status and output.
  (
    trap - EXIT
    outcomes_file="${MMO_OUTCOMES_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator/outcomes.tsv}"
    directory="${repo_dir:-$PWD}"
    directory="$(cd -- "$directory" && pwd)" || directory="${repo_dir:-$PWD}"
    repo="$(git -C "$directory" remote get-url origin 2>/dev/null)" || repo=""
    case "$repo" in
      *://*) repo="${repo#*://}"; repo="${repo#*/}" ;;
      *:*) repo="${repo#*:}" ;;
      *) repo="" ;;
    esac
    repo="${repo%/}"
    repo="${repo%.git}"
    if [[ "$repo" == */* ]]; then
      name="${repo##*/}"
      owner="${repo%/*}"
      repo="${owner##*/}/$name"
    else
      repo="${directory%/}"
      repo="${repo##*/}"
    fi
    fields=("$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$repo" "${MMO_OUTCOME_TIER:-}"
      "${mode:-}" "$mmo_outcome_provider" "${model:-}" "$mmo_outcome_served_model"
      "${effective_effort:-${effort:-}}" "$exit_code" "$((SECONDS - mmo_outcome_started))"
      "$mmo_outcome_tokens" "$mmo_outcome_head_sha" "$mmo_outcome_verdict")
    for i in "${!fields[@]}"; do
      fields[$i]="${fields[$i]//$'\t'/ }"
      fields[$i]="${fields[$i]//$'\n'/ }"
      fields[$i]="${fields[$i]//$'\r'/ }"
    done
    mkdir -p -- "$(dirname -- "$outcomes_file")" || exit 0
    if [ ! -e "$outcomes_file" ]; then
      # Publish a complete header before any writer can append.
      header_file="$(mktemp "${outcomes_file}.XXXXXX")" || exit 0
      trap 'rm -f -- "$header_file"' EXIT
      printf 'utc_time\trepo\ttier\trole\tprovider\trequested_model\tserved_model\teffort\texit_code\tduration_seconds\ttokens\thead_sha\tverdict\n' > "$header_file" || exit 0
      ln -- "$header_file" "$outcomes_file" || [ -f "$outcomes_file" ] || exit 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${fields[@]}" >> "$outcomes_file"
  ) >/dev/null 2>&1 || :
  return 0
}
