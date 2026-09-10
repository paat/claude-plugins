#!/usr/bin/env bash
# Validated decisions become immutable assessment snapshots; no tracker calls.
set -euo pipefail
usage() { echo 'usage: wit-register.sh --snapshot FILE --decisions FILE --output-dir DIR [--code-ref DIR] [--run-id ID]' >&2; exit "${1:-2}"; }
snapshot= decisions= output= code= run_id=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help) usage 0 ;;
    --snapshot|--decisions|--output-dir|--code-ref|--run-id)
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --snapshot) snapshot=$2 ;; --decisions) decisions=$2 ;; --output-dir) output=$2 ;;
        --code-ref) code=$2 ;; --run-id) run_id=$2 ;;
      esac; shift 2 ;;
    *) usage ;;
  esac
done
[ -f "$snapshot" ] && [ -f "$decisions" ] && [ -n "$output" ] || usage
now=${WIT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
commit=null
if [ -n "$code" ]; then commit=$(git -C "$code" rev-parse --verify HEAD); fi
# Reject malformed or mismatched cards before allocating any durable output.
jq -en --slurpfile s "$snapshot" --slurpfile d "$decisions" '
  def text: type == "string" and test("\\S");
  def cardfield: text or (type == "object" and length>0 and all(.[]; text));
  def strings: type == "array" and all(.[]; text);
  def complete: . == "complete" or . == "incomplete";
  ($s|length)==1 and ($d|length)==1 and
  ($s[0] | (.source.system|text) and (.source.scope|text) and (.fetched_at|text) and
    (.completeness|complete) and (.capability_limits|strings) and
    (.items|type=="array") and all(.items[];
      (.id|text) and (.title|text) and (.updatedAt == null or (.updatedAt|text)) and
      (.comments_fetched|type=="number" and .>=0 and floor==.) and (.completeness|complete))) and
  ($d[0].items|type=="array") and
  ([$s[0].items[].id]|sort) == ([$d[0].items[].id]|sort) and
  ([$s[0].items[].id]|length) == ([$s[0].items[].id]|unique|length) and
  all($d[0].items[];
    (.direction as $direction | .disposition as $disposition |
      if $direction=="existing" then
        ["implement-minimally","consolidate-into","verify-first","defer","close-completed","close-duplicate"]
      elif $direction=="proposed" then
        ["do-not-file","file-minimal","append-to","fix-now-no-item","record-as-limitation"]
      else [] end | index($disposition)!=null) and
    (.outcome|cardfield) and (.response|text) and (.cost|cardfield) and
    (.evidence.class as $class | ["reproduced","source-reachable","hypothetical","unavailable"]|index($class)!=null) and
    (if .evidence.class=="unavailable" then ([..|objects|has("frequency")]|any|not) else true end) and
    (.necessity=="required" or .necessity=="discretionary") and
    (.readiness=="ready" or .readiness=="blocked" or .readiness=="unknown") and
    (.priority|type=="number" and .>=1 and floor==.) and (.prerequisites|strings) and
    (.next_task|text) and (.stop_condition|text) and (.code_refs|strings) and
    (.enforcement.class as $class | ["native","instruction-only","unavailable"]|index($class)!=null) and
    (.enforcement.mechanism|text) and
    (if .disposition=="defer" then (.revisit_trigger|text and test("[0-9]{4}-[0-9]{2}-[0-9]{2}|#[0-9]+|evidence: *[^ ]")) else true end) and
    (if .disposition=="consolidate-into" or .disposition=="append-to" then (.target|text) else true end))
' >/dev/null || { echo 'wit-register: invalid snapshot or decision schema/coverage' >&2; exit 2; }
if [ "$commit" = null ] && jq -e 'any(.items[]; .code_refs|length>0)' "$decisions" >/dev/null; then
  echo 'wit-register: code_refs require --code-ref to pin HEAD' >&2; exit 2
fi
root=$output/work-item-triage
mkdir -p "$root"
mkdir "$root/.writer-lock" 2>/dev/null || { echo 'wit-register: another writer is active' >&2; exit 1; }
stage=
trap '[ -z "$stage" ] || rm -rf "$stage"; rm -rf "$root/.writer-lock"' EXIT
if [ -n "$run_id" ]; then
  [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
  [ "$run_id" != pointer.json ] || usage
else
  base=$(printf '%s' "$now" | tr -cd 'A-Za-z0-9_-'); run_id=$base; n=0
  [ -n "$base" ] || usage
  while [ -e "$root/$run_id" ]; do n=$((n+1)); run_id=$base-$n; done
fi
[ ! -e "$root/$run_id" ] || { echo 'wit-register: refusing existing run directory' >&2; exit 1; }
previous=$root/.writer-lock/previous.json
: > "$previous"
prior_run=
if [ -f "$root/pointer.json" ]; then
  prior=$(jq -er '.run_id | select(test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))' "$root/pointer.json")
  prior_run=$prior
  seen='|'
  while [ -n "$prior" ]; do
    [[ $seen != *"|$prior|"* ]] || { echo 'wit-register: cyclic assessment history' >&2; exit 1; }
    seen="$seen$prior|"
    cat "$root/$prior/register.json" >> "$previous"
    prior=$(jq -r '.previous_run_id // empty' "$root/$prior/register.json")
    [[ -z "$prior" || "$prior" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
  done
fi
stage=$(mktemp -d "$root/.snapshot.XXXXXX")
jq -n --slurpfile s "$snapshot" --slurpfile d "$decisions" --slurpfile p "$previous" \
  --arg run "$run_id" --arg prior "$prior_run" --arg now "$now" --arg commit "$commit" '
  $s[0] as $snapshot | {schema_version:1,run_id:$run,previous_run_id:(if $prior=="" then null else $prior end),created_at:$now,source:$snapshot.source,
    completeness:$snapshot.completeness,capability_limits:$snapshot.capability_limits,
    items:[$d[0].items[] | . as $decision |
      ($snapshot.items[]|select(.id==$decision.id)) as $item |
      {id,direction,outcome,evidence,necessity,readiness,response,cost,disposition,priority,
       prerequisites,next_task,stop_condition,enforcement} +
      (if has("target") then {target} else {} end) +
      (if has("revisit_trigger") then {revisit_trigger} else {} end) +
      {title:$item.title,url:($item.url//null),
       provenance:({source:$snapshot.source,item_id:$item.id,fetched_at:$snapshot.fetched_at,
         updatedAt:$item.updatedAt,comments_fetched:$item.comments_fetched,
         completeness:(if $snapshot.completeness=="incomplete" then "incomplete" else $item.completeness end),
         code_refs:[$decision.code_refs[]|{ref:.,commit:$commit}]} +
         (if $item.history_digest then {history_digest:$item.history_digest} else {} end)),
       supersedes:([$p[]|select(.source==$snapshot.source)|. as $previous|.items[]|
         select(.id==$decision.id and .direction==$decision.direction)|
         {run_id:$previous.run_id,disposition:.disposition}][0]//null)}]}
' > "$stage/register.json"
jq -r '
  (.items|group_by(.disposition)|map(.[0].disposition+": "+(length|tostring))|join("; ")) as $counts |
  "# Work-item triage assessment: \(.run_id)\n",
  "Coverage: \(.items|length) items; \(.completeness). Proposed decisions; actual changes are in applied.json.\n",
  "Dispositions: \($counts).\n",
  (if .completeness=="incomplete" or any(.items[];.provenance.completeness=="incomplete") then
    "INCOMPLETE: missing pages or history; do not claim a complete census or apply dependent actions.\n" else empty end),
  (.capability_limits[]|"Capability limit: \(.)\n"),
  (if any(.items[];.direction=="proposed" and .disposition=="file-minimal") then
    "Filing handoff: delegate drafts to saas-startup-team:issue-file when installed. Otherwise output drafts and stop. WARNING: these drafts have had no PII review.\n" else empty end),
  "First five cards by necessity, then priority follow; register.json contains every card.\n",
  (.items|sort_by((if .necessity=="required" then 0 else 1 end), .priority, .id)|.[0:5][]|"## \(.id): \(.title)\n\nDirection: \(.direction); disposition: \(.disposition).\n\nOutcome: \(.outcome)\n\nEvidence: \(.evidence|tojson)\n\nNecessity: \(.necessity); readiness: \(.readiness).\n\nSmallest adequate response: \(.response)\n\nCost: \(.cost)\n",
    (if has("target") then "Target owner: \(.target)\n" else empty end),
    (if has("revisit_trigger") then "Revisit: \(.revisit_trigger)\n" else empty end))
' "$stage/register.json" > "$stage/summary.md"
jq -r '
  def eligible: .direction=="existing" and .disposition=="implement-minimally" and .readiness=="ready" and .provenance.completeness=="complete";
  def row: "- Priority \(.priority) — \(.id): \(.next_task)\n  Source: \(.provenance.source.system)/\(.provenance.source.scope); \(.url // .id)\n  Minimum scope: \(.response)\n  Necessity: \(.necessity); readiness: \(.readiness); disposition: \(.disposition)\n  Target owner: \(.target // "none")\n  Prerequisites: \(.prerequisites|join("; "))\n  Stop/refresh: \(.stop_condition)\n  enforcement: \(.enforcement.class) — \(.enforcement.mechanism)\n";
  "# Next actions: \(.run_id)\n\nAssessment: register.json; execution: applied.json; latest snapshot: ../pointer.json.\n",
  "Read the consuming selector before claiming enforcement. An instruction link does not change an unattended scheduler.\n",
  "## Implement now\n", ([.items[]|select(eligible)]|sort_by((if .necessity=="required" then 0 else 1 end), .priority, .id)|.[0:10][]|row),
  "## Prerequisites and other dispositions\n", ([.items[]|select(eligible|not)]|sort_by((if .necessity=="required" then 0 else 1 end), .priority, .id)|.[0:10][]|row),
  "Queue bounded to 10 rows per section; consult register.json for all decisions. Refresh when a stop condition, prerequisite, owner ruling, or tracker history changes."
' "$stage/register.json" > "$stage/queue.md"
printf '{"schema_version":1,"actions":[]}\n' > "$stage/applied.json"
mv "$stage" "$root/$run_id"; stage=
jq -n --arg run "$run_id" '{run_id:$run}' > "$root/.writer-lock/pointer.json"
mv "$root/.writer-lock/pointer.json" "$root/pointer.json"
printf '%s\n' "$root/$run_id"
