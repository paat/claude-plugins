#!/usr/bin/env bash
#
# issue-file.sh — shared auto-filing helper for discovered defects (#195, #326).
#
# Files or reuses a GitHub issue without a human "shall I file it?" round-trip.
# Best-effort open-issue duplicate resistance:
#   - with --pattern-key: whole-line body marker **Pattern:** `key` on open issues
#   - without key: normalized-title match (legacy); multi-match → ambiguous
# Never treats post-create search as a hard gate; create URL comes from create.
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
#
# Pattern key (optional): ^[a-z0-9][a-z0-9:_-]*$ (single line, no newlines)
# When set, injects exactly one whole-line marker and pre-checks open issues for it.
# Conflicting Pattern markers in the body are rejected (exit 2).
# Legacy title adopt (key path, 0 marker hits, 1 same-title issue) backfills the
# marker onto the issue body before commenting so later key searches can hit.
#
# Guarantee: open-issue duplicate resistance only. Closed priors, search lag, and
# concurrent creates can still yield a new issue.
#
# Exit: 0 created/reused/dry-run-file · 2 usage/env · 3 parked · 1 error/ambiguous
# Stdout: issue URL on success (created/reused); human messages for dry-run/park.
# Stderr: one terminal status line: issue-file: status=...
#   created | reused | ambiguous | parked | dry-run | usage | precheck_failed
#   | comment_failed | create_failed | unknown
#
set -euo pipefail

_status() {  # key=value pairs → one stderr line
  local line="issue-file: status=$1"
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
while [ $# -gt 0 ]; do
  case "$1" in
    --title)        _need "$@"; TITLE="$2"; shift 2 ;;
    --body)         _need "$@"; BODY="$2"; shift 2 ;;
    --body-file)    _need "$@"; BODY_FILE="$2"; shift 2 ;;
    --repo)         _need "$@"; REPO="$2"; shift 2 ;;
    --labels)       _need "$@"; LABELS="$2"; shift 2 ;;
    --root)         _need "$@"; ROOT="$2"; shift 2 ;;
    --digest-file)  _need "$@"; DIGEST_FILE="$2"; shift 2 ;;
    --pattern-key)  _need "$@"; PATTERN_KEY="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
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
  _status "dry-run" "action=file"
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
# Sets global _list_n and uses caller-provided name for iterating via jq.
_list_len() {  # $1=json → echo length or fail
  local j="$1" n
  n="$(printf '%s' "$j" | jq 'if type=="array" then length else empty end' 2>/dev/null)" \
    || _fail_precheck "dedup parse failed — refusing to file" "parse"
  [ -n "$n" ] || _fail_precheck "dedup parse failed — refusing to file" "schema"
  printf '%s' "$n"
}

# --- Pattern-key open-issue path ---
if [ -n "$PATTERN_KEY" ]; then
  hits="$(gh issue list --repo "$REPO" --state open --limit 100 \
    --search "\"${PATTERN_KEY}\" in:body" \
    --json number,title,url,body 2>/dev/null)" \
    || _fail_precheck "dedup search failed (gh) — refusing to file" "search"

  n="$(_list_len "$hits")"
  [ "$n" -lt 100 ] || _fail_precheck "dedup result cap hit (100) — refusing to file" "cap"

  marker_hits=()
  i=0
  while [ "$i" -lt "$n" ]; do
    row="$(printf '%s' "$hits" | jq -c --argjson i "$i" '.[$i]' 2>/dev/null)" \
      || _fail_precheck "dedup row parse failed — refusing to file" "parse"
    hnum="$(printf '%s' "$row" | jq -r 'if (.number|type)=="number" then (.number|tostring) else empty end')"
    htitle="$(printf '%s' "$row" | jq -r 'if (.title|type)=="string" then .title else empty end')"
    hurl="$(printf '%s' "$row" | jq -r 'if (.url|type)=="string" and .url!="" then .url else empty end')"
    hbody="$(printf '%s' "$row" | jq -r 'if .body == null then empty elif (.body|type)=="string" then .body else empty end')"
    [ -n "$hnum" ] || _fail_precheck "dedup row missing number — refusing to file" "schema"
    [ -n "$hurl" ] || _fail_precheck "dedup row missing url for #$hnum — refusing to file" "schema"
    [ -n "$htitle" ] || _fail_precheck "dedup row missing title for #$hnum — refusing to file" "schema"
    # body may be empty string; if jq said null we got empty — try view when field absent from object?
    # When body key missing, jq .body is null → empty. Fetch to be sure if no whole-line marker possible.
    if ! printf '%s' "$row" | jq -e 'has("body")' >/dev/null 2>&1; then
      if ! hbody="$(gh issue view "$hnum" --repo "$REPO" --json body -q .body 2>/dev/null)"; then
        _fail_precheck "body fetch failed for #$hnum — refusing to file" "body_fetch"
      fi
    fi
    if _body_has_marker "$hbody" "$MARKER_LINE"; then
      marker_hits+=("$hnum|$hurl")
    fi
    i=$((i + 1))
  done

  mh="${#marker_hits[@]}"
  if [ "$mh" -ge 2 ]; then
    _fail_ambiguous "$mh open issues share pattern key" "$mh"
  fi
  if [ "$mh" -eq 1 ]; then
    match_num="${marker_hits[0]%%|*}"
    match_url="${marker_hits[0]#*|}"
  else
    # Legacy adopt: exactly one open issue with same normalized title.
    thits="$(gh issue list --repo "$REPO" --state open --limit 100 \
      --search "$TITLE in:title" \
      --json number,title,url 2>/dev/null)" \
      || _fail_precheck "title adopt search failed (gh) — refusing to file" "search"
    tn="$(_list_len "$thits")"
    [ "$tn" -lt 100 ] || _fail_precheck "title adopt result cap hit (100) — refusing to file" "cap"
    title_hits_url=()
    title_hits_num=()
    i=0
    while [ "$i" -lt "$tn" ]; do
      ht="$(printf '%s' "$thits" | jq -r --argjson i "$i" '.[$i].title // empty')"
      hn="$(printf '%s' "$thits" | jq -r --argjson i "$i" 'if (.[$i].number|type)=="number" then (.[$i].number|tostring) else empty end')"
      hu="$(printf '%s' "$thits" | jq -r --argjson i "$i" 'if (.[$i].url|type)=="string" and .[$i].url!="" then .[$i].url else empty end')"
      [ -n "$hn" ] && [ -n "$hu" ] && [ -n "$ht" ] \
        || _fail_precheck "title adopt row schema failed — refusing to file" "schema"
      if [ "$(_norm "$ht")" = "$want" ]; then
        title_hits_url+=("$hu")
        title_hits_num+=("$hn")
      fi
      i=$((i + 1))
    done
    thc="${#title_hits_url[@]}"
    if [ "$thc" -ge 2 ]; then
      _fail_ambiguous "$thc open issues share normalized title (legacy adopt)" "$thc"
    fi
    if [ "$thc" -eq 1 ]; then
      match_url="${title_hits_url[0]}"
      match_num="${title_hits_num[0]}"
      adopt_backfill=1
    fi
  fi
else
  # --- Title-only path ---
  hits="$(gh issue list --repo "$REPO" --state open --limit 100 \
    --search "$TITLE in:title" --json number,title,url 2>/dev/null)" \
    || _fail_precheck "dedup search failed (gh) — refusing to file" "search"
  n="$(_list_len "$hits")"
  [ "$n" -lt 100 ] || _fail_precheck "dedup result cap hit (100) — refusing to file" "cap"
  title_hits_url=()
  title_hits_num=()
  i=0
  while [ "$i" -lt "$n" ]; do
    ht="$(printf '%s' "$hits" | jq -r --argjson i "$i" '.[$i].title // empty')"
    hn="$(printf '%s' "$hits" | jq -r --argjson i "$i" 'if (.[$i].number|type)=="number" then (.[$i].number|tostring) else empty end')"
    hu="$(printf '%s' "$hits" | jq -r --argjson i "$i" 'if (.[$i].url|type)=="string" and .[$i].url!="" then .[$i].url else empty end')"
    [ -n "$hn" ] && [ -n "$hu" ] && [ -n "$ht" ] \
      || _fail_precheck "dedup row schema failed — refusing to file" "schema"
    if [ "$(_norm "$ht")" = "$want" ]; then
      title_hits_url+=("$hu")
      title_hits_num+=("$hn")
    fi
    i=$((i + 1))
  done
  thc="${#title_hits_url[@]}"
  if [ "$thc" -ge 2 ]; then
    _fail_ambiguous "$thc open issues share normalized title" "$thc"
  fi
  if [ "$thc" -eq 1 ]; then
    match_url="${title_hits_url[0]}"
    match_num="${title_hits_num[0]}"
  fi
fi

if [ -n "$match_url" ]; then
  # Legacy adopt: persist pattern marker on the issue body so later key searches hit.
  if [ "$adopt_backfill" = 1 ] && [ -n "$MARKER_LINE" ]; then
    cur_body=""
    if ! cur_body="$(gh issue view "$match_num" --repo "$REPO" --json body -q .body 2>/dev/null)"; then
      _fail_precheck "adopt body fetch failed for #$match_num — refusing to file" "body_fetch"
    fi
    if ! _body_has_marker "$cur_body" "$MARKER_LINE"; then
      editf="$(mktemp)"
      if [ -n "$cur_body" ]; then
        printf '%s\n\n%s\n' "$cur_body" "$MARKER_LINE" > "$editf"
      else
        printf '%s\n' "$MARKER_LINE" > "$editf"
      fi
      if ! gh issue edit "$match_num" --repo "$REPO" --body-file "$editf" >/dev/null 2>&1; then
        rm -f "$editf"
        echo "issue-file: adopt backfill edit failed on #$match_num" >&2
        _status "comment_failed" "number=$match_num" "reason=backfill"
        exit 1
      fi
      rm -f "$editf"
    fi
  fi
  if gh issue comment "$match_num" --repo "$REPO" --body-file "$bodyf" >/dev/null 2>&1; then
    echo "$match_url"
    _digest_line "- Updated issue #$match_num $match_url"
    _status "reused" "number=$match_num" "url=$match_url"
    exit 0
  fi
  echo "issue-file: comment failed on #$match_num" >&2
  _status "comment_failed" "number=$match_num"
  exit 1
fi

lbl=()
# shellcheck disable=SC2206
[ -n "$LABELS" ] && lbl=(--label "$LABELS")
create_out=""
if create_out="$(gh issue create --repo "$REPO" --title "$TITLE" --body-file "$bodyf" "${lbl[@]}" 2>/dev/null)"; then
  url="$(printf '%s' "$create_out" | grep -oE 'https://[^[:space:]]+' | tail -1 || true)"
  if [ -z "$url" ]; then
    echo "issue-file: create returned no URL (mutation may have succeeded)" >&2
    _status "unknown" "mutation_possible=true"
    exit 1
  fi
  num="$(printf '%s' "$url" | grep -oE '[0-9]+$' || true)"
  echo "$url"
  _digest_line "- Filed issue #${num:-?} $url"
  if [ -n "$num" ]; then
    _status "created" "number=$num" "url=$url"
  else
    _status "created" "url=$url"
  fi
  exit 0
fi
echo "issue-file: create failed" >&2
_status "create_failed"
exit 1
