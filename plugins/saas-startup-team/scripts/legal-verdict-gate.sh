#!/bin/bash
# legal-verdict-gate.sh — hedge-propagation gate for docs/legal/*.md verdict
# frontmatter (schema: skills/lawyer/SKILL.md "Analysis Workflow" section;
# policy: its "Evidence-Tier Policy" section).
#
# A hedged verdict is verdict != CONFIRMED OR blocking_human_tasks non-empty.
# Missing file, missing frontmatter, or missing verdict key is treated as
# hedged (fail-closed) — never a crash. Only the frontmatter block (between
# the first two `---` lines) is parsed; a `verdict:`-looking string in the
# document body is never read.
#
# Usage: legal-verdict-gate.sh [--enforce|--validate] <doc.md> [<doc.md>...]
# Emits one JSON object per doc on stdout:
#   {"doc": "<path>", "verdict": "...", "evidence_tier": "...",
#    "blocking_human_tasks": <n>, "invalid_tier_a_quote": true|false,
#    "claim_hedged": true|false, "human_task_mismatch": true|false,
#    "over_budget": true|false,
#    "schema_invalid": true|false,
#    "hedged": true|false}
# Exit 0: normally (report only).
# Exit 2: with --validate, if a document is structurally invalid; with
# --enforce, if any document is hedged; or on a usage error.

set -euo pipefail

mode=report
case "${1:-}" in
  --enforce) mode=enforce; shift ;;
  --validate) mode=validate; shift ;;
  --*)
    echo "Usage: legal-verdict-gate.sh [--enforce|--validate] <doc.md> [<doc.md>...]" >&2
    exit 2
    ;;
esac

if [ "$#" -eq 0 ]; then
  echo "Usage: legal-verdict-gate.sh [--enforce|--validate] <doc.md> [<doc.md>...]" >&2
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
any_invalid=false

for doc in "$@"; do
  verdict=""
  evidence_tier=""
  count=0
  invalid_tier_a_quote=false
  claim_hedged=false
  human_task_mismatch=false
  over_budget=false
  schema_invalid=false
  structural_invalid=false
  line_count=0
  fm=""
  body=""

  # Strip \r so CRLF docs parse identically to LF docs.
  content=""
  [ -f "$doc" ] && content=$(tr -d '\r' < "$doc" 2>/dev/null || true)
  [ ! -f "$doc" ] || line_count=$(awk 'END { print NR + 0 }' "$doc")
  [ "$line_count" -le 150 ] || over_budget=true

  if [ "$(printf '%s\n' "$content" | sed -n '1p')" = "---" ]; then
    end_line=$(printf '%s\n' "$content" | awk 'NR>1 && /^---[[:space:]]*$/ { print NR; exit }' || true)
    if [ -n "$end_line" ] && [ "$end_line" -gt 2 ]; then
      fm=$(printf '%s\n' "$content" | sed -n "2,$((end_line - 1))p")
      body=$(printf '%s\n' "$content" | sed -n "$((end_line + 1)),\$p")

      verdict=$(printf '%s\n' "$fm" | extract_scalar "verdict" | trim)
      evidence_tier=$(printf '%s\n' "$fm" | extract_scalar "evidence_tier" | trim)

      bht_raw=$(printf '%s\n' "$fm" | extract_scalar "blocking_human_tasks" | trim)
      front_tasks=""
      bht_schema_valid=false
      if [ "$bht_raw" = "[]" ]; then
        count=0
        bht_schema_valid=true
      elif [ -z "$bht_raw" ]; then
        # Block-list form: count "- " entries under the key until the next
        # top-level (unindented) key or end of frontmatter.
        bht_block_check=$(printf '%s\n' "$fm" | awk '
          /^blocking_human_tasks:[[:space:]]*$/ { found=1; next }
          found && /^[[:space:]]*-/ {
            line=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            value=line
            if (value ~ /^"([^"\\]|\\.)+"$/) {
              sub(/^"/, "", value); sub(/"$/, "", value)
              if (value ~ /[^[:space:]]/) c++; else invalid=1
            } else invalid=1
            next
          }
          found && /^[^[:space:]]/ { found=0 }
          END { print c + 0, invalid + 0 }
        ')
        count=${bht_block_check%% *}
        bht_block_invalid=${bht_block_check#* }
        front_tasks=$(printf '%s\n' "$fm" | awk '
          /^blocking_human_tasks:[[:space:]]*$/ { found=1; next }
          found && /^[[:space:]]*-[[:space:]]+/ {
            line=$0
            sub(/^[[:space:]]*-[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line !~ /^"([^"\\]|\\.)+"$/) next
            sub(/^"/, "", line); sub(/"$/, "", line)
            if (line !~ /[^[:space:]]/) next
            print line; next
          }
          found && /^[^[:space:]]/ { exit }
        ')
        if [ "$count" -gt 0 ] && [ "$bht_block_invalid" -eq 0 ]; then
          bht_schema_valid=true
        fi
      elif [[ "$bht_raw" == \[*\] ]]; then
        # YAML inline JSON form. Only an array of strings satisfies the schema.
        if printf '%s' "$bht_raw" \
          | jq -e 'type == "array" and all(.[]; type == "string" and test("\\S"))' >/dev/null 2>&1; then
          count=$(printf '%s' "$bht_raw" | jq 'length')
          front_tasks=$(printf '%s' "$bht_raw" | jq -r '.[]')
          bht_schema_valid=true
        else
          count=1
        fi
      else
        count=1
      fi
      [ "$bht_schema_valid" = true ] || schema_invalid=true

      # Validate every claim's own schema. Confirmed Tier A claims additionally
      # require a complete scalar sentence from an HTTPS primary source.
      claim_check=$(printf '%s\n' "$fm" | awk '
        function terminal_quote_escaped(text, i, slashes) {
          for (i=length(text) - 1; i > 1 && substr(text, i, 1) == "\\"; i--)
            slashes++
          return slashes % 2
        }
        function scalar(line, first, last) {
          sub(/^[^:]*:[[:space:]]*/, "", line)
          sub(/[[:space:]]+$/, "", line)
          first=substr(line, 1, 1)
          last=substr(line, length(line), 1)
          if (first == "\"" || first == "\047") {
            if (length(line) < 2 || last != first ||
                (first == "\"" && terminal_quote_escaped(line))) {
              scalar_invalid=1
              return ""
            }
            line=substr(line, 2, length(line) - 2)
          } else if (last == "\"" || last == "\047") {
            scalar_invalid=1
            return ""
          }
          return line
        }
        function blank(value) {
          gsub(/[[:space:]]/, "", value)
          return value == ""
        }
        function valid_https(url) {
          return url ~ /^https:\/\/[[:alnum:]]([[:alnum:].-]*[[:alnum:]])?(:[0-9]+)?([\/?#].*)?$/
        }
        function leap_year(year) {
          return year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)
        }
        function valid_date(text, parts, year, month, day, maximum) {
          if (text !~ /^[0-9][0-9][0-9][0-9]-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$/)
            return 0
          split(text, parts, "-")
          year=parts[1] + 0; month=parts[2] + 0; day=parts[3] + 0
          maximum=31
          if (month == 4 || month == 6 || month == 9 || month == 11) maximum=30
          if (month == 2) maximum=28 + leap_year(year)
          return day <= maximum
        }
        function finish() {
          if (!claim) return
          if (scalar_invalid || blank(id) || claim_verdict !~ /^(CONFIRMED|UNCONFIRMED|UNVERIFIABLE-IN-CORPUS)$/ ||
              claim_tier !~ /^(A|B|C)$/ || blank(value) ||
              !valid_https(source) || blank(quote) ||
              !valid_date(verified) || !valid_date(review)) {
            schema_invalid=1
          }
          if (claim_verdict != "CONFIRMED") claim_hedged=1
          if (claim_verdict == "CONFIRMED" &&
              (claim_tier != "A" || !valid_https(source) || blank(quote) ||
               quote !~ /[.!?]$/ || quote ~ /(\.\.\.|…|\[\.\.\.\]|\[…\])/)) {
            invalid=1
          }
        }
        /^claims:[[:space:]]*\[[[:space:]]*\][[:space:]]*$/ { claims_key=1; next }
        /^claims:[[:space:]]*$/ { claims_key=1; in_claims=1; next }
        in_claims && /^  - id:[[:space:]]*/ {
          finish(); claim=1; claim_count++; id=scalar($0); claim_verdict=""; claim_tier=""
          value=""; source=""; quote=""; verified=""; review=""
          next
        }
        in_claims && /^  - / { finish(); claim=1; claim_count++; schema_invalid=1; next }
        in_claims && /^[^[:space:]]/ { finish(); in_claims=0 }
        in_claims && claim && /^    verdict:[[:space:]]*/ { claim_verdict=scalar($0); next }
        in_claims && claim && /^    evidence_tier:[[:space:]]*/ { claim_tier=scalar($0); next }
        in_claims && claim && /^    value:[[:space:]]*/ { value=scalar($0); next }
        in_claims && claim && /^    source_url:[[:space:]]*/ { source=scalar($0); next }
        in_claims && claim && /^    quote:[[:space:]]*/ { quote=scalar($0); next }
        in_claims && claim && /^    verified_at:[[:space:]]*/ { verified=scalar($0); next }
        in_claims && claim && /^    review_by:[[:space:]]*/ { review=scalar($0); next }
        END {
          finish()
          if (!claims_key || claim_count == 0) schema_invalid=1
          print invalid + 0, schema_invalid + 0, claim_hedged + 0
        }
      ')
      claim_invalid=${claim_check%% *}
      claim_check_rest=${claim_check#* }
      claim_schema_invalid=${claim_check_rest%% *}
      claim_hedged_raw=${claim_check_rest#* }
      if [ "$claim_invalid" -ne 0 ]; then
        invalid_tier_a_quote=true
      fi
      if [ "$claim_schema_invalid" -ne 0 ]; then
        schema_invalid=true
      fi
      if [ "$claim_hedged_raw" -ne 0 ]; then
        claim_hedged=true
      fi

      section_tasks=$(printf '%s\n' "$body" | awk '
        /^##[[:space:]]+(Inimülesanded|Human Tasks)([[:space:]]|$)/ { section=1; next }
        section && /^##[[:space:]]/ { exit }
        section && /^[[:space:]]*[-*][[:space:]]+/ {
          line=$0; sub(/^[[:space:]]*[-*][[:space:]]+/, "", line); print line; next
        }
        section && /^[[:space:]]*[0-9]+\.[[:space:]]+/ {
          line=$0; sub(/^[[:space:]]*[0-9]+\.[[:space:]]+/, "", line); print line
        }
      ')
      marked_tasks=$(printf '%s\n' "$body" \
        | grep -E '^[[:space:]]*[-*][[:space:]].*\[(INIMENE|HUMAN)' 2>/dev/null \
        | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' || true)
      body_tasks=$(printf '%s\n%s\n' "$section_tasks" "$marked_tasks" \
        | awk 'NF && !seen[$0]++')
      front_normalized=$(printf '%s\n' "$front_tasks" | awk 'NF' | LC_ALL=C sort -u)
      body_normalized=$(printf '%s\n' "$body_tasks" | awk 'NF' | LC_ALL=C sort -u)
      [ "$front_normalized" = "$body_normalized" ] || human_task_mismatch=true
    fi
  fi

  case "$verdict" in CONFIRMED|UNCONFIRMED|UNVERIFIABLE-IN-CORPUS) : ;; *) schema_invalid=true ;; esac
  case "$evidence_tier" in A|B|C) : ;; *) schema_invalid=true ;; esac
  if [ "$verdict" = CONFIRMED ] && [ "$evidence_tier" != A ]; then
    schema_invalid=true
  fi
  if [ "$invalid_tier_a_quote" = true ] || [ "$human_task_mismatch" = true ] \
    || [ "$over_budget" = true ] || [ "$schema_invalid" = true ]; then
    structural_invalid=true
    any_invalid=true
  fi

  if [ -z "$verdict" ]; then
    verdict="UNCONFIRMED"
    hedged=true
  elif [ "$verdict" != "CONFIRMED" ] || [ "$claim_hedged" = true ] || [ "$count" -gt 0 ] \
    || [ "$structural_invalid" = true ]; then
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
    --argjson invalid_quote "$invalid_tier_a_quote" \
    --argjson claim_hedged "$claim_hedged" \
    --argjson task_mismatch "$human_task_mismatch" \
    --argjson line_count "$line_count" \
    --argjson over_budget "$over_budget" \
    --argjson schema_invalid "$schema_invalid" \
    --argjson structural_invalid "$structural_invalid" \
    --argjson hedged "$hedged" \
    '{doc: $doc, verdict: $verdict, evidence_tier: $tier, blocking_human_tasks: $bht, invalid_tier_a_quote: $invalid_quote, claim_hedged: $claim_hedged, human_task_mismatch: $task_mismatch, line_count: $line_count, over_budget: $over_budget, schema_invalid: $schema_invalid, structural_invalid: $structural_invalid, hedged: $hedged}'
done

if [ "$mode" = "validate" ] && [ "$any_invalid" = true ]; then
  exit 2
fi
if [ "$mode" = "enforce" ] && [ "$any_hedged" = true ]; then
  exit 2
fi
exit 0
