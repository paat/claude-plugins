#!/usr/bin/env bash
# maintain-human-gate.sh — supervisor-only park gate for /maintain triage.
#
# Before applying needs-human, the supervisor MUST call evaluate. Epics (label
# only) are never parked as needs-human. An ACL-checked human override
# (label maintain:human-cleared, or a standalone comment line
# maintain:human-cleared from OWNER/MEMBER/COLLABORATOR, ignoring bot park
# comments) suppresses non-credential parks and can request removal of a stale
# needs-human label.
#
# Issue text is never trusted. Prefer --reason-kind over free-text inference.
# Pass untrusted triage prose via --reason-file (one line) to avoid shell
# metacharacter breakage in caller templates.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: maintain-human-gate.sh evaluate
  --verdict agent-fixable|partially-fixable|needs-human
  --reason TEXT | --reason-file PATH
  [--reason-kind epic|credentials|judgment|other]
  [--labels-file PATH]          # JSON array of label name strings
  [--comments-file PATH]        # JSON array of comment objects (offline)
  [--repo OWNER/REPO --issue N] # live fetch when fixtures omitted
  [--has-needs-human true|false]
EOF
  exit 2
}

die() { printf 'maintain-human-gate: %s\n' "$1" >&2; exit "${2:-1}"; }

action=${1:-}; [ "$action" = evaluate ] || usage; shift

verdict=""; reason=""; reason_file=""; reason_kind=""
labels_file=""; comments_file=""
repo=""; issue=""; has_needs_human="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --verdict) [ "$#" -ge 2 ] || usage; verdict=$2; shift 2 ;;
    --reason) [ "$#" -ge 2 ] || usage; reason=$2; shift 2 ;;
    --reason-file) [ "$#" -ge 2 ] || usage; reason_file=$2; shift 2 ;;
    --reason-kind) [ "$#" -ge 2 ] || usage; reason_kind=$2; shift 2 ;;
    --labels-file) [ "$#" -ge 2 ] || usage; labels_file=$2; shift 2 ;;
    --comments-file) [ "$#" -ge 2 ] || usage; comments_file=$2; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || usage; repo=$2; shift 2 ;;
    --issue) [ "$#" -ge 2 ] || usage; issue=$2; shift 2 ;;
    --has-needs-human) [ "$#" -ge 2 ] || usage; has_needs_human=$2; shift 2 ;;
    *) usage ;;
  esac
done

case "$verdict" in
  agent-fixable|partially-fixable|needs-human) : ;;
  *) die "invalid --verdict" 2 ;;
esac

if [ -n "$reason_file" ]; then
  [ -z "$reason" ] || die "use only one of --reason or --reason-file" 2
  [ -f "$reason_file" ] && [ ! -L "$reason_file" ] || die "unsafe --reason-file"
  # Single line, strip CR; empty file is invalid.
  reason=$(head -n 1 -- "$reason_file" | tr -d '\r')
fi
[ -n "$reason" ] || die "--reason or --reason-file is required" 2
# Bound free-text for digest safety (not shell-evaled).
reason=${reason:0:500}

case "$reason_kind" in
  ''|epic|credentials|judgment|other) : ;;
  *) die "invalid --reason-kind" 2 ;;
esac
case "$has_needs_human" in true|false) : ;; *) die "--has-needs-human must be true|false" 2 ;; esac

if [ -n "$repo" ] || [ -n "$issue" ]; then
  case "$issue" in *[!0-9]*|0*|'') die "invalid --issue" 2 ;; esac
  [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || die "invalid --repo" 2
fi

labels_json='[]'
if [ -n "$labels_file" ]; then
  [ -f "$labels_file" ] && [ ! -L "$labels_file" ] || die "unsafe --labels-file"
  labels_json=$(jq -ce 'if type=="array" and all(.[]; type=="string") then . else empty end' \
    "$labels_file") || die "labels-file must be a JSON string array"
elif [ -n "$repo" ] && [ -n "$issue" ]; then
  command -v gh >/dev/null 2>&1 || die "gh is required for live fetch" 2
  labels_json=$(gh api "repos/$repo/issues/$issue" \
    --jq '[.labels[].name]') || die "failed to fetch issue labels"
elif [ "$verdict" = needs-human ]; then
  die "needs-human evaluate requires --labels-file or --repo/--issue" 2
fi

if jq -e 'index("needs-human") != null' <<<"$labels_json" >/dev/null 2>&1; then
  has_needs_human=true
fi

# Epic exclusion is label-driven (queue already uses .excluded.epic). Optional
# --reason-kind=epic covers triage that classified without the label yet.
is_epic=false
if jq -e 'index("epic") != null' <<<"$labels_json" >/dev/null 2>&1; then
  is_epic=true
fi
if [ "$reason_kind" = epic ]; then
  is_epic=true
fi

# Credentials only via explicit kind — free-text keywords are too noisy.
is_credential=false
if [ "$reason_kind" = credentials ]; then
  is_credential=true
fi

has_clear_label=false
if jq -e 'index("maintain:human-cleared") != null' <<<"$labels_json" >/dev/null 2>&1; then
  has_clear_label=true
fi

# Live comments only when an override could still change the outcome.
need_comments=false
if [ "$verdict" = needs-human ] && [ "$is_epic" = false ] \
  && [ "$has_clear_label" = false ] && [ "$is_credential" = false ]; then
  need_comments=true
fi

comments_json='[]'
if [ -n "$comments_file" ]; then
  [ -f "$comments_file" ] && [ ! -L "$comments_file" ] || die "unsafe --comments-file"
  comments_json=$(jq -ce 'if type=="array" then . else empty end' "$comments_file") \
    || die "comments-file must be a JSON array"
elif [ "$need_comments" = true ] && [ -n "$repo" ] && [ -n "$issue" ]; then
  command -v gh >/dev/null 2>&1 || die "gh is required for live fetch" 2
  # Flatten paginated arrays into one list.
  comments_json=$(gh api --paginate "repos/$repo/issues/$issue/comments" \
    --jq '[.[] | {body, author_association, user: {login: .user.login}}]' \
    | jq -s 'add // []') || die "failed to fetch issue comments"
fi

override_by=""
override_via=""
if [ "$has_clear_label" = true ]; then
  override_via=label
  override_by="label:maintain:human-cleared"
fi

if [ -z "$override_via" ] && { [ "$need_comments" = true ] || [ -n "$comments_file" ]; }; then
  # Exact unindented marker line only (not fenced, not indented code).
  # Skip bot park comments. Require OWNER|MEMBER|COLLABORATOR.
  hit=$(jq -c '
    def assoc_ok:
      . as $a
      | ($a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR");
    def is_bot_comment:
      ((.body // "") | test("<!--[[:space:]]*maintain:bot:"));
    def has_clear_line:
      ((.body // "")
        | split("\n")
        | map(gsub("\r$"; ""))
        | . as $lines
        | reduce range(0; ($lines|length)) as $i (
            {in_fence:false, hit:false};
            if ($lines[$i] | test("^[[:space:]]*```")) then
              .in_fence |= not
            elif (.in_fence | not)
              and ($lines[$i] | test("^maintain:human-cleared[[:space:]]*$")) then
              .hit = true
            else . end
          )
        | .hit);
    [.[]
      | select((.body // "") | type == "string")
      | select(is_bot_comment | not)
      | select(has_clear_line)
      | select((.author_association // "") | assoc_ok)
      | {
          login: ((.user.login // .author.login // "unknown") | tostring),
          association: (.author_association // "")
        }
    ] | .[0] // empty
  ' <<<"$comments_json" 2>/dev/null || true)
  if [ -n "$hit" ]; then
    override_via=comment
    override_by=$(jq -r '.login' <<<"$hit")
  fi
fi

emit() {
  local park=$1 act=$2 remove=$3 digest=$4
  jq -cn \
    --argjson park "$park" \
    --arg action "$act" \
    --argjson remove_needs_human "$remove" \
    --arg override_by "${override_by:-}" \
    --arg override_via "${override_via:-}" \
    --arg digest "$digest" \
    --argjson is_epic "$is_epic" \
    --argjson is_credential "$is_credential" \
    '{
      park: $park,
      action: $action,
      remove_needs_human: $remove_needs_human,
      override_by: (if $override_by == "" then null else $override_by end),
      override_via: (if $override_via == "" then null else $override_via end),
      digest: $digest,
      is_epic: $is_epic,
      is_credential: $is_credential
    }'
}

if [ "$verdict" != needs-human ]; then
  # Residual parks after partially-fixable must re-invoke with --verdict needs-human.
  emit false no-op false "no-op:$verdict"
  exit 0
fi

if [ "$is_epic" = true ]; then
  remove=false
  [ "$has_needs_human" = true ] && remove=true
  emit false exclude-epic "$remove" "excluded:epic"
  exit 0
fi

if [ -n "$override_via" ] && [ "$is_credential" = false ]; then
  remove=false
  [ "$has_needs_human" = true ] && remove=true
  digest="verdict-overridden-by:${override_by}"
  emit false override-cleared "$remove" "$digest"
  exit 0
fi

if [ -n "$override_via" ] && [ "$is_credential" = true ]; then
  emit true park false "needs-human:credential-override-ignored"
  exit 0
fi

# Digest uses a stable prefix; free-text reason is not shell-evaluated.
digest_reason=$(printf '%s' "$reason" | tr '\n\r\t' '   ' | cut -c1-200)
emit true park false "needs-human:${digest_reason}"
exit 0
