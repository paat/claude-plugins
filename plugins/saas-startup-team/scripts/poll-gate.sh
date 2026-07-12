#!/usr/bin/env bash
#
# poll-gate.sh - single-shot, non-blocking CI/deploy status probe.
#
# Replaces unbounded `gh ... --watch` blocking waits, which get Exit-143 killed
# on long CI/deploy runs. The orchestrator drives the poll loop and backoff;
# this script only reports one status and returns immediately.
#
# Usage:
#   poll-gate.sh --pr N          [--repo OWNER/REPO]   # PR check-runs
#   poll-gate.sh --run ID        [--repo OWNER/REPO]   # workflow run
#   poll-gate.sh --deploy-sha SHA [--branch NAME] [--workflow NAME] [--repo OWNER/REPO]
#                # workflow run(s) whose headSha equals SHA — never "the latest run"
#
# Prints exactly one of: pending | green | red
#   green   = at least one check exists AND all completed and passed
#   red     = any check failed/cancelled
#   pending = none reported yet, or any still in progress
# Exit 0 on a clean probe; exit 2 on usage error; exit 3 (fail-closed, prints
# "pending") when gh itself errors — a network/auth blip never reads as green.
#
# --deploy-sha binds the deploy watch to the exact merge commit: with --workflow
# only that workflow's matching run counts; without it, every run for the SHA
# must pass. A missing matching run stays pending (the caller's poll budget
# converts sustained pending to red) — it never falls back to the latest run.

set -uo pipefail

MODE=""; TARGET=""; REPO=""; BRANCH=""; WORKFLOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)   MODE="pr";  [ $# -ge 2 ] || { echo "poll-gate: --pr needs a value" >&2; exit 2; }; TARGET="$2"; shift 2 ;;
    --run)  MODE="run"; [ $# -ge 2 ] || { echo "poll-gate: --run needs a value" >&2; exit 2; }; TARGET="$2"; shift 2 ;;
    --deploy-sha) MODE="deploy-sha"; [ $# -ge 2 ] || { echo "poll-gate: --deploy-sha needs a value" >&2; exit 2; }; TARGET="$2"; shift 2 ;;
    --branch) [ $# -ge 2 ] || { echo "poll-gate: --branch needs a value" >&2; exit 2; }; BRANCH="$2"; shift 2 ;;
    --workflow) [ $# -ge 2 ] || { echo "poll-gate: --workflow needs a value" >&2; exit 2; }; WORKFLOW="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || { echo "poll-gate: --repo needs a value" >&2; exit 2; }; REPO="$2"; shift 2 ;;
    *) echo "poll-gate: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] && [ -n "$TARGET" ] || { echo "poll-gate: usage: poll-gate.sh --pr N | --run ID | --deploy-sha SHA [--branch NAME] [--workflow NAME] [--repo OWNER/REPO]" >&2; exit 2; }
if [ "$MODE" != "deploy-sha" ] && { [ -n "$BRANCH" ] || [ -n "$WORKFLOW" ]; }; then
  echo "poll-gate: --branch/--workflow only apply to --deploy-sha" >&2; exit 2
fi

repo_args=()
[ -n "$REPO" ] && repo_args=(--repo "$REPO")

ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT

if [ "$MODE" = "pr" ]; then
  out="$(gh pr checks "$TARGET" "${repo_args[@]}" --json bucket 2>"$ERR")"
  if ! printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1; then
    # No valid JSON: "no checks reported" is a real pending state (gh exits 1);
    # anything else (auth, network, unknown PR) is a gh error → fail closed.
    if grep -qi 'no check' "$ERR"; then echo "pending"; exit 0; fi
    echo "pending"; exit 3
  fi
  if [ "$(printf '%s' "$out" | jq 'length')" -eq 0 ]; then echo "pending"; exit 0; fi
  if printf '%s' "$out" | jq -e 'any(.[]; .bucket=="fail" or .bucket=="cancel")' >/dev/null; then echo "red"; exit 0; fi
  # green only by whitelist: every bucket recognized-passing and >=1 real pass;
  # anything unrecognized (null, missing, future gh values) stays pending — the
  # caller's poll budget converts sustained pending to red, never to green.
  if printf '%s' "$out" | jq -e '(all(.[]; .bucket=="pass" or .bucket=="skipping")) and any(.[]; .bucket=="pass")' >/dev/null; then
    echo "green"; exit 0
  fi
  echo "pending"; exit 0
fi

if [ "$MODE" = "deploy-sha" ]; then
  list_args=(--limit 100 --json databaseId,headSha,status,conclusion)
  [ -n "$WORKFLOW" ] && list_args+=(--workflow "$WORKFLOW")
  [ -n "$BRANCH" ] && list_args+=(--branch "$BRANCH")
  out="$(gh run list "${repo_args[@]}" "${list_args[@]}" 2>"$ERR")"
  gh_rc=$?
  if [ "$gh_rc" -ne 0 ] || ! printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1; then
    echo "pending"; exit 3
  fi
  matches="$(printf '%s' "$out" | jq --arg sha "$TARGET" '[.[] | select(.headSha == $sha)]')"
  # No matching run yet: stays pending — never fall back to the latest run.
  if [ "$(printf '%s' "$matches" | jq 'length')" -eq 0 ]; then echo "pending"; exit 0; fi
  if printf '%s' "$matches" | jq -e 'any(.[]; .status=="completed" and (.conclusion // "") != "" and .conclusion != "success" and .conclusion != "skipped")' >/dev/null; then
    echo "red"; exit 0
  fi
  # Green only by whitelist: every matching run completed successfully (or was
  # skipped) and at least one real success exists; anything else stays pending.
  if printf '%s' "$matches" | jq -e '(all(.[]; .status=="completed" and (.conclusion=="success" or .conclusion=="skipped"))) and any(.[]; .conclusion=="success")' >/dev/null; then
    echo "green"; exit 0
  fi
  echo "pending"; exit 0
fi

# MODE=run — a single workflow run is the unit of green/red.
out="$(gh run view "$TARGET" "${repo_args[@]}" --json status,conclusion 2>"$ERR")"
if ! printf '%s' "$out" | jq -e 'type=="object"' >/dev/null 2>&1; then
  echo "pending"; exit 3
fi
status="$(printf '%s' "$out" | jq -r '.status // empty')"
conclusion="$(printf '%s' "$out" | jq -r '.conclusion // empty')"
[ "$status" = "completed" ] || { echo "pending"; exit 0; }
[ "$conclusion" = "success" ] && { echo "green"; exit 0; }
echo "red"; exit 0
