#!/usr/bin/env bash
# Print plan-limit windows per provider, one line each:
#   <provider> <window> <used>% resets <UTC> in <XdYhZm> as-of <UTC>
# Codex: newest rate_limits event by that event's own timestamp, among the 20 newest session
# logs from the last 8 days (free). Claude: newest rate_limit_event in a run-claude.sh --stream-log (free) or,
# with --probe-claude, one tiny claude -p call. agy: its local /usage command (free; Gemini
# buckets only). Grok and Muse have no source. A provider with no data prints "<provider> unknown <why>".
# Always exits 0 unless misused.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: usage.sh [--claude-log FILE]... [--probe-claude]'
}

claude_logs=()
probe_claude=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude-log) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; claude_logs+=("$2"); shift 2 ;;
    --probe-claude) probe_claude=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { printf 'usage.sh: jq not found\n' >&2; exit 127; }

now=$(date +%s)
# jq strftime formats epoch seconds in UTC (jq 1.6+).
utc() { jq -nr --argjson t "$1" '$t | strftime("%Y-%m-%dT%H:%MZ")'; }
# File mtime as epoch seconds.
# BSD stat: -f is a format, so `stat -f %m FILE` prints one integer.
# GNU stat: -f is a filesystem query and does not print an integer, so use `date -r FILE`.
mmo_file_mtime=date
mmo_probe=$(stat -f %m /dev/null 2>/dev/null || true)
case "$mmo_probe" in
  ''|*[!0-9]*) ;;
  *) mmo_file_mtime=stat ;;
esac
unset mmo_probe
file_epoch() {
  local t=0
  if [ "$mmo_file_mtime" = stat ]; then
    t=$(stat -f %m "$1" 2>/dev/null) || t=0
  else
    t=$(date -r "$1" +%s 2>/dev/null) || t=0
  fi
  case "$t" in
    ''|*[!0-9]*) t=0 ;;
  esac
  printf '%s\n' "$t"
}
span() {
  local s=$(( $1 > 0 ? $1 : 0 ))
  printf '%dd%dh%dm' $((s / 86400)) $((s % 86400 / 3600)) $((s % 3600 / 60))
}
# stdin: TSV "window used_percent resets_at_epoch"; $1 provider, $2 as-of epoch.
emit() {
  local provider="$1" as_of="$2" window used resets
  while IFS=$'\t' read -r window used resets; do
    [ -n "$window" ] || continue
    if [ "$resets" -le "$now" ]; then
      printf '%s %s 0%% (reset at %s since as-of) as-of %s\n' "$provider" "$window" "$(utc "$resets")" "$(utc "$as_of")"
    else
      printf '%s %s %s%% resets %s in %s as-of %s\n' "$provider" "$window" "$used" "$(utc "$resets")" "$(span $((resets - now)))" "$(utc "$as_of")"
    fi
  done
}

# Codex rollout logs: payload.rate_limits.{primary,secondary}.{used_percent,window_minutes,resets_at}.
# Candidates are the 20 newest rollout files from the last 8 days (mtime). Each contributes its
# last valid event. The newest event timestamp wins; as-of is that timestamp. File mtime is only
# a fallback when the event has no .timestamp, and it never outranks a timestamped event.
codex_rows=""
codex_as_of=0
codex_rank=-1
codex_mtime_rank=-1
sessions="${CODEX_HOME:-$HOME/.codex}/sessions"
if [ -d "$sessions" ]; then
  # Stat the 8-day window, then parse only the newest 20. Event timestamps decide inside that set.
  codex_list=$(mktemp)
  find "$sessions" -name 'rollout-*.jsonl' -type f -mtime -8 -print0 2>/dev/null |
    while IFS= read -r -d '' cand; do
      printf '%s\t%s\n' "$(file_epoch "$cand")" "$cand"
    done > "$codex_list" || true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    parsed=$(grep -F '"rate_limits":{' "$f" 2>/dev/null | jq -R -n -r '
      def mkrow(wm; up; ra):
        if (ra | type) == "number" and (up | type) == "number"
        then [(wm | if . == 300 then "5h" elif . == 10080 then "7d" else "\(.)m" end), (up | round), ra]
        else empty end;
      def event_epoch:
        (.timestamp // null) as $t
        | if ($t | type) == "number" then ($t | floor)
          elif ($t | type) == "string" then
            ($t | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null | if . == null then null else floor end)
          else null end;
      [inputs | fromjson?
       | . as $ev
       | .payload.rate_limits as $rl
       | [[$rl.primary, $rl.secondary][]? | select(. != null)
          | mkrow(.window_minutes; .used_percent; .resets_at)] as $rows
       | select($rows | length > 0)
       | {ts: ($ev | event_epoch), rows: $rows}]
      | last // empty
      | if . == null then empty
        else ((if .ts == null then "" else (.ts | tostring) end), (.rows[] | @tsv))
        end' 2>/dev/null) || parsed=""
    [ -n "$parsed" ] || continue
    event_ts="${parsed%%$'\n'*}"
    rows="${parsed#"$event_ts"}"
    rows="${rows#$'\n'}"
    [ -n "$rows" ] || continue
    case "$event_ts" in
      ''|*[!0-9]*) event_ts="" ;;
    esac
    if [ -n "$event_ts" ]; then
      if [ "$event_ts" -gt "$codex_rank" ]; then
        codex_rows="$rows"
        codex_as_of="$event_ts"
        codex_rank="$event_ts"
      fi
    elif [ "$codex_rank" -lt 0 ]; then
      mt=$(file_epoch "$f")
      if [ "$mt" -gt "$codex_mtime_rank" ]; then
        codex_rows="$rows"
        codex_as_of="$mt"
        codex_mtime_rank="$mt"
      fi
    fi
  done < <(sort -nr "$codex_list" | head -n 20 | cut -f2- || true)
  rm -f "$codex_list"
fi
if [ -n "$codex_rows" ]; then
  printf '%s\n' "$codex_rows" | emit codex "$codex_as_of"
else
  printf 'codex unknown (no rate_limits in session logs from the last 8 days)\n'
fi

# Claude stream-json: rate_limit_event.rate_limit_info.unifiedWindows.<name>.{utilization,resetsAt}.
claude_rows() {
  grep -hF '"rate_limit_event"' "$@" 2>/dev/null | jq -R -n -r '
    def relabel(t): (t | sub("five_hour"; "5h") | sub("seven_day"; "7d"));
    def mkrow(name; ra; up):
      if (ra | type) == "number" and (up | type) == "number"
      then [name, (up * 100 | round), ra] else empty end;
    [inputs | fromjson?
     | .rate_limit_info as $ri | ($ri.unifiedWindows // {}) as $uw
     | (([$uw | to_entries[] | mkrow(relabel(.key); .value.resetsAt; .value.utilization)])
        + (if ($ri.rateLimitType != null) and (($uw | has($ri.rateLimitType)) | not)
           then [mkrow(relabel($ri.rateLimitType); $ri.resetsAt; $ri.utilization)] else [] end)) as $rows
     | select($rows | length > 0) | $rows]
    | last // empty | .[]? | @tsv' 2>/dev/null || true
}
claude_out=""
claude_as_of=-1
for f in ${claude_logs[@]+"${claude_logs[@]}"}; do
  [ -f "$f" ] || continue
  rows=$(claude_rows "$f")
  if [ -n "$rows" ]; then
    mt=$(file_epoch "$f")
    if [ "$mt" -gt "$claude_as_of" ]; then
      claude_out="$rows"
      claude_as_of=$mt
    fi
  fi
done
if [ -z "$claude_out" ] && [ "$probe_claude" -eq 1 ] && command -v claude >/dev/null 2>&1; then
  probe_dir=$(mktemp -d)
  # Non-repo cwd and closed stdin: the probe must not load project context or wait on input.
  (cd "$probe_dir" && timeout -k 5 90 claude -p ok --model claude-haiku-5-5 --max-turns 1 \
    --output-format stream-json --verbose </dev/null > "$probe_dir/stream.jsonl" 2>/dev/null) || true
  claude_out=$(claude_rows "$probe_dir/stream.jsonl")
  claude_as_of=$now
  rm -rf "$probe_dir"
fi
if [ -n "$claude_out" ]; then
  printf '%s\n' "$claude_out" | emit claude "$claude_as_of"
elif [ "$probe_claude" -eq 1 ]; then
  printf 'claude unknown (probe returned no rate_limit_event)\n'
else
  printf 'claude unknown (pass --claude-log or --probe-claude; desktop app: get_usage)\n'
fi

# agy print-mode /usage answers locally (0 tokens): command.data.groups[].buckets[] with
# id gemini-5h|gemini-weekly, remaining_fraction, reset_time. The 3p buckets (Claude/GPT
# inside agy) are not pool routes and are skipped.
if command -v agy >/dev/null 2>&1; then
  agy_dir=$(mktemp -d)
  agy_rows=$( (cd "$agy_dir" && timeout -k 5 60 agy -p=/usage --output-format json </dev/null 2>/dev/null) | jq -r '
    [.command.data.groups[]?.buckets[]?
     | select((.id | type) == "string" and (.remaining_fraction | type) == "number")
     | (.id | if . == "gemini-5h" then "5h" elif . == "gemini-weekly" then "7d" else empty end) as $w
     | ((.reset_time // "") | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty) as $r
     | [$w, ((1 - .remaining_fraction) * 100 | round), $r]]
    | .[] | @tsv' 2>/dev/null) || agy_rows=""
  rm -rf "$agy_dir"
  if [ -n "$agy_rows" ]; then
    printf '%s\n' "$agy_rows" | emit agy "$now"
  else
    printf 'agy unknown (/usage returned no Gemini buckets)\n'
  fi
else
  printf 'agy unknown (agy CLI not installed)\n'
fi

printf 'grok unknown (Grok CLI exposes no plan-limit data)\n'
printf 'muse unknown (Muse CLI exposes no plan-limit data)\n'
