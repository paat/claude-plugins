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
if [ -z "$clis" ] && [ ! -f "$MANIFEST" ]; then clis=$'git\njq\ngh'; fi
while IFS= read -r c; do
  [ -n "$c" ] || continue
  if command -v "$c" >/dev/null 2>&1; then note_ok "cli:$c"; else note_bad "cli:$c missing from PATH"; fi
done <<< "$clis"

# ---------- auth checks ----------
run_auth() { # <name> <cmd>
  if timeout 10 bash -c "$2" >/dev/null 2>&1; then
    note_ok "auth:$1"
  else
    note_bad "auth:$1 FAILED ($2)"
  fi
}
if [ "$HAVE_JQ" -eq 1 ] && [ -f "$MANIFEST" ]; then
  while IFS=$'\t' read -r name cmd; do
    [ -n "$name" ] && [ -n "$cmd" ] || continue
    run_auth "$name" "$cmd"
  done < <(jq -r '(.auth // [])[] | [.name, .cmd] | @tsv' "$MANIFEST" 2>/dev/null)
elif command -v gh >/dev/null 2>&1; then
  run_auth github "gh auth status"
fi

# ---------- expected tokens: shell env AND known file locations ----------
token_in_file() { # <var> <file> — set as VAR=... or export VAR=...
  [ -f "$2" ] && grep -qE "^(export[[:space:]]+)?$1=." "$2" 2>/dev/null
}
if [ "$HAVE_JQ" -eq 1 ] && [ -f "$MANIFEST" ]; then
  while IFS=$'\t' read -r var files; do
    [ -n "$var" ] || continue
    if [ -n "$(printenv "$var" 2>/dev/null || true)" ]; then
      note_ok "token:$var (env)"
      continue
    fi
    found=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in /*) p="$f" ;; "~/"*) p="$HOME/${f#\~/}" ;; *) p="$CWD/$f" ;; esac
      if token_in_file "$var" "$p"; then found="$p"; break; fi
    done <<< "$(printf '%s' "$files" | tr ',' '\n')"
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
  done < <(jq -r '(.tokens // [])[] | [.env, ((.files // []) | join(","))] | @tsv' "$MANIFEST" 2>/dev/null)
fi

# ---------- report ----------
echo "[session-preflight] $identity"
if [ "${#BAD[@]}" -gt 0 ]; then
  echo "[session-preflight] ATTENTION — ${#BAD[@]} check(s) failed; fix or work around these BEFORE relying on them:"
  for b in "${BAD[@]}"; do echo "  !! $b"; done
fi
if [ "${#OK[@]}" -gt 0 ]; then
  echo "[session-preflight] ok: ${OK[*]}"
fi
exit 0
