#!/bin/bash
# check-regression-test.sh — PreToolUse hook for Bash events.
#
# Hard gate: block `gh pr merge` for an incident-linked PR unless the PR diff
# adds/touches a test, OR an explicit override marker is present.
#
# "Incident-linked" = the PR closes a GitHub issue carrying an incident label
# (default: bug, monitor, customer-issue), OR the PR body carries a
# `Plane-Item:` marker (partial Plane coverage — see the plugin's Plane notes).
#
# Override: put `Regression-Test: none — <reason>` in the PR body (or the
# merge command). The reason is surfaced in the allow message — auditable.
#
# LIMITATION: this verifies a test is PRESENT in the diff, not that it COVERS
# the specific bug. Coverage intent is carried by the tech-founder Bug Fix
# Protocol and the issue Definition-of-Done checklist.
#
# Input:  JSON on stdin with tool_input.command
# Exit 0: not a `gh pr merge`, not incident-linked, test present, override
#         present, or any gh/parse error (FAIL-OPEN — never hard-block on
#         flaky infra; a warning is emitted on stderr instead).
# Exit 2: incident-linked merge with no test and no override (blocked).

set -uo pipefail

input=$(timeout 5 cat 2>/dev/null || echo '{}')
command=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$command" ] && exit 0

# Only act on `gh pr merge`.
echo "$command" | grep -Eq '\bgh\s+pr\s+merge\b' || exit 0

warn() { echo "{\"systemMessage\":\"regression-test gate: $1 — failing open (allowing merge).\"}" >&2; }

# --- Config (optional) --------------------------------------------------------
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
config="${GIT_ROOT:-.}/.claude/saas-startup-team.local.md"
incident_labels="bug,monitor,customer-issue"
# Extended-regex matching test paths from `gh pr diff --name-only`.
test_path_regex='(\.test\.|\.spec\.|(^|/)test_[^/]*\.py$|_test\.go$|(^|/)tests?/|(^|/)__tests__/|(^|/)spec/)'
if [ -f "$config" ]; then
  # strip surrounding quotes only — keep internal spaces (labels can contain them)
  v=$(grep -oP '^\s*incident_labels:\s*\K.*' "$config" 2>/dev/null | sed -E 's/^["'"'"']//; s/["'"'"']$//' || true)
  [ -n "$v" ] && incident_labels="$v"
  v=$(grep -oP '^\s*test_path_regex:\s*\K.*' "$config" 2>/dev/null | sed -E 's/^["'"'"']//; s/["'"'"']$//' || true)
  [ -n "$v" ] && test_path_regex="$v"
fi

# --- Parse the PR argument (number / url / branch; may be empty) --------------
# First non-flag token after `merge`. Empty => gh uses the current branch.
pr_arg=$(echo "$command" \
  | sed -E 's/.*\bgh\s+pr\s+merge\b//' \
  | tr -d '"'"'"'' \
  | awk '{for(i=1;i<=NF;i++){if($i !~ /^-/){print $i; exit}}}' \
  | sed -E 's/^#//')

# positional PR ref first, then flags (gh's documented order)
gh_pr() { if [ -n "$pr_arg" ]; then gh pr "$1" "$pr_arg" "${@:2}"; else gh pr "$@"; fi; }

# --- Gather PR data (fail-open on any error) ----------------------------------
pr_json=$(gh_pr view --json closingIssuesReferences,body 2>/dev/null) || { warn "could not read PR via gh"; exit 0; }
pr_body=$(echo "$pr_json" | jq -r '.body // ""' 2>/dev/null || echo "")
closing=$(echo "$pr_json" | jq -r '.closingIssuesReferences[].number' 2>/dev/null || true)

# --- Override check -----------------------------------------------------------
override_re='Regression-Test[[:space:]]*:[[:space:]]*none[[:space:]]*[—-]'
if echo "$pr_body" | grep -Eqi "$override_re" || echo "$command" | grep -Eqi "$override_re"; then
  # [^"] keeps the reason from breaking the JSON systemMessage string below
  reason=$( { echo "$pr_body"; echo "$command"; } | grep -Eio "${override_re}[^\"]*" | head -1)
  echo "{\"systemMessage\":\"regression-test gate: override accepted (${reason:-no reason given}). Logged.\"}" >&2
  exit 0
fi

# --- Is this PR incident-linked? ----------------------------------------------
incident_linked=0
# (a) closes an incident-labeled GitHub issue
if [ -n "$closing" ]; then
  IFS=',' read -ra LBLSET <<< "$incident_labels"
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    labels=$(gh issue view "$n" --json labels --jq '.labels[].name' 2>/dev/null) || { warn "could not read labels for #$n"; exit 0; }
    for want in "${LBLSET[@]}"; do
      want=$(printf '%s' "$want" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')  # trim ", " spacing
      [ -z "$want" ] && continue
      if echo "$labels" | grep -qixF "$want"; then incident_linked=1; break; fi
    done
    [ "$incident_linked" -eq 1 ] && break
  done <<< "$closing"
fi
# (b) PR body references a Plane work item
if [ "$incident_linked" -eq 0 ] && echo "$pr_body" | grep -Eqi 'Plane-Item:[[:space:]]*\S'; then
  incident_linked=1
fi

[ "$incident_linked" -eq 0 ] && exit 0

# --- Does the diff include a test? --------------------------------------------
files=$(gh_pr diff --name-only 2>/dev/null) || { warn "could not read PR diff"; exit 0; }
if echo "$files" | grep -Eq "$test_path_regex"; then
  exit 0
fi

# --- Block ---------------------------------------------------------------------
cat >&2 <<MSG
{"systemMessage":"REGRESSION-TEST GATE: this PR resolves an incident/issue but its diff adds no test (no path matched the test-path pattern). Before merging, add a regression test that reproduces the incident (fails pre-fix, passes post-fix) and reference its path in the PR body. If the fix is genuinely untestable, record an override in the PR body: 'Regression-Test: none — <reason>'."}
MSG
exit 2
