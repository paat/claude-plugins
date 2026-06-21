#!/usr/bin/env bash
# agent-sync: lint Claude Code config for doc-drift and rules-file bloat.
# Dependencies: bash 4+, jq, grep, awk, sort, sed. Deterministic, vendorable.
set -euo pipefail
export LC_ALL=C

CONFIG_PATH=""
REPO_ROOT=""

# --- CLI parsing (mirrors generate.sh) ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ -z "${2:-}" ]] && { echo "[agent-sync lint] --config requires a path" >&2; exit 2; }
      CONFIG_PATH="$2"; shift 2 ;;
    --root)
      [[ -z "${2:-}" ]] && { echo "[agent-sync lint] --root requires a path" >&2; exit 2; }
      REPO_ROOT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: lint.sh [--config <path>] [--root <path>]"
      echo ""
      echo "  --config <path>  Path to sources.json (default: auto-detect)"
      echo "  --root <path>    Project root (default: inferred from config dir)"
      exit 0 ;;
    *)
      echo "[agent-sync lint] Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- Locate config (same precedence as generate.sh) ---
find_config() {
  local search_dir="${1:-.}"
  for candidate in "tools/agent-sync/sources.json" ".agent-sync/sources.json"; do
    [[ -f "$search_dir/$candidate" ]] && { echo "$search_dir/$candidate"; return 0; }
  done
  return 1
}

if [[ -z "$CONFIG_PATH" ]]; then
  if ! CONFIG_PATH="$(find_config "$(pwd)")"; then
    echo "[agent-sync lint] No sources.json found. Run /agent-sync:init to create one." >&2
    exit 2
  fi
fi
[[ -f "$CONFIG_PATH" ]] || { echo "[agent-sync lint] Config not found: $CONFIG_PATH" >&2; exit 2; }
CONFIG_PATH="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$(basename "$CONFIG_PATH")"

# --- Resolve REPO_ROOT (same logic as generate.sh; --root overrides) ---
if [[ -z "$REPO_ROOT" ]]; then
  config_dir="$(dirname "$CONFIG_PATH")"
  parent_dir="$(dirname "$config_dir")"
  dir_name="$(basename "$config_dir")"
  if [[ "$dir_name" == "agent-sync" || "$dir_name" == ".agent-sync" ]]; then
    if [[ "$(basename "$parent_dir")" == "tools" ]]; then
      REPO_ROOT="$(dirname "$parent_dir")"
    else
      REPO_ROOT="$parent_dir"
    fi
  else
    REPO_ROOT="$config_dir"
  fi
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

# --- Dependency check ---
for cmd in jq grep awk sort sed; do
  command -v "$cmd" &>/dev/null || { echo "[agent-sync lint] Missing dependency: $cmd" >&2; exit 2; }
done

# --- Read + parse config ---
CONFIG="$(cat "$CONFIG_PATH")"
jq empty <<<"$CONFIG" 2>/dev/null || { echo "[agent-sync lint] config error: malformed JSON in $CONFIG_PATH" >&2; exit 2; }

# --- Gate: no lint block -> silent success ---
[[ "$(jq 'has("lint")' <<<"$CONFIG")" == "true" ]] || exit 0

# --- Config validation ---
cfg_err() { echo "[agent-sync lint] config error: $1" >&2; exit 2; }

validate_lint_config() {
  local check sev t
  # lint itself must be an object.
  [[ "$(jq -r '.lint | type' <<<"$CONFIG")" == "object" ]] || cfg_err "lint must be an object"
  # every child of lint must be an object.
  [[ "$(jq '.lint | to_entries | all(.value | type == "object")' <<<"$CONFIG")" == "true" ]] \
    || cfg_err "each lint check must be an object"
  for check in contradictions lineBudget softPreferences; do
    [[ "$(jq --arg c "$check" 'has("lint") and (.lint|has($c))' <<<"$CONFIG")" == "true" ]] || continue
    # each configured check must be an object.
    [[ "$(jq -r --arg c "$check" '.lint[$c] | type' <<<"$CONFIG")" == "object" ]] \
      || cfg_err "$check must be an object"
    # severity
    sev="$(jq -r --arg c "$check" '.lint[$c] | if has("severity") then .severity else "warn" end' <<<"$CONFIG")"
    case "$sev" in error|warn|off) ;; *) cfg_err "invalid severity '$sev' for $check (use error|warn|off)";; esac
    # files type
    t="$(jq -r --arg c "$check" '.lint[$c].files | type' <<<"$CONFIG")"
    [[ "$t" == "array" || "$t" == "null" ]] || cfg_err "$check.files must be an array"
    if [[ "$t" == "array" ]]; then
      [[ "$(jq --arg c "$check" '[.lint[$c].files[] | type] | all(. == "string")' <<<"$CONFIG")" == "true" ]] \
        || cfg_err "$check.files must be an array of strings"
    fi
  done
  # lineBudget.max must be a positive integer when present
  if [[ "$(jq 'has("lint") and (.lint|has("lineBudget")) and (.lint.lineBudget|has("max"))' <<<"$CONFIG")" == "true" ]]; then
    [[ "$(jq -r '.lint.lineBudget.max | (type == "number" and . == floor and . > 0)' <<<"$CONFIG")" == "true" ]] \
      || cfg_err "lineBudget.max must be a positive integer"
  fi
  # exclusiveGroups must be an array of arrays of strings when present
  if [[ "$(jq 'has("lint") and (.lint|has("contradictions")) and (.lint.contradictions|has("exclusiveGroups"))' <<<"$CONFIG")" == "true" ]]; then
    [[ "$(jq '.lint.contradictions.exclusiveGroups | type' <<<"$CONFIG")" == '"array"' ]] \
      || cfg_err "contradictions.exclusiveGroups must be an array"
    [[ "$(jq '[.lint.contradictions.exclusiveGroups[] | (type == "array") and ([.[] | type] | all(. == "string"))] | all' <<<"$CONFIG")" == "true" ]] \
      || cfg_err "contradictions.exclusiveGroups must be an array of arrays of strings"
  fi
}
validate_lint_config

# --- Findings collector ---
# Each entry: "SEVERITY<TAB>CHECK_IDX<TAB>SORT_KEY<TAB>MESSAGE"
FINDINGS=()
add_finding() { FINDINGS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"); }

# --- Reporting ---
report() {
  local errors=0 warns=0 entry sev
  for entry in "${FINDINGS[@]:-}"; do
    [[ -z "$entry" ]] && continue
    sev="${entry%%$'\t'*}"
    [[ "$sev" == "error" ]] && errors=$((errors+1))
    [[ "$sev" == "warn" ]] && warns=$((warns+1))
  done
  if ((${#FINDINGS[@]})); then
    printf '%s\n' "${FINDINGS[@]}" | sort -t$'\t' -k2,2 -k3,3 | cut -f4-
  fi
  printf '[agent-sync lint] summary: %d errors, %d warnings\n' "$errors" "$warns"
  if (( errors > 0 )); then exit 1; fi
  exit 0
}

# (checks wired in later tasks call add_finding before report)

report
