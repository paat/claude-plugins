#!/usr/bin/env bash
# Report required GitHub check-runs for an exact commit sha (fail-closed).
#
# Usage:
#   required-checks.sh --repo owner/name --sha <40-hex>
#
# Prints one JSON object to stdout:
#   {sha, checks:[{name,status,conclusion}], ok:bool}
#
# Exit 0 iff every required check is completed+success and at least one
# required check exists. Exit 1 on empty / pending / failed required checks.
# Exit 2 on bad args or transport/API failure.
#
# Required = every check-run whose conclusion is not skipped/neutral.
# Empty check-runs list ⇒ ok=false (unearned green).
# Does not use `gh pr checks` (can mis-label required vs optional).
set -euo pipefail

export NO_COLOR=1 CLICOLOR_FORCE=0 GH_FORCE_TTY=

usage() {
  printf 'usage: %s --repo owner/name --sha <40-hex>\n' "$(basename "$0")" >&2
  exit 2
}

REPO=""
SHA=""
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

# Paginate may emit one object per page. Slurp + flatten. jq keeps unicode
# (e.g. em-dashes in check names) without ensure_ascii escaping.
OUT="$(printf '%s\n' "$RAW" | jq -sc --arg sha "$SHA" '
  [.[].check_runs[]?] as $runs
  | ($runs | map({
      name: (.name // ""),
      status: (.status // ""),
      conclusion: (if .conclusion == null then "" else (.conclusion | tostring) end)
    })) as $checks
  | ($checks | map(select(
      (.conclusion | ascii_downcase) != "skipped"
      and (.conclusion | ascii_downcase) != "neutral"
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
')"

printf '%s\n' "$OUT"
if [ "$(printf '%s' "$OUT" | jq -r '.ok')" = "true" ]; then
  exit 0
fi
exit 1
