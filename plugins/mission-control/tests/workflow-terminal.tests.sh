#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)"
MC="$PLUGIN/scripts/mission-control.sh"
PASS=0; FAIL=0; TD=""
t() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "ok - $name"
  else FAIL=$((FAIL + 1)); echo "FAIL - $name"
  fi
}
trap '[ -z "$TD" ] || rm -rf "$TD"' EXIT

setup_env() { # <project command> [engine template] [container]
  [ -z "$TD" ] || rm -rf "$TD"
  TD="$(mktemp -d)"
  local command="$1" template="${2:-codex exec {prompt}}" container="${3:-local}"
  mkdir -p "$TD/repo" "$TD/bin" \
    "$TD/codex/plugins/cache/paat-plugins/saas-startup-team/2.9.0/scripts" \
    "$TD/codex/plugins/cache/paat-plugins/saas-startup-team/2.10.0/scripts"
  export CODEX_HOME="$TD/codex" CLAUDE_HOME="$TD/claude"
  export HELPER_CALLS="$TD/helper.calls" ENGINE_CAPTURE="$TD/engine.ids"
  export FAKE_SCHEMA=2 FAKE_ACCOUNT_MODE=valid FAKE_OUTCOME=success
  export FAKE_REASON="" FAKE_COMMAND=maintain ENGINE_RC=0 ENGINE_OUTPUT="" FAKE_CACHE_TAMPER=""
  export FAKE_CODEX_PLUGIN_VERSION=2.10.0 FAKE_CODEX_PLUGIN_ENABLED=true
  export FAKE_CLAUDE_PLUGIN_VERSION=2.10.0 FAKE_CLAUDE_PLUGIN_ENABLED=true
  : > "$HELPER_CALLS"; : > "$ENGINE_CAPTURE"
cat > "$TD/bin/codex" <<'SH'
#!/bin/bash
if [ "${1:-}" = plugin ] && [ "${2:-}" = list ] && [ "${3:-}" = --json ]; then
  jq -cn --arg version "${FAKE_CODEX_PLUGIN_VERSION:-2.10.0}" \
    --argjson enabled "${FAKE_CODEX_PLUGIN_ENABLED:-true}" \
    '{installed:[{pluginId:"saas-startup-team@paat-plugins",version:$version,
      installed:true,enabled:$enabled}]}'
  exit 0
fi
printf '%s\n' "${SAAS_INVOCATION_ID:-missing}" >> "$ENGINE_CAPTURE"
case "${FAKE_CACHE_TAMPER:-}" in
  higher)
    target="$CODEX_HOME/plugins/cache/paat-plugins/saas-startup-team/99.0.0/scripts"
    mkdir -p "$target"
    cat > "$target/agent-events.sh" <<'MALICIOUS'
#!/bin/bash
printf 'MALICIOUS_HIGHER_EXECUTED\n' >> "$HELPER_CALLS"
exit 99
MALICIOUS
    printf '# sibling\n' > "$target/pii-gate.sh"
    printf '# sibling\n' > "$target/delivery-route.sh"
    chmod +x "$target/agent-events.sh"
    ;;
  bound)
    target="$CODEX_HOME/plugins/cache/paat-plugins/saas-startup-team/2.10.0/scripts/agent-events.sh"
    cat > "$target" <<'MALICIOUS'
#!/bin/bash
printf 'MALICIOUS_BOUND_EXECUTED\n' >> "$HELPER_CALLS"
exit 99
MALICIOUS
    chmod +x "$target"
    ;;
esac
printf '%b' "${ENGINE_OUTPUT:-}"
exit "${ENGINE_RC:-0}"
SH
  cat > "$TD/bin/claude" <<'SH'
#!/bin/bash
if [ "${1:-}" = plugin ] && [ "${2:-}" = list ] && [ "${3:-}" = --json ]; then
  jq -cn --arg version "${FAKE_CLAUDE_PLUGIN_VERSION:-2.10.0}" \
    --argjson enabled "${FAKE_CLAUDE_PLUGIN_ENABLED:-true}" \
    --arg path "$CLAUDE_HOME/plugins/cache/paat-plugins/saas-startup-team/${FAKE_CLAUDE_PLUGIN_VERSION:-2.10.0}" \
    '[{id:"saas-startup-team@paat-plugins",version:$version,scope:"user",
      enabled:$enabled,installPath:$path}]'
  exit 0
fi
printf '%s\n' "${SAAS_INVOCATION_ID:-missing}" >> "$ENGINE_CAPTURE"
printf '%b' "${ENGINE_OUTPUT:-}"
exit "${ENGINE_RC:-0}"
SH
  cat > "$TD/bin/docker" <<'SH'
#!/bin/bash
printf 'docker' >> "$DOCKER_CALLS"
printf ' %q' "$@" >> "$DOCKER_CALLS"
printf '\n' >> "$DOCKER_CALLS"
[ "${1:-}" = info ] && exit 0
[ "${1:-}" = exec ] || exit 2
shift
env_args=(IN_FAKE_CONTAINER=1)
while [ $# -gt 0 ]; do
  case "$1" in
    -u) shift 2 ;;
    -e) env_args+=("$2"); shift 2 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || exit 2
shift
env "${env_args[@]}" "$@"
SH
  chmod +x "$TD/bin/codex" "$TD/bin/claude" "$TD/bin/docker"
  export PATH="$TD/bin:$PATH" DOCKER_CALLS="$TD/docker.calls"
  : > "$DOCKER_CALLS"

  cat > "$TD/codex/plugins/cache/paat-plugins/saas-startup-team/2.9.0/scripts/agent-events.sh" <<'SH'
#!/bin/bash
printf 'old:%s\n' "$*" >> "$HELPER_CALLS"
echo '{"schema_version":1}'
SH
  cat > "$TD/codex/plugins/cache/paat-plugins/saas-startup-team/2.10.0/scripts/agent-events.sh" <<'SH'
#!/bin/bash
printf '%s|container=%s|%s\n' "$0" "${IN_FAKE_CONTAINER:-0}" "$*" >> "$HELPER_CALLS"
echo 'helper private diagnostic' >&2
if [ "${1:-}" = schema-version ]; then
  jq -cn --arg v "${FAKE_SCHEMA:-2}" '{schema_version:($v|tonumber)}'
  exit 0
fi
[ "${1:-}" = account ] || exit 2
case "${FAKE_ACCOUNT_MODE:-valid}" in
  missing) exit 4 ;;
  conflict) exit 3 ;;
  malformed) echo '{bad json'; exit 0 ;;
esac
shift
run_id=""; duration=""; total=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run-id) run_id="$2"; shift 2 ;;
    --duration-ms) duration="$2"; shift 2 ;;
    --total-tokens) total="$2"; shift 2 ;;
    *) exit 2 ;;
  esac
done
[ "${FAKE_ACCOUNT_MODE:-valid}" != token-mismatch ] || total=$((total + 1))
jq -cn --arg run "$run_id" --arg duration "$duration" --arg total "$total" \
  --arg command "${FAKE_COMMAND:-maintain}" --arg outcome "${FAKE_OUTCOME:-success}" \
  --arg reason "${FAKE_REASON:-}" '
  {schema_version:2,run_id:$run,command:$command,phase:"pass-outcome",parent_run_id:null,
   event_type:"accounted",duration_ms:($duration|tonumber),outcome:$outcome,
   terminal_reason:(if $reason=="" then null else $reason end),
   total_tokens:(if $total=="" then null else ($total|tonumber) end)}'
SH
  for version in 2.9.0 2.10.0; do
    printf '# test pii gate\n' > "$TD/codex/plugins/cache/paat-plugins/saas-startup-team/$version/scripts/pii-gate.sh"
    printf '# test delivery route\n' > "$TD/codex/plugins/cache/paat-plugins/saas-startup-team/$version/scripts/delivery-route.sh"
  done
  chmod +x "$TD"/codex/plugins/cache/paat-plugins/saas-startup-team/*/scripts/agent-events.sh
  mkdir -p "$TD/claude/plugins/cache/paat-plugins/saas-startup-team"
  cp -R "$TD/codex/plugins/cache/paat-plugins/saas-startup-team/2.9.0" \
    "$TD/codex/plugins/cache/paat-plugins/saas-startup-team/2.10.0" \
    "$TD/claude/plugins/cache/paat-plugins/saas-startup-team/"
  jq -n --arg td "$TD" --arg command "$command" --arg template "$template" --arg container "$container" '{
    state_dir:($td+"/state"), docker_cmd:"docker",
    engines:{e:{pool:"p",cmd:$template}}, pools:{p:{}}, slots:{A:{pinned:"p"}},
    projects:[{name:"p",container:$container,repo_path:($td+"/repo"),stage:"live",engine:"e",
      command:$command,hold:false,work_probe:"printf yes"}],
    admission:{wip_cap:1,confidence_min:0.7,veto_hours:72}}' > "$TD/config.json"
}

lib_call() {
  MC_LIB_ONLY=1 MC_CONFIG="$TD/config.json" bash -c 'source "$1"; shift; "$@"' _ "$MC" "$@"
}

run_wrapper() { # [run-id]
  local run_id="${1:-run-0123456789abcdef0123456789abcdef}" base="$TD/direct"
  : > "$base.log"; rm -f "$base.json"
  bash "$MC" wrapper --config "$TD/config.json" --slot A --project p --engine e \
    --container "$(jq -r '.projects[0].container' "$TD/config.json")" --repo-path "$TD/repo" \
    --envelope 1 --base "$base" --cmd "$(jq -r '.engines.e.cmd' "$TD/config.json" | sed 's/{prompt}/\/maintain/')" \
    --run-id "$run_id" >> "$base.log" 2>&1
}

wait_dispatch() {
  local i=0
  while ! compgen -G "$TD/state/dispatches/*.json" >/dev/null; do
    i=$((i + 1)); [ "$i" -lt 80 ] || return 1; sleep 0.05
  done
}

classifier_positive_contract() {
  local got command
  while IFS='|' read -r command got; do
    [ "$(lib_call workflow_command "$command" 2>/dev/null || true)" = "$got" ] || return 1
  done <<'EOF'
/maintain-loop --once --limit 1|maintain-loop
/maintain later arguments|maintain
/goal-deliver 42|goal-deliver
/saas-startup-team:maintain --fix|maintain
/saas-startup-team:maintain-loop --once|maintain-loop
/saas-startup-team:goal-deliver 42|goal-deliver
$saas-startup-team:maintain --fix|maintain
$saas-startup-team:maintain-loop --once|maintain-loop
$saas-startup-team:goal-deliver 42|goal-deliver
EOF
}
setup_env '/maintain'
t "classifier accepts bare and prefixed contracted workflows" classifier_positive_contract

classifier_negative_contract() {
  local command
  for command in '/maintain-loop' '/maintain-loop --once-ish' '/maintain --dry-run' \
    '/goal-deliver x --dry-run' '/saas-startup-team:maintain-loop' \
    '/saas-startup-team:maintain --dry-run' '$saas-startup-team:maintain --dry-run' \
    '/saas-startup-team:growth --channel seo' '$saas-startup-team:growth --channel seo' \
    '/saas-startup-team:lessons-deliver' '$saas-startup-team:status' \
    '/saas-startup-team:maintain-extra' '/lessons-deliver' '/maintain-extra' \
    'bash -c /maintain' 'echo /goal-deliver' 'x/maintain' '/saas-startup-team:Bad'; do
    ! lib_call workflow_command "$command" >/dev/null 2>&1 || return 1
  done
}
setup_env '/maintain'
t "classifier rejects non-contracted prefixes and invalid forms" classifier_negative_contract

footer_contract() {
  local log="$TD/footer.log"
  printf 'tokens used\n123\n' > "$log"
  [ "$(lib_call codex_total_tokens "$log")" = 123 ] || return 1
  printf 'tokens used\r\n65,980\r\n' > "$log"
  [ "$(lib_call codex_total_tokens "$log")" = 65980 ] || return 1
  printf 'tokens used\n12,34\ntokens used\n7,001\ntokens used\n42\n' > "$log"
  [ "$(lib_call codex_total_tokens "$log")" = 42 ] || return 1
  for value in 'tokens used: 12' 'tokens used \n12' 'tokens used\n12 ' 'tokens used\n1,23' \
    'prose tokens used\n12' 'tokens used\nabout 12'; do
    printf '%b\n' "$value" > "$log"
    [ -z "$(lib_call codex_total_tokens "$log")" ] || return 1
  done
  lib_call engine_template_is_codex_exec 'CODEX_HOME=/tmp/x /usr/bin/codex exec {prompt}' || return 1
  ! lib_call engine_template_is_codex_exec 'claude -p codex exec' || return 1
  ! lib_call engine_template_is_codex_exec 'bash -c "codex exec x"' || return 1
}
t "Codex footer parser is strict, CR-safe, and last-pair-wins" footer_contract

dispatch_identity() {
  ENGINE_OUTPUT='tokens used\n65,980\n'; export ENGINE_OUTPUT
  bash "$MC" tick --config "$TD/config.json" || return 1
  wait_dispatch || return 1
  local json; json="$(compgen -G "$TD/state/dispatches/*.json" | head -1)"
  local run_id; run_id="$(jq -r .run_id "$json")"
  [[ "$run_id" =~ ^run-[0-9a-f]{32}$ ]] &&
    [ "$(cat "$ENGINE_CAPTURE")" = "$run_id" ] &&
    jq -e '.terminal_status=="accounted" and .workflow_outcome=="success" and
      .workflow_reason==null and .total_tokens==65980 and .outcome=="ok" and
      (.run_id|type)=="string" and (.terminal_status|type)=="string" and
      (.workflow_outcome|type)=="string" and (.workflow_reason|type)=="null" and
      (.total_tokens|type)=="number" and (.started_at|type)=="number" and
      (.ended_at|type)=="number" and (.exit_code|type)=="number"' "$json" >/dev/null &&
    [ "$(grep -c 'schema-version' "$HELPER_CALLS")" -eq 1 ] &&
    [ "$(grep -c '|account ' "$HELPER_CALLS")" -eq 1 ] &&
    ! grep -q 'helper private diagnostic' "$TD/state/dispatches/"*.log
}
setup_env '/maintain'
t "dispatch mints one ID, injects it, accounts once, and adds typed JSON fields" dispatch_identity

generic_no_probe() {
  run_wrapper || return 1
  [ ! -s "$HELPER_CALLS" ] &&
    jq -e '.terminal_status=="not-applicable" and .workflow_outcome==null and
      .workflow_reason==null and .total_tokens==null and .outcome=="ok"' "$TD/direct.json" >/dev/null
}
setup_env '/lessons-deliver' 'claude -p {prompt}'
ENGINE_OUTPUT='tokens used\n999\n'; export ENGINE_OUTPUT
t "generic and lessons-deliver commands never probe or parse non-Codex footers" generic_no_probe

docker_boundary() {
  run_wrapper || return 1
  local run_id; run_id="$(jq -r .run_id "$TD/direct.json")"
  grep -q -- "-e SAAS_INVOCATION_ID=$run_id" "$DOCKER_CALLS" &&
    grep -q '|container=1|schema-version' "$HELPER_CALLS" &&
    grep -q '|container=1|account ' "$HELPER_CALLS" &&
    [ "$(cat "$ENGINE_CAPTURE")" = "$run_id" ]
}
setup_env '/maintain' 'codex exec {prompt}' dev-container
t "docker injects the ID and performs schema/account inside the container boundary" docker_boundary

account_status() { # <mode> <expected status> <expected governor outcome> [engine rc]
  FAKE_ACCOUNT_MODE="$1" ENGINE_RC="${4:-0}"; export FAKE_ACCOUNT_MODE ENGINE_RC
  run_wrapper || return 1
  jq -e --arg status "$2" --arg outcome "$3" \
    '.terminal_status==$status and .outcome==$outcome' "$TD/direct.json" >/dev/null
}
setup_env '/maintain'; t "rc0 missing terminal is error" account_status missing missing error
setup_env '/maintain'; t "rc0 conflicting terminal is invalid/error" account_status conflict invalid error
setup_env '/maintain'; t "rc0 malformed terminal is invalid/error" account_status malformed invalid error
setup_env '/maintain'; t "success terminal plus nonzero exit is exit-conflict/error" account_status valid exit-conflict error 1

footer_mismatch_visible() {
  ENGINE_OUTPUT='tokens used\n1,234\n'; FAKE_ACCOUNT_MODE=token-mismatch
  export ENGINE_OUTPUT FAKE_ACCOUNT_MODE
  run_wrapper || return 1
  jq -e '.terminal_status=="invalid" and .outcome=="error" and .total_tokens==1234' "$TD/direct.json" >/dev/null
}
setup_env '/maintain'
t "footer mismatch invalidates terminal but preserves strict footer total" footer_mismatch_visible

outcome_mappings() {
  local workflow expected reason
  while IFS='|' read -r workflow expected reason; do
    FAKE_OUTCOME="$workflow"; FAKE_REASON="$reason"; export FAKE_OUTCOME FAKE_REASON
    : > "$HELPER_CALLS"
    run_wrapper || return 1
    [ "$(jq -r .outcome "$TD/direct.json")" = "$expected" ] || return 1
  done <<'EOF'
success|ok|
no-op|ok|
skipped|ok|
blocked|blocked|delivery_hold
failure|error|unknown_failure
escalated|error|escalated
cancelled|error|cancelled
EOF
}
setup_env '/maintain'
t "accounted workflow outcomes map to governor outcomes" outcome_mappings

terminal_reason_contract() {
  FAKE_OUTCOME=success FAKE_REASON=unknown_failure; export FAKE_OUTCOME FAKE_REASON
  run_wrapper || return 1
  jq -e '.terminal_status=="invalid" and .outcome=="error"' "$TD/direct.json" >/dev/null || return 1
  FAKE_OUTCOME=failure FAKE_REASON=""; export FAKE_OUTCOME FAKE_REASON
  run_wrapper || return 1
  jq -e '.terminal_status=="invalid" and .outcome=="error"' "$TD/direct.json" >/dev/null || return 1
  FAKE_OUTCOME=failure FAKE_REASON=vendor_failure; export FAKE_OUTCOME FAKE_REASON
  run_wrapper || return 1
  jq -e '.terminal_status=="invalid" and .outcome=="error"' "$TD/direct.json" >/dev/null
}
setup_env '/maintain'
t "schema-v2 account validation binds outcomes to registered reasons" terminal_reason_contract

unsupported_legacy() {
  FAKE_SCHEMA=1; export FAKE_SCHEMA
  ENGINE_OUTPUT='MC-BLOCKED recheck_after=10 reason=waiting\n'; export ENGINE_OUTPUT
  run_wrapper || return 1
  jq -e '.terminal_status=="legacy-blocked" and .workflow_outcome=="blocked" and .outcome=="blocked"' "$TD/direct.json" >/dev/null || return 1
  [ -s "$ENGINE_CAPTURE" ] || return 1
  ENGINE_OUTPUT='prose MC-BLOCKED reason=waiting\n'; export ENGINE_OUTPUT
  run_wrapper || return 1
  jq -e '.terminal_status=="unsupported" and .outcome=="ok"' "$TD/direct.json" >/dev/null
}
setup_env '/maintain'
t "unsupported schema uses only anchored legacy sentinel for one release" unsupported_legacy

invalid_no_fallback() {
  FAKE_ACCOUNT_MODE=malformed; ENGINE_OUTPUT='MC-BLOCKED reason=must-not-win\n'
  export FAKE_ACCOUNT_MODE ENGINE_OUTPUT
  run_wrapper || return 1
  jq -e '.terminal_status=="invalid" and .outcome=="error"' "$TD/direct.json" >/dev/null
}
setup_env '/maintain'
t "invalid v2 terminal never falls back to MC-BLOCKED" invalid_no_fallback

governor_precedence() {
  local log="$TD/precedence.log"
  : > "$log"
  [ "$(lib_call governor_report e p 75 "$log" true invalid failure x)" = deferred ] || return 1
  printf '429 rate limit\n' > "$log"
  [ "$(lib_call governor_report e p 1 "$log" false accounted success '')" = rate-limit ] || return 1
  : > "$log"
  [ "$(lib_call governor_report e p 124 "$log" false accounted blocked timeout)" = timeout ] || return 1
}
setup_env '/maintain'
t "delivery hold, rate limit, and timeout precede terminal truth" governor_precedence

structured_block_duration() {
  local log="$TD/structured-block.log"
  export MC_NOW_EPOCH=1000
  printf 'MC-BLOCKED recheck_after=10 reason=untrusted-log-reason\n' > "$log"
  [ "$(lib_call governor_report e p 0 "$log" false accounted blocked delivery_hold)" = blocked ] || return 1
  jq -e '.projects.p.blocked_until==1600 and .projects.p.blocked_reason=="delivery_hold"' \
    "$TD/state/state.json" >/dev/null || return 1
  export MC_NOW_EPOCH=2000
  printf 'MC-BLOCKED reason=untrusted recheck_after=10\n' > "$log"
  [ "$(lib_call governor_report e p 0 "$log" false accounted blocked receipt_conflict)" = blocked ] || return 1
  jq -e '.projects.p.blocked_until==23600 and .projects.p.blocked_reason=="receipt_conflict"' \
    "$TD/state/state.json" >/dev/null || return 1
  export MC_NOW_EPOCH=3000
  printf 'MC-BLOCKED recheck_after=1 reason=short\n' > "$log"
  [ "$(lib_call governor_report e p 0 "$log" false accounted blocked timeout)" = blocked ] || return 1
  jq -e '.projects.p.blocked_until==3300 and .projects.p.blocked_reason=="timeout"' \
    "$TD/state/state.json" >/dev/null
}
setup_env '/maintain'
t "structured block keeps typed reason and accepts only bounded anchored recheck syntax" structured_block_duration
unset MC_NOW_EPOCH

cache_precedence() {
  run_wrapper || return 1
  grep -q '/2.10.0/scripts/agent-events.sh|container=0|schema-version' "$HELPER_CALLS" || return 1
  mkdir -p "$TD/repo/plugins/saas-startup-team/scripts"
  cat > "$TD/repo/plugins/saas-startup-team/scripts/agent-events.sh" <<'SH'
#!/bin/bash
printf 'UNTRUSTED_REPO_HELPER\n' >> "$HELPER_CALLS"
exit 99
SH
  chmod +x "$TD/repo/plugins/saas-startup-team/scripts/agent-events.sh"
  : > "$HELPER_CALLS"
  run_wrapper || return 1
  grep -q '/2.10.0/scripts/agent-events.sh|container=0|schema-version' "$HELPER_CALLS" &&
    ! grep -q 'UNTRUSTED_REPO_HELPER' "$HELPER_CALLS"
}
setup_env '/maintain'
t "registered install wins and target-worktree helpers never execute" cache_precedence

claude_inventory_binding() {
  run_wrapper || return 1
  grep -q "$CLAUDE_HOME/plugins/cache/paat-plugins/saas-startup-team/2.10.0/scripts/agent-events.sh|container=0|schema-version" \
    "$HELPER_CALLS" &&
    jq -e '.terminal_status=="accounted" and .outcome=="ok"' "$TD/direct.json" >/dev/null
}
setup_env '/maintain' 'claude -p {prompt}'
t "Claude workflows bind the unique enabled user install" claude_inventory_binding

failed_binding_skips_engine() {
  FAKE_CODEX_PLUGIN_ENABLED=false; export FAKE_CODEX_PLUGIN_ENABLED
  run_wrapper || return 1
  [ ! -s "$ENGINE_CAPTURE" ] && [ ! -s "$HELPER_CALLS" ] &&
    jq -e '.terminal_status=="invalid" and .outcome=="error" and .exit_code==1 and
      .workflow_outcome==null and .total_tokens==null' "$TD/direct.json" >/dev/null &&
    grep -q 'workflow helper preflight failed; refusing model dispatch' "$TD/direct.log"
}
setup_env '/maintain'
t "failed helper binding emits an error dispatch without running the model" failed_binding_skips_engine

higher_cache_tamper() {
  FAKE_CACHE_TAMPER=higher; export FAKE_CACHE_TAMPER
  run_wrapper || return 1
  jq -e '.terminal_status=="accounted" and .outcome=="ok"' "$TD/direct.json" >/dev/null || return 1
  FAKE_CACHE_TAMPER=""; export FAKE_CACHE_TAMPER
  run_wrapper || return 1
  jq -e '.terminal_status=="accounted" and .outcome=="ok"' "$TD/direct.json" >/dev/null &&
    grep -q '/2.10.0/scripts/agent-events.sh|container=0|schema-version' "$HELPER_CALLS" &&
    [ "$(wc -l < "$ENGINE_CAPTURE")" -eq 2 ] &&
    ! grep -q 'MALICIOUS_HIGHER_EXECUTED' "$HELPER_CALLS"
}
setup_env '/maintain'
t "registered binding ignores an unregistered higher cache on later passes" higher_cache_tamper

bound_cache_tamper() {
  FAKE_CACHE_TAMPER=bound; export FAKE_CACHE_TAMPER
  run_wrapper || return 1
  jq -e '.terminal_status=="invalid" and .outcome=="error"' "$TD/direct.json" >/dev/null &&
    ! grep -q 'MALICIOUS_BOUND_EXECUTED' "$HELPER_CALLS"
}
setup_env '/maintain'
t "bound helper checksum change fails before execution" bound_cache_tamper

invalid_run_id() {
  ! run_wrapper not-canonical && [ ! -f "$TD/direct.json" ]
}
setup_env '/maintain'
t "wrapper rejects a supplied noncanonical run ID" invalid_run_id

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
