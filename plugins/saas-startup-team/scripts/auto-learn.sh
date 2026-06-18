#!/bin/bash
# PostToolUse hook: auto-extract learnings from .startup/ handoffs/reviews/signoffs/go-live
# Deterministic path filter in bash — only fires systemMessage for matching files.
# Non-matching files get exit 0 with no output (guaranteed no "stopped continuation").
#
# Caps the '### Recent (unsorted)' staging area in CLAUDE.md at SAAS_LEARNINGS_MAX
# entries (default 10). When the staged count nears the cap, the systemMessage also
# instructs Claude to migrate the surplus into docs/learnings/<topic>.md topic files,
# keeping CLAUDE.md lean. Requires: jq, awk.
set -euo pipefail

# Max staged learnings allowed in '### Recent (unsorted)' before auto-migration kicks in.
# Guard a malformed override (empty/non-numeric/float) — a bad value would otherwise
# abort the whole hook under `set -e` on the arithmetic expansion below.
max="${SAAS_LEARNINGS_MAX:-10}"
[[ "$max" =~ ^[1-9][0-9]*$ ]] || max=10

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')

# Deterministic path filter — only .startup/ handoffs/reviews/signoffs/go-live .md files
if [[ ! "$file_path" =~ \.startup/(handoffs|reviews|signoffs|go-live)/.*\.md$ ]]; then
  exit 0
fi

# Deterministically count dash-bullets staged in '### Recent (unsorted)' of CLAUDE.md.
ref_dir=$(dirname "$file_path")
[[ -d "$ref_dir" ]] || ref_dir="$PWD"
git_root=$(git -C "$ref_dir" rev-parse --show-toplevel 2>/dev/null || true)
claude_md="$git_root/CLAUDE.md"

recent_count=0
if [[ -n "$git_root" && -f "$claude_md" ]]; then
  recent_count=$(awk '
    /^### Recent \(unsorted\)/ { insec=1; next }
    insec && /^#{1,3} /        { insec=0 }
    insec && /^[[:space:]]*- / { n++ }
    END                        { print n+0 }
  ' "$claude_md")
fi

# Base extraction instruction (unchanged behaviour).
msg='Read the file just written. Extract up to 3 reusable project learnings (tech stack decisions, coding conventions, error patterns, API gotchas, business/legal rules). Skip obvious knowledge. Find git root (git rev-parse --show-toplevel). Ensure CLAUDE.md exists with '"'"'# Project Learnings'"'"' H1 and '"'"'## Learnings'"'"' H2. List files in docs/learnings/*.md at git root (skip if dir missing); for each, read the first '"'"'#'"'"'/'"'"'##'"'"' heading line (fall back to filename stem with dashes→spaces if no heading) to build a topic catalog. For each candidate learning: (a) skip if semantically equivalent to any existing entry in any topic file or in '"'"'### Recent (unsorted)'"'"'; (b) if it clearly fits one existing topic file, append a dash-bullet to that file; (c) otherwise ensure '"'"'### Recent (unsorted)'"'"' subsection exists under '"'"'## Learnings'"'"' with comment '"'"'<!-- Uncertain/new-topic learnings staged here. Run /saas-startup-team:learnings-migrate to organise into docs/learnings/*.md. -->'"'"' and append the dash-bullet there. One dash per line, laconic (~15 words max), NEVER/ALWAYS for rules. Max 3 new entries total. If nothing worth recording, do nothing.'

# Cap enforcement — trigger migration when appending up to 3 entries could exceed the cap.
# threshold = max - 2 (floored at 1) so Recent self-heals back to <= max each run.
threshold=$(( max > 2 ? max - 2 : 1 ))
if (( recent_count >= threshold )); then
  msg="$msg"' THEN enforce the '"'"'### Recent (unsorted)'"'"' cap of '"$max"' entries (it currently holds ~'"$recent_count"'): after appending, if Recent holds more than '"$max"' dash-bullets, migrate the surplus — oldest first (entries nearest the top of Recent) — into docs/learnings/. For each migrated entry: route it to the best-fit existing topic file by matching against the '"'"'## Domain Learnings'"'"' catalog and append a dash-bullet there; if no topic fits, create docs/learnings/<kebab-topic>.md with a '"'"'# <Topic>'"'"' H1, append the entry, and add a '"'"'- [<Topic>](docs/learnings/<kebab-topic>.md) — <hook>'"'"' line to the '"'"'## Domain Learnings'"'"' index. Then delete every migrated bullet from Recent so it ends with at most '"$max"' entries. Never drop a learning — only relocate it. Skip an entry only if it is semantically equivalent to one already in its target topic file (still remove it from Recent).'
fi

# Emit the systemMessage as valid JSON (jq handles escaping).
jq -cn --arg m "$msg" '{systemMessage: $m}' >&2
exit 2
