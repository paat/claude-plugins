#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd -- "$HERE/.." && pwd)"
TEMPLATE="$PLUGIN/templates/plugin-issue-reporting.md"
PASS=0; FAIL=0; TD=""; CASE=""

t() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "ok - $name"
  else FAIL=$((FAIL + 1)); echo "FAIL - $name"
  fi
}
trap '[ -z "$TD" ] || rm -rf -- "$TD"' EXIT

setup_suite() {
  TD="$(mktemp -d)"
  mkdir -p "$TD/plugin/scripts"
  cp "$PLUGIN/scripts/harvest.sh" "$PLUGIN/scripts/pii-gate.sh" "$TD/plugin/scripts/"
  cat > "$TD/plugin/scripts/agent-events.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROJECTOR_CALLS"
[ "$#" -eq 3 ] && [ "$1" = terminals ] && [ "$2" = --events ] || exit 97
case "$3" in
  *conflict.events) exit 3 ;;
  *malformed.events) printf '{bad projection\n'; exit 0 ;;
esac
cat -- "$3.projected"
SH
  chmod +x "$TD/plugin/scripts/agent-events.sh"
  HARVEST="$TD/plugin/scripts/harvest.sh"
  export HARVEST
}

new_case() {
  CASE="$(mktemp -d "$TD/case.XXXXXX")"
  EVENTS="$CASE/events.jsonl"
  PROJECTED="$EVENTS.projected"
  INSIGHTS="$CASE/insights.jsonl"
  LEDGER="$CASE/ledger.json"
  CANDIDATES="$CASE/candidates.jsonl"
  REPORT="$CASE/report.md"
  PROJECTOR_CALLS="$CASE/projector.calls"
  export PROJECTOR_CALLS
  : > "$EVENTS"; : > "$PROJECTED"; : > "$INSIGHTS"; : > "$PROJECTOR_CALLS"
}

terminal() { # id command outcome reason|null tokens|null [pr] [merge] [deployment]
  local hex
  printf -v hex '%032x' "$1"
  jq -cn --arg run "run-$hex" --arg command "$2" --arg outcome "$3" \
    --arg reason "$4" --arg tokens "$5" --arg pr "${6:-}" --arg merge "${7:-}" \
    --arg deployment "${8:-}" '
      {run_id:$run,parent_run_id:null,phase:"pass-outcome",command:$command,
       outcome:$outcome,terminal_reason:(if $reason=="null" then null else $reason end),
       total_tokens:(if $tokens=="null" then null else ($tokens|tonumber) end),
       pr:(if $pr=="" then null else $pr end),
       merge:(if $merge=="" then null else $merge end),
       deployment:(if $deployment=="" then null else $deployment end)}'
}

insight() {
  jq -cn --arg signal "$1" --arg summary "$2" --arg ref "$3" \
    '{signal_type:$signal,sanitized_summary:$summary,local_evidence_ref:$ref,confidence:"medium"}'
}

run_events() {
  bash "$HARVEST" --in "$INSIGHTS" --events "$EVENTS" --ledger "$LEDGER" \
    --candidates "$CANDIDATES" --report "$REPORT" --project acme
}

candidate_count() { jq -s 'length' "$CANDIDATES"; }

setup_suite

authoritative_command() {
  new_case
  terminal 1 maintain-loop failure false_success null > "$PROJECTED"
  printf '%s\n' 'raw/private/project/#912/run-customer-name' > "$EVENTS"
  run_events || return 1
  [ "$(cat "$PROJECTOR_CALLS")" = "terminals --events $EVENTS" ] &&
    [ "$(candidate_count)" -eq 1 ]
}
t "uses the authoritative sibling terminals command" authoritative_command

high_signal_policy() {
  new_case
  local i=0 reason
  for reason in false_success context_binding_violation invalid_workflow_state lease_conflict receipt_conflict; do
    i=$((i + 1)); terminal "$i" maintain-loop failure "$reason" 1 >> "$PROJECTED"
  done
  run_events && [ "$(candidate_count)" -eq 5 ] &&
    jq -se 'all(.[]; .signal_type=="workflow_friction" and .confidence=="high")' "$CANDIDATES" >/dev/null
}
t "one occurrence surfaces every explicit high-signal reason" high_signal_policy

cost_policy() {
  new_case
  terminal 1 improve failure budget_exhausted 20000 >> "$PROJECTED"
  terminal 2 improve failure timeout 19999 >> "$PROJECTED"
  run_events && [ "$(candidate_count)" -eq 1 ] &&
    jq -e '.deidentified_summary | contains("known total tokens 20000")' "$CANDIDATES" >/dev/null
}
t "costly non-success without an artifact surfaces at the token floor" cost_policy

artifact_success_policy() {
  new_case
  terminal 1 improve failure timeout 30000 open >> "$PROJECTED"
  terminal 2 improve failure timeout 30000 merged >> "$PROJECTED"
  terminal 3 improve failure timeout 30000 '' merged >> "$PROJECTED"
  terminal 4 improve failure timeout 30000 '' success >> "$PROJECTED"
  terminal 5 improve failure timeout 30000 '' '' success >> "$PROJECTED"
  run_events && [ "$(candidate_count)" -eq 0 ]
}
t "all successful artifact states centrally suppress costly friction" artifact_success_policy

successful_outcomes_excluded() {
  new_case
  terminal 1 improve success timeout 40000 >> "$PROJECTED"
  terminal 2 improve no-op timeout 40000 >> "$PROJECTED"
  terminal 3 improve skipped timeout 40000 >> "$PROJECTED"
  run_events && [ "$(candidate_count)" -eq 0 ]
}
t "success no-op and skipped outcomes never trigger the costly rule" successful_outcomes_excluded

recurrence_policy() {
  new_case
  terminal 1 maintain failure delivery_failed null >> "$PROJECTED"
  terminal 2 maintain failure delivery_failed null >> "$PROJECTED"
  terminal 3 maintain failure delivery_failed null >> "$PROJECTED"
  run_events && [ "$(candidate_count)" -eq 1 ] &&
    jq -e '.count==3 and .confidence=="medium" and (.deidentified_summary|contains("total tokens unavailable"))' \
      "$CANDIDATES" >/dev/null
}
t "three null-token terminals with one stable fingerprint recur" recurrence_policy

unknown_reason_excluded() {
  new_case
  local i
  for i in 1 2 3; do terminal "$i" maintain failure null null >> "$PROJECTED"; done
  for i in 4 5 6; do terminal "$i" maintain failure other null >> "$PROJECTED"; done
  for i in 7 8 9; do terminal "$i" maintain failure '' null >> "$PROJECTED"; done
  run_events && [ "$(candidate_count)" -eq 0 ]
}
t "null empty and other reasons never form recurrence candidates" unknown_reason_excluded

overlap_dedup() {
  new_case
  terminal 1 maintain-loop failure false_success 25000 > "$PROJECTED"
  run_events && [ "$(candidate_count)" -eq 1 ] && [ "$(jq -r .count "$CANDIDATES")" -eq 1 ]
}
t "overlapping high-signal and costly rules emit one fingerprint" overlap_dedup

projection_excludes_child() {
  new_case
  printf '%s\n' \
    '{"run_id":"raw-root","parent_run_id":null}' \
    '{"run_id":"raw-child-private","parent_run_id":"raw-root","reason":"false_success"}' > "$EVENTS"
  terminal 1 maintain-loop failure delivery_failed null > "$PROJECTED"
  terminal 2 maintain-loop failure delivery_failed null >> "$PROJECTED"
  terminal 3 maintain-loop failure delivery_failed null >> "$PROJECTED"
  run_events && [ "$(candidate_count)" -eq 1 ] &&
    ! grep -Eq 'raw-root|raw-child-private' "$CANDIDATES" "$REPORT"
}
t "child and raw records excluded by projection never reach harvest" projection_excludes_child

failed_projection_preserves_outputs() {
  new_case
  printf 'old candidates\n' > "$CANDIDATES"; printf 'old report\n' > "$REPORT"
  local bad="$CASE/conflict.events"
  : > "$bad"
  ! bash "$HARVEST" --events "$bad" --in "$INSIGHTS" --ledger "$LEDGER" \
      --candidates "$CANDIDATES" --report "$REPORT" >/dev/null 2>&1 &&
    [ "$(cat "$CANDIDATES")" = 'old candidates' ] && [ "$(cat "$REPORT")" = 'old report' ] || return 1
  bad="$CASE/malformed.events"; : > "$bad"
  ! bash "$HARVEST" --events "$bad" --in "$INSIGHTS" --ledger "$LEDGER" \
      --candidates "$CANDIDATES" --report "$REPORT" >/dev/null 2>&1 &&
    [ "$(cat "$CANDIDATES")" = 'old candidates' ] && [ "$(cat "$REPORT")" = 'old report' ]
}
t "conflict or malformed projection is fatal and preserves old outputs" failed_projection_preserves_outputs

privacy_contract() {
  new_case
  printf '%s\n' '/home/customer/repo issue #488 PR#91 unhashed-run-id customer@example.com' > "$EVENTS"
  terminal 9 goal-deliver failure invalid_workflow_state null > "$PROJECTED"
  run_events || return 1
  ! grep -Eqi '/home|customer|#488|PR#91|unhashed-run-id|@example' "$CANDIDATES" &&
    jq -e '(.evidence_refs | all(.[]; test("^workflow-event:run-[0-9a-f]{32}$"))) and
      (.deidentified_summary | contains("goal-deliver") and contains("invalid_workflow_state")) and
      (.recommendation | type=="string")' "$CANDIDATES" >/dev/null
}
t "candidates contain only generic normalized fields and opaque refs" privacy_contract

evidence_cap() {
  new_case
  local i
  for i in $(seq 1 14); do terminal "$i" maintain-loop failure false_success null >> "$PROJECTED"; done
  run_events && [ "$(jq -r '.count' "$CANDIDATES")" -eq 14 ] &&
    [ "$(jq -r '.evidence_refs|length' "$CANDIDATES")" -eq 10 ] &&
    jq -e '.evidence_refs == (.evidence_refs | unique | sort)' "$CANDIDATES" >/dev/null
}
t "opaque evidence refs are deduped sorted and capped at ten" evidence_cap

deterministic_order() {
  new_case
  terminal 8 improve failure receipt_conflict null > "$PROJECTED"
  terminal 2 maintain-loop failure false_success null >> "$PROJECTED"
  run_events || return 1
  cp "$CANDIDATES" "$CASE/first.jsonl"
  tac "$PROJECTED" > "$CASE/reversed"; mv "$CASE/reversed" "$PROJECTED"
  run_events || return 1
  cmp -s "$CASE/first.jsonl" "$CANDIDATES" &&
    jq -s -e 'map(.fingerprint) == (map(.fingerprint)|sort)' "$CANDIDATES" >/dev/null
}
t "candidate and evidence order is deterministic" deterministic_order

ledger_dedup() {
  new_case
  terminal 1 maintain failure lease_conflict null > "$PROJECTED"
  run_events || return 1
  local fp; fp="$(jq -r .fingerprint "$CANDIDATES")"
  jq -n --arg fp "$fp" '{($fp):{filed:true}}' > "$LEDGER"
  run_events && [ "$(candidate_count)" -eq 0 ] && grep -q 'deduped (already in ledger): 1' "$REPORT"
}
t "workflow friction respects the existing fingerprint ledger" ledger_dedup

mixed_sorted_output() {
  new_case
  insight correction 'use pnpm for the generated workspace' '/tmp/a#L1' >> "$INSIGHTS"
  insight correction 'use pnpm for the generated workspace' '/tmp/a#L2' >> "$INSIGHTS"
  terminal 1 maintain failure context_binding_violation null > "$PROJECTED"
  run_events && [ "$(candidate_count)" -eq 2 ] &&
    jq -s -e '(map(.signal_type)|sort) == ["correction","workflow_friction"] and
      (map(.fingerprint) == (map(.fingerprint)|sort))' "$CANDIDATES" >/dev/null
}
t "legacy insights and friction share one deterministic sorted output" mixed_sorted_output

legacy_compatibility() {
  new_case
  insight correction 'the invoice total is rounded incorrectly' '/tmp/a#L1' >> "$INSIGHTS"
  insight correction 'the invoice total is rounded incorrectly' '/tmp/a#L2' >> "$INSIGHTS"
  bash "$HARVEST" --in "$INSIGHTS" --ledger "$LEDGER" --candidates "$CANDIDATES" \
    --report "$REPORT" --project acme && [ "$(candidate_count)" -eq 1 ] &&
    [ ! -s "$PROJECTOR_CALLS" ] && [ "$(jq -r .signal_type "$CANDIDATES")" = correction ]
}
t "legacy --in behavior remains available without event projection" legacy_compatibility

network_free() {
  new_case
  mkdir -p "$CASE/bin"
  local command
  for command in gh curl wget; do
    printf '#!/usr/bin/env bash\nprintf called > "$NETWORK_CALLED"\nexit 99\n' > "$CASE/bin/$command"
    chmod +x "$CASE/bin/$command"
  done
  terminal 1 maintain failure false_success null > "$PROJECTED"
  NETWORK_CALLED="$CASE/network.called" PATH="$CASE/bin:$PATH" run_events &&
    [ ! -e "$CASE/network.called" ] && ! grep -Eq '(^|[^[:alnum:]_])(gh|curl|wget)[[:space:]]' "$HARVEST"
}
t "harvest remains strictly local and network-free" network_free

template_routing() {
  grep -q 'scripts/issue-file.sh' "$TEMPLATE" && grep -q -- '--labels' "$TEMPLATE" &&
    ! grep -q 'gh issue create' "$TEMPLATE"
}
t "plugin defects route through issue-file with labels and no direct gh create" template_routing

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
