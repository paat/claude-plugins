#!/usr/bin/env bash
#
# harvest.sh — dry-run candidate generator for the self-improvement loop (v2).
#
# Reads local session-insights records, clusters recurring signals, de-identifies
# them, runs a HARD PII/secrets gate, dedups against a fingerprint ledger, and
# writes candidate plugin-improvement drafts + a report. It is the deterministic
# SAFETY layer: it does NOT decide genericity/phrasing (that is the /harvest
# agent + the human review gate), and it does NOT file anything or touch the
# network. See docs/design/self-improvement-loop.md.
#
# Output candidates are *dry-run only* — review precedes any filing, which is a
# separate, later, opt-in stage.
#
# Usage:
#   harvest.sh [--in FILE] [--ledger FILE] [--candidates FILE] [--report FILE]
#              [--project NAME]

set -uo pipefail

IN=""; LEDGER=""; CANDIDATES=""; REPORT=""; PROJECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --in)         IN="$2";         shift 2 ;;
    --ledger)     LEDGER="$2";     shift 2 ;;
    --candidates) CANDIDATES="$2"; shift 2 ;;
    --report)     REPORT="$2";     shift 2 ;;
    --project)    PROJECT="$2";    shift 2 ;;
    *) echo "harvest: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PROJECT" ]    || PROJECT="$(basename "$PWD")"
[ -n "$IN" ]         || IN=".startup/insights/records.jsonl"
[ -n "$LEDGER" ]     || LEDGER=".startup/insights/harvest-ledger.json"
[ -n "$CANDIDATES" ] || CANDIDATES=".startup/insights/candidates.jsonl"
[ -n "$REPORT" ]     || REPORT=".startup/insights/harvest-report.md"

mkdir -p "$(dirname "$CANDIDATES")" "$(dirname "$REPORT")" "$(dirname "$LEDGER")"
: > "$CANDIDATES"   # regenerated each run

# Cap evidence refs per candidate so a high-count cluster doesn't dump hundreds of
# refs into the issue body (the occurrence count is reported separately).
MAX_REFS="${SAAS_HARVEST_MAX_REFS:-10}"

# Recurrence thresholds per signal (env-overridable). High-confidence signals
# surface from a single occurrence; noisier ones must recur.
thr_for() {
  case "$1" in
    interrupt)    echo "${SAAS_HARVEST_MIN_INTERRUPT:-1}" ;;
    nudge)        echo "${SAAS_HARVEST_MIN_NUDGE:-1}" ;;
    correction)   echo "${SAAS_HARVEST_MIN_CORRECTION:-2}" ;;
    tool_failure) echo "${SAAS_HARVEST_MIN_TOOLFAIL:-3}" ;;
    *)            echo 2 ;;
  esac
}

# HARD PII/secrets gate — shared single source of truth (see pii-gate.sh). Sourced
# FATALLY: if the gate is missing/unsourceable, refuse to run rather than emit
# ungated candidates. Resolve via BASH_SOURCE so cwd invocation can't break it.
_sd="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 2
# shellcheck source=pii-gate.sh
. "$_sd/pii-gate.sh" || exit 2
command -v pii_hit >/dev/null 2>&1 || { echo "harvest: PII gate unavailable; refusing to run" >&2; exit 2; }

# De-identify: replace literal project-name occurrences with a template var.
pj_esc="$(printf '%s' "$PROJECT" | sed 's/[][\.*^$/]/\\&/g')"
deidentify() {
  local s="$1"
  if [ -n "$pj_esc" ]; then
    s="$(printf '%s' "$s" | sed "s/${pj_esc}/{{PROJECT}}/Ig")"
  fi
  # Strip project-specific issue references (e.g. #864) — never generic. Evidence
  # refs like "file.jsonl#L42" keep their letter-prefixed line marker (not matched).
  printf '%s' "$s" | sed -E 's/#[0-9]+/#N/g'
}
normalize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }

# Low-signal floor: a cluster whose summary carries no lesson — the bare interrupt
# marker, a generic tool error, or near-empty text — is noise, not a candidate.
# Compared on a lowercased alnum-only "core" so spacing/punctuation don't matter.
is_low_signal() {
  local core
  core="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/\[request interrupted by user\]//g' \
    | tr -cd 'a-z0-9')"
  [ -z "$core" ] && return 0
  [ "$core" = "toolresulterror" ] && return 0
  [ "${#core}" -lt 8 ] && return 0
  return 1
}

# Ledger of already-surfaced/filed fingerprints (object; tolerate missing/corrupt).
LEDGER_JSON="$(cat "$LEDGER" 2>/dev/null || true)"
printf '%s' "$LEDGER_JSON" | jq -e 'type=="object"' >/dev/null 2>&1 || LEDGER_JSON='{}'

declare -A CNT SUM SIG CONF REFS PII
MALFORMED=0

if [ -f "$IN" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    obj="$(printf '%s' "$line" | jq -c . 2>/dev/null)" || { MALFORMED=$((MALFORMED + 1)); continue; }
    [ -n "$obj" ] || { MALFORMED=$((MALFORMED + 1)); continue; }
    sig="$(printf '%s' "$obj" | jq -r '.signal_type // ""')"
    [ -n "$sig" ] && [ "$sig" != "null" ] || continue
    summ="$(printf '%s' "$obj" | jq -r '.sanitized_summary // ""')"
    ref="$(printf '%s' "$obj" | jq -r '.local_evidence_ref // ""')"
    conf="$(printf '%s' "$obj" | jq -r '.confidence // "medium"')"

    deid="$(deidentify "$summ")"
    norm="$(normalize "$deid")"
    fp="${sig}:$(printf '%s' "$norm" | sha1sum | cut -c1-12)"

    # Refs are evidence too: strip the absolute path, de-identify, and PII-gate them.
    safe_ref=""
    [ -n "$ref" ] && safe_ref="$(deidentify "$(basename -- "$ref")")"

    CNT[$fp]=$(( ${CNT[$fp]:-0} + 1 ))
    SIG[$fp]="$sig"; CONF[$fp]="$conf"
    [ -n "${SUM[$fp]:-}" ] || SUM[$fp]="$deid"
    REFS[$fp]="${REFS[$fp]:-}${safe_ref}"$'\n'
    if pii_hit "$summ" || pii_hit "$ref" || pii_hit "$safe_ref"; then PII[$fp]=1; fi
  done < "$IN"
fi

SURFACED=0; BELOW=0; BLOCKED=0; DEDUP=0; LOWSIG=0
# Iterate fingerprints in sorted order so candidate output is deterministic.
while IFS= read -r fp; do
  [ -n "$fp" ] || continue
  sig="${SIG[$fp]}"; count="${CNT[$fp]}"; thr="$(thr_for "$sig")"
  if printf '%s' "$LEDGER_JSON" | jq -e --arg fp "$fp" 'has($fp)' >/dev/null 2>&1; then
    DEDUP=$((DEDUP + 1)); continue
  fi
  if [ -n "${PII[$fp]:-}" ]; then BLOCKED=$((BLOCKED + 1)); continue; fi
  if [ "$count" -lt "$thr" ]; then BELOW=$((BELOW + 1)); continue; fi
  if is_low_signal "${SUM[$fp]}"; then LOWSIG=$((LOWSIG + 1)); continue; fi

  # build evidence_refs as a JSON array — quoted to avoid word-split/glob; deduped+sorted+capped.
  refs_json="$(printf '%s' "${REFS[$fp]}" | jq -R . | jq -cs --argjson n "$MAX_REFS" 'map(select(length>0)) | unique | .[0:$n]')"
  jq -cn \
    --arg fp "$fp" --arg sig "$sig" --argjson count "$count" \
    --arg conf "${CONF[$fp]}" --arg sum "${SUM[$fp]}" --argjson refs "$refs_json" \
    '{fingerprint:$fp, signal_type:$sig, count:$count, confidence:$conf,
      deidentified_summary:$sum, evidence_refs:$refs,
      observation:$sum, hypothesis:null, recommendation:null}' \
    >> "$CANDIDATES"
  SURFACED=$((SURFACED + 1))
done < <(printf '%s\n' "${!CNT[@]}" | sort)

{
  echo "# Harvest — candidate plugin improvements (DRY RUN)"
  echo
  echo "_Local only. Nothing filed. These are candidates for human review; genericity"
  echo "and phrasing are decided at review, not here._"
  echo
  echo "- project: \`$PROJECT\`"
  echo "- input: \`$IN\`"
  echo "- malformed records skipped: $MALFORMED"
  echo
  echo "## Disposition"
  echo "- surfaced (written to candidates): $SURFACED"
  echo "- below recurrence threshold: $BELOW"
  echo "- low-signal (no actionable content): $LOWSIG"
  echo "- blocked (PII/secret detected): $BLOCKED"
  echo "- deduped (already in ledger): $DEDUP"
  echo
  echo "Candidates: \`$CANDIDATES\` — review before any filing (filing is a separate, opt-in stage)."
} > "$REPORT"

exit 0
