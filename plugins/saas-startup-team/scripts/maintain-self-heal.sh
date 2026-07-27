#!/usr/bin/env bash
# Model-free environment heal for maintain autonomy.
# Run before treating the host as blocked. Prefer heal → continue over MC-BLOCKED.
#
# Exit 0: primary environment is ready (possibly after heals).
# Exit 1: residual condition remains that an agent can still clear (reason on stderr).
# Exit 4: true external block (Codex missing, etc. — not used by this script today).
# Exit 2: usage / unsafe arguments.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ACTION=""
REPO_ROOT=""
DRY_RUN=0

usage() {
  cat >&2 <<'EOF'
usage: maintain-self-heal.sh all --repo-root DIR [--dry-run]
       maintain-self-heal.sh receipts --repo-root DIR [--dry-run]
       maintain-self-heal.sh worktrees --repo-root DIR [--dry-run]
EOF
  exit 2
}

die() { printf 'maintain-self-heal: %s\n' "$1" >&2; exit "${2:-1}"; }
log() { printf 'maintain-self-heal: %s\n' "$*" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    all|receipts|worktrees) ACTION=$1; shift ;;
    --repo-root) [ "$#" -ge 2 ] || usage; REPO_ROOT=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$ACTION" ] && [ -n "$REPO_ROOT" ] || usage

# shellcheck source=maintain-paths.sh
. "$SCRIPT_DIR/maintain-paths.sh"
maintain_paths_resolve "$REPO_ROOT" || die "cannot resolve primary repository path" 2
ROOT=$MAINTAIN_ROOT
PRIMARY=$MAINTAIN_PRIMARY
[ "$ROOT" = "$PRIMARY" ] || die "must run from the primary working directory ($PRIMARY), not $ROOT" 1

HEALED=0
RESIDUALS=()

# ---------------------------------------------------------------------------
# Receipts: read-only inventory only. Migration is never automatic (#381) —
# operators must run maintain-delivery.sh migrate-receipt-worktrees explicitly.
# ---------------------------------------------------------------------------
heal_receipts() {
  local out ec
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: would inventory pending receipts (no migration)"
    return 0
  fi
  ec=0
  out=$(bash "$SCRIPT_DIR/maintain-delivery.sh" pending --repo-root "$PRIMARY" 2>&1) || ec=$?
  if [ "$ec" -eq 0 ]; then
    log "receipts inventory ok ($(jq -er 'length' <<<"$out" 2>/dev/null || echo 0) pending)"
    return 0
  fi
  log "receipts inventory failed (ec=$ec): ${out//$'\n'/; }"
  log "hint: exclusive migrate-receipt-worktrees if controller.worktree aliases remain"
  RESIDUALS+=("receipts:$out")
  return 1
}

# ---------------------------------------------------------------------------
# Linked worktrees: coexist (#381). Never auto-remove foreign worktrees.
# Report residual linked trees for human/harness cleanup only.
# ---------------------------------------------------------------------------
heal_worktrees() {
  local rows record candidate extras=0
  rows=$(mktemp) || die "cannot create worktree list"
  if ! git -C "$PRIMARY" worktree list --porcelain -z > "$rows"; then
    rm -f -- "$rows"
    die "cannot list git worktrees"
  fi
  while IFS= read -r -d '' record; do
    case "$record" in
      'worktree '*)
        candidate=${record#worktree }
        if ! candidate="$(cd -- "$candidate" 2>/dev/null && pwd -P)"; then
          continue
        fi
        [ "$candidate" = "$PRIMARY" ] && continue
        extras=$((extras + 1))
        log "linked worktree present (coexist; not removed): $candidate"
        ;;
    esac
  done < "$rows"
  rm -f -- "$rows"
  if [ "$extras" -gt 0 ]; then
    log "linked worktrees coexist ($extras); automatic foreign-worktree removal is disabled"
  fi
  return 0
}

run_all() {
  local ok=0
  heal_worktrees || ok=1
  if bash "$SCRIPT_DIR/maintain-leases.sh" assert-primary-only --repo-root "$PRIMARY" >/dev/null 2>&1; then
    heal_receipts || ok=1
  else
    log "primary gate still blocked after worktree observe"
    ok=1
    RESIDUALS+=("primary-only:still-blocked")
  fi
  if [ "$ok" -eq 0 ] && [ "${#RESIDUALS[@]}" -eq 0 ]; then
    log "ready (healed=$HEALED)"
    exit 0
  fi
  log "residual after heal (healed=$HEALED): ${RESIDUALS[*]}"
  exit 1
}

case "$ACTION" in
  receipts) heal_receipts; exit $? ;;
  worktrees) heal_worktrees; exit $? ;;
  all) run_all ;;
  *) usage ;;
esac
