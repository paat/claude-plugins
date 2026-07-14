#!/usr/bin/env bash
# Model-free readiness/no-op probe for recurring workflows.
# Exit 0: launch the workflow. Exit 3: clean no-op. Exit 4: blocked environment
# (hard prerequisite unmet; fix the host, do not launch). Exit 1/2: real failure/usage.
set -euo pipefail

MODE="${1:-}"; [ "$#" -gt 0 ] && shift || true
ROOT=""; REPO=""; ISSUE=""; LABEL=""; DATE=""; DRY_RUN=0
usage() {
  echo "usage: workflow-probe.sh {maintain|maintain-loop|monitor-nightly|digest|lessons-deliver} [--root DIR] [--repo OWNER/REPO] [--issue N] [--label LABEL] [--date YYYY-MM-DD]" >&2
}
need_value() { [ "$#" -ge 2 ] || { usage; exit 2; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) need_value "$@"; ROOT="$2"; shift 2 ;;
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --issue) need_value "$@"; ISSUE="$2"; shift 2 ;;
    --label) need_value "$@"; LABEL="$2"; shift 2 ;;
    --date) need_value "$@"; DATE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --once) shift ;;
    --max-issues|--max-merges|--max-pass-minutes|--max-run-minutes)
      need_value "$@"; shift 2 ;;
    *) echo "workflow-probe: unsupported argument: $1" >&2; usage; exit 2 ;;
  esac
done
case "$MODE" in maintain|maintain-loop|monitor-nightly|digest|lessons-deliver) : ;; *) usage; exit 2 ;; esac
case "$ISSUE" in
  "") ;;
  *[!0-9]*|0*) echo "workflow-probe: --issue must be a positive integer without leading zeros" >&2; exit 2 ;;
esac
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ROOT="$(cd "$ROOT" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
noop() { echo "workflow-probe: $MODE no work to do"; exit 3; }
ready() { echo "workflow-probe: $MODE work available"; exit 0; }
BLOCKED_FILES=()
git_common_dir() {
  local common
  common="$(git -C "$ROOT" rev-parse --git-common-dir)" || return 1
  case "$common" in /*) ;; *) common="$ROOT/$common" ;; esac
  (cd "$common" && pwd)
}
load_blocked_files() {
  local common primary candidate
  common="$(git_common_dir)" || return 1
  primary="$(bash "$SCRIPT_DIR/maintain-leases.sh" primary-root --repo-root "$ROOT")" || return 1
  BLOCKED_FILES=()
  for candidate in \
    "$common/saas-startup-team/maintain/blocked.jsonl" \
    "$primary/.startup/maintain/blocked.jsonl" \
    "$primary/.worktrees/maintain/.startup/maintain/blocked.jsonl"; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    BLOCKED_FILES+=("$candidate")
  done
}

delivery_lease_gate() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  if ! diag="$(bash "$SCRIPT_DIR/maintain-leases.sh" available --repo-root "$ROOT" 2>&1)"; then
    echo "workflow-probe: $MODE blocked: $diag" >&2
    exit 4
  fi
}

# Mutating scheduled modes require a usable Codex writer sandbox; an unchanged
# hard host block must not spend one doomed model launch per tick. A --dry-run
# planning pass is read-only and never blocked here. $1=1 additionally treats a
# missing Codex CLI as a hard block (workflows that always need the worker).
codex_writer_gate() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  require_codex_cli="${1:-0}"
  gate_rc=0
  diag="$(bash "$SCRIPT_DIR/codex-sandbox-check.sh" --root "$ROOT")" || gate_rc=$?
  case "$gate_rc" in
    0) return 0 ;;
    10)
      [ "$require_codex_cli" -eq 1 ] || return 0
      echo "workflow-probe: $MODE blocked: Codex CLI not found; install/authenticate Codex before scheduling this workflow" >&2
      exit 4 ;;
    4)
      echo "workflow-probe: $MODE blocked: $diag" >&2
      exit 4 ;;
    *)
      echo "workflow-probe: Codex sandbox check failed" >&2
      exit 1 ;;
  esac
}

lease_guardian_gate() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  if ! diag="$(bash "$SCRIPT_DIR/lease-guardian.sh" probe 2>&1)"; then
    echo "workflow-probe: $MODE blocked: $diag" >&2
    exit 4
  fi
}

case "$MODE" in
  maintain)
    command -v gh >/dev/null 2>&1 || { echo "workflow-probe: gh is required" >&2; exit 1; }
    routing_schema_version="$(bash "$SCRIPT_DIR/delivery-route.sh" schema-version | jq -er '.schema_version | select(type == "number")')" || {
      echo "workflow-probe: cannot resolve routing schema" >&2; exit 1; }
    cache="$ROOT/.startup/maintain/triage-cache.jsonl"
    gh_args=(issue list --state open --limit 1000 --json "number,labels,updatedAt")
    [ -z "$REPO" ] || gh_args+=(--repo "$REPO")
    [ -z "$LABEL" ] || gh_args+=(--label "$LABEL")
    open_json="$(gh "${gh_args[@]}")" || { echo "workflow-probe: cannot list issues" >&2; exit 1; }
    # Scope every derived signal to an explicit issue before stale-label or cache
    # evaluation. Unrelated repository state must not launch a filtered run.
    if [ -n "$ISSUE" ]; then
      open_json="$(printf '%s' "$open_json" | jq --argjson n "$ISSUE" '[.[]|select(.number==$n)]')" || exit 1
    fi
    load_blocked_files || { echo "workflow-probe: cannot resolve blocked ledgers" >&2; exit 1; }
    blocked_args=(); for blocked_file in "${BLOCKED_FILES[@]}"; do blocked_args+=(--file "$blocked_file"); done
    cooldowns="$(bash "$SCRIPT_DIR/maintain-blocked.sh" active --now "$(date -u +%FT%TZ)" \
      "${blocked_args[@]}")" || { echo "workflow-probe: invalid blocked ledger" >&2; exit 1; }
    stale_cleanup="$(printf '%s' "$open_json" | jq -r --argjson cooldowns "$cooldowns" '
      [.[] | .number as $number | [.labels[].name] as $labels
       | select(($labels | index("maintain:blocked")) != null)
       | select(($cooldowns | index($number)) == null) | $number] | unique | sort | join(",")')" || exit 1
    open_json="$(printf '%s' "$open_json" | jq --argjson cooldowns "$cooldowns" '
      [.[] | .number as $number | [.labels[].name] as $labels
       | select(($labels | (index("needs-human") or index("epic"))) | not)
       | select(($cooldowns | index($number)) == null)]')" || exit 1
    open="$(printf '%s' "$open_json" | jq length)"
    [ "$open" -gt 0 ] || noop
    new="$open"; cached_resumable=0
    if [ -s "$cache" ]; then
      jq -e . "$cache" >/dev/null 2>&1 || {
        echo "workflow-probe: malformed triage cache: $cache" >&2; exit 1; }
      new="$(jq --argjson schema "$routing_schema_version" --slurpfile seen <(jq -c --argjson schema "$routing_schema_version" 'select(.routing_schema_version==$schema)|{number,updatedAt}' "$cache") \
        '[.[]|select({number,updatedAt} as $k|($seen|index($k))|not)]|length' <<<"$open_json")"
      cached_resumable="$(jq -s --argjson schema "$routing_schema_version" --slurpfile open <(printf '%s\n' "$open_json") '
        def matching($c): any($open[0][]; .number==$c.number and .updatedAt==$c.updatedAt);
        def pending: ((.final_state // .finalState // "") | test("^(fixed:|needs-human:|escalated:|skipped:|split:)") | not);
        [.[]|select(.routing_schema_version==$schema)|select(matching(.))
          |select(.verdict=="agent-fixable" or .verdict=="partially-fixable" or .verdict=="needs-human")
          |select(pending)]|length' "$cache")"
    fi
    [ "$new" -gt 0 ] || [ "$cached_resumable" -gt 0 ] || [ -n "$stale_cleanup" ] || noop
    [ -z "$stale_cleanup" ] || echo "workflow-probe: maintain stale maintain:blocked cleanup: $stale_cleanup"
    delivery_lease_gate
    codex_writer_gate 0
    lease_guardian_gate
    ready
    ;;

  maintain-loop)
    pending_args=(pending --repo-root "$ROOT"); [ -z "$ISSUE" ] || pending_args+=(--issue "$ISSUE")
    pending_json="$(bash "$SCRIPT_DIR/maintain-delivery.sh" "${pending_args[@]}")" || {
      echo "workflow-probe: cannot inspect pending maintain-loop delivery" >&2; exit 1; }
    pending_count=$(jq -r 'length' <<<"$pending_json") || exit 1
    if [ "$pending_count" -gt 1 ]; then
      echo "workflow-probe: multiple nonterminal maintain-loop receipts require reconciliation" >&2
      exit 1
    fi
    if [ "$pending_count" -eq 1 ]; then
      pending_state="$(jq -er '.[0].state | select(type == "string" and length > 0)' <<<"$pending_json")" || {
        echo "workflow-probe: invalid pending maintain-loop delivery state" >&2; exit 1; }
      echo "workflow-probe: maintain-loop pending receipt: $pending_state"
      delivery_lease_gate
      case "$pending_state" in
        claimed) codex_writer_gate 1 ;;
        normal_planned|normal_open|normal_merge_authorized|post_merge|release_verified|rollback_planned|rollback_open|rollback_merge_authorized|rollback_merged|rollback_release_verified|close_intent|closed_observed) : ;;
        *) echo "workflow-probe: invalid pending maintain-loop delivery state: $pending_state" >&2; exit 1 ;;
      esac
      lease_guardian_gate
      ready
    fi
    args=(); [ -z "$REPO" ] || args+=(--repo "$REPO"); [ -z "$ISSUE" ] || args+=(--issue "$ISSUE"); [ -z "$LABEL" ] || args+=(--label "$LABEL")
    load_blocked_files || { echo "workflow-probe: cannot resolve blocked ledgers" >&2; exit 1; }
    for blocked_file in "${BLOCKED_FILES[@]}"; do args+=(--blocked-file "$blocked_file"); done
    queue_err=$(mktemp); queue_rc=0
    queue="$(cd "$ROOT" && bash "$SCRIPT_DIR/maintain-queue.sh" "${args[@]}" 2>"$queue_err")" || queue_rc=$?
    if [ "$queue_rc" -ne 0 ]; then
      if [ "$queue_rc" -eq 3 ] && [ -n "$ISSUE" ] \
        && grep -Fqx "maintain-queue: issue #$ISSUE is not open" "$queue_err"; then
        rm -f "$queue_err"; noop
      fi
      sed 's/^/workflow-probe: /' "$queue_err" >&2
      rm -f "$queue_err"; exit 1
    fi
    rm -f "$queue_err"
    [ "$(printf '%s' "$queue" | jq '.queue|length')" -gt 0 ] || noop
    delivery_lease_gate
    codex_writer_gate 1
    lease_guardian_gate
    ready
    ;;

  monitor-nightly)
    config="$ROOT/.claude/saas-startup-team.local.md"
    marker_dir="$ROOT/.monitor"; custom_checks="$ROOT/.startup/monitor-checks.sh"
    state_file="$ROOT/.startup/monitor-state.json"
    if [ -f "$config" ] && grep -q '^[[:space:]]*monitor:[[:space:]]*$' "$config"; then
      block="$(sed -n '/^[[:space:]]*monitor:[[:space:]]*$/,/^[^[:space:]#]/p' "$config")"
      value="$(printf '%s\n' "$block" | sed -nE 's/^[[:space:]]+marker_dir:[[:space:]]*([^#[:space:]][^#]*)$/\1/p' | head -1 | sed -E 's/[[:space:]]+$//;s/^['"'"'"]//;s/['"'"'"]$//')"
      if [ -n "$value" ]; then case "$value" in /*) marker_dir="$value" ;; *) marker_dir="$ROOT/${value#./}" ;; esac; fi
      value="$(printf '%s\n' "$block" | sed -nE 's/^[[:space:]]+custom_checks:[[:space:]]*([^#[:space:]][^#]*)$/\1/p' | head -1 | sed -E 's/[[:space:]]+$//;s/^['"'"'"]//;s/['"'"'"]$//')"
      if [ -n "$value" ]; then case "$value" in /*) custom_checks="$value" ;; *) custom_checks="$ROOT/${value#./}" ;; esac; fi
      value="$(printf '%s\n' "$block" | sed -nE 's/^[[:space:]]+state_file:[[:space:]]*([^#[:space:]][^#]*)$/\1/p' | head -1 | sed -E 's/[[:space:]]+$//;s/^['"'"'"]//;s/['"'"'"]$//')"
      if [ -n "$value" ]; then case "$value" in /*) state_file="$value" ;; *) state_file="$ROOT/${value#./}" ;; esac; fi
    fi
    probe_cache="${state_file}.probe-findings"
    if [ -s "$probe_cache" ] && find "$probe_cache" -mmin -60 -print -quit | grep -q .; then ready; fi
    rm -f "$probe_cache"
    marker_found=0
    if [ -d "$marker_dir" ] && find "$marker_dir" -maxdepth 1 -type f -name '*-last-failure.txt' -print -quit | grep -q .; then marker_found=1; fi
    if [ -x "$custom_checks" ]; then
      window="$("$SCRIPT_DIR/monitor-dedup.sh" window --state "$state_file")" || {
        echo "workflow-probe: cannot resolve monitor window" >&2; exit 1; }
      eval "$window"
      export MONITOR_SINCE MONITOR_SINCE_MINUTES
      set +e
      custom_output="$(cd "$ROOT" && "$custom_checks")"; custom_ec=$?
      set -e
      if [ "$custom_ec" -ne 0 ] || [ -n "$(printf '%s' "$custom_output" | tr -d '[:space:]')" ]; then
        mkdir -p "$(dirname "$probe_cache")"
        probe_tmp="${probe_cache}.tmp.$$"
        printf '%s\n' "$custom_output" > "$probe_tmp"
        if [ "$custom_ec" -ne 0 ]; then
          jq -nc --arg b "custom-checks exited $custom_ec" \
            '{pattern_key:"ops:monitor-checks:failure",severity:"high",entity:null,title:"[Monitor] custom-checks script failed",body:$b}' >> "$probe_tmp"
        fi
        mv "$probe_tmp" "$probe_cache"
        ready
      fi
      rm -f "$probe_cache"
    else
      rm -f "$probe_cache"
    fi
    [ "$marker_found" -eq 0 ] || ready
    noop
    ;;

  digest)
    [ -n "$DATE" ] || DATE="$(date +%F)"
    sent_ec=0
    bash "$SCRIPT_DIR/digest.sh" already-sent --root "$ROOT" --date "$DATE" || sent_ec=$?
    case "$sent_ec" in 0) noop ;; 1) : ;; *) exit "$sent_ec" ;; esac
    kind="${SAAS_NOTIFY_KIND:-}"; url="${SAAS_NOTIFY_URL:-}"; token_env="${SAAS_NOTIFY_TOKEN_ENV:-}"
    notify_config="$ROOT/.startup/notify.json"
    if [ -f "$notify_config" ]; then
      jq -e . "$notify_config" >/dev/null 2>&1 || { echo "workflow-probe: malformed notify config" >&2; exit 1; }
      kind="$(jq -r '.kind // empty' "$notify_config")"
      url="$(jq -r '.url // empty' "$notify_config")"
      token_env="$(jq -r '.token_env // empty' "$notify_config")"
    fi
    [ -n "$kind" ] && [ "$kind" != "none" ] || noop
    case "$kind" in ntfy|webhook) : ;; *) echo "workflow-probe: unknown notify kind: $kind" >&2; exit 1 ;; esac
    [ -n "$url" ] || { echo "workflow-probe: notify URL is missing" >&2; exit 1; }
    if [ -n "$token_env" ] && [ -z "$(printenv "$token_env" 2>/dev/null || true)" ]; then
      echo "workflow-probe: notify token env is empty: $token_env" >&2; exit 1
    fi
    state="$ROOT/.startup/digest-state.json"
    sent='[]'; [ -f "$state" ] && sent="$(jq -c '.sent_runs // []' "$state" 2>/dev/null || echo '[]')"
    new_runs=0
    if [ -d "$ROOT/.startup" ]; then
      while IFS= read -r f; do
        rel="${f#"$ROOT"/}"
        if ! jq -e --arg p "$rel" 'index($p) != null' <<<"$sent" >/dev/null; then new_runs=1; break; fi
      done < <(find "$ROOT/.startup" -type f -path '*/runs/*' -name '*.md' | sort)
    fi
    pending=0
    if [ -f "$ROOT/docs/human-tasks.md" ] && awk '
      /^## +Pending/ { pending=1; next }
      /^## / { if (pending) pending=0 }
      /<!--/ { comment=1 }
      comment { if ($0 ~ /-->/) comment=0; next }
      pending && /^[[:space:]]*- \[ \]/ { found=1; exit }
      END { exit(found ? 0 : 1) }
    ' "$ROOT/docs/human-tasks.md"; then pending=1; fi
    [ "$new_runs" -eq 1 ] || [ "$pending" -eq 1 ] || noop
    ready
    ;;

  lessons-deliver)
    [ -n "$REPO" ] || REPO="${SAAS_PLUGIN_REPO:-}"
    [ -n "$REPO" ] || noop
    queue="$(cd "$ROOT" && bash "$SCRIPT_DIR/lessons-deliver.sh" --list --json --repo "$REPO")" || exit 1
    [ "$(printf '%s' "$queue" | jq length)" -gt 0 ] || noop
    ready
    ;;
esac
