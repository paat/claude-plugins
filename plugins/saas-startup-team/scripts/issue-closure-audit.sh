#!/usr/bin/env bash
#
# issue-closure-audit.sh - guard against closing an issue when the PR only
# satisfies a subset of the issue's material acceptance.
#
# Online usage:
#   issue-closure-audit.sh --pr PR_NUMBER_OR_URL [--repo OWNER/REPO] [--audit-issue N]...
#
# Offline/test usage:
#   issue-closure-audit.sh --pr-json pr.json --issue-json issue.json --changed-files files.txt

set -uo pipefail

PR=""
REPO=""
PR_JSON=""
CHANGED_FILES=""
ISSUE_JSON_FILES=()
AUDIT_ISSUES=()
CLOSING_KEYWORD_RE='(close[sd]?|fix(e[sd])?|resolve[sd]?)'
CLOSING_TARGET_RE='(#[0-9]+|[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*#[0-9]+|https?://github\.com/[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*/issues/[0-9]+)'
CLOSING_REFERENCE_RE="(^|[^[:alnum:]_])${CLOSING_KEYWORD_RE}[[:space:]]*:?[[:space:]]+${CLOSING_TARGET_RE}"

_need_val() { [ "$1" -ge 2 ] || { echo "issue-closure-audit: $2 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pr) _need_val "$#" "$1"; PR="$2"; shift 2 ;;
    --repo) _need_val "$#" "$1"; REPO="$2"; shift 2 ;;
    --pr-json) _need_val "$#" "$1"; PR_JSON="$2"; shift 2 ;;
    --issue-json) _need_val "$#" "$1"; ISSUE_JSON_FILES+=("$2"); shift 2 ;;
    --audit-issue)
      _need_val "$#" "$1"
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || {
        echo "issue-closure-audit: --audit-issue must be a positive integer" >&2; exit 2; }
      AUDIT_ISSUES+=("$2"); shift 2 ;;
    --changed-files) _need_val "$#" "$1"; CHANGED_FILES="$2"; shift 2 ;;
    *) echo "issue-closure-audit: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$REPO" ] && ! [[ "$REPO" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "issue-closure-audit: --repo must be OWNER/REPO" >&2
  exit 2
fi
RESOLVED_REPO="$REPO"; PR_URL_REPO=""
if [[ "$PR" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/[1-9][0-9]*([/?#].*)?$ ]]; then
  PR_URL_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
fi
if [ -n "$PR_URL_REPO" ] && [ -n "$RESOLVED_REPO" ] \
  && [ "${PR_URL_REPO,,}" != "${RESOLVED_REPO,,}" ]; then
  echo "issue-closure-audit: --repo conflicts with the pull request URL" >&2
  exit 2
fi
if [ -z "$PR_JSON" ] && [ -z "$RESOLVED_REPO" ]; then
  if [ -n "$PR_URL_REPO" ]; then
    RESOLVED_REPO="$PR_URL_REPO"
  else
    RESOLVED_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
      echo "issue-closure-audit: cannot resolve the pull request repository" >&2
      exit 1
    }
  fi
fi
if [ -n "$RESOLVED_REPO" ] \
  && ! [[ "$RESOLVED_REPO" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "issue-closure-audit: resolved repository identity is invalid" >&2
  exit 1
fi

AUDIT_TMPDIR="$(mktemp -d)" || {
  echo "issue-closure-audit: cannot create private audit workspace" >&2
  exit 1
}
trap 'rm -rf "$AUDIT_TMPDIR"' EXIT

PR_VIEW="$AUDIT_TMPDIR/pr.json"
FILES="$AUDIT_TMPDIR/files.txt"

if [ -n "$PR_JSON" ]; then
  [ -f "$PR_JSON" ] || { echo "issue-closure-audit: missing --pr-json $PR_JSON" >&2; exit 2; }
  cp "$PR_JSON" "$PR_VIEW" || {
    echo "issue-closure-audit: cannot read --pr-json $PR_JSON" >&2
    exit 1
  }
else
  [ -n "$PR" ] || { echo "issue-closure-audit: --pr or --pr-json is required" >&2; exit 2; }
  repo_args=()
  [ -n "$RESOLVED_REPO" ] && repo_args=(--repo "$RESOLVED_REPO")
  gh pr view "$PR" "${repo_args[@]}" --json number,title,body,files > "$PR_VIEW" 2>/dev/null || {
    echo "issue-closure-audit: cannot inspect PR $PR" >&2
    exit 1
  }
fi

if ! jq -e '
  type == "object"
  and (.body | type == "string")
  and ((has("title") | not) or .title == null or (.title | type == "string"))
' "$PR_VIEW" >/dev/null 2>&1; then
  echo "issue-closure-audit: malformed PR JSON or invalid body shape. Refusing." >&2
  exit 1
fi

if [ -n "$CHANGED_FILES" ]; then
  [ -f "$CHANGED_FILES" ] || { echo "issue-closure-audit: missing --changed-files $CHANGED_FILES" >&2; exit 2; }
  cp "$CHANGED_FILES" "$FILES" || {
    echo "issue-closure-audit: cannot read --changed-files $CHANGED_FILES" >&2
    exit 1
  }
else
  if ! jq -e '
    (.files | type == "array")
    and all(.files[]; type == "object"
      and (.path | type == "string")
      and (.path | length > 0))
  ' "$PR_VIEW" >/dev/null 2>&1; then
    echo "issue-closure-audit: malformed PR JSON or invalid files shape. Refusing." >&2
    exit 1
  fi
  jq -r '.files[].path' "$PR_VIEW" > "$FILES" 2>/dev/null || {
    echo "issue-closure-audit: cannot extract PR files. Refusing." >&2
    exit 1
  }
fi

title="$(jq -r '.title // ""' "$PR_VIEW" 2>/dev/null)" || {
  echo "issue-closure-audit: cannot extract PR title. Refusing." >&2
  exit 1
}
body="$(jq -r '.body' "$PR_VIEW" 2>/dev/null)" || {
  echo "issue-closure-audit: cannot extract PR body. Refusing." >&2
  exit 1
}
pr_text="$(printf '%s\n%s\n' "$title" "$body")"

contains_closing_reference() {
  local text="$1" rc=0
  printf '%s\n' "$text" | grep -Eiq -- "$CLOSING_REFERENCE_RE" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

closing_reference_numbers() {
  local text="$1" matches rc=0
  matches="$(printf '%s\n' "$text" | grep -Eio -- "$CLOSING_REFERENCE_RE")" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$matches" | sed -E 's|.*(#\|/issues/)([0-9]+)$|\2|'
}

qualified_closing_repositories() {
  local text="$1" matches rc=0 line target
  matches="$(printf '%s\n' "$text" | grep -Eio -- "$CLOSING_REFERENCE_RE")" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
  while IFS= read -r line; do
    target=$(printf '%s\n' "$line" | grep -Eio -- "${CLOSING_TARGET_RE}$") || return 1
    case "$target" in
      \#*) ;;
      http://github.com/*/issues/*|https://github.com/*/issues/*)
        target=${target#*github.com/}; target=${target%/issues/*}
        printf '%s\n' "${target,,}"
        ;;
      *\#*) printf '%s\n' "${target%#*}" | tr '[:upper:]' '[:lower:]' ;;
      *) return 1 ;;
    esac
  done <<< "$matches"
}

validate_qualified_closing_repositories() {
  local qualified current repo
  qualified=$(qualified_closing_repositories "$pr_text") || return 1
  [ -n "$qualified" ] || return 0
  [ -n "$RESOLVED_REPO" ] || {
    echo "issue-closure-audit: qualified closing references require --repo in offline audits. Refusing." >&2
    return 1
  }
  current=${RESOLVED_REPO,,}
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    [ "$repo" = "$current" ] || {
      echo "issue-closure-audit: cross-repository closing references are not auditable in this transaction. Refusing." >&2
      return 1
    }
  done <<< "$qualified"
}

audit_nums="$(printf '%s\n' "${AUDIT_ISSUES[@]}" | sed '/^$/d' | sort -nu)" || {
  echo "issue-closure-audit: cannot normalize audited issue numbers. Refusing." >&2
  exit 1
}
if [ -n "$audit_nums" ]; then
  prospective_failures=0
  closing_rc=0
  contains_closing_reference "$pr_text" || closing_rc=$?
  case "$closing_rc" in
    0)
      echo "issue-closure-audit: prospective PR title/body contains a closing issue reference. Refusing." >&2
      prospective_failures=$((prospective_failures + 1))
      ;;
    1) ;;
    *) echo "issue-closure-audit: cannot inspect PR closing references. Refusing." >&2; exit 1 ;;
  esac
  if grep -Eq '^Closure-Audit-Path:' <<< "$body"; then
    echo "issue-closure-audit: prospective audits cannot defer named surfaces. Refusing." >&2
    prospective_failures=$((prospective_failures + 1))
  fi
  audit_count=$(wc -l <<< "$audit_nums" | tr -d ' ')
  refs_lines=$(grep -E '^Refs #[0-9]+$' <<< "$body" || true)
  markers_lines=$(grep -E '^Maintain-Loop-Issue: #[0-9]+$' <<< "$body" || true)
  refs_count=0; markers_count=0
  [ -z "$refs_lines" ] || refs_count=$(wc -l <<< "$refs_lines" | tr -d ' ')
  [ -z "$markers_lines" ] || markers_count=$(wc -l <<< "$markers_lines" | tr -d ' ')
  if [ "$refs_count" -ne "$audit_count" ]; then
    echo "issue-closure-audit: Refs lines must bind exactly once to the audited issue set. Refusing." >&2
    prospective_failures=$((prospective_failures + 1))
  fi
  if [ "$markers_count" -ne "$audit_count" ]; then
    echo "issue-closure-audit: Maintain-Loop-Issue lines must bind exactly once to the audited issue set. Refusing." >&2
    prospective_failures=$((prospective_failures + 1))
  fi
  for n in $audit_nums; do
    ref_count=$(grep -Fxc -- "Refs #$n" <<< "$body" || true)
    marker_count=$(grep -Fxc -- "Maintain-Loop-Issue: #$n" <<< "$body" || true)
    if [ "$ref_count" -ne 1 ]; then
      echo "issue-closure-audit: prospective PR body needs exactly one exact line: Refs #$n" >&2
      prospective_failures=$((prospective_failures + 1))
    fi
    if [ "$marker_count" -ne 1 ]; then
      echo "issue-closure-audit: prospective PR body needs exactly one exact line: Maintain-Loop-Issue: #$n" >&2
      prospective_failures=$((prospective_failures + 1))
    fi
  done
  [ "$prospective_failures" -eq 0 ] || exit 1
fi

validate_qualified_closing_repositories || {
  echo "issue-closure-audit: cannot bind qualified closing references to this repository. Refusing." >&2
  exit 1
}
detected_closure_nums="$(closing_reference_numbers "$pr_text")" || {
  echo "issue-closure-audit: cannot extract PR closing references. Refusing." >&2
  exit 1
}
closure_nums="$({
  printf '%s\n' "$detected_closure_nums"
  printf '%s\n' "$audit_nums"
} | sed '/^$/d' | sort -nu)" || {
  echo "issue-closure-audit: cannot normalize PR closing references. Refusing." >&2
  exit 1
}

if [ -z "$closure_nums" ]; then
  echo "issue-closure-audit: no closing keywords found; nothing to audit."
  exit 0
fi

declare -A ISSUE_JSON_BY_NUMBER=()

find_issue_file() {
  local n="$1" f
  if [ -n "${ISSUE_JSON_BY_NUMBER[$n]+present}" ]; then
    printf '%s\n' "${ISSUE_JSON_BY_NUMBER[$n]}"
    return 0
  fi
  if [ "${#ISSUE_JSON_FILES[@]}" -eq 1 ]; then
    f="${ISSUE_JSON_FILES[0]}"
    printf '%s\n' "$f"
    return 0
  fi
  return 1
}

fetch_issue() {
  local n="$1" dst="$2" src repo_args
  if src="$(find_issue_file "$n")"; then
    cp "$src" "$dst" || return 1
    return 0
  fi
  repo_args=()
  [ -n "$RESOLVED_REPO" ] && repo_args=(--repo "$RESOLVED_REPO")
  gh issue view "$n" "${repo_args[@]}" --json number,state,title,body,comments > "$dst" 2>/dev/null
}

validate_issue_shape() {
  jq -e '
    type == "object"
    and (.number | type == "number" and . >= 1 and floor == .)
    and (.state | type == "string")
    and (.title | type == "string")
    and (.body | type == "string")
    and (.comments | type == "array")
    and all(.comments[]; type == "object" and (.body | type == "string"))
  ' "$1" >/dev/null 2>&1
}

for issue_json in "${ISSUE_JSON_FILES[@]}"; do
  [ -f "$issue_json" ] || {
    echo "issue-closure-audit: missing --issue-json $issue_json" >&2
    exit 2
  }
  validate_issue_shape "$issue_json" || {
    echo "issue-closure-audit: malformed issue JSON: $issue_json. Refusing." >&2
    exit 1
  }
  fixture_number="$(jq -r '.number' "$issue_json")" || {
    echo "issue-closure-audit: cannot read issue fixture number. Refusing." >&2
    exit 1
  }
  if [ -n "${ISSUE_JSON_BY_NUMBER[$fixture_number]+present}" ]; then
    echo "issue-closure-audit: duplicate issue JSON for #$fixture_number. Refusing." >&2
    exit 1
  fi
  ISSUE_JSON_BY_NUMBER[$fixture_number]="$issue_json"
done

extract_paths() {
  # Extract explicit path-like tokens from issue body/comments. This is a mechanical
  # backstop; the workflow prompt still audits non-path surfaces by judgment.
  #
  # `[` `]` are kept out of the split set: they're legitimate path characters in
  # Next.js/React Router dynamic-route segments (e.g. app/[locale]/[token]/page.tsx),
  # and splitting on them shatters such a path into a bare basename that can never
  # match the changed-files list. Markdown-link splitting still works because `(` `)`
  # remain split characters, isolating the link target.
  local dir rc=0
  dir=$(mktemp -d) || return 1
  if ! cat > "$dir/raw" \
    || ! tr '`",;()' '\n' < "$dir/raw" > "$dir/split" \
    || ! sed -E 's/^[[:space:][:punct:]]+//; s/[[:space:][:punct:]]+$//' \
      < "$dir/split" > "$dir/clean"; then
    rm -rf -- "$dir"; return 1
  fi
  grep -E '(^|/)[][A-Za-z0-9_.-]+/[][A-Za-z0-9_./-]+\.[A-Za-z0-9]+$|^[][A-Za-z0-9_./-]+\.(py|js|jsx|ts|tsx|go|rb|php|java|md|json|ya?ml|sql|sh|css|html)$' \
    "$dir/clean" > "$dir/paths" || rc=$?
  case "$rc" in
    0) ;;
    1) rm -rf -- "$dir"; return 0 ;;
    *) rm -rf -- "$dir"; return 1 ;;
  esac
  rc=0
  grep -vE '^https?://' "$dir/paths" > "$dir/local" || rc=$?
  case "$rc" in
    0) ;;
    1) rm -rf -- "$dir"; return 0 ;;
    *) rm -rf -- "$dir"; return 1 ;;
  esac
  sort -u "$dir/local" || { rm -rf -- "$dir"; return 1; }
  rm -rf -- "$dir"
}

# Drop bare basenames when a full repository path with the same basename is
# already present. Issue text often cites both `path/to/file.py` and `file.py`;
# requiring the bare basename in the PR file list is a false fail (#1604).
dedupe_issue_paths() {
  local paths="$1" p base
  declare -A full_basenames=()
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      */*)
        base="${p##*/}"
        full_basenames["$base"]=1
        ;;
    esac
  done <<< "$paths"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      */*) printf '%s\n' "$p" ;;
      *)
        if [ -n "${full_basenames[$p]+present}" ]; then
          continue
        fi
        printf '%s\n' "$p"
        ;;
    esac
  done <<< "$paths"
}

# Explicit negative/unchanged surface disposition. A named path that must remain
# behaviorally unchanged is not an unimplemented surface when the PR body binds
# one exact reason (backed by test/evidence prose). Format:
#   Closure-Audit-Unchanged: #N path/to/file | concrete reason (min 20 chars)
has_unchanged_disposition() {
  local n="$1" path="$2"
  local prefix reasons count reason
  prefix="Closure-Audit-Unchanged: #$n $path | "
  reasons="$(printf '%s\n' "$body" | awk -v prefix="$prefix" '
    index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }
  ')"
  [ -n "$reasons" ] || return 1
  count=$(printf '%s\n' "$reasons" | wc -l | tr -d ' ')
  if [ "$count" -ne 1 ]; then
    echo "issue-closure-audit: unchanged disposition for #$n $path must appear exactly once. Refusing." >&2
    return 1
  fi
  reason="$reasons"
  # Require a concrete reason (min 20 non-space-trimmed characters).
  if ! printf '%s\n' "$reason" | grep -Eq '^[^[:space:]].{19,}$'; then
    echo "issue-closure-audit: unchanged disposition for #$n $path needs a concrete reason (min 20 chars). Refusing." >&2
    return 1
  fi
  return 0
}

has_authorized_deferral() {
  local n="$1" path="$2" issue_file="$3"
  local prefix reasons count reason followup followup_file followup_number followup_state
  local issue_text split_prefix split_lines split_count
  # A prospective maintain-loop audit is one-shot delivery authority: every named
  # surface must be present in the candidate diff. A closing PR may instead bind
  # one authorized OPEN follow-up to one exact issue/path pair.
  [ -z "$audit_nums" ] || return 1
  prefix="Closure-Audit-Path: #$n $path | "
  reasons="$(printf '%s\n' "$body" | awk -v prefix="$prefix" '
    index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }
  ')"
  [ -n "$reasons" ] || return 1
  count=$(printf '%s\n' "$reasons" | wc -l | tr -d ' ')
  if [ "$count" -ne 1 ]; then
    echo "issue-closure-audit: deferral for #$n $path must appear exactly once. Refusing." >&2
    return 1
  fi
  reason="$reasons"
  if ! printf '%s\n' "$reason" \
      | grep -Eq '^follow-up #[1-9][0-9]*: [^[:space:]].{19,}$'; then
    echo "issue-closure-audit: deferral for #$n $path must name one follow-up issue and a concrete reason. Refusing." >&2
    return 1
  fi
  followup="$(printf '%s\n' "$reason" | sed -E 's/^follow-up #([1-9][0-9]*):.*/\1/')"
  if [ "$followup" = "$n" ]; then
    echo "issue-closure-audit: follow-up #$followup must differ from original issue #$n. Refusing." >&2
    return 1
  fi
  if grep -Fqx -- "$followup" <<< "$closure_nums"; then
    echo "issue-closure-audit: follow-up #$followup is also closed by this PR. Refusing." >&2
    return 1
  fi

  issue_text="$(jq -r '[.body, (.comments[].body)] | join("\n")' "$issue_file" 2>/dev/null)" || {
    echo "issue-closure-audit: cannot inspect split authorization on issue #$n. Refusing." >&2
    return 1
  }
  split_prefix="Closure-Audit-Split: #$n $path -> #"
  split_lines="$(printf '%s\n' "$issue_text" | awk -v prefix="$split_prefix" \
    'index($0, prefix) == 1 { print }')"
  split_count=0
  [ -z "$split_lines" ] || split_count=$(printf '%s\n' "$split_lines" | wc -l | tr -d ' ')
  if [ "$split_count" -ne 1 ] \
      || [ "$split_lines" != "${split_prefix}${followup}" ]; then
    echo "issue-closure-audit: original issue #$n needs exactly one split authorization: ${split_prefix}${followup}" >&2
    return 1
  fi

  followup_file="$AUDIT_TMPDIR/follow-up-$followup.json"
  if [ ! -f "$followup_file" ] && ! fetch_issue "$followup" "$followup_file"; then
    echo "issue-closure-audit: cannot inspect follow-up issue #$followup. Refusing." >&2
    return 1
  fi
  if ! validate_issue_shape "$followup_file"; then
    echo "issue-closure-audit: malformed follow-up issue #$followup. Refusing." >&2
    return 1
  fi
  followup_number="$(jq -r '.number' "$followup_file")"
  followup_state="$(jq -r '.state' "$followup_file")"
  if [ "$followup_number" != "$followup" ]; then
    echo "issue-closure-audit: follow-up payload #$followup_number does not match #$followup. Refusing." >&2
    return 1
  fi
  if [ "$followup_state" != "OPEN" ]; then
    echo "issue-closure-audit: follow-up issue #$followup is $followup_state, not OPEN. Refusing." >&2
    return 1
  fi
  return 0
}

failures=0

for n in $closure_nums; do
  issue_file="$AUDIT_TMPDIR/issue-$n.json"
  if ! fetch_issue "$n" "$issue_file"; then
    echo "issue-closure-audit: cannot inspect closing issue #$n. Refusing." >&2
    failures=$((failures + 1))
    continue
  fi

  if ! validate_issue_shape "$issue_file"; then
    echo "issue-closure-audit: malformed issue JSON for #$n. Refusing." >&2
    failures=$((failures + 1))
    continue
  fi
  issue_number="$(jq -r '.number' "$issue_file" 2>/dev/null)" || {
    echo "issue-closure-audit: cannot extract issue number for #$n. Refusing." >&2
    failures=$((failures + 1))
    continue
  }
  if [ "$issue_number" != "$n" ]; then
    echo "issue-closure-audit: issue payload number #$issue_number does not match audited issue #$n. Refusing." >&2
    failures=$((failures + 1))
    continue
  fi
  issue_state="$(jq -r '.state' "$issue_file" 2>/dev/null)" || {
    echo "issue-closure-audit: cannot extract issue state for #$n. Refusing." >&2
    failures=$((failures + 1))
    continue
  }
  if [ "$issue_state" != "OPEN" ]; then
    echo "issue-closure-audit: audited issue #$n is $issue_state, not OPEN. Refusing." >&2
    failures=$((failures + 1))
    continue
  fi

  issue_text="$(jq -r '[.title, .body, (.comments[].body)] | join("\n")' "$issue_file" 2>/dev/null)" || {
    echo "issue-closure-audit: cannot extract issue text for #$n. Refusing." >&2
    failures=$((failures + 1))
    continue
  }
  paths="$(printf '%s' "$issue_text" | extract_paths)" || {
    echo "issue-closure-audit: cannot extract named issue surfaces for #$n. Refusing." >&2
    failures=$((failures + 1))
    continue
  }
  [ -n "$paths" ] || continue
  paths="$(dedupe_issue_paths "$paths")" || {
    echo "issue-closure-audit: cannot canonicalize named issue surfaces for #$n. Refusing." >&2
    failures=$((failures + 1))
    continue
  }
  [ -n "$paths" ] || continue

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if grep -qxF "$path" "$FILES"; then
      continue
    fi
    if has_unchanged_disposition "$n" "$path"; then
      continue
    fi
    if has_authorized_deferral "$n" "$path" "$issue_file"; then
      continue
    fi
    echo "issue-closure-audit: PR closes #$n but does not touch explicitly named surface: $path" >&2
    if [ -n "$audit_nums" ]; then
      echo "issue-closure-audit: prospective audits cannot defer named surfaces; include the missing surface." >&2
    else
      echo "issue-closure-audit: include the surface, change Closes to Refs, add Closure-Audit-Unchanged for a negative requirement, or add an authorized exact Closure-Audit-Path mapping to an OPEN follow-up." >&2
    fi
    failures=$((failures + 1))
  done <<< "$paths"
done

if [ "$failures" -gt 0 ]; then
  exit 1
fi

echo "issue-closure-audit: closing issue surfaces accounted for."
exit 0
