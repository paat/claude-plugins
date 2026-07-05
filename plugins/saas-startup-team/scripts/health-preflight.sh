#!/usr/bin/env bash
#
# health-preflight.sh - reusable environment and surface self-diagnosis for SaaS workflows.
#
# Usage:
#   health-preflight.sh [--json] [--markdown] [--require-gh] [--require-codex]
#                       [--check-sync] [--self-repair] [--repo-root DIR] [--plugin-root DIR]
#
# With --require-codex, this also verifies that a fresh Codex worker shell can
# execute under the selected sandbox. CODEX_SANDBOX overrides the default
# workspace-write mode.

set -uo pipefail

JSON=0; MARKDOWN=0; REQUIRE_GH=0; REQUIRE_CODEX=0; CHECK_SYNC=0; SELF_REPAIR=0
REPO_ROOT=""; PLUGIN_ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --markdown) MARKDOWN=1; shift ;;
    --require-gh) REQUIRE_GH=1; shift ;;
    --require-codex) REQUIRE_CODEX=1; shift ;;
    --check-sync) CHECK_SYNC=1; shift ;;
    --self-repair) SELF_REPAIR=1; shift ;;
    --repo-root) [ "$#" -ge 2 ] || { echo "health-preflight: --repo-root needs a value" >&2; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
    --plugin-root) [ "$#" -ge 2 ] || { echo "health-preflight: --plugin-root needs a value" >&2; exit 2; }; PLUGIN_ROOT="$2"; shift 2 ;;
    *) echo "health-preflight: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ "$JSON" -eq 1 ] || [ "$MARKDOWN" -eq 1 ] || MARKDOWN=1

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
if [ -z "$PLUGIN_ROOT" ]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 2
  PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit 2
fi

RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

is_forced_missing() {
  case " ${SAAS_PREFLIGHT_MISSING:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

have_cmd() {
  ! is_forced_missing "$1" && command -v "$1" >/dev/null 2>&1
}

add() {
  check="$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  status_value="$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  message="$(printf '%s' "$3" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"check": "%s", "status": "%s", "message": "%s"}\n' "$check" "$status_value" "$message" >> "$RESULTS"
}

codex_sandbox_mode() {
  printf '%s\n' "${CODEX_SANDBOX:-workspace-write}"
}

codex_permissions_profile() {
  case "$1" in
    danger-full-access) printf '%s\n' ":danger-full-access" ;;
    workspace-write) printf '%s\n' ":workspace" ;;
    read-only) printf '%s\n' ":read-only" ;;
    *) return 1 ;;
  esac
}

compact_output() {
  printf '%s' "$1" \
    | tr '\n' ' ' \
    | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' \
    | cut -c 1-300
}

running_in_container() {
  case "${SAAS_PREFLIGHT_CONTAINER:-auto}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    return 0
  fi
  if [ -r /proc/1/cgroup ] && grep -qaE 'docker|containerd|kubepods|podman|libpod|lxc' /proc/1/cgroup; then
    return 0
  fi
  return 1
}

codex_worker_shell_smoke() {
  sandbox="$(codex_sandbox_mode)"
  if ! profile="$(codex_permissions_profile "$sandbox")"; then
    add "codex:worker-shell" blocker "unsupported CODEX_SANDBOX=$sandbox"
    return
  fi
  if [ "$sandbox" = "read-only" ]; then
    add "codex:worker-shell" blocker "Codex implementation workers require write access; use CODEX_SANDBOX=workspace-write or danger-full-access inside a disposable dev container"
    return
  fi
  if [ "$sandbox" = "danger-full-access" ] && ! running_in_container; then
    add "codex:worker-shell" blocker "Codex worker -s danger-full-access requires a disposable dev container; set CODEX_SANDBOX=workspace-write or run inside a container"
    return
  fi
  if ! have_cmd timeout; then
    add "codex:worker-shell" blocker "timeout missing; cannot bound Codex worker smoke"
    return
  fi
  if ! codex sandbox --help >/dev/null 2>&1; then
    add "codex:worker-shell" blocker "Codex CLI lacks sandbox smoke support; update Codex before launching separate workers"
    return
  fi

  timeout_secs="${SAAS_CODEX_PREFLIGHT_TIMEOUT:-15}"
  case "$timeout_secs" in ''|0|*[!0-9]*) timeout_secs=15 ;; esac

  output="$(timeout "$timeout_secs" codex sandbox --permissions-profile "$profile" -C "$REPO_ROOT" /bin/pwd 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    add "codex:worker-shell" ok "Codex worker shell smoke passed with -s $sandbox"
    return
  fi

  summary="$(compact_output "$output")"
  [ -n "$summary" ] || summary="exit $rc"
  if printf '%s\n' "$output" | grep -qiE 'bwrap|namespace|sandbox'; then
    add "codex:worker-shell" blocker "Codex worker shell sandbox unusable with -s $sandbox: $summary; use CODEX_SANDBOX=danger-full-access inside a disposable dev container or fix unprivileged user namespaces"
  else
    add "codex:worker-shell" blocker "Codex worker shell smoke failed with -s $sandbox: $summary"
  fi
}

bash_major="${BASH_VERSINFO[0]:-0}"
if [ "$bash_major" -ge 4 ]; then add bash ok "bash $BASH_VERSION"; else add bash blocker "bash 4+ is required"; fi

for cmd in git gh jq awk sed timeout; do
  if have_cmd "$cmd"; then
    add "tool:$cmd" ok "$cmd found"
  else
    case "$cmd" in
      gh) [ "$REQUIRE_GH" -eq 1 ] && add "tool:$cmd" blocker "$cmd missing" || add "tool:$cmd" warning "$cmd missing; GitHub actions unavailable" ;;
      *) add "tool:$cmd" blocker "$cmd missing" ;;
    esac
  fi
done

if [ "$REQUIRE_CODEX" -eq 1 ]; then
  if have_cmd codex; then
    add "tool:codex" ok "codex found"
    codex_worker_shell_smoke
  else
    add "tool:codex" blocker "Codex CLI missing"
  fi
elif have_cmd codex; then
  add "tool:codex" ok "codex found"
else
  add "tool:codex" warning "Codex CLI missing; Codex surfaces cannot spawn separate workers"
fi

if have_cmd gh; then
  if gh auth status >/dev/null 2>&1; then
    add "gh:auth" ok "GitHub auth is available"
  elif [ "$REQUIRE_GH" -eq 1 ]; then
    add "gh:auth" blocker "GitHub auth required but unavailable"
  else
    add "gh:auth" warning "GitHub auth unavailable"
  fi
fi

if [ -d "$REPO_ROOT/.git" ] || git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  dirty="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)"
  if [ -z "$dirty" ]; then
    add "git:worktree" ok "worktree clean"
  else
    plugin_changes="$(printf '%s\n' "$dirty" | awk '$2 ~ /^plugins\/saas-startup-team\// {n++} END{print n+0}')"
    other_changes="$(printf '%s\n' "$dirty" | awk '$2 !~ /^plugins\/saas-startup-team\// {n++} END{print n+0}')"
    add "git:worktree" warning "dirty worktree: plugin_changes=$plugin_changes other_changes=$other_changes"
  fi
else
  add "git:repo" warning "not running inside a git worktree"
fi

if [ -f "$REPO_ROOT/.githooks/pre-push" ]; then
  current_hooks="$(git -C "$REPO_ROOT" config --get core.hooksPath 2>/dev/null || true)"
  if [ "$current_hooks" = ".githooks" ]; then
    add "git:hooksPath" ok "core.hooksPath=.githooks"
  elif [ "$SELF_REPAIR" -eq 1 ]; then
    if git -C "$REPO_ROOT" config core.hooksPath .githooks; then
      add "git:hooksPath" auto-fixed "set core.hooksPath=.githooks"
    else
      add "git:hooksPath" blocker "failed to set core.hooksPath=.githooks"
    fi
  else
    add "git:hooksPath" warning "core.hooksPath is not .githooks"
  fi
fi

hooks_json="$PLUGIN_ROOT/hooks/hooks.json"
if [ -f "$hooks_json" ] && have_cmd jq; then
  broken=0
  while IFS= read -r command_text; do
    [ -n "$command_text" ] || continue
    targets="$(printf '%s\n' "$command_text" \
      | sed -nE 's/.*p=([A-Za-z0-9_./-]+).*/\1/p; s/.*\$\{CLAUDE_PLUGIN_ROOT\}\/([A-Za-z0-9_./-]+).*/\1/p')"
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      if [ ! -f "$PLUGIN_ROOT/$target" ]; then
        add "hooks:target" blocker "missing hook target: $target"; broken=$((broken + 1))
      fi
    done <<< "$targets"
  done < <(jq -r '.. | objects | .command? // empty' "$hooks_json" 2>/dev/null)
  [ "$broken" -eq 0 ] && add "hooks:target" ok "hook targets resolve"
fi

if [ "$CHECK_SYNC" -eq 1 ]; then
  if [ -f "$REPO_ROOT/scripts/sync-codex-marketplace.py" ]; then
    if python3 "$REPO_ROOT/scripts/sync-codex-marketplace.py" --check >/dev/null 2>&1; then
      add "codex:sync" ok "Codex marketplace surfaces are in sync"
    elif [ "$SELF_REPAIR" -eq 1 ]; then
      if python3 "$REPO_ROOT/scripts/sync-codex-marketplace.py" >/dev/null 2>&1; then
        add "codex:sync" auto-fixed "regenerated Codex marketplace surfaces"
      else
        add "codex:sync" blocker "failed to regenerate Codex marketplace surfaces"
      fi
    else
      add "codex:sync" blocker "Codex marketplace surfaces are out of sync"
    fi
  else
    add "codex:sync" warning "sync-codex-marketplace.py not present"
  fi
fi

status="ok"
if have_cmd jq; then
  if jq -s -e 'any(.[]; .status=="blocker")' "$RESULTS" >/dev/null 2>&1; then
    status="blocker"
  elif jq -s -e 'any(.[]; .status=="warning" or .status=="auto-fixed")' "$RESULTS" >/dev/null 2>&1; then
    status="warning"
  fi
else
  if grep -Eq '"status"[[:space:]]*:[[:space:]]*"blocker"' "$RESULTS"; then
    status="blocker"
  elif grep -Eq '"status"[[:space:]]*:[[:space:]]*"(warning|auto-fixed)"' "$RESULTS"; then
    status="warning"
  fi
fi

if [ "$JSON" -eq 1 ]; then
  if have_cmd jq; then
    jq -s --arg status "$status" --arg repo "$REPO_ROOT" --arg plugin "$PLUGIN_ROOT" \
      '{status:$status, repo_root:$repo, plugin_root:$plugin, checks:.}' "$RESULTS"
  else
    status_json="$(printf '%s' "$status" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    repo_json="$(printf '%s' "$REPO_ROOT" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    plugin_json="$(printf '%s' "$PLUGIN_ROOT" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '{"status":"%s","repo_root":"%s","plugin_root":"%s","checks":[' "$status_json" "$repo_json" "$plugin_json"
    first=1
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      [ "$first" -eq 1 ] || printf ','
      printf '%s' "$row"
      first=0
    done < "$RESULTS"
    printf ']}\n'
  fi
fi

if [ "$MARKDOWN" -eq 1 ]; then
  echo "# SaaS startup preflight"
  echo
  echo "- status: $status"
  echo "- repo_root: \`$REPO_ROOT\`"
  echo "- plugin_root: \`$PLUGIN_ROOT\`"
  echo
  if have_cmd jq; then
    jq -r '. | "- [" + .status + "] " + .check + " - " + .message' "$RESULTS"
  else
    while IFS= read -r row; do
      check="$(printf '%s\n' "$row" | sed -n 's/.*"check"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      status_value="$(printf '%s\n' "$row" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      message="$(printf '%s\n' "$row" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      echo "- [$status_value] $check - $message"
    done < "$RESULTS"
  fi
fi

[ "$status" != "blocker" ]
