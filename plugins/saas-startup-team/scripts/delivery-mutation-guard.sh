#!/usr/bin/env bash
# Snapshot and verify the complete product working state around a review-only QA phase.
set -euo pipefail

unset GIT_CONFIG_PARAMETERS
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=core.fsmonitor
export GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=core.hooksPath
export GIT_CONFIG_VALUE_1=/dev/null

ACTION=""; SNAPSHOT=""; ROOT=""; AUTH_TOKEN=""; AUTH_STDIN=0; ALLOW=()
declare -A IGNORED_BASELINE=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  echo "usage: delivery-mutation-guard.sh (--snapshot FILE|--verify FILE) --auth-stdin [--allow PATH] [--repo-root DIR]" >&2
}
need_value() { [ "$#" -ge 2 ] || { usage; exit 2; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot) need_value "$@"; ACTION="snapshot"; SNAPSHOT="$2"; shift 2 ;;
    --verify) need_value "$@"; ACTION="verify"; SNAPSHOT="$2"; shift 2 ;;
    --auth-stdin) AUTH_STDIN=1; shift ;;
    --allow) need_value "$@"; ALLOW+=("${2%/}"); shift 2 ;;
    --repo-root) need_value "$@"; ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "delivery-mutation-guard: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$ACTION" ] && [ -n "$SNAPSHOT" ] || { usage; exit 2; }
[ "$AUTH_STDIN" -eq 1 ] || { usage; exit 2; }
IFS= read -r AUTH_TOKEN || {
  echo "delivery-mutation-guard: authentication token missing on stdin" >&2; exit 2; }
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 2
ROOT="$(cd "$ROOT" && pwd -P)"; cd "$ROOT"
GIT_DIR="$(git rev-parse --absolute-git-dir)"
GIT_DIR="$(cd "$GIT_DIR" && pwd -P)"
GUARD_DIR="$GIT_DIR/saas-startup-team"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_NO_REPLACE_OBJECTS=1
unset GIT_EXTERNAL_DIFF

trusted_git() {
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false \
    git "$@"
}

resolve_snapshot_path() {
  local supplied="$1" resolved parent base
  case "$supplied" in /*) resolved="$supplied" ;; *) resolved="$ROOT/$supplied" ;; esac
  case "$resolved" in *$'\n'*|*$'\r'*|*$'\t'*|*/../*|*/./*) return 1 ;; esac
  parent="$(dirname -- "$resolved")"; base="$(basename -- "$resolved")"
  [ "$parent" = "$GUARD_DIR" ] && [ "$base" != . ] && [ "$base" != .. ] || return 1
  if [ ! -e "$GUARD_DIR" ] && [ ! -L "$GUARD_DIR" ]; then mkdir -m 700 -- "$GUARD_DIR"; fi
  [ -d "$GUARD_DIR" ] && [ ! -L "$GUARD_DIR" ] \
    && [ "$(cd "$GUARD_DIR" && pwd -P)" = "$GUARD_DIR" ] || return 1
  printf '%s\n' "$GUARD_DIR/$base"
}

SNAPSHOT="$(resolve_snapshot_path "$SNAPSHOT")" || {
  echo "delivery-mutation-guard: snapshot must use the dedicated Git guard directory" >&2
  exit 2
}

[[ "$AUTH_TOKEN" =~ ^[0-9a-f]{64}$ ]] || {
  echo "delivery-mutation-guard: invalid authentication token" >&2; exit 2; }

auth_tag() {
  jq -cS 'del(.auth_tag)' "$1" \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$AUTH_TOKEN" \
    | awk '{print $NF}'
}

sign_snapshot() {
  local file="$1" tag tmp
  tag="$(auth_tag "$file")"
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  jq --arg tag "$tag" '.auth_tag=$tag' "$file" > "$tmp"
  chmod 400 "$tmp"
  mv -f -- "$tmp" "$file"
}

head_ref() {
  git symbolic-ref -q HEAD 2>/dev/null || true
}

other_refs_fingerprint() {
  local active="$1"
  git for-each-ref --format='%(refname)%09%(objectname)%09%(symref)' \
    | while IFS=$'\t' read -r ref oid symref; do
        [ "$ref" = "$active" ] || printf '%s\0%s\0%s\0' "$ref" "$oid" "$symref"
      done \
    | git hash-object --stdin
}

hooks_fingerprint() {
  local dir="$1" tmp path rel mode oid result failed=0 old_shopt
  tmp="$(mktemp)"
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    old_shopt="$(shopt -p dotglob nullglob globstar || true)"
    shopt -s dotglob nullglob globstar
    for path in "$dir"/**; do
      rel="${path#"$dir"/}"
      if [ -d "$path" ] && [ ! -L "$path" ]; then continue
      elif [ -f "$path" ] && [ ! -L "$path" ]; then
        if [ -x "$path" ]; then mode=100755; else mode=100644; fi
        oid="$(git hash-object --no-filters -- "$path" 2>/dev/null || echo unreadable)"
      else
        failed=1; break
      fi
      printf '%s\0%s\0%s\0' "$rel" "$mode" "$oid" >> "$tmp"
    done
    eval "$old_shopt"
    [ "$failed" -eq 0 ] || { rm -f "$tmp"; return 1; }
  elif [ -e "$dir" ] || [ -L "$dir" ]; then
    rm -f "$tmp"; return 1
  fi
  result="$(git hash-object --no-filters "$tmp")"
  rm -f "$tmp"
  printf '%s\n' "$result"
}

resolve_hook_source() {
  local configured source parent base
  configured="$(trusted_git config --path core.hooksPath 2>/dev/null || true)"
  if [ -n "$configured" ]; then
    case "$configured" in /*) source="$configured" ;; *) source="$ROOT/$configured" ;; esac
  else
    source="$(trusted_git rev-parse --git-path hooks)"
    case "$source" in /*) : ;; *) source="$ROOT/$source" ;; esac
  fi
  parent="$(dirname -- "$source")"; base="$(basename -- "$source")"
  [ -d "$parent" ] && [ "$base" != . ] && [ "$base" != .. ] || return 1
  parent="$(cd "$parent" && pwd -P)"; source="$parent/$base"
  [ ! -L "$source" ] || return 1
  if [ -e "$source" ] && [ ! -d "$source" ]; then return 1; fi
  printf '%s\n' "$source"
}

git_control_fingerprint() {
  local tmp key path mode oid result
  tmp="$(mktemp)"
  for key in info/attributes objects/info/alternates shallow grafts commondir gitdir \
    HEAD config.worktree MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD BISECT_LOG; do
    path="$(git rev-parse --git-path "$key")"
    case "$path" in /*) : ;; *) path="$ROOT/$path" ;; esac
    if [ -L "$path" ]; then rm -f "$tmp"; return 1
    elif [ -f "$path" ]; then
      if [ -x "$path" ]; then mode=100755; else mode=100644; fi
      oid="$(git hash-object --no-filters -- "$path")"
    elif [ -e "$path" ]; then rm -f "$tmp"; return 1
    else mode=missing; oid=missing
    fi
    printf '%s\0%s\0%s\0' "$key" "$mode" "$oid" >> "$tmp"
  done
  result="$(git hash-object --no-filters "$tmp")"
  rm -f "$tmp"
  printf '%s\n' "$result"
}

index_metadata_fingerprint() {
  git -c core.fsmonitor=false ls-files --stage -v -z | git hash-object --stdin
}

allowed_path() {
  local path="$1" prefix
  for prefix in "${ALLOW[@]}"; do
    if [ "$path" = "$prefix" ] || [ "${path#"$prefix"/}" != "$path" ]; then return 0; fi
  done
  return 1
}

valid_allowed_path() {
  case "$1" in ''|.|/*|:*|*$'\n'*|*$'\r'*|*$'\t'*|../*|*/../*|*/..|./*|*/./*|*/.) return 1 ;; esac
  return 0
}

safe_allow_slot() {
  local relative="$1" current="$ROOT" component next canonical
  while [[ "$relative" == */* ]]; do
    component="${relative%%/*}"
    relative="${relative#*/}"
    next="$current/$component"
    [ ! -L "$next" ] || return 1
    if [ ! -e "$next" ]; then return 0; fi
    [ -d "$next" ] || return 1
    canonical="$(cd "$next" && pwd -P)" || return 1
    case "$canonical/" in "$ROOT/"*) : ;; *) return 1 ;; esac
    current="$canonical"
  done
  next="$current/$relative"
  [ ! -L "$next" ] || return 1
  [ ! -e "$next" ] || [ -f "$next" ]
}

fingerprint_entry() {
  local path="$1"
  if [ -L "$path" ]; then
    ENTRY_MODE=120000
    ENTRY_OID="$(readlink "$path" | git hash-object --stdin)"
  elif [ -f "$path" ]; then
    if [ -x "$path" ]; then ENTRY_MODE=100755; else ENTRY_MODE=100644; fi
    ENTRY_OID="$(git hash-object --no-filters -- "$path" 2>/dev/null || echo unreadable)"
  elif [ -d "$path" ]; then
    ENTRY_MODE=040000; ENTRY_OID=directory
  elif [ -e "$path" ]; then
    ENTRY_MODE=unsupported; ENTRY_OID=unreadable
  else
    ENTRY_MODE=missing; ENTRY_OID=missing
  fi
}

diff_fingerprint() {
  local kind="$1" base="$2" prefix
  local pathspec=(.)
  for prefix in "${ALLOW[@]}"; do
    pathspec+=(":(exclude,literal)$prefix")
  done
  case "$kind" in
    index) git -c core.fsmonitor=false diff --binary --no-ext-diff --no-textconv --cached "$base" -- "${pathspec[@]}" | git hash-object --stdin ;;
    worktree) git -c core.fsmonitor=false diff --binary --no-ext-diff --no-textconv -- "${pathspec[@]}" | git hash-object --stdin ;;
    *) return 2 ;;
  esac
}

status_outside_allow() {
  local prefix pathspec=(.)
  for prefix in "${ALLOW[@]}"; do
    pathspec+=(":(exclude,literal)$prefix")
  done
  git -c core.fsmonitor=false status --short -- "${pathspec[@]}"
}

untracked_fingerprint() {
  fingerprint_other_files untracked --others --exclude-standard
}

always_exempt_ignored_path() {
  local path="${1%/}"
  [ ! -L "$path" ] || return 1
  case "/$path/" in
    */node_modules/*|*/.pnpm-store/*|*/.pnpm/*|*/bower_components/*|\
    */.yarn/cache/*|*/.yarn/unplugged/*) return 0 ;;
  esac
  case "$path" in
    .startup/leases/*/heartbeat|.startup/leases/*/audit.log) return 0 ;;
  esac
  return 1
}

ignored_paths() {
  local path directory
  while IFS= read -r -d '' path; do
    if [[ "$path" == */ ]]; then
      directory=${path%/}
      always_exempt_ignored_path "$directory" && continue
      while IFS= read -r -d '' path; do
        allowed_path "$path" || always_exempt_ignored_path "$path" || printf '%s\0' "$path"
      done < <(git -c core.fsmonitor=false ls-files -z --others --ignored --exclude-standard -- "$directory")
    else
      allowed_path "$path" || always_exempt_ignored_path "$path" || printf '%s\0' "$path"
    fi
  done < <(git -c core.fsmonitor=false ls-files -z --others --ignored --exclude-standard --directory -- .)
}

ignored_path_key() {
  printf '%s' "$1" | git hash-object --stdin
}

list_ignored_baseline_keys() {
  local path
  while IFS= read -r -d '' path; do
    ignored_path_key "$path"
  done < <(ignored_paths)
}

protected_ignored_paths() {
  local path key
  while IFS= read -r -d '' path; do
    key="$(ignored_path_key "$path")"
    [ -n "${IGNORED_BASELINE[$key]+present}" ] || continue
    printf '%s\0' "$path"
  done < <(ignored_paths)
}

new_ignored_paths() {
  local path key
  declare -A seen=()
  while IFS= read -r -d '' path; do
    key="$(ignored_path_key "$path")"
    [[ -v seen["$key"] ]] && continue
    seen["$key"]=1
    [ -z "${IGNORED_BASELINE[$key]+present}" ] || continue
    printf '%s\0' "$path"
  done < <(ignored_paths)
}

safe_ignored_cleanup_slot() {
  local relative="$1" current="$ROOT" component next canonical
  valid_allowed_path "$relative" || return 1
  while [[ "$relative" == */* ]]; do
    component="${relative%%/*}"
    relative="${relative#*/}"
    next="$current/$component"
    [ -d "$next" ] && [ ! -L "$next" ] || return 1
    canonical="$(cd "$next" && pwd -P)" || return 1
    case "$canonical/" in "$ROOT/"*) : ;; *) return 1 ;; esac
    current="$canonical"
  done
  CLEANUP_PATH="$current/$relative"
  [ -f "$CLEANUP_PATH" ] || [ -L "$CLEANUP_PATH" ]
}

cleanup_new_ignored_paths() {
  local path
  while IFS= read -r -d '' path; do
    safe_ignored_cleanup_slot "$path" || {
      printf 'delivery-mutation-guard: unsafe disposable ignored path: %q\n' "$path" >&2
      return 1
    }
    rm -f -- "$CLEANUP_PATH" || {
      printf 'delivery-mutation-guard: cannot remove disposable ignored path: %q\n' "$path" >&2
      return 1
    }
  done < <(new_ignored_paths)
  if IFS= read -r -d '' path < <(new_ignored_paths); then
    printf 'delivery-mutation-guard: disposable ignored path survived cleanup: %q\n' "$path" >&2
    return 1
  fi
}

ignored_fingerprint() {
  local tmp path
  tmp="$(mktemp)"
  while IFS= read -r -d '' path; do
    fingerprint_one ignored "$path" "$tmp"
  done < <(protected_ignored_paths)
  git hash-object --no-filters "$tmp"
  rm -f "$tmp"
}

fingerprint_one() {
  local kind="$1" path="$2" tmp="$3"
  allowed_path "$path" && return 0
  fingerprint_entry "$path"
  printf '%s\0%s\0%s\0%s\0' "$kind" "$path" "$ENTRY_MODE" "$ENTRY_OID" >> "$tmp"
}

fingerprint_other_files() {
  local kind="$1" tmp path result
  shift
  tmp="$(mktemp)"
  while IFS= read -r -d '' path; do
    fingerprint_one "$kind" "$path" "$tmp"
  done < <(git -c core.fsmonitor=false ls-files -z "$@" -- .)
  result="$(git hash-object --no-filters "$tmp")"
  rm -f "$tmp"
  printf '%s\n' "$result"
}

git_exclusion_fingerprint() {
  local tmp exclude_path external raw path oid result
  tmp="$(mktemp)"
  git config --show-origin --show-scope --list 2>/dev/null > "$tmp" || true
  exclude_path="$(git rev-parse --git-path info/exclude)"
  if [ -e "$exclude_path" ] || [ -L "$exclude_path" ]; then
    fingerprint_entry "$exclude_path"
    printf 'info-exclude\0%s\0%s\0' "$ENTRY_MODE" "$ENTRY_OID" >> "$tmp"
  else
    printf 'info-exclude\0missing\0' >> "$tmp"
  fi
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    external=${raw#*$'\t'}
    case "$external" in
      \~/*) path="${HOME:-}/${external:2}" ;;
      /*) path="$external" ;;
      *) path="$ROOT/$external" ;;
    esac
    if [ -f "$path" ] && [ ! -L "$path" ]; then
      oid="$(git hash-object --no-filters -- "$path" 2>/dev/null || echo unreadable)"
      printf 'global-exclude\0%s\0' "$oid" >> "$tmp"
    else
      printf 'global-exclude\0missing\0' >> "$tmp"
    fi
  done < <(git config --show-origin --get-all core.excludesfile 2>/dev/null || true)
  result="$(git hash-object --no-filters "$tmp")"
  rm -f "$tmp"
  printf '%s\n' "$result"
}

state_fingerprint() {
  local path=".startup/state.json"
  if [ -e "$path" ] || [ -L "$path" ]; then
    fingerprint_entry "$path"
    printf 'present\0%s\0%s\0' "$ENTRY_MODE" "$ENTRY_OID" | git hash-object --stdin
  else
    printf 'missing\0' | git hash-object --stdin
  fi
}

head_boundary_intact() {
  [ "$(git rev-parse HEAD)" = "$1" ]
}

if [ "$ACTION" = "snapshot" ]; then
  [ "${#ALLOW[@]}" -gt 0 ] || {
    echo "delivery-mutation-guard: at least one exact --allow path is required" >&2
    exit 2
  }
  for allowed in "${ALLOW[@]}"; do
    valid_allowed_path "$allowed" || {
      printf 'delivery-mutation-guard: invalid allowed path: %q\n' "$allowed" >&2
      exit 2
    }
    safe_allow_slot "$allowed" || {
      printf 'delivery-mutation-guard: unsafe allowed artifact slot: %q\n' "$allowed" >&2
      exit 1
    }
  done
  base="$(git rev-parse HEAD)"
  index_fp="$(diff_fingerprint index "$base")"
  worktree_fp="$(diff_fingerprint worktree "$base")"
  untracked_fp="$(untracked_fingerprint)"
  ignored_baseline_keys=()
  mapfile -t ignored_baseline_keys < <(list_ignored_baseline_keys)
  for path_key in "${ignored_baseline_keys[@]}"; do
    IGNORED_BASELINE["$path_key"]=1
  done
  ignored_fp="$(ignored_fingerprint)"
  exclusion_fp="$(git_exclusion_fingerprint)"
  state_fp="$(state_fingerprint)"
  active_ref="$(head_ref)"
  refs_fp="$(other_refs_fingerprint "$active_ref")"
  hook_source="$(resolve_hook_source)" || {
    echo "delivery-mutation-guard: active hook source is unsafe" >&2; exit 1; }
  hooks_fp="$(hooks_fingerprint "$hook_source")" || {
    echo "delivery-mutation-guard: active hook set is unsafe" >&2; exit 1; }
  control_fp="$(git_control_fingerprint)" || {
    echo "delivery-mutation-guard: Git control metadata is unsafe" >&2; exit 1; }
  index_metadata_fp="$(index_metadata_fingerprint)"
  [ ! -e "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ] || {
    echo "delivery-mutation-guard: snapshot already exists" >&2; exit 1; }
  allow_json="$(printf '%s\n' "${ALLOW[@]}" | jq -R . | jq -s .)"
  ignored_baseline_json="$(printf '%s\n' "${ignored_baseline_keys[@]}" \
    | jq -R 'select(length > 0)' | jq -s .)"
  snapshot_tmp="$(mktemp "${SNAPSHOT}.unsigned.XXXXXX")"
  jq -n --arg head "$base" --arg index "$index_fp" --arg worktree "$worktree_fp" \
    --arg untracked "$untracked_fp" --arg ignored "$ignored_fp" --arg exclusion "$exclusion_fp" \
    --arg state "$state_fp" --arg active_ref "$active_ref" --arg refs "$refs_fp" \
    --arg hooks "$hooks_fp" --arg control "$control_fp" --arg index_metadata "$index_metadata_fp" \
    --argjson allow "$allow_json" --argjson ignored_baseline "$ignored_baseline_json" \
    '{schema_version:6,base_head:$head,head_ref:$active_ref,other_refs_fingerprint:$refs,
      hooks_fingerprint:$hooks,git_control_fingerprint:$control,
      index_metadata_fingerprint:$index_metadata,
      index_fingerprint:$index,
      worktree_fingerprint:$worktree,untracked_fingerprint:$untracked,
      ignored_fingerprint:$ignored,git_exclusion_fingerprint:$exclusion,
      state_fingerprint:$state,ignored_baseline:$ignored_baseline,
      allow:$allow,auth_tag:null}' > "$snapshot_tmp"
  sign_snapshot "$snapshot_tmp"
  mv -- "$snapshot_tmp" "$SNAPSHOT"
  [ ! -e "${SNAPSHOT}.active" ] && [ ! -L "${SNAPSHOT}.active" ] || {
    echo "delivery-mutation-guard: active marker already exists" >&2; exit 1; }
  (umask 077; printf 'guard-active\n' > "${SNAPSHOT}.active")
  chmod 400 "${SNAPSHOT}.active"
  echo "delivery-mutation-guard: snapshot $(git rev-parse --short HEAD)"
  exit 0
fi

[ -f "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ] || {
  echo "delivery-mutation-guard: snapshot not found or unsafe: $SNAPSHOT" >&2; exit 2; }
[ -f "${SNAPSHOT}.active" ] && [ ! -L "${SNAPSHOT}.active" ] || {
  echo "delivery-mutation-guard: active guard marker is missing or unsafe" >&2; exit 1; }
jq -e '.schema_version == 6 and (.base_head|type=="string")
  and (.head_ref|type=="string") and (.other_refs_fingerprint|type=="string")
  and (.hooks_fingerprint|type=="string") and (.git_control_fingerprint|type=="string")
  and (.index_metadata_fingerprint|type=="string")
  and (.index_fingerprint|type=="string") and (.worktree_fingerprint|type=="string")
  and (.untracked_fingerprint|type=="string") and (.ignored_fingerprint|type=="string")
  and (.git_exclusion_fingerprint|type=="string") and (.state_fingerprint|type=="string")
  and (.ignored_baseline|type=="array")
  and (.allow|type=="array") and (.auth_tag|type=="string")' "$SNAPSHOT" >/dev/null || {
  echo "delivery-mutation-guard: malformed snapshot" >&2; exit 2; }
[ "$(auth_tag "$SNAPSHOT")" = "$(jq -r .auth_tag "$SNAPSHOT")" ] || {
  echo "delivery-mutation-guard: snapshot authentication failed" >&2; exit 1; }
base="$(jq -r '.base_head' "$SNAPSHOT")"
mapfile -t ALLOW < <(jq -r '.allow[]' "$SNAPSHOT")
for allowed in "${ALLOW[@]}"; do
  valid_allowed_path "$allowed" || {
    echo "delivery-mutation-guard: authenticated allowlist is invalid" >&2; exit 1; }
  safe_allow_slot "$allowed" || {
    printf 'delivery-mutation-guard: authenticated artifact slot became unsafe: %q\n' "$allowed" >&2
    exit 1
  }
done
mapfile -t ignored_baseline_keys < <(jq -r '.ignored_baseline[]' "$SNAPSHOT")
for path_key in "${ignored_baseline_keys[@]}"; do
  [[ "$path_key" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || {
    echo "delivery-mutation-guard: authenticated ignored-state baseline is invalid" >&2
    exit 1
  }
  IGNORED_BASELINE["$path_key"]=1
done
VERIFIED="${SNAPSHOT}.verified"
resume_import=0
if [ -e "$VERIFIED" ] || [ -L "$VERIFIED" ]; then
  [ -f "$VERIFIED" ] && [ ! -L "$VERIFIED" ] \
    && jq -e --arg snapshot_tag "$(jq -r .auth_tag "$SNAPSHOT")" \
      '.schema_version == 1 and .snapshot_auth_tag == $snapshot_tag and (.auth_tag|type=="string")' \
      "$VERIFIED" >/dev/null \
    && [ "$(auth_tag "$VERIFIED")" = "$(jq -r .auth_tag "$VERIFIED")" ] || {
      echo "delivery-mutation-guard: telemetry import marker authentication failed" >&2; exit 1; }
  resume_import=1
fi

if [ "$resume_import" -eq 0 ]; then
  hook_source="$(resolve_hook_source)" || {
    echo "delivery-mutation-guard: active hook source became unsafe" >&2; exit 1; }
  [ "$(hooks_fingerprint "$hook_source")" = "$(jq -r .hooks_fingerprint "$SNAPSHOT")" ] \
    && [ "$(git_control_fingerprint)" = "$(jq -r .git_control_fingerprint "$SNAPSHOT")" ] \
    && [ "$(index_metadata_fingerprint)" = "$(jq -r .index_metadata_fingerprint "$SNAPSHOT")" ] || {
      echo "delivery-mutation-guard: worker changed Git hooks or control metadata" >&2
      exit 1
    }
  [ "$(head_ref)" = "$(jq -r .head_ref "$SNAPSHOT")" ] \
    && [ "$(other_refs_fingerprint "$(head_ref)")" = "$(jq -r .other_refs_fingerprint "$SNAPSHOT")" ] || {
      echo "delivery-mutation-guard: Git refs changed outside the allowed phase" >&2
      exit 1
    }
  head_boundary_intact "$base" || {
    echo "delivery-mutation-guard: worker changed commit history; only the supervisor may commit" >&2
    exit 1
  }
  expected_index="$(jq -r '.index_fingerprint' "$SNAPSHOT")"
  expected_worktree="$(jq -r '.worktree_fingerprint' "$SNAPSHOT")"
  expected_untracked="$(jq -r '.untracked_fingerprint' "$SNAPSHOT")"
  expected_ignored="$(jq -r '.ignored_fingerprint' "$SNAPSHOT")"
  expected_exclusion="$(jq -r '.git_exclusion_fingerprint' "$SNAPSHOT")"
  expected_state="$(jq -r '.state_fingerprint' "$SNAPSHOT")"
  actual_index="$(diff_fingerprint index "$base")"
  actual_worktree="$(diff_fingerprint worktree "$base")"
  actual_untracked="$(untracked_fingerprint)"
  actual_ignored="$(ignored_fingerprint)"
  actual_exclusion="$(git_exclusion_fingerprint)"
  actual_state="$(state_fingerprint)"

  if [ "$actual_index" != "$expected_index" ] \
    || [ "$actual_worktree" != "$expected_worktree" ] \
    || [ "$actual_untracked" != "$expected_untracked" ] \
    || [ "$actual_ignored" != "$expected_ignored" ] \
    || [ "$actual_exclusion" != "$expected_exclusion" ] \
    || [ "$actual_state" != "$expected_state" ]; then
    echo "delivery-mutation-guard: guarded phase modified files outside its allowed paths" >&2
    echo "delivery-mutation-guard: changed fingerprint components:" >&2
    tracked_state_changed=0
    if [ "$actual_index" != "$expected_index" ]; then
      echo "  - tracked index" >&2; tracked_state_changed=1
    fi
    if [ "$actual_worktree" != "$expected_worktree" ]; then
      echo "  - tracked worktree" >&2; tracked_state_changed=1
    fi
    if [ "$actual_untracked" != "$expected_untracked" ]; then
      echo "  - untracked files" >&2; tracked_state_changed=1
    fi
    if [ "$actual_ignored" != "$expected_ignored" ]; then
      echo "  - protected ignored state" >&2
      echo "delivery-mutation-guard: current protected ignored paths (a removed path is absent):" >&2
      ignored_count=0; ignored_shown=0
      while IFS= read -r -d '' ignored_path; do
        ignored_count=$((ignored_count + 1))
        if [ "$ignored_shown" -lt 20 ]; then
          printf '    %q\n' "$ignored_path" >&2
          ignored_shown=$((ignored_shown + 1))
        fi
      done < <(protected_ignored_paths)
      if [ "$ignored_count" -eq 0 ]; then
        echo "    (none)" >&2
      elif [ "$ignored_count" -gt "$ignored_shown" ]; then
        printf '    ... and %d more\n' "$((ignored_count - ignored_shown))" >&2
      fi
    fi
    if [ "$actual_exclusion" != "$expected_exclusion" ]; then
      echo "  - Git exclusion metadata" >&2
    fi
    if [ "$actual_state" != "$expected_state" ]; then
      echo "  - .startup/state.json" >&2
    fi
    if [ "$tracked_state_changed" -eq 1 ]; then
      status_outside_allow >&2
    fi
    exit 1
  fi
fi
cleanup_new_ignored_paths || exit 1
shopt -s nullglob
telemetry_receipts=("${SNAPSHOT}.telemetry-"*.json)
shopt -u nullglob
if [ "$resume_import" -eq 0 ] && [ "${#telemetry_receipts[@]}" -gt 0 ]; then
  for telemetry_receipt in "${telemetry_receipts[@]}"; do
    bash "$SCRIPT_DIR/agent-events.sh" import-guarded --check --receipt "$telemetry_receipt" >/dev/null || {
      echo "delivery-mutation-guard: guarded telemetry preflight failed" >&2
      exit 1
    }
  done
  verified_tmp="$(mktemp "${VERIFIED}.tmp.XXXXXX")"
  jq -n --arg snapshot_tag "$(jq -r .auth_tag "$SNAPSHOT")" \
    '{schema_version:1,snapshot_auth_tag:$snapshot_tag,auth_tag:null}' > "$verified_tmp"
  sign_snapshot "$verified_tmp"
  mv -- "$verified_tmp" "$VERIFIED"
fi
for telemetry_receipt in "${telemetry_receipts[@]}"; do
  bash "$SCRIPT_DIR/agent-events.sh" import-guarded --receipt "$telemetry_receipt" >/dev/null || {
    echo "delivery-mutation-guard: guarded telemetry import failed" >&2
    exit 1
  }
done
rm -f -- "${SNAPSHOT}.telemetry-identity-key" "$VERIFIED" "${SNAPSHOT}.active"
echo "delivery-mutation-guard: review-only boundary intact"
