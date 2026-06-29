#!/usr/bin/env bash
# agent-sync PostToolUse hook.
#
# Runtime modes:
# - Claude Code: regenerate AGENTS.md when a tracked Claude source file is edited.
# - Codex: mirror root AGENTS.md to root CLAUDE.md. AGENTS.md is the only source of truth.
#
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
[[ -z "$cwd" ]] && cwd="$PWD"
if [[ -z "$file_path" ]]; then
  if [[ -n "${CODEX_HOME:-}" || -n "${CODEX_MANAGED_BY_NPM:-}" || -n "${CODEX_MANAGED_BY_BUN:-}" || -n "${CODEX_MANAGED_PACKAGE_ROOT:-}" ]]; then
    file_path="__agent_sync_unknown_file_path__"
  else
    exit 0
  fi
fi

# 4. Resolve a path to its canonical absolute form (parent resolved via subshell cd; portable).
abspath() {
  local p="$1" d="" b=""
  case "$p" in /*) ;; *) p="$cwd/$p" ;; esac
  d="$(dirname "$p")"; b="$(basename "$p")"
  ( cd "$d" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$b" ) || printf '%s' "$p"
}

emit() {
  jq -n --arg m "$1" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  exit 0
}

is_codex_runtime() {
  [[ -n "${CODEX_HOME:-}" ]] && return 0
  [[ -n "${CODEX_MANAGED_BY_NPM:-}" ]] && return 0
  [[ -n "${CODEX_MANAGED_BY_BUN:-}" ]] && return 0
  [[ -n "${CODEX_MANAGED_PACKAGE_ROOT:-}" ]] && return 0
  return 1
}

auto_stage_enabled() {
  case "$(printf '%s' "${AGENT_SYNC_AUTO_STAGE:-}" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) return 1 ;;
  esac
  return 0
}

codex_should_sync_agents_to_claude() {
  local agents_abs edited_abs
  agents_abs="$(abspath "AGENTS.md")"
  edited_abs="$(abspath "$file_path")"

  if [[ "$edited_abs" == "$agents_abs" ]]; then
    return 0
  fi

  # Codex apply_patch payloads may not expose a single file_path. If the payload
  # shape changes and file_path is unavailable, fall back to git drift detection.
  if [[ "$file_path" == "__agent_sync_unknown_file_path__" ]] \
     && command -v git >/dev/null 2>&1 \
     && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$cwd" diff --quiet -- AGENTS.md 2>/dev/null || return 0
    git -C "$cwd" diff --cached --quiet -- AGENTS.md 2>/dev/null || return 0
  fi

  return 1
}

sync_agents_to_claude_for_codex() {
  local agents="$cwd/AGENTS.md"
  local claude="$cwd/CLAUDE.md"

  [[ -f "$agents" ]] || exit 0
  codex_should_sync_agents_to_claude || exit 0

  if [[ -f "$claude" ]] && cmp -s "$agents" "$claude"; then
    emit "[agent-sync] AGENTS.md changed; CLAUDE.md already in sync."
  fi

  cat "$agents" > "$claude" || emit "[agent-sync] AGENTS.md changed but CLAUDE.md mirror failed."

  staged=""
  if auto_stage_enabled && command -v git >/dev/null 2>&1 \
     && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && git -C "$cwd" add -- CLAUDE.md >/dev/null 2>&1; then
    staged="yes"
  fi

  if [[ -n "$staged" ]]; then
    emit "[agent-sync] AGENTS.md changed; mirrored it to CLAUDE.md and staged CLAUDE.md."
  fi
  emit "[agent-sync] AGENTS.md changed; mirrored it to CLAUDE.md."
}

if is_codex_runtime; then
  sync_agents_to_claude_for_codex
fi

# 5. Locate sources.json directly under cwd (non-recursive, matching generate.sh auto-detect).
#    Repo root == cwd, so tracked relative paths resolve against cwd.
config=""
for candidate in "tools/agent-sync/sources.json" ".agent-sync/sources.json"; do
  if [[ -f "$cwd/$candidate" ]]; then
    config="$cwd/$candidate"
    break
  fi
done
[[ -z "$config" ]] && exit 0

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
staged=""
if auto_stage_enabled && command -v git >/dev/null 2>&1 \
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
