#!/usr/bin/env bash
# /lawyer marker scan (internal helper). Scans project source for `LAW:` markers
# and prints one "<slug>\t<file>:<line>" line per marker-slug pair on stdout.
# Scope: source + customer-facing content; excludes docs/legal/ (lawyer output).
set -uo pipefail

SCAN_DIRS=()
for d in src app pages components lib server public content docs; do
  [ -d "$d" ] && SCAN_DIRS+=("$d")
done

# Guard: with no known source dirs, skip entirely — an unscoped rg/grep would
# recurse from cwd and match LAW: tokens in docs/plans/, .startup/, node_modules.
if [ ${#SCAN_DIRS[@]} -eq 0 ]; then
  exit 0
fi

PATTERN='(//|#|/\*|<!--|\{/\*)\s*LAW:\s*[a-z0-9-]+(\s*,\s*[a-z0-9-]+)*'
if command -v rg >/dev/null 2>&1; then
  raw=$(rg -n --pcre2 "$PATTERN" "${SCAN_DIRS[@]}" 2>/dev/null | grep -v '^docs/legal/' || true)
else
  raw=$(grep -rEn "$PATTERN" "${SCAN_DIRS[@]}" 2>/dev/null | grep -v '^docs/legal/' || true)
fi

printf '%s\n' "$raw" | awk -F: '
  {
    file=$1; line=$2
    tail=""
    for (i=3; i<=NF; i++) tail = tail (i==3?"":":") $i
    if (match(tail, /LAW:[[:space:]]*[a-z0-9,\- \t]+/) == 0) next
    slugs = substr(tail, RSTART+4)   # drop "LAW:" prefix
    gsub(/\*\/.*/, "", slugs)
    gsub(/-->.*/, "", slugs)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", slugs)
    ns = split(slugs, arr, /[[:space:]]*,[[:space:]]*/)
    for (j=1; j<=ns; j++) {
      s = arr[j]
      if (s ~ /^[a-z0-9-]+$/) print s "\t" file ":" line
    }
  }
'
