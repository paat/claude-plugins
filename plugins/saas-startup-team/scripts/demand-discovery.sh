#!/usr/bin/env bash
#
# demand-discovery.sh - internal evidence harvester for market/customer needs.
#
# No network access. It ingests configured local evidence sources and emits ranked,
# de-identified SaaS improvement candidates with acceptance criteria.
#
# Usage:
#   demand-discovery.sh [--project NAME] [--out FILE] [--report FILE]
#     [--claude-jsonl FILE]... [--codex-jsonl FILE]...
#     [--issues-json FILE] [--prs-json FILE] [--docs-dir DIR]...
#     [--test-log FILE]... [--analytics-json FILE]...

set -uo pipefail

PROJECT="$(basename "$PWD")"; OUT=".startup/demand/candidates.jsonl"; REPORT=".startup/demand/report.md"
CLAUDE_FILES=(); CODEX_FILES=(); DOC_DIRS=(); TEST_LOGS=(); ANALYTICS_FILES=()
ISSUES_JSON=""; PRS_JSON=""

_need_val() { [ "$1" -ge 2 ] || { echo "demand-discovery: $2 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project) _need_val "$#" "$1"; PROJECT="$2"; shift 2 ;;
    --out) _need_val "$#" "$1"; OUT="$2"; shift 2 ;;
    --report) _need_val "$#" "$1"; REPORT="$2"; shift 2 ;;
    --claude-jsonl) _need_val "$#" "$1"; CLAUDE_FILES+=("$2"); shift 2 ;;
    --codex-jsonl) _need_val "$#" "$1"; CODEX_FILES+=("$2"); shift 2 ;;
    --issues-json) _need_val "$#" "$1"; ISSUES_JSON="$2"; shift 2 ;;
    --prs-json) _need_val "$#" "$1"; PRS_JSON="$2"; shift 2 ;;
    --docs-dir) _need_val "$#" "$1"; DOC_DIRS+=("$2"); shift 2 ;;
    --test-log) _need_val "$#" "$1"; TEST_LOGS+=("$2"); shift 2 ;;
    --analytics-json) _need_val "$#" "$1"; ANALYTICS_FILES+=("$2"); shift 2 ;;
    *) echo "demand-discovery: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ "${#CLAUDE_FILES[@]}" -eq 0 ] && [ -f ".startup/insights/records.jsonl" ]; then
  CLAUDE_FILES+=(".startup/insights/records.jsonl")
fi
if [ "${#DOC_DIRS[@]}" -eq 0 ]; then
  for d in docs/learnings docs/research docs/business docs/operate; do
    [ -d "$d" ] && DOC_DIRS+=("$d")
  done
fi

mkdir -p "$(dirname "$OUT")" "$(dirname "$REPORT")"
: > "$OUT"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 2
PACKS="$SCRIPT_DIR/acceptance-packs.sh"

project_esc="$(printf '%s' "$PROJECT" | sed 's/[][\.*^$/]/\\&/g')"

deid() {
  local s="$1"
  [ -n "$project_esc" ] && s="$(printf '%s' "$s" | sed "s/${project_esc}/{{PROJECT}}/Ig")"
  printf '%s' "$s" | sed -E 's#[[:space:]]/[A-Za-z0-9._/@%+=:,~-]+#[ {{PATH}}#g; s#https?://[^[:space:])]+#{{URL}}#g; s/#[0-9]+/#N/g'
}

category_for() {
  local t
  t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    *onboarding*|*activation*|*signup*|*invite*) echo activation_onboarding ;;
    *pricing*|*checkout*|*payment*|*paid*|*billing*|*conversion*|*trial*) echo paid_conversion ;;
    *report*|*citation*|*finding*|*undefined*|*enum*|*output*|*summary*) echo report_output_quality ;;
    *async*|*background*|*webhook*|*retry*|*eta*|*timeout*|*job*) echo async_payment_reliability ;;
    *external*|*provider*|*api*|*rate-limit*|*unavailable*|*dependency*) echo external_data_dependency_failure ;;
    *gdpr*|*privacy*|*legal*|*compliance*|*regulation*|*tax*|*vat*) echo compliance_regulatory_coverage ;;
    *support*|*complaint*|*ticket*|*confus*|*customer*) echo support_burden_noise ;;
    *codex*|*claude*|*hook*|*agent*|*workflow*|*tool*) echo plugin_tooling_friction ;;
    *) echo product_demand ;;
  esac
}

add_signal() {
  local source="$1" ref="$2" text="$3"
  text="$(printf '%s' "$text" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  [ "${#text}" -ge 12 ] || return 0
  safe="$(deid "$text")"
  category="$(category_for "$safe")"
  jq -cn --arg source "$source" --arg ref "$(basename -- "$ref")" --arg text "$safe" --arg category "$category" \
    '{source:$source, ref:$ref, text:$text, category:$category}' >> "$TMP"
}

jsonl_texts() {
  local file="$1" source="$2"
  [ -f "$file" ] || return 0
  local line n text
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    text="$(printf '%s' "$line" | jq -r '
      [
        .text?,
        .body?,
        .sanitized_summary?,
        .message?.content?,
        .content?,
        (.messages[]?.content?),
        (.choices[]?.message?.content?)
      ]
      | flatten
      | map(if type=="object" then .text? // empty else . end)
      | map(select(type=="string"))
      | join(" ")
    ' 2>/dev/null || true)"
    [ -n "$text" ] && add_signal "$source" "$file:L$n" "$text"
  done < "$file"
}

for f in "${CLAUDE_FILES[@]}"; do jsonl_texts "$f" "claude-session"; done
for f in "${CODEX_FILES[@]}"; do jsonl_texts "$f" "codex-session"; done

if [ -f "$ISSUES_JSON" ]; then
  jq -cr '.[]? | [.title?, .body?] | map(select(type=="string")) | join(" ")' "$ISSUES_JSON" 2>/dev/null \
    | while IFS= read -r text; do add_signal "github-issue" "$ISSUES_JSON" "$text"; done
fi

if [ -f "$PRS_JSON" ]; then
  jq -cr '.[]? | [.title?, .body?] | map(select(type=="string")) | join(" ")' "$PRS_JSON" 2>/dev/null \
    | while IFS= read -r text; do add_signal "github-pr" "$PRS_JSON" "$text"; done
fi

for d in "${DOC_DIRS[@]}"; do
  [ -d "$d" ] || continue
  while IFS= read -r f; do
    add_signal "local-doc" "$f" "$(sed -n '1,80p' "$f")"
  done < <(find "$d" -type f \( -name '*.md' -o -name '*.txt' \) | sort)
done

for f in "${TEST_LOGS[@]}"; do
  [ -f "$f" ] && add_signal "test-failure" "$f" "$(grep -Ei 'fail|error|timeout|payment|checkout|report|undefined' "$f" 2>/dev/null | head -40)"
done

for f in "${ANALYTICS_FILES[@]}"; do
  [ -f "$f" ] && add_signal "analytics" "$f" "$(jq -c . "$f" 2>/dev/null || cat "$f")"
done

if [ ! -s "$TMP" ]; then
  {
    echo "# Demand discovery"
    echo
    echo "- candidates: 0"
    echo "- limitation: no configured local evidence produced demand signals"
  } > "$REPORT"
  exit 0
fi

jq -sc '
  group_by(.category)
  | map({
      category: .[0].category,
      count: length,
      evidence_refs: (map(.source + ":" + .ref) | unique | .[0:10]),
      snippets: (map(.text) | unique | .[0:3])
    })
  | map(. + {
      customer_pain: (if .count >= 3 then 5 elif .count == 2 then 4 else 3 end),
      willingness_to_pay: (if (.category|test("paid|payment|conversion|compliance")) then 4 else 3 end),
      urgency: (if (.category|test("payment|external|compliance|support")) then 4 else 3 end),
      implementation_complexity: (if (.category|test("external|compliance")) then 3 else 2 end),
      confidence: (if .count >= 3 then "high" elif .count == 2 then "medium" else "low" end)
    })
  | map(. + {score:(.customer_pain + .willingness_to_pay + .urgency - .implementation_complexity)})
  | sort_by(-.score, .category)
' "$TMP" | jq -c '.[]' | while IFS= read -r row; do
  category="$(printf '%s' "$row" | jq -r .category)"
  text="$(printf '%s' "$row" | jq -r '.snippets | join(" ")')"
  pack_ids="$("$PACKS" --select --category "$category" --text "$text" --json 2>/dev/null | jq -c '[.[].id]' 2>/dev/null || echo '[]')"
  jq -cn --argjson row "$row" --argjson packs "$pack_ids" '
    $row + {
      target_customer_segment:("Configured SaaS users affected by " + ($row.category | gsub("_"; " "))),
      discovered_need:("Reduce customer pain in " + ($row.category | gsub("_"; " "))),
      desired_customer_outcome:"The customer can complete the workflow without confusion, silent failure, or unsupported claims.",
      acceptance_packs:$packs,
      acceptance_criteria:[
        "Evidence-backed brief includes source refs and confidence.",
        "Implementation uses selected acceptance packs as gates.",
        "Verification covers the highest-risk customer workflow.",
        "No project-specific names, paths, tenants, or customer data appear in public artifacts."
      ],
      non_goals:["External market scouting", "Copying competitor-specific features", "Changing pricing promises without explicit approval"],
      rollout_checks:["Run the project check suite", "Update issue/PR with evidence and residual risks"]
    }
  ' >> "$OUT"
done

{
  echo "# Demand discovery"
  echo
  echo "- candidates: $(wc -l < "$OUT" | tr -d ' ')"
  echo "- sources: internal configured evidence only"
  echo "- external research: not used by this script"
  echo
  jq -r '"- " + .category + " score=" + (.score|tostring) + " confidence=" + .confidence + " refs=" + (.evidence_refs|length|tostring)' "$OUT"
} > "$REPORT"

exit 0
