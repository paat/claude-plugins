#!/usr/bin/env bash
# Collect and seal merge-gate tribunal evidence. Provider output is advisory;
# this runner owns provider identity, repository/PR binding, and artifact hashes.
set -euo pipefail
umask 077
export LC_ALL=C GIT_NO_REPLACE_OBJECTS=1
unset BASH_ENV ENV CDPATH GLOBIGNORE
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_SSH_COMMAND

for command_name in git gh jq sha256sum awk sed wc date mktemp chmod mkdir mv rm rmdir cat dirname basename tr pwd env bash printf timeout head cp cmp stat setsid unshare ps kill codex agy dsh qwen grok muse claude; do
  unset -f "$command_name" 2>/dev/null || true
done
unset command_name

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# Load git-surface hardening first so `git()` covers library helpers and traps.
# shellcheck source=collector-git-surface.sh
. "$SCRIPT_DIR/collector-git-surface.sh"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=collector-containment.sh
. "$SCRIPT_DIR/collector-containment.sh"
# shellcheck source=collector-validate.sh
. "$SCRIPT_DIR/collector-validate.sh"
# shellcheck source=collector-proof.sh
. "$SCRIPT_DIR/collector-proof.sh"

SCHEMA_COLLECTION="tribunal-collection/v1"
SCHEMA_PROOF="tribunal-proof/v1"
PROVIDERS="codex gemini deepseek qwen grok muse claude"
STAGING=""
REVIEW_SOURCE=""
REVIEW_WORKTREES=()
REVIEW_PIDS=()
REVIEW_NAMES=()
CONTAINMENT=session
declare -A LEG_CONTAINMENT=() NAMESPACE_PIDS=()
CONFIG_FILE=""
CONFIG_SNAPSHOT=""
SAFE_DIRECTORY_COUNT=0
SAFE_DIRECTORY_ENV=()
SURFACE_ROOT=""
SURFACE_GITDIR=""
SURFACE_COMMON=""
SURFACE_ID=""
SURFACE_KIND=""
SURFACE_GITDIR_ID=""
SURFACE_COMMON_ID=""
SURFACE_STATE=""
SURFACE_SNAPSHOTS=""
SURFACE_FAILED=0
SURFACE_PINNED=0
VERIFIED_COLLECTION=""
FINAL_TMP1=""
FINAL_TMP2=""

die() { printf 'tribunal evidence: %s\n' "$*" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha_file() { sha256sum -- "$1" | awk '{print $1}'; }
bytes_file() { wc -c < "$1" | tr -d ' '; }
real_dir() {
  [ -d "$1" ] || die "directory not found: $1"
  (cd "$1" && pwd -P)
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

require_tools() {
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )) \
    || die "bash 4.3+ is required for wait -n"
  local tool
  for tool in git gh jq sha256sum awk sed wc date mktemp chmod cmp stat flock setsid ps timeout; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
  done
}

require_git_version() {
  local version
  version="$(command git --version)"
  [[ "$version" =~ ^git\ version\ ([0-9]+)\.([0-9]+) ]] \
    && (( BASH_REMATCH[1] > 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] >= 42) )) \
    || die "git 2.42+ is required for --attr-source and cat-file -Z (found: $version)"
}

collect() {
  # Crashing legs must not leave core files in their sealed review worktrees.
  ulimit -c 0 || true
  set +m
  local root="" pr="" output="" started binding head_oid base_oid parent review_tmp bundle
  local wrapper name rc provider status artifact stderr wrapper_name providers_json ignored_paths_json deleted_paths_json
  local mutation_gate_json sensitive_paths sensitive_paths_sha256="" source line path content
  local codex_worktree gemini_worktree deepseek_worktree qwen_worktree grok_worktree muse_worktree claude_worktree review_worktree
  local min_ok_legs panel_size panel_json backup_legs backups backup backup_worktree_var limited ok_count missing_ok needed grok_recovery
  local prior_rejections="" prior_rejections_sha256=""
  local -x TRIBUNAL_PRIOR_REJECTIONS_FILE=""
  local -A mutation_errors=() review_gitdirs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo-root) [ "$#" -ge 2 ] || die "--repo-root needs a value"; root="$2"; shift 2 ;;
      --pr) [ "$#" -ge 2 ] || die "--pr needs a value"; pr="$2"; shift 2 ;;
      --output) [ "$#" -ge 2 ] || die "--output needs a value"; output="$2"; shift 2 ;;
      --prior-rejections) [ "$#" -ge 2 ] && [ -n "$2" ] || die "--prior-rejections needs a value"; prior_rejections="$2"; shift 2 ;;
      *) die "unknown collect argument: $1" ;;
    esac
  done
  [ -n "$root" ] && [ -n "$pr" ] && [ -n "$output" ] || die "collect requires --repo-root, --pr, and --output"
  case "$pr" in ''|*[!0-9]*|0) die "invalid PR number" ;; esac
  # Fail closed on an invalid floor before any provider leg runs (issue #519).
  min_ok_legs="$(tribunal_min_ok_legs)" || exit 1
  grok_recovery="${TRIBUNAL_GROK_RECOVERY:-permit}"
  case "$grok_recovery" in
    permit|reject) ;;
    *) die "invalid TRIBUNAL_GROK_RECOVERY: $grok_recovery (allowed: permit, reject)" ;;
  esac
  tribunal_select_panel || exit 1
  panel_size="$TRIBUNAL_SELECTED_PANEL_SIZE"
  panel_json="$TRIBUNAL_SELECTED_PANEL_JSON"
  backup_legs="$TRIBUNAL_SELECTED_BACKUPS"
  root="$(real_dir "$root")"
  SURFACE_ROOT="$root"
  load_safe_directories
  require_git_version
  [ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" = "$root" ] || die "--repo-root is not a Git worktree root"
  pin_git_surface
  reject_uncontained_config "$root"
  case "$output" in /*) ;; *) die "--output must be absolute" ;; esac
  [ ! -e "$output" ] && [ ! -L "$output" ] || die "collection output already exists"
  parent="$(dirname "$output")"; parent="$(real_dir "$parent")"
  case "$(basename "$output")" in .|..) die "invalid collection output name" ;; esac
  output="$parent/$(basename "$output")"
  [ ! -e "$output" ] && [ ! -L "$output" ] || die "collection output already exists"
  bundle="$(bash "$SCRIPT_DIR/check-runner-bundle.sh")" || die "installed tribunal runner bundle failed integrity validation"
  started="$(now)"
  binding="$(live_binding "$root" "$pr")"
  head_oid="$(printf '%s' "$binding" | jq -r .pull_request.headRefOid)"
  base_oid="$(printf '%s' "$binding" | jq -r .pull_request.baseRefOid)"
  [ "$(git -C "$root" rev-parse HEAD)" = "$head_oid" ] || die "worktree HEAD differs from PR head"
  git -C "$root" cat-file -e "$base_oid^{commit}" 2>/dev/null || die "PR base commit is not available locally"
  git -C "$root" cat-file -e "$head_oid^{commit}" 2>/dev/null || die "PR head commit is not available locally"

  STAGING="$(mktemp -d "$parent/.tribunal-collection.XXXXXX")"
  mkdir -p "$STAGING/providers" "$STAGING/wrappers"
  if [ -n "$prior_rejections" ]; then
    [ -f "$prior_rejections" ] || die "prior-rejections input is not a regular file"
    cp -- "$prior_rejections" "$STAGING/prior-rejections.json"
    validate_prior_rejections "$STAGING/prior-rejections.json" || die "prior-rejections input schema invalid"
    prior_rejections_sha256="$(sha_file "$STAGING/prior-rejections.json")"
    chmod 0400 "$STAGING/prior-rejections.json"
    TRIBUNAL_PRIOR_REJECTIONS_FILE="$STAGING/prior-rejections.json"
  fi
  printf '%s' "$binding" | jq -j .pull_request.body > "$STAGING/pr-body.txt"
  git -C "$root" diff --binary --no-ext-diff --no-textconv "$base_oid...$head_oid" > "$STAGING/review.diff"
  [ -s "$STAGING/review.diff" ] || die "PR has no diff"
  ignored_paths_json="$(cd "$root" && tribunal_ignored_additions "$base_oid")"
  if [ "$(printf '%s' "$ignored_paths_json" | jq 'length')" -gt 0 ]; then
    printf '%s' "$ignored_paths_json" | jq -S . > "$STAGING/ignored-paths.json"
    validate_ignored_paths "$STAGING/ignored-paths.json" || die "internal ignored-path evidence is invalid"
    sensitive_paths="[]"
    while IFS=$'\t' read -r source line path; do
      content="$(git -C "$root" show "$head_oid:$source")" || die "cannot read ignored-path policy: $source"
      if printf '%s\n' "$content" | sed -n "1,${line}p" | awk -v line="$line" '
        NR >= line { exit }
        /^[[:space:]]*#/ {
          if (tolower($0) ~ /(^|[^[:alnum:]])(secrets?|pii|credentials?|keys?)([^[:alnum:]]|$)/ \
              || tolower($0) ~ /(^|[^[:alnum:]])never[[:space:]]+commit([^[:alnum:]]|$)/) sensitive=1
          next
        }
        /^[[:space:]]*$/ { sensitive=0 }
        END { exit !sensitive }
      '; then
        sensitive_paths="$(jq -c --arg path "$path" '. + [$path]' <<<"$sensitive_paths")"
      fi
    done < <(jq -r '.[] | [.source, (.line | tostring), .path] | @tsv' "$STAGING/ignored-paths.json")
    printf '%s' "$sensitive_paths" | jq -S . > "$STAGING/sensitive-paths.json"
    sensitive_paths_sha256="$(sha_file "$STAGING/sensitive-paths.json")"
  fi
  deleted_paths_json="$(cd "$root" && tribunal_deleted_policy_paths "$base_oid")"
  if [ "$(printf '%s' "$deleted_paths_json" | jq 'length')" -gt 0 ]; then
    printf '%s' "$deleted_paths_json" | jq -S . > "$STAGING/deleted-paths.json"
    validate_deleted_paths "$STAGING/deleted-paths.json" || die "internal deleted-path evidence is invalid"
  fi
  mutation_gate_json="$(cd "$root" && tribunal_mutation_gate "$base_oid" "$head_oid")"
  if [ "$(printf '%s' "$mutation_gate_json" | jq 'length')" -gt 0 ]; then
    printf '%s' "$mutation_gate_json" | jq -S . > "$STAGING/mutation-gate.json"
    validate_mutation_gate "$STAGING/mutation-gate.json" || die "internal mutation-gate evidence is invalid"
  fi

  REVIEW_SOURCE="$root"; REVIEW_WORKTREES=()
  for name in codex gemini deepseek qwen grok muse claude; do
    review_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tribunal-$name.XXXXXX")"; rmdir "$review_tmp"
    git -C "$root" worktree add --detach --quiet "$review_tmp" "$head_oid"
    review_tmp="$(real_dir "$review_tmp")"
    REVIEW_WORKTREES+=("$review_tmp")
    # Pin the admin directory, including its worktree id, before any reviewer runs.
    review_gitdirs["$review_tmp"]="$(real_dir "$(git -C "$review_tmp" rev-parse --absolute-git-dir)")"
    case "$name" in
      codex) codex_worktree="$review_tmp" ;;
      gemini) gemini_worktree="$review_tmp" ;;
      deepseek) deepseek_worktree="$review_tmp" ;;
      qwen) qwen_worktree="$review_tmp" ;;
      grok) grok_worktree="$review_tmp" ;;
      muse) muse_worktree="$review_tmp" ;;
      claude) claude_worktree="$review_tmp" ;;
    esac
  done

  probe_containment
  run_wrapper codex "$SCRIPT_DIR/run-codex-review.sh" "$codex_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper gemini "$SCRIPT_DIR/run-gemini-review.sh" "$gemini_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper deepseek "$SCRIPT_DIR/run-deepseek-review.sh" "$deepseek_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper qwen "$SCRIPT_DIR/run-qwen-review.sh" "$qwen_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper grok "$SCRIPT_DIR/run-grok-review.sh" "$grok_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper muse "$SCRIPT_DIR/run-muse-review.sh" "$muse_worktree" "$base_oid" "$STAGING/wrappers"
  run_wrapper claude "$SCRIPT_DIR/run-claude-review.sh" "$claude_worktree" "$base_oid" "$STAGING/wrappers"
  wait_wrappers

  for name in $PROVIDERS; do
    rc="$(cat "$STAGING/wrappers/$name.exit")"
    normalize_single "$name" "$STAGING/wrappers/$name.raw" "$rc" "$STAGING/providers/$name.json" \
      "$base_oid" "$head_oid" "$grok_recovery"
  done
  fail_mutated_providers "$head_oid" "$STAGING"

  # Run idle installed backups for plan-limited legs and when ok legs fall below min_ok_legs.
  # Original failed legs stay failed.
  limited=0
  ok_count=0
  for provider in $PROVIDERS; do
    status="$(provider_status "$STAGING/providers/$provider.json")"
    if [ "$status" = ok ]; then
      ok_count=$((ok_count + 1))
    fi
    if jq -e '(.error // "") | startswith("plan limit:")' "$STAGING/providers/$provider.json" >/dev/null; then
      limited=$((limited + 1))
    fi
  done
  missing_ok=0
  if [ "$ok_count" -lt "$min_ok_legs" ]; then
    missing_ok=$((min_ok_legs - ok_count))
  fi
  needed="$limited"
  if [ "$missing_ok" -gt "$needed" ]; then
    needed="$missing_ok"
  fi
  backups=""
  for backup in $backup_legs; do
    [ "$needed" -gt 0 ] || break
    [ "$(provider_status "$STAGING/providers/$backup.json")" = disabled ] || continue
    tribunal_backup_installed "$backup" || continue
    backups="$backups $backup "; needed=$((needed - 1))
  done
  if [ -n "$backups" ]; then
    if [ "$limited" -gt 0 ]; then
      printf 'tribunal evidence: running backup legs for plan-limited legs:%s\n' "$backups" >&2
    else
      printf 'tribunal evidence: running backup legs for quorum:%s\n' "$backups" >&2
    fi
    for backup in $backups; do
      backup_worktree_var="${backup}_worktree"
      export "TRIBUNAL_${backup^^}=on"
      run_wrapper "$backup" "$(wrapper_for_provider "$backup")" "${!backup_worktree_var}" "$base_oid" "$STAGING/wrappers"
    done
    wait_wrappers
    for backup in $backups; do
      normalize_single "$backup" "$STAGING/wrappers/$backup.raw" "$(cat "$STAGING/wrappers/$backup.exit")" \
          "$STAGING/providers/$backup.json" "$base_oid" "$head_oid" "$grok_recovery"
    done
    fail_mutated_providers "$head_oid" "$STAGING"
  fi
  providers_json="$STAGING/providers.jsonl"; : > "$providers_json"
  for provider in $PROVIDERS; do
    artifact="$STAGING/providers/$provider.json"
    validate_provider "$provider" "$artifact" "$base_oid" "$head_oid" \
      || die "internal provider normalization failed: $provider"
    wrapper="$(wrapper_for_provider "$provider")"; wrapper_name="$(basename "$wrapper" .sh)"
    wrapper_name="${wrapper_name#run-}"
    name="$provider"
    status="$(provider_status "$artifact")"
    stderr="$STAGING/wrappers/$name.stderr"
    jq -nc --arg provider "$provider" --arg status "$status" --arg containment "${LEG_CONTAINMENT[$provider]}" \
      --arg wrapper_path "$wrapper" --arg wrapper_sha256 "$(sha_file "$wrapper")" \
      --arg artifact_path "providers/$provider.json" --arg artifact_sha256 "$(sha_file "$artifact")" \
      --argjson artifact_bytes "$(bytes_file "$artifact")" \
      --arg started_at "$(cat "$STAGING/wrappers/$name.started")" \
      --arg finished_at "$(cat "$STAGING/wrappers/$name.finished")" \
      --argjson exit_code "$(cat "$STAGING/wrappers/$name.exit")" \
      --arg stderr_sha256 "$(sha_file "$stderr")" --argjson stderr_bytes "$(bytes_file "$stderr")" \
      '{provider:$provider,status:$status,containment:$containment,wrapper:{path:$wrapper_path,sha256:$wrapper_sha256},
        artifact:{path:$artifact_path,sha256:$artifact_sha256,bytes:$artifact_bytes},
        started_at:$started_at,finished_at:$finished_at,exit_code:$exit_code,
        stderr:{sha256:$stderr_sha256,bytes:$stderr_bytes}}' >> "$providers_json"
  done

  rm -rf "$STAGING/wrappers"
  for review_worktree in "${REVIEW_WORKTREES[@]}"; do
    # A leg may delete its .git file; remove that disposable directory before deregistering it.
    [ -e "$review_worktree/.git" ] || rm -rf -- "$review_worktree"
    git -C "$root" worktree remove -f -f "$review_worktree" >/dev/null
    REVIEW_WORKTREES=("${REVIEW_WORKTREES[@]:1}")
  done
  REVIEW_WORKTREES=(); REVIEW_SOURCE=""
  mkdir "$STAGING/git-surface"
  cp -- "$SURFACE_SNAPSHOTS/"* "$STAGING/git-surface/"
  chmod 0400 "$STAGING/git-surface/"*
  if [ -n "$sensitive_paths_sha256" ]; then
    [ -f "$STAGING/sensitive-paths.json" ] && [ ! -L "$STAGING/sensitive-paths.json" ] \
      && [ "$(sha_file "$STAGING/sensitive-paths.json")" = "$sensitive_paths_sha256" ] \
      || die "sensitive-path evidence changed during review"
  fi
  if [ -n "$prior_rejections_sha256" ]; then
    [ -f "$STAGING/prior-rejections.json" ] && [ ! -L "$STAGING/prior-rejections.json" ] \
      && [ "$(sha_file "$STAGING/prior-rejections.json")" = "$prior_rejections_sha256" ] \
      || die "prior-rejections evidence changed during review"
  fi
  jq -S -n --arg schema "$SCHEMA_COLLECTION" --arg started_at "$started" \
    --arg completed_at "$(now)" --argjson binding "$binding" \
    --argjson git_surface "$SURFACE_STATE" \
    --arg body_sha256 "$(sha_file "$STAGING/pr-body.txt")" \
    --argjson body_bytes "$(bytes_file "$STAGING/pr-body.txt")" \
    --arg diff_sha256 "$(sha_file "$STAGING/review.diff")" \
    --argjson diff_bytes "$(bytes_file "$STAGING/review.diff")" \
    --arg prior_rejections_sha256 "$prior_rejections_sha256" \
    --argjson prior_rejections_bytes "$([ ! -f "$STAGING/prior-rejections.json" ] && printf '0' || bytes_file "$STAGING/prior-rejections.json")" \
    --arg ignored_paths_sha256 "$([ ! -f "$STAGING/ignored-paths.json" ] || sha_file "$STAGING/ignored-paths.json")" \
    --argjson ignored_paths_bytes "$([ ! -f "$STAGING/ignored-paths.json" ] && printf '0' || bytes_file "$STAGING/ignored-paths.json")" \
    --arg sensitive_paths_sha256 "$sensitive_paths_sha256" \
    --argjson sensitive_paths_bytes "$([ ! -f "$STAGING/sensitive-paths.json" ] && printf '0' || bytes_file "$STAGING/sensitive-paths.json")" \
    --arg deleted_paths_sha256 "$([ ! -f "$STAGING/deleted-paths.json" ] || sha_file "$STAGING/deleted-paths.json")" \
    --argjson deleted_paths_bytes "$([ ! -f "$STAGING/deleted-paths.json" ] && printf '0' || bytes_file "$STAGING/deleted-paths.json")" \
    --arg mutation_gate_sha256 "$([ ! -f "$STAGING/mutation-gate.json" ] || sha_file "$STAGING/mutation-gate.json")" \
    --argjson mutation_gate_bytes "$([ ! -f "$STAGING/mutation-gate.json" ] && printf '0' || bytes_file "$STAGING/mutation-gate.json")" \
    --arg runner_path "$SCRIPT_DIR/collect-review-evidence.sh" \
    --arg runner_sha256 "$(sha_file "$SCRIPT_DIR/collect-review-evidence.sh")" \
    --arg library_path "$SCRIPT_DIR/lib.sh" --arg library_sha256 "$(sha_file "$SCRIPT_DIR/lib.sh")" \
    --arg bundle_manifest_path "$PLUGIN_ROOT/integrity/runner-bundle.json" \
    --arg bundle_manifest_sha256 "$(printf '%s' "$bundle" | jq -r .sha256)" \
    --argjson min_ok_legs "$min_ok_legs" --argjson panel_size "$panel_size" --argjson panel "$panel_json" \
    --arg grok_recovery "$grok_recovery" \
    --slurpfile providers "$providers_json" \
    '{schema:$schema,started_at:$started_at,completed_at:$completed_at,
      repository:$binding.repository,
      git_surface:$git_surface,
      pull_request:{number:$binding.pull_request.number,url:$binding.pull_request.url,state:$binding.pull_request.state,
        base_ref:$binding.pull_request.baseRefName,base_oid:$binding.pull_request.baseRefOid,
        head_ref:$binding.pull_request.headRefName,head_oid:$binding.pull_request.headRefOid,
        body:{path:"pr-body.txt",sha256:$body_sha256,bytes:$body_bytes}},
      diff:{path:"review.diff",sha256:$diff_sha256,bytes:$diff_bytes},
      runner:{path:$runner_path,sha256:$runner_sha256,library_path:$library_path,library_sha256:$library_sha256,
        bundle_manifest_path:$bundle_manifest_path,bundle_manifest_sha256:$bundle_manifest_sha256},
      providers:$providers,
      containment:(if all($providers[]; .containment == "pid-namespace") then "pid-namespace" else "session" end),
      panel_policy:{min_ok_legs:$min_ok_legs,panel_size:$panel_size,panel:$panel,source:"env"},grok_recovery:$grok_recovery}
      + (if $prior_rejections_sha256 == "" then {} else
          {prior_rejections:{path:"prior-rejections.json",sha256:$prior_rejections_sha256,bytes:$prior_rejections_bytes}} end)
      + (if $ignored_paths_sha256 == "" then {} else
          {ignored_paths:{path:"ignored-paths.json",sha256:$ignored_paths_sha256,bytes:$ignored_paths_bytes},
           sensitive_paths:{path:"sensitive-paths.json",sha256:$sensitive_paths_sha256,bytes:$sensitive_paths_bytes}} end)
      + (if $deleted_paths_sha256 == "" then {} else
          {deleted_paths:{path:"deleted-paths.json",sha256:$deleted_paths_sha256,bytes:$deleted_paths_bytes}} end)
      + (if $mutation_gate_sha256 == "" then {} else
          {mutation_gate:{path:"mutation-gate.json",sha256:$mutation_gate_sha256,bytes:$mutation_gate_bytes}} end)' \
    > "$STAGING/manifest.json"
  rm -f "$providers_json"
  chmod 0444 "$STAGING/manifest.json" "$STAGING/pr-body.txt" "$STAGING/review.diff" "$STAGING/providers/"*.json
  [ ! -f "$STAGING/ignored-paths.json" ] || chmod 0444 "$STAGING/ignored-paths.json" "$STAGING/sensitive-paths.json"
  [ ! -f "$STAGING/deleted-paths.json" ] || chmod 0444 "$STAGING/deleted-paths.json"
  [ ! -f "$STAGING/mutation-gate.json" ] || chmod 0444 "$STAGING/mutation-gate.json"
  mv -T -- "$STAGING" "$output" 2>/dev/null \
    || die "collection output appeared concurrently"
  STAGING=""
  jq -nc --arg collection "$output" --arg manifest_sha256 "$(sha_file "$output/manifest.json")" \
    --arg runner_bundle_sha256 "$(printf '%s' "$bundle" | jq -r .sha256)" \
    --arg head_oid "$head_oid" \
    '{collection:$collection,manifest_sha256:$manifest_sha256,
      runner_bundle_sha256:$runner_bundle_sha256,head_oid:$head_oid}'
}

usage() {
  cat >&2 <<'EOF'
Usage:
  collect-review-evidence.sh collect --repo-root ROOT --pr N --output ABS_DIR [--prior-rejections FILE]
  collect-review-evidence.sh verify-collection --collection DIR --expected-manifest-sha256 SHA
  collect-review-evidence.sh finalize --collection DIR --expected-manifest-sha256 SHA --arbitration FILE
  collect-review-evidence.sh verify-proof --collection DIR --expected-manifest-sha256 SHA --expected-proof-sha256 SHA
EOF
  exit 2
}

require_tools
command="${1:-}"; [ "$#" -gt 0 ] && shift || true
case "$command" in
  collect) collect "$@" ;;
  verify-collection) verify_collection_cmd "$@" ;;
  finalize) finalize "$@" ;;
  verify-proof) verify_proof_cmd "$@" ;;
  *) usage ;;
esac
