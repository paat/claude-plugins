#!/usr/bin/env bash
# maintain-wip.sh — inventory unmerged WIP the maintain loop must prefer.
# Checkpoint of truth is git/PR (not claims). Selection order:
#   open PR > remote branch with commits > local branch with commits > (none)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage: maintain-wip.sh inventory --repo-root DIR [--worktree PATH] [--default-branch NAME]

Print JSON: { "items": [ {kind, issue, pr_number, branch, updated_at, title} ] }
Sorted: open PRs first (newest first), then remote branches, then local branches.
Only OPEN issues. Skips needs-human / epic labeled issues when gh can read labels.
EOF
}

ACTION=""
ROOT=""
WORKTREE=""
DEFAULT_BRANCH=""

die() { echo "maintain-wip: $1" >&2; exit "${2:-1}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    inventory) ACTION=inventory; shift ;;
    --repo-root) ROOT="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --default-branch) DEFAULT_BRANCH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[ "$ACTION" = inventory ] || { usage; exit 2; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || die "--repo-root must be a directory" 2
ROOT="$(cd "$ROOT" && pwd)"
if [ -z "$WORKTREE" ]; then
  WORKTREE="$ROOT/.worktrees/maintain"
fi
if [ -z "$DEFAULT_BRANCH" ]; then
  if [ -x "$SCRIPT_DIR/default-branch.sh" ]; then
    DEFAULT_BRANCH="$(bash "$SCRIPT_DIR/default-branch.sh" --repo-root "$ROOT" 2>/dev/null || true)"
  fi
  [ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=main
fi

command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"

# Open PRs that close an open issue (WIP closest to merge).
prs_json="$(
  cd "$ROOT" && gh pr list --state open --limit 100 \
    --json number,title,headRefName,updatedAt,body,closingIssuesReferences,isDraft 2>/dev/null \
    || printf '[]\n'
)"

# Open issues eligible for agent work (not needs-human / epic).
issues_json="$(
  cd "$ROOT" && gh issue list --state open --limit 200 \
    --json number,title,labels,updatedAt 2>/dev/null \
    || printf '[]\n'
)"

eligible_issues="$(jq -c '
  [ .[]
    | select((.labels // []) | map(.name) | (index("needs-human") or index("epic")) | not)
    | {number, title, updatedAt}
  ]
' <<<"$issues_json")"

# Map issue -> open PR that closes it (first only per issue).
pr_items="$(jq -c --argjson issues "$eligible_issues" '
  def closes($n):
    ((.closingIssuesReferences // []) | any(.number == $n))
    or ((.body // "") | test("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\s+#" + ($n|tostring) + "\\b"));
  [
    .[] as $pr
    | $issues[]?
    | select($pr | closes(.number))
    | {
        kind: "pr",
        issue: .number,
        pr_number: $pr.number,
        branch: $pr.headRefName,
        updated_at: $pr.updatedAt,
        title: (.title // $pr.title),
        is_draft: ($pr.isDraft // false)
      }
  ]
  | unique_by(.issue)
  | sort_by(.updated_at) | reverse
' <<<"$prs_json")"

# Branches that look like issue work: fix/123-..., improve/123-..., issue-123-...
branch_issue() {
  local b="$1"
  if [[ "$b" =~ ^(fix|improve|feat|feature|chore|docs)/([0-9]+)([-/]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "$b" =~ ^issue-([0-9]+)([-/]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Collect remote and local branches for open eligible issues without a PR item.
issues_with_pr="$(jq -r '[.[].issue] | unique | .[]' <<<"$pr_items" 2>/dev/null || true)"
has_pr_issue() {
  local n="$1" i
  for i in $issues_with_pr; do
    [ "$i" = "$n" ] && return 0
  done
  return 1
}

is_eligible_issue() {
  local n="$1"
  jq -e --argjson n "$n" 'any(.[]; .number == $n)' <<<"$eligible_issues" >/dev/null 2>&1
}

remote_items='[]'
local_items='[]'

# Remote heads (origin)
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  branch="${ref#refs/heads/}"
  issue="$(branch_issue "$branch" || true)"
  [ -n "$issue" ] || continue
  has_pr_issue "$issue" && continue
  is_eligible_issue "$issue" || continue
  # tip date via for-each-ref
  updated="$(git -C "$ROOT" log -1 --format=%cI "refs/remotes/origin/$branch" 2>/dev/null || true)"
  [ -n "$updated" ] || updated="1970-01-01T00:00:00Z"
  title="$(jq -r --argjson n "$issue" '.[] | select(.number==$n) | .title' <<<"$eligible_issues")"
  remote_items="$(jq -c --argjson n "$issue" --arg branch "$branch" --arg at "$updated" --arg title "$title" '
    . + [{kind:"remote_branch", issue:$n, pr_number:null, branch:$branch, updated_at:$at, title:$title, is_draft:false}]
  ' <<<"$remote_items")"
done < <(git -C "$ROOT" for-each-ref --format='%(refname:strip=2)' refs/remotes/origin 2>/dev/null \
  | sed 's#^origin/##' | grep -v '^HEAD$' || true)

# Local branches (maintain worktree or primary)
branch_repo="$ROOT"
if [ -d "$WORKTREE/.git" ] || [ -f "$WORKTREE/.git" ]; then
  branch_repo="$WORKTREE"
fi
while IFS= read -r branch; do
  [ -n "$branch" ] || continue
  issue="$(branch_issue "$branch" || true)"
  [ -n "$issue" ] || continue
  has_pr_issue "$issue" && continue
  is_eligible_issue "$issue" || continue
  # skip if already listed as remote
  if jq -e --arg b "$branch" 'any(.[]; .kind=="remote_branch" and .branch==$b)' <<<"$remote_items" >/dev/null 2>&1; then
    continue
  fi
  updated="$(git -C "$branch_repo" log -1 --format=%cI "$branch" 2>/dev/null || true)"
  [ -n "$updated" ] || updated="1970-01-01T00:00:00Z"
  # require at least one commit not on default
  if git -C "$branch_repo" merge-base --is-ancestor "$branch" "origin/$DEFAULT_BRANCH" 2>/dev/null; then
    # fully merged into default — not WIP
    continue
  fi
  title="$(jq -r --argjson n "$issue" '.[] | select(.number==$n) | .title' <<<"$eligible_issues")"
  local_items="$(jq -c --argjson n "$issue" --arg branch "$branch" --arg at "$updated" --arg title "$title" '
    . + [{kind:"local_branch", issue:$n, pr_number:null, branch:$branch, updated_at:$at, title:$title, is_draft:false}]
  ' <<<"$local_items")"
done < <(git -C "$branch_repo" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null || true)

# Prefer: pr (already sorted) > remote (newest) > local (newest)
remote_sorted="$(jq -c 'sort_by(.updated_at) | reverse' <<<"$remote_items")"
local_sorted="$(jq -c 'sort_by(.updated_at) | reverse' <<<"$local_items")"

jq -n --argjson prs "$pr_items" --argjson remote "$remote_sorted" --argjson local "$local_sorted" \
  --arg worktree "$WORKTREE" --arg default_branch "$DEFAULT_BRANCH" '
  {
    worktree: $worktree,
    default_branch: $default_branch,
    items: ($prs + $remote + $local)
  }
'
