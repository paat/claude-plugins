#!/usr/bin/env bash
# Print plan-limit windows per provider, one line each:
#   <provider> <window> <used>% resets <UTC> in <XdYhZm> as-of <UTC>
# Codex: newest rate_limits event in its session logs (free). Claude: newest rate_limit_event in a
# run-claude.sh --stream-log (free) or, with --probe-claude, one tiny claude -p call. Grok has no
# source. A provider with no data prints "<provider> unknown <why>". Always exits 0 unless misused.
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
utc() { date -u -d "@$1" +%Y-%m-%dT%H:%MZ; }
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
codex_rows=""
codex_as_of=0
sessions="${CODEX_HOME:-$HOME/.codex}/sessions"
if [ -d "$sessions" ]; then
  while IFS= read -r f; do
    row=$(grep -F '"rate_limits":{' "$f" 2>/dev/null | jq -R -n -r '
      def mkrow(wm; up; ra):
        if (ra | type) == "number" and (up | type) == "number"
        then [(wm | if . == 300 then "5h" elif . == 10080 then "7d" else "\(.)m" end), (up | round), ra]
        else empty end;
      [inputs | fromjson?
       | .payload.rate_limits as $rl
       | [[$rl.primary, $rl.secondary][]? | select(. != null)
          | mkrow(.window_minutes; .used_percent; .resets_at)] as $rows
       | select($rows | length > 0) | $rows]
      | last // empty | .[]? | @tsv' 2>/dev/null) || row=""
    if [ -n "$row" ]; then codex_rows="$row"; codex_as_of=$(stat -c %Y "$f"); break; fi
  done < <(find "$sessions" -name 'rollout-*.jsonl' -mtime -8 -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 20 | cut -d' ' -f2-)
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
claude_as_of=0
for f in ${claude_logs[@]+"${claude_logs[@]}"}; do
  [ -f "$f" ] || continue
  rows=$(claude_rows "$f")
  if [ -n "$rows" ] && [ "$(stat -c %Y "$f")" -gt "$claude_as_of" ]; then
    claude_out="$rows"; claude_as_of=$(stat -c %Y "$f")
  fi
done
if [ -z "$claude_out" ] && [ "$probe_claude" -eq 1 ] && command -v claude >/dev/null 2>&1; then
  probe_dir=$(mktemp -d)
  # Non-repo cwd and closed stdin: the probe must not load project context or wait on input.
  (cd "$probe_dir" && timeout -k 5 90 claude -p ok --model claude-haiku-4-5 --max-turns 1 \
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

printf 'grok unknown (Grok CLI exposes no plan-limit data)\n'
