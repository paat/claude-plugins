#!/usr/bin/env bash
# friction-report.sh — recurring friction per provider, model, effort and role, from the local
# records (no model calls). Evidence for changing a default or a harness-adjustments.tsv row.
#
#   friction-report.sh [--days N] [--min-count N] [--min-rate PCT] [--flags-only]
#                      [--outcomes FILE]... [--checks FILE]...
#
# Defaults: --days 30, --min-count 3, --min-rate 30, and the files the writers use
# (MMO_OUTCOMES_FILE, MMO_LEG_CHECKS_FILE, else under ${XDG_STATE_HOME:-$HOME/.local/state}/
# multi-model-orchestrator/). --outcomes/--checks repeat to combine hosts; a missing file is skipped.
# Rows older than N days, gate rows and rows without a provider are left out. Model is the served
# model when recorded, else the requested one; check rows have role implement.
#
# Kinds from runner exit codes (skills/meta-orchestration/references/leg-liveness.md, runner
# headers): 124 timeout, 5 empty_output, 6 no_verdict, 7 readonly_write, 55/76/78 step_cap,
# 1 provider_error, any other unlisted code exit_N. Their legs = the group's runner exits, 0 included.
# Not model friction (flag info, legs = every runner exit of the group, out of the other rates):
# 75 unavailable, 77 auth, 127 cli_missing, 2/3/4 usage, 129/130/143 interrupted.
# Kinds from leg checks: scope, verify, no_change, and asks-to-continue (detail column); legs =
# the group's checks.
#
# Output: TSV with header, sorted by rate_pct descending; flag yes when count >= --min-count and
# rate_pct >= --min-rate. --flags-only keeps only flag yes rows. Exit 0 (also when empty), 2 usage.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: friction-report.sh [--days N] [--min-count N] [--min-rate PCT] [--flags-only] [--outcomes FILE]... [--checks FILE]...'
}
usage_error() { printf 'friction-report: %s\n' "$1" >&2; usage >&2; exit 2; }

days=30
min_count=3
min_rate=30
flags_only=0
outcomes=()
checks=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --flags-only) flags_only=1; shift; continue ;;
    --days|--min-count|--min-rate|--outcomes|--checks) [ "$#" -ge 2 ] || usage_error "$1 needs a value" ;;
    *) usage_error "unknown option: $1" ;;
  esac
  case "$1" in
    --days) days="$2" ;;
    --min-count) min_count="$2" ;;
    --min-rate) min_rate="$2" ;;
    --outcomes) outcomes+=("$2") ;;
    --checks) checks+=("$2") ;;
  esac
  shift 2
done
[[ "$days" =~ ^[1-9][0-9]*$ ]] || usage_error '--days must be a positive integer'
[[ "$min_count" =~ ^[1-9][0-9]*$ ]] || usage_error '--min-count must be a positive integer'
[[ "$min_rate" =~ ^[0-9]+$ ]] && [ "$min_rate" -le 100 ] || usage_error '--min-rate must be an integer from 0 to 100'

state="${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator"
[ "${#outcomes[@]}" -gt 0 ] || outcomes=("${MMO_OUTCOMES_FILE:-$state/outcomes.tsv}")
[ "${#checks[@]}" -gt 0 ] || checks=("${MMO_LEG_CHECKS_FILE:-$state/leg-checks.tsv}")
cutoff="$(date -u -d "-$days days" +%Y-%m-%dT%H:%M:%SZ)"

export LC_ALL=C
printf 'provider\tmodel\teffort\trole\tkind\tcount\tlegs\trate_pct\tfirst_seen\tlast_seen\tflag\n'
{
  for f in "${outcomes[@]}"; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    awk '{print "o\t" $0}' < "$f"
  done
  for f in "${checks[@]}"; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    awk '{print "c\t" $0}' < "$f"
  done
} | awk -F '\t' -v OFS='\t' -v cutoff="$cutoff" -v min_count="$min_count" -v min_rate="$min_rate" -v flags_only="$flags_only" '
  function d(v) { return v == "" ? "-" : v }
  function add(group, kind, when, info) {
    k = group SUBSEP kind
    count[k]++
    if (!(k in first) || when < first[k]) first[k] = when
    if (!(k in last) || when > last[k]) last[k] = when
    is_info[k] = info
  }
  $2 == "utc_time" || $2 < cutoff { next }
  $1 == "o" && NF >= 10 && $5 != "gate" && $6 != "" && $10 ~ /^[0-9]+$/ {
    g = $6 OFS d($8 != "" ? $8 : $7) OFS d($9) OFS d($5)
    rc = $10 + 0
    attempts[g]++
    info = ""
    if (rc == 75) info = "unavailable"
    else if (rc == 77) info = "auth"
    else if (rc == 127) info = "cli_missing"
    else if (rc == 2 || rc == 3 || rc == 4) info = "usage"
    else if (rc == 129 || rc == 130 || rc == 143) info = "interrupted"
    if (info != "") { add(g, info, $2, 1); next }
    runs[g]++
    kind = ""
    if (rc == 124) kind = "timeout"
    else if (rc == 5) kind = "empty_output"
    else if (rc == 6) kind = "no_verdict"
    else if (rc == 7) kind = "readonly_write"
    else if (rc == 55 || rc == 76 || rc == 78) kind = "step_cap"
    else if (rc == 1) kind = "provider_error"
    else if (rc != 0) kind = "exit_" rc
    if (kind != "") add(g, kind, $2, 0)
    next
  }
  $1 == "c" && NF >= 11 && $7 != "" {
    g = $7 OFS d($8) OFS d($9) OFS "implement"
    legchecks[g]++
    if ($10 == "scope" || $10 == "verify" || $10 == "no_change") add(g, $10, $2, 0)
    if ($11 == "asks-to-continue") add(g, "asks-to-continue", $2, 0)
  }
  END {
    for (k in count) {
      split(k, part, SUBSEP)
      g = part[1]; kind = part[2]
      if (is_info[k]) legs = attempts[g]
      else if (kind == "scope" || kind == "verify" || kind == "no_change" || kind == "asks-to-continue") legs = legchecks[g]
      else legs = runs[g]
      rate = sprintf("%.1f", 100 * count[k] / legs)
      flag = is_info[k] ? "info" : (count[k] >= min_count + 0 && rate + 0 >= min_rate + 0 ? "yes" : "no")
      if (flags_only && flag != "yes") continue
      print g, kind, count[k], legs, rate, first[k], last[k], flag
    }
  }
' | sort -t "$(printf '\t')" -k8,8gr -k6,6nr -k1,5
