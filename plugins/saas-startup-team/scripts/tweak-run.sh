#!/usr/bin/env bash
# Apply one prepared interactive tweak under a trapped role and shared diff guard.

set -euo pipefail

PATCH=""; MESSAGE=""; MODE="current"; BRANCH=""; PARENT=""; PUSH=0
ROUTING_MODE="interactive-tweak"
REMOTE="origin"; ROOT=""
usage() {
  echo "usage: tweak-run.sh --patch FILE --message TEXT [--routing-mode interactive-tweak|autonomous] [--mode current|new-branch --branch NAME --parent REF] [--push]" >&2
  exit 2
}
need_value() { [ "$#" -ge 2 ] || usage; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --patch) need_value "$@"; PATCH="$2"; shift 2 ;;
    --message) need_value "$@"; MESSAGE="$2"; shift 2 ;;
    --mode) need_value "$@"; MODE="$2"; shift 2 ;;
    --branch) need_value "$@"; BRANCH="$2"; shift 2 ;;
    --parent) need_value "$@"; PARENT="$2"; shift 2 ;;
    --routing-mode) need_value "$@"; ROUTING_MODE="$2"; shift 2 ;;
    --remote) need_value "$@"; REMOTE="$2"; shift 2 ;;
    --repo-root) need_value "$@"; ROOT="$2"; shift 2 ;;
    --push) PUSH=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if [ -z "$PATCH" ] || [ -z "$MESSAGE" ]; then usage; fi
[ -f "$PATCH" ] || { echo "tweak-run: patch not found: $PATCH" >&2; exit 2; }
case "$MODE" in
  current) : ;;
  new-branch)
    [ -n "$BRANCH" ] && [ -n "$PARENT" ] || usage
    ;;
  *) usage ;;
esac
case "$ROUTING_MODE" in interactive-tweak|autonomous) : ;; *) usage ;; esac
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 2
ROOT="$(cd "$ROOT" && pwd)"
cd "$ROOT"
if ! git diff --cached --quiet -- .startup/runs; then
  echo "tweak-run: staged runtime telemetry must be removed before committing" >&2
  exit 1
fi
initial_dirty="$(git status --porcelain --untracked-files=all | grep -vE '^.. \.startup/runs/' || true)"
[ -z "$initial_dirty" ] || {
  echo "tweak-run: working tree must be clean" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="${SAAS_RUN_ID:-$(bash "$SCRIPT_DIR/agent-events.sh" new-run-id)}"
ATTEMPT="${SAAS_ATTEMPT:-1}"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_SECONDS="$(date +%s)"
ROUTE_FILE="$(mktemp)"
ROUTE_ARGS=()
if [ -n "${SAAS_ROUTING_REASONS:-}" ]; then
  IFS=',' read -r -a reasons <<< "$SAAS_ROUTING_REASONS"
  for reason in "${reasons[@]}"; do
    [ -z "$reason" ] || ROUTE_ARGS+=(--routing-reason "$reason")
  done
fi

bash "$SCRIPT_DIR/agent-events.sh" append --run-id "$RUN_ID" --command "${SAAS_COMMAND:-tweak}" \
  --phase mutation --surface script --profile light --writer-id "supervisor-$RUN_ID" \
  --attempt "$ATTEMPT" --event-type started --started-at "$STARTED_AT" \
  --outcome incomplete "${ROUTE_ARGS[@]}" >/dev/null || {
    rm -f "$ROUTE_FILE"
    echo "tweak-run: could not record start event" >&2
    exit 4
  }

STATE="$ROOT/.startup/state.json"; STATE_EXISTS=0; STATE_BACKUP="$(mktemp)"
if [ -f "$STATE" ]; then
  STATE_EXISTS=1
  cp -p -- "$STATE" "$STATE_BACKUP"
fi

finish() {
  local rc=$? final_rc outcome checks finished duration
  trap - EXIT HUP INT TERM
  if [ "$STATE_EXISTS" -eq 1 ]; then
    rm -rf -- "$STATE" "$STATE.tmp"
    mkdir -p "$(dirname "$STATE")"
    cp -p -- "$STATE_BACKUP" "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  else
    rm -rf -- "$STATE" "$STATE.tmp"
  fi
  rm -f "$ROUTE_FILE" "$STATE_BACKUP"
  final_rc=$rc; outcome=failure; checks=failed
  if [ "$rc" -eq 0 ]; then outcome=success; checks=passed
  elif [ "$rc" -eq 20 ]; then outcome=escalated
  fi
  finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  duration=$(( ($(date +%s) - START_SECONDS) * 1000 ))
  if ! bash "$SCRIPT_DIR/agent-events.sh" append --run-id "$RUN_ID" --command "${SAAS_COMMAND:-tweak}" \
    --phase mutation --surface script --profile light --writer-id "supervisor-$RUN_ID" \
    --attempt "$ATTEMPT" --event-type completed --started-at "$STARTED_AT" \
    --finished-at "$finished" --duration-ms "$duration" --checks "$checks" \
    --outcome "$outcome" "${ROUTE_ARGS[@]}" >/dev/null; then
    echo "tweak-run: could not record completion event" >&2
    [ "$final_rc" -ne 0 ] || final_rc=4
  fi
  exit "$final_rc"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$MODE" = new-branch ]; then
  git show-ref --verify --quiet "refs/heads/$BRANCH" && {
    echo "tweak-run: branch exists: $BRANCH" >&2
    exit 1
  }
  git checkout -b "$BRANCH" "$PARENT"
fi
if [ -f "$STATE" ]; then
  jq '.active_role = "team-lead-tweak"' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
fi

cleanup_rejected_patch() {
  git reset --hard "$BASE_SHA" >/dev/null
  if [ "$MODE" = new-branch ]; then
    git checkout "$PARENT" >/dev/null
    git branch -D "$BRANCH" >/dev/null
  fi
}

reject_scope() {
  echo "tweak-run: post-diff containment requires escalation" >&2
  cleanup_rejected_patch
  exit 20
}

BASE_SHA="$(git rev-parse HEAD)"
if ! git apply --check "$PATCH" || ! git apply --index "$PATCH"; then
  [ "$ROUTING_MODE" != autonomous ] || cleanup_rejected_patch
  exit 1
fi
if ! bash "$SCRIPT_DIR/check-staged-size.sh"; then reject_scope; fi
if git diff --cached --name-status | awk '$1 != "M" { bad=1 } END { exit bad ? 0 : 1 }' \
  || git diff --cached --numstat | awk '$1 == "-" || $2 == "-" { bad=1 } END { exit bad ? 0 : 1 }' \
  || git diff --cached --summary | grep -qE '(create|delete|rename|mode change)'; then
  echo "tweak-run: additions, deletions, renames, mode-only, and binary edits require escalation" >&2
  reject_scope
fi
route_rc=0
bash "$SCRIPT_DIR/delivery-route.sh" check-diff --base "$BASE_SHA" --cached \
  > "$ROUTE_FILE" || route_rc=$?
if [ "$route_rc" -ne 0 ] || [ "$(jq -r .profile "$ROUTE_FILE")" != light ] \
  || { [ "$ROUTING_MODE" = autonomous ] && [ "$(jq -r .ui_touch "$ROUTE_FILE")" = true ]; }; then
  if [ "$route_rc" -eq 2 ]; then cleanup_rejected_patch; exit 2; fi
  reject_scope
fi

checked_tree="$(git write-tree)"
commit_rc=0
git commit -m "$MESSAGE" || commit_rc=$?
if [ "$commit_rc" -ne 0 ]; then
  [ "$ROUTING_MODE" != autonomous ] || cleanup_rejected_patch
  exit "$commit_rc"
fi
if [ "$(git rev-parse 'HEAD^{tree}')" != "$checked_tree" ]; then
  echo "tweak-run: commit hook expanded the checked diff; commit rolled back and push blocked" >&2
  git reset --mixed "$BASE_SHA" >/dev/null
  [ "$ROUTING_MODE" != autonomous ] || cleanup_rejected_patch
  exit 1
fi
unexpected="$(git status --porcelain --untracked-files=all \
  | grep -vE '^[ MARC?][MD?] \.startup/state\.json$|^.. \.startup/runs/' || true)"
if [ -n "$unexpected" ]; then
  echo "tweak-run: commit hook left changes outside runtime state; push blocked" >&2
  [ "$ROUTING_MODE" != autonomous ] || cleanup_rejected_patch
  exit 1
fi
if [ "$PUSH" -eq 1 ]; then
  push_rc=0
  git push -u "$REMOTE" HEAD || push_rc=$?
  if [ "$push_rc" -ne 0 ]; then
    if [ "$ROUTING_MODE" = autonomous ] && [ "$MODE" = new-branch ]; then
      remote_ref=""
      if remote_ref="$(git ls-remote --heads "$REMOTE" "$BRANCH")"; then
        if [ -n "$remote_ref" ]; then
          remote_sha="${remote_ref%%[[:space:]]*}"
          if [ "$remote_sha" = "$(git rev-parse HEAD)" ]; then
            git push "$REMOTE" --delete "$BRANCH" >/dev/null 2>&1 || exit "$push_rc"
          else
            echo "tweak-run: remote branch changed; automatic cleanup refused" >&2
            exit "$push_rc"
          fi
        fi
        cleanup_rejected_patch
      fi
    fi
    exit "$push_rc"
  fi
fi
echo "tweak-run: committed $(git rev-parse --short HEAD)"
