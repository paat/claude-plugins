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
{"systemMessage": "Read the file just written. Extract up to 3 reusable project learnings (tech stack decisions, coding conventions, error patterns, API gotchas, business/legal rules). Skip obvious knowledge. Find git root (git rev-parse --show-toplevel). Ensure CLAUDE.md exists with '# Project Learnings' H1 and '## Learnings' H2. List files in docs/learnings/*.md at git root (skip if dir missing); for each, read the first '#'/'##' heading line (fall back to filename stem with dashes→spaces if no heading) to build a topic catalog. For each candidate learning: (a) skip if semantically equivalent to any existing entry in any topic file or in '### Recent (unsorted)'; (b) if it clearly fits one existing topic file, append a dash-bullet to that file; (c) otherwise ensure '### Recent (unsorted)' subsection exists under '## Learnings' with comment '<!-- Uncertain/new-topic learnings staged here. Run /saas-startup-team:learnings-migrate to organise into docs/learnings/*.md. -->' and append the dash-bullet there. One dash per line, laconic (~15 words max), NEVER/ALWAYS for rules. Max 3 new entries total. If nothing worth recording, do nothing."}
MSG
exit 2
