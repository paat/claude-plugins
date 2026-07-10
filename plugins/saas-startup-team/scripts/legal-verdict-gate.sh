#!/bin/bash
# legal-verdict-gate.sh — hedge-propagation gate for docs/legal/*.md verdict
# frontmatter (see skills/lawyer/SKILL.md "Output" for the schema).
#
# A hedged verdict is verdict != CONFIRMED OR blocking_human_tasks non-empty.
# Missing file, missing frontmatter, or missing verdict key is treated as
# hedged (fail-closed) — never a crash. Only the frontmatter block (between
# the first two `---` lines) is parsed; a `verdict:`-looking string in the
# document body is never read.
#
# Usage: legal-verdict-gate.sh [--enforce] <doc.md> [<doc.md>...]
# Emits one JSON object per doc on stdout:
#   {"doc": "<path>", "verdict": "...", "evidence_tier": "...",
#    "blocking_human_tasks": <n>, "hedged": true|false}
# Exit 0: normally (report only).
# Exit 2: with --enforce, if any doc is hedged, or on a usage error.

set -euo pipefail

enforce=false
if [ "${1:-}" = "--enforce" ]; then
  enforce=true
  shift
fi

if [ "$#" -eq 0 ]; then
  echo "Usage: legal-verdict-gate.sh [--enforce] <doc.md> [<doc.md>...]" >&2
  exit 2
fi

# Prints the raw value after "<field>: " on the first matching frontmatter
# line, or nothing if the field is absent. Frontmatter text comes in on stdin.
extract_scalar() {
  awk -v f="^$1:" '$0 ~ f { sub(/^[^:]*:[[:space:]]?/, ""); print; exit }'
}

trim() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

any_hedged=false

for doc in "$@"; do
  verdict=""
  evidence_tier=""
  count=0

  if [ -f "$doc" ] && [ "$(sed -n '1p' "$doc" 2>/dev/null || true)" = "---" ]; then
    end_line=$(awk 'NR>1 && /^---[[:space:]]*$/ { print NR; exit }' "$doc" || true)
    if [ -n "$end_line" ] && [ "$end_line" -gt 2 ]; then
      fm=$(sed -n "2,$((end_line - 1))p" "$doc")

      verdict=$(printf '%s\n' "$fm" | extract_scalar "verdict" | trim)
      evidence_tier=$(printf '%s\n' "$fm" | extract_scalar "evidence_tier" | trim)

      bht_raw=$(printf '%s\n' "$fm" | extract_scalar "blocking_human_tasks" | trim)
      if [ "$bht_raw" = "[]" ]; then
        count=0
      elif [ -z "$bht_raw" ]; then
        # Block-list form: count "- " entries under the key until the next
        # top-level (unindented) key or end of frontmatter.
        count=$(printf '%s\n' "$fm" | awk '
          /^blocking_human_tasks:[[:space:]]*$/ { found=1; next }
          found && /^[[:space:]]*-/ { c++; next }
          found && /^[^[:space:]]/ { found=0 }
          END { print c + 0 }
        ')
      elif [[ "$bht_raw" == \[*\] ]]; then
        # Inline non-empty list, e.g. ["a", "b"].
        inner="${bht_raw#\[}"
        inner="${inner%\]}"
        if [ -z "$(printf '%s' "$inner" | tr -d '[:space:]')" ]; then
          count=0
        else
          count=$(printf '%s\n' "$inner" | awk -F',' '{ print NF }')
        fi
      fi
    fi
  fi

  if [ -z "$verdict" ]; then
    verdict="UNCONFIRMED"
    hedged=true
  elif [ "$verdict" != "CONFIRMED" ] || [ "$count" -gt 0 ]; then
    hedged=true
  else
    hedged=false
  fi

  [ "$hedged" = true ] && any_hedged=true

  jq -nc \
    --arg doc "$doc" \
    --arg verdict "$verdict" \
    --arg tier "$evidence_tier" \
    --argjson bht "$count" \
    --argjson hedged "$hedged" \
    '{doc: $doc, verdict: $verdict, evidence_tier: $tier, blocking_human_tasks: $bht, hedged: $hedged}'
done

if [ "$enforce" = true ] && [ "$any_hedged" = true ]; then
  exit 2
fi
exit 0
