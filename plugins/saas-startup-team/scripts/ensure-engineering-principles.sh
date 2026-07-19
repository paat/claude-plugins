#!/usr/bin/env bash
#
# ensure-engineering-principles.sh — install KISS/YAGNI/DRY project guidance.
#
# Idempotent. Writes a managed block into CLAUDE.md and ensures AGENTS.md sees
# the same content (symlink to CLAUDE.md when possible, else its own block).
#
# Usage:
#   ensure-engineering-principles.sh [--root DIR] [--plugin-root DIR] [--dry-run]
#
# Exit: 0 always for hook safety (prints actions on stderr when changing files).
#       2 only for usage errors when invoked as a CLI (not from hooks).
#
set -euo pipefail

ROOT="."
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-}}"
DRY_RUN=0
STRICT=0

_die() { echo "ensure-engineering-principles: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --root)        [ $# -ge 2 ] || _die "--root needs a value"; ROOT="$2"; shift 2 ;;
    --plugin-root) [ $# -ge 2 ] || _die "--plugin-root needs a value"; PLUGIN_ROOT="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --strict)      STRICT=1; shift ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) _die "unknown arg: $1" ;;
  esac
done

if [ -z "$PLUGIN_ROOT" ]; then
  # Resolve relative to this script: scripts/ → plugin root
  PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

TEMPLATE="$PLUGIN_ROOT/templates/claude-md-engineering-principles.md"
[ -f "$TEMPLATE" ] || {
  echo "ensure-engineering-principles: template missing: $TEMPLATE" >&2
  [ "$STRICT" = 1 ] && exit 2
  exit 0
}

ROOT="$(cd "$ROOT" && pwd)"
START_MARK='<!-- saas-startup-team:engineering-principles:start -->'
END_MARK='<!-- saas-startup-team:engineering-principles:end -->'

_block() {
  # Managed block body (markers + template content)
  printf '%s\n' "$START_MARK"
  # Strip a leading blank line from template if present
  cat "$TEMPLATE"
  printf '%s\n' "$END_MARK"
}

_has_complete_principles() {
  local f="$1"
  [ -f "$f" ] || return 1
  # Prefer managed block: start+end + all three markers inside the file
  if grep -qF "$START_MARK" "$f" && grep -qF "$END_MARK" "$f" \
    && grep -qF '**KISS**' "$f" && grep -qF '**YAGNI**' "$f" && grep -qF '**DRY**' "$f"; then
    return 0
  fi
  # Legacy heading without managed markers: still require all three principle bold labels
  if grep -qE '^## Engineering principles[[:space:]]*$' "$f" \
    && grep -qF '**KISS**' "$f" && grep -qF '**YAGNI**' "$f" && grep -qF '**DRY**' "$f"; then
    return 0
  fi
  return 1
}

_write_file() {
  local path="$1" content="$2"
  if [ "$DRY_RUN" = 1 ]; then
    echo "ensure-engineering-principles: [dry-run] would write $path" >&2
    return 0
  fi
  printf '%s' "$content" > "$path"
}

_append_block() {
  local f="$1"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$f" ] && [ -s "$f" ]; then
    cat "$f" > "$tmp"
    # Ensure trailing newline before block
    [ -z "$(tail -c 1 "$tmp" 2>/dev/null | tr -d '\n' || true)" ] || printf '\n' >> "$tmp"
    printf '\n' >> "$tmp"
  else
    printf '# Project guidance\n\n' > "$tmp"
  fi
  _block >> "$tmp"
  if [ "$DRY_RUN" = 1 ]; then
    echo "ensure-engineering-principles: [dry-run] would append block to $f" >&2
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$f"
  echo "ensure-engineering-principles: installed principles in $f" >&2
}

_replace_or_install() {
  local f="$1"
  if _has_complete_principles "$f"; then
    return 0
  fi
  # If managed markers exist but incomplete, replace the marked region
  if [ -f "$f" ] && grep -qF "$START_MARK" "$f" && grep -qF "$END_MARK" "$f"; then
    local tmp
    tmp="$(mktemp)"
    awk -v start="$START_MARK" -v end="$END_MARK" '
      $0 == start { skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$f" > "$tmp"
    # Trim trailing blank lines then append fresh block
    # shellcheck disable=SC2016
    if [ -s "$tmp" ]; then
      printf '\n' >> "$tmp"
    else
      printf '# Project guidance\n\n' > "$tmp"
    fi
    _block >> "$tmp"
    if [ "$DRY_RUN" = 1 ]; then
      echo "ensure-engineering-principles: [dry-run] would refresh managed block in $f" >&2
      rm -f "$tmp"
      return 0
    fi
    mv "$tmp" "$f"
    echo "ensure-engineering-principles: refreshed principles in $f" >&2
    return 0
  fi
  # Incomplete heading without markers: append managed block (keep old text; agents see full principles)
  _append_block "$f"
}

_realpath() {
  # Portable resolve; empty on failure
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$p" 2>/dev/null || realpath "$p" 2>/dev/null || true
  else
    (cd "$(dirname "$p")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")") || true
  fi
}

_ensure_claude() {
  local claude="$ROOT/CLAUDE.md"
  # Symlink first: [ ! -e ] is true for dangling links, and printf > follows them
  # outside the project. Never create through a link; resolve or replace it.
  # Dangling = -L && ! -e (portable; does not require readlink -f).
  if [ -L "$claude" ]; then
    if [ ! -e "$claude" ]; then
      echo "ensure-engineering-principles: warning: dangling CLAUDE.md symlink; replacing with a real file" >&2
      if [ "$DRY_RUN" = 1 ]; then
        echo "ensure-engineering-principles: [dry-run] would replace dangling CLAUDE.md" >&2
        return 0
      fi
      rm -f "$claude"
    else
      local target
      target="$(readlink -f "$claude" 2>/dev/null || true)"
      [ -n "$target" ] || target="$(_realpath "$claude")"
      if [ -z "$target" ] || [ ! -e "$target" ]; then
        echo "ensure-engineering-principles: warning: could not resolve CLAUDE.md symlink; skipping" >&2
        return 0
      fi
      case "$target" in
        "$ROOT"/*|"$ROOT") _replace_or_install "$target" ;;
        *)
          echo "ensure-engineering-principles: warning: CLAUDE.md symlink leaves project root ($target); skipping" >&2
          ;;
      esac
      return 0
    fi
  fi
  if [ ! -e "$claude" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "ensure-engineering-principles: [dry-run] would create $claude" >&2
      return 0
    fi
    printf '# Project guidance\n' > "$claude"
  fi
  _replace_or_install "$claude"
}

_ensure_agents() {
  local agents="$ROOT/AGENTS.md"
  local claude="$ROOT/CLAUDE.md"
  local claude_real agents_real

  if [ -L "$agents" ]; then
    agents_real="$(readlink -f "$agents" 2>/dev/null || true)"
    claude_real="$(readlink -f "$claude" 2>/dev/null || true)"
    # Dangling or unresolvable: recreate → CLAUDE.md (do not create a new target file
    # just because realpath synthesizes a path under ROOT).
    if [ -z "$agents_real" ] || [ ! -e "$agents_real" ]; then
      echo "ensure-engineering-principles: warning: dangling AGENTS.md symlink; recreating → CLAUDE.md" >&2
      if [ "$DRY_RUN" = 1 ]; then
        echo "ensure-engineering-principles: [dry-run] would replace dangling AGENTS.md" >&2
        return 0
      fi
      rm -f "$agents"
      ln -s CLAUDE.md "$agents" || {
        printf '# Project guidance\n' > "$agents"
        _replace_or_install "$agents"
      }
      return 0
    fi
    if [ -n "$claude_real" ] && [ "$agents_real" = "$claude_real" ]; then
      # Same path as CLAUDE.md — already ensured
      return 0
    fi
    case "$agents_real" in
      "$ROOT"/*|"$ROOT")
        _replace_or_install "$agents_real"
        ;;
      *)
        echo "ensure-engineering-principles: warning: AGENTS.md symlink leaves project ($agents_real); writing real AGENTS.md" >&2
        if [ "$DRY_RUN" = 1 ]; then
          return 0
        fi
        rm -f "$agents"
        printf '# Project guidance\n' > "$agents"
        _replace_or_install "$agents"
        ;;
    esac
    return 0
  fi

  if [ -f "$agents" ]; then
    _replace_or_install "$agents"
    return 0
  fi

  # Missing AGENTS.md — prefer symlink to CLAUDE.md
  if [ "$DRY_RUN" = 1 ]; then
    echo "ensure-engineering-principles: [dry-run] would create AGENTS.md → CLAUDE.md" >&2
    return 0
  fi
  if [ -e "$claude" ] || [ -L "$claude" ]; then
    ln -s CLAUDE.md "$agents" 2>/dev/null || {
      printf '# Project guidance\n' > "$agents"
      _replace_or_install "$agents"
    }
  else
    printf '# Project guidance\n' > "$agents"
    _replace_or_install "$agents"
  fi
  echo "ensure-engineering-principles: ensured AGENTS.md under $ROOT" >&2
}

_ensure_claude
_ensure_agents
exit 0
