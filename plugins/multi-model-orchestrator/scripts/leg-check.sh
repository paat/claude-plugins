#!/usr/bin/env bash
# leg-check.sh — deterministic acceptance checks for one implement leg, recorded per call.
#
#   leg-check.sh --repo DIR --base REF [--allow-paths GLOBS] [--verify-cmd CMD] [--verify-pattern ERE]
#                [--verify-timeout SECONDS] [--final FILE] [--out PATH]...
#                [--task ID] [--cycle N] [--tier T] [--provider P] [--model M] [--effort E]
#
# REF is the commit the leg started from. Changed paths: tracked paths that differ between REF
# and the working tree (committed or not) plus untracked, non-ignored files; the leg outputs
# (--out and the runner files beside it) do not count. Checks, first failure wins:
#   no_change  exit 10  nothing changed
#   scope      exit 8   a changed path matches none of the comma-separated --allow-paths globs
#                       ([[ path == glob ]], so * crosses /; a glob ending in / is that directory)
#   verify     exit 9   --verify-cmd (bash -c in the repo, timeout default 900 s) failed or timed
#                       out, or its combined output does not match --verify-pattern (catches a test
#                       runner that exits 0 having run nothing)
#   pass       exit 0
# Advisory, never changes the exit: when the last 15 lines of --final (the worker's final message)
# ask to continue ("want me to", "would you like me to", "shall I", "should I continue|proceed",
# "let me know if you"; case-insensitive), the result line adds note=asks-to-continue.
# Exit 2: usage error or invalid REF (no row is recorded).
#
# Each check appends one row to ${MMO_LEG_CHECKS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/
# multi-model-orchestrator/leg-checks.tsv}; a write failure never changes the exit status.
# Last stderr line: leg-check: exit=N check=<pass|no_change|scope|verify> paths=K [note=...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"
# shellcheck source=lib-outcomes.sh
. "$SCRIPT_DIR/lib-outcomes.sh"

usage() {
  printf '%s\n' 'Usage: leg-check.sh --repo DIR --base REF [--allow-paths GLOBS] [--verify-cmd CMD] [--verify-pattern ERE] [--verify-timeout SECONDS] [--final FILE] [--out PATH]... [--task ID] [--cycle N] [--tier T] [--provider P] [--model M] [--effort E]'
}

repo_dir=""
base_ref=""
allow_paths=""
allow_set=0
verify_cmd=""
verify_set=0
verify_pattern=""
pattern_set=0
verify_timeout=900
final_file=""
outs=()
task=""
cycle=""
tier=""
provider=""
model=""
effort=""
while [ "$#" -gt 0 ]; do
  case "$1" in -h|--help) usage; exit 0 ;; esac
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  case "$1" in
    --repo) repo_dir="$2" ;;
    --base) base_ref="$2" ;;
    --allow-paths) allow_paths="$2"; allow_set=1 ;;
    --verify-cmd) verify_cmd="$2"; verify_set=1 ;;
    --verify-pattern) verify_pattern="$2"; pattern_set=1 ;;
    --verify-timeout) verify_timeout="$2" ;;
    --final) final_file="$2" ;;
    --out) outs+=("$2") ;;
    --task) task="$2" ;;
    --cycle) cycle="$2" ;;
    --tier) tier="$2" ;;
    --provider) provider="$2" ;;
    --model) model="$2" ;;
    --effort) effort="$2" ;;
    *) printf 'leg-check: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift 2
done

usage_error() { printf 'leg-check: %s\n' "$1" >&2; exit 2; }
[ -n "$repo_dir" ] && [ -n "$base_ref" ] || usage_error '--repo and --base are required'
case "$base_ref" in -*) usage_error "--base must be a revision, not an option: $base_ref" ;; esac
[[ "$verify_timeout" =~ ^[1-9][0-9]*$ ]] || usage_error '--verify-timeout must be a positive integer'
[ -z "$cycle" ] || [[ "$cycle" =~ ^[0-9]+$ ]] || usage_error '--cycle must be a non-negative integer'
[ "$verify_set" -eq 0 ] || [ -n "${verify_cmd//[[:space:]]/}" ] || usage_error '--verify-cmd is empty'
if [ "$pattern_set" -eq 1 ]; then
  [ "$verify_set" -eq 1 ] || usage_error '--verify-pattern needs --verify-cmd'
  [ -n "$verify_pattern" ] || usage_error '--verify-pattern is empty'
  rc=0; grep -Eq -- "$verify_pattern" /dev/null 2>/dev/null || rc=$?
  [ "$rc" -le 1 ] || usage_error "invalid --verify-pattern: $verify_pattern"
fi
globs=()
if [ "$allow_set" -eq 1 ]; then
  IFS=',' read -r -a raw_globs <<< "$allow_paths"
  for glob in ${raw_globs[@]+"${raw_globs[@]}"}; do
    glob="${glob#"${glob%%[![:space:]]*}"}"
    glob="${glob%"${glob##*[![:space:]]}"}"
    glob="${glob#./}"
    [ -z "$glob" ] || globs+=("$glob")
  done
  [ "${#globs[@]}" -gt 0 ] || usage_error '--allow-paths names no glob'
fi
for tool in git timeout; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'leg-check: %s not found\n' "$tool" >&2; exit 127; }
done
repo_dir="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)" || usage_error "not a git repository: $repo_dir"
git -C "$repo_dir" rev-parse --verify -q "$base_ref^{commit}" >/dev/null || usage_error "invalid base ref: $base_ref"

started=$SECONDS
mmo_out_spec "$repo_dir" ${outs[@]+"${outs[@]}"}
changed=()
while IFS= read -r -d '' path; do changed+=("$path"); done < <(
  git -C "$repo_dir" diff --no-ext-diff --no-relative --no-renames --name-only -z "$base_ref" -- "${mmo_spec[@]}"
  git -C "$repo_dir" ls-files -z --others --exclude-standard -- "${mmo_spec[@]}"
)

note=""
if [ -n "$final_file" ] && [ -r "$final_file" ] &&
   tail -n 15 -- "$final_file" | grep -Eiq "want me to|would you like me to|\bshall i\b|\bshould i (continue|proceed)\b|let me know if you"; then
  note=asks-to-continue
fi

check=pass
rc=0
detail=""
if [ "${#changed[@]}" -eq 0 ]; then
  check=no_change; rc=10
elif [ "${#globs[@]}" -gt 0 ]; then
  outside=()
  for path in "${changed[@]}"; do
    for glob in "${globs[@]}"; do
      # Unquoted on purpose: the glob is a pattern.
      if [[ "$glob" == */ ]]; then
        [[ "$path" == $glob* ]] && continue 2
      else
        [[ "$path" == $glob ]] && continue 2
      fi
    done
    outside+=("$path")
  done
  if [ "${#outside[@]}" -gt 0 ]; then
    check=scope; rc=8; detail="${outside[0]}"
    printf 'leg-check: changed outside --allow-paths: %s\n' "${outside[@]:0:20}" >&2
    [ "${#outside[@]}" -le 20 ] || printf 'leg-check: ... and %s more\n' "$(( ${#outside[@]} - 20 ))" >&2
  fi
fi
if [ "$rc" -eq 0 ] && [ "$verify_set" -eq 1 ]; then
  verify_out="$(mktemp)"
  trap 'rm -f "$verify_out"' EXIT
  verify_started=$SECONDS
  verify_rc=0
  (cd "$repo_dir" && exec timeout -k 10 "$verify_timeout" bash -c "$verify_cmd") < /dev/null > "$verify_out" 2>&1 || verify_rc=$?
  if [ "$verify_rc" -eq 124 ] || { [ "$verify_rc" -eq 137 ] && [ $((SECONDS - verify_started)) -ge "$verify_timeout" ]; }; then
    check=verify; rc=9; detail=verify-timeout
    printf 'leg-check: --verify-cmd timed out after %ss\n' "$verify_timeout" >&2
  elif [ "$verify_rc" -ne 0 ]; then
    check=verify; rc=9; detail="verify-exit=$verify_rc"
    printf 'leg-check: --verify-cmd exited %s\n' "$verify_rc" >&2
  elif [ "$pattern_set" -eq 1 ] && ! grep -Eq -- "$verify_pattern" "$verify_out"; then
    check=verify; rc=9; detail=verify-pattern
    printf 'leg-check: --verify-cmd output does not match --verify-pattern %s\n' "$verify_pattern" >&2
  fi
  [ "$rc" -eq 0 ] || tail -n 20 -- "$verify_out" >&2
fi
[ -n "$detail" ] || detail="$note"

mmo_tsv_append "${MMO_LEG_CHECKS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator/leg-checks.tsv}" \
  $'utc_time\trepo\ttask\tcycle\ttier\tprovider\tmodel\teffort\tcheck\tdetail\thead_sha\tchanged_paths\tduration_seconds' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(mmo_repo_name "$repo_dir")" "$task" "$cycle" "$tier" "$provider" \
  "$model" "$effort" "$check" "$detail" "$(git -C "$repo_dir" rev-parse -q --verify HEAD 2>/dev/null || :)" \
  "${#changed[@]}" "$((SECONDS - started))"

printf 'leg-check: exit=%s check=%s paths=%s%s\n' "$rc" "$check" "${#changed[@]}" "${note:+ note=$note}" >&2
exit "$rc"
