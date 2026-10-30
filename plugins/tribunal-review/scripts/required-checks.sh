#!/usr/bin/env bash
# Report required GitHub check-runs for an exact commit sha (fail-closed).
#
# Usage:
#   required-checks.sh --repo owner/name --sha <40-hex> [--base <branch>]
#
# Prints one JSON object to stdout:
#   {sha, checks:[{name,status,conclusion}], ok:bool, ci, reason?}
#
# Exit 0 iff every required check is completed+success and at least one
# required check exists. Exit 1 on empty / pending / failed required checks.
# Exit 2 on bad args or transport/API failure.
#
# Required names = base branch protection contexts/checks plus branch rulesets.
# Base defaults to the repository default branch. Required checks union configured
# names with every check-run whose conclusion is not skipped/neutral.
# A required name whose latest run is skipped/neutral fails (stricter than GitHub; deliberately fail-closed).
# Empty check-runs list ⇒ ok=false (unearned green).
# With no configured names, legacy statuses, or active Actions workflows either, ci=none.
# Legacy statuses prevent the no-CI exception; status-only required contexts count as missing.
# Does not use `gh pr checks` (can mis-label required vs optional).
set -euo pipefail

export NO_COLOR=1 CLICOLOR_FORCE=0 GH_FORCE_TTY=

usage() {
  printf 'usage: %s --repo owner/name --sha <40-hex> [--base <branch>]\n' "$(basename "$0")" >&2
  exit 2
}

REPO=""
SHA=""
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || usage
      REPO="$2"
      shift 2
      ;;
    --sha)
      [ $# -ge 2 ] || usage
      SHA="$2"
      shift 2
      ;;
    --base)
      [ $# -ge 2 ] && [ -n "$2" ] || usage
      BASE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      printf 'required-checks: unknown arg: %s\n' "$1" >&2
      usage
      ;;
  esac
done

[ -n "$REPO" ] && [ -n "$SHA" ] || usage

case "$REPO" in
  */*) ;;
  *)
    printf 'required-checks: --repo must be owner/name, got %s\n' "$REPO" >&2
    exit 2
    ;;
esac
# Reject empty owner or name, or extra slashes.
case "$REPO" in
  /*|*/*/*|*/)
    printf 'required-checks: --repo must be owner/name, got %s\n' "$REPO" >&2
    exit 2
    ;;
esac
printf '%s' "$REPO" | grep -Eq '^[^/]+/[^/]+$' || {
  printf 'required-checks: --repo must be owner/name, got %s\n' "$REPO" >&2
  exit 2
}

printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{40}$' || {
  printf 'required-checks: --sha must be a 40-char lowercase hex oid, got %s\n' "$SHA" >&2
  exit 2
}

command -v gh >/dev/null 2>&1 || {
  printf 'required-checks: gh is required\n' >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  printf 'required-checks: jq is required\n' >&2
  exit 2
}

ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT HUP INT TERM

api() {
  local reason="$1" response doc='' empty=''
  shift
  if ! response="$(gh api -H 'Accept: application/vnd.github+json' "$@" 2>"$ERR")"; then
    case "$reason" in
      rules)
        doc='https://docs.github.com/rest/repos/rules#get-rules-for-a-branch'
        empty='[]' ;;
    esac
    # GitHub's free-private-plan denial, probed 2026-10-30 on the rules API.
    # Match the API JSON, not stderr: permission/rate-limit/partial-page failures stay closed.
    if [ -n "$doc" ] && printf '%s' "$response" | jq -se --arg doc "$doc" '
      length == 1 and (.[0] |
        .status == "403"
        and .message == "Upgrade to GitHub Pro or make this repository public to enable this feature."
        and .documentation_url == $doc)
    ' >/dev/null 2>&1; then
      printf '%s\n' "$empty"
      return 0
    fi
    printf 'required-checks: %s API failed for %s\n' "$reason" "$REPO" >&2
    cat "$ERR" >&2
    return 2
  fi
  printf '%s\n' "$response"
}

invalid_response() {
  printf 'required-checks: invalid %s response for %s\n' "$1" "$REPO" >&2
  exit 2
}

if [ -z "$BASE" ]; then
  REPOSITORY="$(api 'default branch' "repos/${REPO}")" || exit 2
  BASE="$(printf '%s' "$REPOSITORY" | jq -er '
    .default_branch | select(type == "string" and length > 0)
  ')" || invalid_response 'default branch'
fi
BASE_PATH="$(printf '%s' "$BASE" | jq -sRr @uri)"
BRANCH="$(api 'branch protection' "repos/${REPO}/branches/${BASE_PATH}")" || exit 2
PROTECTION_NAMES="$(printf '%s' "$BRANCH" | jq -ce '
  if type != "object" then error("expected branch object")
  elif (.protection.required_status_checks | type) == "object" then
    .protection.required_status_checks
    | if (has("contexts") or has("checks"))
         and ((.contexts // [] | type) == "array")
         and ((.checks // [] | type) == "array") then
        [(.contexts // [])[], (.checks // [])[] .context]
      else error("invalid required_status_checks") end
  elif .protected == false or .protection.enabled == false
       or ((.protection | type) == "object"
           and (.protection | has("required_status_checks"))
           and .protection.required_status_checks == null) then []
  else error("missing protection metadata") end
  | if all(.[]; type == "string" and length > 0) then unique
    else error("invalid required context") end
')" || invalid_response 'branch protection'

RULES="$(api 'rules' --paginate "repos/${REPO}/rules/branches/${BASE_PATH}?per_page=100")" || exit 2
RULE_NAMES="$(printf '%s' "$RULES" | jq -sce '
  if length > 0 and all(.[]; type == "array") then add
    else error("expected rules arrays") end
  | [ .[]
      | if type == "object" and (.type | type) == "string" then .
        else error("invalid rule") end
      | select(.type == "required_status_checks")
      | .parameters.required_status_checks
      | if type == "array" then .[] .context
        else error("invalid required_status_checks rule") end ]
  | if all(.[]; type == "string" and length > 0) then unique
    else error("invalid required context") end
')" || invalid_response 'rules'
REQUIRED_NAMES="$(jq -nc --argjson protection "$PROTECTION_NAMES" --argjson rules "$RULE_NAMES" \
  '$protection + $rules | unique')"

# REST check-runs on the exact sha. Paginate; never gh pr checks.
RAW_EC=0
RAW="$(gh api --paginate \
  -H 'Accept: application/vnd.github+json' \
  "repos/${REPO}/commits/${SHA}/check-runs?per_page=100" 2>"$ERR")" || RAW_EC=$?

if [ "$RAW_EC" -ne 0 ]; then
  printf 'required-checks: gh api check-runs failed for %s@%s\n' "$REPO" "$SHA" >&2
  cat "$ERR" >&2 || true
  exit 2
fi

# Paginate may emit one object per page. Slurp + flatten. Keep one run per
# name (latest) before evaluating ok — GitHub retains historical re-runs as
# separate objects with the same name. Latest = greatest id when present
# (monotonic); if id is missing, max completed_at, then started_at.
# jq keeps unicode (e.g. em-dashes in check names) without ensure_ascii escaping.
OUT="$(printf '%s\n' "$RAW" | jq -sce --arg sha "$SHA" --argjson names "$REQUIRED_NAMES" '
  if length > 0 and all(.[]; (.check_runs | type) == "array") then .
    else error("invalid check-runs pages") end
  | [.[].check_runs[]] as $raw_runs
  | ($raw_runs
     | group_by(.name // "")
     | map(max_by([
         (if (.id | type) == "number" then .id else -1 end),
         (.completed_at // ""),
         (.started_at // "")
       ]))
    ) as $runs
  | ($runs | map({
      name: (.name // ""),
      status: (.status // ""),
      conclusion: (if .conclusion == null then "" else (.conclusion | tostring) end)
    })) as $present
  | ($present + [$names[] as $name
      | select(all($present[]; .name != $name))
      | {name: $name, status: "missing", conclusion: ""}]) as $checks
  | ($checks | map(select(
      (.name as $name | $names | index($name)) != null
      or ((.conclusion | ascii_downcase) != "skipped"
          and (.conclusion | ascii_downcase) != "neutral")
    ))) as $required
  | {
      sha: $sha,
      checks: $checks,
      ok: (
        ($checks | length) > 0
        and ($required | length) > 0
        and all($required[];
          (.status | ascii_downcase) == "completed"
          and (.conclusion | ascii_downcase) == "success"
        )
      )
    }
  + (if ($raw_runs | length) == 0 and ($names | length) == 0
     then {ci: "none", reason: "no CI configured"}
     else {ci: "checks"} end)
')" || invalid_response 'check-runs'

# An empty commit can precede CI creation or skip active workflows entirely.
if [ "$(printf '%s' "$OUT" | jq -r '.ci')" = none ]; then
  STATUSES="$(api 'commit statuses' "repos/${REPO}/commits/${SHA}/status")" || exit 2
  HAS_STATUSES="$(printf '%s' "$STATUSES" | jq -er '
    if (.total_count | type) == "number" and .total_count >= 0
       and (.statuses | type) == "array" then
      if .total_count > 0 or (.statuses | length) > 0 then "yes" else "no" end
    else error("invalid commit statuses") end
  ')" || invalid_response 'commit statuses'
  WORKFLOWS="$(api 'workflows' --paginate "repos/${REPO}/actions/workflows?per_page=100")" || exit 2
  ACTIVE="$(printf '%s' "$WORKFLOWS" | jq -se '
    if length > 0 and all(.[]; (.workflows | type) == "array") then
      [.[].workflows[]
        | if (.state | type) == "string" then .
          else error("invalid workflow state") end
        | select(.state == "active")] | length
    else error("invalid workflows pages") end
  ')" || invalid_response 'workflows'
  if [ "$ACTIVE" -gt 0 ] || [ "$HAS_STATUSES" = yes ]; then
    OUT="$(printf '%s' "$OUT" | jq -c '.ci = "checks" | del(.reason)')"
  fi
fi

printf '%s\n' "$OUT"
if [ "$(printf '%s' "$OUT" | jq -r '.ok')" = "true" ]; then
  exit 0
fi
exit 1
