#!/usr/bin/env bash
#
# lesson-file.sh — gated public filing of harvested candidates (self-improvement v3).
#
# Reads harvester candidates and files each as a `lesson-candidate` GitHub issue in
# the PINNED plugin repo — but ONLY when filing is explicitly enabled. By default it
# is a dry run: it makes no GitHub calls or mutations, but still refreshes the local
# fingerprint ledger and filing report. This is the first stage that writes to a
# public repo, so it is heavily gated:
#
#   - Files only when  SAAS_LESSON_SYNC_ENABLED=true  AND a repo is explicitly pinned
#     (--repo or $SAAS_PLUGIN_REPO). Anything else stays dry-run.
#   - Re-runs the HARD PII/secrets gate on every issue title+body at the filing
#     boundary (defense-in-depth; the candidate was already gated upstream).
#   - Idempotent: a fingerprint already in the ledger is never re-filed. A stable,
#     privacy-safe marker reconciles create-before-ledger crashes across all issue states.
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

command -v sha256sum >/dev/null 2>&1 || { echo "lesson-file: sha256sum is required" >&2; exit 2; }

persist_ledger() {
  local tmp
  tmp="$(mktemp "$(dirname "$LEDGER")/.lesson-ledger.XXXXXX")" || return 1
  if ! printf '%s\n' "$LEDGER_JSON" > "$tmp" \
     || ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1 \
     || ! mv -f -- "$tmp" "$LEDGER"; then
    rm -f -- "$tmp"
    return 1
  fi
}

record_fingerprint() {
  local fp="$1" url="$2" next
  next="$(printf '%s' "$LEDGER_JSON" | jq -c \
    --arg fp "$fp" --arg u "$url" '.[$fp] = {issue: $u}')" || return 1
  LEDGER_JSON="$next"
  persist_ledger
}

FILED=0; WOULD=0; BLOCKED=0; DEDUP_LEDGER=0; DEDUP_SEARCH=0
BUDGET_SKIP=0; FAILED=0; MALFORMED=0; PERSIST_FATAL=0

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
    marker_digest="$(printf '%s' "$fp" | sha256sum | awk '{print $1}')" || {
      FAILED=$((FAILED + 1)); continue
    }
    marker="<!-- saas-lesson-fingerprint:v1:$marker_digest -->"
    body="$(printf '## Observation\n%s\n\n## Recommendation\n%s\n\n## Evidence\n- occurrences: %s\n- refs: %s\n\n---\nFiled by the saas-startup-team self-improvement harvester as a candidate (de-identified + PII-gated). Review before implementing; close if not generic.\n\n%s\n' "$obs" "$rec" "$count" "$refs" "$marker")"

    # PII re-gate at the filing boundary (defense-in-depth)
    if pii_hit "$title" || pii_hit "$body"; then BLOCKED=$((BLOCKED + 1)); continue; fi

    if [ "$MODE" = "dry-run" ]; then WOULD=$((WOULD + 1)); continue; fi

    # FILE mode
    if [ "$FILED" -ge "$MAX_ISSUES" ]; then BUDGET_SKIP=$((BUDGET_SKIP + 1)); continue; fi

    # Authoritative crash reconciliation: the marker survives even when creation
    # completed but the local ledger write did not. Closed issues count too.
    if ! marked="$(gh issue list --repo "$REPO" --search "$marker_digest in:body" \
      --state all --limit 100 --json number,url,body,state 2>/dev/null)"; then
      FAILED=$((FAILED + 1)); continue
    fi
    if ! marked_url="$(printf '%s' "$marked" | jq -er --arg marker "$marker" '
      if type != "array" then error("marker result is not an array")
      else map(select((.body | type == "string") and (.body | contains($marker))))
        | sort_by(.number) | if length == 0 then "" else .[0].url end
      end
    ' 2>/dev/null)"; then
      FAILED=$((FAILED + 1)); continue
    fi
    if [ -n "$marked_url" ]; then
      if ! record_fingerprint "$fp" "$marked_url"; then
        FAILED=$((FAILED + 1)); PERSIST_FATAL=1
        break
      fi
      DEDUP_LEDGER=$((DEDUP_LEDGER + 1))
      continue
    fi

    # advisory dedup against existing open issues — FAIL CLOSED on search error
    # (a failed search must not let us open a duplicate public issue).
    if ! existing="$(gh issue list --repo "$REPO" --search "$title in:title" --state open --json number,title 2>/dev/null)"; then
      FAILED=$((FAILED + 1)); continue
    fi
    if ! cnt="$(printf '%s' "$existing" | jq -er \
      'if type == "array" then length else error("dedup result is not an array") end' 2>/dev/null)"; then
      FAILED=$((FAILED + 1)); continue
    fi
    if [ "$cnt" -gt 0 ]; then DEDUP_SEARCH=$((DEDUP_SEARCH + 1)); continue; fi

    url="$(gh issue create --repo "$REPO" --title "$title" --body "$body" --label "$labels" 2>/dev/null)" || { FAILED=$((FAILED + 1)); continue; }
    FILED=$((FILED + 1))
    # Persist the ledger immediately so a crash after this create can't cause a re-file.
    if ! record_fingerprint "$fp" "$url"; then
      FAILED=$((FAILED + 1)); PERSIST_FATAL=1
      break
    fi
  done < "$CANDIDATES"
fi

if [ "$PERSIST_FATAL" -eq 0 ] && ! persist_ledger; then
  FAILED=$((FAILED + 1))
fi

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
  echo "- filing failures (search/parse/create): $FAILED"
  echo "- malformed candidates skipped: $MALFORMED"
} > "$REPORT"

[ "$FAILED" -eq 0 ] || exit 1
exit 0
