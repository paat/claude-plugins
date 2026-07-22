#!/usr/bin/env bash
#
# issue-file.sh — shared auto-filing helper for discovered defects (#195, #326, #328).
#
# Files or reuses a GitHub issue without a human "shall I file it?" round-trip.
# Best-effort open-issue duplicate resistance:
#   - with --pattern-key: whole-line body marker **Pattern:** `key` on open issues
#   - without key: normalized-title match (legacy); multi-match → ambiguous
# Never treats post-create search as a hard gate; create URL comes from create.
#
# Optional source-repo escalation (#328): after a successful local create/reuse,
# the same pattern-key pre-check ladder can run against --source-repo and either
# comment on an open match or create once (no second source issue for the same key).
#
# Sensitive-content carve-out (stated once, here; commands reference this):
# customer data / security detail must never be auto-filed to a public tracker.
# Title + final outbound body are run through the shared pii-gate; on a hit the
# defect is PARKED as a human task in docs/human-tasks.md and NOTHING is sent to
# GitHub (exit 3).
#
# Usage:
#   issue-file.sh --title T (--body B | --body-file F) [--repo OWNER/REPO]
#                 [--pattern-key KEY] [--labels a,b] [--root DIR]
#                 [--digest-file PATH] [--dry-run]
#                 [--source-repo OWNER/REPO] [--source-escalate none|comment]
#
# Pattern key (optional): ^[a-z0-9][a-z0-9:_-]*$ (single line, no newlines)
# When set, injects exactly one whole-line marker and pre-checks open issues for it.
# Conflicting Pattern markers in the body are rejected (exit 2).
# Legacy title adopt (key path, 0 marker hits, 1 same-title issue) backfills the
# marker onto the issue body before commenting so later key searches can hit.
#
# Source escalate (default none): requires --source-repo + --pattern-key when mode
# is comment. Runs only after local created/reused success.
#
# Guarantee: open-issue duplicate resistance only. Closed priors, search lag, and
# concurrent creates can still yield a new issue.
#
# Exit: 0 created/reused/dry-run-file · 2 usage/env · 3 parked · 1 error/ambiguous
# Stdout: issue URL on success (created/reused); human messages for dry-run/park.
# Stderr: one terminal status line: issue-file: status=...
#   created | reused | ambiguous | parked | dry-run | usage | precheck_failed
#   | comment_failed | create_failed | unknown
# Optional second status line after local success when source escalate runs:
#   issue-file: source_escalate=created|reused|... (same status vocabulary)
#
set -euo pipefail

_status() {  # key=value pairs → one stderr line
  local line="issue-file: status=$1"
  shift
  local a
  for a in "$@"; do line="$line $a"; done
  printf '%s\n' "$line" >&2
}

_source_status() {  # source_escalate=... key=value
  local line="issue-file: source_escalate=$1"
  shift
  local a
  for a in "$@"; do line="$line $a"; done
  printf '%s\n' "$line" >&2
}

_die()  {
  echo "issue-file: $*" >&2
  _status "usage"
  exit 2
}
_need() { [ $# -ge 2 ] || _die "flag $1 requires a value"; }

TITLE=""; BODY=""; BODY_FILE=""; REPO=""; LABELS=""; ROOT="."; DIGEST_FILE=""; DRY_RUN=0
PATTERN_KEY=""
SOURCE_REPO=""
SOURCE_ESCALATE="none"
while [ $# -gt 0 ]; do
  case "$1" in
    --title)            _need "$@"; TITLE="$2"; shift 2 ;;
    --body)             _need "$@"; BODY="$2"; shift 2 ;;
    --body-file)        _need "$@"; BODY_FILE="$2"; shift 2 ;;
    --repo)             _need "$@"; REPO="$2"; shift 2 ;;
    --labels)           _need "$@"; LABELS="$2"; shift 2 ;;
    --root)             _need "$@"; ROOT="$2"; shift 2 ;;
    --digest-file)      _need "$@"; DIGEST_FILE="$2"; shift 2 ;;
    --pattern-key)      _need "$@"; PATTERN_KEY="$2"; shift 2 ;;
    --source-repo)      _need "$@"; SOURCE_REPO="$2"; shift 2 ;;
    --source-escalate)  _need "$@"; SOURCE_ESCALATE="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    *) _die "unknown arg $1" ;;
  esac
done

[ -n "$TITLE" ] || _die "--title required"
if [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || _die "--body-file not found: $BODY_FILE"
  BODY="$(cat "$BODY_FILE")"
fi
[ -n "$BODY" ] || _die "--body or --body-file required"

if [ -n "$PATTERN_KEY" ]; then
  case "$PATTERN_KEY" in
    *$'\n'*|*$'\r'*) _die "--pattern-key must be a single line" ;;
  esac
  [[ "$PATTERN_KEY" =~ ^[a-z0-9][a-z0-9:_-]*$ ]] \
    || _die "--pattern-key must match ^[a-z0-9][a-z0-9:_-]*$ (lowercase)"
fi

case "$SOURCE_ESCALATE" in
  none|comment) : ;;
  *) _die "--source-escalate must be none or comment" ;;
esac
if [ -n "$SOURCE_REPO" ]; then
  case "$SOURCE_REPO" in
    */*) : ;;
    *) _die "--source-repo must be OWNER/REPO" ;;
  esac
fi
if [ "$SOURCE_ESCALATE" = "comment" ]; then
  [ -n "$SOURCE_REPO" ] || _die "--source-escalate comment requires --source-repo"
  [ -n "$PATTERN_KEY" ] || _die "--source-escalate comment requires --pattern-key"
fi
if [ -n "$SOURCE_REPO" ] && [ "$SOURCE_ESCALATE" = "none" ]; then
  _die "--source-repo requires --source-escalate comment"
fi

# Read-only PII/secrets dependency — single source of truth; never modified here.
_sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pii-gate.sh
. "$_sd/pii-gate.sh" || _die "PII gate unavailable"
command -v pii_hit >/dev/null 2>&1 || _die "PII gate unavailable"

# Normalize a title for dedup: lowercase, non-alphanumerics → spaces, collapse runs.
_norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'; }

# Whole-line exact marker present in body?
_body_has_marker() {  # $1=body $2=marker_line
  printf '%s\n' "$1" | grep -Fqx -- "$2"
}

# Best-effort digest; never fails the process after a successful remote mutation.
_digest_line() {
  [ -n "$DIGEST_FILE" ] || return 0
  mkdir -p "$(dirname "$DIGEST_FILE")" 2>/dev/null || {
    echo "issue-file: warning: cannot create digest dir for $DIGEST_FILE" >&2
    return 0
  }
  if ! printf '%s\n' "$1" >> "$DIGEST_FILE" 2>/dev/null; then
    echo "issue-file: warning: cannot append digest line to $DIGEST_FILE" >&2
  fi
  return 0
}

_park() {
  local safe_title="$TITLE"
  [ "${1:-0}" = 1 ] && safe_title="(withheld — title contains sensitive content)"
  if [ "$DRY_RUN" = 1 ]; then
    echo "[DRY RUN] would PARK (sensitive content): $safe_title"
    _status "dry-run" "action=park"
    exit 3
  fi
  local local_tasks="$ROOT/docs/human-tasks.md"
  mkdir -p "$ROOT/docs"
  [ -f "$local_tasks" ] || printf '# Human Tasks\n\n## Pending\n\n## Completed\n' > "$local_tasks"
  local entry
  entry="$(printf -- '- [ ] **Review sensitive defect before filing: %s** — needed for: redact customer data / security detail, then file manually\n  - Notes: auto-file blocked by the pii-gate; the draft carries a secret-shaped or PII string.' "$safe_title")"
  if grep -q '^## \+Pending' "$local_tasks"; then
    local tmp
    tmp="$(mktemp)"
    awk -v e="$entry" '{print} /^## +Pending/ && !done {print e; done=1}' "$local_tasks" > "$tmp" && mv "$tmp" "$local_tasks"
  else
    printf '\n## Pending\n\n%s\n' "$entry" >> "$local_tasks"
  fi
  echo "issue-file: PARKED (sensitive) → $local_tasks"
  _status "parked"
  exit 3
}

_fail_precheck() {
  echo "issue-file: $1" >&2
  _status "precheck_failed" "reason=${2:-search}"
  exit 1
}

_fail_ambiguous() {
  echo "issue-file: ambiguous: $1" >&2
  _status "ambiguous" "count=$2"
  exit 1
}

_fail_source_precheck() {
  echo "issue-file: source escalate: $1" >&2
  _source_status "precheck_failed" "reason=${2:-search}" "repo=$SOURCE_REPO"
  exit 1
}

_fail_source_ambiguous() {
  echo "issue-file: source escalate ambiguous: $1" >&2
  _source_status "ambiguous" "count=$2" "repo=$SOURCE_REPO"
  exit 1
}

# --- Build final outbound body (pattern marker) before PII ---
MARKER_LINE=""
if [ -n "$PATTERN_KEY" ]; then
  MARKER_LINE="**Pattern:** \`$PATTERN_KEY\`"
  # Whole-line Pattern markers only.
  existing_markers="$(printf '%s\n' "$BODY" | grep -F '**Pattern:** `' | grep -E '^\*\*Pattern:\*\* `' || true)"
  if [ -n "$existing_markers" ]; then
    while IFS= read -r em; do
      [ -z "$em" ] && continue
      if [ "$em" != "$MARKER_LINE" ]; then
        _die "body has conflicting Pattern marker (expected $MARKER_LINE)"
      fi
    done <<< "$existing_markers"
    BODY="$(printf '%s\n' "$BODY" | grep -vxF -- "$MARKER_LINE" || true)"
  fi
  if [ -n "$BODY" ]; then
    BODY="$(printf '%s\n\n%s\n' "$BODY" "$MARKER_LINE")"
  else
    BODY="$(printf '%s\n' "$MARKER_LINE")"
  fi
fi

# --- Sensitive-content carve-out on title + final body ---
title_pii=0; pii_hit "$TITLE" && title_pii=1
if [ "$title_pii" = 1 ] || pii_hit "$BODY"; then
  _park "$title_pii"
fi

# --- Resolve repo (read-only; skipped under dry-run) ---
if [ -z "$REPO" ] && [ "$DRY_RUN" != 1 ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ -n "$REPO" ] || _die "could not resolve repo (pass --repo OWNER/REPO)"
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "[DRY RUN] would file/dedup issue: $TITLE"
  if [ "$SOURCE_ESCALATE" = "comment" ]; then
    echo "[DRY RUN] would source-escalate (comment-or-create) to $SOURCE_REPO key=$PATTERN_KEY"
    _status "dry-run" "action=file" "source_repo=$SOURCE_REPO" "source_escalate=comment"
  else
    _status "dry-run" "action=file"
  fi
  exit 0
fi

bodyf="$(mktemp)"; printf '%s' "$BODY" > "$bodyf"
[ -n "$BODY" ] && [[ "$BODY" == *$'\n' ]] || printf '\n' >> "$bodyf"
trap 'rm -f "$bodyf"' EXIT

want="$(_norm "$TITLE")"
match_url=""
match_num=""
adopt_backfill=0

# Parse issue list JSON: require array; optional body field.
_list_len() {  # $1=json → echo length or fail
  local j="$1" n
  n="$(printf '%s' "$j" | jq 'if type=="array" then length else empty end' 2>/dev/null)" \
    || _fail_precheck "dedup parse failed — refusing to file" "parse"
  [ -n "$n" ] || _fail_precheck "dedup parse failed — refusing to file" "schema"
  printf '%s' "$n"
}

# Shared title-match for legacy-adopt and title-only paths (no dual drift sites).
# On success with exactly one normalized match: sets match_url + match_num.
# Zero matches: leaves them empty. Multi-match / schema: fail closed.
# $1=list JSON (number,title,url)  $2=context label for errors  $3=fail helper kind (local|source)
_title_match_from_list() {
  local hits="$1" context="$2" fail_kind="${3:-local}"
  local n i ht hn hu thc
  local -a title_hits_url=() title_hits_num=()
  n="$(_list_len "$hits")"
  [ "$n" -lt 100 ] || {
    if [ "$fail_kind" = source ]; then
      _fail_source_precheck "$context result cap hit (100) — refusing to escalate" "cap"
    else
      _fail_precheck "$context result cap hit (100) — refusing to file" "cap"
    fi
  }
  i=0
  while [ "$i" -lt "$n" ]; do
    ht="$(printf '%s' "$hits" | jq -r --argjson i "$i" '.[$i].title // empty')"
    hn="$(printf '%s' "$hits" | jq -r --argjson i "$i" 'if (.[$i].number|type)=="number" then (.[$i].number|tostring) else empty end')"
    hu="$(printf '%s' "$hits" | jq -r --argjson i "$i" 'if (.[$i].url|type)=="string" and .[$i].url!="" then .[$i].url else empty end')"
    if [ -z "$hn" ] || [ -z "$hu" ] || [ -z "$ht" ]; then
      if [ "$fail_kind" = source ]; then
        _fail_source_precheck "$context row schema failed — refusing to escalate" "schema"
      else
        _fail_precheck "$context row schema failed — refusing to file" "schema"
      fi
    fi
    if [ "$(_norm "$ht")" = "$want" ]; then
      title_hits_url+=("$hu")
      title_hits_num+=("$hn")
    fi
    i=$((i + 1))
  done
  thc="${#title_hits_url[@]}"
  if [ "$thc" -ge 2 ]; then
    if [ "$fail_kind" = source ]; then
      _fail_source_ambiguous "$thc open source issues share normalized title" "$thc"
    else
      _fail_ambiguous "$thc open issues share normalized title${context:+ ($context)}" "$thc"
    fi
  fi
  if [ "$thc" -eq 1 ]; then
    match_url="${title_hits_url[0]}"
    match_num="${title_hits_num[0]}"
  fi
}

# Pattern-key open-issue pre-check ladder for a repo. Sets match_url/match_num/adopt_backfill.
# $1=repo  $2=fail_kind local|source
_pattern_key_precheck() {
  local target_repo="$1" fail_kind="${2:-local}"
  local hits n i row hnum htitle hurl hbody mh thits
  local -a marker_hits=()
  match_url=""; match_num=""; adopt_backfill=0

  hits="$(gh issue list --repo "$target_repo" --state open --limit 100 \
    --search "\"${PATTERN_KEY}\" in:body" \
    --json number,title,url,body 2>/dev/null)" || {
    if [ "$fail_kind" = source ]; then
      _fail_source_precheck "dedup search failed (gh) — refusing to escalate" "search"
    else
      _fail_precheck "dedup search failed (gh) — refusing to file" "search"
    fi
  }

  n="$(_list_len "$hits")"
  [ "$n" -lt 100 ] || {
    if [ "$fail_kind" = source ]; then
      _fail_source_precheck "dedup result cap hit (100) — refusing to escalate" "cap"
    else
      _fail_precheck "dedup result cap hit (100) — refusing to file" "cap"
    fi
  }

  i=0
  while [ "$i" -lt "$n" ]; do
    row="$(printf '%s' "$hits" | jq -c --argjson i "$i" '.[$i]' 2>/dev/null)" || {
      if [ "$fail_kind" = source ]; then
        _fail_source_precheck "dedup row parse failed — refusing to escalate" "parse"
      else
        _fail_precheck "dedup row parse failed — refusing to file" "parse"
      fi
    }
    hnum="$(printf '%s' "$row" | jq -r 'if (.number|type)=="number" then (.number|tostring) else empty end')"
    htitle="$(printf '%s' "$row" | jq -r 'if (.title|type)=="string" then .title else empty end')"
    hurl="$(printf '%s' "$row" | jq -r 'if (.url|type)=="string" and .url!="" then .url else empty end')"
    hbody="$(printf '%s' "$row" | jq -r 'if .body == null then empty elif (.body|type)=="string" then .body else empty end')"
    if [ -z "$hnum" ]; then
      if [ "$fail_kind" = source ]; then
        _fail_source_precheck "dedup row missing number — refusing to escalate" "schema"
      else
        _fail_precheck "dedup row missing number — refusing to file" "schema"
      fi
    fi
    if [ -z "$hurl" ]; then
      if [ "$fail_kind" = source ]; then
        _fail_source_precheck "dedup row missing url for #$hnum — refusing to escalate" "schema"
      else
        _fail_precheck "dedup row missing url for #$hnum — refusing to file" "schema"
      fi
    fi
    if [ -z "$htitle" ]; then
      if [ "$fail_kind" = source ]; then
        _fail_source_precheck "dedup row missing title for #$hnum — refusing to escalate" "schema"
      else
        _fail_precheck "dedup row missing title for #$hnum — refusing to file" "schema"
      fi
    fi
    if ! printf '%s' "$row" | jq -e 'has("body")' >/dev/null 2>&1; then
      if ! hbody="$(gh issue view "$hnum" --repo "$target_repo" --json body -q .body 2>/dev/null)"; then
        if [ "$fail_kind" = source ]; then
          _fail_source_precheck "body fetch failed for #$hnum — refusing to escalate" "body_fetch"
        else
          _fail_precheck "body fetch failed for #$hnum — refusing to file" "body_fetch"
        fi
      fi
    fi
    if _body_has_marker "$hbody" "$MARKER_LINE"; then
      marker_hits+=("$hnum|$hurl")
    fi
    i=$((i + 1))
  done

  mh="${#marker_hits[@]}"
  if [ "$mh" -ge 2 ]; then
    if [ "$fail_kind" = source ]; then
      _fail_source_ambiguous "$mh open source issues share pattern key" "$mh"
    else
      _fail_ambiguous "$mh open issues share pattern key" "$mh"
    fi
  fi
  if [ "$mh" -eq 1 ]; then
    match_num="${marker_hits[0]%%|*}"
    match_url="${marker_hits[0]#*|}"
    return 0
  fi

  # Legacy adopt: exactly one open issue with same normalized title.
  thits="$(gh issue list --repo "$target_repo" --state open --limit 100 \
    --search "$TITLE in:title" \
    --json number,title,url 2>/dev/null)" || {
    if [ "$fail_kind" = source ]; then
      _fail_source_precheck "title adopt search failed (gh) — refusing to escalate" "search"
    else
      _fail_precheck "title adopt search failed (gh) — refusing to file" "search"
    fi
  }
  match_url=""; match_num=""
  _title_match_from_list "$thits" "title adopt" "$fail_kind"
  if [ -n "$match_url" ]; then
    adopt_backfill=1
  fi
}

# Comment on match (optional marker backfill) or create. $1=repo $2=fail_kind
# Prints URL on stdout for local path; for source, only status lines.
# Sets _OUT_URL _OUT_NUM _OUT_STATUS (created|reused)
_mutate_match_or_create() {
  local target_repo="$1" fail_kind="${2:-local}"
  local cur_body editf create_out url num lbl
  _OUT_URL=""; _OUT_NUM=""; _OUT_STATUS=""

  if [ -n "$match_url" ]; then
    if [ "$adopt_backfill" = 1 ] && [ -n "$MARKER_LINE" ]; then
      cur_body=""
      if ! cur_body="$(gh issue view "$match_num" --repo "$target_repo" --json body -q .body 2>/dev/null)"; then
        if [ "$fail_kind" = source ]; then
          _fail_source_precheck "adopt body fetch failed for #$match_num — refusing to escalate" "body_fetch"
        else
          _fail_precheck "adopt body fetch failed for #$match_num — refusing to file" "body_fetch"
        fi
      fi
      if ! _body_has_marker "$cur_body" "$MARKER_LINE"; then
        editf="$(mktemp)"
        if [ -n "$cur_body" ]; then
          printf '%s\n\n%s\n' "$cur_body" "$MARKER_LINE" > "$editf"
        else
          printf '%s\n' "$MARKER_LINE" > "$editf"
        fi
        if ! gh issue edit "$match_num" --repo "$target_repo" --body-file "$editf" >/dev/null 2>&1; then
          rm -f "$editf"
          if [ "$fail_kind" = source ]; then
            echo "issue-file: source escalate adopt backfill edit failed on #$match_num" >&2
            _source_status "comment_failed" "number=$match_num" "reason=backfill" "repo=$target_repo"
            exit 1
          fi
          echo "issue-file: adopt backfill edit failed on #$match_num" >&2
          _status "comment_failed" "number=$match_num" "reason=backfill"
          exit 1
        fi
        rm -f "$editf"
      fi
    fi
    if gh issue comment "$match_num" --repo "$target_repo" --body-file "$bodyf" >/dev/null 2>&1; then
      _OUT_URL="$match_url"
      _OUT_NUM="$match_num"
      _OUT_STATUS="reused"
      return 0
    fi
    if [ "$fail_kind" = source ]; then
      echo "issue-file: source escalate comment failed on #$match_num" >&2
      _source_status "comment_failed" "number=$match_num" "repo=$target_repo"
      exit 1
    fi
    echo "issue-file: comment failed on #$match_num" >&2
    _status "comment_failed" "number=$match_num"
    exit 1
  fi

  lbl=()
  # shellcheck disable=SC2206
  [ -n "$LABELS" ] && lbl=(--label "$LABELS")
  create_out=""
  if create_out="$(gh issue create --repo "$target_repo" --title "$TITLE" --body-file "$bodyf" "${lbl[@]}" 2>/dev/null)"; then
    url="$(printf '%s' "$create_out" | grep -oE 'https://[^[:space:]]+' | tail -1 || true)"
    if [ -z "$url" ]; then
      if [ "$fail_kind" = source ]; then
        echo "issue-file: source escalate create returned no URL (mutation may have succeeded)" >&2
        _source_status "unknown" "mutation_possible=true" "repo=$target_repo"
        exit 1
      fi
      echo "issue-file: create returned no URL (mutation may have succeeded)" >&2
      _status "unknown" "mutation_possible=true"
      exit 1
    fi
    num="$(printf '%s' "$url" | grep -oE '[0-9]+$' || true)"
    _OUT_URL="$url"
    _OUT_NUM="$num"
    _OUT_STATUS="created"
    return 0
  fi
  if [ "$fail_kind" = source ]; then
    echo "issue-file: source escalate create failed" >&2
    _source_status "create_failed" "repo=$target_repo"
    exit 1
  fi
  echo "issue-file: create failed" >&2
  _status "create_failed"
  exit 1
}

_run_source_escalate() {
  [ "$SOURCE_ESCALATE" = "comment" ] || return 0
  [ -n "$SOURCE_REPO" ] || return 0
  [ -n "$PATTERN_KEY" ] || return 0

  match_url=""; match_num=""; adopt_backfill=0
  _pattern_key_precheck "$SOURCE_REPO" source
  _mutate_match_or_create "$SOURCE_REPO" source
  if [ -n "$_OUT_NUM" ]; then
    _source_status "$_OUT_STATUS" "number=$_OUT_NUM" "url=$_OUT_URL" "repo=$SOURCE_REPO"
  else
    _source_status "$_OUT_STATUS" "url=$_OUT_URL" "repo=$SOURCE_REPO"
  fi
  if [ "$_OUT_STATUS" = "created" ]; then
    _digest_line "- Source-escalated issue #${_OUT_NUM:-?} $_OUT_URL"
  else
    _digest_line "- Source-escalated update #${_OUT_NUM:-?} $_OUT_URL"
  fi
}

# --- Local open-issue path ---
if [ -n "$PATTERN_KEY" ]; then
  _pattern_key_precheck "$REPO" local
else
  # Title-only path
  hits="$(gh issue list --repo "$REPO" --state open --limit 100 \
    --search "$TITLE in:title" --json number,title,url 2>/dev/null)" \
    || _fail_precheck "dedup search failed (gh) — refusing to file" "search"
  match_url=""; match_num=""; adopt_backfill=0
  _title_match_from_list "$hits" "title" local
fi

_mutate_match_or_create "$REPO" local
echo "$_OUT_URL"
if [ "$_OUT_STATUS" = "created" ]; then
  _digest_line "- Filed issue #${_OUT_NUM:-?} $_OUT_URL"
else
  _digest_line "- Updated issue #${_OUT_NUM:-?} $_OUT_URL"
fi
if [ -n "$_OUT_NUM" ]; then
  _status "$_OUT_STATUS" "number=$_OUT_NUM" "url=$_OUT_URL"
else
  _status "$_OUT_STATUS" "url=$_OUT_URL"
fi
_run_source_escalate
exit 0
