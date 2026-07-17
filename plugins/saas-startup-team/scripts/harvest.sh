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
#   harvest.sh [--in FILE] [--events FILE] [--ledger FILE] [--candidates FILE]
#              [--report FILE] [--project NAME]

set -uo pipefail

IN=""; EVENTS=""; LEDGER=""; CANDIDATES=""; REPORT=""; PROJECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --in)         IN="$2";         shift 2 ;;
    --events)     EVENTS="$2";     shift 2 ;;
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

# Cap evidence refs per candidate so a high-count cluster doesn't dump hundreds of
# refs into the issue body (the occurrence count is reported separately).
MAX_REFS="${SAAS_HARVEST_MAX_REFS:-10}"
MIN_FRICTION_TOKENS="${SAAS_HARVEST_MIN_FRICTION_TOKENS:-20000}"
MIN_FRICTION_RECURRENCE="${SAAS_HARVEST_MIN_FRICTION_RECURRENCE:-3}"
for value in "$MAX_REFS" "$MIN_FRICTION_TOKENS" "$MIN_FRICTION_RECURRENCE"; do
  case "$value" in ''|*[!0-9]*) echo "harvest: thresholds must be non-negative integers" >&2; exit 2 ;; esac
done

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

mkdir -p "$(dirname "$CANDIDATES")" "$(dirname "$REPORT")" "$(dirname "$LEDGER")"
CANDIDATES_TMP="$(mktemp "${CANDIDATES}.tmp.XXXXXX")" || exit 2
REPORT_TMP="$(mktemp "${REPORT}.tmp.XXXXXX")" || { rm -f -- "$CANDIDATES_TMP"; exit 2; }
TERMINALS_TMP=""
cleanup() { rm -f -- "$CANDIDATES_TMP" "$REPORT_TMP" ${TERMINALS_TMP:+"$TERMINALS_TMP"}; }
trap cleanup EXIT

# The event API owns lifecycle validation, root selection, precedence, identity
# normalization, and ordering. Harvest never reads the event file itself.
if [ -n "$EVENTS" ]; then
  TERMINALS_TMP="$(mktemp)" || exit 2
  if ! bash "$_sd/agent-events.sh" terminals --events "$EVENTS" > "$TERMINALS_TMP"; then
    echo "harvest: terminal event projection failed; outputs unchanged" >&2
    exit 3
  fi
fi

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
# marker, a generic tool error, or degenerate near-empty text — is noise, not a
# candidate. Compared on a lowercased alnum-only "core" so spacing/punctuation
# don't matter. The length guard is deliberately small (<4) so it only catches
# degenerate residue, never terse-but-real lessons ("fix ci", "use pnpm").
is_low_signal() {
  local core
  core="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/\[request interrupted by user\]//g' \
    | tr -cd 'a-z0-9')"
  [ -z "$core" ] && return 0
  [ "$core" = "toolresulterror" ] && return 0
  [ "${#core}" -lt 4 ] && return 0
  return 1
}

# Only genuine investor interventions become filed lesson candidates. tool_failure
# is still EXTRACTED (local diagnostics) but is agent/environment friction — browser
# timeouts, model-unavailable, permission denials, read-before-write, user
# rejections — not a generic plugin lesson, so it is never surfaced for filing.
is_filed_signal() {
  case "$1" in
    interrupt|nudge|correction) return 0 ;;
    *) return 1 ;;
  esac
}

# Ledger of already-surfaced/filed fingerprints (object; tolerate missing/corrupt).
LEDGER_JSON="$(cat "$LEDGER" 2>/dev/null || true)"
printf '%s' "$LEDGER_JSON" | jq -e 'type=="object"' >/dev/null 2>&1 || LEDGER_JSON='{}'

declare -A CNT SUM SIG CONF REFS PII
declare -A FR_COMMAND FR_OUTCOME FR_REASON FR_HIGH FR_COSTLY FR_NULL_TOKENS FR_TOKEN_SUM FR_TOKEN_COUNT
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

has_successful_artifact() {
  case "$1" in open|merged) return 0 ;; esac
  case "$2" in merged|success) return 0 ;; esac
  [ "$3" = success ]
}

if [ -n "$TERMINALS_TMP" ]; then
  while IFS= read -r event || [ -n "$event" ]; do
    [ -n "$event" ] || continue
    if ! printf '%s\n' "$event" | jq -e '
      type == "object" and
      (.run_id | type == "string" and test("^run-[0-9a-f]{32}$")) and
      .parent_run_id == null and .phase == "pass-outcome" and
      (.command | type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and
      (.outcome | type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and
      (.terminal_reason == null or
        (.terminal_reason | type == "string" and
          (. == "" or test("^[a-z0-9][a-z0-9_]*$")))) and
      (.total_tokens == null or
        (.total_tokens | type == "number" and . >= 0 and floor == .)) and
      (.pr == null or (.pr | type == "string")) and
      (.merge == null or (.merge | type == "string")) and
      (.deployment == null or (.deployment | type == "string"))
    ' >/dev/null; then
      echo "harvest: terminal event projection returned invalid data; outputs unchanged" >&2
      exit 3
    fi

    run_ref="$(printf '%s\n' "$event" | jq -r '.run_id')"
    command="$(printf '%s\n' "$event" | jq -r '.command')"
    outcome="$(printf '%s\n' "$event" | jq -r '.outcome')"
    reason="$(printf '%s\n' "$event" | jq -r '.terminal_reason // empty')"
    tokens="$(printf '%s\n' "$event" | jq -r '.total_tokens // empty')"
    pr="$(printf '%s\n' "$event" | jq -r '.pr // empty')"
    merge="$(printf '%s\n' "$event" | jq -r '.merge // empty')"
    deployment="$(printf '%s\n' "$event" | jq -r '.deployment // empty')"
    reason_key="${reason:-none}"
    fp="workflow_friction:$(printf '%s\t%s\t%s' "$command" "$outcome" "$reason_key" | sha1sum | cut -c1-12)"
    safe_ref="workflow-event:$run_ref"

    CNT[$fp]=$(( ${CNT[$fp]:-0} + 1 ))
    SIG[$fp]="workflow_friction"
    FR_COMMAND[$fp]="$command"; FR_OUTCOME[$fp]="$outcome"; FR_REASON[$fp]="$reason_key"
    REFS[$fp]="${REFS[$fp]:-}${safe_ref}"$'\n'
    if [ -n "$tokens" ]; then
      FR_TOKEN_SUM[$fp]=$(( ${FR_TOKEN_SUM[$fp]:-0} + tokens ))
      FR_TOKEN_COUNT[$fp]=$(( ${FR_TOKEN_COUNT[$fp]:-0} + 1 ))
    elif [ -n "$reason" ] && [ "$reason" != other ]; then
      FR_NULL_TOKENS[$fp]=$(( ${FR_NULL_TOKENS[$fp]:-0} + 1 ))
    fi
    case "$reason" in
      false_success|context_binding_violation|invalid_workflow_state|lease_conflict|receipt_conflict)
        FR_HIGH[$fp]=1
        ;;
    esac
    case "$outcome" in
      success|no-op|skipped) ;;
      *)
        if [ -n "$tokens" ] && [ "$tokens" -ge "$MIN_FRICTION_TOKENS" ] \
          && ! has_successful_artifact "$pr" "$merge" "$deployment"; then
          FR_COSTLY[$fp]=1
        fi
        ;;
    esac
    if pii_hit "$command" || pii_hit "$outcome" || pii_hit "$reason" || pii_hit "$safe_ref"; then
      PII[$fp]=1
    fi
  done < "$TERMINALS_TMP"
fi

SURFACED=0; BELOW=0; BLOCKED=0; DEDUP=0; LOWSIG=0; NONINTERVENTION=0
# Iterate fingerprints in sorted order so candidate output is deterministic.
while IFS= read -r fp; do
  [ -n "$fp" ] || continue
  sig="${SIG[$fp]}"; count="${CNT[$fp]}"
  if [ "$sig" = workflow_friction ]; then
    if [ -z "${FR_HIGH[$fp]:-}" ] && [ -z "${FR_COSTLY[$fp]:-}" ] \
      && { [ "${FR_NULL_TOKENS[$fp]:-0}" -eq 0 ] \
        || [ "${FR_NULL_TOKENS[$fp]:-0}" -lt "$MIN_FRICTION_RECURRENCE" ]; }; then
      if [ "${FR_NULL_TOKENS[$fp]:-0}" -gt 0 ]; then BELOW=$((BELOW + 1))
      else NONINTERVENTION=$((NONINTERVENTION + 1)); fi
      continue
    fi
  else
    thr="$(thr_for "$sig")"
    if ! is_filed_signal "$sig"; then NONINTERVENTION=$((NONINTERVENTION + 1)); continue; fi
  fi
  if printf '%s' "$LEDGER_JSON" | jq -e --arg fp "$fp" 'has($fp)' >/dev/null 2>&1; then
    DEDUP=$((DEDUP + 1)); continue
  fi
  if [ -n "${PII[$fp]:-}" ]; then BLOCKED=$((BLOCKED + 1)); continue; fi
  if [ "$sig" != workflow_friction ]; then
    if [ "$count" -lt "$thr" ]; then BELOW=$((BELOW + 1)); continue; fi
    if is_low_signal "${SUM[$fp]}"; then LOWSIG=$((LOWSIG + 1)); continue; fi
  else
    known_count="${FR_TOKEN_COUNT[$fp]:-0}"
    if [ "$known_count" -gt 0 ]; then
      token_summary="known total tokens ${FR_TOKEN_SUM[$fp]} across $known_count occurrences"
    else
      token_summary="total tokens unavailable"
    fi
    SUM[$fp]="Workflow friction for command ${FR_COMMAND[$fp]}: outcome ${FR_OUTCOME[$fp]}, terminal reason ${FR_REASON[$fp]}; occurrences $count; $token_summary."
    CONF[$fp]="medium"
    if [ -n "${FR_HIGH[$fp]:-}" ] || [ -n "${FR_COSTLY[$fp]:-}" ]; then CONF[$fp]="high"; fi
  fi

  # build evidence_refs as a JSON array — quoted to avoid word-split/glob; deduped+sorted+capped.
  refs_json="$(printf '%s' "${REFS[$fp]}" | jq -R . | jq -cs --argjson n "$MAX_REFS" 'map(select(length>0)) | unique | .[0:$n]')"
  recommendation=""
  if [ "$sig" = workflow_friction ]; then
    recommendation="Review the normalized ${FR_COMMAND[$fp]} workflow path for outcome ${FR_OUTCOME[$fp]} and terminal reason ${FR_REASON[$fp]}; strengthen deterministic state validation and completion evidence."
  fi
  jq -cn \
    --arg fp "$fp" --arg sig "$sig" --argjson count "$count" \
    --arg conf "${CONF[$fp]}" --arg sum "${SUM[$fp]}" --arg rec "$recommendation" --argjson refs "$refs_json" \
    '{fingerprint:$fp, signal_type:$sig, count:$count, confidence:$conf,
      deidentified_summary:$sum, evidence_refs:$refs,
      observation:$sum, hypothesis:null,
      recommendation:(if $rec == "" then null else $rec end)}' \
    >> "$CANDIDATES_TMP" || { echo "harvest: could not stage candidates" >&2; exit 2; }
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
  echo "- skipped (non-intervention signal): $NONINTERVENTION"
  echo "- blocked (PII/secret detected): $BLOCKED"
  echo "- deduped (already in ledger): $DEDUP"
  echo
  if [ -n "$EVENTS" ]; then echo "- terminal events: projected authoritative roots"; fi
  echo "Candidates: \`$CANDIDATES\` — review before any filing (filing is a separate, opt-in stage)."
} > "$REPORT_TMP" || { echo "harvest: could not stage report" >&2; exit 2; }

# Each output is replaced by a same-directory rename only after every source has
# validated and both complete replacements have been staged.
mv -f -- "$CANDIDATES_TMP" "$CANDIDATES" || exit 2
CANDIDATES_TMP=""
mv -f -- "$REPORT_TMP" "$REPORT" || exit 2
REPORT_TMP=""

exit 0
