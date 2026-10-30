#!/usr/bin/env bash
# Shared EXIT hook; runners retain their own cleanup after mmo_outcome_exit.
mmo_outcome_init() {
  mmo_outcome_provider="$1"
  mmo_outcome_started=$SECONDS
  mmo_outcome_served_model=""
  mmo_outcome_tokens=""
  mmo_outcome_head_sha=""
  mmo_outcome_verdict=""
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'mmo_outcome_exit "$?"' EXIT
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
