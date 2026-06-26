#!/usr/bin/env bash
# agent-sync PostToolUse hook: regenerate AGENTS.md when a tracked source file is edited.
# Correct-by-construction (issue #93): rather than only nudging, this regenerates AGENTS.md in the
# same environment that changed the source, so the working tree never drifts. Staging is opt-in via
# AGENT_SYNC_AUTO_STAGE. Non-blocking: every path exits 0. Silent unless the edited file is a
# tracked source under a discoverable sources.json. Degrades to a nudge when no generator is found.

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

# 6. Never react to a generated output being edited (defends against any re-trigger loop and
#    against an output path that happens to also be listed as a source).
while IFS= read -r out; do
  [[ -z "$out" ]] && continue
  if [[ "$(abspath "$out")" == "$abs_edited" ]]; then
    exit 0
  fi
done < <(jq -r '.outputs[]?.path // empty' "$config" 2>/dev/null)

# 7. Compare against each tracked source. On first match, proceed; otherwise stay silent.
match=""
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  if [[ "$(abspath "$rel")" == "$abs_edited" ]]; then
    match="yes"
    break
  fi
done < <(jq -r '.files[]? // empty' "$config" 2>/dev/null)

[[ -z "$match" ]] && exit 0

# 8. Emit a PostToolUse additionalContext message and exit 0 (non-blocking).
emit() {
  jq -n --arg m "$1" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  exit 0
}

# 9. Locate the generator: prefer the repo's vendored copy (the same one CI/`/agent-sync:check`
#    use), fall back to the plugin's bundled copy. If neither exists, degrade to a nudge.
gen=""
# `${CLAUDE_PLUGIN_ROOT:+...}` yields an empty element when the var is unset, so we never probe a
# bare "/scripts/generate.sh" at the filesystem root (which could match a stray system file).
for cand in "$cwd/tools/agent-sync/generate.sh" "$cwd/.agent-sync/generate.sh" "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/generate.sh}"; do
  [[ -n "$cand" && -f "$cand" ]] || continue
  gen="$cand"
  break
done
if [[ -z "$gen" ]]; then
  emit "[agent-sync] Source file changed. Run /agent-sync:generate to update AGENTS.md."
fi

# 10. Regenerate in this same environment (correct-by-construction). Capture output; never abort.
gen_out="$(bash "$gen" --config "$config" --root "$cwd" 2>&1)"; gen_rc=$?

if [[ $gen_rc -ne 0 ]]; then
  emit "[agent-sync] Source changed but AGENTS.md auto-regeneration failed (exit $gen_rc): ${gen_out##*$'\n'}. Run /agent-sync:generate."
fi

# 11. Stage regenerated outputs by default so the derived AGENTS.md rides along with the source
#     change (correct-by-construction commits). Opt out with AGENT_SYNC_AUTO_STAGE=0 (or
#     false/no/off) if you'd rather manage staging yourself.
auto_stage="yes"
case "$(printf '%s' "${AGENT_SYNC_AUTO_STAGE:-}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) auto_stage="" ;;
esac

staged=""
if [[ -n "$auto_stage" ]] && command -v git >/dev/null 2>&1 \
   && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r out; do
    [[ -z "$out" ]] && continue
    if [[ -f "$cwd/$out" ]] && git -C "$cwd" add -- "$out" >/dev/null 2>&1; then
      staged="yes"
    fi
  done < <(jq -r '.outputs[]?.path // empty' "$config" 2>/dev/null)
fi

# 12. Report what happened. "No changes" output means the file was already in sync. Use bash
#     pattern matching (no pipe) so this can't take SIGPIPE under pipefail — the same bug class
#     this change removes from generate.sh (issue #92).
if [[ "$gen_out" == *"[agent-sync] Updated"* ]]; then
  if [[ -n "$staged" ]]; then
    emit "[agent-sync] Source changed; regenerated AGENTS.md and staged it."
  else
    emit "[agent-sync] Source changed; regenerated AGENTS.md (review and commit it alongside your change)."
  fi
else
  emit "[agent-sync] Source changed; AGENTS.md already in sync."
fi
