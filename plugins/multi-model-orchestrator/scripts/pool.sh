#!/usr/bin/env bash
# pool.sh — pick or run a worker for a complexity tier.
#
#   pool.sh pick --tier T1|T2|T3|T4 [--mode implement|review] [--allow LIST] [--deny LIST]
#                [--prefer PROVIDER_OR_MODEL] [--usage FILE] [--timeout SECONDS]
#   pool.sh run  <pick options> [--repo DIR] [--base REF] [--out FILE]   (prompt on stdin)
#                [--allow-paths GLOBS] [--verify-cmd CMD] [--verify-pattern ERE] [--task ID] [--cycle N]
#
# The tier comes from the caller (route-model-task); the worker order per tier comes from
# pool-tiers.tsv (or MMO_POOL_TIERS). This script only removes workers that cannot take the
# task now: a provider with no runner, not allowed or denied (LIST = comma-separated providers or models), CLI not
# installed, an advisory engine (local qwen, agy, vibe; agy claude-opus-5-5 excepted, paat/ai-overlord#474, 2026-11-18) on a review, or a plan window >= 90% used
# that resets after the timeout. claude-api shares Claude's identity, but not its plan windows.
# --deny claude also removes agy's claude-* rows (same model).
# Within each tier, --prefer's rows go first, then the rows a 7d window binds when it is
# <= 60% used and resets within 24h (use it or lose it).
# Usage comes from --usage (usage.sh output) or a fresh usage.sh run. T1 and T2 workers are
# followed by the higher tiers' workers as fallbacks; T3 and T4 never fall to a weaker tier.
#
# pick prints "tier provider model effort" (TSV) per remaining worker, best first.
# run feeds the prompt to each in turn; a runner exit of 75, 77, or 127 moves to the next
# worker (a provider/model that already exited 75 is not retried later in the run), unless the leg changed the repository: then it exits 55 (partly edited — salvage
# or reset before redispatch). Any other runner exit is the result.
# Exit 75 when no worker is left; the reason and the earliest reset go to stderr.
# Implement runs only: contract flags (--allow-paths ... --cycle) are validated by leg-check.sh
# before any worker runs; the HEAD and a snapshot of the dirty tree are captured before dispatch,
# and a worker exit of 0 is followed by leg-check.sh against them. Its exit (0, 8 scope, 9 verify,
# 10 no change, 11 check could not run) is the result; the final line adds check=<result>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"
. "$SCRIPT_DIR/lib-outcomes.sh"
mmo_signal_init

usage() {
  printf '%s\n' 'Usage: pool.sh pick|run --tier T1|T2|T3|T4 [--mode implement|review] [--allow LIST] [--deny LIST] [--prefer PROVIDER_OR_MODEL] [--usage FILE] [--timeout SECONDS] [--repo DIR] [--base REF] [--out FILE] [--allow-paths GLOBS] [--verify-cmd CMD] [--verify-pattern ERE] [--task ID] [--cycle N]'
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
contract=()
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
    --allow-paths|--verify-cmd|--verify-pattern|--task|--cycle)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }; contract+=("$1" "$2"); shift 2 ;;
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
if [ "${#contract[@]}" -gt 0 ] && { [ "$action" != run ] || [ "$mode" != implement ]; }; then
  printf 'pool: --allow-paths, --verify-cmd, --verify-pattern, --task and --cycle apply to run --mode implement only\n' >&2
  exit 2
fi
# Reject a malformed contract before a worker spends a run on it (leg-check owns the rules).
if [ "${#contract[@]}" -gt 0 ]; then
  "$SCRIPT_DIR/leg-check.sh" --validate "${contract[@]}" || exit 2
fi
tiers_file="${MMO_POOL_TIERS:-$SCRIPT_DIR/pool-tiers.tsv}"
[ -r "$tiers_file" ] || { printf 'pool: cannot read tier table %s\n' "$tiers_file" >&2; exit 2; }

in_list() {  # in_list LIST provider model
  local list=",$1," provider="$2"
  list="${list//,claude-api,/,claude,}"
  [ "$provider" != claude-api ] || provider=claude
  case "$list" in *",$provider,"*|*",$3,"*) return 0 ;; *) return 1 ;; esac
}

# Tight windows as "provider window reset_epoch". A window named <w>_<x> (Claude's 7d_opus)
# binds only models containing <x>; any other window binds the whole provider.
# Spare windows as "provider window": a 7d window with headroom that is about to reset.
now=$(date +%s)
if [ -n "$usage_file" ]; then
  [ -r "$usage_file" ] || { printf 'pool: cannot read usage file %s\n' "$usage_file" >&2; exit 2; }
  usage_text="$(cat "$usage_file")"
else
  usage_text="$("$SCRIPT_DIR/usage.sh" 2>/dev/null || true)"
fi
tight=""
spare=""
while read -r u_provider u_window u_used u_word u_reset _; do
  [ "$u_word" = resets ] || continue
  u_used="${u_used%\%}"
  [[ "$u_used" =~ ^[0-9]+$ ]] || continue
  u_epoch="$(date -u -d "$u_reset" +%s 2>/dev/null)" || continue
  if [ "$u_used" -ge 90 ] && [ "$u_epoch" -gt $((now + run_timeout)) ]; then
    tight+="$u_provider $u_window $u_epoch"$'\n'
  elif [[ "$u_window" == 7d || "$u_window" == 7d_* ]] && [ "$u_used" -le 60 ] && [ "$u_epoch" -gt "$now" ] && [ "$u_epoch" -le $((now + 86400)) ]; then
    spare+="$u_provider $u_window"$'\n'
    printf 'pool: use it or lose it: %s %s %s%% used, resets %s\n' "$u_provider" "$u_window" "$u_used" "$u_reset" >&2
  fi
done <<< "$usage_text"

binds() {  # binds window model
  case "$1" in *_*) [[ "$2" == *"${1#*_}"* ]] ;; esac
}

# Prints the latest reset among the tight windows that bind this worker (it is usable only
# after all of them reset); fails when none does.
tight_reset() {  # tight_reset provider model
  local t_provider t_window t_epoch found=""
  while read -r t_provider t_window t_epoch; do
    [ "$t_provider" = "$1" ] && binds "$t_window" "$2" || continue
    [ -n "$found" ] && [ "$found" -ge "$t_epoch" ] || found="$t_epoch"
  done <<< "$tight"
  [ -n "$found" ] && printf '%s' "$found"
}

is_spare() {  # is_spare provider model
  local s_provider s_window
  while read -r s_provider s_window; do
    [ "$s_provider" = "$1" ] && binds "$s_window" "$2" && return 0
  done <<< "$spare"
  return 1
}

cli_for() {
  case "$1" in claude-api) printf claude ;; claude|codex|grok|muse|agy|vibe) printf '%s' "$1" ;; *) printf '' ;; esac
}

known_provider() {
  case "$1" in claude|claude-api|codex|grok|muse|agy|vibe|qwen) return 0 ;; *) return 1 ;; esac
}

candidates=()
deferred_api=()
earliest=""
for t in $chain; do
  rows=()
  preferred=()
  spared=()
  while IFS=$'\t' read -r r_tier r_provider r_model r_effort; do
    [ "$r_tier" = "$t" ] || continue
    if [ -n "$prefer" ] && { [ "$r_provider" = "$prefer" ] || [ "$r_model" = "$prefer" ]; }; then
      preferred+=("$r_tier"$'\t'"$r_provider"$'\t'"$r_model"$'\t'"$r_effort")
    elif is_spare "$r_provider" "$r_model"; then
      spared+=("$r_tier"$'\t'"$r_provider"$'\t'"$r_model"$'\t'"$r_effort")
    else
      rows+=("$r_tier"$'\t'"$r_provider"$'\t'"$r_model"$'\t'"$r_effort")
    fi
  done < <(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$tiers_file")
  rows=(${preferred[@]+"${preferred[@]}"} ${spared[@]+"${spared[@]}"} ${rows[@]+"${rows[@]}"})
  for row in ${rows[@]+"${rows[@]}"}; do
    IFS=$'\t' read -r r_tier r_provider r_model r_effort <<< "$row"
    why=""
    if ! known_provider "$r_provider"; then why="unknown provider"
    elif [ -n "$allow" ] && ! in_list "$allow" "$r_provider" "$r_model"; then why="not allowed"
    elif [ -n "$deny" ] && { in_list "$deny" "$r_provider" "$r_model" || { [ "$r_provider" = agy ] && [[ "$r_model" == claude-* ]] && in_list "$deny" claude "$r_model"; }; }; then why="denied"
    elif [ "$mode" = review ] && { [ "$r_provider" = qwen ] || [ "$r_provider" = vibe ] || { [ "$r_provider" = agy ] && [ "$r_model" != claude-opus-5-5 ]; }; }; then why="advisory reviewer"
    elif [ -n "$(cli_for "$r_provider")" ] && ! command -v "$(cli_for "$r_provider")" >/dev/null 2>&1; then why="CLI not installed"
    elif [ "$r_provider" = claude-api ]; then
      if [ -z "${MMO_CLAUDE_API_KEY_FILE:-}" ] || [ ! -f "$MMO_CLAUDE_API_KEY_FILE" ] || [ ! -r "$MMO_CLAUDE_API_KEY_FILE" ] || [ ! -s "$MMO_CLAUDE_API_KEY_FILE" ]; then
        why="MMO_CLAUDE_API_KEY_FILE unavailable"
      elif ! tight_reset claude "$r_model" >/dev/null; then
        if [ "$action" = run ]; then
          deferred_api+=("$row")
          continue
        fi
        why="Claude plan row available"
      fi
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
prompt_file="$(mktemp)"
runner_stderr=""
snapshot_file=""
trap 'rm -f "$prompt_file" "$runner_stderr" "$snapshot_file"' EXIT
cat > "$prompt_file"
[ -s "$prompt_file" ] || { printf 'pool: empty prompt\n' >&2; exit 2; }
if [ "${#contract[@]}" -gt 0 ]; then
  leg_base="$(git -C "$repo_dir" rev-parse --verify -q HEAD)" || { printf 'pool: leg checks need a commit at HEAD\n' >&2; exit 2; }
  # Edits already in the tree are not the leg's: the check compares against this snapshot.
  snapshot_file="$(mktemp)"
  snapshot_args=(--snapshot "$snapshot_file" --repo "$repo_dir")
  [ -z "$output_file" ] || snapshot_args+=(--out "$output_file")
  "$SCRIPT_DIR/leg-check.sh" "${snapshot_args[@]}" || {
    printf 'pool: exit=11 check=error cannot snapshot the tree before dispatch\n' >&2
    exit 11
  }
fi

rc=75
fell_through=0
failed_pm=()
for ((candidate_index=0; candidate_index<${#candidates[@]}; candidate_index++)); do
  row="${candidates[$candidate_index]}"
  IFS=$'\t' read -r r_tier r_provider r_model r_effort <<< "$row"
  # A provider/model that already exited 75 is not retried on later rows of the same
  # run (e.g. the T3 vibe row after the T2 vibe row exited 75).
  skip75=0
  for ((failed_index=0; failed_index<${#failed_pm[@]}; failed_index++)); do
    if [ "${failed_pm[$failed_index]}" = "$r_provider/$r_model" ]; then
      skip75=1
      break
    fi
  done
  if [ "$skip75" -eq 1 ]; then
    printf 'pool: skip %s %s/%s: already unavailable (exit 75)\n' "$r_tier" "$r_provider" "$r_model" >&2
    fell_through=1
    continue
  fi
  args=(--mode "$mode" --repo "$repo_dir" --timeout "$run_timeout")
  args+=(--model "$r_model")
  [ "$r_effort" = n/a ] || args+=(--effort "$r_effort")
  [ -z "$base_ref" ] || args+=(--base "$base_ref")
  [ -z "$output_file" ] || args+=(--out "$output_file")
  case "$r_provider" in
    qwen) runner=run-qwen-local.sh ;;
    claude-api) runner=run-claude.sh; args+=(--api) ;;
    *) runner="run-$r_provider.sh" ;;
  esac
  printf 'pool: %s -> %s/%s/%s\n' "$r_tier" "$r_provider" "$r_model" "$r_effort" >&2
  before="$(mmo_tree_state "$repo_dir" "$output_file")"
  rc=0
  if [ "$r_provider" = claude ]; then
    [ -n "$runner_stderr" ] || runner_stderr="$(mktemp)"
    MMO_OUTCOME_TIER="$r_tier" mmo_run direct "" "" "$SCRIPT_DIR/$runner" "${args[@]}" < "$prompt_file" 2> "$runner_stderr" || rc=$?
    cat "$runner_stderr" >&2
  else
    MMO_OUTCOME_TIER="$r_tier" mmo_run direct "" "" "$SCRIPT_DIR/$runner" "${args[@]}" < "$prompt_file" || rc=$?
  fi
  case "$rc" in
    75|77|127)
      if [ "$(mmo_tree_state "$repo_dir" "$output_file")" != "$before" ]; then
        printf 'pool: %s exited %s after changing the repository; not handing the task to another worker\n' "$r_provider" "$rc" >&2
        rc=55
        fell_through=0
        break
      fi
      # Only the runner's final exit line can unlock matching API overflow.
      if [ "$r_provider" = claude ] && [ "$rc" -eq 75 ] &&
         tail -n 1 "$runner_stderr" | grep -q '^run-claude: exit=75 failure=limit '; then
        for api_row in ${deferred_api[@]+"${deferred_api[@]}"}; do
          IFS=$'\t' read -r api_tier api_provider api_model api_effort <<< "$api_row"
          [ "$api_model" = "$r_model" ] && [ "$api_effort" = "$r_effort" ] || continue
          candidates=("${candidates[@]:0:candidate_index+1}" "$api_row" "${candidates[@]:candidate_index+1}")
          break
        done
      fi
      printf 'pool: %s unavailable (exit %s); next worker\n' "$r_provider" "$rc" >&2
      [ "$rc" -eq 75 ] && failed_pm+=("$r_provider/$r_model")
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
check_note=""
if [ "$rc" -eq 0 ] && [ "${#contract[@]}" -gt 0 ]; then
  check_args=(--repo "$repo_dir" --base "$leg_base" --baseline "$snapshot_file" "${contract[@]}"
    --tier "$r_tier" --provider "$r_provider" --model "$r_model" --effort "$r_effort")
  if [ -n "$output_file" ]; then
    check_args+=(--out "$output_file")
    case "$output_file" in /dev/*) ;; *) check_args+=(--final "$output_file") ;; esac
  fi
  # Under the signal supervisor, like a worker: cancelling the pool stops a long verify.
  mmo_run direct "" "" "$SCRIPT_DIR/leg-check.sh" "${check_args[@]}" || rc=$?
  case "$rc" in 0) check_note=" check=pass" ;; 8) check_note=" check=scope" ;; 9) check_note=" check=verify" ;; 10) check_note=" check=no_change" ;; *) check_note=" check=error" ;; esac
fi
printf 'pool: exit=%s worker=%s model=%s effort=%s tier=%s%s\n' "$rc" "$r_provider" "$r_model" "$r_effort" "$r_tier" "$check_note" >&2
exit "$rc"
