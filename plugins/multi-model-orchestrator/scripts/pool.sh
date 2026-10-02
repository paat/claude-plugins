#!/usr/bin/env bash
# pool.sh — pick or run a worker for a complexity tier.
#
#   pool.sh pick --tier T1|T2|T3|T4 [--mode implement|review] [--allow LIST] [--deny LIST]
#                [--prefer PROVIDER] [--usage FILE] [--timeout SECONDS]
#   pool.sh run  <pick options> [--repo DIR] [--base REF] [--out FILE]   (prompt on stdin)
#
# The tier comes from the caller (route-model-task); the worker order per tier comes from
# pool-tiers.tsv (or MMO_POOL_TIERS). This script only removes workers that cannot take the
# task now: not allowed or denied (LIST = comma-separated providers or models), CLI not
# installed, an advisory engine (local qwen, agy) on a review, or a plan window >= 90% used
# that resets after the timeout. Usage comes from --usage (usage.sh output) or a fresh
# usage.sh run. A T1 or T2 tier with nobody left escalates upward; T3 and T4 never fall to a
# weaker tier.
#
# pick prints "tier provider model effort" (TSV) per remaining worker, best first.
# run feeds the prompt to each in turn; a runner exit of 75, 77, or 127 moves to the next
# worker unless the leg changed the repository. Any other exit is the result.
# Exit 75 when no worker is left; the reason and the earliest reset go to stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"

usage() {
  printf '%s\n' 'Usage: pool.sh pick|run --tier T1|T2|T3|T4 [--mode implement|review] [--allow LIST] [--deny LIST] [--prefer PROVIDER] [--usage FILE] [--timeout SECONDS] [--repo DIR] [--base REF] [--out FILE]'
}

action="${1:-}"
case "$action" in pick|run) shift ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
tier=""
mode=implement
allow=""
deny=""
prefer=""
usage_file=""
run_timeout=1800
repo_dir="$PWD"
base_ref=""
output_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tier) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; tier="$2"; shift 2 ;;
    --mode) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; mode="$2"; shift 2 ;;
    --allow) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; allow="$2"; shift 2 ;;
    --deny) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; deny="$2"; shift 2 ;;
    --prefer) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; prefer="$2"; shift 2 ;;
    --usage) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; usage_file="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; run_timeout="$2"; shift 2 ;;
    --repo|--dir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; repo_dir="$2"; shift 2 ;;
    --base) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; base_ref="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; output_file="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'pool: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$tier" in T1) chain="T1 T2 T3" ;; T2) chain="T2 T3" ;; T3|T4) chain="$tier" ;; *) printf 'pool: --tier must be T1, T2, T3, or T4\n' >&2; exit 2 ;; esac
case "$mode" in implement|review) ;; *) printf 'pool: --mode must be implement or review\n' >&2; exit 2 ;; esac
[[ "$run_timeout" =~ ^[1-9][0-9]*$ ]] || { printf 'pool: timeout must be a positive integer\n' >&2; exit 2; }
if [ "$action" = run ] && [ "$mode" = review ] && [ -z "$base_ref" ]; then
  printf 'pool: run --mode review needs --base\n' >&2
  exit 2
fi
tiers_file="${MMO_POOL_TIERS:-$SCRIPT_DIR/pool-tiers.tsv}"
[ -r "$tiers_file" ] || { printf 'pool: cannot read tier table %s\n' "$tiers_file" >&2; exit 2; }

in_list() {  # in_list LIST provider model
  case ",$1," in *",$2,"*|*",$3,"*) return 0 ;; *) return 1 ;; esac
}

# Tight windows as "provider window reset_epoch". A window named <w>_<x> (Claude's 7d_opus)
# binds only models containing <x>; any other window binds the whole provider.
now=$(date +%s)
if [ -n "$usage_file" ]; then
  [ -r "$usage_file" ] || { printf 'pool: cannot read usage file %s\n' "$usage_file" >&2; exit 2; }
  usage_text="$(cat "$usage_file")"
else
  usage_text="$("$SCRIPT_DIR/usage.sh" 2>/dev/null || true)"
fi
tight=""
while read -r u_provider u_window u_used u_word u_reset _; do
  [ "$u_word" = resets ] || continue
  u_used="${u_used%\%}"
  [[ "$u_used" =~ ^[0-9]+$ ]] && [ "$u_used" -ge 90 ] || continue
  u_epoch="$(date -u -d "$u_reset" +%s 2>/dev/null)" || continue
  [ "$u_epoch" -gt $((now + run_timeout)) ] || continue
  tight+="$u_provider $u_window $u_epoch"$'\n'
done <<< "$usage_text"

# Prints the earliest reset among the windows that bind this worker; fails when none does.
tight_reset() {  # tight_reset provider model
  local t_provider t_window t_epoch suffix found=""
  while read -r t_provider t_window t_epoch; do
    [ "$t_provider" = "$1" ] || continue
    case "$t_window" in
      *_*) suffix="${t_window#*_}"; case "$2" in *"$suffix"*) ;; *) continue ;; esac ;;
    esac
    [ -n "$found" ] && [ "$found" -le "$t_epoch" ] || found="$t_epoch"
  done <<< "$tight"
  [ -n "$found" ] && printf '%s' "$found"
}

cli_for() {
  case "$1" in claude|codex|grok|agy) printf '%s' "$1" ;; *) printf '' ;; esac
}

candidates=()
earliest=""
for t in $chain; do
  rows=()
  preferred=()
  while IFS=$'\t' read -r r_tier r_provider r_model r_effort; do
    [ "$r_tier" = "$t" ] || continue
    if [ -n "$prefer" ] && [ "$r_provider" = "$prefer" ]; then
      preferred+=("$r_tier"$'\t'"$r_provider"$'\t'"$r_model"$'\t'"$r_effort")
    else
      rows+=("$r_tier"$'\t'"$r_provider"$'\t'"$r_model"$'\t'"$r_effort")
    fi
  done < <(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$tiers_file")
  rows=(${preferred[@]+"${preferred[@]}"} ${rows[@]+"${rows[@]}"})
  for row in ${rows[@]+"${rows[@]}"}; do
    IFS=$'\t' read -r r_tier r_provider r_model r_effort <<< "$row"
    why=""
    if [ -n "$allow" ] && ! in_list "$allow" "$r_provider" "$r_model"; then why="not allowed"
    elif [ -n "$deny" ] && in_list "$deny" "$r_provider" "$r_model"; then why="denied"
    elif [ "$mode" = review ] && { [ "$r_provider" = qwen ] || [ "$r_provider" = agy ]; }; then why="advisory reviewer"
    elif [ -n "$(cli_for "$r_provider")" ] && ! command -v "$(cli_for "$r_provider")" >/dev/null 2>&1; then why="CLI not installed"
    elif reset="$(tight_reset "$r_provider" "$r_model")"; then
      why="plan window >= 90% until $(date -u -d "@$reset" +%Y-%m-%dT%H:%MZ)"
      [ -n "$earliest" ] && [ "$earliest" -le "$reset" ] || earliest="$reset"
    fi
    if [ -n "$why" ]; then
      printf 'pool: skip %s %s/%s: %s\n' "$r_tier" "$r_provider" "$r_model" "$why" >&2
    else
      candidates+=("$row")
    fi
  done
  # Escalate only when this tier left nobody.
  [ "${#candidates[@]}" -eq 0 ] || break
done

if [ "${#candidates[@]}" -eq 0 ]; then
  printf 'pool: no worker left for %s' "$tier" >&2
  [ -z "$earliest" ] || printf '; earliest plan reset %s' "$(date -u -d "@$earliest" +%Y-%m-%dT%H:%MZ)" >&2
  printf '\n' >&2
  exit 75
fi

if [ "$action" = pick ]; then
  printf '%s\n' "${candidates[@]}"
  exit 0
fi

command -v git >/dev/null 2>&1 || { printf 'pool: git not found\n' >&2; exit 127; }
repo_dir="$(git -C "$repo_dir" rev-parse --show-toplevel)" || exit 2
out_abs=""
[ -z "$output_file" ] || out_abs="$(realpath -m "$output_file")"
prompt_file="$(mktemp)"
trap 'rm -f "$prompt_file"' EXIT
cat > "$prompt_file"
[ -s "$prompt_file" ] || { printf 'pool: empty prompt\n' >&2; exit 2; }

rc=75
fell_through=0
for row in "${candidates[@]}"; do
  IFS=$'\t' read -r r_tier r_provider r_model r_effort <<< "$row"
  args=(--mode "$mode" --repo "$repo_dir" --timeout "$run_timeout")
  [ "$r_provider" = qwen ] || args+=(--model "$r_model")
  [ "$r_effort" = n/a ] || args+=(--effort "$r_effort")
  [ -z "$base_ref" ] || args+=(--base "$base_ref")
  [ -z "$output_file" ] || args+=(--out "$output_file")
  case "$r_provider" in qwen) runner=run-qwen-local.sh ;; *) runner="run-$r_provider.sh" ;; esac
  printf 'pool: %s -> %s/%s/%s\n' "$r_tier" "$r_provider" "$r_model" "$r_effort" >&2
  before="$(mmo_tree_state "$repo_dir" "$out_abs")"
  rc=0
  "$SCRIPT_DIR/$runner" "${args[@]}" < "$prompt_file" || rc=$?
  case "$rc" in
    75|77|127)
      if [ "$(mmo_tree_state "$repo_dir" "$out_abs")" != "$before" ]; then
        printf 'pool: %s exited %s after changing the repository; not handing the task to another worker\n' "$r_provider" "$rc" >&2
        break
      fi
      printf 'pool: %s unavailable (exit %s); next worker\n' "$r_provider" "$rc" >&2
      fell_through=1
      continue
      ;;
  esac
  fell_through=0
  break
done
if [ "$fell_through" -eq 1 ]; then
  printf 'pool: exit=75 every %s worker was unavailable\n' "$tier" >&2
  exit 75
fi
printf 'pool: exit=%s worker=%s model=%s effort=%s tier=%s\n' "$rc" "$r_provider" "$r_model" "$r_effort" "$r_tier" >&2
exit "$rc"
