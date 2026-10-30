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

# Only the literal path reaches argv; Claude reads the key privately.
unset api_key MMO_CLAUDE_API_KEY_FILE
settings="$(jq -nc --arg path "$key_file" \
  '{apiKeyHelper: ("cat -- " + ($path | @sh)),
    env: {CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD: "1"}}')"
# Excluding settings also skips memory; explicitly reload project-root CLAUDE.md.
exec "$@" --setting-sources '' --add-dir "$PWD" \
  --settings "$settings" 3>&-
