#!/usr/bin/env bash
# Model-free environment heal for maintain autonomy.
# Run before treating the host as blocked. Prefer heal → continue over MC-BLOCKED.
#
# Exit 0: primary-only environment is ready (possibly after heals).
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

ROOT="$(cd -- "$REPO_ROOT" && pwd -P)" || die "cannot resolve repository" 2
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git worktree" 2
PRIMARY="$(bash "$SCRIPT_DIR/maintain-leases.sh" primary-root --repo-root "$ROOT")" \
  || die "cannot resolve primary root" 2
[ "$ROOT" = "$PRIMARY" ] || die "must run from the primary working directory ($PRIMARY), not $ROOT" 1

HEALED=0
RESIDUALS=()

# ---------------------------------------------------------------------------
# Receipts: migrate path aliases (/workspace → physical primary) via pending.
# Terminal receipts are validated then skipped; aliases must not fail the inventory.
# ---------------------------------------------------------------------------
heal_receipts() {
  local out ec
  ec=0
  out=$(bash "$SCRIPT_DIR/maintain-delivery.sh" pending --repo-root "$PRIMARY" 2>&1) || ec=$?
  if [ "$ec" -eq 0 ]; then
    log "receipts inventory ok ($(jq -er 'length' <<<"$out" 2>/dev/null || echo 0) pending)"
    return 0
  fi
  # One more pass after worktree heal may clear malformed-route residues.
  log "receipts inventory failed (ec=$ec): ${out//$'\n'/; }"
  RESIDUALS+=("receipts:$out")
  return 1
}

# ---------------------------------------------------------------------------
# Foreign git worktrees: remove leftovers that carry no unique unpushed commits.
# Never invent product work; never leave the portfolio paused on disposable trees.
# ---------------------------------------------------------------------------
worktree_is_disposable_path() {
  local path=$1
  case "$path" in
    "$PRIMARY/.worktrees/maintain"|"$PRIMARY/.worktrees/maintain"/*) return 0 ;;
    /tmp/tribunal-*|"${TMPDIR:-/tmp}"/tribunal-*) return 0 ;;
    */saas-tribunal-*|*tribunal-pr*) return 0 ;;
  esac
  return 1
}

worktree_has_unique_commits() {
  local path=$1 head default_ref ahead
  head=$(git -C "$path" rev-parse HEAD 2>/dev/null) || return 0
  default_ref=$(git -C "$PRIMARY" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$default_ref" ]; then
    default_ref=${default_ref#refs/remotes/}
  else
    default_ref=origin/main
  fi
  if git -C "$PRIMARY" rev-parse -q --verify "$default_ref" >/dev/null 2>&1; then
    ahead=$(git -C "$PRIMARY" rev-list --count "$default_ref..$head" 2>/dev/null || echo 1)
  else
    ahead=$(git -C "$PRIMARY" rev-list --count "HEAD..$head" 2>/dev/null || echo 1)
  fi
  [ "${ahead:-1}" -gt 0 ]
}

worktree_is_clean() {
  local path=$1
  git -C "$path" diff --quiet -- && git -C "$path" diff --cached --quiet -- \
    && [ -z "$(git -C "$path" ls-files --others --exclude-standard)" ]
}

remove_worktree() {
  local path=$1 reason=$2
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: would remove worktree $path ($reason)"
    HEALED=$((HEALED + 1))
    return 0
  fi
  if git -C "$PRIMARY" worktree remove --force -- "$path" 2>/dev/null; then
    log "removed worktree $path ($reason)"
    HEALED=$((HEALED + 1))
    return 0
  fi
  # Path may already be gone; prune handles the registration.
  log "worktree remove failed for $path — will prune"
  return 1
}

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
          # Registration points at a missing dir — prune later.
          continue
        fi
        [ "$candidate" = "$PRIMARY" ] && continue
        if worktree_is_disposable_path "$candidate"; then
          remove_worktree "$candidate" "disposable-path" || true
          continue
        fi
        if ! worktree_has_unique_commits "$candidate"; then
          # Fully merged / no unique commits: safe to drop even if dirty tree noise.
          remove_worktree "$candidate" "no-unique-commits" || true
          continue
        fi
        # Expeditor path: pin unique commits on a primary-reachable branch, then
        # remove the linked worktree so primary-only maintain can resume the WIP.
        if preserve_unique_commits_on_primary "$candidate"; then
          remove_worktree "$candidate" "preserved-on-primary-branch" || true
          continue
        fi
        extras=$((extras + 1))
        RESIDUALS+=("foreign-worktree:$candidate")
        log "residual foreign worktree (could not preserve unique commits): $candidate"
        ;;
    esac
  done < "$rows"
  rm -f -- "$rows"
  if [ "$DRY_RUN" -eq 0 ]; then
    git -C "$PRIMARY" worktree prune >/dev/null 2>&1 || true
  else
    log "dry-run: would git worktree prune"
  fi
  [ "$extras" -eq 0 ]
}

# Keep unique worktree commits reachable from a primary branch, then the worktree
# can be removed safely. Prefer existing branch name; otherwise mint maintain/heal-*.
preserve_unique_commits_on_primary() {
  local path=$1 head short branch existing
  head=$(git -C "$path" rev-parse HEAD 2>/dev/null) || return 1
  short=$(git -C "$PRIMARY" rev-parse --short "$head" 2>/dev/null || printf '%.7s' "$head")
  branch=$(git -C "$path" symbolic-ref -q --short HEAD 2>/dev/null || true)
  case "$branch" in
    ''|HEAD|main|master) branch="maintain/heal-$short" ;;
  esac
  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: would pin $head as branch $branch then remove $path"
    HEALED=$((HEALED + 1))
    return 0
  fi
  if git -C "$PRIMARY" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    existing=$(git -C "$PRIMARY" rev-parse "refs/heads/$branch")
    if [ "$existing" = "$head" ]; then
      log "branch $branch already pins $short"
      return 0
    fi
    if git -C "$PRIMARY" merge-base --is-ancestor "$existing" "$head" 2>/dev/null; then
      git -C "$PRIMARY" branch -f "$branch" "$head" \
        || { log "cannot fast-forward $branch to $short"; return 1; }
      log "fast-forwarded $branch to $short"
      HEALED=$((HEALED + 1))
      return 0
    fi
    # Diverged: mint a heal branch so nothing is lost.
    branch="maintain/heal-$short"
  fi
  if git -C "$PRIMARY" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    log "heal branch $branch already exists"
    return 0
  fi
  git -C "$PRIMARY" branch "$branch" "$head" \
    || { log "cannot create branch $branch at $short"; return 1; }
  log "pinned unique commits as $branch ($short) for primary resume"
  HEALED=$((HEALED + 1))
  return 0
}

run_all() {
  local ok=0
  heal_worktrees || ok=1
  # Receipts after worktrees: primary-only gate must pass for delivery inventory.
  if bash "$SCRIPT_DIR/maintain-leases.sh" assert-primary-only --repo-root "$PRIMARY" >/dev/null 2>&1; then
    heal_receipts || ok=1
  else
    log "primary-only still blocked after worktree heal"
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
