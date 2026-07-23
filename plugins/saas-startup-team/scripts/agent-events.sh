#!/usr/bin/env bash
# Append and read privacy-safe delivery events.
#
# append --run-id ID --command CODE --phase CODE --surface claude|codex|script
#        --profile mechanical|light|standard|deep --writer-id ID [--once] [fields...]
# read [--events FILE] [--legacy-root DIR]
# terminal --run-id ID [--events FILE]
# terminals [--events FILE]
# account --run-id ID --duration-ms N [--total-tokens N] [--events FILE]
# new-run-id
# schema-version

set -euo pipefail

SCHEMA_VERSION=2
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROUTING_SCHEMA_VERSION=$(bash "$SCRIPT_DIR/delivery-route.sh" schema-version 2>/dev/null | jq -er '.schema_version') || {
  echo "agent-events: could not resolve delivery routing schema" >&2
  exit 2
}

usage() {
  echo "usage: agent-events.sh append --run-id ID --command CODE --phase CODE --surface SURFACE --profile PROFILE --writer-id ID [--once] [options]" >&2
  echo "       agent-events.sh read [--events FILE] [--legacy-root DIR]" >&2
  echo "       agent-events.sh terminal --run-id ID [--events FILE]" >&2
  echo "       agent-events.sh terminals [--events FILE]" >&2
  echo "       agent-events.sh account --run-id ID --duration-ms N [--total-tokens N] [--events FILE]" >&2
  echo "       agent-events.sh new-run-id | schema-version" >&2
  exit 2
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

primary_worktree_root() {
  local current records record root common candidate_common
  current=$(git rev-parse --show-toplevel 2>/dev/null) || { pwd; return 0; }
  current=$(cd -- "$current" && pwd -P) || return 1
  common=$(git -C "$current" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in /*) : ;; *) common="$current/$common" ;; esac
  common=$(cd -- "$common" && pwd -P) || return 1
  records=$(mktemp) || return 1
  if ! git -C "$current" worktree list --porcelain -z > "$records"; then
    rm -f -- "$records"
    return 1
  fi
  root=""
  while IFS= read -r -d '' record; do
    case "$record" in 'worktree '*) root=${record#worktree }; break ;; esac
  done < "$records"
  rm -f -- "$records"
  [ -n "$root" ] || return 1
  root=$(cd -- "$root" && pwd -P) || return 1
  candidate_common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$candidate_common" in /*) : ;; *) candidate_common="$root/$candidate_common" ;; esac
  candidate_common=$(cd -- "$candidate_common" && pwd -P) || return 1
  [ "$candidate_common" = "$common" ] || return 1
  printf '%s\n' "$root"
}

default_events_file() {
  local root
  root=$(primary_worktree_root)
  printf '%s\n' "$root/.startup/runs/agent-events.jsonl"
}

resolve_events_file() {
  local events_file="$1"
  [ -n "$events_file" ] || events_file=$(default_events_file)
  case "$events_file" in /*) : ;; *) events_file="$PWD/$events_file" ;; esac
  printf '%s\n' "$events_file"
}

safe_path_string() {
  case "$1" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*|../*|*/../*|*/..|./*|*/./*|*/.) return 1 ;;
  esac
}

ensure_real_directory() {
  local target="$1" create="${2:-0}" current=/ rel part
  local parts=()
  [[ "$target" == /* ]] && safe_path_string "$target" || return 1
  rel=${target#/}
  IFS=/ read -r -a parts <<< "$rel"
  for part in "${parts[@]}"; do
    [ -n "$part" ] && [ "$part" != . ] && [ "$part" != .. ] || return 1
    current="${current%/}/$part"
    [ ! -L "$current" ] || return 1
    if [ -e "$current" ]; then
      [ -d "$current" ] || return 1
      [ "$(cd "$current" && pwd -P)" = "$current" ] || return 1
    elif [ "$create" -eq 1 ]; then
      mkdir -- "$current" || return 1
      [ -d "$current" ] && [ ! -L "$current" ] \
        && [ "$(cd "$current" && pwd -P)" = "$current" ] || return 1
    else
      return 0
    fi
  done
}

safe_append_target() {
  local events_file="$1" parent leaf candidate
  [[ "$events_file" == /* ]] && safe_path_string "$events_file" || return 1
  parent=$(dirname -- "$events_file"); leaf=$(basename -- "$events_file")
  [ "$leaf" != . ] && [ "$leaf" != .. ] || return 1
  ensure_real_directory "$parent" 1 || return 1
  for candidate in "$events_file" "${events_file}.identity-key" "${events_file}.lock"; do
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
    fi
  done
}

valid_code() { [[ "$1" =~ ^[a-z][a-z0-9_.:-]{0,63}$ ]]; }
valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$ ]]; }
valid_model() { [ -z "$1" ] || [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$ ]]; }
valid_sha() { [ -z "$1" ] || [[ "$1" =~ ^[0-9a-fA-F]{7,64}$ ]]; }
valid_time() { [ -z "$1" ] || [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }
valid_uint_or_empty() { [ -z "$1" ] || [[ "$1" =~ ^[0-9]+$ ]]; }
valid_status() { [ -z "$1" ] || [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; }
valid_terminal_reason_code() {
  case "$1" in
    invalid_workflow_state|context_binding_violation|false_success|probe_failed|triage_failed|delivery_failed|verification_failed|lease_conflict|receipt_conflict|budget_exhausted|timeout|rate_limited|delivery_hold|cancelled|escalated|unknown_failure) return 0 ;;
    *) return 1 ;;
  esac
}

random_hex() {
  local bytes="$1" value
  value=$(od -An -N"$bytes" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || value=""
  if [ "${#value}" -ne "$((bytes * 2))" ]; then
    value=$(printf '%s\037%s\037%s\037%s\n' "$(date +%s%N 2>/dev/null || date +%s)" "$$" "${RANDOM:-0}" "$bytes" \
      | sha256_stream) || return 1
  fi
  [[ "$value" =~ ^[0-9a-f]+$ ]] || return 1
  printf '%s\n' "$value"
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "agent-events: sha256sum or shasum is required" >&2
    return 2
  fi
}

identity_key_for_append() {
  local events_file="$1" key_file="${1}.identity-key" key old_umask tmp
  if [ -e "$key_file" ] || [ -L "$key_file" ]; then
    [ -f "$key_file" ] && [ ! -L "$key_file" ] || {
      echo "agent-events: unsafe identity key for $events_file" >&2
      return 1
    }
  fi
  if [ ! -s "$key_file" ]; then
    key=$(random_hex 32) || return 1
    old_umask=$(umask); umask 077
    tmp="${key_file}.$$.$RANDOM.tmp"
    printf '%s\n' "$key" > "$tmp"
    mv -f -- "$tmp" "$key_file"
    umask "$old_umask"
  fi
  IFS= read -r key < "$key_file" || return 1
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] || {
    echo "agent-events: invalid identity key for $events_file" >&2
    return 1
  }
  chmod 600 "$key_file" 2>/dev/null || true
  printf '%s\n' "$key"
}

identity_key_for_read() {
  local events_file="$1" key_file="${1}.identity-key" key
  if [ -s "$key_file" ]; then
    IFS= read -r key < "$key_file" || return 1
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] || {
      echo "agent-events: invalid identity key for $events_file" >&2
      return 1
    }
    printf '%s\n' "$key"
  else
    random_hex 32
  fi
}

opaque_id() {
  local kind="$1" raw="$2" key="$3" digest
  if [[ "$raw" =~ ^${kind}-[0-9a-f]{32}$ ]]; then
    printf '%s\n' "$raw"
    return 0
  fi
  digest=$(printf '%s\037%s\037%s\n' "$key" "$kind" "$raw" | sha256_stream) || return 1
  printf '%s-%s\n' "$kind" "${digest:0:32}"
}

normalize_event_identity() {
  local key="$1" line raw_run raw_parent raw_writer safe_run safe_parent safe_writer
  line=$(cat)
  raw_run=$(jq -r '.run_id' <<< "$line") || return 1
  raw_parent=$(jq -r '.parent_run_id // empty' <<< "$line") || return 1
  raw_writer=$(jq -r '.writer_id' <<< "$line") || return 1
  safe_run=$(opaque_id run "$raw_run" "$key") || return 1
  safe_parent=""
  [ -z "$raw_parent" ] || safe_parent=$(opaque_id run "$raw_parent" "$key") || return 1
  safe_writer=$(opaque_id writer "$raw_writer" "$key") || return 1
  jq -c --arg run_id "$safe_run" --arg parent_run_id "$safe_parent" --arg writer_id "$safe_writer" \
    '.run_id=$run_id | .parent_run_id=(if $parent_run_id == "" then null else $parent_run_id end)
      | .writer_id=$writer_id | .terminal_reason=(.terminal_reason // null) | .total_tokens=(.total_tokens // null)' <<< "$line"
}

normalize_event_dimensions() {
  jq -c '
    def norm_code($allowed):
      if type != "string" then "other"
      else . as $v | if ($allowed | index($v)) != null then $v else "other" end
      end;
    def commands: [
      "ads","bootstrap","codex-run-role","digest","goal-deliver","growth","harvest","improve","investigate",
      "lawyer","learnings-compress","learnings-migrate","lessons-deliver","lessons-review","maintain","maintain-loop",
      "market-scout","monitor","monitor-nightly","nudge","operate","pause","replay-abandoned","session-insights",
      "standard-medium-eval","startup","status","tweak","ux-test","validate-experiment","legacy"
    ];
    def phases: [
      "browser-operator","browser-operator-pro","business-brief","business-founder","business-founder-maintain","business-qa",
      "checks","commit","delivery","delivery-supervisor","deployment","discovery","escalation","firewall","growth-hacker",
      "handoff","implementation","implementation-controller","implementation-fix","incident-investigator","issue-outcome",
      "lawyer","legacy-artifact","lesson-outcome","maintain-triage","market-research","mechanical","merge","mutation",
      "pass-outcome","pr","qa","replay","rollback","routing","selection","session-replay","supervisor","support-triage",
      "tech-founder","tech-founder-claude","tech-founder-claude-maintain","tech-founder-codex","tech-founder-codex-maintain",
      "triage","tribunal","ux-tester","verdict","work-unit"
    ];
    def reasons: [
      "ambiguous_rca_or_arbitration","autonomous_exact_text","autonomous_light_exclusion","bounded_read_only",
      "diff_behavioral_code","diff_behavioral_ui_code","diff_bounded_text","diff_bounded_ui_text_or_css",
      "diff_containment_exceeded","diff_ignored_sensitive_path","diff_legal_judgment","diff_product_judgment","diff_sensitive_surface",
      "diff_tests_dependencies_workflows","diff_untracked_file","empty_diff","interactive_behavior_excluded",
      "interactive_nonbehavioral_tweak","interactive_scope_uncertain","legacy_artifact","product_judgment",
      "routine_scoped_work","script_only","sensitive_accounting_reporting","sensitive_architecture_concurrency",
      "sensitive_data_migration","sensitive_legal","sensitive_payment_pricing","sensitive_security_auth",
      "sensitive_surface_vocabulary","terra_unavailable_fallback"
    ];
    def terminal_reasons: [
      "invalid_workflow_state","context_binding_violation","false_success",
      "probe_failed","triage_failed","delivery_failed","verification_failed",
      "lease_conflict","receipt_conflict","budget_exhausted","timeout","rate_limited",
      "delivery_hold","cancelled","escalated","unknown_failure"
    ];
    def norm_provider:
      if . == null or . == "" then null
      else (ascii_downcase) as $v
      | if ["openai","anthropic","google","xai","local"] | index($v) then $v else "other" end
      end;
    def norm_model:
      if . == null or . == "" then null
      else (ascii_downcase) as $v
      | if $v == "gpt-5.6-sol" or $v == "gpt-5.6-terra" then $v
        elif $v == "fable" or ($v | test("^claude-fable(-[0-9]+)*$")) then "claude-fable"
        elif $v == "opus" or ($v | test("^claude-opus(-[0-9]+)*$")) then "claude-opus"
        elif $v == "sonnet" or ($v | test("^claude-sonnet(-[0-9]+)*$")) then "claude-sonnet"
        elif $v == "haiku" or ($v | test("^claude-haiku(-[0-9]+)*$")) then "claude-haiku"
        elif ($v | test("^gemini-[0-9]+([.-][a-z0-9]+)*$")) then "gemini"
        elif ($v | test("^grok-[0-9]+([.-][a-z0-9]+)*$")) then "grok"
        else "other"
        end
      end;
    def norm_effort:
      if . == null or . == "" then null
      else (ascii_downcase) as $v
      | if ["low","medium","high","xhigh","max"] | index($v) then $v else "other" end
      end;
    def norm_profile:
      if . == null or . == "" then null
      else (ascii_downcase) as $v
      | if ["mechanical","light","standard","deep"] | index($v) then $v else "other" end
      end;
    def norm_status:
      if . == null or . == "" then null
      else (ascii_downcase) as $v
      | if ["not_run","not_started","not_created","not_applicable","not_needed","pending","passed","failed","blocked","skipped","incomplete","draft","open","closed","merged","rolled_back","cancelled","success"] | index($v)
        then $v else "other" end
      end;
    def norm_outcome:
      if . == null or . == "" then null
      else (ascii_downcase) as $v
      | if ["incomplete","success","failure","blocked","skipped","no-op","escalated","cancelled"] | index($v)
        then $v else "other" end
      end;
    .command |= norm_code(commands)
    | .phase |= norm_code(phases)
    | .surface |= norm_code(["claude","codex","script","legacy"])
    | .routing_reasons |= (if type == "array" then map(norm_code(reasons)) | unique else ["other"] end)
    | .profile |= norm_profile
    | .outcome |= norm_outcome
    | .requested_provider |= norm_provider | .effective_provider |= norm_provider
    | .requested_model |= norm_model | .effective_model |= norm_model
    | .requested_effort |= norm_effort | .effective_effort |= norm_effort
    | .checks |= norm_status | .qa |= norm_status | .tribunal |= norm_status
    | .pr |= norm_status | .merge |= norm_status | .deployment |= norm_status | .rollback |= norm_status
    | .terminal_reason |= (if . == null or . == "" then null else norm_code(terminal_reasons) end)
  '
}

append_event() {
  local run_id="" parent_run_id="" command="" phase="" surface="" profile="" writer_id=""
  local event_type="started" attempt=1 started_at="" finished_at="" duration_ms=""
  local requested_provider="" requested_model="" requested_effort=""
  local effective_provider="" effective_model="" effective_effort=""
  local tokens_before="" tokens_after="" input_tokens="" output_tokens="" cached_input_tokens="" cost_microunits="" total_tokens=""
  local checks="" qa="" tribunal="" pr="" merge="" deployment="" rollback=""
  local outcome="incomplete" terminal_reason="" events_file="" base_sha="" result_sha="" recorded_at payload lock_file identity_key
  local append_once=0 existing existing_count payload_semantic existing_semantic
  local reasons=() reasons_json

  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id) [ "$#" -ge 2 ] || usage; run_id="$2"; shift 2 ;;
      --parent-run-id) [ "$#" -ge 2 ] || usage; parent_run_id="$2"; shift 2 ;;
      --command) [ "$#" -ge 2 ] || usage; command="$2"; shift 2 ;;
      --phase) [ "$#" -ge 2 ] || usage; phase="$2"; shift 2 ;;
      --surface) [ "$#" -ge 2 ] || usage; surface="$2"; shift 2 ;;
      --profile) [ "$#" -ge 2 ] || usage; profile="$2"; shift 2 ;;
      --routing-reason) [ "$#" -ge 2 ] || usage; reasons+=("$2"); shift 2 ;;
      --writer-id) [ "$#" -ge 2 ] || usage; writer_id="$2"; shift 2 ;;
      --event-type) [ "$#" -ge 2 ] || usage; event_type="$2"; shift 2 ;;
      --attempt) [ "$#" -ge 2 ] || usage; attempt="$2"; shift 2 ;;
      --started-at) [ "$#" -ge 2 ] || usage; started_at="$2"; shift 2 ;;
      --finished-at) [ "$#" -ge 2 ] || usage; finished_at="$2"; shift 2 ;;
      --duration-ms) [ "$#" -ge 2 ] || usage; duration_ms="$2"; shift 2 ;;
      --requested-provider) [ "$#" -ge 2 ] || usage; requested_provider="$2"; shift 2 ;;
      --requested-model) [ "$#" -ge 2 ] || usage; requested_model="$2"; shift 2 ;;
      --requested-effort) [ "$#" -ge 2 ] || usage; requested_effort="$2"; shift 2 ;;
      --effective-provider) [ "$#" -ge 2 ] || usage; effective_provider="$2"; shift 2 ;;
      --effective-model) [ "$#" -ge 2 ] || usage; effective_model="$2"; shift 2 ;;
      --effective-effort) [ "$#" -ge 2 ] || usage; effective_effort="$2"; shift 2 ;;
      --tokens-available-before) [ "$#" -ge 2 ] || usage; tokens_before="$2"; shift 2 ;;
      --tokens-available-after) [ "$#" -ge 2 ] || usage; tokens_after="$2"; shift 2 ;;
      --input-tokens) [ "$#" -ge 2 ] || usage; input_tokens="$2"; shift 2 ;;
      --output-tokens) [ "$#" -ge 2 ] || usage; output_tokens="$2"; shift 2 ;;
      --cached-input-tokens) [ "$#" -ge 2 ] || usage; cached_input_tokens="$2"; shift 2 ;;
      --cost-microunits) [ "$#" -ge 2 ] || usage; cost_microunits="$2"; shift 2 ;;
      --total-tokens) [ "$#" -ge 2 ] || usage; total_tokens="$2"; shift 2 ;;
      --checks) [ "$#" -ge 2 ] || usage; checks="$2"; shift 2 ;;
      --qa) [ "$#" -ge 2 ] || usage; qa="$2"; shift 2 ;;
      --tribunal) [ "$#" -ge 2 ] || usage; tribunal="$2"; shift 2 ;;
      --pr) [ "$#" -ge 2 ] || usage; pr="$2"; shift 2 ;;
      --merge) [ "$#" -ge 2 ] || usage; merge="$2"; shift 2 ;;
      --deployment) [ "$#" -ge 2 ] || usage; deployment="$2"; shift 2 ;;
      --rollback) [ "$#" -ge 2 ] || usage; rollback="$2"; shift 2 ;;
      --outcome) [ "$#" -ge 2 ] || usage; outcome="$2"; shift 2 ;;
      --terminal-reason) [ "$#" -ge 2 ] || usage; terminal_reason="$2"; shift 2 ;;
      --base-sha) [ "$#" -ge 2 ] || usage; base_sha="$2"; shift 2 ;;
      --result-sha) [ "$#" -ge 2 ] || usage; result_sha="$2"; shift 2 ;;
      --events) [ "$#" -ge 2 ] || usage; events_file="$2"; shift 2 ;;
      --once) append_once=1; shift ;;
      *) usage ;;
    esac
  done

  valid_id "$run_id" || { echo "agent-events: invalid --run-id" >&2; exit 2; }
  [ -z "$parent_run_id" ] || valid_id "$parent_run_id" || { echo "agent-events: invalid --parent-run-id" >&2; exit 2; }
  valid_code "$command" || { echo "agent-events: invalid --command" >&2; exit 2; }
  valid_code "$phase" || { echo "agent-events: invalid --phase" >&2; exit 2; }
  case "$surface" in claude|codex|script) : ;; *) echo "agent-events: invalid --surface" >&2; exit 2 ;; esac
  case "$profile" in mechanical|light|standard|deep) : ;; *) echo "agent-events: invalid --profile" >&2; exit 2 ;; esac
  valid_id "$writer_id" || { echo "agent-events: invalid --writer-id" >&2; exit 2; }
  case "$event_type" in started|progress|completed|accounted) : ;; *) echo "agent-events: invalid --event-type" >&2; exit 2 ;; esac
  [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || { echo "agent-events: invalid --attempt" >&2; exit 2; }
  valid_time "$started_at" && valid_time "$finished_at" || { echo "agent-events: timestamps must be UTC ISO seconds" >&2; exit 2; }
  for value in "$duration_ms" "$tokens_before" "$tokens_after" "$input_tokens" "$output_tokens" "$cached_input_tokens" "$cost_microunits" "$total_tokens"; do
    valid_uint_or_empty "$value" || { echo "agent-events: numeric metrics must be non-negative integers" >&2; exit 2; }
  done
  for value in "$requested_provider" "$requested_model" "$requested_effort" "$effective_provider" "$effective_model" "$effective_effort"; do
    valid_model "$value" || { echo "agent-events: invalid provider/model/effort value" >&2; exit 2; }
  done
  for value in "$checks" "$qa" "$tribunal" "$pr" "$merge" "$deployment" "$rollback" "$outcome"; do
    valid_status "$value" || { echo "agent-events: invalid status value" >&2; exit 2; }
  done
  case "$outcome" in incomplete|success|failure|blocked|skipped|no-op|escalated|cancelled) : ;; *) echo "agent-events: invalid --outcome" >&2; exit 2 ;; esac
  if { [ "$event_type" = completed ] || [ "$event_type" = accounted ]; } && [ "$outcome" = incomplete ]; then
    echo "agent-events: terminal events require a terminal outcome" >&2
    exit 2
  fi
  if [ "$event_type" != completed ] && [ "$event_type" != accounted ] && [ "$outcome" != incomplete ]; then
    echo "agent-events: nonterminal events require outcome=incomplete" >&2
    exit 2
  fi
  if [ "$append_once" -eq 1 ] && [ "$event_type" != completed ]; then
    echo "agent-events: --once requires a completed event" >&2
    exit 2
  fi
  valid_sha "$base_sha" && valid_sha "$result_sha" || { echo "agent-events: invalid commit SHA" >&2; exit 2; }
  [ -z "$terminal_reason" ] || valid_code "$terminal_reason" || { echo "agent-events: invalid --terminal-reason" >&2; exit 2; }
  if [ -z "$parent_run_id" ] && [ "$phase" = pass-outcome ] \
     && { [ "$event_type" = completed ] || [ "$event_type" = accounted ]; }; then
    case "$outcome" in
      success|no-op|skipped)
        [ -z "$terminal_reason" ] || {
          echo "agent-events: successful root pass outcomes require a null terminal reason" >&2
          exit 2
        }
        ;;
      blocked|failure|escalated|cancelled)
        [ -n "$terminal_reason" ] && valid_terminal_reason_code "$terminal_reason" || {
          echo "agent-events: unsuccessful root pass outcomes require a registered terminal reason" >&2
          exit 2
        }
        ;;
    esac
  fi
  local reason
  for reason in "${reasons[@]}"; do
    valid_code "$reason" || { echo "agent-events: invalid routing reason" >&2; exit 2; }
  done

  recorded_at=$(now_iso)
  [ -n "$started_at" ] || started_at="$recorded_at"
  [ "$event_type" != completed ] || [ -n "$finished_at" ] || finished_at="$recorded_at"
  reasons_json=$(printf '%s\n' "${reasons[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')

  payload=$(jq -cn \
    --argjson schema_version "$SCHEMA_VERSION" --argjson routing_schema_version "$ROUTING_SCHEMA_VERSION" \
    --arg run_id "$run_id" --arg parent_run_id "$parent_run_id" --arg command "$command" --arg phase "$phase" --arg surface "$surface" \
    --arg profile "$profile" --argjson routing_reasons "$reasons_json" --arg writer_id "$writer_id" \
    --arg event_type "$event_type" --argjson attempt "$attempt" --arg recorded_at "$recorded_at" \
    --arg started_at "$started_at" --arg finished_at "$finished_at" --arg duration_ms "$duration_ms" \
    --arg requested_provider "$requested_provider" --arg requested_model "$requested_model" --arg requested_effort "$requested_effort" \
    --arg effective_provider "$effective_provider" --arg effective_model "$effective_model" --arg effective_effort "$effective_effort" \
    --arg tokens_before "$tokens_before" --arg tokens_after "$tokens_after" --arg input_tokens "$input_tokens" \
    --arg output_tokens "$output_tokens" --arg cached_input_tokens "$cached_input_tokens" --arg cost_microunits "$cost_microunits" --arg total_tokens "$total_tokens" \
    --arg checks "$checks" --arg qa "$qa" --arg tribunal "$tribunal" --arg pr "$pr" --arg merge "$merge" \
    --arg deployment "$deployment" --arg rollback "$rollback" --arg outcome "$outcome" --arg terminal_reason "$terminal_reason" \
    --arg base_sha "$base_sha" --arg result_sha "$result_sha" '
      def ns: if . == "" then null else tonumber end;
      def ss: if . == "" then null else . end;
      {
        schema_version:$schema_version,routing_schema_version:$routing_schema_version,
        run_id:$run_id,parent_run_id:($parent_run_id|ss),command:$command,phase:$phase,surface:$surface,profile:$profile,
        routing_reasons:$routing_reasons,writer_id:$writer_id,event_type:$event_type,attempt:$attempt,
        recorded_at:$recorded_at,started_at:$started_at,finished_at:($finished_at|ss),duration_ms:($duration_ms|ns),
        requested_provider:($requested_provider|ss),requested_model:($requested_model|ss),requested_effort:($requested_effort|ss),
        effective_provider:($effective_provider|ss),effective_model:($effective_model|ss),effective_effort:($effective_effort|ss),
        tokens_available_before:($tokens_before|ns),tokens_available_after:($tokens_after|ns),
        input_tokens:($input_tokens|ns),output_tokens:($output_tokens|ns),cached_input_tokens:($cached_input_tokens|ns),cost_microunits:($cost_microunits|ns),total_tokens:($total_tokens|ns),
        checks:($checks|ss),qa:($qa|ss),tribunal:($tribunal|ss),pr:($pr|ss),merge:($merge|ss),
        deployment:($deployment|ss),rollback:($rollback|ss),outcome:$outcome,terminal_reason:($terminal_reason|ss),
        base_sha:($base_sha|ss),result_sha:($result_sha|ss),source_schema_version:$schema_version
      }')

  # Inspect caller values before unknown public dimensions are collapsed to "other".
  # shellcheck source=pii-gate.sh
  . "$SCRIPT_DIR/pii-gate.sh" || { echo "agent-events: PII gate unavailable" >&2; exit 2; }
  if pii_hit "$payload"; then
    echo "agent-events: event rejected by secret/PII gate" >&2
    exit 3
  fi
  payload=$(printf '%s\n' "$payload" | normalize_event_dimensions) || {
    echo "agent-events: dimension normalization failed" >&2
    exit 3
  }

  events_file=$(resolve_events_file "$events_file")
  safe_append_target "$events_file" || {
    echo "agent-events: unsafe event destination" >&2
    exit 3
  }
  lock_file="${events_file}.lock"
  command -v flock >/dev/null 2>&1 || { echo "agent-events: flock is required" >&2; exit 2; }
  exec 9>>"$lock_file"
  flock 9
  identity_key=$(identity_key_for_append "$events_file") || {
    flock -u 9
    echo "agent-events: could not initialize opaque identities" >&2
    exit 3
  }
  payload=$(printf '%s\n' "$payload" | normalize_event_identity "$identity_key") || {
    flock -u 9
    echo "agent-events: identity normalization failed" >&2
    exit 3
  }
  if [ "$append_once" -eq 1 ] && [ -s "$events_file" ]; then
    existing=$(jq -c --arg run_id "$(jq -r .run_id <<<"$payload")" \
      --arg writer_id "$(jq -r .writer_id <<<"$payload")" \
      --arg command "$(jq -r .command <<<"$payload")" \
      --arg phase "$(jq -r .phase <<<"$payload")" \
      --argjson attempt "$(jq -r .attempt <<<"$payload")" '
        select(.run_id == $run_id and .writer_id == $writer_id
          and .command == $command and .phase == $phase
          and .event_type == "completed" and .attempt == $attempt)
      ' "$events_file") || {
        flock -u 9
        echo "agent-events: cannot inspect existing event identities" >&2
        exit 3
      }
    existing_count=$(printf '%s\n' "$existing" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ "$existing_count" -gt 1 ]; then
      flock -u 9
      echo "agent-events: duplicate exactly-once event identity already exists" >&2
      exit 3
    fi
    if [ "$existing_count" -eq 1 ]; then
      payload_semantic=$(jq -Sc 'del(.recorded_at,.started_at,.finished_at,.duration_ms)' <<<"$payload")
      existing_semantic=$(jq -Sc 'del(.recorded_at,.started_at,.finished_at,.duration_ms)' <<<"$existing")
      if [ "$payload_semantic" != "$existing_semantic" ]; then
        flock -u 9
        echo "agent-events: conflicting exactly-once event identity" >&2
        exit 3
      fi
      flock -u 9
      printf '%s\n' "$existing"
      return 0
    fi
  fi
  printf '%s\n' "$payload" >> "$events_file"
  flock -u 9
  printf '%s\n' "$payload"
}

validate_event_line() {
  jq -ce '
    def uint: type == "number" and . >= 0 and floor == .;
    def nullable_string: . == null or type == "string";
    def nullable_uint: . == null or uint;
    def nullable_time: . == null or (type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"));
    def nullable_sha: . == null or (type == "string" and test("^[0-9a-fA-F]{7,64}$"));
    def registered_terminal_reason:
      . != null and IN(
        "invalid_workflow_state","context_binding_violation","false_success",
        "probe_failed","triage_failed","delivery_failed","verification_failed",
        "lease_conflict","receipt_conflict","budget_exhausted","timeout","rate_limited",
        "delivery_hold","cancelled","escalated","unknown_failure");
    def v1_keys: [
      "schema_version","routing_schema_version","run_id","command","phase","surface","profile","routing_reasons",
      "writer_id","event_type","attempt","recorded_at","started_at","finished_at","duration_ms",
      "requested_provider","requested_model","requested_effort","effective_provider","effective_model","effective_effort",
      "tokens_available_before","tokens_available_after","input_tokens","output_tokens","cached_input_tokens","cost_microunits",
      "checks","qa","tribunal","pr","merge","deployment","rollback","outcome","base_sha","result_sha","source_schema_version"
    ];
    def v2_keys: v1_keys + ["parent_run_id","terminal_reason","total_tokens"];
    . as $event |
    type == "object" and
    (.schema_version == 1 or .schema_version == 2) and
    (.routing_schema_version | uint) and
    (.run_id | type == "string") and
    (.command | type == "string") and
    (.phase | type == "string") and
    (.surface | type == "string") and
    (.profile | nullable_string) and
    (.routing_reasons | type == "array" and all(.[]; type == "string")) and
    (.writer_id | type == "string") and
    (.event_type | . == "started" or . == "progress" or . == "completed" or
      (. == "accounted" and $event.schema_version == 2)) and
    (.attempt | uint and . >= 1) and
    (.recorded_at | nullable_time) and (.started_at | nullable_time) and (.finished_at | nullable_time) and
    (.duration_ms | nullable_uint) and
    (.requested_provider | nullable_string) and (.requested_model | nullable_string) and (.requested_effort | nullable_string) and
    (.effective_provider | nullable_string) and (.effective_model | nullable_string) and (.effective_effort | nullable_string) and
    (.tokens_available_before | nullable_uint) and (.tokens_available_after | nullable_uint) and
    (.input_tokens | nullable_uint) and (.output_tokens | nullable_uint) and (.cached_input_tokens | nullable_uint) and
    (.cost_microunits | nullable_uint) and
    (if .schema_version == 2 then (.parent_run_id | nullable_string) and (.terminal_reason | nullable_string) and (.total_tokens | nullable_uint)
     else (has("parent_run_id") or has("terminal_reason") or has("total_tokens") | not) end) and
    (.checks | nullable_string) and (.qa | nullable_string) and (.tribunal | nullable_string) and
    (.pr | nullable_string) and (.merge | nullable_string) and (.deployment | nullable_string) and (.rollback | nullable_string) and
    (.outcome | type == "string") and
    (if .event_type == "completed" or .event_type == "accounted" then .outcome != "incomplete" else .outcome == "incomplete" end) and
    (if .schema_version == 2 and .parent_run_id == null and .phase == "pass-outcome" and
        (.event_type == "completed" or .event_type == "accounted")
     then if (.outcome | IN("success","no-op","skipped")) then .terminal_reason == null
          elif (.outcome | IN("blocked","failure","escalated","cancelled"))
          then (.terminal_reason | registered_terminal_reason)
          else false
          end
     else true end) and
    (.base_sha | nullable_sha) and (.result_sha | nullable_sha) and
    (.source_schema_version | uint) and
    ((keys | sort) == (if .schema_version == 1 then v1_keys else v2_keys end | sort))
  ' >/dev/null
}

emit_legacy() {
  local file="$1" index="$2" outcome=incomplete event_type=started duration=""
  if grep -qE '^(fixed:|shipped:)' "$file"; then
    outcome=success; event_type=completed
  elif grep -qE '^(blocked:|needs-human:|escalated:)' "$file"; then
    outcome=blocked; event_type=completed
  elif grep -qE '^skipped:' "$file"; then
    outcome=skipped; event_type=completed
  fi
  duration=$(awk -F: '/^(duration_ms|elapsed_ms):[[:space:]]*[0-9]+/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$file")
  jq -cn --argjson schema_version "$SCHEMA_VERSION" --argjson index "$index" \
    --arg outcome "$outcome" --arg event_type "$event_type" --arg duration "$duration" '
      {
        schema_version:$schema_version,routing_schema_version:0,
        run_id:("legacy-" + ($index|tostring)),parent_run_id:null,command:"legacy",phase:"legacy-artifact",surface:"legacy",profile:null,
        routing_reasons:["legacy_artifact"],writer_id:"legacy-reader",event_type:$event_type,attempt:1,
        recorded_at:null,started_at:null,finished_at:null,duration_ms:(if $duration=="" then null else ($duration|tonumber) end),
        requested_provider:null,requested_model:null,requested_effort:null,effective_provider:null,effective_model:null,effective_effort:null,
        tokens_available_before:null,tokens_available_after:null,input_tokens:null,output_tokens:null,cached_input_tokens:null,cost_microunits:null,total_tokens:null,
        checks:null,qa:null,tribunal:null,pr:null,merge:null,deployment:null,rollback:null,outcome:$outcome,terminal_reason:null,
        base_sha:null,result_sha:null,source_schema_version:0
      }'
}

read_events() {
  local events_file="" legacy_root="" line normalized identity_key n=0 index=0 file
  while [ $# -gt 0 ]; do
    case "$1" in
      --events) [ "$#" -ge 2 ] || usage; events_file="$2"; shift 2 ;;
      --legacy-root) [ "$#" -ge 2 ] || usage; legacy_root="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  events_file=$(resolve_events_file "$events_file")
  # shellcheck source=pii-gate.sh
  . "$SCRIPT_DIR/pii-gate.sh" || { echo "agent-events: PII gate unavailable" >&2; exit 2; }
  if [ -f "$events_file" ]; then
    identity_key=$(identity_key_for_read "$events_file") || {
      echo "agent-events: could not initialize opaque identities" >&2
      exit 3
    }
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      [ -n "$line" ] || continue
      if pii_hit "$line"; then
        echo "agent-events: secret/PII detected at line $n" >&2
        exit 3
      fi
      if ! printf '%s\n' "$line" | validate_event_line; then
        echo "agent-events: invalid event at line $n" >&2
        exit 3
      fi
      normalized=$(printf '%s\n' "$line" | normalize_event_dimensions) || {
        echo "agent-events: invalid dimensions at line $n" >&2
        exit 3
      }
      if ! printf '%s\n' "$normalized" | normalize_event_identity "$identity_key"; then
        echo "agent-events: invalid identities at line $n" >&2
        exit 3
      fi
    done < "$events_file"
  fi
  if [ -n "$legacy_root" ]; then
    [ -d "$legacy_root" ] || { echo "agent-events: legacy root is not a directory" >&2; exit 2; }
    while IFS= read -r file; do
      index=$((index + 1))
      if pii_hit "$(cat "$file")"; then
        echo "agent-events: secret/PII detected in legacy artifact" >&2
        exit 3
      fi
      emit_legacy "$file" "$index"
    done < <(find "$legacy_root" -type f -path '*/runs/*' -name '*.md' -print | LC_ALL=C sort)
  fi
}

project_terminals() {
  local events_file="$1" raw_run_id="${2:-}" identity_key query_id="" records result status incomplete_count
  records=$(mktemp) || return 3
  if ! read_events --events "$events_file" > "$records"; then
    rm -f -- "$records"
    return 3
  fi
  if [ -n "$raw_run_id" ]; then
    identity_key=$(identity_key_for_read "$events_file") || { rm -f -- "$records"; return 3; }
    query_id=$(opaque_id run "$raw_run_id" "$identity_key") || { rm -f -- "$records"; return 3; }
  fi
  result=$(jq -cs --arg run_id "$query_id" '
    def logical_terminal:
      del(.schema_version,.source_schema_version,.event_type,.recorded_at,.started_at,.finished_at,.duration_ms,.total_tokens);
    [to_entries[]
      | select(.value.phase == "pass-outcome" and .value.parent_run_id == null and
          ($run_id == "" or .value.run_id == $run_id))]
    | sort_by(.value.run_id)
    | group_by(.value.run_id)
    | map(
        . as $lifecycle
        | [.[] | select(.value.event_type == "completed" or .value.event_type == "accounted")] as $candidates
        | if ($lifecycle | map(.value.writer_id) | unique | length) != 1 or
             ($lifecycle | map(.value.command) | unique | length) != 1
          then {status:"conflict",run_id:$lifecycle[0].value.run_id}
          elif ($candidates | length) == 0 then {status:"incomplete",run_id:$lifecycle[0].value.run_id}
          # Duration is wall-clock authority (see account_event): multiple
          # duration stamps on the same logical terminal are not a conflict —
          # the sort below keeps the richest/latest. Divergent token totals still
          # conflict. Distinct logical outcomes always conflict.
          elif ($candidates | map(.value | logical_terminal | tojson) | unique | length) != 1 or
               ($candidates | map(.value.total_tokens) | map(select(. != null)) | unique | length) > 1
          then {status:"conflict",run_id:$lifecycle[0].value.run_id}
          else {
            status:"ok",
            event:($candidates
              | sort_by([(.value.event_type == "accounted"),(.value.duration_ms != null),
                  (.value.total_tokens != null),(.value.recorded_at // ""),.key])
              | last.value)
          }
          end
      ) as $runs
    | if ($runs | length) == 0 then {status:"missing",events:[]}
      elif any($runs[]; .status == "conflict") then {status:"conflict",events:[]}
      elif $run_id != "" and any($runs[]; .status == "incomplete") then {status:"incomplete",events:[]}
      else {
        status:"ok",
        incomplete_count:([$runs[] | select(.status == "incomplete")] | length),
        events:($runs | map(select(.status == "ok") | .event) | sort_by(.run_id))
      }
      end
  ' "$records") || { rm -f -- "$records"; return 3; }
  rm -f -- "$records"
  status=$(jq -r .status <<< "$result")
  case "$status" in
    ok)
      incomplete_count=$(jq -r '.incomplete_count // 0' <<< "$result")
      if [ -z "$raw_run_id" ] && [ "$incomplete_count" -gt 0 ]; then
        echo "agent-events: skipped $incomplete_count incomplete root pass-outcome lifecycle(s)" >&2
      fi
      jq -c '.events[]' <<< "$result"
      ;;
    missing)
      [ -z "$raw_run_id" ] && return 0
      echo "agent-events: terminal event is missing" >&2; return 4
      ;;
    incomplete) echo "agent-events: root pass-outcome lifecycle is incomplete" >&2; return 3 ;;
    conflict) echo "agent-events: conflicting logical terminal events" >&2; return 3 ;;
    *) echo "agent-events: terminal projection failed" >&2; return 3 ;;
  esac
}

project_terminal() {
  project_terminals "$1" "$2"
}

terminal_event() {
  local run_id="" events_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id) [ "$#" -ge 2 ] || usage; run_id="$2"; shift 2 ;;
      --events) [ "$#" -ge 2 ] || usage; events_file="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  valid_id "$run_id" || { echo "agent-events: invalid --run-id" >&2; exit 2; }
  events_file=$(resolve_events_file "$events_file")
  project_terminal "$events_file" "$run_id"
}

terminal_events() {
  local events_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --events) [ "$#" -ge 2 ] || usage; events_file="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  events_file=$(resolve_events_file "$events_file")
  project_terminals "$events_file"
}

account_event() {
  local run_id="" duration_ms="" total_tokens="" events_file="" terminal current payload
  local desired_total existing_duration existing_total target lock_file identity_key recorded_at
  while [ $# -gt 0 ]; do
    case "$1" in
      --run-id) [ "$#" -ge 2 ] || usage; run_id="$2"; shift 2 ;;
      --duration-ms) [ "$#" -ge 2 ] || usage; duration_ms="$2"; shift 2 ;;
      --total-tokens) [ "$#" -ge 2 ] || usage; total_tokens="$2"; shift 2 ;;
      --events) [ "$#" -ge 2 ] || usage; events_file="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  valid_id "$run_id" || { echo "agent-events: invalid --run-id" >&2; exit 2; }
  [ -n "$duration_ms" ] && valid_uint_or_empty "$duration_ms" || {
    echo "agent-events: --duration-ms must be a non-negative integer" >&2; exit 2; }
  valid_uint_or_empty "$total_tokens" || {
    echo "agent-events: --total-tokens must be a non-negative integer" >&2; exit 2; }
  events_file=$(resolve_events_file "$events_file")
  terminal=$(project_terminal "$events_file" "$run_id") || exit $?
  existing_duration=$(jq -r '.duration_ms // empty' <<< "$terminal")
  existing_total=$(jq -r '.total_tokens // empty' <<< "$terminal")
  # Caller-supplied duration_ms is the wall-clock authority (outer scheduler
  # envelope). Child maintain passes may pre-stamp an internal duration that
  # differs by coordinator overhead — overwriting that is correct, not a
  # conflict. Token totals still conflict if both sides set different values.
  [ -z "$total_tokens" ] || [ -z "$existing_total" ] || [ "$existing_total" = "$total_tokens" ] || {
    echo "agent-events: conflicting terminal token accounting" >&2; exit 3; }
  desired_total=${total_tokens:-$existing_total}
  if [ "$(jq -r .event_type <<< "$terminal")" = accounted ] &&
     [ "$existing_duration" = "$duration_ms" ] && [ "$existing_total" = "$desired_total" ]; then
    printf '%s\n' "$terminal"
    return 0
  fi
  recorded_at=$(now_iso)
  payload=$(jq -c --argjson schema_version "$SCHEMA_VERSION" --arg recorded_at "$recorded_at" \
    --arg duration_ms "$duration_ms" --arg total_tokens "$desired_total" '
      . as $terminal
      | .schema_version=$schema_version | .source_schema_version=$schema_version
      | .event_type="accounted" | .recorded_at=$recorded_at
      | .duration_ms=($duration_ms|tonumber)
      | .total_tokens=(if $total_tokens == "" then null else ($total_tokens|tonumber) end)
      | .terminal_reason=(
          if $terminal.schema_version == 1 and
             ($terminal.outcome | IN("blocked","failure","escalated","cancelled"))
          then "unknown_failure"
          else ($terminal.terminal_reason // null)
          end)
    ' <<< "$terminal") || { echo "agent-events: could not construct accounting event" >&2; exit 3; }
  printf '%s\n' "$payload" | validate_event_line || {
    echo "agent-events: invalid accounting event" >&2; exit 3; }
  # shellcheck source=pii-gate.sh
  . "$SCRIPT_DIR/pii-gate.sh" || { echo "agent-events: PII gate unavailable" >&2; exit 2; }
  ! pii_hit "$payload" || { echo "agent-events: accounting event rejected by secret/PII gate" >&2; exit 3; }
  safe_append_target "$events_file" || { echo "agent-events: unsafe event destination" >&2; exit 3; }
  target=$events_file
  lock_file="${target}.lock"
  command -v flock >/dev/null 2>&1 || { echo "agent-events: flock is required" >&2; exit 2; }
  exec 7>>"$lock_file"
  flock 7
  identity_key=$(identity_key_for_append "$target") || {
    flock -u 7; echo "agent-events: could not initialize opaque identities" >&2; exit 3; }
  payload=$(printf '%s\n' "$payload" | normalize_event_identity "$identity_key") || {
    flock -u 7; echo "agent-events: identity normalization failed" >&2; exit 3; }
  current=""
  if current=$(project_terminal "$target" "$run_id" 2>/dev/null); then
    existing_duration=$(jq -r '.duration_ms // empty' <<< "$current")
    existing_total=$(jq -r '.total_tokens // empty' <<< "$current")
    if [ "$(jq -r .event_type <<< "$current")" = accounted ] &&
       [ "$existing_duration" = "$duration_ms" ] && [ "$existing_total" = "$desired_total" ]; then
      flock -u 7
      printf '%s\n' "$current"
      return 0
    fi
    # Duration is wall-clock authority (see above); only token totals conflict.
    [ -z "$desired_total" ] || [ -z "$existing_total" ] || [ "$existing_total" = "$desired_total" ] || {
      flock -u 7; echo "agent-events: conflicting terminal token accounting" >&2; exit 3; }
  fi
  printf '%s\n' "$payload" >> "$target"
  flock -u 7
  printf '%s\n' "$payload"
}

case "${1:-}" in
  append) shift; append_event "$@" ;;
  read) shift; read_events "$@" ;;
  terminal) shift; terminal_event "$@" ;;
  terminals) shift; terminal_events "$@" ;;
  account) shift; account_event "$@" ;;
  new-run-id)
    [ "$#" -eq 1 ] || usage
    token=$(random_hex 16) || { echo "agent-events: could not generate run id" >&2; exit 3; }
    printf 'run-%s\n' "$token"
    ;;
  schema-version)
    [ "$#" -eq 1 ] || usage
    jq -cn --argjson schema_version "$SCHEMA_VERSION" --argjson routing_schema_version "$ROUTING_SCHEMA_VERSION" \
      '{schema_version:$schema_version,routing_schema_version:$routing_schema_version}'
    ;;
  *) usage ;;
esac
