#!/usr/bin/env bash
# legacy-drain.sh — explicit, isolated, idempotent drain of legacy maintain receipts.
#
# Inventories every nonterminal delivery receipt before any mutation. Recoverable
# receipts get a drain marker (source receipt files left intact until verify).
# Unresolved cases append sanitized human tasks (no secrets/PII/paths/bodies).
# Does not create, load, or migrate claims on the normal maintain-v3 path.
#
# Usage:
#   legacy-drain.sh inventory --repo-root DIR [--state-root DIR] [--json]
#   legacy-drain.sh drain     --repo-root DIR [--state-root DIR] [--apply] [--json]
#   legacy-drain.sh verify    --repo-root DIR [--state-root DIR] [--json]
#
# Exit: 0 success, 1 residual unresolved after apply/verify, 2 usage/config.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=maintain-paths.sh
. "$SCRIPT_DIR/maintain-paths.sh"

ACTION=""
REPO_ROOT=""
STATE_ROOT=""
AS_JSON=0
APPLY=0

usage() {
  sed -n '2,16p' "$0" >&2
  exit 2
}

die() { printf 'legacy-drain: %s\n' "$1" >&2; exit "${2:-1}"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 required" 2; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
valid_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    inventory|drain|verify) ACTION=$1; shift ;;
    --repo-root) REPO_ROOT=${2:-}; shift 2 ;;
    --state-root) STATE_ROOT=${2:-}; shift 2 ;;
    --json) AS_JSON=1; shift ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

[ -n "$ACTION" ] || usage
[ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT" ] || die "--repo-root must be an existing directory" 2
need jq

maintain_paths_resolve "$REPO_ROOT" || die "cannot resolve repository primary path" 2
PRIMARY=$MAINTAIN_PRIMARY
COMMON=$MAINTAIN_COMMON

if [ -z "$STATE_ROOT" ]; then
  STATE_ROOT="$COMMON/saas-startup-team/maintain-runtime/deliveries"
fi
DRAIN_ROOT="$COMMON/saas-startup-team/legacy-drain"
MARKERS="$DRAIN_ROOT/markers"
REPORT="$DRAIN_ROOT/last-inventory.json"
HUMAN_TASKS="$PRIMARY/docs/human-tasks.md"

# Terminal receipt states (match former maintain-delivery terminal_state).
is_terminal() {
  case "$1" in
    archived_claim|finalized_success|finalized_rolled_back) return 0 ;;
    *) return 1 ;;
  esac
}

# Minimal safe field extraction — no body, title, digests, paths, or identities.
# Recoverable offline: claimed with no normal/rollback PR object, or already marked.
classify_receipt() {
  local file=$1 issue state schema has_normal has_rollback has_pr marker disposition reason
  issue=$(jq -r '.issue_number // empty' "$file" 2>/dev/null || true)
  state=$(jq -r '.state // empty' "$file" 2>/dev/null || true)
  schema=$(jq -r '.schema_version // empty' "$file" 2>/dev/null || true)
  if ! valid_uint "${issue:-}" || [ -z "$state" ]; then
    printf '%s\n' "unresolved|0|malformed|missing_issue_or_state"
    return 0
  fi
  if is_terminal "$state"; then
    printf '%s\n' "terminal|$issue|$state|already_terminal"
    return 0
  fi
  marker="$MARKERS/issue-${issue}.json"
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    disposition=$(jq -r '.disposition // empty' "$marker" 2>/dev/null || true)
    printf '%s\n' "drained|$issue|$state|marker:${disposition:-present}"
    return 0
  fi
  has_normal=$(jq -r 'if (.normal|type)=="object" then "yes" else "no" end' "$file" 2>/dev/null || echo no)
  has_rollback=$(jq -r 'if (.rollback|type)=="object" then "yes" else "no" end' "$file" 2>/dev/null || echo no)
  has_pr=$(jq -r 'if ((.normal.pr_number//null)!=null) or ((.rollback.pr_number//null)!=null) then "yes" else "no" end' \
    "$file" 2>/dev/null || echo no)
  # Abandoned claim: no PR surface — safe offline drain marker only.
  if [ "$state" = claimed ] && [ "$has_normal" = no ] && [ "$has_rollback" = no ]; then
    printf '%s\n' "recoverable|$issue|$state|abandoned_claim_no_pr"
    return 0
  fi
  if [ "$state" = claimed ] && [ "$has_pr" = no ]; then
    printf '%s\n' "recoverable|$issue|$state|claimed_without_pr_number"
    return 0
  fi
  # Mid-flight delivery with PR or later recovery steps needs a human.
  reason="nonterminal_${state}"
  [ "$has_pr" = yes ] && reason="${reason}_with_pr"
  printf '%s\n' "unresolved|$issue|$state|$reason"
}

scan_inventory() {
  local dir file line kind issue state reason rows=()
  shopt -s nullglob
  if [ ! -d "$STATE_ROOT" ]; then
    jq -nc --arg at "$(now_iso)" --arg primary "$PRIMARY" --arg state_root "$STATE_ROOT" \
      '{schema_version:1,engine:"legacy-drain",observed_at:$at,primary:$primary,
        state_root:$state_root,source_intact:true,items:[],
        summary:{total:0,recoverable:0,unresolved:0,terminal:0,drained:0}}'
    return 0
  fi
  for dir in "$STATE_ROOT"/issue-*; do
    [ -L "$dir" ] && continue
    [ -d "$dir" ] || continue
    file="$dir/current.json"
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    line=$(classify_receipt "$file")
    IFS='|' read -r kind issue state reason <<<"$line"
    rows+=("$(jq -nc \
      --arg kind "$kind" --argjson issue "${issue:-0}" --arg state "$state" \
      --arg reason "$reason" --arg receipt_basename "issue-${issue}/current.json" \
      '{kind:$kind,issue:$issue,state:$state,reason:$reason,
        receipt_rel:$receipt_basename,secrets:false,pii:false}')")
  done
  if [ "${#rows[@]}" -eq 0 ]; then
    jq -nc --arg at "$(now_iso)" --arg primary "$PRIMARY" --arg state_root "$STATE_ROOT" \
      '{schema_version:1,engine:"legacy-drain",observed_at:$at,primary:$primary,
        state_root:$state_root,source_intact:true,items:[],
        summary:{total:0,recoverable:0,unresolved:0,terminal:0,drained:0}}'
    return 0
  fi
  printf '%s\n' "${rows[@]}" | jq -s --arg at "$(now_iso)" --arg primary "$PRIMARY" \
    --arg state_root "$STATE_ROOT" '
    {
      schema_version:1,engine:"legacy-drain",observed_at:$at,primary:$primary,
      state_root:$state_root,source_intact:true,
      items:(sort_by(.issue)),
      summary:{
        total:length,
        recoverable:([.[]|select(.kind=="recoverable")]|length),
        unresolved:([.[]|select(.kind=="unresolved")]|length),
        terminal:([.[]|select(.kind=="terminal")]|length),
        drained:([.[]|select(.kind=="drained")]|length)
      }
    }'
}

ensure_drain_dirs() {
  mkdir -p -- "$MARKERS" || die "cannot create drain markers dir"
  [ -d "$MARKERS" ] && [ ! -L "$MARKERS" ] || die "unsafe markers dir"
}

write_marker() {
  local issue=$1 state=$2 reason=$3 path tmp
  path="$MARKERS/issue-${issue}.json"
  [ -f "$path" ] && return 0
  tmp=$(mktemp "$MARKERS/.marker.XXXXXX") || die "cannot create marker tmp"
  jq -nc --argjson issue "$issue" --arg state "$state" --arg reason "$reason" \
    --arg at "$(now_iso)" --arg disposition "drained_offline" \
    '{schema_version:1,issue:$issue,prior_state:$state,reason:$reason,
      disposition:$disposition,drained_at:$at,source_left_intact:true,
      claims:false,compatibility_receipts:false}' >"$tmp"
  mv -f -- "$tmp" "$path"
}

append_human_task() {
  local issue=$1 state=$2 reason=$3 marker_line dir
  dir=$(dirname -- "$HUMAN_TASKS")
  mkdir -p -- "$dir" || die "cannot create docs/"
  if [ ! -f "$HUMAN_TASKS" ]; then
    cat >"$HUMAN_TASKS" <<'EOF'
# Human Tasks (Investor Action Required)

Tasks that only the human can perform. The startup loop continues
without blocking — complete these when you can.

## Pending

## Completed
EOF
  fi
  marker_line="- [ ] **Legacy maintain receipt #${issue}** — needed for: drain unresolved nonterminal state \`${state}\` (${reason}); inspect git/PR for issue #${issue} then resume with maintain-v3 or close manually"
  # Idempotent: skip if issue already mentioned in a legacy-drain task line.
  if grep -qF "Legacy maintain receipt #${issue}" "$HUMAN_TASKS" 2>/dev/null; then
    return 0
  fi
  # Insert under ## Pending when present; else append.
  if grep -qE '^## +Pending' "$HUMAN_TASKS"; then
    awk -v line="$marker_line" '
      /^## +Pending/ { print; print line; next }
      { print }
    ' "$HUMAN_TASKS" >"${HUMAN_TASKS}.tmp" && mv -f -- "${HUMAN_TASKS}.tmp" "$HUMAN_TASKS"
  else
    printf '%s\n' "$marker_line" >>"$HUMAN_TASKS"
  fi
}

# Source receipts under STATE_ROOT must remain byte-present after drain apply.
assert_sources_intact() {
  local inv item issue rel path
  inv=$1
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    issue=$(jq -r .issue <<<"$item")
    rel=$(jq -r .receipt_rel <<<"$item")
    path="$STATE_ROOT/$rel"
    [ -f "$path" ] || die "source receipt missing after drain: issue $issue" 1
  done < <(jq -c '.items[]?' <<<"$inv")
}

do_inventory() {
  local inv
  inv=$(scan_inventory)
  mkdir -p -- "$DRAIN_ROOT" 2>/dev/null || true
  if [ -d "$DRAIN_ROOT" ] && [ ! -L "$DRAIN_ROOT" ]; then
    printf '%s\n' "$inv" >"$REPORT.tmp" && mv -f -- "$REPORT.tmp" "$REPORT" || true
  fi
  if [ "$AS_JSON" -eq 1 ]; then
    printf '%s\n' "$inv"
  else
    echo "legacy-drain inventory"
    echo "primary: $PRIMARY"
    echo "state_root: $STATE_ROOT"
    jq -r '
      "summary: total=\(.summary.total) recoverable=\(.summary.recoverable) unresolved=\(.summary.unresolved) drained=\(.summary.drained) terminal=\(.summary.terminal)",
      (.items[]? | "  #\(.issue) kind=\(.kind) state=\(.state) reason=\(.reason)")
    ' <<<"$inv"
  fi
}

do_drain() {
  local inv item kind issue state reason applied=0 human=0
  # Always inventory first (acceptance: before mutation).
  inv=$(scan_inventory)
  mkdir -p -- "$DRAIN_ROOT" 2>/dev/null || true
  printf '%s\n' "$inv" >"$REPORT.tmp" && mv -f -- "$REPORT.tmp" "$REPORT"

  if [ "$APPLY" -eq 0 ]; then
    if [ "$AS_JSON" -eq 1 ]; then
      jq -c --arg mode dry_run '{mode:$mode,applied:false} + .' <<<"$inv"
    else
      echo "legacy-drain drain (dry-run; pass --apply to mutate markers/human-tasks)"
      jq -r '"would_recover=\(.summary.recoverable) would_human=\(.summary.unresolved)"' <<<"$inv"
    fi
    return 0
  fi

  ensure_drain_dirs
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    kind=$(jq -r .kind <<<"$item")
    issue=$(jq -r .issue <<<"$item")
    state=$(jq -r .state <<<"$item")
    reason=$(jq -r .reason <<<"$item")
    case "$kind" in
      recoverable)
        write_marker "$issue" "$state" "$reason"
        applied=$((applied + 1))
        ;;
      unresolved)
        append_human_task "$issue" "$state" "$reason"
        human=$((human + 1))
        ;;
    esac
  done < <(jq -c '.items[]?' <<<"$inv")

  assert_sources_intact "$inv"
  inv=$(scan_inventory)
  printf '%s\n' "$inv" >"$REPORT.tmp" && mv -f -- "$REPORT.tmp" "$REPORT"

  if [ "$AS_JSON" -eq 1 ]; then
    jq -c --argjson applied "$applied" --argjson human "$human" --arg mode apply \
      '{mode:$mode,applied:true,markers_written:$applied,human_tasks_appended:$human} + .' <<<"$inv"
  else
    echo "legacy-drain drain applied markers=$applied human_tasks=$human source_intact=true"
    jq -r '"summary: total=\(.summary.total) recoverable=\(.summary.recoverable) unresolved=\(.summary.unresolved) drained=\(.summary.drained)"' <<<"$inv"
  fi
  # Residual unresolved still needs humans — exit 1 so operators notice.
  [ "$(jq -r .summary.unresolved <<<"$inv")" = 0 ] || return 1
  return 0
}

do_verify() {
  local inv unresolved missing=0 item issue path
  inv=$(scan_inventory)
  # Verify: every drained marker still has intact source; no recoverable left without marker.
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    issue=$(jq -r .issue <<<"$item")
    path="$STATE_ROOT/issue-${issue}/current.json"
    if [ ! -f "$path" ]; then
      missing=$((missing + 1))
    fi
  done < <(jq -c '.items[]?|select(.kind=="drained" or .kind=="recoverable" or .kind=="unresolved")' <<<"$inv")

  if [ "$AS_JSON" -eq 1 ]; then
    jq -c --argjson missing "$missing" --arg at "$(now_iso)" \
      '. + {verified_at:$at,source_missing:$missing,
            ok:((.summary.recoverable==0) and ($missing==0))}' <<<"$inv"
  else
    echo "legacy-drain verify missing_sources=$missing recoverable=$(jq -r .summary.recoverable <<<"$inv") unresolved=$(jq -r .summary.unresolved <<<"$inv")"
  fi
  unresolved=$(jq -r .summary.unresolved <<<"$inv")
  recoverable=$(jq -r .summary.recoverable <<<"$inv")
  [ "$missing" -eq 0 ] || return 1
  [ "$recoverable" = 0 ] || return 1
  # unresolved is OK after verify if human tasks exist — still exit 1 to signal residual
  [ "$unresolved" = 0 ] || return 1
  return 0
}

case "$ACTION" in
  inventory) do_inventory ;;
  drain) do_drain ;;
  verify) do_verify ;;
  *) usage ;;
esac
