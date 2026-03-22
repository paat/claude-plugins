#!/bin/bash
# check-handoff-secrets.sh — PostToolUse hook for Write|Edit events
# Blocks handoff files that contain hardcoded secrets, API keys, or passwords.
# Non-matching files exit 0 silently. Violations exit 2 with systemMessage.
set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // .tool_input.file_path // ""')

# Only check .startup/handoffs/ files and idle-handoff snapshots
if [[ ! "$file_path" =~ \.startup/handoffs/ ]] && [[ ! "$file_path" =~ \.startup/\.idle-handoff ]]; then
  exit 0
fi

# Read the file content
content=$(cat "$file_path" 2>/dev/null || exit 0)

# Patterns that match real secrets (not references to env var names or general discussion)
# Each pattern targets a specific credential format
violations=""

# API key values: sk-or-v1-..., sk-..., dl-..., key-... followed by 20+ hex/alphanum chars
if echo "$content" | grep -qE '(sk-or-v1-[a-f0-9]{20,}|sk-[a-zA-Z0-9]{20,}|dl-[a-f0-9]{20,}|key-[a-f0-9]{20,})'; then
  violations="${violations}API key value detected. "
fi

# Hardcoded env var assignments with actual values (KEY=value, not KEY=\$VAR or KEY=<placeholder>)
# Match: ADMIN_API_KEY=test123, SECRET_KEY=abc123, etc.
# Skip: KEY=${VAR}, KEY=<your-key>, KEY="", KEY=your_key_here, KEY=changeme
if echo "$content" | grep -qE '(API_KEY|SECRET_KEY|PASSWORD|ACCESS_KEY)=[^$<"{][a-zA-Z0-9_-]{4,}' | grep -qvE '(changeme|your_|example|placeholder|xxx)' 2>/dev/null; then
  violations="${violations}Hardcoded credential assignment detected. "
fi

# Bearer tokens or auth headers with actual values
if echo "$content" | grep -qE 'Authorization:\s*(Bearer|Basic)\s+[a-zA-Z0-9+/=_-]{20,}'; then
  violations="${violations}Hardcoded auth token detected. "
fi

# Curl commands with actual API key values in headers (not env var references like $API_KEY)
if echo "$content" | grep -qE 'X-API-Key:\s*[a-zA-Z0-9_-]{8,}' | grep -qvE '\$' 2>/dev/null; then
  violations="${violations}Hardcoded API key in curl command. "
fi

# More targeted: catch the specific patterns seen in real handoffs
# sk-or-v1- prefix (OpenRouter)
if echo "$content" | grep -qF 'sk-or-v1-'; then
  violations="${violations}OpenRouter API key detected. "
fi

# dl- prefix followed by hex (Datalake keys)
if echo "$content" | grep -qE 'dl-[a-f0-9]{30,}'; then
  violations="${violations}Datalake API key detected. "
fi

# Actual password values assigned to env vars
if echo "$content" | grep -qE '(ADMIN_API_KEY|ADMIN_PASSWORD|DB_PASSWORD|SECRET)=(test123|password|admin|secret)'; then
  violations="${violations}Test/default password in env var assignment. "
fi

if [ -n "$violations" ]; then
  cat >&2 <<MSG
{"systemMessage":"BLOCKED: This handoff contains hardcoded secrets or credentials. ${violations}NEVER write actual API keys, passwords, or tokens in handoff documents. Instead use: (1) env var references like \\\$OPENROUTER_API_KEY or \\\$ADMIN_API_KEY, (2) 'see .env file' references, (3) '<configured-in-env>' placeholders. Rewrite the handoff replacing all hardcoded secrets with env var references."}
MSG
  exit 2
fi

exit 0
