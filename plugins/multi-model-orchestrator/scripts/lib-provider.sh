#!/usr/bin/env bash
# Shared provider transport, auth, env-scrubbing, and failure-classification helpers.
# Identical copies live in plugins/multi-model-orchestrator/scripts/ and
# plugins/tribunal-review/scripts/ (verified by cmp in CI).

# Classify provider failure text read from stdin.
# Prints "limit" (plan window or balance used up), "transient", "auth", or nothing.
# Callers must not pass model stdout bodies.
provider_classify_failure_stream() {
  local text
  # A stack-frame position (file.js:503:12) is not an HTTP status.
  text="$(sed -E 's/:[0-9]+:[0-9]+//g')"
  [ -n "$text" ] || return 0
  if grep -Eiq '\b402\b|usage[[:space:]_-]?limit|hit your .*limit\b|quota|(resource|balance|credits?)[[:space:]_-]?exhausted|credit balance (is )?too low|billing_error' <<< "$text"; then
    printf 'limit\n'
    return 0
  fi
  if grep -Eiq '\b(429|529|503)\b|overloaded|rate[[:space:]_-]?limit|temporarily[[:space:]]+unavailable' <<< "$text"; then
    printf 'transient\n'
    return 0
  fi
  if grep -Eiq '\b401\b|unauthorized|not[[:space:]]+signed[[:space:]]+in|not[[:space:]]+logged[[:space:]]+in|login[[:space:]]+required|missing[[:space:]]+([[:alnum:]_-]+[[:space:]]+)?credentials|(expired|invalid)[[:space:]]+(api[[:space:]]*key|token)|(api[[:space:]]*key|token).*(expired|invalid)' <<< "$text"; then
    printf 'auth\n'
    return 0
  fi
}

# List untracked .env* files in REPO (ignored or not; ignored directories are not entered).
provider_find_untracked_env_files() {  # provider_find_untracked_env_files REPO
  local repo="$1"
  { git -C "$repo" ls-files -z --others --exclude-standard
    git -C "$repo" ls-files -z --others --ignored --exclude-standard --directory; } \
    | tr '\0' '\n' | grep -E '(^|/)\.env[^/]*$'
}

# Run or exec a provider CLI with a scrubbed environment: a shared base allowlist,
# the provider's own variables (names or PREFIX* patterns before --), and the names
# listed in EXTRA_ENV_VAR (e.g. MMO_LEG_ENV or TRIBUNAL_LEG_ENV).
# Usage: provider_leg_env_run exec|run EXTRA_ENV_VAR fail|warn [NAME|PREFIX*]... -- COMMAND [ARG]...
provider_leg_env_run() {
  local mode="$1" extra_var="$2" invalid_policy="$3"
  shift 3
  local keep=(PATH HOME USER LOGNAME SHELL LANG LC_ALL TERM TMPDIR
    HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy SSL_CERT_FILE NODE_EXTRA_CA_CERTS)
  local pass=() names=() extra=() name extra_val=""
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do keep+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  extra_val="${!extra_var:-}"
  if [ -n "$extra_val" ]; then
    read -r -a extra <<< "$extra_val"
  fi
  for name in "${keep[@]}" ${extra[@]+"${extra[@]}"}; do
    case "$name" in
      *'*') mapfile -t -O "${#names[@]}" names < <(compgen -e -- "${name%\*}") ;;
      *) names+=("$name") ;;
    esac
  done
  for name in "${names[@]}"; do
    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      if [ "$invalid_policy" = fail ]; then
        printf 'mmo: invalid %s name: %s\n' "$extra_var" "$name" >&2
        return 2
      fi
      printf 'tribunal: ignoring invalid %s name: %s\n' "$extra_var" "$name" >&2
      continue
    fi
    [ -z "${!name+x}" ] || pass+=("$name=${!name}")
  done
  if [ "$mode" = exec ]; then
    exec env -i ${pass[@]+"${pass[@]}"} "$@"
  else
    env -i ${pass[@]+"${pass[@]}"} "$@"
  fi
}

# True when Claude CLI reports loggedIn==true within TIMEOUT_SECONDS (default 20).
provider_claude_authenticated() {  # provider_claude_authenticated [TIMEOUT_SECONDS]
  local timeout_s="${1:-20}" status
  [[ "$timeout_s" =~ ^[1-9][0-9]*$ ]] || timeout_s=20
  status="$(timeout -k 1 "$timeout_s" claude auth status --json 2>/dev/null)" || return 1
  printf '%s\n' "$status" | jq -e '.loggedIn == true' >/dev/null 2>&1
}

# Host path to Grok CLI credentials (pre-isolation GROK_HOME/HOME).
provider_grok_auth_file() {
  printf '%s\n' "${GROK_HOME:-${HOME}/.grok}/auth.json"
}

# True when auth.json is parseable JSON with at least one non-empty access token
# (OIDC/API session field "key", or access_token).
provider_grok_auth_json_usable() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
  jq -e '
    type == "object" and (
      (
        to_entries
        | map(.value)
        | map(select(type == "object"))
        | map(.key // .access_token // empty)
        | map(select(type == "string" and length > 0))
        | length > 0
      )
      or ((.key // .access_token // "") | type == "string" and length > 0)
    )
  ' "$f" >/dev/null 2>&1
}

# Usable for autonomous Grok legs: XAI_API_KEY in env, or a live session in auth.json.
provider_grok_authenticated() {
  if [ -n "${XAI_API_KEY:-}" ]; then
    return 0
  fi
  provider_grok_auth_json_usable "$(provider_grok_auth_file)"
}

# Latest expires_at string across credential objects (empty if none). Lexicographic
# ISO-8601 compares work for the Grok CLI's Zulu timestamps.
provider_grok_auth_max_expires() {
  local f="$1"
  jq -r '
    [
      (to_entries // [])[]
      | .value
      | select(type == "object")
      | .expires_at // empty
      | select(type == "string" and length > 0)
    ]
    | if length == 0 then empty else max end
  ' "$f" 2>/dev/null || true
}

# Write isolated Grok config.toml disabling foreign-vendor compat layers and telemetry.
provider_grok_write_isolated_config() {  # provider_grok_write_isolated_config DEST_FILE
  cat > "$1" <<'EOF'
[compat.claude]
skills = false
rules = false
agents = false
mcps = false
hooks = false
sessions = false

[compat.cursor]
skills = false
rules = false
agents = false
mcps = false
hooks = false
sessions = false

[compat.codex]
skills = false
rules = false
agents = false
mcps = false
hooks = false
sessions = false

[features]
telemetry = false
feedback = false
codebase_indexing = false
EOF
}

# Write back an isolated Grok auth.json to the host atomically under a lockdir.
# When START_SNAPSHOT is provided, skips if isolated did not change or host changed
# since leg start. When jq is available, also refuses to regress a fresher host expires_at.
# Usage: provider_grok_auth_writeback ISOLATED HOST [START_SNAPSHOT] [LOG_PREFIX]
provider_grok_auth_writeback() {
  local isolated="${1:-}" host="${2:-}" start_snapshot="${3:-}" log_prefix="${4:-provider}"
  local host_dir lock_dir lock_pid auth_tmp host_exp iso_exp write_rc=0
  [ -n "$isolated" ] && [ -n "$host" ] || return 0
  if [ -n "$start_snapshot" ]; then
    [ -s "$isolated" ] || return 0
    if [ -f "$start_snapshot" ]; then
      cmp -s "$isolated" "$start_snapshot" 2>/dev/null && return 0
    fi
    if [ -f "$start_snapshot" ]; then
      if [ ! -f "$host" ] || ! cmp -s "$host" "$start_snapshot" 2>/dev/null; then
        return 0
      fi
    elif [ -f "$host" ] && [ -s "$host" ]; then
      return 0
    fi
  else
    [ -f "$isolated" ] || return 0
    provider_grok_auth_json_usable "$isolated" || return 1
  fi
  [ ! -f "$host" ] || ! cmp -s "$isolated" "$host" 2>/dev/null || return 0
  host_dir="$(dirname "$host")"
  mkdir -p "$host_dir" || return 1
  lock_dir="${host}.lockdir"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    lock_pid=""
    [ ! -f "$lock_dir/pid" ] || IFS= read -r lock_pid < "$lock_dir/pid" || true
    # Stale: its holder is gone, or it died before writing its pid (the lock is held for milliseconds).
    if { [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; } ||
       { [ -z "$lock_pid" ] && [ -n "$(find "$lock_dir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }; then
      rm -rf -- "$lock_dir"
      mkdir "$lock_dir" 2>/dev/null || {
        printf '%s: auth refresh not written back; lock busy: %s\n' "$log_prefix" "$lock_dir" >&2
        return 0
      }
    else
      printf '%s: auth refresh not written back; lock busy: %s\n' "$log_prefix" "$lock_dir" >&2
      return 0
    fi
  fi
  printf '%s\n' "$$" > "$lock_dir/pid"
  # Re-check host freshness under the lock (TOCTOU).
  if [ -n "$start_snapshot" ]; then
    if [ -f "$start_snapshot" ]; then
      if [ ! -f "$host" ] || ! cmp -s "$host" "$start_snapshot" 2>/dev/null; then
        rm -f "$lock_dir/pid"
        rmdir "$lock_dir" 2>/dev/null || true
        return 0
      fi
    elif [ -f "$host" ] && [ -s "$host" ]; then
      rm -f "$lock_dir/pid"
      rmdir "$lock_dir" 2>/dev/null || true
      return 0
    fi
  fi
  if [ -f "$host" ] && command -v jq >/dev/null 2>&1 && provider_grok_auth_json_usable "$host"; then
    if cmp -s "$isolated" "$host" 2>/dev/null; then
      rm -f "$lock_dir/pid"
      rmdir "$lock_dir" 2>/dev/null || true
      return 0
    fi
    host_exp="$(provider_grok_auth_max_expires "$host")"
    iso_exp="$(provider_grok_auth_max_expires "$isolated")"
    if [ -n "$host_exp" ] && [ -n "$iso_exp" ] && [[ "$iso_exp" < "$host_exp" ]]; then
      rm -f "$lock_dir/pid"
      rmdir "$lock_dir" 2>/dev/null || true
      return 0
    fi
  fi
  auth_tmp="$(mktemp "$host_dir/.auth.json.XXXXXX")" || {
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
  }
  cp -p "$isolated" "$auth_tmp" && chmod 600 "$auth_tmp" 2>/dev/null && mv -f "$auth_tmp" "$host" || write_rc=$?
  rm -f "$auth_tmp" "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null || true
  return "$write_rc"
}
