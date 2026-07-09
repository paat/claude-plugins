#!/usr/bin/env bash
#
# issue-file.sh — shared auto-filing helper for discovered defects.
#
# Files a GitHub issue for an agent-discovered defect WITHOUT a human "shall I
# file it?" round-trip: normalize the title, search open issues, comment the new
# evidence on an existing match instead of creating a duplicate, else create.
#
# Sensitive-content carve-out (stated once, here; commands reference this):
# customer data / security detail must never be auto-filed to a public tracker.
# The title+body are run through the shared pii-gate (read-only dependency); on a
# hit the defect is PARKED as a human task in docs/human-tasks.md and NOTHING is
# sent to GitHub (exit 3).
#
# Usage:
#   issue-file.sh --title T (--body B | --body-file F) [--repo OWNER/REPO]
#                 [--labels a,b] [--root DIR] [--digest-file PATH] [--dry-run]
#
# Exit: 0 filed/updated · 2 usage/env · 3 parked (sensitive) · 1 gh/other error.
set -euo pipefail

_die()  { echo "issue-file: $*" >&2; exit 2; }
_need() { [ $# -ge 2 ] || _die "flag $1 requires a value"; }

TITLE=""; BODY=""; BODY_FILE=""; REPO=""; LABELS=""; ROOT="."; DIGEST_FILE=""; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --title)       _need "$@"; TITLE="$2"; shift 2 ;;
    --body)        _need "$@"; BODY="$2"; shift 2 ;;
    --body-file)   _need "$@"; BODY_FILE="$2"; shift 2 ;;
    --repo)        _need "$@"; REPO="$2"; shift 2 ;;
    --labels)      _need "$@"; LABELS="$2"; shift 2 ;;
    --root)        _need "$@"; ROOT="$2"; shift 2 ;;
    --digest-file) _need "$@"; DIGEST_FILE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    *) _die "unknown arg $1" ;;
  esac
done

[ -n "$TITLE" ] || _die "--title required"
if [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || _die "--body-file not found: $BODY_FILE"
  BODY="$(cat "$BODY_FILE")"
fi
[ -n "$BODY" ] || _die "--body or --body-file required"

# Read-only PII/secrets dependency — single source of truth; never modified here.
_sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pii-gate.sh
. "$_sd/pii-gate.sh" || _die "PII gate unavailable"
command -v pii_hit >/dev/null 2>&1 || _die "PII gate unavailable"

# Normalize a title for dedup: lowercase, non-alphanumerics → spaces, collapse runs.
_norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'; }

_digest_line() {  # $1: line — append to the run digest so /digest surfaces it
  [ -n "$DIGEST_FILE" ] || return 0
  mkdir -p "$(dirname "$DIGEST_FILE")" 2>/dev/null || true
  printf '%s\n' "$1" >> "$DIGEST_FILE"
}

# --- Sensitive-content carve-out: park instead of filing ---
title_pii=0; pii_hit "$TITLE" && title_pii=1
if [ "$title_pii" = 1 ] || pii_hit "$BODY"; then
  # Never echo a title that itself carries PII/secret into the local doc or the log.
  safe_title="$TITLE"; [ "$title_pii" = 1 ] && safe_title="(withheld — title contains sensitive content)"
  if [ "$DRY_RUN" = 1 ]; then
    echo "[DRY RUN] would PARK (sensitive content): $safe_title"; exit 3
  fi
  local_tasks="$ROOT/docs/human-tasks.md"
  mkdir -p "$ROOT/docs"
  [ -f "$local_tasks" ] || printf '# Human Tasks\n\n## Pending\n\n## Completed\n' > "$local_tasks"
  entry="$(printf -- '- [ ] **Review sensitive defect before filing: %s** — needed for: redact customer data / security detail, then file manually\n  - Notes: auto-file blocked by the pii-gate; the draft carries a secret-shaped or PII string.' "$safe_title")"
  # Insert under the FIRST "## Pending" header; if the doc lacks one, append a section so
  # the entry is never silently dropped.
  if grep -q '^## \+Pending' "$local_tasks"; then
    tmp="$(mktemp)"
    awk -v e="$entry" '{print} /^## +Pending/ && !done {print e; done=1}' "$local_tasks" > "$tmp" && mv "$tmp" "$local_tasks"
  else
    printf '\n## Pending\n\n%s\n' "$entry" >> "$local_tasks"
  fi
  echo "issue-file: PARKED (sensitive) → $local_tasks"
  exit 3
fi

# --- Resolve repo (read-only; skipped under dry-run) ---
if [ -z "$REPO" ] && [ "$DRY_RUN" != 1 ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ -n "$REPO" ] || _die "could not resolve repo (pass --repo OWNER/REPO)"
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "[DRY RUN] would file/dedup issue: $TITLE"
  exit 0
fi

# Body travels via a temp file so non-ASCII / generated text survives intact.
bodyf="$(mktemp)"; printf '%s\n' "$BODY" > "$bodyf"
trap 'rm -f "$bodyf"' EXIT

# --- Dedup: search open issues, match on normalized title ---
# Fail CLOSED: a failed search/parse must not fall through to CREATE (that would duplicate
# issues exactly when dedup is unavailable — auth/network/tooling failure).
want="$(_norm "$TITLE")"
match=""
hits="$(gh issue list --repo "$REPO" --state open --search "$TITLE in:title" --json number,title,url 2>/dev/null)" \
  || { echo "issue-file: dedup search failed (gh) — refusing to file" >&2; exit 1; }
n="$(printf '%s' "$hits" | jq 'length' 2>/dev/null)" \
  || { echo "issue-file: dedup parse failed — refusing to file" >&2; exit 1; }
i=0
while [ "$i" -lt "$n" ]; do
  ht="$(printf '%s' "$hits" | jq -r ".[$i].title")"
  if [ "$(_norm "$ht")" = "$want" ]; then
    match="$(printf '%s' "$hits" | jq -r ".[$i].url")"
    mnum="$(printf '%s' "$hits" | jq -r ".[$i].number")"
    break
  fi
  i=$((i + 1))
done

if [ -n "$match" ]; then
  if gh issue comment "$mnum" --repo "$REPO" --body-file "$bodyf" >/dev/null 2>&1; then
    echo "$match"
    _digest_line "- Updated issue #$mnum $match"
    exit 0
  fi
  echo "issue-file: comment failed on #$mnum" >&2; exit 1
fi

lbl=(); [ -n "$LABELS" ] && lbl=(--label "$LABELS")
if url="$(gh issue create --repo "$REPO" --title "$TITLE" --body-file "$bodyf" "${lbl[@]}" 2>/dev/null)"; then
  url="$(printf '%s' "$url" | grep -oE 'https://[^[:space:]]+' | tail -1)"
  [ -n "$url" ] || { echo "issue-file: create returned no URL" >&2; exit 1; }
  echo "$url"
  num="$(printf '%s' "$url" | grep -oE '[0-9]+$')"
  _digest_line "- Filed issue #$num $url"
  exit 0
fi
echo "issue-file: create failed" >&2; exit 1
