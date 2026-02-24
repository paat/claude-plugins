#!/bin/bash
# PostToolUse hook: auto-extract learnings from .startup/ handoffs/reviews/signoffs/go-live
# Deterministic path filter in bash — only fires systemMessage for matching files.
# Non-matching files get exit 0 with no output (guaranteed no "stopped continuation").
set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')

# Deterministic path filter — only .startup/ handoffs/reviews/signoffs/go-live .md files
if [[ ! "$file_path" =~ \.startup/(handoffs|reviews|signoffs|go-live)/.*\.md$ ]]; then
  exit 0
fi

# Matching file — instruct Claude to extract learnings via systemMessage on stderr
cat >&2 <<'MSG'
{"systemMessage": "Read the file just written. Extract up to 3 reusable project learnings (tech stack decisions, coding conventions, error patterns, API gotchas, business/legal rules). Skip obvious knowledge. Read CLAUDE.md at git root. If missing, create with '# Project Learnings' header and '## Learnings' section. If exists but lacks '## Learnings', append it. Skip entries semantically equivalent to existing ones. Append new entries under '## Learnings' — one dash per line, laconic (~15 words max), NEVER/ALWAYS for rules. Max 3 new entries. If nothing worth recording, do nothing."}
MSG
exit 2
