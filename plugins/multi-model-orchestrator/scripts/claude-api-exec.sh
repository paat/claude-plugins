#!/usr/bin/env bash
# Private runner helper: invoked only after mmo_leg_env has scrubbed the environment.
set +x
set -euo pipefail

key_file="$1"
shift
api_key=""
if [ -f "$key_file" ] && [ -r "$key_file" ]; then
  api_key="$(< "$key_file")"
fi
if [ -z "$api_key" ] || [[ "$api_key" == *$'\n'* || "$api_key" == *$'\r'* ]]; then
  printf 'run-claude: exit=75 MMO_CLAUDE_API_KEY_FILE unavailable or invalid\n' >&2
  exit 75
fi

# Redact before any output reaches the runner's files, including CLI error text.
redact() {
  local line
  while IFS= read -r line; do
    printf '%s\n' "${line//"$api_key"/[REDACTED]}"
  done
  printf '%s' "${line//"$api_key"/[REDACTED]}"
}
exec 3> >(redact >&2)
stderr_pid=$!
set +e
(
  export ANTHROPIC_API_KEY="$api_key"
  exec "$@"
) 2>&3 | redact
cli_rc=${PIPESTATUS[0]} redact_rc=${PIPESTATUS[1]}
exec 3>&-
wait "$stderr_pid"
stderr_rc=$?
set -e
[ "$cli_rc" -eq 0 ] || exit "$cli_rc"
[ "$redact_rc" -eq 0 ] || exit "$redact_rc"
exit "$stderr_rc"
