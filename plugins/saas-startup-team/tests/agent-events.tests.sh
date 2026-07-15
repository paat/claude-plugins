# Sourced by run-tests.sh: append-only telemetry, legacy parsing, and sanitized export.

test_agent_events() {
  echo -e "\n${CYAN}Suite: delivery agent events and redacted evaluation export${NC}"
  local events_script="$PLUGIN_ROOT/scripts/agent-events.sh"
  local exporter="$PLUGIN_ROOT/scripts/agent-events-export.sh"
  local aggregator="$PLUGIN_ROOT/scripts/agent-events-aggregate.sh"
  local wd events out ec i lines export1 export2 aggregate secret generated_id bad_output
  local identity_events identity_export identity_tmp tampered_events tampered_read tampered_secret_events route_events
  local guard_repo guard_dir snapshot auth receipt receipt_backup outside bin first_receipt verified tag concurrent

  assert_file_exists "EV1: event writer/parser exists" "$events_script"
  assert_file_exists "EV2: redacted exporter exists" "$exporter"
  assert_file_exists "EV3: sanitized aggregator exists" "$aggregator"
  assert_equals "EV3a: event routing schema follows the router" \
    "$(bash "$events_script" schema-version | jq -r .routing_schema_version)" \
    "$(bash "$PLUGIN_ROOT/scripts/delivery-route.sh" schema-version | jq -r .schema_version)"

  generated_id=$(bash "$events_script" new-run-id)
  assert_equals "EV3b: generated run IDs are opaque" \
    "$([[ "$generated_id" =~ ^run-[0-9a-f]{32}$ ]] && echo true || echo false)" "true"

  wd=$(mktemp -d); events="$wd/events.jsonl"
  bash "$events_script" append --events "$events" --run-id run-1 --command improve --phase implementation \
    --surface codex --profile standard --writer-id worker-1 --event-type started --outcome incomplete >/dev/null
  assert_equals "EV4: routing reasons are optional" "$(jq -r '.routing_reasons | length' "$events")" "0"
  assert_equals "EV5: missing effective model remains null" "$(jq -r '.effective_model == null' "$events")" "true"
  assert_equals "EV6: missing token data remains null" "$(jq -r '.input_tokens == null' "$events")" "true"
  ec=0; bash "$events_script" append --events "$events" --run-id run-bad --command improve --phase implementation \
    --surface codex --profile standard --writer-id worker-bad --event-type started --outcome success \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV6a: nonterminal events cannot claim success" "$ec" 2
  bash "$events_script" append --events "$events" --run-id run-1 --command improve --phase implementation \
    --surface codex --profile standard --writer-id worker-1 --event-type completed --outcome success \
    --requested-provider openai --requested-model gpt-5.6-sol --requested-effort high \
    --effective-provider openai --effective-model gpt-5.6-sol --effective-effort high \
    --duration-ms 120 --input-tokens 100 --output-tokens 20 --checks passed >/dev/null
  assert_equals "EV7: start and completion are append-only" "$(wc -l < "$events" | tr -d ' ')" "2"

  # Concurrent writers must leave one valid JSON object per append.
  for i in $(seq 1 24); do
    bash "$events_script" append --events "$events" --run-id "run-c-$i" --command maintain --phase triage \
      --surface script --profile light --writer-id "writer-$i" --event-type completed --outcome success \
      --duration-ms "$i" >/dev/null &
  done
  wait
  lines=$(wc -l < "$events" | tr -d ' ')
  assert_equals "EV8: concurrent append preserves every line" "$lines" "26"
  ec=0; jq -e . "$events" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV9: concurrent JSONL is not corrupted" "$ec" 0

  mkdir -p "$wd/.startup/maintain/runs" "$wd/.startup/maintain-loop/runs/rid"
  printf '%s\n' '# old run' 'fixed:PR#7' 'duration_ms: 55' > "$wd/.startup/maintain/runs/old.md"
  printf '%s\n' '# interrupted run without a terminal marker' > "$wd/.startup/maintain-loop/runs/rid/issue.md"
  out=$(bash "$events_script" read --events "$events" --legacy-root "$wd/.startup")
  assert_equals "EV10: old and new artifacts parse together" "$(wc -l <<< "$out" | tr -d ' ')" "28"
  assert_equals "EV11: legacy fixed artifact normalizes to success" "$(jq -rs '[.[] | select(.source_schema_version==0 and .outcome=="success")] | length' <<< "$out")" "1"
  assert_equals "EV12: interrupted legacy artifact stays explicitly incomplete" "$(jq -rs '[.[] | select(.source_schema_version==0 and .outcome=="incomplete")] | length' <<< "$out")" "1"

  export1="$wd/export1.json"
  bash "$exporter" --events "$events" --legacy-root "$wd/.startup" --out "$export1" >/dev/null
  assert_json_valid "EV13: sanitized export is valid JSON" "$export1"
  assert_equals "EV14: start/completion pair collapses to latest" "$(jq -r .sample_count "$export1")" "27"
  assert_equals "EV15: incomplete interrupted run is counted" "$(jq -r '.metrics.outcomes.incomplete' "$export1")" "1"
  assert_equals "EV16: export contains no raw run ids" "$(jq 'paths | map(tostring) | join(".") | select(test("run_id"))' "$export1" | wc -l | tr -d ' ')" "0"
  assert_equals "EV16a: export retains new routing schema counts" \
    "$(jq -r '.metrics.routing_schema_versions["1"]' "$export1")" "25"
  assert_equals "EV16b: export retains legacy routing schema counts" \
    "$(jq -r '.metrics.routing_schema_versions["0"]' "$export1")" "2"
  ec=0; jq -r '.. | strings' "$export1" | grep -qE '(https?://|/tmp/|old\.md|issue\.md|PR#)' && ec=1 || true
  assert_exit_code "EV17: export contains no paths URLs filenames or PR ids" "$ec" 0

  # Secret-shaped values are blocked at the writer boundary.
  secret='sk-'"$(printf 'a%.0s' $(seq 1 24))"
  ec=0
  bash "$events_script" append --events "$events" --run-id run-secret --command improve --phase implementation \
    --surface codex --profile standard --writer-id writer-secret --requested-model "$secret" \
    --event-type completed --outcome failure >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV18: secret fixture is blocked" "$ec" 3

  printf 'owner: person@example.com\n' > "$wd/.startup/maintain/runs/pii.md"
  ec=0; bash "$events_script" read --events "$events" --legacy-root "$wd/.startup" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV18a: legacy PII fixture is blocked before export" "$ec" 3
  rm -f "$wd/.startup/maintain/runs/pii.md"

  # Launcher overrides remain exact in argv/logs, while the append boundary stores
  # only fixed public dimension values.
  identity_events="$wd/identity-events.jsonl"
  bash "$events_script" append --events "$identity_events" --run-id customer-acme-run \
    --command customer-acme-command --phase customer-acme-phase --routing-reason customer-acme-reason \
    --surface codex --profile standard --writer-id customer-acme-writer --event-type started --outcome incomplete \
    --requested-provider customer-acme-provider --requested-model customer-acme-model --requested-effort customer-acme-effort \
    --effective-provider customer-acme-provider --effective-model customer-acme-model --effective-effort customer-acme-effort \
    --checks customer-acme-status >/dev/null
  bash "$events_script" append --events "$identity_events" --run-id customer-acme-run \
    --command customer-acme-command --phase customer-acme-phase --routing-reason customer-acme-reason \
    --surface codex --profile standard --writer-id customer-acme-writer --event-type completed --outcome success \
    --requested-provider customer-acme-provider --requested-model customer-acme-model --requested-effort customer-acme-effort \
    --effective-provider customer-acme-provider --effective-model customer-acme-model --effective-effort customer-acme-effort \
    --checks customer-acme-status >/dev/null
  assert_equals "EV18b: raw events contain no arbitrary identity-shaped dimensions" \
    "$(grep -c 'customer-acme' "$identity_events" || true)" "0"
  assert_equals "EV18c: writer normalizes every unknown public dimension" \
    "$(jq -s 'all(.[]; [.requested_provider,.requested_model,.requested_effort,.effective_provider,.effective_model,.effective_effort,.checks] | all(.[]; . == "other"))' "$identity_events")" "true"
  assert_equals "EV18c2: command phase and routing reasons use strict public codes" \
    "$(jq -s '[.[].command,.[].phase,.[].routing_reasons[]] | all(.[]; . == "other")' "$identity_events")" "true"
  assert_equals "EV18c3: caller run and writer identities become stable opaque IDs" \
    "$(jq -s '([.[].run_id] | unique | length) == 1 and ([.[].writer_id] | unique | length) == 1 and all(.[]; (.run_id | test("^run-[0-9a-f]{32}$")) and (.writer_id | test("^writer-[0-9a-f]{32}$")))' "$identity_events")" "true"

  route_events="$wd/route-events.jsonl"
  bash "$events_script" append --events "$route_events" --run-id route-reason-run \
    --command maintain-loop --phase routing --surface script --profile deep --writer-id route-reason-writer \
    --routing-reason sensitive_accounting_reporting --routing-reason sensitive_surface_vocabulary \
    --event-type completed --outcome escalated >/dev/null
  assert_equals "EV18c4: sensitive delivery route reasons survive the append/read boundary" \
    "$(bash "$events_script" read --events "$route_events" | jq -c '.routing_reasons')" \
    '["sensitive_accounting_reporting","sensitive_surface_vocabulary"]'

  # Older or manually tampered records remain readable, but the reader and exporter
  # normalize their dimensions before returning any evaluation data.
  identity_tmp="$wd/identity-events.tmp"
  jq -c '
    .run_id="customer-acme-run" | .writer_id="customer-acme-writer"
    | .command="customer-acme-command" | .phase="customer-acme-phase" | .routing_reasons=["customer-acme-reason"]
    | .profile="customer-acme-profile"
    | .outcome=(if .event_type == "completed" then "customer-acme-outcome" else "incomplete" end)
    | .requested_provider="customer-acme-provider" | .effective_provider="customer-acme-provider"
    | .requested_model="customer-acme-model" | .effective_model="customer-acme-model"
    | .requested_effort="customer-acme-effort" | .effective_effort="customer-acme-effort"
    | .checks="customer-acme-status"
  ' \
    "$identity_events" > "$identity_tmp"
  tampered_events="$wd/tampered-events.jsonl"
  mv "$identity_tmp" "$tampered_events"
  tampered_read=$(bash "$events_script" read --events "$tampered_events")
  assert_equals "EV18d: reader does not return tampered identity dimensions" \
    "$(grep -c 'customer-acme' <<< "$tampered_read" || true)" "0"
  assert_equals "EV18e: reader preserves nonterminal incomplete and normalizes terminal outcome" \
    "$(jq -s 'all(.[]; .profile == "other" and .checks == "other" and
      (if .event_type == "completed" then .outcome == "other" else .outcome == "incomplete" end))' <<< "$tampered_read")" "true"
  assert_equals "EV18e2: reader hashes tampered IDs and allowlists code fields" \
    "$(jq -s '([.[].run_id] | unique | length) == 1 and ([.[].writer_id] | unique | length) == 1 and all(.[]; .command == "other" and .phase == "other" and .routing_reasons == ["other"] and (.run_id | test("^run-[0-9a-f]{32}$")) and (.writer_id | test("^writer-[0-9a-f]{32}$")))' <<< "$tampered_read")" "true"
  identity_export="$wd/identity-export.json"
  bash "$exporter" --events "$tampered_events" --out "$identity_export" >/dev/null
  assert_equals "EV18f: arbitrary identity-shaped dimensions never reach export" \
    "$(grep -c 'customer-acme' "$identity_export" || true)" "0"
  assert_equals "EV18g: unknown provider is normalized" \
    "$(jq -r '.metrics.providers.requested.other' "$identity_export")" "1"
  assert_equals "EV18h: unknown model is normalized" \
    "$(jq -r '.metrics.models.requested.other' "$identity_export")" "1"
  assert_equals "EV18i: unknown effort is normalized" \
    "$(jq -r '.metrics.efforts.requested.other' "$identity_export")" "1"
  assert_equals "EV18j: unknown profile is normalized" \
    "$(jq -r '.metrics.profiles.other' "$identity_export")" "1"
  assert_equals "EV18k: unknown outcome is normalized" \
    "$(jq -r '.metrics.outcomes.other' "$identity_export")" "1"
  assert_equals "EV18l: unknown phase status is normalized" \
    "$(jq -r '.metrics.phase_statuses.checks.other' "$identity_export")" "1"

  tampered_secret_events="$wd/tampered-secret-events.jsonl"
  jq -c --arg secret "$secret" '.requested_model=$secret' \
    "$identity_events" > "$tampered_secret_events"
  ec=0; bash "$events_script" read --events "$tampered_secret_events" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV18m: reader blocks secrets before legacy normalization" "$ec" 3
  ec=0; bash "$exporter" --events "$tampered_secret_events" --out "$wd/tampered-secret-export.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV18n: exporter blocks secret-bearing legacy events" "$ec" 3

  # A second anonymous export aggregates without learning either project identity.
  local empty_events="$wd/empty.jsonl"
  : > "$empty_events"
  export2="$wd/export2.json"
  bash "$exporter" --events "$empty_events" --out "$export2" >/dev/null
  assert_equals "EV19: empty event set exports cleanly" "$(jq -r .sample_count "$export2")" "0"
  aggregate="$wd/aggregate.json"
  bash "$aggregator" --out "$aggregate" "$export1" "$export2" >/dev/null
  assert_equals "EV20: cross-project aggregate sums exports" "$(jq -r .export_count "$aggregate")" "2"
  assert_equals "EV21: aggregate preserves anonymous sample count" "$(jq -r .sample_count "$aggregate")" "27"
  assert_equals "EV21a: aggregate preserves routing schema strata" \
    "$(jq -r '.metrics.routing_schema_versions["1"]' "$aggregate")" "25"
  assert_equals "EV22: aggregate contains no project field" "$(jq 'paths | map(tostring) | join(".") | select(test("project|repository|run_id"))' "$aggregate" | wc -l | tr -d ' ')" "0"

  jq '.project="forbidden"' "$export1" > "$wd/bad-export.json"
  ec=0; bash "$aggregator" --out "$wd/bad-aggregate.json" "$wd/bad-export.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23: aggregator rejects identity-bearing schema additions" "$ec" 3

  jq '.metrics.models.requested["customer-acme-model"]=1' "$export1" > "$wd/bad-dimension-export.json"
  ec=0; bash "$aggregator" --out "$wd/bad-dimension-aggregate.json" "$wd/bad-dimension-export.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23b: aggregator rejects arbitrary dimension keys" "$ec" 3

  jq '.sample_count="27"' "$export1" > "$wd/bad-sample-type.json"
  ec=0; bad_output=$(bash "$aggregator" --out "$wd/bad-sample-type-aggregate.json" "$wd/bad-sample-type.json" 2>&1) || ec=$?
  assert_exit_code "EV23c: aggregator rejects non-integer sample count" "$ec" 3
  assert_output_contains "EV23d: aggregate validation failure is explicit" "$bad_output" "schema, count, or rate validation failed"

  jq '.run_count=.sample_count+1' "$export1" > "$wd/bad-run-count.json"
  ec=0; bash "$aggregator" --out "$wd/bad-run-count-aggregate.json" "$wd/bad-run-count.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23e: aggregator rejects run count above sample count" "$ec" 3

  jq '.metrics.fallback_count=.sample_count+1' "$export1" > "$wd/bad-fallback-count.json"
  ec=0; bash "$aggregator" --out "$wd/bad-fallback-aggregate.json" "$wd/bad-fallback-count.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23f: aggregator rejects invalid fallback count" "$ec" 3

  jq '.metrics.duration_ms={}' "$export1" > "$wd/bad-metric-array.json"
  ec=0; bash "$aggregator" --out "$wd/bad-metric-array-aggregate.json" "$wd/bad-metric-array.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23g: aggregator rejects malformed metric arrays" "$ec" 3

  jq '.metrics.providers=[]' "$export1" > "$wd/bad-metric-object.json"
  ec=0; bash "$aggregator" --out "$wd/bad-metric-object-aggregate.json" "$wd/bad-metric-object.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23h: aggregator rejects malformed metric objects" "$ec" 3

  jq '.metrics.outcomes.success=0.5' "$export1" > "$wd/bad-countmap.json"
  ec=0; bash "$aggregator" --out "$wd/bad-countmap-aggregate.json" "$wd/bad-countmap.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23i: aggregator rejects fractional count-map values" "$ec" 3

  jq '.metrics.routing_schema_versions={"customer-acme":.sample_count}' "$export1" > "$wd/bad-routing-schema.json"
  ec=0; bash "$aggregator" --out "$wd/bad-routing-aggregate.json" "$wd/bad-routing-schema.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23i2: aggregator rejects nonnumeric routing schema keys" "$ec" 3

  jq '.rates.success.value=2' "$export1" > "$wd/bad-rate-range.json"
  ec=0; bash "$aggregator" --out "$wd/bad-rate-range-aggregate.json" "$wd/bad-rate-range.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23j: aggregator rejects out-of-range rate values" "$ec" 3

  jq '.rates.qa_passed.value="bad"' "$export1" > "$wd/bad-rate-type.json"
  ec=0; bash "$aggregator" --out "$wd/bad-rate-type-aggregate.json" "$wd/bad-rate-type.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23k: aggregator validates every rate object" "$ec" 3

  jq 'del(.rates.success.numerator)' "$export1" > "$wd/bad-rate-object.json"
  ec=0; bash "$aggregator" --out "$wd/bad-rate-object-aggregate.json" "$wd/bad-rate-object.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23l: aggregator rejects incomplete rate objects" "$ec" 3

  jq '.rates.success.denominator=0' "$export1" > "$wd/bad-rate-consistency.json"
  ec=0; bash "$aggregator" --out "$wd/bad-rate-consistency-aggregate.json" "$wd/bad-rate-consistency.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EV23m: aggregator rejects rates inconsistent with counts" "$ec" 3

  assert_file_contains "EV24: raw events are gitignored" "$PLUGIN_ROOT/templates/gitignore-block.txt" '.startup/runs/'
  assert_file_contains "EV25: local evaluation corpus is gitignored" "$PLUGIN_ROOT/templates/gitignore-block.txt" '.startup/evaluation/'

  # Direct Claude/controller events use the Git-dir buffer while a role guard is
  # active, then become visible only after the authenticated verification.
  guard_repo=$(mktemp -d)
  git -C "$guard_repo" init -q
  git -C "$guard_repo" config user.email test@example.invalid
  git -C "$guard_repo" config user.name Test
  printf 'base\n' > "$guard_repo/app.txt"
  git -C "$guard_repo" add app.txt
  git -C "$guard_repo" commit -qm base
  auth=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  guard_dir="$(git -C "$guard_repo" rev-parse --absolute-git-dir)/saas-startup-team"
  snapshot="$guard_dir/qa.json"
  (cd "$guard_repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --snapshot "$snapshot" --auth-stdin --allow review.md <<<"$auth" >/dev/null)
  (cd "$guard_repo" && bash "$events_script" append --run-id run-guarded-claude \
    --command improve --phase qa --surface claude --profile deep --writer-id writer-guarded-claude \
    --event-type started --outcome incomplete >/dev/null)
  assert_file_not_exists "EV26: guarded Claude event is not written before verification" \
    "$guard_repo/.startup/runs/agent-events.jsonl"
  assert_equals "EV27: guarded Claude event publishes one import receipt" \
    "$(find "$guard_dir" -maxdepth 1 -name 'qa.json.telemetry-*.json' | wc -l | tr -d ' ')" "1"
  printf 'review\n' > "$guard_repo/review.md"
  ec=0; (cd "$guard_repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --verify "$snapshot" --auth-stdin <<<"$auth" >/dev/null) || ec=$?
  assert_exit_code "EV28: guard imports the buffered Claude event" "$ec" 0
  assert_equals "EV29: interrupted Claude phase remains explicitly incomplete" \
    "$(jq -r '.outcome' "$guard_repo/.startup/runs/agent-events.jsonl")" "incomplete"
  rm -rf "$guard_repo"

  # Forged traversal and symlink destinations fail before any outside write.
  guard_repo=$(mktemp -d); outside=$(mktemp -d)
  git -C "$guard_repo" init -q
  git -C "$guard_repo" config user.email test@example.invalid
  git -C "$guard_repo" config user.name Test
  printf 'base\n' > "$guard_repo/app.txt"; git -C "$guard_repo" add app.txt; git -C "$guard_repo" commit -qm base
  auth=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  guard_dir="$(git -C "$guard_repo" rev-parse --absolute-git-dir)/saas-startup-team"; snapshot="$guard_dir/qa.json"
  (cd "$guard_repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --snapshot "$snapshot" --auth-stdin --allow review.md <<<"$auth" >/dev/null)
  (cd "$guard_repo" && bash "$events_script" append --run-id run-traversal --command improve --phase qa \
    --surface claude --profile deep --writer-id writer-traversal --event-type started --outcome incomplete >/dev/null)
  receipt=$(find "$guard_dir" -maxdepth 1 -name 'qa.json.telemetry-*.json' -print -quit)
  receipt_backup="$receipt.backup"; cp "$receipt" "$receipt_backup"
  jq --arg destination "$guard_repo/.startup/runs/../../victim.jsonl" \
    '.destination=$destination' "$receipt_backup" > "$receipt"
  ec=0; (cd "$guard_repo" && bash "$events_script" import-guarded --check --receipt "$receipt" >/dev/null 2>&1) || ec=$?
  assert_exit_code "EV30: traversal receipt is rejected" "$ec" 3
  assert_file_not_exists "EV31: traversal import cannot write outside runtime state" "$guard_repo/victim.jsonl"
  mv "$receipt_backup" "$receipt"
  rm -rf "$guard_repo/.startup"; mkdir -p "$guard_repo/.startup"; ln -s "$outside" "$guard_repo/.startup/runs"
  ec=0; (cd "$guard_repo" && bash "$events_script" append --run-id run-symlink --command improve --phase qa \
    --surface claude --profile deep --writer-id writer-symlink --event-type started --outcome incomplete >/dev/null 2>&1) || ec=$?
  assert_exit_code "EV32: symlinked runtime destination is rejected" "$ec" 3
  assert_file_not_exists "EV33: symlinked runtime destination receives no event" "$outside/agent-events.jsonl"
  rm -rf "$guard_repo" "$outside"

  # An import retry after the atomic destination replacement does not duplicate
  # events, and a verified two-receipt batch resumes after the first import.
  guard_repo=$(mktemp -d)
  git -C "$guard_repo" init -q
  git -C "$guard_repo" config user.email test@example.invalid
  git -C "$guard_repo" config user.name Test
  printf 'base\n' > "$guard_repo/app.txt"; git -C "$guard_repo" add app.txt; git -C "$guard_repo" commit -qm base
  auth=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  guard_dir="$(git -C "$guard_repo" rev-parse --absolute-git-dir)/saas-startup-team"; snapshot="$guard_dir/qa.json"
  (cd "$guard_repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --snapshot "$snapshot" --auth-stdin --allow review.md <<<"$auth" >/dev/null)
  (cd "$guard_repo" && bash "$events_script" append --run-id run-retry --command improve --phase qa \
    --surface claude --profile deep --writer-id writer-retry --event-type started --outcome incomplete >/dev/null)
  receipt=$(find "$guard_dir" -maxdepth 1 -name 'qa.json.telemetry-*.json' -print -quit)
  mkdir -p "$guard_repo/.startup/runs"
  cp "$(jq -r .source "$receipt")" "$guard_repo/.startup/runs/agent-events.jsonl"
  cp "$(jq -r .source "$receipt").identity-key" "$guard_repo/.startup/runs/agent-events.jsonl.identity-key"
  (cd "$guard_repo" && bash "$events_script" import-guarded --receipt "$receipt" >/dev/null)
  assert_equals "EV34: guarded import retry deduplicates an already-persisted event" \
    "$(wc -l < "$guard_repo/.startup/runs/agent-events.jsonl" | tr -d ' ')" "1"
  rm -rf "$guard_repo"

  guard_repo=$(mktemp -d)
  git -C "$guard_repo" init -q
  git -C "$guard_repo" config user.email test@example.invalid
  git -C "$guard_repo" config user.name Test
  printf 'base\n' > "$guard_repo/app.txt"; git -C "$guard_repo" add app.txt; git -C "$guard_repo" commit -qm base
  auth=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  guard_dir="$(git -C "$guard_repo" rev-parse --absolute-git-dir)/saas-startup-team"; snapshot="$guard_dir/qa.json"
  (cd "$guard_repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --snapshot "$snapshot" --auth-stdin --allow review.md <<<"$auth" >/dev/null)
  for i in 1 2; do
    (cd "$guard_repo" && bash "$events_script" append --run-id "run-resume-$i" --command improve --phase qa \
      --surface claude --profile deep --writer-id "writer-resume-$i" --event-type started --outcome incomplete >/dev/null)
  done
  for receipt in "$snapshot.telemetry-"*.json; do
    (cd "$guard_repo" && bash "$events_script" import-guarded --check --receipt "$receipt" >/dev/null)
  done
  verified="$snapshot.verified"
  jq -n --arg snapshot_tag "$(jq -r .auth_tag "$snapshot")" \
    '{schema_version:1,snapshot_auth_tag:$snapshot_tag,auth_tag:null}' > "$verified"
  tag=$(jq -cS 'del(.auth_tag)' "$verified" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$auth" | awk '{print $NF}')
  jq --arg tag "$tag" '.auth_tag=$tag' "$verified" > "$verified.tmp"; mv "$verified.tmp" "$verified"; chmod 400 "$verified"
  rm -f "${snapshot}.active"
  first_receipt=$(find "$guard_dir" -maxdepth 1 -name 'qa.json.telemetry-*.json' | LC_ALL=C sort | head -n 1)
  (cd "$guard_repo" && bash "$events_script" import-guarded --receipt "$first_receipt" >/dev/null)
  ec=0; (cd "$guard_repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --verify "$snapshot" --auth-stdin <<<"$auth" >/dev/null) || ec=$?
  assert_exit_code "EV35: authenticated guard resumes a partially imported batch" "$ec" 0
  assert_equals "EV36: resumed batch preserves each event exactly once" \
    "$(wc -l < "$guard_repo/.startup/runs/agent-events.jsonl" | tr -d ' ')" "2"
  rm -rf "$guard_repo"

  # A controller event and nested Codex events share one guard-scoped identity;
  # the receipt is visible to the fake worker before it runs.
  guard_repo=$(mktemp -d); bin=$(mktemp -d)
  git -C "$guard_repo" init -q
  git -C "$guard_repo" config user.email test@example.invalid
  git -C "$guard_repo" config user.name Test
  printf 'base\n' > "$guard_repo/app.txt"; printf 'review task\n' > "$guard_repo/task.md"
  git -C "$guard_repo" add app.txt task.md; git -C "$guard_repo" commit -qm base
  printf '%s\n' '#!/usr/bin/env bash' \
    'find "$EXPECT_GUARD_DIR" -maxdepth 1 -name "qa.json.telemetry-*.json" -print -quit | grep -q .' \
    'while [ "$#" -gt 0 ]; do shift; done' \
    'cat >/dev/null' \
    "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"review complete\"}}'" \
    "printf '%s\\n' '{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"cached_input_tokens\":0}}'" \
    > "$bin/codex"
  chmod +x "$bin/codex"
  auth=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  guard_dir="$(git -C "$guard_repo" rev-parse --absolute-git-dir)/saas-startup-team"; snapshot="$guard_dir/qa.json"
  (cd "$guard_repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --snapshot "$snapshot" --auth-stdin --allow review.md <<<"$auth" >/dev/null)
  concurrent="$guard_dir/concurrent.json"
  (cd "$guard_repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --snapshot "$concurrent" --auth-stdin --allow concurrent-review.md <<<"$auth" >/dev/null)
  jq -n --arg snapshot_tag "$(jq -r .auth_tag "$snapshot")" \
    '{schema_version:1,snapshot_auth_tag:$snapshot_tag,auth_tag:"forged"}' > "${snapshot}.verified"
  chmod 400 "${snapshot}.verified"
  ec=0; (cd "$guard_repo" && PATH="$bin:$PATH" SAAS_RUN_ID=run-concurrent \
    SAAS_WRITER_ID=writer-concurrent bash "$PLUGIN_ROOT/scripts/codex-run-role.sh" \
    --role qa --profile deep --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "EV36a: forged terminal marker cannot hide two genuinely live guards" "$ec" 4
  rm -f "${snapshot}.verified"
  (cd "$guard_repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --verify "$concurrent" --auth-stdin <<<"$auth" >/dev/null)
  (cd "$guard_repo" && bash "$events_script" append --run-id run-controller --command improve --phase qa \
    --surface claude --profile deep --writer-id writer-controller --event-type started --outcome incomplete >/dev/null)
  ec=0; (cd "$guard_repo" && PATH="$bin:$PATH" EXPECT_GUARD_DIR="$guard_dir" SAAS_RUN_ID=run-codex \
    SAAS_WRITER_ID=writer-codex SAAS_CODEX_ROLE_TIMEOUT=10s bash "$PLUGIN_ROOT/scripts/codex-run-role.sh" \
    --role qa --profile deep --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "EV37: guarded Codex worker sees its receipt before launch" "$ec" 0
  ec=0; (cd "$guard_repo" && PATH="$bin:$PATH" SAAS_RUN_ID='../escape' SAAS_WRITER_ID=writer-invalid \
    bash "$PLUGIN_ROOT/scripts/codex-run-role.sh" --role qa --profile deep --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "EV38: unsafe run id fails before creating a buffer path" "$ec" 2
  (cd "$guard_repo" && bash "$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh" \
    --verify "$snapshot" --auth-stdin <<<"$auth" >/dev/null)
  assert_equals "EV39: mixed controller and Codex events import together" \
    "$(wc -l < "$guard_repo/.startup/runs/agent-events.jsonl" | tr -d ' ')" "3"
  assert_equals "EV40: mixed guarded imports leave no receipt" \
    "$(find "$guard_dir" -maxdepth 1 -name 'qa.json.telemetry-*.json' | wc -l | tr -d ' ')" "0"
  rm -rf "$guard_repo" "$bin"
  rm -rf "$wd"
}

test_agent_events
