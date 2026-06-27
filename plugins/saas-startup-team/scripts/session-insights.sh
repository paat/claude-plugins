#!/usr/bin/env bash
#
# session-insights.sh — local-only intervention extractor (self-improvement loop v1).
#
# Scans Claude Code session transcripts (*.jsonl) for high-confidence investor
# interventions and agent friction, and emits typed JSONL records to a LOCAL file.
# It NEVER touches the network and NEVER files issues — that is a later, gated
# stage. See docs/design/self-improvement-loop.md.
#
# Design points (per two codex reviews + real-log precision testing):
#  - Parse JSON first, then inspect normalized fields (never grep raw lines as records).
#  - User text may be a plain string OR an array of {type:text} blocks — handle both.
#  - Exclude harness-injected command-output wrappers (<local-command-caveat> etc.);
#    they are not investor turns.
#  - Watermark by file + BYTE OFFSET; only advance past COMPLETE (newline-terminated)
#    lines so a mid-write partial line is picked up once finished — never half-processed.
#  - Tolerate malformed lines (skip + count); never abort the scan.
#
# Usage:
#   session-insights.sh [--logs-dir DIR] [--state FILE] [--out FILE] [--report FILE]
#                       [--project NAME] [--max-records N]

set -uo pipefail

LOGS_DIR=""; STATE=""; OUT=""; REPORT=""; PROJECT=""
MAX_RECORDS="${SAAS_INSIGHTS_MAX_RECORDS:-1000}"

while [ $# -gt 0 ]; do
  case "$1" in
    --logs-dir) LOGS_DIR="$2"; shift 2 ;;
    --state)    STATE="$2";    shift 2 ;;
    --out)      OUT="$2";      shift 2 ;;
    --report)   REPORT="$2";   shift 2 ;;
    --project)  PROJECT="$2";  shift 2 ;;
    --max-records) MAX_RECORDS="$2"; shift 2 ;;
    *) echo "session-insights: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PROJECT" ] || PROJECT="$(basename "$PWD")"
if [ -z "$LOGS_DIR" ]; then
  esc="$(printf '%s' "$PWD" | sed 's/[/.]/-/g')"
  LOGS_DIR="${HOME}/.claude/projects/${esc}"
fi
[ -n "$STATE" ]  || STATE=".startup/insights/watermark.json"
[ -n "$OUT" ]    || OUT=".startup/insights/records.jsonl"
[ -n "$REPORT" ] || REPORT=".startup/insights/report.md"

mkdir -p "$(dirname "$STATE")" "$(dirname "$OUT")" "$(dirname "$REPORT")"
[ -f "$OUT" ] || : > "$OUT"

# Correction vocabulary (case-insensitive), ANCHORED at the start of the turn so a
# mid-sentence word ("...use X instead") cannot trigger it. Conservative; medium confidence.
CORRECTION_RE='^[[:space:]]*(no[,.! ]|nope|stop[,.! ]|actually,|that.?s (wrong|not)|you (missed|misunderstood)|don.?t |do not |wrong,|not what)'
# A correction must also be a short human turn.
CORRECTION_MAXLEN=600

EMITTED=0; MALFORMED=0; SKIPPED_FILES=0
COUNT_interrupt=0; COUNT_nudge=0; COUNT_correction=0; COUNT_toolfail=0

# Watermark state must be a JSON object (empty/missing/corrupt -> {}).
STATE_JSON="$(cat "$STATE" 2>/dev/null || true)"
printf '%s' "$STATE_JSON" | jq -e 'type=="object"' >/dev/null 2>&1 || STATE_JSON='{}'

emit_record() {
  local file="$1" lineno="$2" sig="$3" conf="$4" sid="$5" ts="$6" summary="$7"
  jq -cn \
    --arg sp "$PROJECT" --arg sid "$sid" --arg file "$file" --argjson line "$lineno" \
    --arg ts "$ts" --arg st "$sig" --arg ev "${file}#L${lineno}" \
    --arg sum "$summary" --arg conf "$conf" \
    '{source_project:$sp, session_id:$sid, file:$file, line:$line,
      timestamp:(if $ts=="" then null else $ts end),
      signal_type:$st, local_evidence_ref:$ev, sanitized_summary:$sum, confidence:$conf}' \
    >> "$OUT"
  EMITTED=$((EMITTED + 1))
  case "$sig" in
    interrupt)    COUNT_interrupt=$((COUNT_interrupt + 1)) ;;
    nudge)        COUNT_nudge=$((COUNT_nudge + 1)) ;;
    correction)   COUNT_correction=$((COUNT_correction + 1)) ;;
    tool_failure) COUNT_toolfail=$((COUNT_toolfail + 1)) ;;
  esac
}

process_line() {
  local line="$1" file="$2" lineno="$3" default_sid="$4"
  local parsed
  # One jq pass. Fields joined by the unit separator (0x1f, non-whitespace) so EMPTY
  # fields (e.g. a missing timestamp) survive read-splitting. user_text unifies string
  # content and array {type:text} blocks; is_noise flags harness command-output wrappers.
  parsed="$(printf '%s' "$line" | jq -r '
    ( ( if (.message.content|type)=="string" then .message.content
        elif (.message.content|type)=="array" then ([ .message.content[]? | select(.type=="text") | .text ] | join(" "))
        else "" end ) | gsub("[[:cntrl:]]"; " ") ) as $t
    | ( [ .message.content[]? | select((.type=="tool_result") and (.is_error==true))
          | ( if (.content|type)=="string" then .content
              elif (.content|type)=="array" then ([ .content[]? | select(.type=="text") | .text ] | join(" "))
              else "" end ) ]
        | join(" ") | gsub("[[:cntrl:]]"; " ") ) as $err
    | [ (.type // ""),
        (([ .message.content[]? | select((.type=="tool_result") and (.is_error==true)) ] | length > 0) | tostring),
        (.sessionId // ""),
        (.timestamp // ""),
        ($t | test("^[[:space:]]*(<(local-command-caveat|local-command-stdout|bash-stdin|bash-stdout|bash-stderr|system-reminder)|Stop hook feedback)") | tostring),
        $t,
        $err
      ] | join("\u001f")' 2>/dev/null)" || { MALFORMED=$((MALFORMED + 1)); return 0; }
  [ -n "$parsed" ] || { MALFORMED=$((MALFORMED + 1)); return 0; }

  local f_type f_toolerr f_sid f_ts f_noise f_text f_err
  IFS=$'\037' read -r f_type f_toolerr f_sid f_ts f_noise f_text f_err <<< "$parsed"
  [ "$f_type" = "user" ] || return 0

  local sid="$f_sid" ts="$f_ts"
  [ -n "$sid" ] && [ "$sid" != "null" ] || sid="$default_sid"

  local sig="" conf="" summary=""
  if [ "$f_toolerr" = "true" ]; then
    sig="tool_failure"; conf="medium"
    # Carry the specific error text so distinct failures cluster distinctly;
    # fall back to the generic marker only when no message text is present.
    summary="$(printf '%s' "$f_err" | cut -c1-160)"
    [ -n "$summary" ] || summary="tool_result error"
  elif [ "$f_noise" = "true" ]; then
    return 0  # harness/hook-injected turn, not an investor turn
  elif [ -n "$f_text" ]; then
    if printf '%s' "$f_text" | grep -qF '[Request interrupted by user]'; then
      sig="interrupt"; conf="high"
    elif [ "${#f_text}" -le 300 ] \
         && printf '%s' "$f_text" | grep -qiE '^[[:space:]]*/nudge([[:space:]]|$)'; then
      sig="nudge"; conf="high"
    elif [ "${#f_text}" -le "$CORRECTION_MAXLEN" ] \
         && printf '%s' "$f_text" | grep -qiE "$CORRECTION_RE"; then
      sig="correction"; conf="medium"
    else
      return 0
    fi
    summary="$(printf '%s' "$f_text" | cut -c1-160)"
  else
    return 0
  fi

  emit_record "$file" "$lineno" "$sig" "$conf" "$sid" "$ts" "$summary"
}

shopt -s nullglob
for f in "$LOGS_DIR"/*.jsonl; do
  [ -f "$f" ] || continue
  # Budget is enforced at FILE granularity: once the cap is reached, defer the
  # remaining files (watermark untouched) so the next run resumes them — no data loss.
  if [ "$EMITTED" -ge "$MAX_RECORDS" ]; then SKIPPED_FILES=$((SKIPPED_FILES + 1)); continue; fi
  default_sid="$(basename "$f" .jsonl)"

  size="$(wc -c < "$f" | tr -d ' ')"
  [ "$size" -gt 0 ] || continue

  # complete_size = byte offset just past the last newline (bytes of all complete lines)
  if tail -c1 "$f" | od -An -tx1 2>/dev/null | grep -q '0a'; then
    complete_size="$size"
  else
    partial_bytes=$(LC_ALL=C awk 'BEGIN{RS="\n"} {l=$0} END{print length(l)+0}' "$f")
    complete_size=$(( size - partial_bytes ))
  fi

  start="$(printf '%s' "$STATE_JSON" | jq -r --arg f "$f" '.[$f].offset // 0')"
  linebase="$(printf '%s' "$STATE_JSON" | jq -r --arg f "$f" '.[$f].lines // 0')"
  if [ "$start" -gt "$size" ]; then start=0; linebase=0; fi  # rotation / truncation guard

  if [ "$complete_size" -gt "$start" ]; then
    region_len=$(( complete_size - start ))
    while IFS= read -r line; do
      linebase=$((linebase + 1))
      process_line "$line" "$f" "$linebase" "$default_sid"
    done < <(tail -c +$((start + 1)) "$f" | head -c "$region_len")
  fi

  STATE_JSON="$(printf '%s' "$STATE_JSON" | jq -c \
    --arg f "$f" --argjson off "$complete_size" --argjson ln "$linebase" \
    '.[$f] = {offset: $off, lines: $ln}')"
done
shopt -u nullglob

printf '%s\n' "$STATE_JSON" > "$STATE"

interventions=$(( COUNT_interrupt + COUNT_nudge + COUNT_correction ))
{
  echo "# Session Insights — local intervention extract"
  echo
  echo "_Local only. No network. Records are NOT auto-filed — review precedes any filing._"
  echo
  echo "- project: \`$PROJECT\`"
  echo "- logs dir: \`$LOGS_DIR\`"
  echo "- records appended this run: $EMITTED"
  echo "- malformed lines skipped: $MALFORMED"
  echo
  echo "## Signal counts (this run)"
  echo "- interrupt: $COUNT_interrupt"
  echo "- nudge: $COUNT_nudge"
  echo "- correction: $COUNT_correction"
  echo "- tool_failure: $COUNT_toolfail"
  echo
  echo "**Investor interventions (interrupt+nudge+correction): $interventions**"
  if [ "$SKIPPED_FILES" -gt 0 ]; then
    echo
    echo "> budget of $MAX_RECORDS records reached — $SKIPPED_FILES file(s) deferred to next run (no data lost)."
  fi
  echo
  echo "Records: \`$OUT\`"
} > "$REPORT"

exit 0
