#!/usr/bin/env bash
# agent-sync PostToolUse hook: remind to regenerate AGENTS.md when a tracked source file is edited.
# Silent (exit 0, no output) on every path EXCEPT: a sources.json exists under cwd AND the edited
# file is one of its tracked sources. Missing jq, malformed input, or no match -> silent exit 0.

set -uo pipefail

# 1. Read hook payload from stdin.
payload="$(cat 2>/dev/null || true)"
[[ -z "$payload" ]] && exit 0

# 2. jq is required; if absent, stay silent (jq is a documented agent-sync prerequisite).
command -v jq >/dev/null 2>&1 || exit 0

# 3. Extract the edited file path and the working directory.
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"
[[ -z "$file_path" ]] && exit 0
[[ -z "$cwd" ]] && cwd="$PWD"

# 4. Locate sources.json directly under cwd (non-recursive, matching generate.sh auto-detect).
#    Repo root == cwd, so tracked relative paths resolve against cwd.
config=""
for candidate in "tools/agent-sync/sources.json" ".agent-sync/sources.json"; do
  if [[ -f "$cwd/$candidate" ]]; then
    config="$cwd/$candidate"
    break
  fi
done
[[ -z "$config" ]] && exit 0

# 5. Resolve a path to its canonical absolute form (parent resolved via subshell cd; portable).
abspath() {
  local p="$1" d="" b=""
  case "$p" in /*) ;; *) p="$cwd/$p" ;; esac
  d="$(dirname "$p")"; b="$(basename "$p")"
  ( cd "$d" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$b" ) || printf '%s' "$p"
}

abs_edited="$(abspath "$file_path")"

# 6. Compare against each tracked source. On first match, emit reminder; otherwise stay silent.
match=""
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  if [[ "$(abspath "$rel")" == "$abs_edited" ]]; then
    match="yes"
    break
  fi
done < <(jq -r '.files[]? // empty' "$config" 2>/dev/null)

[[ -z "$match" ]] && exit 0

# 7. Match: feed the reminder to Claude as additionalContext (faithful to the old prompt hook).
msg="[agent-sync] Source file changed. Run /agent-sync:generate to update AGENTS.md."
jq -n --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
exit 0
