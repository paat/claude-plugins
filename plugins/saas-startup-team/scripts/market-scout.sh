#!/usr/bin/env bash
#
# market-scout.sh - external market-signal scout with internal fallback.
#
# It converts legally usable public/external evidence into ranked SaaS improvement
# candidates. If no external source is configured or fetchable, it runs the local
# demand-discovery fallback instead of blocking for user input.
#
# Usage:
#   market-scout.sh [--project NAME] [--category TEXT]
#     [--source-json FILE]... [--source-url URL]...
#     [--out FILE] [--report FILE]

set -uo pipefail

PROJECT="$(basename "$PWD")"
CATEGORY="${SAAS_MARKET_SCOUT_CATEGORY:-}"
OUT=".startup/demand/market-scout.jsonl"
REPORT=".startup/demand/market-scout-report.md"
SOURCE_JSON_FILES=()
SOURCE_URLS=()

_need_val() { [ "$1" -ge 2 ] || { echo "market-scout: $2 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project) _need_val "$#" "$1"; PROJECT="$2"; shift 2 ;;
    --category) _need_val "$#" "$1"; CATEGORY="$2"; shift 2 ;;
    --source-json) _need_val "$#" "$1"; SOURCE_JSON_FILES+=("$2"); shift 2 ;;
    --source-url) _need_val "$#" "$1"; SOURCE_URLS+=("$2"); shift 2 ;;
    --out) _need_val "$#" "$1"; OUT="$2"; shift 2 ;;
    --report) _need_val "$#" "$1"; REPORT="$2"; shift 2 ;;
    *) echo "market-scout: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -n "${SAAS_MARKET_SCOUT_SOURCES_FILE:-}" ]; then
  SOURCE_JSON_FILES+=("$SAAS_MARKET_SCOUT_SOURCES_FILE")
fi
if [ -n "${SAAS_MARKET_SCOUT_URLS:-}" ]; then
  # shellcheck disable=SC2206
  SOURCE_URLS+=($SAAS_MARKET_SCOUT_URLS)
fi

mkdir -p "$(dirname "$OUT")" "$(dirname "$REPORT")"
: > "$OUT"

TMP="$(mktemp)"
FETCH_LOG="$(mktemp)"
trap 'rm -f "$TMP" "$FETCH_LOG"' EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 2
PACKS="$SCRIPT_DIR/acceptance-packs.sh"

project_esc="$(printf '%s' "$PROJECT" | sed 's/[][\.*^$/]/\\&/g')"

deid() {
  local s="$1"
  [ -n "$project_esc" ] && s="$(printf '%s' "$s" | sed "s/${project_esc}/{{PROJECT}}/Ig")"
  printf '%s' "$s" | sed -E \
    -e 's#[[:space:]]/[A-Za-z0-9._/@%+=:,~-]+# {{PATH}}#g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/{{EMAIL}}/g' \
    -e 's/#[0-9]+/#N/g'
}

category_for() {
  local t
  t="$(printf '%s %s' "$CATEGORY" "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    *pricing*|*packaging*|*plan*|*paid*|*trial*|*conversion*) echo pricing_packaging_gap ;;
    *complaint*|*review*|*support*|*frustrat*|*confus*|*manual*) echo public_complaint_pain ;;
    *regulat*|*compliance*|*gdpr*|*vat*|*tax*|*law*) echo regulatory_change ;;
    *competitor*|*alternative*|*feature*|*gap*) echo competitor_feature_gap ;;
    *search*|*content*|*seo*|*keyword*) echo search_content_gap ;;
    *estonian*|*e-resident*|*micro-o*|*micro-ou*|*micro-oue*|*micro-oü*) echo estonian_micro_saas_gap ;;
    *) echo external_market_need ;;
  esac
}

add_evidence() {
  local source_type="$1" title="$2" url="$3" date="$4" snippet="$5"
  local text safe category today
  text="$(printf '%s %s' "$title" "$snippet" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  [ "${#text}" -ge 12 ] || return 0
  safe="$(deid "$text")"
  category="$(category_for "$safe")"
  today="$(date -u +%Y-%m-%d)"
  [ -n "$date" ] || date="$today"
  jq -cn \
    --arg source_type "$source_type" \
    --arg title "$(deid "$title")" \
    --arg url "$url" \
    --arg date "$date" \
    --arg snippet "$(deid "$snippet")" \
    --arg category "$category" \
    '{source_type:$source_type,title:$title,url:$url,date:$date,snippet:$snippet,category:$category}' >> "$TMP"
}

load_source_json() {
  local file="$1"
  [ -f "$file" ] || { echo "missing source-json: $file" >> "$FETCH_LOG"; return 0; }
  jq -cr '
    def rows:
      if type == "array" then .[]
      elif type == "object" and (.items | type == "array") then .items[]
      elif type == "object" then .
      else empty end;
    rows
    | {
        source_type: ((.source_type // .type // "external") | tostring),
        title: ((.title // .name // .headline // "Untitled external signal") | tostring),
        url: ((.url // .source_url // .link // "") | tostring),
        date: ((.date // .published_at // .observed_at // .retrieved_at // "") | tostring),
        snippet: ((.snippet // .summary // .body // .text // .description // "") | tostring)
      }
  ' "$file" 2>>"$FETCH_LOG" | while IFS= read -r row; do
    add_evidence \
      "$(printf '%s' "$row" | jq -r .source_type)" \
      "$(printf '%s' "$row" | jq -r .title)" \
      "$(printf '%s' "$row" | jq -r .url)" \
      "$(printf '%s' "$row" | jq -r .date)" \
      "$(printf '%s' "$row" | jq -r .snippet)"
  done
}

fetch_source_url() {
  local url="$1" body title snippet
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl unavailable for $url" >> "$FETCH_LOG"
    return 0
  fi
  body="$(curl -fsSL --max-time 15 "$url" 2>>"$FETCH_LOG" | tr '\n' ' ' | sed -E 's#<[sS][cC][rR][iI][pP][tT][^>]*>[^<]*</[sS][cC][rR][iI][pP][tT]># #g; s#<[sS][tT][yY][lL][eE][^>]*>[^<]*</[sS][tT][yY][lL][eE]># #g; s/<[^>]+>/ /g; s/[[:space:]]+/ /g' | cut -c 1-1200)" || {
    echo "fetch failed: $url" >> "$FETCH_LOG"
    return 0
  }
  title="$(printf '%s' "$body" | cut -c 1-120)"
  snippet="$(printf '%s' "$body" | cut -c 1-600)"
  add_evidence "external-url" "$title" "$url" "$(date -u +%Y-%m-%d)" "$snippet"
}

for file in "${SOURCE_JSON_FILES[@]}"; do load_source_json "$file"; done
for url in "${SOURCE_URLS[@]}"; do fetch_source_url "$url"; done

if [ ! -s "$TMP" ]; then
  fallback_report="${REPORT}.internal"
  if [ -x "$SCRIPT_DIR/demand-discovery.sh" ]; then
    bash "$SCRIPT_DIR/demand-discovery.sh" --project "$PROJECT" --out "$OUT" --report "$fallback_report" >/dev/null 2>&1 || true
  fi
  count=0
  [ -s "$OUT" ] && count="$(wc -l < "$OUT" | tr -d ' ')"
  {
    echo "# Market scout"
    echo
    echo "- external research: unavailable"
    echo "- fallback: internal demand discovery"
    echo "- candidates: $count"
    if [ -s "$FETCH_LOG" ]; then
      echo "- source notes: $(tr '\n' ';' < "$FETCH_LOG" | sed 's/;*$//')"
    else
      echo "- source notes: no external sources configured"
    fi
  } > "$REPORT"
  exit 0
fi

jq -sc '
  group_by(.category)
  | map({
      category: .[0].category,
      evidence_count: length,
      evidence: (map({source_type,title,url,date,snippet}) | .[0:8]),
      source_links: (map(.url) | map(select(. != "")) | unique),
      evidence_dates: (map(.date) | unique),
      snippets: (map(.snippet + " " + .title) | unique | .[0:3])
    })
  | map(. + {
      customer_pain: (if (.category|test("complaint|regulatory")) then 5 elif .evidence_count >= 2 then 4 else 3 end),
      willingness_to_pay: (if (.category|test("pricing|regulatory|estonian")) then 5 else 3 end),
      urgency: (if (.category|test("regulatory|complaint")) then 5 elif (.category|test("pricing")) then 4 else 3 end),
      implementation_complexity: (if (.category|test("regulatory")) then 4 elif (.category|test("competitor")) then 3 else 2 end),
      estonian_small_business_fit: (if ((.snippets | join(" ") | ascii_downcase) | test("estonian|e-resident|micro-o|micro-ou|micro-oü|ou|oü")) then 5 else 3 end),
      confidence: (if .evidence_count >= 3 then "high" elif .evidence_count == 2 then "medium" else "low" end)
    })
  | map(. + {score:(.customer_pain + .willingness_to_pay + .urgency + .estonian_small_business_fit - .implementation_complexity)})
  | sort_by(-.score, .category)
' "$TMP" | jq -c '.[]' | while IFS= read -r row; do
  category="$(printf '%s' "$row" | jq -r .category)"
  text="$(printf '%s' "$row" | jq -r '.snippets | join(" ")')"
  pack_ids="$("$PACKS" --select --category "$category" --text "$text" --json 2>/dev/null | jq -c '[.[].id]' 2>/dev/null || echo '[]')"
  jq -cn --argjson row "$row" --argjson packs "$pack_ids" '
    $row + {
      target_customer_segment:("SaaS customers affected by " + ($row.category | gsub("_"; " "))),
      discovered_need:("Address externally evidenced " + ($row.category | gsub("_"; " "))),
      desired_customer_outcome:"The customer can choose, buy, or complete the workflow with less uncertainty, manual work, or compliance risk.",
      acceptance_packs:$packs,
      acceptance_criteria:[
        "Candidate cites dated external evidence and source links.",
        "Recommendation is generic and does not copy competitor-specific implementation details.",
        "Implementation validates the highest-risk customer workflow before release.",
        "Public artifacts contain no project-specific names, private customer data, or proprietary copied content."
      ],
      non_goals:["Copying competitor-specific features", "Using private customer data", "Changing pricing or legal claims without owner authorization"],
      rollout_checks:["Run project checks", "Record source dates and confidence in the PR", "Document residual market/research risk"]
    }
  ' >> "$OUT"
done

{
  echo "# Market scout"
  echo
  echo "- external research: used"
  echo "- candidates: $(wc -l < "$OUT" | tr -d ' ')"
  echo "- sources: JSON files=${#SOURCE_JSON_FILES[@]}, URLs=${#SOURCE_URLS[@]}"
  echo
  jq -r '"- " + .category + " score=" + (.score|tostring) + " confidence=" + .confidence + " links=" + (.source_links|length|tostring) + " dates=" + (.evidence_dates|join(","))' "$OUT"
} > "$REPORT"

exit 0
