#!/bin/bash
# check-estonian-diacritics.sh — PreToolUse hook for Write events
# Blocks writing spec.md if Estonian ad copy contains ASCII substitutes
# for diacritical characters (ö→o, ä→a, ü→u, õ→o, š→s, ž→z).
#
# Only fires on iterations/vN/spec.md writes.
# Checks for common Estonian words that are ALWAYS wrong in ASCII form.
#
# Input: JSON on stdin with tool_input.file_path and tool_input.content
# Exit 0: not a spec.md, or no diacritics violations found
# Exit 2: blocked — ASCII-for-diacritics detected

set -euo pipefail

input=$(cat)

file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

# Only check iterations/vN/spec.md writes
if [[ ! "$file_path" =~ docs/ads/[^/]+/iterations/v[0-9]+/spec\.md$ ]]; then
  exit 0
fi

content=$(echo "$input" | jq -r '.tool_input.content // empty' 2>/dev/null)
[ -z "$content" ] && exit 0

# Check if the spec contains Estonian language markers
# Only enforce diacritics check if Estonian content is present
if ! echo "$content" | grep -qiP '(language:\s*et|— language: et|estonian)'; then
  exit 0
fi

# Common Estonian words that are ALWAYS wrong without diacritics.
# Pattern: ASCII-wrong-form → correct form
# These are word-boundary-safe patterns to avoid false positives.
violations=()

# ü → u violations
if echo "$content" | grep -qP '(?i)\bules\b'; then
  violations+=("'ules' should be 'üles'")
fi

# ä → a violations
if echo "$content" | grep -qP '\bTahtaeg\b'; then
  violations+=("'Tahtaeg' should be 'Tähtaeg'")
fi

# ö → o violations
if echo "$content" | grep -qP '(?i)\bkottejotlik\b'; then
  violations+=("'kottejotlik' should be 'kõttejõtlik'")
fi

# õ → o violations
if echo "$content" | grep -qP '(?i)\bpohjalik\b'; then
  violations+=("'pohjalik' should be 'põhjalik'")
fi
if echo "$content" | grep -qP '(?i)\btoendipohine\b'; then
  violations+=("'toendipohine' should be 'tõendipõhine'")
fi

# š → s violations
if echo "$content" | grep -qP '(?i)\bsabloon\b'; then
  violations+=("'sabloon' should be 'šabloon'")
fi

# General pattern: detect headlines/descriptions that contain ZERO Estonian
# diacritics despite being marked as Estonian language — likely all-ASCII
estonian_diacritics_count=$(echo "$content" | grep -cP '[äöüõšžÄÖÜÕŠŽ]' || true)
estonian_word_count=$(echo "$content" | grep -ciP '(aruanne|teenus|ettevot|maksu|arve|tahtaeg|toendip)' || true)

if [ "$estonian_word_count" -gt 5 ] && [ "$estonian_diacritics_count" -lt 3 ]; then
  violations+=("Spec contains $estonian_word_count Estonian words but only $estonian_diacritics_count diacritical characters — likely all-ASCII. Every Estonian headline and description must use proper diacritics (ä, ö, ü, õ, š, ž)")
fi

if [ ${#violations[@]} -gt 0 ]; then
  violation_list=$(printf '\\n- %s' "${violations[@]}")
  cat >&2 <<MSG
{"systemMessage":"BLOCKED: ${file_path} contains Estonian ad copy with ASCII substitutes for diacritical characters. Google Ads will display these literally — 'Tahtaeg' is not 'Tähtaeg' and looks illiterate to Estonian speakers.\\n\\nViolations found:${violation_list}\\n\\nFix: Rewrite all Estonian headlines and descriptions with proper diacritics (ä, ö, ü, õ, š, ž). Then retry the write."}
MSG
  exit 2
fi

exit 0
