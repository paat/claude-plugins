#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage: maintain-queue.sh [--repo OWNER/REPO] [--issue N] [--label LABEL]
                         [--default-branch NAME]
                         [--blocked-file PATH]...
                         [--resume-candidate-file PATH]
                         [--dependency-status-file PATH]
                         [--issues-file PATH --open-prs-file PATH]

Build the /maintain and /maintain-loop eligible issue queue from GitHub issue
metadata. Fixture mode uses --issues-file and --open-prs-file.
EOF
}

repo=""
issue=""
label=""
blocked_files=()
issues_file=""
open_prs_file=""
dependency_status_file=""
resume_candidate_file=""
default_branch="${MAINTAIN_QUEUE_DEFAULT_BRANCH:-}"
default_branch_explicit=0
[ -n "${MAINTAIN_QUEUE_DEFAULT_BRANCH:-}" ] && default_branch_explicit=1
dep_clause_re='(?i)\b(?:depends on|blocked by)\b\s*\*{0,2}\s*:?\s*\*{0,2}\s*(?<refs>(?:[-*]\s*)?#[0-9]+(?:(?:[ \t]*(?:(?:,\s*)?and\s+|,\s*)|\s*\n\s*[-*]\s*)#[0-9]+)*)'
dep_ref_re='#(?<n>[0-9]+)'
fixture_mode=0
list_limit=1000

valid_repo_slug() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

resolve_repo_slug() {
  local root origin slug
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  origin=$(git -C "$root" config --local --get remote.origin.url) || return 1
  case "$origin" in
    https://github.com/*) slug=${origin#https://github.com/} ;;
    git@github.com:*) slug=${origin#git@github.com:} ;;
    ssh://git@github.com/*) slug=${origin#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  slug=${slug%/}; slug=${slug%.git}
  valid_repo_slug "$slug" || return 1
  printf '%s\n' "$slug"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      repo="$2"; shift 2 ;;
    --issue)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      issue="$2"; shift 2 ;;
    --label)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      label="$2"; shift 2 ;;
    --default-branch)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      default_branch="$2"; default_branch_explicit=1; shift 2 ;;
    --blocked-file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      blocked_files+=("$2"); shift 2 ;;
    --issues-file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      issues_file="$2"; shift 2 ;;
    --open-prs-file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      open_prs_file="$2"; shift 2 ;;
    --dependency-status-file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      dependency_status_file="$2"; shift 2 ;;
    --resume-candidate-file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      resume_candidate_file="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "maintain-queue: unknown argument: $1" >&2
      usage
      exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "maintain-queue: jq is required" >&2; exit 2; }
if [ -n "$repo" ] && ! valid_repo_slug "$repo"; then
  echo "maintain-queue: --repo must be OWNER/REPO" >&2
  exit 2
fi
case "$issue" in
  "") ;;
  *[!0-9]*|0*) echo "maintain-queue: --issue must be a positive integer without leading zeros" >&2; exit 2 ;;
esac
if [ "$default_branch_explicit" -eq 1 ] \
  && ! git check-ref-format --branch "$default_branch" >/dev/null 2>&1; then
  echo "maintain-queue: default branch is invalid: $default_branch" >&2
  exit 2
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

issues_json="$tmpdir/issues.json"
open_prs_json="$tmpdir/open-prs.json"
blocked_json="$tmpdir/blocked.json"
dep_status_json="$tmpdir/dependency-status.json"
output_json="$tmpdir/output.json"
resume_candidate_json="$tmpdir/resume-candidate.json"

if [ -n "$resume_candidate_file" ]; then
  [ -f "$resume_candidate_file" ] && [ ! -L "$resume_candidate_file" ] || {
    echo "maintain-queue: resume candidate is missing or unsafe" >&2
    exit 3
  }
  if ! jq -e 'select(
    type == "object"
    and ((.number | type) == "number")
    and (.number > 0) and (.number == (.number | floor))
    and ((.updatedAt | type) == "string") and (.updatedAt | length > 0)
    and (.updatedAt | test("[[:cntrl:]]") | not)
    and ((.pr_number | type) == "number")
    and (.pr_number > 0) and (.pr_number == (.pr_number | floor))
  )' "$resume_candidate_file" > "$resume_candidate_json"; then
    echo "maintain-queue: resume candidate is malformed" >&2
    exit 3
  fi
  candidate_issue=$(jq -r .number "$resume_candidate_json")
  if [ -n "$issue" ] && [ "$issue" != "$candidate_issue" ]; then
    echo "maintain-queue: --issue does not match resume candidate" >&2
    exit 2
  fi
  issue="$candidate_issue"
fi

gh_with_repo() {
  [ -n "$repo" ] || return 2
  /usr/bin/env -u GH_REPO -u GH_HOST -u GH_CONFIG_DIR gh "$@" --repo "github.com/$repo"
}

if [ -n "$issues_file" ] || [ -n "$open_prs_file" ]; then
  fixture_mode=1
  [ -n "$issues_file" ] && [ -n "$open_prs_file" ] || {
    echo "maintain-queue: fixture mode requires both --issues-file and --open-prs-file" >&2
    exit 2
  }
  jq -e 'if type == "array" then . else error("issues fixture must be an array") end' \
    "$issues_file" > "$issues_json"
  jq -e 'if type == "array" then . else error("open PR fixture must be an array") end' \
    "$open_prs_file" > "$open_prs_json"
  if [ -n "$issue" ]; then
    jq --argjson issue "$issue" 'map(select(.number == $issue))' \
      "$issues_json" > "$issues_json.filtered"
    mv "$issues_json.filtered" "$issues_json"
    if [ "$(jq length "$issues_json")" -eq 0 ]; then
      echo "maintain-queue: issue #$issue was not found in fixture" >&2
      exit 3
    fi
    if [ "$(jq -r '.[0].state // "OPEN"' "$issues_json")" != "OPEN" ]; then
      echo "maintain-queue: issue #$issue is not open" >&2
      exit 3
    fi
  fi
else
  command -v gh >/dev/null 2>&1 || { echo "maintain-queue: gh is required" >&2; exit 2; }
  if [ -z "$repo" ]; then
    repo=$(resolve_repo_slug) || {
      echo "maintain-queue: could not bind GitHub queries to remote.origin; pass --repo OWNER/REPO" >&2
      exit 3
    }
  fi
  if [ -n "$issue" ]; then
    gh_with_repo issue view "$issue" \
      --json number,title,body,labels,assignees,state,createdAt,updatedAt,closedByPullRequestsReferences |
      jq '[.]' > "$issues_json"
    if [ "$(jq -r '.[0].state // "OPEN"' "$issues_json")" != "OPEN" ]; then
      echo "maintain-queue: issue #$issue is not open" >&2
      exit 3
    fi
  else
    gh_with_repo issue list --state open --limit "$list_limit" \
      --json number,title,body,labels,assignees,createdAt,updatedAt,closedByPullRequestsReferences \
      > "$issues_json"
  fi
  gh_with_repo pr list --state open --limit "$list_limit" \
    --json number,title,body,closingIssuesReferences > "$open_prs_json"
  if [ "$default_branch_explicit" -eq 0 ]; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
    default_args=(--repo-root "$repo_root"); [ -z "$repo" ] || default_args+=(--repo "$repo")
    if ! default_branch=$(/usr/bin/env -u GH_REPO -u GITHUB_REPOSITORY -u GH_HOST -u GH_CONFIG_DIR \
      bash "$SCRIPT_DIR/default-branch.sh" "${default_args[@]}"); then
      echo "maintain-queue: could not resolve repository default branch; pass --default-branch or set MAINTAIN_QUEUE_DEFAULT_BRANCH" >&2
      exit 3
    fi
  fi
  if [ -z "$issue" ] && [ "$(jq length "$issues_json")" -ge "$list_limit" ]; then
    echo "maintain-queue: fetched $list_limit open issues; refusing possibly truncated queue" >&2
    exit 3
  fi
  if [ "$(jq length "$open_prs_json")" -ge "$list_limit" ]; then
    echo "maintain-queue: fetched $list_limit open PRs; refusing possibly truncated linked-PR set" >&2
    exit 3
  fi
fi

if [ -n "$resume_candidate_file" ]; then
  if ! jq -e --argjson number "$issue" '
    type == "array" and length == 1
    and (.[0].number == $number)
    and (.[0].state == "OPEN")
    and ((.[0].updatedAt | type) == "string") and (.[0].updatedAt | length > 0)
    and ((.[0].labels | type) == "array")
    and all(.[0].labels[];
      (type == "string") or (type == "object" and ((.name | type) == "string")))
    and ((.[0].assignees | type) == "array")
    and all(.[0].assignees[];
      type == "object" and ((.login | type) == "string") and (.login | length > 0))
    and ((.[0].closedByPullRequestsReferences | type) == "array")
    and all(.[0].closedByPullRequestsReferences[];
      ((.number | type) == "number") and (.number > 0)
      and (.number == (.number | floor)))
  ' "$issues_json" >/dev/null; then
    echo "maintain-queue: live resume issue data is malformed" >&2
    exit 3
  fi
  if ! jq -e '
    type == "array"
    and ((map(.number) | unique | length) == length)
    and all(.[];
      ((.number | type) == "number") and (.number > 0)
      and (.number == (.number | floor))
      and (((.body // "") | type) == "string")
      and ((.closingIssuesReferences | type) == "array")
      and all(.closingIssuesReferences[];
        ((.number | type) == "number") and (.number > 0)
        and (.number == (.number | floor))))
  ' "$open_prs_json" >/dev/null; then
    echo "maintain-queue: live resume PR data is malformed" >&2
    exit 3
  fi
fi

blocked_args=()
for blocked_file in "${blocked_files[@]}"; do
  [ -e "$blocked_file" ] || [ -L "$blocked_file" ] || continue
  blocked_args+=(--file "$blocked_file")
done
blocked_err="$tmpdir/blocked.err"
if ! bash "$SCRIPT_DIR/maintain-blocked.sh" normalize "${blocked_args[@]}" \
  > "$blocked_json" 2>"$blocked_err"; then
  if [ "${#blocked_files[@]}" -gt 0 ]; then
    echo "maintain-queue: invalid blocked file: ${blocked_files[*]}" >&2
  else
    echo "maintain-queue: blocked ledger normalization failed" >&2
  fi
  sed 's/^/maintain-queue: /' "$blocked_err" >&2
  exit 3
fi

if [ -n "$dependency_status_file" ]; then
  jq -e 'if type == "array" then . else error("dependency status fixture must be an array") end' \
    "$dependency_status_file" > "$dep_status_json"
elif [ "$fixture_mode" -eq 0 ]; then
  open_numbers="$(jq -r '[.[] | select((.state // "OPEN") == "OPEN") | .number] | unique[]' "$issues_json")"
  dep_numbers="$(jq -r \
    --arg dep_clause_re "$dep_clause_re" \
    --arg dep_ref_re "$dep_ref_re" '
    [ .[]
      | ((.title // "") + "\n" + (.body // "")
        | match($dep_clause_re; "g")
        | .captures[0].string
        | match($dep_ref_re; "g")
        | .captures[0].string
        | tonumber)
    ] | unique[]' "$issues_json")"
  dep_status_jsonl="$tmpdir/dependency-status.jsonl"
  : > "$dep_status_jsonl"
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if printf '%s\n' "$open_numbers" | grep -qx "$dep"; then
      continue
    fi
    if dep_status="$(gh_with_repo issue view "$dep" \
      --json number,state,closedByPullRequestsReferences 2>/dev/null)"; then
      pr_refs_json="$tmpdir/dependency-$dep-prs.jsonl"
      : > "$pr_refs_json"
      while IFS= read -r pr; do
        [ -n "$pr" ] || continue
        if ! gh_with_repo pr view "$pr" --json number,state,mergedAt,baseRefName \
          >> "$pr_refs_json" 2>/dev/null; then
          echo "maintain-queue: warning: could not inspect closing PR #$pr for dependency #$dep" >&2
        fi
        printf '\n' >> "$pr_refs_json"
      done <<EOF
$(printf '%s\n' "$dep_status" | jq -r '.closedByPullRequestsReferences[]?.number')
EOF
      jq -c --slurpfile prs "$pr_refs_json" \
        '.closedByPullRequestsReferences = ($prs | map(select(type == "object")))' \
        <<<"$dep_status" >> "$dep_status_jsonl"
    else
      jq -nc --argjson number "$dep" \
        '{number: $number, state: "UNKNOWN", closedByPullRequestsReferences: []}' \
        >> "$dep_status_jsonl"
    fi
  done <<EOF
$dep_numbers
EOF
  jq -s '[.[] | select(type == "object")]' "$dep_status_jsonl" > "$dep_status_json"
else
  printf '[]\n' > "$dep_status_json"
fi

now="${MAINTAIN_QUEUE_NOW:-$(date -u +%FT%TZ)}"

jq -n \
  --slurpfile issues "$issues_json" \
  --slurpfile prs "$open_prs_json" \
  --slurpfile blocked "$blocked_json" \
  --slurpfile dep_status "$dep_status_json" \
  --arg label "$label" \
  --arg issue "$issue" \
  --arg default_branch "$default_branch" \
  --arg dep_clause_re "$dep_clause_re" \
  --arg dep_ref_re "$dep_ref_re" \
  --arg now "$now" '
  def label_names:
    (.labels // [] | map(if type == "object" then (.name // "") else tostring end));

  def assignee_names:
    (.assignees // [] | map(if type == "object" then (.login // "") else tostring end));

  def depnums:
    [((.title // "") + "\n" + (.body // "")
      | match($dep_clause_re; "g")
      | .captures[0].string
      | match($dep_ref_re; "g")
      | .captures[0].string
      | tonumber)] | unique;

  def severity_rank($labels):
    if ($labels | index("critical")) then 0
    elif ($labels | index("high")) then 1
    elif ($labels | index("medium")) then 2
    elif ($labels | index("low")) then 3
    else 4 end;

  def severity_name($rank):
    ["critical", "high", "medium", "low", "none"][$rank];

  def pr_closes($pr; $n):
    (($pr.closingIssuesReferences // []) | any(.number == $n))
    or (($pr.body // "")
      | test("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\s+#" + ($n | tostring) + "\\b"));

  def linked_prs($issue; $prs; $open_pr_numbers):
    ([
      ($issue.closedByPullRequestsReferences // [])[]?.number as $prn
      | select($open_pr_numbers | index($prn))
      | $prn
    ] + [
      $prs[]? | select(pr_closes(.; $issue.number)) | .number
    ]) | unique;

  def base_excluded:
    (.label_match | not)
    or .needs_human
    or .assigned
    or .epic
    or .cooldown;

  def resumable_pr:
    (base_excluded | not)
    and .maintain_claimed
    and ((.linked_prs | length) == 1);

  def dep_satisfied($dep; $statuses):
    ($statuses | map(select(.number == $dep)) | first) as $status
    | if $status == null then false
      else (($status.state // "") == "CLOSED"
        and any($status.closedByPullRequestsReferences[]?;
          ((.mergedAt // "") != "") and ((.baseRefName // "") == $default_branch)))
      end;

  def numbers($items):
    [$items[]? | if type == "object" then .number else . end] | unique | sort;

  ($issues[0] // []) as $raw_issues
  | ($prs[0] // []) as $open_prs
  | ($blocked[0] // []) as $blocked_rows
  | ($dep_status[0] // []) as $dependency_statuses
  | ($open_prs | map(.number)) as $open_pr_numbers
  | ($blocked_rows
      | map(select(((.cooldown_until // "") > $now) and (.number != null)) | .number)
      | unique) as $cooldown_numbers
  | [
      $raw_issues[]?
      | select(.number != null)
      | select((.state // "OPEN") == "OPEN")
      | label_names as $labels
      | assignee_names as $assignees
      | severity_rank($labels) as $rank
      | {
          number,
          title: (.title // ""),
          createdAt: (.createdAt // ""),
          updatedAt: (.updatedAt // ""),
          labels: $labels,
          assignees: $assignees,
          deps: depnums,
          severity_rank: $rank,
          severity: severity_name($rank),
          label_match: ($issue != "" or $label == "" or (($labels | index($label)) != null)),
          needs_human: (($labels | index("needs-human")) != null),
          assigned: (($assignees | length) > 0),
          maintain_claimed: (($labels | index("maintain:claimed")) != null),
          maintain_blocked: (($labels | index("maintain:blocked")) != null),
          epic: (($labels | index("epic")) != null),
          cooldown: (.number as $n | (($cooldown_numbers | index($n)) != null)),
          linked_prs: linked_prs(.; $open_prs; $open_pr_numbers)
        }
    ] as $records
  | ($records | map(.number)) as $open_numbers
  | [
      $records[]
      | . + {
          blocked_deps: ([
            .deps[]? as $dep
            | select(($open_numbers | index($dep)) or (dep_satisfied($dep; $dependency_statuses) | not))
            | $dep
          ] | unique)
        }
    ] as $with_deps
  | ($with_deps
      | map(select((base_excluded | not)
          and ((.linked_prs | length) == 0)
          and ((.blocked_deps | length) == 0)))
      | sort_by(.severity_rank, .createdAt, .number)) as $queue
  | ($with_deps
      | map(select(resumable_pr and ((.blocked_deps | length) == 0)))
      | sort_by(.severity_rank, .createdAt, .number)) as $resumable
  | {
      label_filter: numbers($with_deps | map(select(.label_match | not))),
      needs_human: numbers($with_deps | map(select(.needs_human))),
      assigned: numbers($with_deps | map(select(.assigned))),
      maintain_blocked: numbers($with_deps | map(select(.maintain_blocked and .cooldown))),
      epic: numbers($with_deps | map(select(.epic))),
      cooldown: numbers($with_deps | map(select(.cooldown))),
      linked_pr: numbers($with_deps
        | map(select(((.linked_prs | length) > 0) and (resumable_pr | not)))),
      dependency_wait: [
        $with_deps[]
        | select((base_excluded | not)
            and (((.linked_prs | length) == 0) or resumable_pr)
            and ((.blocked_deps | length) > 0))
        | {number, deps: .blocked_deps}
      ]
    } as $excluded
  | (
      numbers($queue)
      + numbers($resumable)
      + $excluded.label_filter
      + $excluded.needs_human
      + $excluded.assigned
      + $excluded.maintain_blocked
      + $excluded.epic
      + $excluded.cooldown
      + $excluded.linked_pr
      + numbers($excluded.dependency_wait)
      | unique
    ) as $accounted
  | ($open_numbers - $accounted) as $unaccounted
  | {
      raw_open_count: ($with_deps | length),
      eligible_count: (($queue | length) + ($resumable | length)),
      cleanup: {
        stale_maintain_blocked: numbers($with_deps
          | map(select(.maintain_blocked and (.cooldown | not))))
      },
      queue: [
        $queue[]
        | {
            number,
            title,
            severity,
            createdAt,
            updatedAt,
            assignees,
            deps,
            linked_prs
          }
      ],
      resumable: [
        $resumable[]
        | {
            number,
            title,
            severity,
            createdAt,
            updatedAt,
            assignees,
            deps,
            pr_number: .linked_prs[0]
          }
      ],
      excluded: $excluded,
      unaccounted: $unaccounted
    }
' > "$output_json"

unaccounted_count="$(jq -r '.unaccounted | length' "$output_json")"

if [ "$unaccounted_count" -gt 0 ]; then
  echo "maintain-queue: some open issues were not queued, excluded, or blocked" >&2
  jq -c '{raw_open_count, excluded, unaccounted}' "$output_json" >&2
  exit 3
fi

if [ -n "$resume_candidate_file" ]; then
  if ! jq -e --slurpfile expected "$resume_candidate_json" '
    ($expected[0]) as $candidate
    | select((.resumable | length) == 1
      and .resumable[0].number == $candidate.number
      and .resumable[0].updatedAt == $candidate.updatedAt
      and .resumable[0].pr_number == $candidate.pr_number)
    | .resumable[0]
  ' "$output_json" > "$tmpdir/matched-resume.json"; then
    echo "maintain-queue: resume candidate drifted or is no longer eligible" >&2
    jq -c '{resumable, excluded}' "$output_json" >&2
    exit 3
  fi
  cat "$tmpdir/matched-resume.json"
  exit 0
fi

jq '.' "$output_json"
