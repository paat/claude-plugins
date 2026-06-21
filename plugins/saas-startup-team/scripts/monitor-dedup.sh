#!/usr/bin/env bash
# monitor-dedup.sh — deterministic engine for /monitor-nightly. Generic/project-agnostic.
#   window --state <file>
#   commit --state <file> [--repo S] [--labels a,b] [--repro-recipe TPL] [--dry-run]
# Owns ALL state I/O and ALL `gh` calls (including repo resolution).
set -euo pipefail

_die() { echo "monitor-dedup: $*" >&2; exit 1; }
_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_iso_to_epoch() { date -u -d "$1" +%s 2>/dev/null; }   # non-fatal: empty on bad input

# Echo a usable state object, or "" if missing/corrupt.
_read_state() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return; }
  if jq -e '.version == 1 and (.patterns|type=="object")' "$f" >/dev/null 2>&1; then
    cat "$f"
  else
    echo ""
  fi
}

REPO=""; DRY_RUN=0; LABELS="monitor,customer-issue"; REPRO_RECIPE=""
declare -A ISSUE_STATE_CACHE

_gh() {
  if [ "$DRY_RUN" = 1 ]; then echo "[DRY RUN] gh $*" >&2; return 0; fi
  gh "$@" --repo "$REPO"
}
_label_color() {
  case "$1" in
    monitor) echo "0E8A16" ;; customer-issue) echo "D93F0B" ;;
    high) echo "B60205" ;; medium) echo "FBCA04" ;; low) echo "0075CA" ;;
    *) echo "ededed" ;;
  esac
}
_ensure_labels() {  # never fatal — a label failure must not stop filing
  local l
  for l in "$@"; do
    [ -n "$l" ] || continue
    _gh label create "$l" --color "$(_label_color "$l")" --description "monitor" --force >/dev/null 2>&1 \
      || echo "monitor-dedup: WARNING could not ensure label '$l'" >&2
  done
}
_new_body() {  # args: body pattern_key entity   (entity "" means none)
  local body="$1" pk="$2" ent="$3"
  printf '%s\n\n**Pattern:** `%s`\n' "$body" "$pk"
  if [ -n "$ent" ]; then
    printf '**Entity:** `%s`\n' "$ent"
    [ -n "$REPRO_RECIPE" ] && printf '\n### Reproduction\n```\n%s\n```\n' "${REPRO_RECIPE//\{entity\}/$ent}"
  fi
  printf '\n*Fixing this requires a regression test (or an explicit `Regression-Test: none — <reason>` override), per the regression-test gate.*\n'
}
# Echo the validated finding as ONE compact JSON line, or empty if malformed.
_validate() {  # arg: raw line
  printf '%s' "$1" | jq -c '
    select(
      (.pattern_key|type=="string") and (.pattern_key|test("^[a-z0-9][a-z0-9:_-]*$")) and
      (.severity|type=="string") and (.title|type=="string") and (.body|type=="string") and
      (has("entity")) and (.entity == null or ((.entity|type=="string") and (.entity|test("[\n`]")|not)))
    )' 2>/dev/null | head -1 || true
}
_write_state() {  # atomic, same-dir temp, inline cleanup (no RETURN trap)
  local f="$1" content="$2" dir tmp
  [ "$DRY_RUN" = 1 ] && return 0
  dir="$(dirname "$f")"; mkdir -p "$dir"
  tmp="$(mktemp "$dir/.monitor-state.XXXXXX")"
  if printf '%s\n' "$content" > "$tmp" && mv "$tmp" "$f"; then :; else rm -f "$tmp"; return 1; fi
}

cmd_window() {
  local state_file="" minutes since now last epoch
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state_file="$2"; shift 2 ;;
      *) _die "window: unknown arg $1" ;;
    esac
  done
  [ -n "$state_file" ] || _die "window: --state required"
  local state; state="$(_read_state "$state_file")"
  last="$(printf '%s' "$state" | jq -r '.last_run_at // empty' 2>/dev/null || true)"
  now="$(date -u +%s)"
  epoch=""
  if [ -n "$last" ] && [ "$last" != "null" ]; then epoch="$(_iso_to_epoch "$last" || true)"; fi
  if [ -z "$epoch" ]; then
    minutes=1440
  else
    minutes=$(( ( now - epoch ) / 60 ))
    [ "$minutes" -lt 1 ] && minutes=1
    [ "$minutes" -gt 2880 ] && minutes=2880
  fi
  since="$(date -u -d "@$(( now - minutes * 60 ))" +%Y-%m-%dT%H:%M:%SZ)"
  echo "MONITOR_SINCE_MINUTES=$minutes"
  echo "MONITOR_SINCE=$since"
}

_issue_open() {  # echo yes/no; gh failure or UNKNOWN → yes (conservative: keep mapping)
  local num="$1" st
  if [ -z "${ISSUE_STATE_CACHE[$num]:-}" ]; then
    st="$(_gh issue view "$num" --json state -q .state 2>/dev/null || echo UNKNOWN)"
    ISSUE_STATE_CACHE[$num]="$st"
  fi
  [ "${ISSUE_STATE_CACHE[$num]}" = "CLOSED" ] && echo no || echo yes
}
# Echo a VERIFIED existing open issue number for (pk,ent), or empty. Checks EVERY
# search hit's body for the embedded markers (not just the first result).
_recover_issue() {  # args: pattern_key entity("" if none)
  local pk="$1" ent="$2" q="${pk//:/ }" json nums n vbody
  [ -n "$ent" ] && q="$q $ent"
  json="$(_gh issue list --state open --search "$q" --json number -q '.' 2>/dev/null || echo '[]')"
  nums="$(printf '%s' "$json" | jq -r 'if type=="array" then .[].number else empty end' 2>/dev/null || true)"
  for n in $nums; do
    vbody="$(_gh issue view "$n" --json body -q .body 2>/dev/null || echo "")"
    printf '%s' "$vbody" | grep -qF "**Pattern:** \`$pk\`" || continue
    if [ -n "$ent" ]; then printf '%s' "$vbody" | grep -qF "**Entity:** \`$ent\`" || continue; fi
    echo "$n"; return
  done
  echo ""
}

cmd_commit() {
  local state_file="" failed=0; local malformed=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --state)        [ $# -ge 2 ] || _die "commit: --state needs a value"; state_file="$2"; shift 2 ;;
      --repo)         [ $# -ge 2 ] || _die "commit: --repo needs a value"; REPO="$2"; shift 2 ;;
      --labels)       [ $# -ge 2 ] || _die "commit: --labels needs a value"; LABELS="$2"; shift 2 ;;
      --repro-recipe) [ $# -ge 2 ] || _die "commit: --repro-recipe needs a value"; REPRO_RECIPE="$2"; shift 2 ;;
      --dry-run)      DRY_RUN=1; shift ;;
      *) _die "commit: unknown arg $1" ;;
    esac
  done
  [ -n "$state_file" ] || _die "commit: --state required"
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    [ -n "$REPO" ] || _die "commit: could not resolve repo (set monitor.repo)"
  fi

  local state; state="$(_read_state "$state_file")"
  [ -n "$state" ] || state='{"version":1,"last_run_at":null,"patterns":{}}'

  local raw f pk sev ent title body summary
  while IFS= read -r raw || [ -n "$raw" ]; do
    [ -z "$raw" ] && continue
    f="$(_validate "$raw")"
    if [ -z "$f" ]; then failed=1; malformed+=("$raw"); echo '{"action":"malformed"}'; continue; fi
    pk="$(printf '%s' "$f"      | jq -r '.pattern_key')"
    sev="$(printf '%s' "$f"     | jq -r '.severity')"
    ent="$(printf '%s' "$f"     | jq -r '.entity // ""')"     # null → ""
    title="$(printf '%s' "$f"   | jq -r '.title')"
    body="$(printf '%s' "$f"    | jq -r '.body')"
    summary="$(printf '%s' "$f" | jq -r '.summary // .title')"

    # === Task 3 inserts: closed-issue reconciliation (drop stale CLOSED mapping) ===

    if printf '%s' "$state" | jq -e --arg k "$pk" '.patterns|has($k)' >/dev/null; then
      local cur_issue; cur_issue="$(printf '%s' "$state" | jq -r --arg k "$pk" '.patterns[$k].gh_issue')"
      if [ "$(_issue_open "$cur_issue")" = no ]; then
        state="$(printf '%s' "$state" | jq --arg k "$pk" 'del(.patterns[$k])')"
      fi
    fi

    if printf '%s' "$state" | jq -e --arg k "$pk" '.patterns|has($k)' >/dev/null; then
      local issue seen
      issue="$(printf '%s' "$state" | jq -r --arg k "$pk" '.patterns[$k].gh_issue')"
      seen="$(printf '%s' "$state" | jq -r --arg k "$pk" --arg e "$ent" '(.patterns[$k].sessions // [])|index($e)|tostring')"
      if [ "$seen" != "null" ]; then
        printf '%s' "$f" | jq -nc --arg pk "$pk" --arg e "$ent" --argjson i "$issue" '{action:"skip",pattern_key:$pk,entity:$e,issue:$i}'
        continue
      fi
      if _gh issue comment "$issue" --body "Recurrence ($(_now_iso)): $summary"; then
        state="$(printf '%s' "$state" | jq --arg k "$pk" --arg e "$ent" --arg ts "$(_now_iso)" '.patterns[$k].sessions += [$e] | .patterns[$k].last_seen=$ts')"
        jq -nc --arg pk "$pk" --arg e "$ent" --argjson i "$issue" '{action:"comment",pattern_key:$pk,entity:$e,issue:$i}'
      else
        failed=1; jq -nc --arg pk "$pk" --arg e "$ent" '{action:"error",pattern_key:$pk,entity:$e,issue:null}'
      fi
      continue
    fi

    # === Task 3 inserts: state-loss recovery search (adopt verified existing issue) ===

    local rec; rec="$(_recover_issue "$pk" "$ent")"
    if [ -n "$rec" ]; then
      if _gh issue comment "$rec" --body "Recurrence ($(_now_iso)): $summary"; then
        state="$(printf '%s' "$state" | jq --arg k "$pk" --argjson n "$rec" --arg e "$ent" --arg ts "$(_now_iso)" '.patterns[$k]={gh_issue:$n,sessions:[$e],first_seen:$ts,last_seen:$ts}')"
        jq -nc --arg pk "$pk" --arg e "$ent" --argjson i "$rec" '{action:"comment",pattern_key:$pk,entity:$e,issue:$i}'
      else
        failed=1; jq -nc --arg pk "$pk" --arg e "$ent" '{action:"error",pattern_key:$pk,entity:$e,issue:null}'
      fi
      continue
    fi

    # --- CREATE ---
    local _lbls; IFS=',' read -ra _lbls <<< "$LABELS"
    _ensure_labels "${_lbls[@]}" "$sev"
    if [ "$DRY_RUN" = 1 ]; then
      _gh issue create --title "$title" --label "$LABELS,$sev" --body "x" >/dev/null 2>&1 || true
      jq -nc --arg pk "$pk" --arg e "$ent" '{action:"create",pattern_key:$pk,entity:$e,issue:null}'
      continue
    fi
    local out num
    if out="$(_gh issue create --title "$title" --label "$LABELS,$sev" --body "$(_new_body "$body" "$pk" "$ent")")"; then
      num="$(printf '%s' "$out" | grep -oE '[0-9]+$' | tail -1)"
      if [ -z "$num" ] || [ "$num" = 0 ]; then
        failed=1; jq -nc --arg pk "$pk" --arg e "$ent" '{action:"error",pattern_key:$pk,entity:$e,issue:null}'; continue
      fi
      state="$(printf '%s' "$state" | jq --arg k "$pk" --argjson n "$num" --arg e "$ent" --arg ts "$(_now_iso)" '.patterns[$k]={gh_issue:$n,sessions:[$e],first_seen:$ts,last_seen:$ts}')"
      jq -nc --arg pk "$pk" --arg e "$ent" --argjson n "$num" '{action:"create",pattern_key:$pk,entity:$e,issue:$n}'
    else
      failed=1; jq -nc --arg pk "$pk" --arg e "$ent" '{action:"error",pattern_key:$pk,entity:$e,issue:null}'
    fi
  done

  # === Task 4 inserts: file one ops:monitor-input:malformed issue if malformed[] non-empty ===

  if [ "${#malformed[@]}" -gt 0 ]; then
    local _mlbls; IFS=',' read -ra _mlbls <<< "$LABELS"
    _ensure_labels "${_mlbls[@]}" high
    local mbody
    mbody="$(printf 'The monitor received %s unparseable / invalid finding line(s):\n\n```\n%s\n```\n' \
      "${#malformed[@]}" "$(printf '%s\n' "${malformed[@]}")")"
    _gh issue create --title "[Monitor] malformed monitor input" --label "$LABELS,high" \
      --body "$(_new_body "$mbody" "ops:monitor-input:malformed" "")" >/dev/null 2>&1 || true
  fi

  if [ "$failed" = 0 ]; then
    state="$(printf '%s' "$state" | jq --arg ts "$(_now_iso)" '.last_run_at=$ts')"
  fi
  _write_state "$state_file" "$state"
  [ "$failed" = 0 ]
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    window) cmd_window "$@" ;;
    commit) cmd_commit "$@" ;;
    *) _die "usage: monitor-dedup.sh {window|commit} ..." ;;
  esac
}
main "$@"
