#!/bin/bash
# memory-gc.sh — conservative garbage collection over project memory (issue #196).
#
# Scans CLAUDE.md '## Learnings' + docs/learnings/*.md and classifies bullets:
#   - Expired one-off grants ('- Grant: ... expires: YYYY-MM-DD' past today) — the ONLY
#     deletion class: moved to docs/learnings/retired.md with a retirement date.
#   - Stale entries (a bullet's absolute date older than --stale-days, default 21) — flag only.
#   - Near-duplicate / contradiction candidates (same Label repeated in one file) — flag only.
#
# Writes a human-reviewable report to .startup/memory-gc/<today>.md ONLY when something is
# retired or flagged; clean memory writes no file and exits 0 (near-zero cost).
# --weekly gates the run on a 7-day cursor in .startup/memory-gc/state.json.
#
# Deps: bash 4+, jq, awk, sed, GNU date. Date override for tests: SAAS_GC_TODAY=YYYY-MM-DD.
set -euo pipefail

ROOT=""
STALE_DAYS=21
WEEKLY=0

need_val() { [ "$#" -ge 2 ] || { echo "memory-gc: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --root) need_val "$@"; ROOT="$2"; shift 2 ;;
    --stale-days) need_val "$@"; STALE_DAYS="$2"; shift 2 ;;
    --weekly) WEEKLY=1; shift ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "memory-gc: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ "$STALE_DAYS" =~ ^[0-9]+$ ]] || { echo "memory-gc: --stale-days must be an integer" >&2; exit 2; }

if [ -z "$ROOT" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
[ -d "$ROOT" ] || { echo "memory-gc: root not a directory: $ROOT" >&2; exit 2; }

TODAY="${SAAS_GC_TODAY:-$(date +%F)}"
CUTOFF=$(date -d "$TODAY - $STALE_DAYS days" +%F)

STATE_DIR="$ROOT/.startup/memory-gc"
STATE="$STATE_DIR/state.json"

# --weekly: skip if the last run was under 7 days ago.
if [ "$WEEKLY" -eq 1 ] && [ -f "$STATE" ]; then
  last=$(jq -r '.last_run // ""' "$STATE" 2>/dev/null || echo "")
  if [ -n "$last" ]; then
    age=$(( ( $(date -d "$TODAY" +%s) - $(date -d "$last" +%s) ) / 86400 ))
    if [ "$age" -lt 7 ]; then
      echo "memory-gc: last run $last (${age}d ago) < 7d; skipping."
      exit 0
    fi
  fi
fi

# Collect in-scope memory files.
files=()
[ -f "$ROOT/CLAUDE.md" ] && files+=("$ROOT/CLAUDE.md")
if [ -d "$ROOT/docs/learnings" ]; then
  for f in "$ROOT"/docs/learnings/*.md; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "retired.md" ] && continue
    files+=("$f")
  done
fi

# Records (rel-path<TAB>lineno<TAB>text), one per classified bullet.
EXPIRED=()
STALE=()
DUP=()

scan_file() {  # $1=path  $2=isclaude(1/0) — emits KIND\tNR\ttext on stdout
  awk -v today="$TODAY" -v cutoff="$CUTOFF" -v isclaude="$2" '
    function inscope() { return (isclaude==0) || inlearn }
    BEGIN { inlearn=0 }
    isclaude==1 && /^## Learnings/ { inlearn=1; next }
    isclaude==1 && /^## /         { inlearn=0 }
    inscope() && /^[[:space:]]*-[[:space:]]/ {
      expired=0
      # Deletion is gated on the exact grant-bullet shape so a durable rule that merely
      # mentions an expiry date is never retired.
      if ($0 ~ /^[[:space:]]*-[[:space:]]*Grant:[[:space:]]/ && match($0, /expires:[[:space:]]*[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        d=substr($0, RSTART, RLENGTH); sub(/expires:[[:space:]]*/, "", d)
        if (d < today) { print "EXPIRED\t" NR "\t" $0; expired=1 }
      }
      lbl=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", lbl)
      sub(/^PROMOTE\?:[[:space:]]*/, "", lbl)
      ci=index(lbl, ":")
      # Grants are lifecycle-managed by expiry, not a contradiction label; expired lines
      # are being removed — neither belongs in the near-duplicate scan.
      if (!expired && ci > 1) {
        key=tolower(substr(lbl, 1, ci-1))
        if (key != "grant") {
          cnt[key]++
          lines[key]=lines[key] NR ","
          text[key SUBSEP NR]=$0
        }
      }
      if (!expired && match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
        dd=substr($0, RSTART, RLENGTH)
        if (dd < cutoff) print "STALE\t" NR "\t" $0
      }
    }
    END {
      for (k in cnt) if (cnt[k] >= 2) {
        n=split(lines[k], a, ",")
        for (i=1; i<=n; i++) if (a[i] != "") print "DUP\t" a[i] "\t" text[k SUBSEP a[i]]
      }
    }
  ' "$1"
}

for f in "${files[@]}"; do
  isclaude=0; [ "$f" = "$ROOT/CLAUDE.md" ] && isclaude=1
  rel="${f#"$ROOT"/}"
  while IFS=$'\t' read -r kind lno text; do
    [ -n "$kind" ] || continue
    case "$kind" in
      EXPIRED) EXPIRED+=("$rel"$'\t'"$lno"$'\t'"$text") ;;
      STALE)   STALE+=("$rel"$'\t'"$lno"$'\t'"$text") ;;
      DUP)     DUP+=("$rel"$'\t'"$lno"$'\t'"$text") ;;
    esac
  done < <(scan_file "$f" "$isclaude")
done

# Retire expired grants: append to retired.md, then delete from source (descending line order).
if [ "${#EXPIRED[@]}" -gt 0 ]; then
  retired="$ROOT/docs/learnings/retired.md"
  mkdir -p "$ROOT/docs/learnings"
  if [ ! -f "$retired" ]; then
    printf '# Retired Learnings\n\nAuto-retired by memory-gc.sh (expired one-off grants). Kept for audit.\n' > "$retired"
  fi
  printf '\n## %s\n' "$TODAY" >> "$retired"
  declare -A todelete=()
  for rec in "${EXPIRED[@]}"; do
    IFS=$'\t' read -r rel lno text <<<"$rec"
    printf -- '%s  (from %s)\n' "$text" "$rel" >> "$retired"
    todelete["$rel"]+="$lno "
  done
  for rel in "${!todelete[@]}"; do
    # Delete highest line numbers first so earlier deletions don't shift targets.
    for lno in $(printf '%s\n' ${todelete[$rel]} | sort -rn); do
      sed -i "${lno}d" "$ROOT/$rel"
    done
  done
fi

# Reported line numbers for flagged items must point at the post-GC file: subtract the
# retired grant lines above them in the same file (deletion shifts everything below up).
declare -A RETIRED_LINES=()
for rec in "${EXPIRED[@]:-}"; do
  [ -n "$rec" ] || continue
  IFS=$'\t' read -r rel lno _ <<<"$rec"; RETIRED_LINES["$rel"]+="$lno "
done
adjust() {  # $1=rel $2=lineno → line number after retired lines above it are removed
  local rel="$1" lno="$2" d out="$2"
  for d in ${RETIRED_LINES[$rel]:-}; do [ "$d" -lt "$lno" ] && out=$((out - 1)); done
  echo "$out"
}

total=$(( ${#EXPIRED[@]} + ${#STALE[@]} + ${#DUP[@]} ))
report=""
if [ "$total" -gt 0 ]; then
  mkdir -p "$STATE_DIR"
  report="$STATE_DIR/$TODAY.md"
  {
    printf '# Memory GC report — %s\n' "$TODAY"
    if [ "${#EXPIRED[@]}" -gt 0 ]; then
      printf '\n## Retired: expired grants — %d\n' "${#EXPIRED[@]}"
      for rec in "${EXPIRED[@]}"; do
        IFS=$'\t' read -r rel lno text <<<"$rec"; printf -- '- %s → retired.md — %s\n' "$rel" "$text"
      done
    fi
    if [ "${#STALE[@]}" -gt 0 ]; then
      printf '\n## Flagged: stale (older than %sd) — %d\n' "$STALE_DAYS" "${#STALE[@]}"
      for rec in "${STALE[@]}"; do
        IFS=$'\t' read -r rel lno text <<<"$rec"; printf -- '- %s:%s — %s\n' "$rel" "$(adjust "$rel" "$lno")" "$text"
      done
    fi
    if [ "${#DUP[@]}" -gt 0 ]; then
      printf '\n## Flagged: contradiction / near-duplicate — %d\n' "${#DUP[@]}"
      for rec in "${DUP[@]}"; do
        IFS=$'\t' read -r rel lno text <<<"$rec"; printf -- '- %s:%s — %s\n' "$rel" "$(adjust "$rel" "$lno")" "$text"
      done
    fi
  } > "$report"
fi

if [ "$WEEKLY" -eq 1 ]; then
  mkdir -p "$STATE_DIR"
  jq -n --arg d "$TODAY" '{last_run: $d}' > "$STATE"
fi

if [ -n "$report" ]; then
  echo "$report"
fi
exit 0
