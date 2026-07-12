#!/usr/bin/env bash
# session-preflight SessionStart hook. Fast, read-only, never blocks: always
# exits 0; stdout becomes session context. Failures are surfaced loudly at the
# top so the first tool call is not wasted on a dead environment.
set -uo pipefail

# stdin carries the hook payload; cwd field beats $PWD when present.
CWD="$PWD"
if IN="$(cat 2>/dev/null)" && [ -n "$IN" ] && command -v jq >/dev/null 2>&1; then
  c="$(printf '%s' "$IN" | jq -r '.cwd // empty' 2>/dev/null)" && [ -d "${c:-}" ] && CWD="$c"
fi

MANIFEST="$CWD/.claude/preflight.json"
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

OK=(); BAD=()
note_ok()  { OK+=("$1"); }
note_bad() { BAD+=("$1"); }

mf() { # <jq filter> — read manifest, empty when absent/unreadable
  [ "$HAVE_JQ" -eq 1 ] && [ -f "$MANIFEST" ] || return 0
  jq -r "$1" "$MANIFEST" 2>/dev/null || true
}

# ---------- identity (never wrong-host assumptions) ----------
host="$(hostname 2>/dev/null || echo '?')"
user="$(id -un 2>/dev/null || echo '?')"
repo=""; branch=""
if command -v git >/dev/null 2>&1; then
  repo="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
  branch="$(git -C "$CWD" branch --show-current 2>/dev/null || true)"
fi
identity="host=$host user=$user"
[ -n "$repo" ] && identity="$identity repo=$(basename "$repo") branch=${branch:-detached}"
[ -f /.dockerenv ] && identity="$identity (container)"

# ---------- required CLIs ----------
clis="$(mf '(.clis // [])[]')"
# Defaults apply with no manifest AND when jq is unavailable to read one.
if [ -z "$clis" ] && { [ ! -f "$MANIFEST" ] || [ "$HAVE_JQ" -eq 0 ]; }; then clis=$'git\njq\ngh'; fi
while IFS= read -r c; do
  [ -n "$c" ] || continue
  if command -v "$c" >/dev/null 2>&1; then note_ok "cli:$c"; else note_bad "cli:$c missing from PATH"; fi
done <<< "$clis"

# ---------- auth checks (built-in catalog ONLY) ----------
# The manifest selects checks BY NAME from this fixed read-only catalog. It
# never supplies command text: a repo-local file must not gain arbitrary code
# execution at session start, and a fixed catalog can never embed secrets in
# output.
auth_cmd_for() { # <name> -> catalog command on stdout, or nothing
  case "$1" in
    github)  echo "gh auth status" ;;
    npm)     echo "npm whoami" ;;
    docker)  echo "docker info" ;;
    gcloud)  echo "gcloud auth list --filter=status:ACTIVE --format=value(account)" ;;
    aws)     echo "aws sts get-caller-identity" ;;
    codex)   echo "codex login status" ;;
    *)       return 1 ;;
  esac
}
with_timeout() { # <secs> <cmd...> — degrade gracefully where timeout is absent
  if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi
}
run_auth() { # <name>
  local cmd
  if ! cmd="$(auth_cmd_for "$1")"; then
    note_bad "auth:$1 unknown check name (supported: github npm docker gcloud aws codex)"
    return
  fi
  # shellcheck disable=SC2086 — catalog commands are fixed word lists
  if with_timeout 10 $cmd >/dev/null 2>&1; then
    note_ok "auth:$1"
  else
    note_bad "auth:$1 FAILED"
  fi
}
if [ "$HAVE_JQ" -eq 1 ] && [ -f "$MANIFEST" ]; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    run_auth "$name"
  done < <(jq -r '(.auth // [])[] | if type == "object" then (.name // empty) else . end' "$MANIFEST" 2>/dev/null)
elif command -v gh >/dev/null 2>&1; then
  run_auth github
fi

# ---------- expected tokens: shell env AND known file locations ----------
token_in_file() { # <var> <file> — set as VAR=... or export VAR=...
  [ -f "$2" ] && grep -qE "^(export[[:space:]]+)?$1=." "$2" 2>/dev/null
}
US=$'\x1f'
if [ "$HAVE_JQ" -eq 1 ] && [ -f "$MANIFEST" ]; then
  while IFS="$US" read -r var files; do
    [ -n "$var" ] || continue
    case "$var" in
      [A-Za-z_]*) case "$var" in *[!A-Za-z0-9_]*) note_bad "token:$var invalid variable name"; continue ;; esac ;;
      *) note_bad "token:$var invalid variable name"; continue ;;
    esac
    if [ -n "$(printenv "$var" 2>/dev/null || true)" ]; then
      note_ok "token:$var (env)"
      continue
    fi
    found=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in /*) p="$f" ;; "~/"*) p="${HOME:-/nonexistent}/${f#\~/}" ;; *) p="$CWD/$f" ;; esac
      if token_in_file "$var" "$p"; then found="$p"; break; fi
    done <<< "${files//$US/$'\n'}"
    if [ -z "$found" ]; then
      for p in "$CWD/.env" "$CWD/.env.local"; do
        if token_in_file "$var" "$p"; then found="$p"; break; fi
      done
    fi
    if [ -n "$found" ]; then
      note_ok "token:$var (in $found — NOT in shell env; source it before use)"
    else
      note_bad "token:$var not in shell env, .env, or configured files"
    fi
  done < <(jq -r '(.tokens // [])[] | [(.env // ""), ((.files // []) | join("\u001f"))] | join("\u001f")' "$MANIFEST" 2>/dev/null)
fi

# ---------- report (control chars stripped: manifest text cannot forge lines) ----------
emit() { printf '%s\n' "$1" | tr -d '\000-\010\013-\037'; }
emit "[session-preflight] $identity"
if [ "${#BAD[@]}" -gt 0 ]; then
  emit "[session-preflight] ATTENTION — ${#BAD[@]} check(s) failed; fix or work around these BEFORE relying on them:"
  for b in "${BAD[@]}"; do emit "  !! $b"; done
fi
if [ "${#OK[@]}" -gt 0 ]; then
  emit "[session-preflight] ok: ${OK[*]}"
fi
exit 0
