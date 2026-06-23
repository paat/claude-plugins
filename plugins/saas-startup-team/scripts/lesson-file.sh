#!/usr/bin/env bash
#
# lesson-file.sh — gated public filing of harvested candidates (self-improvement v3).
#
# Reads harvester candidates and files each as a `lesson-candidate` GitHub issue in
# the PINNED plugin repo — but ONLY when filing is explicitly enabled. By default it
# is a dry run (prints what it would file, touches nothing). This is the first stage
# that writes to a public repo, so it is heavily gated:
#
#   - Files only when  SAAS_LESSON_SYNC_ENABLED=true  AND a repo is explicitly pinned
#     (--repo or $SAAS_PLUGIN_REPO). Anything else stays dry-run.
#   - Re-runs the HARD PII/secrets gate on every issue title+body at the filing
#     boundary (defense-in-depth; the candidate was already gated upstream).
#   - Idempotent: a fingerprint already in the ledger is never re-filed.
#   - Advisory dedup: skips when an open issue with the same title already exists.
#   - Per-run budget cap.
#
# See docs/design/self-improvement-loop.md.
#
# Usage:
#   lesson-file.sh [--candidates FILE] [--ledger FILE] [--repo OWNER/REPO]
#                  [--report FILE] [--max-issues N]

set -uo pipefail

CANDIDATES=""; LEDGER=""; REPO=""; REPORT=""
MAX_ISSUES="${SAAS_LESSON_MAX_ISSUES:-10}"

while [ $# -gt 0 ]; do
  case "$1" in
    --candidates) CANDIDATES="$2"; shift 2 ;;
    --ledger)     LEDGER="$2";     shift 2 ;;
    --repo)       REPO="$2";       shift 2 ;;
    --report)     REPORT="$2";     shift 2 ;;
    --max-issues) MAX_ISSUES="$2"; shift 2 ;;
    *) echo "lesson-file: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$CANDIDATES" ] || CANDIDATES=".startup/insights/candidates.jsonl"
[ -n "$LEDGER" ]     || LEDGER=".startup/insights/harvest-ledger.json"
[ -n "$REPORT" ]     || REPORT=".startup/insights/filing-report.md"
[ -n "$REPO" ]       || REPO="${SAAS_PLUGIN_REPO:-}"

mkdir -p "$(dirname "$LEDGER")" "$(dirname "$REPORT")"

# Validate the budget up front so a bad value can't silently disable it.
case "$MAX_ISSUES" in ''|*[!0-9]*) echo "lesson-file: --max-issues must be a non-negative integer" >&2; exit 2 ;; esac

# Source the shared PII gate FATALLY — if it is missing/unsourceable, refuse to run
# (never file without the gate). Resolve via BASH_SOURCE so cwd/PATH invocation can't break it.
_sd="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 2
# shellcheck source=pii-gate.sh
. "$_sd/pii-gate.sh" || exit 2
command -v pii_hit >/dev/null 2>&1 || { echo "lesson-file: PII gate unavailable; refusing to run" >&2; exit 2; }

# Filing is opt-in: requires the explicit enable flag AND a pinned repo.
ENABLED=0; [ "${SAAS_LESSON_SYNC_ENABLED:-}" = "true" ] && ENABLED=1
if [ "$ENABLED" -eq 1 ] && [ -z "$REPO" ]; then
  echo "lesson-file: SAAS_LESSON_SYNC_ENABLED=true but no repo pinned (--repo or SAAS_PLUGIN_REPO). Refusing to file." >&2
  exit 2
fi
MODE="dry-run"; [ "$ENABLED" -eq 1 ] && MODE="file"

LEDGER_JSON="$(cat "$LEDGER" 2>/dev/null || true)"
printf '%s' "$LEDGER_JSON" | jq -e 'type=="object"' >/dev/null 2>&1 || LEDGER_JSON='{}'

FILED=0; WOULD=0; BLOCKED=0; DEDUP_LEDGER=0; DEDUP_SEARCH=0; BUDGET_SKIP=0; FAILED=0; MALFORMED=0

if [ -f "$CANDIDATES" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    obj="$(printf '%s' "$line" | jq -c . 2>/dev/null)" || { MALFORMED=$((MALFORMED + 1)); continue; }
    [ -n "$obj" ] || { MALFORMED=$((MALFORMED + 1)); continue; }
    fp="$(printf '%s' "$obj" | jq -r '.fingerprint // ""')"
    [ -n "$fp" ] && [ "$fp" != "null" ] || continue

    # already filed?
    if printf '%s' "$LEDGER_JSON" | jq -e --arg fp "$fp" 'has($fp)' >/dev/null 2>&1; then
      DEDUP_LEDGER=$((DEDUP_LEDGER + 1)); continue
    fi

    title="$(printf '%s' "$obj" | jq -r '.title // ("lesson: " + (.signal_type // "?") + " — " + ((.observation // "")[0:70]))')"
    domain="$(printf '%s' "$obj" | jq -r '.domain // ""')"
    obs="$(printf '%s' "$obj" | jq -r '.observation // ""')"
    rec="$(printf '%s' "$obj" | jq -r '.recommendation // "(needs human drafting)"')"
    count="$(printf '%s' "$obj" | jq -r '.count // 1')"
    refs="$(printf '%s' "$obj" | jq -r '(.evidence_refs // []) | join(", ")')"
    labels="lesson-candidate"; [ -n "$domain" ] && [ "$domain" != "null" ] && labels="lesson-candidate,$domain"
    body="$(printf '## Observation\n%s\n\n## Recommendation\n%s\n\n## Evidence\n- occurrences: %s\n- refs: %s\n\n---\nFiled by the saas-startup-team self-improvement harvester as a candidate (de-identified + PII-gated). Review before implementing; close if not generic.\n' "$obs" "$rec" "$count" "$refs")"

    # PII re-gate at the filing boundary (defense-in-depth)
    if pii_hit "$title" || pii_hit "$body"; then BLOCKED=$((BLOCKED + 1)); continue; fi

    if [ "$MODE" = "dry-run" ]; then WOULD=$((WOULD + 1)); continue; fi

    # FILE mode
    if [ "$FILED" -ge "$MAX_ISSUES" ]; then BUDGET_SKIP=$((BUDGET_SKIP + 1)); continue; fi

    # advisory dedup against existing open issues — FAIL CLOSED on search error
    # (a failed search must not let us open a duplicate public issue).
    if existing="$(gh issue list --repo "$REPO" --search "$title in:title" --state open --json number,title 2>/dev/null)"; then
      cnt="$(printf '%s' "$existing" | jq 'length' 2>/dev/null || echo 0)"
    else
      cnt="fail"
    fi
    if [ "$cnt" = "fail" ] || [ "${cnt:-0}" -gt 0 ]; then DEDUP_SEARCH=$((DEDUP_SEARCH + 1)); continue; fi

    url="$(gh issue create --repo "$REPO" --title "$title" --body "$body" --label "$labels" 2>/dev/null)" || { FAILED=$((FAILED + 1)); continue; }
    LEDGER_JSON="$(printf '%s' "$LEDGER_JSON" | jq -c --arg fp "$fp" --arg u "$url" '.[$fp] = {issue: $u}')"
    # Persist the ledger immediately so a crash after this create can't cause a re-file.
    printf '%s\n' "$LEDGER_JSON" > "${LEDGER}.tmp" && mv -f "${LEDGER}.tmp" "$LEDGER"
    FILED=$((FILED + 1))
  done < "$CANDIDATES"
fi

printf '%s\n' "$LEDGER_JSON" > "${LEDGER}.tmp" && mv -f "${LEDGER}.tmp" "$LEDGER"

{
  echo "# Lesson filing — $MODE"
  echo
  if [ "$MODE" = "dry-run" ]; then
    echo "_Dry run: nothing was filed. To file, set \`SAAS_LESSON_SYNC_ENABLED=true\` and pin a repo._"
  else
    echo "Filed to: \`$REPO\`"
  fi
  echo
  echo "- filed: $FILED"
  echo "- would file (dry-run): $WOULD"
  echo "- blocked (PII at filing boundary): $BLOCKED"
  echo "- skipped (already in ledger): $DEDUP_LEDGER"
  echo "- skipped (existing open issue): $DEDUP_SEARCH"
  echo "- skipped (budget $MAX_ISSUES reached): $BUDGET_SKIP"
  echo "- create failures: $FAILED"
  echo "- malformed candidates skipped: $MALFORMED"
} > "$REPORT"

exit 0
