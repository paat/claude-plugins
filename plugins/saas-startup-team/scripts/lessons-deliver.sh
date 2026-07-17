#!/usr/bin/env bash
#
# lessons-deliver.sh — deterministic surface of the autonomous lesson implementer
# (self-improvement loop, component #6). The Claude playbook commands/lessons-deliver.md
# orchestrates; this script owns every script-testable, fail-closed decision:
# eligibility selection, repo-pin validation, GitHub-native claim/block/needs-human/ship,
# the mechanical diff firewall, dual version bump, startup reconciliation, gh-error class.
# See docs/design/lessons-deliver.md.
#
# Convention (matches lesson-review.sh): the LABEL change is authoritative and
# fail-closed (any gh issue edit failure -> exit 1, nothing mutated); the explanatory
# COMMENT is best-effort annotation (|| true). set -uo pipefail (no -e) with explicit
# checks, per the sibling scripts.
#
# Usage:
#   lessons-deliver.sh --list [--json] [--repo OWNER/REPO] [--limit N]
#   lessons-deliver.sh --claim N        [--repo OWNER/REPO] [--run-id ID]
#   lessons-deliver.sh --block N --reason TEXT        [--repo OWNER/REPO]
#   lessons-deliver.sh --needs-human N --reason TEXT  [--repo OWNER/REPO]
#   lessons-deliver.sh --ship  N --pr URL             [--repo OWNER/REPO]
#   lessons-deliver.sh --reconcile [--repo OWNER/REPO]
#   lessons-deliver.sh --firewall DIFF_FILE
#   lessons-deliver.sh --bump-version LEVEL           (patch|minor|major)
#   lessons-deliver.sh --classify-gh-error "MESSAGE"

set -uo pipefail

ACTION=""; NUM=""; REPO=""; JSON=0; LIMIT="${SAAS_LESSON_LIST_LIMIT:-50}"
REASON=""; PR=""; RUNID=""; DIFF=""; LEVEL=""; ERRMSG=""

_need_val() { [ "$1" -ge 2 ] || { echo "lessons-deliver: $2 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --list)         ACTION="list"; shift ;;
    --claim)        _need_val "$#" "$1"; ACTION="claim"; NUM="$2"; shift 2 ;;
    --block)        _need_val "$#" "$1"; ACTION="block"; NUM="$2"; shift 2 ;;
    --needs-human)  _need_val "$#" "$1"; ACTION="needs-human"; NUM="$2"; shift 2 ;;
    --ship)         _need_val "$#" "$1"; ACTION="ship";  NUM="$2"; shift 2 ;;
    --reconcile)    ACTION="reconcile"; shift ;;
    --firewall)     _need_val "$#" "$1"; ACTION="firewall"; DIFF="$2"; shift 2 ;;
    --bump-version) _need_val "$#" "$1"; ACTION="bump"; LEVEL="$2"; shift 2 ;;
    --classify-gh-error) _need_val "$#" "$1"; ACTION="classify"; ERRMSG="$2"; shift 2 ;;
    --reason)       _need_val "$#" "$1"; REASON="$2"; shift 2 ;;
    --pr)           _need_val "$#" "$1"; PR="$2"; shift 2 ;;
    --run-id)       _need_val "$#" "$1"; RUNID="$2"; shift 2 ;;
    --repo)         _need_val "$#" "$1"; REPO="$2"; shift 2 ;;
    --limit)        _need_val "$#" "$1"; LIMIT="$2"; shift 2 ;;
    --json)         JSON=1; shift ;;
    *) echo "lessons-deliver: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ACTION" ] || ACTION="list"

APPROVED_LABEL="lesson-approved"
CLAIMED_LABEL="lessons:claimed"
BLOCKED_LABEL="lessons:blocked"
HUMAN_LABEL="lessons:needs-human"
SHIPPED_LABEL="lesson-shipped"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lesson-review-binding.sh
. "$SCRIPT_DIR/lesson-review-binding.sh" || {
  echo "lessons-deliver: review binding helper is unavailable" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 \
  && command -v lesson_review_binding_present >/dev/null 2>&1 || {
    echo "lessons-deliver: review binding prerequisites are unavailable" >&2
    exit 1
  }

# --- repo pin validation (required for all gh-touching actions) --------------
_require_repo() {
  [ -n "$REPO" ] || REPO="${SAAS_PLUGIN_REPO:-}"
  if [ -z "$REPO" ]; then
    echo "lessons-deliver: no repo pinned (--repo OWNER/REPO or \$SAAS_PLUGIN_REPO). Refusing." >&2
    exit 2
  fi
  if ! printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "lessons-deliver: --repo must be OWNER/REPO (got: $REPO)" >&2; exit 2
  fi
}

# Fetch an issue's state + labels + linked-PR refs, or fail closed. Require a string
# state AND a list closedByPullRequestsReferences, so a malformed field can't make
# _has_linked_pr fail open ("no linked PR" -> delivered twice).
_issue_view() {
  local out
  out="$(gh issue view "$1" --repo "$REPO" --json state,labels,closedByPullRequestsReferences 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e 'type=="object" and (.state|type=="string") and ((.closedByPullRequestsReferences//[])|type=="array")' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}
_approved_issue_view() {
  local out
  out="$(gh issue view "$1" --repo "$REPO" \
    --json state,labels,closedByPullRequestsReferences,title,body,comments 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e '
    type == "object" and (.state | type == "string") and (.labels | type == "array")
    and ((.closedByPullRequestsReferences // []) | type == "array")
    and (.title | type == "string") and (.body | type == "string")
    and (.comments | type == "array")
    and all(.comments[];
      (.body | type == "string")
      and ((.author // {}) | type == "object")
      and ((.author.login // null) | type == "string")
      and ((.authorAssociation // "") | type == "string"))
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}
_has_label()     { printf '%s' "$1" | jq -e --arg l "$2" '(.labels // []) | any(.name == $l)' >/dev/null 2>&1; }
_is_open()       { [ "$(printf '%s' "$1" | jq -r '.state // "" | ascii_downcase')" = "open" ]; }
_has_linked_pr() { [ "$(printf '%s' "$1" | jq '(.closedByPullRequestsReferences // []) | length')" -gt 0 ]; }

case "$ACTION" in

  # --- list: read-only view of the deliverable queue --------------------------
  list)
    _require_repo
    case "$LIMIT" in ''|*[!0-9]*) echo "lessons-deliver: --limit must be a positive integer" >&2; exit 2 ;; esac
    [ "$LIMIT" -ge 1 ] || { echo "lessons-deliver: --limit must be >= 1" >&2; exit 2; }
    out="$(gh issue list --repo "$REPO" --label "$APPROVED_LABEL" --state open --limit "$LIMIT" \
            --json number,title,body,labels,url,createdAt,comments,closedByPullRequestsReferences 2>/dev/null)" || {
      echo "lessons-deliver: cannot list lessons from $REPO (gh failed / not authed)." >&2; exit 1; }
    if ! printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1; then
      echo "lessons-deliver: $REPO returned an unparseable issue list. Refusing." >&2; exit 1
    fi
    # Filter: drop blocked / needs-human / claimed / linked-PR. Sort oldest-first.
    # Every jq used for control flow/output is checked — a jq failure must fail closed.
    filtered="$(printf '%s' "$out" | jq -c --arg b "$BLOCKED_LABEL" --arg h "$HUMAN_LABEL" --arg c "$CLAIMED_LABEL" '
      map(select(
        ((.labels // []) | map(.name)) as $l
        | ($l | index($b) | not)
        and ($l | index($h) | not)
        and ($l | index($c) | not)
        and (((.closedByPullRequestsReferences // []) | length) == 0)
      )) | sort_by(.createdAt)')" || {
      echo "lessons-deliver: failed to filter the issue list. Refusing." >&2; exit 1; }
    bound='[]'
    while IFS= read -r item; do
      if lesson_review_binding_present "$item" approve; then
        bound="$(printf '%s' "$bound" | jq -c --argjson item "$item" '. + [$item]')" || {
          echo "lessons-deliver: failed to build bound queue. Refusing." >&2
          exit 1
        }
      else
        item_number="$(printf '%s' "$item" | jq -r '.number // "?"')"
        echo "lessons-deliver: ignoring #$item_number: approval is not bound to current title/body." >&2
      fi
    done < <(printf '%s' "$filtered" | jq -c '.[]')
    filtered="$bound"
    if [ "$JSON" -eq 1 ]; then printf '%s' "$filtered" | jq '.' || { echo "lessons-deliver: bad filtered JSON." >&2; exit 1; }; exit 0; fi
    count="$(printf '%s' "$filtered" | jq 'length')" \
      || { echo "lessons-deliver: cannot count filtered lessons. Refusing." >&2; exit 1; }
    case "$count" in ''|*[!0-9]*) echo "lessons-deliver: non-numeric count. Refusing." >&2; exit 1 ;; esac
    if [ "$count" -eq 0 ]; then echo "No approved lessons ready to deliver in $REPO."; exit 0; fi
    echo "# Approved lessons ready to deliver — $REPO ($count)"; echo
    printf '%s' "$filtered" | jq -r '.[] | "## #\(.number) — \(.title)\n- url: \(.url)\n"'
    exit 0
    ;;

  # --- claim: GitHub-native, refuse on existing claim -------------------------
  claim)
    _require_repo
    case "$NUM" in ''|*[!0-9]*) echo "lessons-deliver: --claim needs a positive integer" >&2; exit 2 ;; esac
    info="$(_approved_issue_view "$NUM")" || { echo "lessons-deliver: cannot inspect exact approved content of #$NUM in $REPO. Refusing." >&2; exit 1; }
    _is_open "$info" || { echo "lessons-deliver: #$NUM is not open. Refusing." >&2; exit 1; }
    _has_linked_pr "$info" && { echo "lessons-deliver: #$NUM already has a linked PR. Refusing." >&2; exit 1; }
    if _has_label "$info" "$BLOCKED_LABEL" || _has_label "$info" "$HUMAN_LABEL"; then
      echo "lessons-deliver: #$NUM is blocked/needs-human. Refusing." >&2; exit 1; fi
    # Already claimed -> refuse (a live claim belongs to another pass; a stale claim is
    # cleared by --reconcile or a human). Never silently no-op over another run's claim.
    if _has_label "$info" "$CLAIMED_LABEL"; then echo "lessons-deliver: #$NUM already claimed. Refusing." >&2; exit 1; fi
    _has_label "$info" "$APPROVED_LABEL" || { echo "lessons-deliver: #$NUM is not $APPROVED_LABEL. Refusing." >&2; exit 1; }
    lesson_review_binding_present "$info" approve || {
      echo "lessons-deliver: #$NUM approval is not bound to its current title/body. Refusing." >&2
      exit 1
    }
    claim_digest="$(lesson_review_digest_json "$info")" || {
      echo "lessons-deliver: #$NUM cannot derive review digest. Refusing." >&2
      exit 1
    }
    gh issue edit "$NUM" --repo "$REPO" --add-label "$CLAIMED_LABEL" >/dev/null 2>&1 \
      || { echo "lessons-deliver: failed to claim #$NUM." >&2; exit 1; }
    # Revalidate after the label transition so concurrent title/body edits cannot
    # keep a claim that no longer matches the approved binding.
    post_claim="$(_approved_issue_view "$NUM")" || {
      echo "lessons-deliver: #$NUM disappeared after claim. Refusing." >&2
      exit 1
    }
    post_digest="$(lesson_review_digest_json "$post_claim")" || {
      echo "lessons-deliver: #$NUM content invalid after claim. Refusing." >&2
      exit 1
    }
    if [ "$post_digest" != "$claim_digest" ] \
       || ! lesson_review_binding_present "$post_claim" approve \
       || ! _has_label "$post_claim" "$APPROVED_LABEL" \
       || ! _has_label "$post_claim" "$CLAIMED_LABEL"; then
      echo "lessons-deliver: #$NUM drifted after claim; binding no longer matches. Refusing." >&2
      exit 1
    fi
    gh issue comment "$NUM" --repo "$REPO" --body "<!-- lessons:claimed:${RUNID:-?} --> claimed by lessons-deliver run ${RUNID:-?}" >/dev/null 2>&1 || true
    echo "lessons-deliver: #$NUM claimed."
    exit 0
    ;;

  # --- block: transient delivery failure, durable via removing approved -------
  block)
    _require_repo
    case "$NUM" in ''|*[!0-9]*) echo "lessons-deliver: --block needs a positive integer" >&2; exit 2 ;; esac
    [ -n "$REASON" ] || { echo "lessons-deliver: --block needs --reason TEXT" >&2; exit 2; }
    info="$(_issue_view "$NUM")" || { echo "lessons-deliver: cannot inspect #$NUM. Refusing." >&2; exit 1; }
    # Drop the claim too — a blocked delivery must not leave a stale lessons:claimed.
    gh issue edit "$NUM" --repo "$REPO" --remove-label "$APPROVED_LABEL" --remove-label "$CLAIMED_LABEL" --add-label "$BLOCKED_LABEL" >/dev/null 2>&1 \
      || { echo "lessons-deliver: failed to block #$NUM." >&2; exit 1; }
    gh issue comment "$NUM" --repo "$REPO" --body "lessons-deliver blocked: $REASON" >/dev/null 2>&1 || true
    echo "lessons-deliver: #$NUM blocked ($REASON)."
    exit 0
    ;;

  # --- needs-human: firewall/safety escalation --------------------------------
  needs-human)
    _require_repo
    case "$NUM" in ''|*[!0-9]*) echo "lessons-deliver: --needs-human needs a positive integer" >&2; exit 2 ;; esac
    [ -n "$REASON" ] || { echo "lessons-deliver: --needs-human needs --reason TEXT" >&2; exit 2; }
    info="$(_issue_view "$NUM")" || { echo "lessons-deliver: cannot inspect #$NUM. Refusing." >&2; exit 1; }
    gh issue edit "$NUM" --repo "$REPO" --remove-label "$APPROVED_LABEL" --remove-label "$CLAIMED_LABEL" --add-label "$HUMAN_LABEL" >/dev/null 2>&1 \
      || { echo "lessons-deliver: failed to escalate #$NUM. Nothing changed." >&2; exit 1; }
    gh issue comment "$NUM" --repo "$REPO" --body "lessons-deliver escalated to needs-human: $REASON" >/dev/null 2>&1 || true
    echo "lessons-deliver: #$NUM escalated to needs-human ($REASON)."
    exit 0
    ;;

  # --- ship: idempotent on the shipped label ----------------------------------
  ship)
    _require_repo
    case "$NUM" in ''|*[!0-9]*) echo "lessons-deliver: --ship needs a positive integer" >&2; exit 2 ;; esac
    [ -n "$PR" ] || { echo "lessons-deliver: --ship needs --pr URL" >&2; exit 2; }
    info="$(_issue_view "$NUM")" || { echo "lessons-deliver: cannot inspect #$NUM. Refusing." >&2; exit 1; }
    if _has_label "$info" "$SHIPPED_LABEL"; then echo "lessons-deliver: #$NUM already shipped (no-op)."; exit 0; fi
    gh issue edit "$NUM" --repo "$REPO" --add-label "$SHIPPED_LABEL" --remove-label "$CLAIMED_LABEL" >/dev/null 2>&1 \
      || { echo "lessons-deliver: failed to mark #$NUM shipped." >&2; exit 1; }
    gh issue comment "$NUM" --repo "$REPO" --body "<!-- lessons:shipped:$NUM --> Shipped in $PR" >/dev/null 2>&1 || true
    echo "lessons-deliver: #$NUM shipped ($PR)."
    exit 0
    ;;

  # --- reconcile: repair shipped state from merged PRs (fail closed) ----------
  reconcile)
    _require_repo
    # --state all: a merged `Closes #N` auto-closes the issue, so a crash between merge and
    # --ship leaves a CLOSED issue still labelled lessons:claimed — an open-only list misses it.
    claimed="$(gh issue list --repo "$REPO" --label "$CLAIMED_LABEL" --state all --limit 100 --json number,labels 2>/dev/null)" || {
      echo "lessons-deliver: reconcile cannot list claimed issues. Refusing (fail closed)." >&2; exit 1; }
    printf '%s' "$claimed" | jq -e 'type=="array"' >/dev/null 2>&1 || {
      echo "lessons-deliver: reconcile got unparseable claimed list. Refusing." >&2; exit 1; }
    # Fail closed: a transient `gh pr list` failure must NOT read as "nothing merged"
    # (that would strand a merged lesson as forever-claimed).
    prs="$(gh pr list --repo "$REPO" --state merged --limit 100 --json number,headRefName,body 2>/dev/null)" || {
      echo "lessons-deliver: reconcile cannot list merged PRs. Refusing (fail closed)." >&2; exit 1; }
    printf '%s' "$prs" | jq -e 'type=="array"' >/dev/null 2>&1 || {
      echo "lessons-deliver: reconcile got unparseable PR list. Refusing." >&2; exit 1; }
    repaired=0; failures=0
    for n in $(printf '%s' "$claimed" | jq -r '.[].number'); do
      merged="$(printf '%s' "$prs" | jq --arg n "$n" 'any(.[]; (.body // "" | test("[Cc]loses #" + $n + "\\b")) or (.headRefName // "" | test("^lesson/" + $n + "-")))')"
      if [ "$merged" = "true" ]; then
        if gh issue edit "$n" --repo "$REPO" --add-label "$SHIPPED_LABEL" --remove-label "$CLAIMED_LABEL" >/dev/null 2>&1; then
          repaired=$((repaired+1))
        else
          failures=$((failures+1)); echo "lessons-deliver: reconcile: failed to repair #$n." >&2
        fi
      fi
    done
    echo "lessons-deliver: reconcile repaired $repaired issue(s)."
    [ "$failures" -eq 0 ] || { echo "lessons-deliver: reconcile had $failures repair failure(s)." >&2; exit 1; }
    exit 0
    ;;

  # --- firewall: mechanical diff guard (fail closed) --------------------------
  firewall)
    [ -f "$DIFF" ] || { echo "lessons-deliver: BLOCKED: diff file not found: $DIFF" >&2; exit 3; }
    # Reject quoted/escaped diff headers (paths with spaces/tabs/unicode) rather than
    # risk mis-parsing them — fail closed.
    if grep -qE '^diff --git "' "$DIFF"; then
      echo "lessons-deliver: BLOCKED: quoted path in diff header (unsupported, fail closed)" >&2; exit 3
    fi
    if ! awk '
      /^diff --git / {
        seen=1
        if ($0 !~ /^diff --git a\/[^[:space:]]+ b\/[^[:space:]]+$/) bad=1
      }
      END { exit(seen && !bad ? 0 : 1) }
    ' "$DIFF"; then
      echo "lessons-deliver: BLOCKED: malformed or whitespace-bearing diff header" >&2; exit 3
    fi
    # Changed paths from BOTH sides of each `diff --git a/<A> b/<B>` header — a rename
    # moves <A> (possibly out-of-tree) to <B>, so both must satisfy the allowlist.
    # Quoted headers were rejected above, so paths contain no spaces -> `[^ ]*` is exact.
    paths="$( { grep -E '^diff --git ' "$DIFF" | sed -E 's#^diff --git a/([^ ]*) b/.*#\1#'; \
                grep -E '^diff --git ' "$DIFF" | sed -E 's#^diff --git a/[^ ]* b/##'; } | sort -u )"
    [ -n "$paths" ] || { echo "lessons-deliver: BLOCKED: no changed paths parsed from diff" >&2; exit 3; }
    if awk '
      function is_test(p) {
        return p ~ /(^|\/)(__tests__|tests?|specs?|e2e)\// \
          || p ~ /(^|[._-])(tests?|spec|e2e)\.[^/]+$/ \
          || p ~ /(^|\/)(test_|spec_)[^/]+$/ \
          || p ~ /(^|\/)[^/]+_(test|spec)\.[^/]+$/
      }
      /^diff --git / {
        src=$3; dst=$4; sub(/^a\//,"",src); sub(/^b\//,"",dst); p=dst
        if (src != dst && is_test(src)) found=1
      }
      /^deleted file mode / && is_test(p) { found=1 }
      END { exit(found ? 0 : 1) }
    ' "$DIFF"; then
      echo "lessons-deliver: BLOCKED: autonomous deletion or removal-by-rename of a test file" >&2; exit 3
    fi
    removed_assertions=$(grep -E '^-[^-]' "$DIFF" \
      | grep -E '(assert[_.(]|expect\(|describe\(|it\(|test\(|def test_|#\[test\])' \
      | wc -l | tr -d ' ')
    added_assertions=$(grep -E '^\+[^+]' "$DIFF" \
      | grep -E '(assert[_.(]|expect\(|describe\(|it\(|test\(|def test_|#\[test\])' \
      | wc -l | tr -d ' ')
    if [ "$removed_assertions" -gt "$added_assertions" ]; then
      echo "lessons-deliver: BLOCKED: autonomous assertion/test-count reduction" >&2; exit 3
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "/$p/" in */../*|*/./*|*//*)
        echo "lessons-deliver: BLOCKED: unsafe path in diff header: $p" >&2; exit 3 ;;
      esac
      case "$p" in /*|*\\*)
        echo "lessons-deliver: BLOCKED: unsafe path in diff header: $p" >&2; exit 3 ;;
      esac
      # Allowlist: anywhere under plugins/ OR the root marketplace manifest.
      case "$p" in
        plugins/*) : ;;
        .claude-plugin/marketplace.json) : ;;
        *) echo "lessons-deliver: BLOCKED: change outside plugins/ tree: $p" >&2; exit 3 ;;
      esac
      # Self-mod guard: the loop's own safety infrastructure (incl. the single test harness).
      case "$p" in
        plugins/saas-startup-team/scripts/lessons-deliver.sh \
        | plugins/saas-startup-team/scripts/lesson-*.sh \
        | plugins/saas-startup-team/scripts/pii-gate.sh \
        | plugins/saas-startup-team/scripts/supervisor-commit.sh \
        | plugins/saas-startup-team/scripts/delivery-mutation-guard.sh \
        | plugins/saas-startup-team/scripts/mutation-auth-token.sh \
        | plugins/saas-startup-team/references/workflows/mutation-ownership.md \
        | plugins/saas-startup-team/tests/run-tests.sh \
        | plugins/saas-startup-team/commands/lessons-*.md)
          echo "lessons-deliver: BLOCKED: self-mod of safety infra: $p" >&2; exit 3 ;;
      esac
      case "$p" in *tribunal*) echo "lessons-deliver: BLOCKED: self-mod of tribunal config: $p" >&2; exit 3 ;; esac
    done <<< "$paths"
    # Secret scan: source pii-gate (sourced, not executed) and block on a hit. Fail
    # closed if the gate cannot be sourced.
    # shellcheck source=/dev/null
    if ! . "$(dirname "$0")/pii-gate.sh" 2>/dev/null; then
      echo "lessons-deliver: BLOCKED: cannot source pii-gate (fail closed)" >&2; exit 3
    fi
    if pii_hit "$(cat "$DIFF")"; then
      echo "lessons-deliver: BLOCKED: secret/PII pattern in diff" >&2; exit 3
    fi
    echo "lessons-deliver: firewall clean ($(printf '%s' "$paths" | grep -c .) path(s))."
    exit 0
    ;;

  # --- bump-version: both manifests, atomic, semver-guarded -------------------
  bump)
    case "$LEVEL" in patch|minor|major) : ;; *) echo "lessons-deliver: --bump-version needs patch|minor|major" >&2; exit 2 ;; esac
    pj="plugins/saas-startup-team/.claude-plugin/plugin.json"
    mp=".claude-plugin/marketplace.json"
    [ -f "$pj" ] && [ -f "$mp" ] || { echo "lessons-deliver: version files not found (run from repo root)" >&2; exit 1; }
    cur="$(jq -r '.version' "$pj" 2>/dev/null)"
    # Strict semver — reject 1.2.3.4, 1..3, .2.3, empty, null.
    printf '%s' "$cur" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
      || { echo "lessons-deliver: current version is not strict semver: '$cur'" >&2; exit 1; }
    # The marketplace entry must exist exactly once before we touch anything.
    n_entries="$(jq '[.plugins[] | select(.name=="saas-startup-team")] | length' "$mp" 2>/dev/null || echo 0)"
    [ "$n_entries" = "1" ] || { echo "lessons-deliver: expected exactly one saas-startup-team marketplace entry, found $n_entries" >&2; exit 1; }
    IFS=. read -r MA MI PA <<< "$cur"
    case "$LEVEL" in
      major) MA=$((MA+1)); MI=0; PA=0 ;;
      minor) MI=$((MI+1)); PA=0 ;;
      patch) PA=$((PA+1)) ;;
    esac
    new="$MA.$MI.$PA"
    # Write BOTH temp files and validate BOTH before moving either — never leave the
    # two manifests out of sync on a partial failure.
    jq --arg v "$new" '.version=$v' "$pj" > "$pj.tmp" 2>/dev/null \
      || { echo "lessons-deliver: failed to rewrite $pj" >&2; rm -f "$pj.tmp"; exit 1; }
    jq --arg v "$new" '(.plugins[] | select(.name=="saas-startup-team") | .version) = $v' "$mp" > "$mp.tmp" 2>/dev/null \
      || { echo "lessons-deliver: failed to rewrite $mp" >&2; rm -f "$pj.tmp" "$mp.tmp"; exit 1; }
    if [ "$(jq -r '.version' "$pj.tmp")" != "$new" ] \
       || [ "$(jq -r '.plugins[] | select(.name=="saas-startup-team") | .version' "$mp.tmp")" != "$new" ]; then
      echo "lessons-deliver: post-write validation failed; not committing bump." >&2; rm -f "$pj.tmp" "$mp.tmp"; exit 1
    fi
    # Checked moves. If the second fails after the first succeeded, roll plugin.json back
    # to $cur so the two manifests never diverge on disk.
    if ! mv -f "$pj.tmp" "$pj"; then
      echo "lessons-deliver: failed to install $pj; bump aborted." >&2; rm -f "$pj.tmp" "$mp.tmp"; exit 1
    fi
    if ! mv -f "$mp.tmp" "$mp"; then
      echo "lessons-deliver: failed to install $mp; rolling $pj back to $cur." >&2
      jq --arg v "$cur" '.version=$v' "$pj" > "$pj.tmp" 2>/dev/null && mv -f "$pj.tmp" "$pj" \
        || echo "lessons-deliver: WARNING: could not roll $pj back; manifests may be out of sync." >&2
      rm -f "$pj.tmp" "$mp.tmp"; exit 1
    fi
    echo "$cur -> $new"
    exit 0
    ;;

  # --- classify-gh-error: retriable vs terminal -------------------------------
  classify)
    lc="$(printf '%s' "$ERRMSG" | tr '[:upper:]' '[:lower:]')"
    # Any HTTP 5xx is transient -> retriable.
    if printf '%s' "$lc" | grep -Eq '\b5[0-9][0-9]\b'; then echo "retriable"; exit 0; fi
    case "$lc" in
      *"rate limit"*|*timeout*|*"timed out"*|*"temporarily unavailable"*|*"connection reset"*|*"network"*|*"try again"*)
        echo "retriable" ;;
      *) echo "terminal" ;;
    esac
    exit 0
    ;;

  *)
    echo "lessons-deliver: unknown action: $ACTION" >&2; exit 2 ;;
esac
