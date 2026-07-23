#!/usr/bin/env bash
# maintain-wip.sh — inventory git WIP the maintain loop MUST handle before greenfield.
#
# WIP is not only open PRs. It includes:
#   - open PRs
#   - remote/local branches with commits not on the default branch
#   - uncommitted (dirty) work on the primary checkout
#
# Policy (action field):
#   resume  — open issue / dirty work / open PR → continue fixing toward auto-merge
#   delete  — issue closed (or clearly post-merge leftover) → delete branch, no new work
#   inspect — no issue number / ambiguous → human or short audit then delete or resume
#
# Selection order: dirty primary > pr > remote_branch > local_branch
# Never start a new greenfield issue while any resume/delete WIP remains unhandled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage: maintain-wip.sh inventory --repo-root DIR [--default-branch NAME]

Print JSON:
  {
    "worktree": "<primary>",
    "default_branch": "main",
    "dirty": { "clean": bool, "porcelain": "...", "action": "resume"|"none" },
    "items": [ {
        kind, action, issue, issue_state, pr_number, branch, ahead, behind,
        updated_at, title, reason
    } ],
    "summary": { "resume": N, "delete": N, "inspect": N, "dirty": bool }
  }
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
    --default-branch) DEFAULT_BRANCH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[ "$ACTION" = inventory ] || { usage; exit 2; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || die "--repo-root must be a directory" 2
# SSOT: physical primary absolute path only (never symlink alias like /workspace).
if [ -x "$SCRIPT_DIR/maintain-leases.sh" ]; then
  ROOT="$(bash "$SCRIPT_DIR/maintain-leases.sh" primary-root --repo-root "$ROOT")" \
    || die "cannot resolve primary checkout" 2
  bash "$SCRIPT_DIR/maintain-leases.sh" assert-primary-only --repo-root "$ROOT" >/dev/null \
    || die "primary-only gate failed (no linked worktrees)" 2
else
  ROOT="$(cd "$ROOT" && pwd -P)"
fi
WORKTREE="$ROOT"
if [ -z "$DEFAULT_BRANCH" ]; then
  if [ -x "$SCRIPT_DIR/default-branch.sh" ]; then
    DEFAULT_BRANCH="$(bash "$SCRIPT_DIR/default-branch.sh" --repo-root "$ROOT" 2>/dev/null || true)"
  fi
  [ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=main
fi

command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"

DEFAULT_REF="origin/$DEFAULT_BRANCH"
if ! git -C "$ROOT" rev-parse --verify "$DEFAULT_REF" >/dev/null 2>&1; then
  DEFAULT_REF="$DEFAULT_BRANCH"
fi

# --- dirty primary checkout (highest priority WIP) ---
dirty_clean=true
dirty_porcelain=""
if [ -d "$WORKTREE" ] && [ -d "$WORKTREE/.git" ]; then
  dirty_porcelain="$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
  [ -z "$dirty_porcelain" ] || dirty_clean=false
fi
dirty_action=none
[ "$dirty_clean" = true ] || dirty_action=resume

# --- issues (all open + recently closed for delete classification) ---
open_issues_json="$(
  cd "$ROOT" && gh issue list --state open --limit 300 \
    --json number,title,labels,updatedAt,state 2>/dev/null || printf '[]\n'
)"
# Closed issues referenced by local branch names (fetch per branch later if needed)
issue_index="$(jq -c '
  [ .[] | {
      number,
      title: (.title // ""),
      state: (.state // "OPEN"),
      updatedAt: (.updatedAt // ""),
      needs_human: ((.labels // []) | map(.name) | (index("needs-human") != null)),
      epic: ((.labels // []) | map(.name) | (index("epic") != null))
    }
  ]
' <<<"$open_issues_json")"

# --- open PRs ---
prs_json="$(
  cd "$ROOT" && gh pr list --state open --limit 100 \
    --json number,title,headRefName,updatedAt,body,closingIssuesReferences,isDraft 2>/dev/null \
    || printf '[]\n'
)"

pr_items="$(jq -c --argjson issues "$issue_index" '
  def closes($n):
    ((.closingIssuesReferences // []) | any(.number == $n))
    or ((.body // "") | test("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\s+#" + ($n|tostring) + "\\b"))
    or ((.title // "") | test("#" + ($n|tostring)));
  [
    .[] as $pr
    | (
        ([ $issues[]? | select($pr | closes(.number)) ] | first)
        // {number: null, title: $pr.title, state: "OPEN", needs_human: false, epic: false}
      ) as $iss
    | {
        kind: "pr",
        action: (if ($iss.needs_human == true or $iss.epic == true) then "inspect" else "resume" end),
        issue: $iss.number,
        issue_state: ($iss.state // "OPEN"),
        pr_number: $pr.number,
        branch: $pr.headRefName,
        ahead: null,
        behind: null,
        updated_at: $pr.updatedAt,
        title: ($iss.title // $pr.title),
        reason: "open_pr",
        is_draft: ($pr.isDraft // false)
      }
  ]
  | sort_by(.updated_at) | reverse
' <<<"$prs_json")"

branch_issue() {
  local b="$1"
  # fix/123-slug, improve/123-..., ops/123-...
  if [[ "$b" =~ ^(fix|improve|feat|feature|chore|docs|ops)/([0-9]+)([-/]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "$b" =~ ^issue-([0-9]+)([-/]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  # slug ending in -529 / _1192 (common after topic prefix)
  if [[ "$b" =~ [-_/]([0-9]{2,})([-/]?)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Cache closed-issue lookups: issue -> state|title
declare -A ISSUE_STATE=()
declare -A ISSUE_TITLE=()
declare -A ISSUE_HUMAN=()
declare -A ISSUE_EPIC=()

while IFS=$'\t' read -r num state title nh epic; do
  [ -n "$num" ] || continue
  ISSUE_STATE[$num]="$state"
  ISSUE_TITLE[$num]="$title"
  ISSUE_HUMAN[$num]="$nh"
  ISSUE_EPIC[$num]="$epic"
done < <(jq -r '.[] | [.number, .state, .title, (.needs_human|tostring), (.epic|tostring)] | @tsv' <<<"$issue_index")

lookup_issue() {
  local n="$1" json state title labels nh epic
  if [ -n "${ISSUE_STATE[$n]+x}" ]; then
    return 0
  fi
  json="$(cd "$ROOT" && gh issue view "$n" --json number,state,title,labels 2>/dev/null || true)"
  if [ -z "$json" ]; then
    ISSUE_STATE[$n]="UNKNOWN"
    ISSUE_TITLE[$n]=""
    ISSUE_HUMAN[$n]=false
    ISSUE_EPIC[$n]=false
    return 0
  fi
  state="$(jq -r .state <<<"$json")"
  title="$(jq -r .title <<<"$json")"
  nh="$(jq -r '([.labels[].name] | index("needs-human") != null)' <<<"$json")"
  epic="$(jq -r '([.labels[].name] | index("epic") != null)' <<<"$json")"
  ISSUE_STATE[$n]="$state"
  ISSUE_TITLE[$n]="$title"
  ISSUE_HUMAN[$n]="$nh"
  ISSUE_EPIC[$n]="$epic"
}

classify_branch_action() {
  # sets: out_action out_reason out_title out_istate
  local issue="$1" ahead="$2"
  out_title=""
  out_istate="UNKNOWN"
  if [ -z "$issue" ]; then
    out_action=inspect
    out_reason=no_issue_number
    return 0
  fi
  lookup_issue "$issue"
  out_istate="${ISSUE_STATE[$issue]}"
  out_title="${ISSUE_TITLE[$issue]}"
  if [ "$out_istate" = CLOSED ]; then
    # Post-merge leftover (including squash: tip not ancestor of main but issue done).
    out_action=delete
    out_reason=issue_closed_stale_branch
    return 0
  fi
  if [ "${ISSUE_HUMAN[$issue]}" = true ] || [ "${ISSUE_EPIC[$issue]}" = true ]; then
    out_action=inspect
    out_reason=issue_needs_human_or_epic
    return 0
  fi
  if [ "$out_istate" = OPEN ]; then
    out_action=resume
    out_reason=open_issue_unmerged_commits
    return 0
  fi
  out_action=inspect
  out_reason=issue_state_unknown
}

branches_seen='[]'
add_branch_item() {
  local kind="$1" branch="$2" repo="$3" ref="$4"
  local issue ahead behind updated out_action out_reason out_title out_istate
  issue="$(branch_issue "$branch" || true)"
  ahead="$(git -C "$repo" rev-list --count "$DEFAULT_REF..$ref" 2>/dev/null || echo 0)"
  behind="$(git -C "$repo" rev-list --count "$ref..$DEFAULT_REF" 2>/dev/null || echo 0)"
  # No unique commits vs default → not WIP (already fully contained).
  if [ "${ahead:-0}" -eq 0 ]; then
    return 0
  fi
  # De-dupe by branch name
  if jq -e --arg b "$branch" 'index($b) != null' <<<"$branches_seen" >/dev/null 2>&1; then
    return 0
  fi
  branches_seen="$(jq -c --arg b "$branch" '. + [$b]' <<<"$branches_seen")"
  updated="$(git -C "$repo" log -1 --format=%cI "$ref" 2>/dev/null || true)"
  [ -n "$updated" ] || updated="1970-01-01T00:00:00Z"
  classify_branch_action "$issue" "$ahead"
  # Skip open-PR branches already listed as pr kind
  if jq -e --arg b "$branch" 'any(.[]; .kind=="pr" and .branch==$b)' <<<"$pr_items" >/dev/null 2>&1; then
    return 0
  fi
  local issue_arg=null
  [ -n "$issue" ] && issue_arg="$issue"
  items_json="$(jq -c \
    --arg kind "$kind" --arg action "$out_action" --arg reason "$out_reason" \
    --arg branch "$branch" --arg at "$updated" --arg title "$out_title" \
    --arg istate "$out_istate" --argjson ahead "$ahead" --argjson behind "$behind" \
    --argjson issue "$issue_arg" '
    . + [{
      kind: $kind,
      action: $action,
      issue: $issue,
      issue_state: $istate,
      pr_number: null,
      branch: $branch,
      ahead: $ahead,
      behind: $behind,
      updated_at: $at,
      title: $title,
      reason: $reason,
      is_draft: false
    }]
  ' <<<"$items_json")"
}

items_json='[]'

# Remote branches with unmerged commits
while IFS= read -r short; do
  [ -n "$short" ] || continue
  [ "$short" = "HEAD" ] && continue
  [ "$short" = "$DEFAULT_BRANCH" ] && continue
  add_branch_item remote_branch "$short" "$ROOT" "refs/remotes/origin/$short"
done < <(git -C "$ROOT" for-each-ref --format='%(refname:strip=3)' refs/remotes/origin 2>/dev/null || true)

# Local branches (primary common store — same as worktree shared refs)
while IFS= read -r short; do
  [ -n "$short" ] || continue
  [ "$short" = "$DEFAULT_BRANCH" ] && continue
  add_branch_item local_branch "$short" "$ROOT" "refs/heads/$short"
done < <(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null || true)

# Sort: resume first (by updated), then inspect, then delete; within action by updated desc
# Prefer remote over local when same branch already handled by de-dupe.

sorted_items="$(jq -c --argjson prs "$pr_items" '
  def rank:
    if .action == "resume" then 0
    elif .action == "inspect" then 1
    else 2 end;
  # Newest first within each action band; resume before inspect before delete.
  ($prs + .)
  | sort_by(.updated_at) | reverse
  | sort_by(rank)
' <<<"$items_json")"

jq -n \
  --arg worktree "$WORKTREE" \
  --arg default_branch "$DEFAULT_BRANCH" \
  --argjson dirty_clean "$([ "$dirty_clean" = true ] && echo true || echo false)" \
  --arg dirty_porcelain "$dirty_porcelain" \
  --arg dirty_action "$dirty_action" \
  --argjson items "$sorted_items" '
  def counts:
    {
      resume: ([.[] | select(.action=="resume")] | length),
      delete: ([.[] | select(.action=="delete")] | length),
      inspect: ([.[] | select(.action=="inspect")] | length)
    };
  {
    worktree: $worktree,
    default_branch: $default_branch,
    dirty: {
      clean: $dirty_clean,
      porcelain: $dirty_porcelain,
      action: $dirty_action
    },
    items: $items,
    summary: (($items | counts) + {dirty: ($dirty_clean | not)})
  }
'
