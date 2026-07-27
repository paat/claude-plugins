#!/usr/bin/env bash
# legacy-import.sh — bounded read-only importer for useful pre-lifecycle artifacts.
# Surfaces brief, workflow, research, and signoff paths without reviving the
# delivery state machine (no active_role / iteration / handoff mutation).
#
# Usage:
#   legacy-import.sh [--root DIR] [--json]
#
# Exit: 0 always when the scan completes (even if nothing found). 2 on bad args.

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

# Resolve to absolute for stable output
ROOT=$(cd "$ROOT" && pwd)

exists() { [ -e "$1" ] && echo "$1" || true; }

brief=$(exists "$ROOT/docs/business/brief.md")
human_tasks=$(exists "$ROOT/docs/human-tasks.md")
solution_signoff=$(exists "$ROOT/go-live/solution-signoff.md")
# Prefer .startup/go-live (canonical) then loose go-live/
[ -z "$solution_signoff" ] && solution_signoff=$(exists "$ROOT/.startup/go-live/solution-signoff.md")

workflow_registry=$(exists "$ROOT/.startup/workflows/registry.md")
workflows=()
if [ -d "$ROOT/.startup/workflows" ]; then
  while IFS= read -r -d '' f; do
    workflows+=("$f")
  done < <(find "$ROOT/.startup/workflows" -type f -name 'WORKFLOW-*.md' -print0 2>/dev/null | sort -z)
fi

research=()
if [ -d "$ROOT/docs/research" ]; then
  while IFS= read -r -d '' f; do
    research+=("$f")
  done < <(find "$ROOT/docs/research" -type f \( -name '*.md' -o -name '*.txt' \) -print0 2>/dev/null | sort -z)
fi

signoffs=()
if [ -d "$ROOT/.startup/signoffs" ]; then
  while IFS= read -r -d '' f; do
    signoffs+=("$f")
  done < <(find "$ROOT/.startup/signoffs" -type f -name '*.md' -print0 2>/dev/null | sort -z)
fi

# Legacy handoffs: list paths only (content is not authoritative for new runs)
handoffs=()
if [ -d "$ROOT/.startup/handoffs" ]; then
  while IFS= read -r -d '' f; do
    case "$(basename "$f")" in
      INDEX.md) continue ;;
    esac
    handoffs+=("$f")
  done < <(find "$ROOT/.startup/handoffs" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null | sort -z)
fi

legacy_state=""
if [ -f "$ROOT/.startup/state.json" ]; then
  legacy_state="$ROOT/.startup/state.json"
fi

# Read-only summary fields from legacy state (never mutate)
state_status=""
state_phase=""
state_iteration=""
if [ -n "$legacy_state" ] && command -v jq >/dev/null 2>&1; then
  state_status=$(jq -r '.status // empty' "$legacy_state" 2>/dev/null || true)
  state_phase=$(jq -r '.phase // empty' "$legacy_state" 2>/dev/null || true)
  state_iteration=$(jq -r '.iteration // empty' "$legacy_state" 2>/dev/null || true)
fi

json_escape_array() {
  # stdin: paths one per line → JSON string array
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
  research_json=$(printf '%s\n' "${research[@]+"${research[@]}"}" | json_escape_array)
  signoffs_json=$(printf '%s\n' "${signoffs[@]+"${signoffs[@]}"}" | json_escape_array)
  handoffs_json=$(printf '%s\n' "${handoffs[@]+"${handoffs[@]}"}" | json_escape_array)
  jq -n \
    --arg brief "$brief" \
    --arg human_tasks "$human_tasks" \
    --arg solution_signoff "$solution_signoff" \
    --arg workflow_registry "$workflow_registry" \
    --argjson workflows "$workflows_json" \
    --argjson research "$research_json" \
    --argjson signoffs "$signoffs_json" \
    --argjson handoffs "$handoffs_json" \
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
      research: $research,
      signoffs: $signoffs,
      handoffs_listed_only: $handoffs,
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
echo "research: ${#research[@]}"
for f in "${research[@]+"${research[@]}"}"; do echo "  $f"; done
echo "signoffs: ${#signoffs[@]}"
for f in "${signoffs[@]+"${signoffs[@]}"}"; do echo "  $f"; done
echo "handoffs_listed_only: ${#handoffs[@]}"
for f in "${handoffs[@]+"${handoffs[@]}"}"; do echo "  $f"; done
if [ -n "$legacy_state" ]; then
  echo "legacy_state: $legacy_state (status=${state_status:-?} phase=${state_phase:-?} iteration=${state_iteration:-?}) — do not mutate"
else
  echo "legacy_state: (none)"
fi
