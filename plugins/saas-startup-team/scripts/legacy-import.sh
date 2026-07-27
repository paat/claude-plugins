#!/usr/bin/env bash
# legacy-import.sh — bounded read-only importer for useful pre-lifecycle artifacts.
# Surfaces brief, workflow, and signoff paths only. Does not revive the delivery
# state machine (no active_role / iteration / handoff mutation). Does not scan
# research trees or full handoff bodies into the new lifecycle path.
#
# Usage:
#   legacy-import.sh [--root DIR] [--json]
#
# Exit: 0 when the scan completes (even if nothing found). 2 on bad args.

set -euo pipefail

ROOT="."
AS_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      ROOT="${2:-}"
      shift 2
      ;;
    --json)
      AS_JSON=1
      shift
      ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "legacy-import: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "legacy-import: --root must be an existing directory" >&2
  exit 2
fi

ROOT=$(cd "$ROOT" && pwd)

exists() { [ -e "$1" ] && echo "$1" || true; }

brief=$(exists "$ROOT/docs/business/brief.md")
human_tasks=$(exists "$ROOT/docs/human-tasks.md")

# Prefer canonical .startup/go-live, then loose go-live/
solution_signoff=$(exists "$ROOT/.startup/go-live/solution-signoff.md")
[ -z "$solution_signoff" ] && solution_signoff=$(exists "$ROOT/go-live/solution-signoff.md")

workflow_registry=$(exists "$ROOT/.startup/workflows/registry.md")
workflows=()
if [ -d "$ROOT/.startup/workflows" ]; then
  while IFS= read -r -d '' f; do
    workflows+=("$f")
  done < <(find "$ROOT/.startup/workflows" -maxdepth 1 -type f -name 'WORKFLOW-*.md' -print0 2>/dev/null | sort -z)
fi

signoffs=()
if [ -d "$ROOT/.startup/signoffs" ]; then
  while IFS= read -r -d '' f; do
    signoffs+=("$f")
  done < <(find "$ROOT/.startup/signoffs" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null | sort -z)
fi

legacy_state=""
if [ -f "$ROOT/.startup/state.json" ]; then
  legacy_state="$ROOT/.startup/state.json"
fi

state_status=""
state_phase=""
state_iteration=""
if [ -n "$legacy_state" ] && command -v jq >/dev/null 2>&1; then
  state_status=$(jq -r '.status // empty' "$legacy_state" 2>/dev/null || true)
  state_phase=$(jq -r '.phase // empty' "$legacy_state" 2>/dev/null || true)
  state_iteration=$(jq -r '.iteration // empty' "$legacy_state" 2>/dev/null || true)
fi

json_escape_array() {
  if command -v jq >/dev/null 2>&1; then
    jq -R -s 'split("\n") | map(select(length>0))'
  else
    echo '[]'
  fi
}

if [ "$AS_JSON" -eq 1 ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "legacy-import: jq required for --json" >&2
    exit 2
  fi
  workflows_json=$(printf '%s\n' "${workflows[@]+"${workflows[@]}"}" | json_escape_array)
  signoffs_json=$(printf '%s\n' "${signoffs[@]+"${signoffs[@]}"}" | json_escape_array)
  jq -n \
    --arg brief "$brief" \
    --arg human_tasks "$human_tasks" \
    --arg solution_signoff "$solution_signoff" \
    --arg workflow_registry "$workflow_registry" \
    --argjson workflows "$workflows_json" \
    --argjson signoffs "$signoffs_json" \
    --arg legacy_state "$legacy_state" \
    --arg state_status "$state_status" \
    --arg state_phase "$state_phase" \
    --arg state_iteration "$state_iteration" \
    '{
      read_only: true,
      revives_state_machine: false,
      brief: (if $brief == "" then null else $brief end),
      human_tasks: (if $human_tasks == "" then null else $human_tasks end),
      solution_signoff: (if $solution_signoff == "" then null else $solution_signoff end),
      workflow_registry: (if $workflow_registry == "" then null else $workflow_registry end),
      workflows: $workflows,
      signoffs: $signoffs,
      legacy_state: (if $legacy_state == "" then null else {
        path: $legacy_state,
        status: (if $state_status == "" then null else $state_status end),
        phase: (if $state_phase == "" then null else $state_phase end),
        iteration: (if $state_iteration == "" then null else $state_iteration end),
        note: "exposed for context only; lifecycle must not write active_role or iteration"
      } end)
    }'
  exit 0
fi

echo "legacy-import (read-only; does not revive state machine)"
echo "root: $ROOT"
echo "brief: ${brief:-"(none)"}"
echo "human_tasks: ${human_tasks:-"(none)"}"
echo "solution_signoff: ${solution_signoff:-"(none)"}"
echo "workflow_registry: ${workflow_registry:-"(none)"}"
echo "workflows: ${#workflows[@]}"
for f in "${workflows[@]+"${workflows[@]}"}"; do echo "  $f"; done
echo "signoffs: ${#signoffs[@]}"
for f in "${signoffs[@]+"${signoffs[@]}"}"; do echo "  $f"; done
if [ -n "$legacy_state" ]; then
  echo "legacy_state: $legacy_state (status=${state_status:-?} phase=${state_phase:-?} iteration=${state_iteration:-?}) — do not mutate"
else
  echo "legacy_state: (none)"
fi
