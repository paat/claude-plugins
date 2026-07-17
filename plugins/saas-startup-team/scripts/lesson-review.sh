#!/usr/bin/env bash
#
# lesson-review.sh — deterministic lesson review state transitions (component #4).
#
# `lesson-file.sh` files harvested, de-identified, PII-gated improvements as
# `lesson-candidate` issues in the PINNED plugin repo. This script is the investor's
# review surface over that queue: list pending candidates, then APPROVE (mark ready
# for `/lessons-deliver`), CLOSE (reject), or QUARANTINE (block unresolved) each.
#
# State machine (one gh call per action — no partial-mutation window):
#   pending   = open issue labeled `lesson-candidate`
#   approved  = gh issue edit --add-label lesson-approved --remove-label lesson-candidate
#   blocked   = gh issue edit --add-label lessons:blocked --remove-label
#               lesson-candidate --remove-label lesson-approved
#   rejected  = gh issue close --reason "not planned"   (candidate label stays; an
#               open-state listing hides it; reopening is a deliberate re-queue)
#
# Safety rails (mirroring lesson-file.sh rigor):
#   - A repo must be pinned (--repo or $SAAS_PLUGIN_REPO) and be OWNER/REPO, for every
#     action; otherwise we cannot know which queue we are reviewing -> exit 2.
#   - Mutations act only on a real, positive-integer issue number.
#   - LABEL GUARD: a mutation verifies the issue is actually a lesson issue before
#     touching it (prevents acting on an unrelated issue number). Fail CLOSED if the
#     issue cannot be inspected (not found / permission / network).
#   - These are guarded, explicit, per-issue transitions, so there is NO
#     SAAS_LESSON_SYNC_ENABLED gate (that flag guards AUTOMATED bulk filing). The
#     repo pin + label guard are the rails for human and automated reviewers.
#
# See docs/design/self-improvement-loop.md.
#
# Usage:
#   lesson-review.sh --list [--json] [--repo OWNER/REPO] [--limit N]
#   lesson-review.sh --approve N [--note TEXT] [--repo OWNER/REPO]
#   lesson-review.sh --close   N [--note TEXT] [--repo OWNER/REPO]
#   lesson-review.sh --quarantine N [--note TEXT] [--repo OWNER/REPO]
#   lesson-review.sh --auto-reject N [--note TEXT] [--repo OWNER/REPO]

set -uo pipefail

ACTION=""; NUM=""; NOTE=""; REPO=""; JSON=0; LIMIT="${SAAS_LESSON_LIST_LIMIT:-50}"

# A value-taking flag with no value must error, not loop forever (shift 2 with one
# arg left is a no-op when set -e is off, so the parser would re-read the same flag).
_need_val() { [ "$1" -ge 2 ] || { echo "lesson-review: $2 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --list)    ACTION="list"; shift ;;
    --approve) _need_val "$#" "$1"; ACTION="approve"; NUM="$2"; shift 2 ;;
    --close)   _need_val "$#" "$1"; ACTION="close";   NUM="$2"; shift 2 ;;
    --auto-reject) _need_val "$#" "$1"; ACTION="auto-reject"; NUM="$2"; shift 2 ;;
    --quarantine) _need_val "$#" "$1"; ACTION="quarantine"; NUM="$2"; shift 2 ;;
    --note)    _need_val "$#" "$1"; NOTE="$2"; shift 2 ;;
    --repo)    _need_val "$#" "$1"; REPO="$2"; shift 2 ;;
    --limit)   _need_val "$#" "$1"; LIMIT="$2"; shift 2 ;;
    --json)    JSON=1; shift ;;
    *) echo "lesson-review: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ACTION" ] || ACTION="list"
[ -n "$REPO" ]   || REPO="${SAAS_PLUGIN_REPO:-}"

CANDIDATE_LABEL="lesson-candidate"
APPROVED_LABEL="lesson-approved"
BLOCKED_LABEL="lessons:blocked"

# --- shared validation -------------------------------------------------------
# A pinned, fully-qualified repo is required for every action — public mutations
# must never resolve a surprising default gh context.
if [ -z "$REPO" ]; then
  echo "lesson-review: no repo pinned (--repo OWNER/REPO or \$SAAS_PLUGIN_REPO). Refusing." >&2
  exit 2
fi
case "$REPO" in
  */*) : ;;
  *) echo "lesson-review: --repo must be OWNER/REPO (got: $REPO)" >&2; exit 2 ;;
esac
# exactly one slash, no spaces, non-empty owner+name
if ! printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
  echo "lesson-review: malformed repo pin: $REPO" >&2; exit 2
fi

case "$LIMIT" in ''|*[!0-9]*) echo "lesson-review: --limit must be a positive integer" >&2; exit 2 ;; esac
[ "$LIMIT" -ge 1 ] || { echo "lesson-review: --limit must be >= 1" >&2; exit 2; }

# Fetch an issue's state + labels as JSON, or fail closed. Echoes the JSON on
# success; returns non-zero on any gh failure OR on output that is not a parseable
# issue object (a truncated/garbled response must never read as "no labels"/"closed").
_issue_view() {
  local out
  out="$(gh issue view "$1" --repo "$REPO" --json state,labels 2>/dev/null)" || return 1
  # Require a string `state` (not just present) so a parseable-but-malformed object
  # like {"state":{}} can't slip past and make _is_open fail open on close.
  printf '%s' "$out" | jq -e 'type=="object" and (.state | type=="string")' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

_has_label() { # json label -> 0 if present
  printf '%s' "$1" | jq -e --arg l "$2" '(.labels // []) | any(.name == $l)' >/dev/null 2>&1
}

_is_open() { # json -> 0 if state OPEN
  [ "$(printf '%s' "$1" | jq -r '.state // "" | ascii_downcase')" = "open" ]
}

case "$ACTION" in

  # --- list: read-only view of the pending candidate queue --------------------
  list)
    out="$(gh issue list --repo "$REPO" --label "$CANDIDATE_LABEL" --state open \
             --limit "$LIMIT" --json number,title,labels,url,body 2>/dev/null)" || {
      echo "lesson-review: cannot list candidates from $REPO (gh failed / not authed)." >&2
      exit 1
    }
    # Malformed output must NOT read as an empty queue (that would tell the investor
    # "nothing to review" when the listing actually failed). Fail closed instead.
    if ! printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1; then
      echo "lesson-review: $REPO returned an unparseable issue list. Refusing." >&2
      exit 1
    fi

    if [ "$JSON" -eq 1 ]; then
      printf '%s\n' "$out"
      exit 0
    fi

    count="$(printf '%s' "$out" | jq 'length')"
    if [ "${count:-0}" -eq 0 ]; then
      echo "No lesson candidates awaiting review in $REPO."
      exit 0
    fi
    echo "# Lesson candidates awaiting review — $REPO ($count)"
    echo
    printf '%s' "$out" | jq -r '.[] |
      "## #\(.number) — \(.title)\n- url: \(.url)\n- labels: \((.labels // [] | map(.name) | join(", ")))\n"'
    exit 0
    ;;

  # --- approve: mark ready for /lessons-deliver -------------------------------
  approve)
    case "$NUM" in ''|*[!0-9]*) echo "lesson-review: --approve needs a positive integer issue number" >&2; exit 2 ;; esac
    info="$(_issue_view "$NUM")" || { echo "lesson-review: cannot inspect #$NUM in $REPO (not found / no access / gh failed). Refusing." >&2; exit 1; }

    # Order matters: a closed issue is refused FIRST, so a closed+approved issue is
    # never silently resurrected as a no-op success (reopen it deliberately instead).
    if ! _is_open "$info"; then
      echo "lesson-review: #$NUM is closed; reopen before approving. Refusing." >&2
      exit 1
    fi
    # Blocked is terminal for approval even if labels were manually mixed.
    if _has_label "$info" "$BLOCKED_LABEL"; then
      echo "lesson-review: #$NUM is $BLOCKED_LABEL; resolve and re-queue before approving. Refusing." >&2
      exit 1
    fi
    # Idempotent: an OPEN issue already approved (and no longer a candidate) -> no-op.
    if _has_label "$info" "$APPROVED_LABEL" && ! _has_label "$info" "$CANDIDATE_LABEL"; then
      echo "lesson-review: #$NUM already approved (no-op)."
      exit 0
    fi
    # Label guard: only act on an actual candidate.
    if ! _has_label "$info" "$CANDIDATE_LABEL"; then
      echo "lesson-review: #$NUM is not a $CANDIDATE_LABEL (labels do not match). Refusing." >&2
      exit 1
    fi

    # Single atomic edit: swap candidate -> approved.
    gh issue edit "$NUM" --repo "$REPO" \
      --add-label "$APPROVED_LABEL" --remove-label "$CANDIDATE_LABEL" >/dev/null 2>&1 || {
      echo "lesson-review: failed to relabel #$NUM. Nothing changed." >&2
      exit 1
    }
    # Annotation is best-effort — the relabel above is the authoritative state change.
    if [ -n "$NOTE" ]; then
      gh issue comment "$NUM" --repo "$REPO" --body "$NOTE" >/dev/null 2>&1 \
        || echo "lesson-review: warning: relabel succeeded but note comment failed on #$NUM." >&2
    fi
    echo "lesson-review: #$NUM approved (now $APPROVED_LABEL). Implement with: /lessons-deliver --once"
    exit 0
    ;;

  # --- quarantine: remove unresolved candidates from the active queue --------
  quarantine)
    case "$NUM" in ''|*[!0-9]*) echo "lesson-review: --quarantine needs a positive integer issue number" >&2; exit 2 ;; esac
    info="$(_issue_view "$NUM")" || { echo "lesson-review: cannot inspect #$NUM in $REPO (not found / no access / gh failed). Refusing." >&2; exit 1; }

    if ! _is_open "$info"; then
      echo "lesson-review: #$NUM is closed; only open candidates can be quarantined. Refusing." >&2
      exit 1
    fi
    # Idempotent terminal state: an open blocked issue already outside the queue.
    if _has_label "$info" "$BLOCKED_LABEL" && ! _has_label "$info" "$CANDIDATE_LABEL"; then
      echo "lesson-review: #$NUM already quarantined (no-op)."
      exit 0
    fi
    if ! _has_label "$info" "$CANDIDATE_LABEL"; then
      echo "lesson-review: #$NUM is not a $CANDIDATE_LABEL (labels do not match). Refusing." >&2
      exit 1
    fi

    # One edit is the authoritative state transition; no partial label window.
    gh issue edit "$NUM" --repo "$REPO" \
      --add-label "$BLOCKED_LABEL" \
      --remove-label "$CANDIDATE_LABEL" \
      --remove-label "$APPROVED_LABEL" >/dev/null 2>&1 || {
      echo "lesson-review: failed to quarantine #$NUM. Nothing changed." >&2
      exit 1
    }
    if [ -n "$NOTE" ]; then
      gh issue comment "$NUM" --repo "$REPO" --body "$NOTE" >/dev/null 2>&1 \
        || echo "lesson-review: warning: quarantine succeeded but note comment failed on #$NUM." >&2
    fi
    echo "lesson-review: #$NUM quarantined (now $BLOCKED_LABEL)."
    exit 0
    ;;

  # --- close: reject a candidate ----------------------------------------------
  close|auto-reject)
    case "$NUM" in ''|*[!0-9]*) echo "lesson-review: --$ACTION needs a positive integer issue number" >&2; exit 2 ;; esac
    info="$(_issue_view "$NUM")" || { echo "lesson-review: cannot inspect #$NUM in $REPO (not found / no access / gh failed). Refusing." >&2; exit 1; }

    # Human close remains idempotent. Automated rejection is deliberately a
    # candidate-only compare-and-transition and refuses any changed state.
    if ! _is_open "$info"; then
      if [ "$ACTION" = auto-reject ]; then
        echo "lesson-review: #$NUM changed before automated rejection. Refusing." >&2
        exit 1
      fi
      echo "lesson-review: #$NUM already closed (no-op)."
      exit 0
    fi
    if [ "$ACTION" = auto-reject ]; then
      if _has_label "$info" "$APPROVED_LABEL" || _has_label "$info" "$BLOCKED_LABEL" \
         || ! _has_label "$info" "$CANDIDATE_LABEL"; then
        echo "lesson-review: #$NUM is no longer candidate-only. Refusing automated rejection." >&2
        exit 1
      fi
    fi
    # Is-a-lesson guard: only close issues that are part of this loop.
    if ! _has_label "$info" "$CANDIDATE_LABEL" && ! _has_label "$info" "$APPROVED_LABEL"; then
      echo "lesson-review: #$NUM is not a lesson issue (no $CANDIDATE_LABEL/$APPROVED_LABEL). Refusing." >&2
      exit 1
    fi

    if [ -n "$NOTE" ]; then
      gh issue close "$NUM" --repo "$REPO" --reason "not planned" --comment "$NOTE" >/dev/null 2>&1
    else
      gh issue close "$NUM" --repo "$REPO" --reason "not planned" >/dev/null 2>&1
    fi || { echo "lesson-review: failed to close #$NUM. Nothing changed." >&2; exit 1; }
    echo "lesson-review: #$NUM closed (rejected, not planned)."
    exit 0
    ;;

  *)
    echo "lesson-review: unknown action: $ACTION" >&2; exit 2 ;;
esac
