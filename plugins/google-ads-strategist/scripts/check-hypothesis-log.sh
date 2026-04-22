#!/bin/bash
# check-hypothesis-log.sh — PreToolUse hook for Write events
# When result.md is written, validates that hypothesis-log.md has been updated
# with an entry for the current iteration version.
#
# Real campaign post-mortems revealed hypothesis-log.md was sometimes left empty
# after result.md was committed — this hook prevents that gap.
#
# Input: JSON on stdin with tool_input.file_path
# Exit 0: not a result.md, or hypothesis-log.md has the entry
# Exit 2: blocked — hypothesis-log.md missing the iteration entry

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check iterations/vN/result.md writes
if [[ ! "$file_path" =~ docs/ads/([^/]+)/iterations/v([0-9]+)/result\.md$ ]]; then
  exit 0
fi

campaign="${BASH_REMATCH[1]}"
version="v${BASH_REMATCH[2]}"
campaign_dir=$(echo "$file_path" | sed -E 's|(docs/ads/[^/]+)/.*|\1|')

log_file="${campaign_dir}/hypothesis-log.md"

# If hypothesis-log.md doesn't exist at all, block
if [ ! -f "$log_file" ]; then
  cat >&2 <<MSG
{"systemMessage":"BLOCKED: Writing ${file_path} but hypothesis-log.md does not exist at ${log_file}. Create it with the header row first, then add the ${version} entry before writing result.md."}
MSG
  exit 2
fi

# Check that the log contains an entry for this version
# Match "| vN |" or "| vN|" patterns in the table, or "vN" at start of a table row
if ! grep -qP "\\|\\s*${version}\\s*\\|" "$log_file"; then
  cat >&2 <<MSG
{"systemMessage":"BLOCKED: Writing ${file_path} but hypothesis-log.md has no entry for ${version}. Update ${log_file} with the ${version} row (date, loop, variable class, scope, prediction) BEFORE writing result.md. The log is append-only — add the row, then write the result."}
MSG
  exit 2
fi

exit 0
