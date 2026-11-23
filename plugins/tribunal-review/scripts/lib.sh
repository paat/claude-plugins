#!/usr/bin/env bash
# Shared tribunal-review script helpers (public facade).
set -u

TRIBUNAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-provider.sh
. "$TRIBUNAL_LIB_DIR/lib-provider.sh"

# A CLI that failed because its plan window or balance is used up. Timeouts are never
# plan limits; only the tails are read, where CLIs print the terminal error.
tribunal_plan_limited() {
  local exit_code="$1" f kind
  shift
  case "$exit_code" in 124|137) return 1 ;; esac
  for f in "$@"; do
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    kind="$(tail -c 4096 -- "$f" 2>/dev/null | provider_classify_failure_stream)"
    [ "$kind" = limit ] && return 0
  done
  return 1
}

# Run a provider CLI with a scrubbed environment: a base allowlist, the provider's own
# variables (names or PREFIX* patterns before --), and the names in TRIBUNAL_LEG_ENV, so a
# leg's shell cannot read controller secrets. The Codex leg scrubs its shell with
# shell_environment_policy; Grok has no shell.
tribunal_leg_env() {  # tribunal_leg_env [NAME|PREFIX*]... -- COMMAND [ARG]...
  provider_leg_env_run run TRIBUNAL_LEG_ENV warn "$@"
}

tribunal_claude_authenticated() {
  provider_claude_authenticated "${TRIBUNAL_AUTH_TIMEOUT_SECONDS:-20}"
}

# Host path to Grok CLI credentials (pre-isolation GROK_HOME/HOME).
tribunal_grok_auth_file() {
  provider_grok_auth_file
}

# True when auth.json is parseable JSON with at least one non-empty access token
# (OIDC/API session field "key", or access_token). Used for preflight + write-back.
tribunal_grok_auth_json_usable() {
  provider_grok_auth_json_usable "${1:-}"
}

# Usable for autonomous Grok legs: XAI_API_KEY in env, or a live session in auth.json.
# Max/OAuth users need a durable refresh_token in auth.json (issue #374).
tribunal_grok_authenticated() {
  provider_grok_authenticated
}

# Latest expires_at string across credential objects (empty if none). Lexicographic
# ISO-8601 compares work for the Grok CLI's Zulu timestamps.
tribunal_grok_auth_max_expires() {
  provider_grok_auth_max_expires "$1"
}

# Copy isolated auth.json back to the host after OAuth refresh, refusing to regress
# a fresher host expires_at (issue #374).
tribunal_grok_auth_writeback() {
  provider_grok_auth_writeback "${1:-}" "${2:-}" "" tribunal-grok
}

# Plugin root for schema/assets. Explicit TRIBUNAL_PLUGIN_ROOT or harness plugin-root
# variables are authoritative even when the schema is missing (so the runner can fail loud
# instead of silently loading another install — issue #378 / Codex review).
# Fall back to SCRIPT_DIR/.. only when no env root is set.
tribunal_plugin_root() {
  local candidate
  for candidate in \
    "${TRIBUNAL_PLUGIN_ROOT:-}" \
    "${CLAUDE_PLUGIN_ROOT:-}" \
    "${CODEX_PLUGIN_ROOT:-}" \
    "${PLUGIN_ROOT:-}" \
    "${GROK_PLUGIN_ROOT:-}" \
    "${MUSE_PLUGIN_ROOT:-}"; do
    if [ -n "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if [ -n "${SCRIPT_DIR:-}" ] && [ -d "$SCRIPT_DIR/.." ]; then
    (cd "$SCRIPT_DIR/.." && pwd)
    return 0
  fi
  return 1
}

tribunal_review_schema() {
  local root
  if root="$(tribunal_plugin_root)"; then
    printf '%s/schemas/review-output.json\n' "$root"
    return 0
  fi
  printf '%s/../schemas/review-output.json\n' "${SCRIPT_DIR:-.}"
}

# shellcheck source=lib-panel.sh
. "$TRIBUNAL_LIB_DIR/lib-panel.sh"
# shellcheck source=lib-policy-gates.sh
. "$TRIBUNAL_LIB_DIR/lib-policy-gates.sh"
# shellcheck source=lib-prompt.sh
. "$TRIBUNAL_LIB_DIR/lib-prompt.sh"
# shellcheck source=lib-output.sh
. "$TRIBUNAL_LIB_DIR/lib-output.sh"
