#!/usr/bin/env bash
# leg-check.sh — deterministic acceptance checks for one implement leg, recorded per call.
#
#   leg-check.sh --repo DIR --base REF [--baseline FILE] [--allow-paths GLOBS] [--verify-cmd CMD]
#                [--verify-pattern ERE] [--verify-timeout SECONDS] [--final FILE] [--out PATH]...
#                [--task ID] [--cycle N] [--tier T] [--provider P] [--model M] [--effort E]
#   leg-check.sh --snapshot FILE --repo DIR [--out PATH]...   before dispatch (pool.sh does this)
#   leg-check.sh --validate [contract flags]                  parse and validate only: exit 0 or 2
#
# REF is the commit the leg started from. The leg outputs (--out and the runner files beside it)
# never count. Without --baseline, the changed paths are every path whose index or working-tree
# content differs from REF plus untracked, non-ignored files. With --baseline (a --snapshot of each
# dirty or untracked path's index and working-tree state, taken before dispatch), they are the
# paths changed by commits since REF, dirty or untracked paths absent from the snapshot or in
# another state, and snapshot paths whose state changed (a reverted one included), so edits that
# predate the leg do not count. Submodule changes count. Checks, first failure wins:
#   no_change  exit 10  nothing changed
#   scope      exit 8   a changed path matches none of the comma-separated --allow-paths globs
#                       ([[ path == glob ]], so * crosses /; a glob ending in / is that directory)
#   verify     exit 9   --verify-cmd (bash -c in the repo under timeout, default 900 s, in the
#                       scrubbed leg environment: a test that needs a variable gets it through
#                       MMO_LEG_ENV) failed or timed out, or its combined output does not match
#                       --verify-pattern (a test runner that exits 0 having run nothing). After a
#                       passing verify the paths are enumerated again and no_change/scope re-run,
#                       so a test that writes outside the allow-list cannot pass.
#   pass       exit 0
#   error      exit 11  the check could not run (a git command failed); never a pass
# Advisory, never changes the exit: when the last 15 lines of --final (the worker's final message)
# ask to continue ("want me to", "would you like me to", "shall I", "should I continue|proceed",
# "let me know if you"; case-insensitive), the result line adds note=asks-to-continue.
# Exit 2: usage error, invalid REF or unreadable --baseline (no row is recorded).
#
# Each check appends one row to ${MMO_LEG_CHECKS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/
# multi-model-orchestrator/leg-checks.tsv}; a write failure never changes the exit status.
# Last stderr line: leg-check: exit=N check=<pass|no_change|scope|verify|error> paths=K [note=...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-verdict.sh
. "$SCRIPT_DIR/lib-review-verdict.sh"
# shellcheck source=lib-outcomes.sh
. "$SCRIPT_DIR/lib-outcomes.sh"

usage() {
  printf '%s\n' 'Usage: leg-check.sh --repo DIR --base REF [--baseline FILE] [--allow-paths GLOBS] [--verify-cmd CMD] [--verify-pattern ERE] [--verify-timeout SECONDS] [--final FILE] [--out PATH]... [--task ID] [--cycle N] [--tier T] [--provider P] [--model M] [--effort E]'
  printf '%s\n' '       leg-check.sh --snapshot FILE --repo DIR [--out PATH]...'
  printf '%s\n' '       leg-check.sh --validate [--allow-paths GLOBS] [--verify-cmd CMD] [--verify-pattern ERE] [--verify-timeout SECONDS] [--task ID] [--cycle N]'
}

action=check
repo_dir=""
base_ref=""
baseline=""
snapshot=""
verify_timeout=900
final_file=""
outs=()
task=""
cycle=""
tier=""
provider=""
model=""
effort=""
declare -A given=()
declare -A value=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --validate) action=validate; shift; continue ;;
  esac
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  case "$1" in
    --repo) repo_dir="$2" ;;
    --base) base_ref="$2" ;;
    --baseline) baseline="$2" ;;
    --snapshot) snapshot="$2"; action=snapshot ;;
    --allow-paths|--verify-cmd|--verify-pattern|--task|--cycle) given[$1]=1; value[$1]="$2" ;;
    --verify-timeout) verify_timeout="$2" ;;
    --final) final_file="$2" ;;
    --out) outs+=("$2") ;;
    --tier) tier="$2" ;;
    --provider) provider="$2" ;;
    --model) model="$2" ;;
    --effort) effort="$2" ;;
    *) printf 'leg-check: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift 2
done
task="${value[--task]:-}"
cycle="${value[--cycle]:-}"
verify_cmd="${value[--verify-cmd]:-}"
verify_pattern="${value[--verify-pattern]:-}"

usage_error() { printf 'leg-check: %s\n' "$1" >&2; exit 2; }

# The contract: one validation for leg-check and for pool.sh's pre-dispatch --validate.
for flag in "${!given[@]}"; do
  [ -n "${value[$flag]//[[:space:]]/}" ] || usage_error "$flag is empty"
done
[[ "$verify_timeout" =~ ^[1-9][0-9]*$ ]] || usage_error '--verify-timeout must be a positive integer'
[ -z "${given[--cycle]:-}" ] || [[ "$cycle" =~ ^[0-9]+$ ]] || usage_error '--cycle must be a non-negative integer'
if [ -n "${given[--verify-pattern]:-}" ]; then
  [ -n "${given[--verify-cmd]:-}" ] || usage_error '--verify-pattern needs --verify-cmd'
  rc=0; grep -Eq -- "$verify_pattern" /dev/null 2>/dev/null || rc=$?
  [ "$rc" -le 1 ] || usage_error "invalid --verify-pattern: $verify_pattern"
fi
if [ -n "${given[--verify-cmd]:-}" ]; then
  read -r -a leg_env_names <<< "${MMO_LEG_ENV:-}"
  for name in ${leg_env_names[@]+"${leg_env_names[@]}"}; do
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*\*?$ ]] || usage_error "invalid MMO_LEG_ENV name: $name"
  done
fi
globs=()
if [ -n "${given[--allow-paths]:-}" ]; then
  case "${value[--allow-paths]}" in *$'\n'*|*$'\r'*) usage_error '--allow-paths must not contain a newline' ;; esac
  IFS=',' read -r -a raw_globs <<< "${value[--allow-paths]}"
  for glob in ${raw_globs[@]+"${raw_globs[@]}"}; do
    glob="${glob#"${glob%%[![:space:]]*}"}"
    glob="${glob%"${glob##*[![:space:]]}"}"
    glob="${glob#./}"
    [ -z "$glob" ] || globs+=("$glob")
  done
  [ "${#globs[@]}" -gt 0 ] || usage_error '--allow-paths names no glob'
fi
[ "$action" != validate ] || exit 0

[ -n "$repo_dir" ] || usage_error '--repo is required'
if [ "$action" = check ]; then
  [ -n "$base_ref" ] || usage_error '--base is required'
  case "$base_ref" in -*) usage_error "--base must be a revision, not an option: $base_ref" ;; esac
  [ -z "$baseline" ] || [ -r "$baseline" ] || usage_error "cannot read --baseline $baseline"
fi
for tool in git timeout cksum; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'leg-check: %s not found\n' "$tool" >&2; exit 127; }
done
repo_dir="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)" || usage_error "not a git repository: $repo_dir"
if [ "$action" = check ]; then
  git -C "$repo_dir" rev-parse --verify -q "$base_ref^{commit}" >/dev/null || usage_error "invalid base ref: $base_ref"
fi

started=$SECONDS
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mmo_out_spec "$repo_dir" ${outs[@]+"${outs[@]}"}
check=pass
rc=0
detail=""
note=""
changed=()

finish() {
  [ -n "$detail" ] || detail="$note"
  mmo_tsv_append "${MMO_LEG_CHECKS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator/leg-checks.tsv}" \
    $'utc_time\trepo\ttask\tcycle\ttier\tprovider\tmodel\teffort\tcheck\tdetail\thead_sha\tchanged_paths\tduration_seconds' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(mmo_repo_name "$repo_dir")" "$task" "$cycle" "$tier" "$provider" \
    "$model" "$effort" "$check" "$detail" "$(git -C "$repo_dir" rev-parse -q --verify HEAD 2>/dev/null || :)" \
    "${#changed[@]}" "$((SECONDS - started))"
  printf 'leg-check: exit=%s check=%s paths=%s%s\n' "$rc" "$check" "${#changed[@]}" "${note:+ note=$note}" >&2
  exit "$rc"
}

# A git failure while enumerating must never look like a clean tree.
cannot_run() {
  printf 'leg-check: cannot enumerate changes: %s\n' "$1" >&2
  [ ! -s "$tmp/git.err" ] || tail -n 5 "$tmp/git.err" >&2
  [ "$action" = check ] || exit 11
  check=error; rc=11; detail="$1"
  finish
}

git_to() {  # git_to FILE GIT-ARGS...  (NUL-separated paths, status checked)
  local out="$1"
  shift
  git -C "$repo_dir" "$@" > "$out" 2>> "$tmp/git.err" || cannot_run "git $1"
}

read_paths() {  # read_paths FILE  -> array zpaths
  zpaths=()
  local p
  while IFS= read -r -d '' p; do zpaths+=("$p"); done < "$1"
}

diff_names=(diff --no-ext-diff --no-relative --no-renames --ignore-submodules=none --name-only -z)

# Paths whose index or working tree differs from HEAD, plus untracked ones -> array zpaths.
dirty_paths() {
  local -A seen=()
  local -a all=()
  local p f
  git_to "$tmp/wt" "${diff_names[@]}" HEAD -- "${mmo_spec[@]}"
  git_to "$tmp/ix" "${diff_names[@]}" --cached HEAD -- "${mmo_spec[@]}"
  git_to "$tmp/un" ls-files -z --others --exclude-standard -- "${mmo_spec[@]}"
  for f in wt ix un; do
    read_paths "$tmp/$f"
    for p in ${zpaths[@]+"${zpaths[@]}"}; do
      [ -n "${seen[$p]+x}" ] || { seen[$p]=1; all+=("$p"); }
    done
  done
  zpaths=(${all[@]+"${all[@]}"})
}

# Index entry plus working-tree content of one path -> variable state.
path_state() {
  local p="$1" full="$repo_dir/$1" index tree
  index="$(git -C "$repo_dir" ls-files -s -- ":(literal)$p" 2>> "$tmp/git.err")" || cannot_run "git ls-files $p"
  if [ -L "$full" ]; then
    tree="link:$(readlink -- "$full")"
  elif [ -d "$full" ]; then
    tree="$(git -C "$full" rev-parse -q --verify HEAD 2>/dev/null)" || tree=""
    tree="dir:$tree:$(git -C "$full" status --porcelain=v1 --untracked-files=all 2>> "$tmp/git.err" | cksum)" \
      || cannot_run "git status $p"
  elif [ -f "$full" ]; then
    tree="file:$([ ! -x "$full" ] || printf x):$(cksum < "$full")" || cannot_run "cannot read $p"
  elif [ -e "$full" ]; then
    tree=other
  else
    tree=missing
  fi
  state="$index"$'\n'"$tree"
}

if [ "$action" = snapshot ]; then
  dirty_paths
  : > "$tmp/snapshot"
  for p in ${zpaths[@]+"${zpaths[@]}"}; do
    path_state "$p"
    printf '%s\0%s\0' "$p" "$state" >> "$tmp/snapshot"
  done
  cp -- "$tmp/snapshot" "$snapshot" || { printf 'leg-check: cannot write snapshot %s\n' "$snapshot" >&2; exit 11; }
  exit 0
fi

declare -A base_state=()
if [ -n "$baseline" ]; then
  while IFS= read -r -d '' p && IFS= read -r -d '' s; do base_state[$p]="$s"; done < "$baseline"
fi

# Changed paths for this leg -> array changed.
enumerate() {
  local -A seen=()
  local p f
  changed=()
  if [ -z "$baseline" ]; then
    git_to "$tmp/c1" "${diff_names[@]}" "$base_ref" -- "${mmo_spec[@]}"
    git_to "$tmp/c2" "${diff_names[@]}" --cached "$base_ref" -- "${mmo_spec[@]}"
    git_to "$tmp/c3" ls-files -z --others --exclude-standard -- "${mmo_spec[@]}"
    for f in c1 c2 c3; do
      read_paths "$tmp/$f"
      for p in ${zpaths[@]+"${zpaths[@]}"}; do
        [ -n "${seen[$p]+x}" ] || { seen[$p]=1; changed+=("$p"); }
      done
    done
    return 0
  fi
  git_to "$tmp/c1" "${diff_names[@]}" "$base_ref" HEAD -- "${mmo_spec[@]}"
  read_paths "$tmp/c1"
  for p in ${zpaths[@]+"${zpaths[@]}"}; do
    [ -n "${seen[$p]+x}" ] || { seen[$p]=1; changed+=("$p"); }
  done
  local -A dirty=()
  dirty_paths
  for p in ${zpaths[@]+"${zpaths[@]}"}; do
    dirty[$p]=1
    path_state "$p"
    [ -z "${base_state[$p]+x}" ] || [ "${base_state[$p]}" != "$state" ] || continue
    [ -n "${seen[$p]+x}" ] || { seen[$p]=1; changed+=("$p"); }
  done
  # A snapshot path that is clean now was reverted or committed: its state changed.
  for p in "${!base_state[@]}"; do
    [ -z "${dirty[$p]+x}" ] || continue
    [ -n "${seen[$p]+x}" ] || { seen[$p]=1; changed+=("$p"); }
  done
}

# no_change and scope over array changed; sets check/rc/detail on failure.
judge_paths() {
  local path glob
  local -a outside=()
  if [ "${#changed[@]}" -eq 0 ]; then
    check=no_change; rc=10; detail=""
    return 0
  fi
  [ "${#globs[@]}" -gt 0 ] || return 0
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
  [ "${#outside[@]}" -gt 0 ] || return 0
  check=scope; rc=8; detail="${outside[0]}"
  printf 'leg-check: changed outside --allow-paths: %s\n' "${outside[@]:0:20}" >&2
  [ "${#outside[@]}" -le 20 ] || printf 'leg-check: ... and %s more\n' "$(( ${#outside[@]} - 20 ))" >&2
}

if [ -n "$final_file" ] && [ -r "$final_file" ] &&
   tail -n 15 -- "$final_file" | grep -Eiq "want me to|would you like me to|\bshall i\b|\bshould i (continue|proceed)\b|let me know if you"; then
  note=asks-to-continue
fi

enumerate
judge_paths
if [ "$rc" -eq 0 ] && [ -n "${given[--verify-cmd]:-}" ]; then
  verify_started=$SECONDS
  verify_rc=0
  # The command runs repository code the worker just edited: same scrubbed environment as a leg.
  (cd "$repo_dir" && mmo_leg_env -- timeout -k 10 "$verify_timeout" bash -c "$verify_cmd") \
    < /dev/null > "$tmp/verify.out" 2>&1 || verify_rc=$?
  if { [ "$verify_rc" -eq 124 ] || [ "$verify_rc" -eq 137 ]; } && [ $((SECONDS - verify_started)) -ge "$verify_timeout" ]; then
    check=verify; rc=9; detail=verify-timeout
    printf 'leg-check: --verify-cmd timed out after %ss\n' "$verify_timeout" >&2
  elif [ "$verify_rc" -ne 0 ]; then
    check=verify; rc=9; detail="verify-exit=$verify_rc"
    printf 'leg-check: --verify-cmd exited %s\n' "$verify_rc" >&2
  elif [ -n "${given[--verify-pattern]:-}" ] && ! grep -Eq -- "$verify_pattern" "$tmp/verify.out"; then
    check=verify; rc=9; detail=verify-pattern
    printf 'leg-check: --verify-cmd output does not match --verify-pattern %s\n' "$verify_pattern" >&2
  fi
  if [ "$rc" -ne 0 ]; then
    tail -n 20 -- "$tmp/verify.out" >&2
  else
    # The test itself may have written to the tree.
    enumerate
    judge_paths
  fi
fi
finish
