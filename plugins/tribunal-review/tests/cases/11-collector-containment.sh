#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

test_collector_subdirectory_root() {
  local work ec=0
  work="$(mktemp -d)"
  git init -q "$work/repo"
  mkdir -p "$work/repo/subdirectory" "$work/bin"
  printf '#!/usr/bin/env bash\nexit 99\n' > "$work/bin/gh"
  chmod +x "$work/bin/gh"
  PATH="$work/bin:$PATH" bash "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" collect \
    --repo-root "$work/repo/subdirectory" --pr 7 --output "$work/collection" > "$work/out" 2> "$work/err" || ec=$?
  subdirectory_root_rejected() {
    [ "$ec" -eq 1 ] && grep -Fq -- '--repo-root is not a Git worktree root' "$work/err" \
      && ! grep -Fq 'root git path is not a directory or gitfile' "$work/err"
  }
  tr_check "subdirectory repo-root gets the toplevel error before surface pinning" subdirectory_root_rejected
  rm -rf "$work"
}

test_collector_surface_leftovers() {
  local work ec=0
  work="$(mktemp -d)"
  git init -q "$work/repo"
  git -C "$work/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git -C "$work/repo" worktree add -q --detach "$work/review-one"
  git -C "$work/repo" worktree add -q --detach "$work/review-two"
  sed '/^require_tools$/,$d' "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" > "$work/collector-functions.sh"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$work/lib.sh"
  bash -c '
    . "$1/collector-functions.sh"
    SURFACE_ROOT="$1/repo"
    load_safe_directories
    pin_git_surface
    REVIEW_SOURCE="$SURFACE_ROOT"
    REVIEW_WORKTREES=("$1/review-one" "$1/review-two")
    printf "/missing-common-dir\n" > "$SURFACE_ROOT/.git/commondir"
  ' _ "$work" > "$work/out" 2> "$work/err" || ec=$?
  leftovers_reported() {
    [ "$ec" -eq 1 ] && [ -d "$work/review-one" ] && [ -d "$work/review-two" ] \
      && grep -Fq "leftover review worktree: $work/review-one" "$work/err" \
      && grep -Fq "leftover review worktree: $work/review-two" "$work/err" \
      && grep -Fq 'git worktree prune' "$work/err"
  }
  tr_check "surface failure names every leftover worktree and the prune hint on stderr" leftovers_reported
  git -C "$work/repo" worktree remove -f "$work/review-one"
  git -C "$work/repo" worktree remove -f "$work/review-two"
  rm -rf "$work"
}

test_collector_config_includes() {
  local work directive ec
  work="$(mktemp -d)"
  git init -q "$work/repo"
  mkdir "$work/bin"
  printf '#!/usr/bin/env bash\nexit 99\n' > "$work/bin/gh"
  chmod +x "$work/bin/gh"
  for directive in include.path 'includeIf.gitdir:/nonmatching/.path'; do
    git -C "$work/repo" config "$directive" "$work/external-config"
    ec=0
    PATH="$work/bin:$PATH" bash "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" collect \
      --repo-root "$work/repo" --pr 7 --output "$work/collection" > "$work/out" 2> "$work/err" || ec=$?
    config_include_rejected() {
      [ "$ec" -eq 1 ] && grep -Fq 'sealed collection does not support repository config include/includeIf directives' "$work/err"
    }
    tr_check "common config refuses $directive with a named error" config_include_rejected
    git -C "$work/repo" config --unset "$directive"
  done
  rm -rf "$work"
}

test_collector_reap_rescan() {
  local work ec=0
  work="$(mktemp -d)"
  sed '/^require_tools$/,$d' "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" > "$work/collector-functions.sh"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$work/lib.sh"
  mkdir -p "$work/staging/wrappers"
  mkfifo "$work/a.go" "$work/b.go" "$work/child.ready"
  cat > "$work/a.sh" <<'LEG'
read -r go < a.go
exit 17
LEG
  cat > "$work/b.sh" <<'LEG'
read -r go < b.go
timeout 5 bash -c '
  trap "" TERM
  printf "ready\n" > child.ready
  sleep 1
  touch rewritten
' >/dev/null 2>&1 &
read -r ready < child.ready
exit 23
LEG
  printf 'sleep 3\n' > "$work/c.sh"
  timeout -k 1 10 bash -c '
    . "$1/collector-functions.sh"
    set +m
    STAGING="$1/staging"
    checked=0; fixture_root="$1"
    check_git_surface() {
      if [ "$checked" -eq 0 ]; then
        checked=1
        printf "go\n" > "$fixture_root/b.go"
        sleep 0.4
      fi
    }
    run_wrapper a "$1/a.sh" "$1" unused "$STAGING/wrappers"
    run_wrapper b "$1/b.sh" "$1" unused "$STAGING/wrappers"
    run_wrapper c "$1/c.sh" "$1" unused "$STAGING/wrappers"
    printf "go\n" > "$1/a.go"
    wait_wrappers
    STAGING=""
  ' _ "$work" > "$work/out" 2> "$work/err" || ec=$?
  reap_rescan_ok() {
    [ "$ec" -eq 0 ] && [ ! -e "$work/rewritten" ] \
      && [ "$(cat "$work/staging/wrappers/a.exit")" = 17 ] \
      && [ "$(cat "$work/staging/wrappers/b.exit")" = 23 ] \
      && [ "$work/staging/wrappers/b.finished" -ot "$work/staging/wrappers/c.finished" ]
  }
  tr_check "rescan reaps a leg finishing during another leg surface check before its descendant acts" reap_rescan_ok
  rm -rf "$work"
}

test_collector_pid_namespace() {
  local work mode ec
  if ! unshare --user --map-current-user --pid --fork --kill-child true 2>/dev/null; then
    echo "  SKIP PID namespace regressions: unprivileged namespaces unavailable"; SKIP=$((SKIP+1)); return
  fi
  work="$(mktemp -d)"
  sed '/^require_tools$/,$d' "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" > "$work/collector-functions.sh"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$work/lib.sh"
  cat > "$work/escape.py" <<'PY'
import os, time
if os.fork():
    os._exit(0)
os.setsid()
if os.fork():
    os._exit(0)
with open('/proc/self/stat') as f:
    host_pid = f.read().split()[0]
with open('child.pid', 'w') as f:
    f.write(host_pid)
with open('ready', 'w') as f:
    f.write('ready\n')
time.sleep(0.4)
with open('staging/wrappers/escape.raw', 'w') as f:
    f.write('{"provider":"codex","error":"forged"}\n')
open('rewritten', 'w').close()
PY
  cat > "$work/escape.sh" <<'LEG'
id -u > uid
printf '%s\n' "$$" > init.pid
python3 escape.py >/dev/null 2>&1
read -r ready < ready
printf '%s\n' '{"provider":"codex","error":"original"}'
if [ "$FIXTURE_EXIT" = abort ]; then printf 'ready\n' > abort.ready; sleep 5; fi
exit 23
LEG
  for mode in complete abort; do
    mkdir -p "$work/staging/wrappers"
    mkfifo "$work/ready" "$work/abort.ready"
    ec=0
    FIXTURE_EXIT="$mode" timeout -k 1 10 bash -c '
      . "$1/collector-functions.sh"
      set +m
      STAGING="$1/staging"
      if declare -F probe_containment >/dev/null; then probe_containment; fi
      run_wrapper escape "$1/escape.sh" "$1" unused "$STAGING/wrappers"
      if [ "$FIXTURE_EXIT" = abort ]; then
        # Wait for the leg to finish the double-fork handshake, then exercise EXIT.
        read -r ready < "$1/abort.ready"
        exit 19
      fi
      wait_wrappers
      # Hold normalization until after an escaped child would have rewritten raw.
      sleep 0.6
      normalize_single codex "$STAGING/wrappers/escape.raw" 0 "$1/normalized.json"
      STAGING=""
    ' _ "$work" > "$work/out" 2> "$work/err" || ec=$?
    namespace_descendants_gone() {
      [ -s "$work/child.pid" ] && [ ! -e "$work/rewritten" ] || return 1
      case "$(ps -o stat= -p "$(cat "$work/child.pid")")" in ''|Z*) ;; *) return 1 ;; esac
      if [ "$mode" = complete ]; then
        [ "$ec" -eq 0 ] && jq -e '.error == "original"' "$work/normalized.json" >/dev/null \
          && [ "$(cat "$work/staging/wrappers/escape.exit")" = 23 ]
      else [ "$ec" -eq 19 ]; fi
    }
    tr_check "PID namespace kills setsid double-fork before $mode normalization/cleanup" namespace_descendants_gone
    if [ "$mode" = complete ]; then
      tr_check "PID namespace wrapper is PID 1" test "$(cat "$work/init.pid")" = 1
      tr_check "PID namespace preserves caller uid" test "$(cat "$work/uid")" = "$(id -u)"
    fi
    # The base runner leaves the adversary alive; stop it before removing fixtures.
    [ ! -s "$work/child.pid" ] || kill -KILL "$(cat "$work/child.pid")" 2>/dev/null || true
    rm -rf "$work/staging" "$work/ready" "$work/abort.ready" "$work/rewritten" "$work/child.pid"
  done
  rm -rf "$work"
}

test_collector_namespace_failure_cleanup() {
  local work mode ec leg dead
  if ! unshare --user --map-current-user --pid --fork --kill-child true 2>/dev/null; then
    echo "  SKIP namespace failure cleanup: unprivileged namespaces unavailable"; SKIP=$((SKIP+1)); return
  fi
  work="$(mktemp -d)"
  sed '/^require_tools$/,$d' "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" > "$work/collector-functions.sh"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$work/lib.sh"
  git init -q "$work/repo"
  git -C "$work/repo" -c user.name=Fixture -c user.email=fixture@example.test commit -qm initial --allow-empty
  cat > "$work/blocked.sh" <<'LEG'
leg="${PWD##*/}"
read -r host_pid rest < /proc/self/stat
printf '%s\n' "$host_pid" > "../$leg.pid"
printf 'ready\n' > "../$leg.ready"
sleep 1
git config core.fsmonitor planted-by-surviving-leg
sleep 20
LEG
  for mode in die TERM; do
    mkdir -p "$work/staging/wrappers"
    mkfifo "$work/a.ready" "$work/b.ready"
    ec=0
    timeout -k 1 10 bash -c '
      . "$1/collector-functions.sh"
      set +m
      STAGING="$1/staging"
      SURFACE_ROOT="$1/repo"
      REVIEW_SOURCE="$SURFACE_ROOT"
      pin_git_surface
      probe_containment
      for leg in a b; do
        git -C "$REVIEW_SOURCE" worktree add --detach --quiet "$1/$leg" HEAD
        REVIEW_WORKTREES+=("$1/$leg")
        run_wrapper "$leg" "$1/blocked.sh" "$1/$leg" unused "$STAGING/wrappers"
      done
      read -r ready < "$1/a.ready"
      read -r ready < "$1/b.ready"
      # Cleanup must restore this mutation after terminating both blocked legs.
      command git -C "$SURFACE_ROOT" config core.fsmonitor planted-before-exit
      if [ "$2" = die ]; then die "git surface changed; collection rejected"; fi
      kill -TERM "$$"
    ' _ "$work" "$mode" > "$work/$mode.out" 2> "$work/$mode.err" || ec=$?
    tr_check "namespace $mode collector exits with failure" test "$ec" -eq 1
    dead=1
    for leg in a b; do
      if [ ! -s "$work/$leg.pid" ]; then dead=0; continue; fi
      case "$(ps -o stat= -p "$(cat "$work/$leg.pid")")" in ''|Z*) ;; *) dead=0 ;; esac
    done
    tr_check "namespace $mode both legs dead when collector exits" test "$dead" -eq 1
    sleep 2
    tr_check "namespace $mode fsmonitor stays unset after two seconds" \
      test -z "$(git -C "$work/repo" config --get core.fsmonitor || true)"
    tr_check "namespace $mode only main worktree remains registered" \
      test "$(git -C "$work/repo" worktree list --porcelain | sed -n 's/^worktree //p')" = "$work/repo"
    tr_check "namespace $mode staging removed" test ! -e "$work/staging"
    # Also clean up the intentionally failing pre-fix run.
    for leg in a b; do
      [ ! -s "$work/$leg.pid" ] || kill -KILL "$(cat "$work/$leg.pid")" 2>/dev/null || true
      git -C "$work/repo" worktree remove -f -f "$work/$leg" 2>/dev/null || true
    done
    git -C "$work/repo" config --unset core.fsmonitor || true
    rm -rf "$work/staging" "$work/a.ready" "$work/b.ready" "$work/a.pid" "$work/b.pid"
  done
  rm -rf "$work"
}

test_collector_completion_order() {
  local work ec=0
  work="$(mktemp -d)"
  sed '/^require_tools$/,$d' "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" > "$work/collector-functions.sh"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$work/lib.sh"
  mkdir -p "$work/staging/wrappers"
  mkfifo "$work/ready"
  cat > "$work/slow.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
exit 17
EOF
  cat > "$work/early.sh" <<'EOF'
#!/usr/bin/env bash
timeout 5 bash -c '
  trap "" TERM
  printf "ready\n" > ready
  sleep 0.5
  printf "forged\n" > staging/wrappers/early.raw
  touch rewritten
' >/dev/null 2>&1 &
read -r ready < ready
printf 'original\n'
exit 23
EOF
  bash -c '
    . "$1/collector-functions.sh"
    set +m
    STAGING="$1/staging"
    run_wrapper slow "$1/slow.sh" "$1" unused "$STAGING/wrappers"
    run_wrapper early "$1/early.sh" "$1" unused "$STAGING/wrappers"
    wait_wrappers
    STAGING=""
  ' _ "$work" > "$work/out" 2> "$work/err" || ec=$?
  completion_order_ok() {
    [ "$ec" -eq 0 ] && [ ! -e "$work/rewritten" ] \
      && [ "$(cat "$work/staging/wrappers/early.raw")" = original ] \
      && [ "$work/staging/wrappers/early.finished" -ot "$work/staging/wrappers/slow.finished" ]
  }
  completion_status_ok() {
    [ "$ec" -eq 0 ] && [ "$(cat "$work/staging/wrappers/early.exit")" = 23 ] \
      && [ "$(cat "$work/staging/wrappers/slow.exit")" = 17 ] \
      && [ -s "$work/staging/wrappers/early.finished" ] && [ -s "$work/staging/wrappers/slow.finished" ]
  }
  tr_check "finished leg descendants cannot rewrite raw output while an earlier leg runs" completion_order_ok
  tr_check "completion-order reaping retains each leg exit code and finished marker" completion_status_ok
  rm -rf "$work"
}

# Repo-walking legs must not walk a checkout holding untracked .env files (#589).
test_walk_root_hides_env_files() {
  local label="repo-walking legs walk a HEAD clone when the checkout holds .env files; shell legs get a scrubbed env" work fake host_grok leg ok=1
  work="$(mktemp -d)"; fake="$work/bin"; host_grok="$work/host-grok"
  mkdir -p "$fake" "$work/repo"
  install_grok_auth_fixture "$host_grok"
  local review='{"provider":"PROVIDER","model":"MODEL","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10.0,"verdict":"APPROVE"}}'
  review="${review/MODEL/qwen3.8-max}"
  cat > "$fake/codex" <<EOF
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do [ "\$1" = -C ] && dir="\$2"; shift; done
printf '%s %s %s\n' "\$dir" "\$([ -e "\$dir/.env" ] && echo env || echo noenv)" "\$(cat "\$dir/file.txt")" > "$work/codex.walk"
cat >/dev/null
printf '%s\n' '${review/PROVIDER/codex}'
EOF
  cat > "$fake/grok" <<EOF
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do [ "\$1" = --cwd ] && dir="\$2"; shift; done
printf '%s %s %s\n' "\$dir" "\$([ -e "\$dir/.env" ] && echo env || echo noenv)" "\$(cat "\$dir/file.txt")" > "$work/grok.walk"
printf '%s\n' '{"text":"done","stopReason":"EndTurn","sessionId":"11111111-1111-1111-1111-111111111111","structuredOutput":${review/PROVIDER/grok}}'
EOF
  cat > "$fake/qwen" <<EOF
#!/usr/bin/env bash
printf '%s %s %s %s %s\n' "\$PWD" "\$([ -e .env ] && echo env || echo noenv)" "\$(cat file.txt)" "\${LEG_SECRET-unset}" "\${OPENROUTER_API_KEY-unset}" > "$work/qwen.walk"
cat >/dev/null
printf '%s\n' '${review/PROVIDER/qwen}'
EOF
  cat > "$fake/dsh" <<EOF
#!/usr/bin/env bash
printf '%s %s %s %s\n' "\$PWD" "\$([ -e .env ] && echo env || echo noenv)" "\$(cat file.txt)" "\${LEG_SECRET-unset}" > "$work/deepseek.walk"
cat >/dev/null
jq -nc --arg text '${review/PROVIDER/deepseek}' '{type:"final",text:\$text}'
printf '%s\n' '{"type":"status","phase":"turn_end","reason":{"kind":"completed"}}'
EOF
  chmod +x "$fake/codex" "$fake/grok" "$fake/qwen" "$fake/dsh"
  (
    set -e
    cd "$work/repo"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf '.env\n' > .gitignore
    printf 'one\n' > file.txt
    git add .gitignore file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    printf 'dirty\n' > file.txt
    printf 'TOKEN=1\n' > .env
    export PATH="$fake:$PATH" GROK_HOME="$host_grok" TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_GROK=on TRIBUNAL_QWEN=on
    export DEEPSEEK_API_KEY=fixture TRIBUNAL_DEEPSEEK=on LEG_SECRET=leak OPENROUTER_API_KEY=or-key XDG_CONFIG_HOME="$work/xdg"
    unset TRIBUNAL_QWEN_MODEL
    bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/codex.json"
    env -u XAI_API_KEY bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/grok.json"
    bash "$PLUGIN_ROOT/scripts/run-qwen-review.sh" > "$work/qwen.json"
    bash "$PLUGIN_ROOT/scripts/run-deepseek-review.sh" | jq -c 'select(.provider=="deepseek")' > "$work/deepseek.json"
    for leg in codex grok qwen deepseek; do mv "$work/$leg.walk" "$work/$leg.envwalk"; done
    rm .env
    bash "$PLUGIN_ROOT/scripts/run-codex-review.sh" > "$work/codex-clean.json"
  ) || ok=0
  for leg in codex grok qwen deepseek; do
    jq -e '.summary.verdict=="APPROVE"' "$work/$leg.json" >/dev/null 2>&1 || ok=0
    read -r dir env content secret auth < "$work/$leg.envwalk" 2>/dev/null || ok=0
    [ "${dir:-}" != "$work/repo" ] && [ "${env:-}" = noenv ] && [ "${content:-}" = two ] || ok=0
    case "$leg" in qwen|deepseek) [ "${secret:-}" = unset ] || ok=0 ;; esac
    [ "$leg" != qwen ] || [ "${auth:-}" = or-key ] || ok=0
  done
  read -r dir env content < "$work/codex.walk" 2>/dev/null || ok=0
  [ "${dir:-}" = "$work/repo" ] || ok=0
  if [ "$ok" -eq 1 ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    for leg in codex grok qwen deepseek; do echo "    $leg: $(cat "$work/$leg.envwalk" 2>/dev/null) $(head -c 300 "$work/$leg.json" 2>/dev/null)" >&2; done
  fi
  rm -rf "$work"
}


test_collector_completion_order
test_collector_pid_namespace
test_collector_namespace_failure_cleanup
test_collector_reap_rescan
test_collector_config_includes
test_collector_surface_leftovers
test_collector_subdirectory_root
test_walk_root_hides_env_files
