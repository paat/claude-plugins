#!/bin/bash
# digest.sh — assemble one daily needs-human digest per project (idempotent per day).
# Subcommands:
#   assemble  [--date YYYY-MM-DD] [--root DIR]  → write .startup/digests/<date>.md, print its path
#   mark-sent [--root DIR]                      → advance the run cursor after a successful send
# Sources: new run digests since the cursor (.startup/*/runs/*.md, tracked in
# .startup/digest-state.json), docs/human-tasks.md grouped approvals/credentials/FYI,
# shipped PRs + queued issues scraped from the new runs, and a spend/pass-summary
# section a later budget governor fills. No secrets handled here.

set -euo pipefail

CMD="${1:-}"; shift 2>/dev/null || true
DATE=""; ROOT=""
# A value-taking flag with no following value is a usage error (not a set -e shift abort).
need_val() { [ "$1" -ge 2 ] || { echo "digest: $2 requires a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --date) need_val $# "$1"; DATE="$2"; shift 2 ;;
    --root) need_val $# "$1"; ROOT="$2"; shift 2 ;;
    *) echo "digest: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -n "$DATE" ] || DATE="$(date +%F)"
# DATE names an output file — reject anything but YYYY-MM-DD to block path traversal.
case "$DATE" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) echo "digest: invalid --date '$DATE' (expected YYYY-MM-DD)" >&2; exit 2 ;;
esac

STATE="$ROOT/.startup/digest-state.json"
HUMAN_TASKS="$ROOT/docs/human-tasks.md"

# Cursor keys: run paths (relative to $ROOT) already folded into a prior sent digest.
# ROOT-relative, not basename — two loops can emit the same basename (run-1.md) in
# different .startup/<loop>/runs dirs; keying by basename would collide and drop one.
# Scan is lazy (only assemble / mark-sent mismatch need it) so already-sent stays cheap.
NEWRUNS=()
scan_newruns() {
  local sent=() r f
  if [ -f "$STATE" ]; then
    while IFS= read -r r; do [ -n "$r" ] && sent+=("$r"); done \
      < <(jq -r '.sent_runs[]? // empty' "$STATE" 2>/dev/null || true)
  fi
  NEWRUNS=()
  # Any depth under a runs/ dir — some loops nest per-issue files (runs/<rid>/issue-N.md).
  [ -d "$ROOT/.startup" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local rel="${f#"$ROOT"/}" x hit=0
    for x in "${sent[@]:-}"; do [ "$x" = "$rel" ] && { hit=1; break; }; done
    [ "$hit" -eq 0 ] && NEWRUNS+=("$f")
  done < <(find "$ROOT/.startup" -type f -path '*/runs/*' -name '*.md' | sort)
}

case "$CMD" in
  already-sent)
    # Exit 0 if this date's digest was already sent (idempotent-per-day gate), else 1.
    # No run-file scan — the no-op path must stay cheap.
    last=""; [ -f "$STATE" ] && last="$(jq -r '.last_sent_date // ""' "$STATE" 2>/dev/null || echo '')"
    [ "$last" = "$DATE" ] && exit 0 || exit 1
    ;;
  mark-sent)
    # Fold the pending snapshot into sent_runs, but ONLY if it was assembled for THIS date
    # (pending_date guard) — a cross-date backfill would otherwise mark another date's runs.
    # On mismatch, re-derive from this date's own digest file (its authoritative run list).
    sent_json="[]"; pend_json="[]"; pend_date=""
    if [ -f "$STATE" ]; then
      sent_json="$(jq -c '.sent_runs // []' "$STATE" 2>/dev/null || echo '[]')"
      pend_json="$(jq -c '.pending_runs // []' "$STATE" 2>/dev/null || echo '[]')"
      pend_date="$(jq -r '.pending_date // ""' "$STATE" 2>/dev/null || echo '')"
    fi
    if [ "$pend_date" != "$DATE" ]; then
      dfile="$ROOT/.startup/digests/$DATE.md"; list=""
      [ -f "$dfile" ] && list="$(awk '/^## New run activity/{f=1;next} /^## /{f=0} f && sub(/^- /,"")' "$dfile")"
      pend_json="$(printf '%s\n' "$list" | jq -R . | jq -s 'map(select(length>0))')"
    fi
    mkdir -p "$(dirname "$STATE")"
    jq -n --argjson s "$sent_json" --argjson p "$pend_json" --arg d "$DATE" \
      '{sent_runs: (($s + $p) | unique), pending_runs: [], pending_date: "", last_sent_date: $d}' > "$STATE"
    echo "$STATE"
    exit 0
    ;;
  assemble) scan_newruns ;;
  *) echo "digest: usage: digest.sh {assemble|mark-sent|already-sent} [--date YYYY-MM-DD] [--root DIR]" >&2; exit 2 ;;
esac

OUT="$ROOT/.startup/digests/$DATE.md"
mkdir -p "$(dirname "$OUT")"

# Pending human-tasks grouped by axis (first line classifies; sub-bullets follow).
group() {
  local want="$1"
  [ -f "$HUMAN_TASKS" ] || return 0
  awk -v want="$want" '
    /^## +Pending/ {p=1; next}
    /^## / {if(p) p=0}
    # Skip HTML comment blocks so the template placeholder task is not parsed as live.
    # Own flag (inc) — must NOT reuse the classification var c below.
    /<!--/ {inc=1}
    inc { if($0 ~ /-->/) inc=0; next }
    {
      if(!p) next
      if($0 ~ /^- \[ \]/){
        l=tolower($0); c="fyi"
        if(l ~ /credential|secret|api key|apikey|token|password|\.env|access key/) c="credentials"
        else if(l ~ /approv|budget|legal|sign[- ]?off|signature|pricing|invoice|payment/) c="approvals"
        cur=(c==want); if(cur) print; next
      }
      if($0 ~ /^- /){cur=0; next}
      if(cur && $0 ~ /[^[:space:]]/) print
    }
  ' "$HUMAN_TASKS"
}

scrape() {
  local re="$1" f
  for f in "${NEWRUNS[@]:-}"; do [ -f "$f" ] && grep -hE "$re" "$f" || true; done
}

approvals="$(group approvals || true)"
credentials="$(group credentials || true)"
fyi="$(group fyi || true)"
shipped="$(scrape 'PR #[0-9]+|/pull/[0-9]+' || true)"
queued="$(scrape '[Qq]ueued|issue #[0-9]+' || true)"

section() {
  printf '\n## %s\n\n' "$1"
  if [ -n "$2" ]; then printf '%s\n' "$2"; else printf '_None._\n'; fi
}

{
  printf '# Daily digest — %s\n' "$DATE"
  section "Needs-human — approvals" "$approvals"
  section "Needs-human — credentials (copy-paste instructions included)" "$credentials"
  section "Needs-human — FYI" "$fyi"
  section "Shipped" "$shipped"
  section "Queued" "$queued"
  printf '\n## New run activity\n\n'
  if [ "${#NEWRUNS[@]}" -gt 0 ]; then
    for f in "${NEWRUNS[@]}"; do printf -- '- %s\n' "${f#"$ROOT"/}"; done
  else
    printf '_None._\n'
  fi
  printf '\n## Spend & pass summary\n\n'
  printf '_Populated by the budget governor once wired. No spend/pass data yet._\n'
} > "$OUT"

# Persist the exact ROOT-relative run paths this digest included, tagged with its date, so
# mark-sent folds this snapshot only when marking the SAME date (cross-date backfill safe).
pending_json="$(printf '%s\n' "${NEWRUNS[@]:-}" | while IFS= read -r f; do
  [ -n "$f" ] && printf '%s\n' "${f#"$ROOT"/}"; done | jq -R . | jq -s 'map(select(length>0))')"
sent_json="[]"; last_date='""'
if [ -f "$STATE" ]; then
  sent_json="$(jq -c '.sent_runs // []' "$STATE" 2>/dev/null || echo '[]')"
  last_date="$(jq -c '.last_sent_date // ""' "$STATE" 2>/dev/null || echo '""')"
fi
mkdir -p "$(dirname "$STATE")"
jq -n --argjson s "$sent_json" --argjson p "$pending_json" --arg pd "$DATE" --argjson d "$last_date" \
  '{sent_runs:$s, pending_runs:$p, pending_date:$pd, last_sent_date:$d}' > "$STATE"

echo "$OUT"
