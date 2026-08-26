#!/usr/bin/env bash
# Model-free readiness/no-op probe for recurring workflows.
# Exit 0: launch the workflow. Exit 3: clean no-op. Exit 4: blocked environment
# (hard prerequisite unmet; fix the host, do not launch). Exit 1/2: real failure/usage.
set -euo pipefail

die() { echo "workflow-probe: $1" >&2; exit "${2:-1}"; }

MODE="${1:-}"; [ "$#" -gt 0 ] && shift || true
OUTPUT_MODE="$MODE"
ROOT=""; REPO=""; ISSUE=""; LABEL=""; DATE=""; DRY_RUN=0
usage() {
  echo "usage: workflow-probe.sh {maintain|maintain-loop|monitor-nightly|digest} [--root DIR] [--repo OWNER/REPO] [--issue N] [--label LABEL] [--date YYYY-MM-DD]" >&2
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
case "$MODE" in
  maintain-loop) MODE=maintain ;;
  maintain|monitor-nightly|digest) : ;;
  *) usage; exit 2 ;;
esac
case "$ISSUE" in
  "") ;;
  *[!0-9]*|0*) die "--issue must be a positive integer without leading zeros" 2 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# SSOT absolute primary path — single resolver for all maintain scripts.
# shellcheck source=maintain-paths.sh
. "$SCRIPT_DIR/maintain-paths.sh"
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
maintain_paths_resolve "$ROOT" || die "cannot resolve primary repository path"
# Always use the physical primary SSOT (never a symlink alias like /workspace).
ROOT=$MAINTAIN_PRIMARY
noop() { echo "workflow-probe: $OUTPUT_MODE no work to do"; exit 3; }
CONTROLLER_ROUTE=""
ready() {
  [ -z "$CONTROLLER_ROUTE" ] \
    || echo "workflow-probe: $OUTPUT_MODE controller-route=$CONTROLLER_ROUTE"
  echo "workflow-probe: $OUTPUT_MODE work available"
  exit 0
}
BLOCKED_FILES=()
git_common_dir() {
  local common
  common="$(git -C "$ROOT" rev-parse --git-common-dir)" || return 1
  case "$common" in /*) ;; *) common="$ROOT/$common" ;; esac
  (cd "$common" && pwd -P)
}

load_blocked_files() {
  local common candidate
  common="$(git_common_dir)" || return 1
  BLOCKED_FILES=()
  for candidate in \
    "$common/saas-startup-team/maintain/blocked.jsonl" \
    "$ROOT/.startup/maintain/blocked.jsonl"; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    BLOCKED_FILES+=("$candidate")
  done
}

# Source delivery may use Codex; dry-run skips. Not a primary-only / lease gate.
codex_cli_gate() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  case " ${SAAS_PREFLIGHT_MISSING:-} " in
    *" codex "*) ;;
    *)
      if command -v codex >/dev/null 2>&1; then
        command -v timeout >/dev/null 2>&1 || die "$OUTPUT_MODE blocked: timeout is required to verify Codex authentication" 4
        if timeout 10 codex login status >/dev/null 2>&1; then return 0; fi
        die "$OUTPUT_MODE blocked: Codex authentication is unavailable; run codex login before scheduling this workflow" 4
      fi
      ;;
  esac
  die "$OUTPUT_MODE blocked: Codex CLI not found; install/authenticate Codex before scheduling this workflow" 4
}

# Surface leftover nonterminal legacy receipts; does not mutate (drain is explicit).
legacy_receipt_notice() {
  local inv unresolved
  [ -x "$SCRIPT_DIR/legacy-drain.sh" ] || return 0
  inv=$(bash "$SCRIPT_DIR/legacy-drain.sh" inventory --repo-root "$ROOT" --json 2>/dev/null) || return 0
  unresolved=$(jq -r '.summary.unresolved // 0' <<<"$inv" 2>/dev/null || echo 0)
  recoverable=$(jq -r '.summary.recoverable // 0' <<<"$inv" 2>/dev/null || echo 0)
  if [ "${recoverable:-0}" -gt 0 ] || [ "${unresolved:-0}" -gt 0 ]; then
    echo "workflow-probe: $OUTPUT_MODE legacy receipts: recoverable=$recoverable unresolved=$unresolved (run scripts/legacy-drain.sh drain --apply)"
  fi
}

case "$MODE" in
  maintain)
    # v3-only: no leases, guardian, claims, or primary-only stack (#389).
    CONTROLLER_ROUTE=v3
    legacy_receipt_notice
    command -v gh >/dev/null 2>&1 || die "gh is required"
    routing_schema_version="$(bash "$SCRIPT_DIR/delivery-route.sh" schema-version | jq -er '.schema_version | select(type == "number")')" || die "cannot resolve routing schema"
    cache="$ROOT/.startup/maintain/triage-cache.jsonl"
    gh_args=(issue list --state open --limit 1000 --json "number,labels,updatedAt")
    [ -z "$REPO" ] || gh_args+=(--repo "$REPO")
    [ -z "$LABEL" ] || gh_args+=(--label "$LABEL")
    open_json="$(gh "${gh_args[@]}")" || die "cannot list issues"
    if [ -n "$ISSUE" ]; then
      open_json="$(printf '%s' "$open_json" | jq --argjson n "$ISSUE" '[.[]|select(.number==$n)]')" || exit 1
    fi
    load_blocked_files || die "cannot resolve blocked ledgers"
    blocked_args=(); for blocked_file in "${BLOCKED_FILES[@]}"; do blocked_args+=(--file "$blocked_file"); done
    cooldowns="$(bash "$SCRIPT_DIR/maintain-blocked.sh" active --now "$(date -u +%FT%TZ)" \
      "${blocked_args[@]}")" || die "invalid blocked ledger"
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
      jq -e . "$cache" >/dev/null 2>&1 || die "malformed triage cache: $cache"
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
    codex_cli_gate
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
      window="$("$SCRIPT_DIR/monitor-dedup.sh" window --state "$state_file")" || die "cannot resolve monitor window"
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
      jq -e . "$notify_config" >/dev/null 2>&1 || die "malformed notify config"
      kind="$(jq -r '.kind // empty' "$notify_config")"
      url="$(jq -r '.url // empty' "$notify_config")"
      token_env="$(jq -r '.token_env // empty' "$notify_config")"
    fi
    [ -n "$kind" ] && [ "$kind" != "none" ] || noop
    case "$kind" in ntfy|webhook) : ;; *) die "unknown notify kind: $kind" ;; esac
    [ -n "$url" ] || die "notify URL is missing"
    if [ -n "$token_env" ] && [ -z "$(printenv "$token_env" 2>/dev/null || true)" ]; then
      die "notify token env is empty: $token_env"
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
esac
