#!/usr/bin/env bash
#
# issue-closure-audit.sh - guard against closing an issue when the PR only
# satisfies a subset of the issue's material acceptance.
#
# Online usage:
#   issue-closure-audit.sh --pr PR_NUMBER_OR_URL [--repo OWNER/REPO]
#
# Offline/test usage:
#   issue-closure-audit.sh --pr-json pr.json --issue-json issue.json --changed-files files.txt

set -uo pipefail

PR=""
REPO=""
PR_JSON=""
CHANGED_FILES=""
ISSUE_JSON_FILES=()

_need_val() { [ "$1" -ge 2 ] || { echo "issue-closure-audit: $2 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pr) _need_val "$#" "$1"; PR="$2"; shift 2 ;;
    --repo) _need_val "$#" "$1"; REPO="$2"; shift 2 ;;
    --pr-json) _need_val "$#" "$1"; PR_JSON="$2"; shift 2 ;;
    --issue-json) _need_val "$#" "$1"; ISSUE_JSON_FILES+=("$2"); shift 2 ;;
    --changed-files) _need_val "$#" "$1"; CHANGED_FILES="$2"; shift 2 ;;
    *) echo "issue-closure-audit: unknown arg: $1" >&2; exit 2 ;;
  esac
done

AUDIT_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$AUDIT_TMPDIR"' EXIT

PR_VIEW="$AUDIT_TMPDIR/pr.json"
FILES="$AUDIT_TMPDIR/files.txt"

if [ -n "$PR_JSON" ]; then
  [ -f "$PR_JSON" ] || { echo "issue-closure-audit: missing --pr-json $PR_JSON" >&2; exit 2; }
  cp "$PR_JSON" "$PR_VIEW"
else
  [ -n "$PR" ] || { echo "issue-closure-audit: --pr or --pr-json is required" >&2; exit 2; }
  repo_args=()
  [ -n "$REPO" ] && repo_args=(--repo "$REPO")
  gh pr view "$PR" "${repo_args[@]}" --json number,title,body,files > "$PR_VIEW" 2>/dev/null || {
    echo "issue-closure-audit: cannot inspect PR $PR" >&2
    exit 1
  }
fi

if [ -n "$CHANGED_FILES" ]; then
  [ -f "$CHANGED_FILES" ] || { echo "issue-closure-audit: missing --changed-files $CHANGED_FILES" >&2; exit 2; }
  cp "$CHANGED_FILES" "$FILES"
else
  jq -r '.files[]?.path // empty' "$PR_VIEW" > "$FILES" 2>/dev/null || : > "$FILES"
fi

title="$(jq -r '.title // ""' "$PR_VIEW" 2>/dev/null)"
body="$(jq -r '.body // ""' "$PR_VIEW" 2>/dev/null)"
pr_text="$(printf '%s\n%s\n' "$title" "$body")"

closure_nums="$(printf '%s' "$pr_text" \
  | grep -Eio '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]+#[0-9]+' \
  | grep -Eo '[0-9]+' | sort -u || true)"

if [ -z "$closure_nums" ]; then
  echo "issue-closure-audit: no closing keywords found; nothing to audit."
  exit 0
fi

find_issue_file() {
  local n="$1" f
  for f in "${ISSUE_JSON_FILES[@]}"; do
    [ -f "$f" ] || continue
    if [ "$(jq -r '.number // empty' "$f" 2>/dev/null)" = "$n" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  if [ "${#ISSUE_JSON_FILES[@]}" -eq 1 ]; then
    f="${ISSUE_JSON_FILES[0]}"
    if [ -f "$f" ] && jq -e 'has("number") | not' "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f"
      return 0
    fi
  fi
  return 1
}

fetch_issue() {
  local n="$1" dst="$2" src repo_args
  if src="$(find_issue_file "$n")"; then
    cp "$src" "$dst"
    return 0
  fi
  repo_args=()
  [ -n "$REPO" ] && repo_args=(--repo "$REPO")
  gh issue view "$n" "${repo_args[@]}" --json number,title,body,comments > "$dst" 2>/dev/null
}

extract_paths() {
  # Extract explicit path-like tokens from issue body/comments. This is a mechanical
  # backstop; the workflow prompt still audits non-path surfaces by judgment.
  #
  # `[` `]` are kept out of the split set: they're legitimate path characters in
  # Next.js/React Router dynamic-route segments (e.g. app/[locale]/[token]/page.tsx),
  # and splitting on them shatters such a path into a bare basename that can never
  # match the changed-files list. Markdown-link splitting still works because `(` `)`
  # remain split characters, isolating the link target.
  tr '`",;()' '\n' \
    | sed -E 's/^[[:space:][:punct:]]+//; s/[[:space:][:punct:]]+$//' \
    | grep -E '(^|/)[][A-Za-z0-9_.-]+/[][A-Za-z0-9_./-]+\.[A-Za-z0-9]+$|^[][A-Za-z0-9_./-]+\.(py|js|jsx|ts|tsx|go|rb|php|java|md|json|ya?ml|sql|sh|css|html)$' \
    | grep -vE '^https?://' \
    | sort -u || true
}

has_override() {
  local n="$1" path="$2"
  printf '%s' "$body" | grep -qi 'Closure audit' || return 1
  printf '%s' "$body" | grep -q "#$n" || return 1
  printf '%s' "$body" | grep -qiE 'follow-up|not applicable|irrelevant|remaining scope|deferred|refs #[0-9]+' || return 1
  # Mentioning the exact path is preferred, but a structured per-issue closure-audit
  # section is enough for non-path surfaces and renamed files.
  [ -n "$path" ]
}

failures=0

for n in $closure_nums; do
  issue_file="$AUDIT_TMPDIR/issue-$n.json"
  if ! fetch_issue "$n" "$issue_file"; then
    echo "issue-closure-audit: cannot inspect closing issue #$n. Refusing." >&2
    failures=$((failures + 1))
    continue
  fi

  issue_text="$(jq -r '[.title?, .body?, (.comments[]?.body?)] | map(select(type=="string")) | join("\n")' "$issue_file" 2>/dev/null)"
  paths="$(printf '%s' "$issue_text" | extract_paths)"
  [ -n "$paths" ] || continue

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if grep -qxF "$path" "$FILES"; then
      continue
    fi
    if has_override "$n" "$path"; then
      continue
    fi
    echo "issue-closure-audit: PR closes #$n but does not touch explicitly named surface: $path" >&2
    echo "issue-closure-audit: add a Closure audit explanation/follow-up, change Closes to Refs, or include the missing surface." >&2
    failures=$((failures + 1))
  done <<< "$paths"
done

if [ "$failures" -gt 0 ]; then
  exit 1
fi

echo "issue-closure-audit: closing issue surfaces accounted for."
exit 0
