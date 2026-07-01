#!/usr/bin/env bash
#
# acceptance-packs.sh - reusable market-demand quality gates for autonomous SaaS work.
#
# Usage:
#   acceptance-packs.sh --list [--json]
#   acceptance-packs.sh --select --category NAME --text TEXT [--json]
#   acceptance-packs.sh --render PACK_ID[,PACK_ID...]
#   acceptance-packs.sh --verify-report FILE

set -uo pipefail

ACTION="list"; JSON=0; CATEGORY=""; TEXT=""; PACKS=""; FILE=""

_need_val() { [ "$1" -ge 2 ] || { echo "acceptance-packs: $2 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --list) ACTION="list"; shift ;;
    --select) ACTION="select"; shift ;;
    --render) _need_val "$#" "$1"; ACTION="render"; PACKS="$2"; shift 2 ;;
    --verify-report) _need_val "$#" "$1"; ACTION="verify-report"; FILE="$2"; shift 2 ;;
    --category) _need_val "$#" "$1"; CATEGORY="$2"; shift 2 ;;
    --text) _need_val "$#" "$1"; TEXT="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    *) echo "acceptance-packs: unknown arg: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 2
PACK_FILE="$SCRIPT_DIR/../templates/acceptance-packs.json"

[ -f "$PACK_FILE" ] || { echo "acceptance-packs: missing $PACK_FILE" >&2; exit 1; }
jq -e '.packs | type=="array"' "$PACK_FILE" >/dev/null 2>&1 || {
  echo "acceptance-packs: invalid pack file" >&2; exit 1; }

select_packs() {
  local hay
  hay="$(printf '%s %s' "$CATEGORY" "$TEXT" | tr '[:upper:]' '[:lower:]')"
  jq -c --arg hay "$hay" '
    .packs
    | map(select(any(.triggers[]; ascii_downcase as $trigger | ($hay | contains($trigger)))))
    | if length == 0 then
        [(.[] | select(.id=="report_output_product"))]
      else . end
    | unique_by(.id)
  ' "$PACK_FILE"
}

case "$ACTION" in
  list)
    if [ "$JSON" -eq 1 ]; then jq '.packs' "$PACK_FILE"; exit 0; fi
    jq -r '.packs[] | "- \(.id): \(.title)"' "$PACK_FILE"
    exit 0
    ;;

  select)
    selected="$(select_packs)" || { echo "acceptance-packs: selection failed" >&2; exit 1; }
    if [ "$JSON" -eq 1 ]; then printf '%s\n' "$selected" | jq '.'; exit 0; fi
    printf '%s\n' "$selected" | jq -r '.[] | "- \(.id): \(.title)"'
    exit 0
    ;;

  render)
    [ -n "$PACKS" ] || { echo "acceptance-packs: --render needs pack ids" >&2; exit 2; }
    ids_json="$(printf '%s' "$PACKS" | tr ',' '\n' | jq -R . | jq -cs 'map(select(length>0))')"
    jq -r --argjson ids "$ids_json" '
      .packs
      | map(select(.id as $id | $ids | index($id)))
      | .[]
      | "## \(.title)\n\nGates:\n" + (.gates | map("- " + .) | join("\n"))
        + "\n\nVerification:\n" + (.verification | map("- " + .) | join("\n")) + "\n"
    ' "$PACK_FILE"
    exit 0
    ;;

  verify-report)
    [ -f "$FILE" ] || { echo "acceptance-packs: report not found: $FILE" >&2; exit 2; }
    body="$(cat "$FILE")"
    failures=0
    if printf '%s' "$body" | grep -Eiq '\b(undefined|null|nan|\[object object\])\b' \
      || printf '%s' "$body" | grep -Eq '[A-Z0-9]+_[A-Z0-9_]+\b'; then
      echo "acceptance-packs: FAIL report contains raw/internal value" >&2; failures=$((failures + 1))
    fi
    if ! printf '%s' "$body" | grep -Eiq 'https?://|\[[^]]+\]\([^)]+\)'; then
      echo "acceptance-packs: FAIL report has no citation/link" >&2; failures=$((failures + 1))
    fi
    if ! printf '%s' "$body" | grep -Eiq 'remedy|next step|how to fix|recommendation|fix:'; then
      echo "acceptance-packs: FAIL report has no remedy or next step" >&2; failures=$((failures + 1))
    fi
    if printf '%s' "$body" | grep -Eiq '\b(enum|stack trace|implementation detail|database column)\b'; then
      echo "acceptance-packs: FAIL report exposes implementation language" >&2; failures=$((failures + 1))
    fi
    [ "$failures" -eq 0 ] || exit 1
    echo "acceptance-packs: report-quality gate passed."
    exit 0
    ;;

  *)
    echo "acceptance-packs: unknown action: $ACTION" >&2; exit 2 ;;
esac
