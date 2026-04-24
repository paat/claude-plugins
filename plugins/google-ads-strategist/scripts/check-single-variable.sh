#!/bin/bash
# check-single-variable.sh — PreToolUse hook for Write events
# Validates that iterations/vN/hypothesis.md being written declares exactly ONE
# variable class, or multivariate with explicit justification.
# Runs BEFORE the write — reads content from tool_input.content.
#
# Input: JSON on stdin with tool_input.file_path and tool_input.content
# Exit 0: not a hypothesis.md, or valid
# Exit 2: blocked — invalid frontmatter

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

if [[ ! "$file_path" =~ docs/ads/[^/]+/iterations/v[0-9]+/hypothesis\.md$ ]]; then
  exit 0
fi

# Read the content about to be written from the tool input (PreToolUse)
content=$(echo "$input" | jq -r '.tool_input.content // empty' 2>/dev/null)

# Fallback: if content is not in the input (e.g., invoked via Edit), try reading existing file
if [ -z "$content" ] && [ -f "$file_path" ]; then
  content=$(cat "$file_path")
fi

[ -z "$content" ] && exit 0  # nothing to validate

# Extract variable class — accept bold-label style or frontmatter style
variable_class=$(echo "$content" | grep -ioP '\*\*Variable class\*\*:\s*\K[a-z-]+' | head -1 || true)
[ -z "$variable_class" ] && variable_class=$(echo "$content" | grep -ioP '^variable_class:\s*\K[a-z-]+' | head -1 || true)

if [ -z "$variable_class" ]; then
  cat >&2 <<MSG
{"systemMessage":"BLOCKED: ${file_path} is missing the variable class declaration. Add a '**Variable class**: [keywords|copy|targeting|landing-page|bidding|extensions|multivariate]' line at the top of the hypothesis."}
MSG
  exit 2
fi

valid_classes="keywords copy targeting landing-page bidding extensions multivariate"
if ! echo "$valid_classes" | grep -qw "$variable_class"; then
  cat >&2 <<MSG
{"systemMessage":"BLOCKED: ${file_path} declares variable_class='${variable_class}' which is not one of: ${valid_classes}. Pick exactly one class, or use 'multivariate' with explicit justification."}
MSG
  exit 2
fi

if [ "$variable_class" = "multivariate" ]; then
  if ! echo "$content" | grep -qiP '(multivariate justification|multivariate_justification|## multivariate rationale)'; then
    cat >&2 <<MSG
{"systemMessage":"BLOCKED: ${file_path} declares multivariate but has no justification. Add a '## Multivariate justification' section explaining why changing multiple variable classes at once is necessary. Single-variable iterations are the default — multivariate needs a reason."}
MSG
    exit 2
  fi
fi

if ! echo "$content" | grep -qiP '\*\*Prediction\*\*:'; then
  cat >&2 <<MSG
{"systemMessage":"BLOCKED: ${file_path} is missing a '**Prediction**:' line. A hypothesis without a falsifiable prediction is not a hypothesis. Add the observable outcome you expect."}
MSG
  exit 2
fi

exit 0
