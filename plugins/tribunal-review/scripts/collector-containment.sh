#!/usr/bin/env bash
# Reviewer leg containment, process lifecycle, worktree mutation checks, normalization, and cleanup.
# Sourced by scripts/collect-review-evidence.sh.

kill_leg() {
  local pid="$1" group child children
  if [ "${NAMESPACE_PIDS[$pid]:-}" = yes ]; then
    # Leave unshare alive to wait for PID 1: its wait completes only after the
    # kernel has killed and reaped the namespace, including detached sessions.
    children="$(ps -o pid= --ppid "$pid")" || children=""
    if [ -n "$children" ]; then
      for child in $children; do kill -KILL "$child" 2>/dev/null || true; done
      wait "$pid" 2>/dev/null || true
      unset 'NAMESPACE_PIDS[$pid]'
      return 0
    fi
    # The launcher has finished or has not forked yet; --kill-child covers death
    # during startup. No reviewer can run before that parent-death guard is set.
  fi
  # timeout may create nested groups. Kill every group in the wrapper's session;
  # SIGKILL has no handler/grace period and we never wait for orphan descendants.
  kill -KILL "$pid" 2>/dev/null || true
  while read -r group; do
    kill -KILL -- "-$group" 2>/dev/null || true
  done < <(ps -eo sid=,pgid= | awk -v sid="$pid" '$1 == sid && !seen[$2]++ { print $2 }')
  wait "$pid" 2>/dev/null || true
  unset 'NAMESPACE_PIDS[$pid]'
}

probe_containment() {
  local reason help
  CONTAINMENT=session
  if ! command -v unshare >/dev/null 2>&1; then
    reason="unshare is unavailable"
  elif help="$(unshare --help 2>&1)" && [[ "$help" = *--map-current-user* ]]; then
    if reason="$(timeout -k 1 5 unshare --user --map-current-user --pid --fork --kill-child true 2>&1)"; then
      CONTAINMENT=pid-namespace
      return
    fi
    reason="user/PID namespace probe failed: ${reason%%$'\n'*}"
  else
    reason="unshare lacks --map-current-user (util-linux 2.38+ required)"
  fi
  printf 'tribunal evidence: containment degraded: %s\n' "$reason" >&2
}

cleanup() {
  local rc=$? review_worktree pid leftovers=0
  for pid in ${REVIEW_PIDS[@]+"${REVIEW_PIDS[@]}"}; do kill_leg "$pid"; done
  check_git_surface || rc=1
  if [ "$SURFACE_FAILED" -eq 0 ] && [ -n "$REVIEW_SOURCE" ]; then
    for review_worktree in "${REVIEW_WORKTREES[@]}"; do
      if ! git -C "$REVIEW_SOURCE" worktree remove -f -f "$review_worktree" >/dev/null 2>&1; then
        printf 'tribunal evidence: leftover review worktree: %s\n' "$review_worktree" >&2
        leftovers=1
      fi
    done
  elif [ "$SURFACE_FAILED" -eq 1 ] && [ -n "${REVIEW_WORKTREES[0]:-}" ]; then
    for review_worktree in "${REVIEW_WORKTREES[@]}"; do
      printf 'tribunal evidence: leftover review worktree: %s\n' "$review_worktree" >&2
    done
    leftovers=1
  fi
  [ "$leftovers" -eq 0 ] || printf 'tribunal evidence: after restoring the Git surface, remove leftover worktrees and run git worktree prune\n' >&2
  [ -z "$STAGING" ] || [ ! -e "$STAGING" ] || rm -rf -- "$STAGING"
  [ -z "$FINAL_TMP1" ] || [ ! -e "$FINAL_TMP1" ] || rm -f -- "$FINAL_TMP1"
  [ -z "$FINAL_TMP2" ] || [ ! -e "$FINAL_TMP2" ] || rm -f -- "$FINAL_TMP2"
  [ -z "$SURFACE_SNAPSHOTS" ] || rm -rf -- "$SURFACE_SNAPSHOTS"
  exit "$rc"
}

provider_status() {
  jq -r 'if .status == "disabled" then "disabled" elif has("error") then "failed" else "ok" end' "$1"
}

write_failed_provider() {
  local provider="$1" message="$2" out="$3"
  jq -S -n --arg p "$provider" --arg e "$message" '{provider:$p,error:$e}' > "$out"
}

fail_mutated_providers() {
  local expected_head="$1" dir="$2" provider name worktree_var worktree artifact actual_head dirty paths message changed_paths
  local -x GIT_DIR GIT_COMMON_DIR="$SURFACE_COMMON" GIT_WORK_TREE
  # Worktree variables, review_gitdirs and mutation_errors belong to the active collect invocation.
  for provider in $PROVIDERS; do
    artifact="$dir/providers/$provider.json"
    [ "$(provider_status "$artifact")" != disabled ] || continue
    [ -z "${mutation_errors[$provider]:-}" ] || continue
    name="$provider"
    worktree_var="${name}_worktree"; worktree="${!worktree_var}"
    GIT_DIR="${review_gitdirs[$worktree]}"; GIT_WORK_TREE="$worktree"
    actual_head="$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
      || actual_head=unresolvable
    dirty="$(git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null)" \
      || dirty="git status failed"
    [ "$actual_head" != "$expected_head" ] || [ -n "$dirty" ] || continue
    message="provider mutated its review worktree"
    paths="$dirty"
    if [ "$actual_head" != "$expected_head" ]; then
      message="$message: HEAD moved from $expected_head to $actual_head"
      if [ "$actual_head" != unresolvable ]; then
        changed_paths="$(git -C "$worktree" diff --no-ext-diff --no-textconv --name-status "$expected_head" "$actual_head" 2>/dev/null)" \
          || changed_paths="git diff failed"
        paths="$paths"$'\n'"$changed_paths"
      fi
    fi
    paths="$(printf '%s\n' "$paths" | sed '/^$/d' | sed -n '1,20p')"
    [ -z "$paths" ] || message="$message: $paths"
    mutation_errors[$provider]="$message"
    write_failed_provider "$provider" "$message" "$artifact"
    printf 'tribunal evidence: %s: %s\n' "$provider" "${message//$'\n'/; }" >&2
  done
}

wrapper_exit_message() {
  if [ "$1" = 153 ]; then printf 'provider wrapper exited 153 (file size limit (SIGXFSZ))'
  else printf 'provider wrapper exited %s' "$1"; fi
}

run_wrapper() {
  local name="$1" script="$2" worktree="$3" base_oid="$4" dir="$5" pid
  local -a launch=()
  LEG_CONTAINMENT[$name]="$CONTAINMENT"
  if [ "$CONTAINMENT" = pid-namespace ]; then
    if [ "$name" = grok ] && [ "${TRIBUNAL_GROK_SANDBOX:-${GROK_SANDBOX:-none}}" = read-only ]; then
      # Grok's bwrap addresses /proc with namespace PIDs; without a private proc
      # mount that opt-in sandbox fails. Keep its sandbox and run the leg.
      LEG_CONTAINMENT[$name]=session
      printf 'tribunal evidence: containment degraded: grok: read-only sandbox requires host PID visibility\n' >&2
    else
      launch=(unshare --user --map-current-user --pid --fork --kill-child)
    fi
  fi
  printf '%s\n' "$(now)" > "$dir/$name.started"
  # With monitor mode off, $! is not a group leader: setsid execs without forking.
  (cd "$worktree" && ulimit -f 4194304 && exec setsid "${launch[@]+"${launch[@]}"}" env TRIBUNAL_BASE_REF="$base_oid" bash "$script") \
    > "$dir/$name.raw" 2> "$dir/$name.stderr" &
  pid=$!
  REVIEW_PIDS+=("$pid"); REVIEW_NAMES+=("$name")
  if [ "${LEG_CONTAINMENT[$name]}" = pid-namespace ]; then NAMESPACE_PIDS[$pid]=yes; fi
}

wait_wrappers() {
  local index pid name rc running reaped remaining="${#REVIEW_PIDS[@]}"
  while [ "$remaining" -gt 0 ]; do
    running="$(jobs -pr)"
    reaped=0
    for index in "${!REVIEW_PIDS[@]}"; do
      pid="${REVIEW_PIDS[$index]}"; name="${REVIEW_NAMES[$index]}"
      [[ $'\n'"$running"$'\n' != *$'\n'"$pid"$'\n'* ]] || continue
      rc=0
      wait "$pid" || rc=$?
      if [ "${NAMESPACE_PIDS[$pid]:-}" = yes ]; then
        # unshare waited for namespace teardown; never signal a reaped PID.
        unset 'NAMESPACE_PIDS[$pid]'
      else kill_leg "$pid"; fi
      unset 'REVIEW_PIDS[index]' 'REVIEW_NAMES[index]'
      remaining=$((remaining - 1))
      reaped=1
      check_git_surface || die "git surface changed; collection rejected"
      printf '%s\n' "$rc" > "$STAGING/wrappers/$name.exit"
      printf '%s\n' "$(now)" > "$STAGING/wrappers/$name.finished"
    done
    if [ "$remaining" -gt 0 ] && [ "$reaped" -eq 0 ]; then wait -n || true; fi
  done
  REVIEW_PIDS=(); REVIEW_NAMES=()
}

grok_recovery_allowed() {
  local policy="$1" file="$2"
  [ "$policy" = permit ] && return 0
  [ "$policy" = reject ] || return 1
  jq -e '
    .provider != "grok" or has("error") or .status == "disabled"
    or .grok_execution.verdict_phase == "inspect"
    or (.grok_execution.verdict_phase == null and .diff_stat.files_changed == 0)
  ' "$file" >/dev/null
}

normalize_single() {
  local provider="$1" raw="$2" rc="$3" out="$4" want_base="${5:-}" want_head="${6:-}" count
  local grok_recovery="${7:-permit}"
  if [ "$rc" -ne 0 ]; then
    write_failed_provider "$provider" "$(wrapper_exit_message "$rc")" "$out"
    return
  fi
  count="$(jq -s 'length' "$raw" 2>/dev/null || printf 0)"
  if [ "$count" != 1 ]; then
    write_failed_provider "$provider" "provider wrapper emitted malformed JSON" "$out"
    return
  fi
  jq -S -s --arg p "$provider" '.[0] | .provider = $p' "$raw" > "$out.tmp" 2>/dev/null \
    || { rm -f "$out.tmp"; write_failed_provider "$provider" "provider wrapper emitted malformed JSON" "$out"; return; }
  if validate_provider "$provider" "$out.tmp" "$want_base" "$want_head"; then
    if grok_recovery_allowed "$grok_recovery" "$out.tmp"; then
      mv "$out.tmp" "$out"
    else
      rm -f "$out.tmp"
      write_failed_provider "$provider" "grok_recovery_rejected: inspection verdict required by TRIBUNAL_GROK_RECOVERY=reject" "$out"
    fi
  else
    rm -f "$out.tmp"
    write_failed_provider "$provider" "provider wrapper output failed schema validation" "$out"
  fi
}

wrapper_for_provider() {
  case "$1" in
    codex) printf '%s/run-codex-review.sh\n' "$SCRIPT_DIR" ;;
    gemini) printf '%s/run-gemini-review.sh\n' "$SCRIPT_DIR" ;;
    deepseek) printf '%s/run-deepseek-review.sh\n' "$SCRIPT_DIR" ;;
    qwen) printf '%s/run-qwen-review.sh\n' "$SCRIPT_DIR" ;;
    grok) printf '%s/run-grok-review.sh\n' "$SCRIPT_DIR" ;;
    muse) printf '%s/run-muse-review.sh\n' "$SCRIPT_DIR" ;;
    claude) printf '%s/run-claude-review.sh\n' "$SCRIPT_DIR" ;;
    *) die "unknown provider: $1" ;;
  esac
}
