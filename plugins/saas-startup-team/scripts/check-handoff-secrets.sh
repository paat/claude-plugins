#!/bin/bash
# check-handoff-secrets.sh — PostToolUse hook for Write|Edit events
# Scrubs hardcoded secrets, API keys, and passwords from handoff files.
#
# IMPORTANT: this hook REDACTS in place and exits 0 — it never blocks the write.
# Handoffs live under .startup/ which is gitignored, so a blocked (exit 2) write
# was silently lost: the orchestrator would re-dispatch the same task repeatedly
# (especially on LLM-gateway/auth/payment features whose proofs naturally contain
# `Authorization: Bearer …` or `KEY=value`). Redacting instead of blocking keeps
# the handoff on disk, removes the secret, and breaks the block→rewrite→block
# loop that exhausted founder-agent budgets. See GitHub issue #102.
#
# Non-matching files exit 0 silently. Redacted files exit 0 with a non-blocking
# systemMessage so the author learns to reference env var NAMES next time.
set -euo pipefail

input=$(cat)
# Never let malformed/empty hook input abort the script — the hook must not block.
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)

# Only scrub .startup/handoffs/ files and idle-handoff snapshots
if [[ ! "$file_path" =~ \.startup/handoffs/ ]] && [[ ! "$file_path" =~ \.startup/\.idle-handoff ]]; then
  exit 0
fi

# Bail quietly if the file isn't a readable regular file (e.g. already gone)
[ -f "$file_path" ] || exit 0

REDACT='***REDACTED***'

# Count secret markers already present so we only report values WE scrubbed.
# grep exits 1 on no matches — guard it so set -e/pipefail don't abort the hook.
before=$( { grep -oF "$REDACT" "$file_path" 2>/dev/null || true; } | wc -l | tr -d ' ')

# Redact in place. Order matters: redact whole KEY=value assignments first (bare,
# then double/single-quoted) so a recognizable-prefix value inside an assignment
# isn't double-marked, then redact bare tokens (header / prefix forms) elsewhere.
#
# Each assignment pattern preserves env-var REFERENCES ($VAR, ${VAR}), placeholders
# (<…>), and empty values — those start with a guarded first char and don't match.
# Header matches are first-letter case-insensitive ([Aa]/[Bb]/…) to catch lowercase
# curl variants. Note the bare sk-/dl-/key- prefix passes still scrub recognizable
# keys anywhere — including inside quotes or lowercase headers a rule above missed.
sed -E -i.sec.bak \
  -e 's/([A-Z][A-Z0-9_]*(API_KEY|SECRET_KEY|ACCESS_KEY|PASSWORD|TOKEN|SECRET))[[:space:]]*=[[:space:]]*[^[:space:]$<"'"'"'{][A-Za-z0-9._/+:-]*/\1='"$REDACT"'/g' \
  -e 's/([A-Z][A-Z0-9_]*(API_KEY|SECRET_KEY|ACCESS_KEY|PASSWORD|TOKEN|SECRET))[[:space:]]*=[[:space:]]*"[^$<{"][^"]*"/\1="'"$REDACT"'"/g' \
  -e 's/([A-Z][A-Z0-9_]*(API_KEY|SECRET_KEY|ACCESS_KEY|PASSWORD|TOKEN|SECRET))[[:space:]]*=[[:space:]]*'"'"'[^$<{'"'"'][^'"'"']*'"'"'/\1='"'"''"$REDACT"''"'"'/g' \
  -e 's/([Aa]uthorization:[[:space:]]*([Bb]earer|[Bb]asic)[[:space:]]+)[A-Za-z0-9+/=_.-]{20,}/\1'"$REDACT"'/g' \
  -e 's/([Xx]-[Aa][Pp][Ii]-[Kk]ey:[[:space:]]*)[A-Za-z0-9_-]{8,}/\1'"$REDACT"'/g' \
  -e 's/sk-or-v1-[A-Za-z0-9_-]{20,}/sk-or-v1-'"$REDACT"'/g' \
  -e 's/sk-[A-Za-z0-9]{20,}/sk-'"$REDACT"'/g' \
  -e 's/dl-[a-f0-9]{20,}/dl-'"$REDACT"'/g' \
  -e 's/key-[a-f0-9]{20,}/key-'"$REDACT"'/g' \
  "$file_path"

changed=0
cmp -s "$file_path" "$file_path.sec.bak" || changed=1
rm -f "$file_path.sec.bak"

if [ "$changed" -eq 1 ]; then
  after=$( { grep -oF "$REDACT" "$file_path" 2>/dev/null || true; } | wc -l | tr -d ' ')
  n=$((after - before))
  [ "$n" -lt 1 ] && n=1
  # Build the message with single-quoted printf (no shell expansion of $VAR names),
  # then let jq emit it — guarantees valid JSON regardless of the filename's bytes.
  msg=$(printf 'check-handoff-secrets: auto-redacted %s hardcoded secret value(s) in %s — the handoff was SAVED, not blocked. To avoid redaction, reference env var NAMES only (e.g. $OPENROUTER_API_KEY, $ADMIN_API_KEY) or '\''see .env'\'', never literal keys/tokens/passwords or auth curls.' "$n" "$(basename "$file_path")")
  jq -nc --arg msg "$msg" '{systemMessage:$msg}'
fi

exit 0
