# Runtime role, mutation ownership, lifecycle, and prompt-budget regressions.
declare -F make_workdir >/dev/null 2>&1 || {
  echo "runtime-safety.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_runtime_safety() {
  echo -e "\n${CYAN}Suite RS: runtime role and lifecycle safety${NC}"
  local workdir ec out count script owner_file state_dir snapshot patch_file patch_dir remote base old_owner trust_receipt auth_token
  local remote_clone branch progress_head custom_snapshot origin_sentinel injection_snapshot ssh_injector
  local linked git_dir common_dir raw_commondir guard_snapshot guard_auth real_jq path check_log
  local guard_head guard_ref guard_index concurrent_head tree main_next
  local check_pid check_signal check_release check_output check_status
  local supervisor_bwrap_dir limit_log_dir limit_log limit_bytes marker victim_dir started elapsed codex_calls
  local hanging_pid_file hanging_pid leaked_check
  local system_git failed_snapshot array_snapshot check_receipt commit_receipt parent_run
  local -a large_allow_args
  supervisor_bwrap_dir=$(mktemp -d)

  # Registered Claude dispatches and exact effort pins.
  out="$(grep -R -n 'subagent_type: "general-purpose"' \
    "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/references/workflows" \
    "$PLUGIN_ROOT/skills/startup-orchestration" 2>/dev/null || true)"
  assert_equals "RS1: no generic Claude role dispatch" "$out" ""
  assert_file_contains "RS2: startup business type" "$PLUGIN_ROOT/commands/startup.md" 'saas-startup-team:business-founder'
  assert_file_contains "RS3: improve maintenance type" "$PLUGIN_ROOT/references/workflows/improve.md" 'saas-startup-team:business-founder-maintain'
  assert_file_contains "RS4: growth hacker type" "$PLUGIN_ROOT/commands/growth.md" 'saas-startup-team:growth-hacker'
  assert_file_contains "RS5: lawyer type" "$PLUGIN_ROOT/commands/lawyer.md" 'saas-startup-team:lawyer'
  assert_file_contains "RS6: UX type" "$PLUGIN_ROOT/commands/ux-test.md" 'saas-startup-team:ux-tester'
  assert_file_contains "RS7: investigator type" "$PLUGIN_ROOT/commands/investigate.md" 'saas-startup-team:incident-investigator'
  assert_file_contains "RS8: replay type" "$PLUGIN_ROOT/commands/replay-abandoned.md" 'saas-startup-team:session-replay'
  assert_file_contains "RS9: support type" "$PLUGIN_ROOT/commands/operate.md" 'saas-startup-team:support-triage'
  assert_file_not_contains "RS9b: support worker never files GitHub issues" "$PLUGIN_ROOT/agents/support-triage.md" 'scripts/issue-file.sh'
  assert_file_contains "RS9c: support filing stays supervisor-owned" "$PLUGIN_ROOT/commands/operate.md" 'supervisor runs'
  assert_file_contains "RS10: triage type" "$PLUGIN_ROOT/references/workflows/maintain.md" 'saas-startup-team:maintain-triage'
  assert_file_contains "RS11: scoped browser operator" \
    "$PLUGIN_ROOT/references/browser-orchestration.md" 'saas-startup-team:browser-operator'
  assert_file_contains "RS11p0: business founder points at browser orchestration" \
    "$PLUGIN_ROOT/agents/business-founder.md" 'browser-orchestration.md'
  contract="$PLUGIN_ROOT/references/browser-operator-contract.md"
  assert_file_exists "RS11p1: shared browser-operator contract exists" "$contract"
  assert_file_contains "RS11a: operator rejects unavailable tools" "$contract" \
    'an MCP reported as pending, or zero callable browser tools'
  assert_file_contains "RS11b: operator rejects unobserved input echo" "$contract" \
    'never echo it as observed state without a completed tool call'
  assert_file_contains "RS11c: operator never retypes literal output" "$contract" \
    'byte-for-byte from the tool result; never retype'
  assert_file_contains "RS11d: operator has explicit tool gap" "$contract" \
    'tool gap: <tool> — <observed missing/pending/zero-tools state>'
  assert_file_contains "RS11e: operator has unavailable outcome" "$contract" \
    'outcome: tool-unavailable'
  assert_file_contains "RS11f: operator saves requested snapshots outside worktree" "$contract" \
    'Call `browser_snapshot` explicitly with a unique absolute filename matching `/tmp/saas-startup-team-snapshot-<run-id>-<checkpoint>.md`'
  assert_file_contains "RS11g: operator returns only snapshot artifact link" "$contract" \
    'Return only the exact Snapshot path/link emitted by that call'
  assert_file_contains "RS11h: operator rejects inline action snapshots" "$contract" \
    'never use them instead of the explicit saved call'
  for operator_file in browser-operator browser-operator-pro; do
    assert_file_contains "RS11i0/$operator_file: thin agent points at contract" \
      "$PLUGIN_ROOT/agents/$operator_file.md" 'browser-operator-contract.md'
  done
  out="$(diff -u \
    <(sed -n '/browser-operator-contract.md/,$p' "$PLUGIN_ROOT/agents/browser-operator.md" | tail -n +1) \
    <(sed -n '/browser-operator-contract.md/,$p' "$PLUGIN_ROOT/agents/browser-operator-pro.md" | tail -n +1) || true)"
  # Both stubs point at the same contract path (pro may have a one-line role note before the pointer).
  assert_file_contains "RS11i: both operators share one contract path" \
    "$PLUGIN_ROOT/agents/browser-operator-pro.md" 'browser-operator-contract.md'
  assert_file_contains "RS11j: Codex UX saves snapshots mechanically" \
    "$PLUGIN_ROOT/skills/ux-tester/SKILL.md" 'retain only its exact tool-provided path/link'
  assert_file_contains "RS11k: Codex UX rejects inline snapshots" \
    "$PLUGIN_ROOT/skills/ux-tester/SKILL.md" 'never retype the tree or substitute an inline snapshot'
  assert_file_contains "RS11l: Codex UX fails closed without browser tools" \
    "$PLUGIN_ROOT/skills/ux-tester/SKILL.md" 'zero callable browser tools'
  assert_file_contains "RS11m: Codex founder saves snapshots mechanically" \
    "$PLUGIN_ROOT/skills/business-founder/SKILL.md" 'retain only its tool-provided path/link'
  assert_file_contains "RS11n: Codex founder rejects retyped or inline snapshots" \
    "$PLUGIN_ROOT/skills/business-founder/SKILL.md" 'never a retyped or inline tree'
  assert_file_contains "RS11o: Codex founder fails closed without browser tools" \
    "$PLUGIN_ROOT/skills/business-founder/SKILL.md" 'missing/pending/zero browser tools'
  assert_file_contains "RS11p: maintenance founder returns unavailable transport explicitly" \
    "$PLUGIN_ROOT/agents/business-founder-maintain.md" 'outcome: tool-unavailable'
  assert_file_contains "RS11q: Codex UX retries browser transport only once" \
    "$PLUGIN_ROOT/skills/ux-tester/SKILL.md" 'one fresh-session retry'
  assert_file_contains "RS11r: Codex founder cannot turn transport loss into a verdict" \
    "$PLUGIN_ROOT/skills/business-founder/SKILL.md" 'never a product verdict'
  assert_file_contains "RS11s: Claude maintenance founder resolves browser guidance from the plugin root" \
    "$PLUGIN_ROOT/agents/business-founder-maintain.md" \
    '${CLAUDE_PLUGIN_ROOT}/skills/ux-tester/references/design-review-leg.md'

  check_frontmatter() {
    local agent="$1" model="$2" effort="$3" file="$PLUGIN_ROOT/agents/$1.md"
    assert_equals "RS model:$agent" "$(sed -n 's/^model: //p' "$file" | head -1)" "$model"
    assert_equals "RS effort:$agent" "$(sed -n 's/^effort: //p' "$file" | head -1)" "$effort"
  }
  check_frontmatter business-founder fable high
  check_frontmatter business-founder-maintain fable high
  check_frontmatter tech-founder-claude opus xhigh
  check_frontmatter tech-founder-claude-maintain opus xhigh
  check_frontmatter tech-founder-codex sonnet medium
  check_frontmatter tech-founder-codex-maintain sonnet medium
  check_frontmatter growth-hacker opus high
  check_frontmatter lawyer opus high
  check_frontmatter ux-tester sonnet high
  check_frontmatter incident-investigator sonnet high
  check_frontmatter session-replay sonnet low
  check_frontmatter browser-operator haiku low
  check_frontmatter browser-operator-pro sonnet low
  check_frontmatter support-triage haiku low
  check_frontmatter maintain-triage haiku low
  out="$(for controller in tech-founder-codex tech-founder-codex-maintain; do
    sed -n 's/^tools: //p' "$PLUGIN_ROOT/agents/$controller.md" | tr ',' '\n' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -x Edit \
      && printf '%s\n' "$controller" || true
  done)"
  assert_equals "RS12: Codex controllers have no Edit tool" "$out" ""
  assert_file_contains "RS13: Claude nested host documented" "$PLUGIN_ROOT/README.md" 'supports bounded nested browser operators'
  assert_file_contains "RS14: Codex flattened host documented" "$PLUGIN_ROOT/README.md" 'keeps the equivalent browser flow flattened'
  assert_file_contains "RS14a: shared thin mutation contract" \
    "$PLUGIN_ROOT/references/workflows/mutation-ownership.md" 'hooks-paused.sh'
  assert_file_contains "RS14b: startup uses mutation ownership flow" \
    "$PLUGIN_ROOT/commands/startup.md" 'references/workflows/mutation-ownership.md'
  assert_file_contains "RS14c: improve uses thin supervisor commit" \
    "$PLUGIN_ROOT/references/workflows/improve.md" 'supervisor-commit.sh'
  assert_file_contains "RS14d: lessons uses the mechanical firewall" \
    "$PLUGIN_ROOT/commands/lessons-deliver.md" '--firewall-script'
  assert_file_contains "RS14e: maintain routes the raw worker diff" \
    "$PLUGIN_ROOT/scripts/maintain-attempt.sh" 'check-diff --base "$base_sha"'
  assert_file_exists "RS14f1: network-off sandbox wrapper exists" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh"
  assert_file_contains "RS14f2: network-off sandbox uses the Codex proxy" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" '--enable network_proxy'
  assert_file_contains "RS14f3: network-off sandbox has no outbound destinations" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" 'network.mode="limited"'
  assert_file_not_contains "RS14f4: network-off sandbox preserves local socketpairs" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" '--sandbox-state-disable-network'
  assert_file_contains "RS14f5: network-off sandbox ignores ambient Codex config" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" 'CODEX_HOME="$ISOLATED_CODEX_HOME"'
  workdir=$(mktemp -d)
  mkdir -p "$workdir/ambient" "$workdir/bin" "$workdir/home"
  printf 'sandbox_mode = "danger-full-access"\n' > "$workdir/ambient/config.toml"
  cat > "$workdir/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ -n "${CODEX_HOME:-}" ]
[ "$CODEX_HOME" != "$AMBIENT_CODEX_HOME" ]
[ ! -e "$CODEX_HOME/config.toml" ]
[ "${1:-}" = sandbox ]
exit 0
SH
  chmod +x "$workdir/bin/codex"
  ec=0
  AMBIENT_CODEX_HOME="$workdir/ambient" CODEX_HOME="$workdir/ambient" HOME="$workdir/home" \
    CODEX_BIN="$workdir/bin/codex" \
    bash "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" /bin/true || ec=$?
  assert_exit_code "RS14f6: hostile ambient Codex config is isolated" "$ec" 0
  assert_equals "RS14f7: temporary Codex config home is removed" \
    "$(find "$workdir/home/.cache" -maxdepth 1 -name 'saas-codex-sandbox.*' -print)" ""
  rm -rf "$workdir"
  assert_file_contains "RS14g: lessons runs firewall in thin commit" \
    "$PLUGIN_ROOT/commands/lessons-deliver.md" '--firewall-script'
  for paused_hook in auto-commit.sh auto-commit-growth.sh auto-learn.sh compact-state.sh index-handoff.sh; do
    assert_file_contains "RS14 hook defers:$paused_hook" \
      "$PLUGIN_ROOT/scripts/$paused_hook" 'hooks-paused.sh'
  done

  # Stable owner-file survives separate shell PIDs and cleanup is idempotent.
  script="$PLUGIN_ROOT/scripts/single-flight.sh"; state_dir=$(mktemp -d); owner_file="$state_dir/.owners/run.owner"
  bash "$script" --acquire issue/42 --state-dir "$state_dir" --owner-file "$owner_file" >/dev/null
  assert_file_exists "RS22: acquire persisted owner token" "$owner_file"
  bash "$script" --heartbeat issue/42 --state-dir "$state_dir" --owner-file "$owner_file" >/dev/null
  out=$(bash "$script" --status issue/42 --state-dir "$state_dir" --json)
  assert_equals "RS23: active status JSON" "$(jq -r .state <<<"$out")" "active"
  bash "$script" --release issue/42 --state-dir "$state_dir" --owner-file "$owner_file" >/dev/null
  assert_file_not_exists "RS24: release removes owner token" "$owner_file"
  ec=0; bash "$script" --release issue/42 --state-dir "$state_dir" --owner-file "$owner_file" >/dev/null || ec=$?
  assert_exit_code "RS25: repeated release is idempotent" "$ec" 0
  out=$(bash "$script" --status issue/42 --state-dir "$state_dir" --json)
  assert_equals "RS26: missing status JSON" "$(jq -r .state <<<"$out")" "missing"
  assert_equals "RS27: missing status age is null" "$(jq -r .age_seconds <<<"$out")" "null"
  rm -rf "$state_dir"

  # Same-key concurrency keeps one durable identity; owner files cannot cross keys.
  state_dir=$(mktemp -d); owner_file="$state_dir/.owners/concurrent.owner"; pids=()
  for count in $(seq 1 12); do
    bash "$script" --acquire concurrent/key --state-dir "$state_dir" --owner-file "$owner_file" >"$state_dir/$count.out" 2>&1 &
    pids+=("$!")
  done
  count=0
  for pid in "${pids[@]}"; do if wait "$pid"; then count=$((count + 1)); fi; done
  assert_equals "RS27a: exactly one concurrent acquire wins" "$count" "1"
  assert_file_exists "RS27b: concurrent owner token survives" "$owner_file"
  assert_equals "RS27c: owner file matches lease" "$(sed -n '1p' "$owner_file")" "$(cat "$state_dir/concurrent-key/owner")"
  ec=0; bash "$script" --acquire other/key --state-dir "$state_dir" --owner-file "$owner_file" >/dev/null 2>&1 || ec=$?
  assert_exit_code "RS27d: one owner file cannot bind two keys" "$ec" 2
  bash "$script" --release concurrent/key --state-dir "$state_dir" --owner-file "$owner_file" >/dev/null

  owner_file="$state_dir/.owners/stale.owner"
  bash "$script" --acquire stale/key --state-dir "$state_dir" --owner-file "$owner_file" >/dev/null
  old_owner="$(cat "$owner_file")"; printf '1\n' > "$state_dir/stale-key/heartbeat"
  bash "$script" --acquire stale/key --state-dir "$state_dir" --owner-file "$owner_file" \
    --ttl-seconds 1 --replace-stale --reason test >/dev/null
  assert_equals "RS27e: stale takeover mints a new token" "$([[ "$(cat "$owner_file")" != "$old_owner" ]] && echo yes || echo no)" yes
  assert_equals "RS27f: replacement lease uses new token" "$(cat "$state_dir/stale-key/owner")" "$(cat "$owner_file")"
  bash "$script" --release stale/key --state-dir "$state_dir" --owner-file "$owner_file" >/dev/null
  rm -rf "$state_dir"

  # tweak-run always restores the previous active_role.
  make_tweak_repo() {
    workdir=$(make_workdir); (cd "$workdir" && git config user.email t@t.t && git config user.name t)
    mkdir -p "$workdir/.startup"; printf '{"active_role":"team-lead"}\n' > "$workdir/.startup/state.json"
    printf 'body { color: red; }\n' > "$workdir/styles.css"
    printf 'const enabled = false;\n' > "$workdir/app.js"
    printf 'Welcomme to the docs.\n' > "$workdir/README.md"
    printf 'safe\n' > "$workdir/secret.txt"
    (cd "$workdir" && git add . && git commit -qm init)
  }
  simple_patch() {
    patch_file="$1"
    cat > "$patch_file" <<'PATCH'
diff --git a/styles.css b/styles.css
--- a/styles.css
+++ b/styles.css
@@ -1 +1 @@
-body { color: red; }
+body { color: blue; }
PATCH
  }
  docs_patch() {
    patch_file="$1"
    cat > "$patch_file" <<'PATCH'
diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-Welcomme to the docs.
+Welcome to the docs.
PATCH
  }
  script="$PLUGIN_ROOT/scripts/tweak-run.sh"
  make_tweak_repo; patch_file=$(mktemp); simple_patch "$patch_file"; remote=$(mktemp -d); git init -q --bare "$remote"; (cd "$workdir" && git remote add origin "$remote")
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode current --push 2>&1) || ec=$?
  assert_exit_code "RS28: tweak success" "$ec" 0
  assert_equals "RS29: role restored after success" "$(jq -r .active_role "$workdir/.startup/state.json")" "team-lead"
  assert_equals "RS29p0: absent tweak parent preserves unparented events" \
    "$(jq -s '[.[].parent_run_id] | unique == [null]' "$workdir/.startup/runs/agent-events.jsonl")" true
  rm -rf "$workdir" "$remote" "$patch_file"

  parent_run=run-22222222222222222222222222222222
  make_tweak_repo; patch_file=$(mktemp); simple_patch "$patch_file"
  ec=0; out=$(cd "$workdir" && SAAS_RUN_ID=tweak-parented SAAS_PARENT_RUN_ID="$parent_run" \
    bash "$script" --patch "$patch_file" --message tweak --mode current 2>&1) || ec=$?
  assert_exit_code "RS29p1: tweak accepts a canonical parent" "$ec" 0
  assert_equals "RS29p2: every tweak event propagates the parent" \
    "$(jq -s --arg parent "$parent_run" \
      'length == 2 and all(.[]; .parent_run_id == $parent)' "$workdir/.startup/runs/agent-events.jsonl")" true
  rm -rf "$workdir" "$patch_file"

  make_tweak_repo; patch_file=$(mktemp); simple_patch "$patch_file"; base=$(git -C "$workdir" rev-parse HEAD)
  ec=0; out=$(cd "$workdir" && SAAS_RUN_ID=tweak-invalid SAAS_PARENT_RUN_ID=invalid \
    bash "$script" --patch "$patch_file" --message tweak --mode current 2>&1) || ec=$?
  assert_exit_code "RS29p3: tweak rejects an invalid parent" "$ec" 2
  assert_equals "RS29p4: invalid parent leaves tweak HEAD unchanged" "$(git -C "$workdir" rev-parse HEAD)" "$base"
  rm -rf "$workdir" "$patch_file"

  parent_run=run-33333333333333333333333333333333
  make_tweak_repo; patch_file=$(mktemp); simple_patch "$patch_file"; base=$(git -C "$workdir" rev-parse HEAD)
  ec=0; out=$(cd "$workdir" && SAAS_RUN_ID="$parent_run" SAAS_PARENT_RUN_ID="$parent_run" \
    bash "$script" --patch "$patch_file" --message tweak --mode current 2>&1) || ec=$?
  assert_exit_code "RS29p5: tweak rejects parent equal to child" "$ec" 2
  assert_equals "RS29p6: equal parent leaves tweak HEAD unchanged" "$(git -C "$workdir" rev-parse HEAD)" "$base"
  rm -rf "$workdir" "$patch_file"

  make_tweak_repo; mkdir -p "$workdir/.startup/runs"; : > "$workdir/.startup/runs/agent-events.jsonl"; : > "$workdir/.startup/runs/agent-events.jsonl.lock"
  patch_file=$(mktemp); simple_patch "$patch_file"
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode current 2>&1) || ec=$?
  assert_exit_code "RS29a: prior local telemetry does not block next tweak" "$ec" 0
  rm -rf "$workdir" "$patch_file"

  make_tweak_repo; mkdir -p "$workdir/.startup/runs"
  printf '{"private":"raw"}\n' > "$workdir/.startup/runs/agent-events.jsonl"
  (cd "$workdir" && git add .startup/runs/agent-events.jsonl)
  patch_file=$(mktemp); simple_patch "$patch_file"; base=$(git -C "$workdir" rev-parse HEAD)
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode current 2>&1) || ec=$?
  assert_exit_code "RS29b: staged runtime telemetry blocks tweak commit" "$ec" 1
  assert_equals "RS29c: staged telemetry rejection leaves HEAD unchanged" "$(git -C "$workdir" rev-parse HEAD)" "$base"
  rm -rf "$workdir" "$patch_file"

  make_tweak_repo; patch_file=$(mktemp)
  { echo 'diff --git a/styles.css b/styles.css'; echo '--- a/styles.css'; echo '+++ b/styles.css'; echo '@@ -1 +1,16 @@'; echo '-body { color: red; }'; for n in $(seq 1 16); do echo "+.x$n { color: red; }"; done; } > "$patch_file"
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode current 2>&1) || ec=$?
  assert_exit_code "RS30: containment rejection" "$ec" 20
  assert_equals "RS31: role restored after rejection" "$(jq -r .active_role "$workdir/.startup/state.json")" "team-lead"
  rm -rf "$workdir" "$patch_file"

  make_tweak_repo; patch_file=$(mktemp); simple_patch "$patch_file"; printf '#!/bin/sh\nexit 1\n' > "$workdir/.git/hooks/pre-commit"; chmod +x "$workdir/.git/hooks/pre-commit"
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode current 2>&1) || ec=$?
  [ "$ec" -ne 0 ] || ec=99
  assert_equals "RS32: hook failure is nonzero" "$ec" "1"
  assert_equals "RS33: role restored after hook failure" "$(jq -r .active_role "$workdir/.startup/state.json")" "team-lead"
  rm -rf "$workdir" "$patch_file"

  make_tweak_repo; patch_file=$(mktemp); simple_patch "$patch_file"
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode current --push --remote missing 2>&1) || ec=$?
  [ "$ec" -ne 0 ] || ec=99
  assert_equals "RS34: push failure is nonzero" "$ec" "128"
  assert_equals "RS35: role restored after push failure" "$(jq -r .active_role "$workdir/.startup/state.json")" "team-lead"
  rm -rf "$workdir" "$patch_file"

  make_tweak_repo; patch_file=$(mktemp)
  cat > "$patch_file" <<'PATCH'
diff --git a/app.js b/app.js
--- a/app.js
+++ b/app.js
@@ -1 +1 @@
-const enabled = false;
+const enabled = true;
PATCH
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode current 2>&1) || ec=$?
  assert_exit_code "RS35a: behavioral code requires escalation" "$ec" 20
  assert_equals "RS35b: role restored after behavioral rejection" "$(jq -r .active_role "$workdir/.startup/state.json")" team-lead
  rm -rf "$workdir" "$patch_file"

  make_tweak_repo; patch_file=$(mktemp); simple_patch "$patch_file"
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode current --routing-mode autonomous 2>&1) || ec=$?
  assert_exit_code "RS35c: autonomous UI tweak requires escalation" "$ec" 20
  rm -rf "$workdir" "$patch_file"

  # A hook may not expand the checked tree, and a deleted state file is restored byte-for-byte.
  make_tweak_repo; patch_file=$(mktemp); simple_patch "$patch_file"; state_before=$(cat "$workdir/.startup/state.json")
  cat > "$workdir/.git/hooks/pre-commit" <<'SH'
#!/usr/bin/env bash
printf 'hooked\n' > secret.txt
git add secret.txt
SH
  chmod +x "$workdir/.git/hooks/pre-commit"
  remote=$(mktemp -d); git init -q --bare "$remote"; (cd "$workdir" && git remote add origin "$remote" && git push -q -u origin HEAD)
  base=$(git -C "$workdir" rev-parse HEAD)
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode current --push 2>&1) || ec=$?
  assert_exit_code "RS35d: hook-expanded tree blocks push" "$ec" 1
  assert_equals "RS35e: remote remains at checked base" "$(git --git-dir="$remote" rev-parse HEAD)" "$base"
  assert_equals "RS35f: state survives hook expansion" "$(cat "$workdir/.startup/state.json")" "$state_before"
  rm -rf "$workdir" "$patch_file" "$remote"

  make_tweak_repo; patch_file=$(mktemp); simple_patch "$patch_file"; state_before=$(cat "$workdir/.startup/state.json")
  printf '#!/usr/bin/env bash\nrm -f .startup/state.json\nexit 1\n' > "$workdir/.git/hooks/pre-commit"
  chmod +x "$workdir/.git/hooks/pre-commit"
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode current 2>&1) || ec=$?
  assert_exit_code "RS35g: state-deleting hook fails" "$ec" 1
  assert_equals "RS35h: deleted state is restored exactly" "$(cat "$workdir/.startup/state.json")" "$state_before"
  rm -rf "$workdir" "$patch_file"

  # Both early and semantic exit-20 paths clean a newly-created tweak branch.
  make_tweak_repo; patch_file=$(mktemp); parent=$(git -C "$workdir" branch --show-current)
  cat > "$patch_file" <<'PATCH'
diff --git a/new.css b/new.css
new file mode 100644
--- /dev/null
+++ b/new.css
@@ -0,0 +1 @@
+body { color: blue; }
PATCH
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode new-branch --branch tweak/early --parent "$parent" 2>&1) || ec=$?
  assert_exit_code "RS35i: new-file tweak rejects early" "$ec" 20
  assert_equals "RS35j: early rejection returns to parent" "$(git -C "$workdir" branch --show-current)" "$parent"
  assert_equals "RS35k: early rejection deletes branch" "$(git -C "$workdir" show-ref --verify --quiet refs/heads/tweak/early && echo exists || echo missing)" missing
  rm -rf "$workdir" "$patch_file"

  make_tweak_repo; patch_file=$(mktemp); parent=$(git -C "$workdir" branch --show-current)
  cat > "$patch_file" <<'PATCH'
diff --git a/app.js b/app.js
--- a/app.js
+++ b/app.js
@@ -1 +1 @@
-const enabled = false;
+const enabled = true;
PATCH
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak --mode new-branch --branch tweak/route --parent "$parent" 2>&1) || ec=$?
  assert_exit_code "RS35l: behavioral branch tweak rejects" "$ec" 20
  assert_equals "RS35m: route rejection returns to parent" "$(git -C "$workdir" branch --show-current)" "$parent"
  assert_equals "RS35n: route rejection deletes branch" "$(git -C "$workdir" show-ref --verify --quiet refs/heads/tweak/route && echo exists || echo missing)" missing
  rm -rf "$workdir" "$patch_file"

  # Autonomous new-branch failures leave neither a product diff nor a local branch.
  make_tweak_repo; patch_file=$(mktemp); docs_patch "$patch_file"; parent=$(git -C "$workdir" branch --show-current)
  ec=0; out=$(cd "$workdir" && STARTUP_MAX_STAGED_MB=0 bash "$script" --patch "$patch_file" --message tweak \
    --mode new-branch --branch tweak/size --parent "$parent" --routing-mode autonomous 2>&1) || ec=$?
  assert_exit_code "RS35o: staged-size failure escalates" "$ec" 20
  assert_equals "RS35p: staged-size cleanup returns to parent" "$(git -C "$workdir" branch --show-current)" "$parent"
  assert_equals "RS35q: staged-size cleanup deletes branch" "$(git -C "$workdir" show-ref --verify --quiet refs/heads/tweak/size && echo exists || echo missing)" missing
  assert_equals "RS35r: staged-size cleanup restores product tree" "$(git -C "$workdir" diff -- README.md)" ""
  rm -rf "$workdir" "$patch_file"

  make_tweak_repo; patch_file=$(mktemp); docs_patch "$patch_file"; parent=$(git -C "$workdir" branch --show-current)
  printf '#!/bin/sh\nexit 1\n' > "$workdir/.git/hooks/pre-commit"; chmod +x "$workdir/.git/hooks/pre-commit"
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak \
    --mode new-branch --branch tweak/hook --parent "$parent" --routing-mode autonomous 2>&1) || ec=$?
  assert_exit_code "RS35s: autonomous hook failure propagates" "$ec" 1
  assert_equals "RS35t: hook cleanup returns to parent" "$(git -C "$workdir" branch --show-current)" "$parent"
  assert_equals "RS35u: hook cleanup deletes branch" "$(git -C "$workdir" show-ref --verify --quiet refs/heads/tweak/hook && echo exists || echo missing)" missing
  assert_equals "RS35v: hook cleanup restores product tree" "$(git -C "$workdir" diff -- README.md)" ""
  rm -rf "$workdir" "$patch_file"

  make_tweak_repo; patch_file=$(mktemp); docs_patch "$patch_file"; parent=$(git -C "$workdir" branch --show-current)
  remote=$(mktemp -d); git init -q --bare "$remote"
  printf '#!/bin/sh\nexit 1\n' > "$remote/hooks/pre-receive"; chmod +x "$remote/hooks/pre-receive"
  (cd "$workdir" && git remote add origin "$remote")
  ec=0; out=$(cd "$workdir" && bash "$script" --patch "$patch_file" --message tweak \
    --mode new-branch --branch tweak/push --parent "$parent" --routing-mode autonomous --push 2>&1) || ec=$?
  [ "$ec" -ne 0 ] || ec=99
  assert_equals "RS35w: autonomous push failure propagates" "$ec" "1"
  assert_equals "RS35x: push cleanup returns to parent" "$(git -C "$workdir" branch --show-current)" "$parent"
  assert_equals "RS35y: push cleanup deletes local branch" "$(git -C "$workdir" show-ref --verify --quiet refs/heads/tweak/push && echo exists || echo missing)" missing
  assert_equals "RS35z: rejected push creates no remote branch" "$(git --git-dir="$remote" show-ref --verify --quiet refs/heads/tweak/push && echo exists || echo missing)" missing
  assert_equals "RS35za: push cleanup restores product tree" "$(git -C "$workdir" diff -- README.md)" ""
  rm -rf "$workdir" "$patch_file" "$remote"

  assert_file_contains "RS35zb: tweak workflow preserves helper status" "$PLUGIN_ROOT/references/workflows/tweak.md" '|| helper_rc=$?'
  assert_file_contains "RS35zc: tweak workflow branches on helper status" "$PLUGIN_ROOT/references/workflows/tweak.md" 'case "$helper_rc" in'

  # Default-branch resolution prefers GitHub, then a verified origin/HEAD, and never guesses.
  script="$PLUGIN_ROOT/scripts/default-branch.sh"; workdir=$(make_workdir); mkdir -p "$workdir/bin"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t \
    && printf 'base\n' > README.md && git add README.md && git commit -qm init)
  cat > "$workdir/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "repo view" ] || exit 2
printf 'master\n'
SH
  chmod +x "$workdir/bin/gh"
  out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script")
  assert_equals "RS35zd: GitHub master default is preserved" "$out" master
  cat > "$workdir/bin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  git -C "$workdir" remote add origin git@github.com:owner/repo.git
  git -C "$workdir" update-ref refs/remotes/origin/trunk HEAD
  git -C "$workdir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --repo owner/repo 2>&1) || ec=$?
  assert_exit_code "RS35ze: GitHub API failure uses verified origin HEAD" "$ec" 0
  assert_equals "RS35zf: origin trunk default is preserved" "$out" trunk
  git -C "$workdir" symbolic-ref --delete refs/remotes/origin/HEAD
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --repo owner/repo 2>&1) || ec=$?
  assert_exit_code "RS35zg: unresolved default branch fails closed" "$ec" 1
  assert_output_not_contains "RS35zh: resolver never guesses main" "$out" "main"
  rm -rf "$workdir"
  out="$(grep -EnH 'gh repo view.*defaultBranchRef|echo[[:space:]]+main|origin/main' \
    "$PLUGIN_ROOT/references/workflows/tweak.md" \
    "$PLUGIN_ROOT/references/workflows/improve.md" \
    "$PLUGIN_ROOT/references/workflows/goal-deliver.md" \
    "$PLUGIN_ROOT/references/workflows/maintain.md" \
    "$PLUGIN_ROOT/references/workflows/maintain-protocol.md" \
    "$PLUGIN_ROOT/commands/startup.md" \
    "$PLUGIN_ROOT/commands/lessons-deliver.md" \
    "$PLUGIN_ROOT/docs/design/lessons-deliver.md" 2>/dev/null || true)"
  assert_equals "RS35zi: active mutation flows never guess a default branch" "$out" ""
  assert_file_contains "RS35zj: queue builder uses shared default resolver" "$PLUGIN_ROOT/scripts/maintain-queue.sh" 'default-branch.sh'

  # Model-free probe paths: no script contains an assistant launch.
  script="$PLUGIN_ROOT/scripts/workflow-probe.sh"
  assert_file_not_contains "RS36: probe never launches Claude" "$script" 'claude -p'
  assert_file_not_contains "RS37: probe never launches Codex" "$script" 'codex exec'
  assert_file_not_contains "RS37a: probe never invokes the obsolete sandbox checker" \
    "$script" 'codex-sandbox-check.sh'
  assert_file_not_exists "RS37b: obsolete Codex worker sandbox checker is removed" \
    "$PLUGIN_ROOT/scripts/codex-sandbox-check.sh"
  assert_file_contains "RS37b1: maintenance readiness checks bounded Codex auth" \
    "$script" 'timeout 10 codex login status'
  assert_file_contains "RS37c: every separate Codex role uses unrestricted mode" \
    "$PLUGIN_ROOT/scripts/codex-run-role.sh" 'CODEX_SANDBOX_ARGS=(--dangerously-bypass-approvals-and-sandbox)'
  assert_file_not_contains "RS37d: legacy maintain adapter cannot narrow Codex workers" \
    "$PLUGIN_ROOT/scripts/maintain-attempt.sh" 'CODEX_SANDBOX='
  assert_file_not_contains "RS37e: standard evaluation cannot narrow its AI worker" \
    "$PLUGIN_ROOT/scripts/standard-medium-eval.sh" 'SAAS_CODEX_NETWORK_ACCESS='
  workdir=$(make_workdir); mkdir -p "$workdir/bin"
  cat > "$workdir/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") printf '%s\n' "${GH_ISSUES_JSON:-[]}" ;;
  "pr list") printf '%s\n' "${GH_PRS_JSON:-[]}" ;;
  "repo view") printf 'main\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$workdir/bin/gh"
  cat > "$workdir/bin/codex" <<'SH'
#!/bin/sh
if [ "${1:-}" = sandbox ]; then
  root=
  previous=
  for argument in "$@"; do
    if [ "$previous" = -C ]; then root=$argument; fi
    previous=$argument
  done
  case " $* " in *" /bin/pwd "*) printf '%s\n' "$root" ;; esac
fi
exit 0
SH
  cat > "$workdir/bin/bwrap" <<'SH'
#!/bin/sh
exit 0
SH
  cat > "$workdir/bin/check-driver" <<'SH'
#!/bin/sh
if [ "${1:-}" = --metadata ]; then
  printf '%s\n' '{"docker":{"path":"/usr/bin/false"},"daemon_id":"test","image_id":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}'
fi
exit 0
SH
  chmod +x "$workdir/bin/codex" "$workdir/bin/bwrap" "$workdir/bin/check-driver"
  SAAS_SUPERVISOR_CHECK_DRIVER="$workdir/bin/check-driver"
  export SAAS_SUPERVISOR_CHECK_DRIVER
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" maintain 2>&1) || ec=$?
  assert_exit_code "RS38: empty maintain queue is model-free no-op" "$ec" 3
  ec=0; out=$(cd "$workdir" && bash "$script" monitor-nightly 2>&1) || ec=$?
  assert_exit_code "RS40: unconfigured monitor is no-op" "$ec" 3
  mkdir -p "$workdir/.claude" "$workdir/.startup" "$workdir/docs"
  cat > "$workdir/.startup/healthy-check.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${MONITOR_SINCE:-}" ] && [ -n "${MONITOR_SINCE_MINUTES:-}" ] || exit 9
count=0; [ ! -f .startup/custom-count ] || count=$(cat .startup/custom-count)
printf '%s\n' "$((count + 1))" > .startup/custom-count
SH
  chmod +x "$workdir/.startup/healthy-check.sh"
  printf 'monitor:\n  custom_checks: .startup/healthy-check.sh\n' > "$workdir/.claude/saas-startup-team.local.md"
  ec=0; out=$(cd "$workdir" && bash "$script" monitor-nightly 2>&1) || ec=$?
  assert_exit_code "RS40a: healthy configured monitor is model-free no-op" "$ec" 3
  assert_equals "RS40b: healthy custom check runs once" "$(cat "$workdir/.startup/custom-count")" 1
  cat > "$workdir/.startup/healthy-check.sh" <<'SH'
#!/usr/bin/env bash
count=0; [ ! -f .startup/custom-count ] || count=$(cat .startup/custom-count)
count=$((count + 1)); printf '%s\n' "$count" > .startup/custom-count
[ "$count" -ne 1 ] || printf '%s\n' '{"pattern_key":"ops:once","severity":"high","entity":null,"title":"once","body":"once"}'
SH
  printf '0\n' > "$workdir/.startup/custom-count"
  ec=0; out=$(cd "$workdir" && bash "$script" monitor-nightly 2>&1) || ec=$?
  assert_exit_code "RS40c: one-shot custom finding launches monitor" "$ec" 0
  assert_file_contains "RS40d: one-shot finding is preserved" "$workdir/.startup/monitor-state.json.probe-findings" 'ops:once'
  ec=0; out=$(cd "$workdir" && bash "$script" monitor-nightly 2>&1) || ec=$?
  assert_exit_code "RS40d1: retry reuses preserved one-shot finding" "$ec" 0
  assert_equals "RS40d2: retry does not rerun one-shot custom check" "$(cat "$workdir/.startup/custom-count")" 1
  assert_file_contains "RS40e: monitor command consumes probe output" "$PLUGIN_ROOT/commands/monitor-nightly.md" 'PROBE_FINDINGS'
  external_marker=$(mktemp -d); printf 'failed\n' > "$external_marker/api-last-failure.txt"
  printf 'monitor:\n  marker_dir: %s\n  custom_checks: /nonexistent\n' "$external_marker" > "$workdir/.claude/saas-startup-team.local.md"
  ec=0; out=$(cd "$workdir" && bash "$script" monitor-nightly 2>&1) || ec=$?
  assert_exit_code "RS40f: absolute marker directory is honored" "$ec" 0
  rm -rf "$external_marker"
  ec=0; out=$(cd "$workdir" && env -u SAAS_NOTIFY_KIND -u SAAS_NOTIFY_URL bash "$script" digest 2>&1) || ec=$?
  assert_exit_code "RS41: unconfigured digest is no-op" "$ec" 3
  ec=0; out=$(cd "$workdir" && env -u SAAS_PLUGIN_REPO bash "$script" lessons-deliver 2>&1) || ec=$?
  assert_exit_code "RS42: unpinned lessons workflow is no-op" "$ec" 3
  cp "$PLUGIN_ROOT/templates/human-tasks.md" "$workdir/docs/human-tasks.md"
  ec=0; out=$(cd "$workdir" && SAAS_NOTIFY_KIND=webhook SAAS_NOTIFY_URL=https://example.invalid bash "$script" digest 2>&1) || ec=$?
  assert_exit_code "RS42a: commented task template stays a configured no-op" "$ec" 3
  printf '## Pending\n- [ ] Review\n' > "$workdir/docs/human-tasks.md"
  ec=0; out=$(cd "$workdir" && SAAS_NOTIFY_KIND=ntfy env -u SAAS_NOTIFY_URL bash "$script" digest 2>&1) || ec=$?
  assert_exit_code "RS43: half-configured digest fails closed" "$ec" 1
  ec=0; out=$(cd "$workdir" && bash "$script" digest --date ../../bad 2>&1) || ec=$?
  assert_exit_code "RS44: invalid digest date propagates usage failure" "$ec" 2
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" maintain --issue 01 2>&1) || ec=$?
  assert_exit_code "RS45: invalid probe issue is rejected" "$ec" 2
  mkdir -p "$workdir/.startup/maintain"
  printf '%s\n' '{"schema_version":0,"routing_schema_version":0,"number":42,"updatedAt":"2026-01-01T00:00:00Z","verdict":"needs-human"}' > "$workdir/.startup/maintain/triage-cache.jsonl"
  ec=0; out=$(cd "$workdir" && GH_ISSUES_JSON='[{"number":42,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' PATH="$workdir/bin:$PATH" bash "$script" maintain 2>&1) || ec=$?
  assert_exit_code "RS46: stale routing schema reopens triage" "$ec" 0
  routing_schema=$(bash "$PLUGIN_ROOT/scripts/delivery-route.sh" schema-version | jq -r .schema_version)
  printf '{"schema_version":1,"routing_schema_version":%s,"number":42,"updatedAt":"2026-01-01T00:00:00Z","verdict":"needs-human"}\n' \
    "$routing_schema" > "$workdir/.startup/maintain/triage-cache.jsonl"
  ec=0; out=$(cd "$workdir" && GH_ISSUES_JSON='[{"number":42,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' PATH="$workdir/bin:$PATH" bash "$script" maintain 2>&1) || ec=$?
  assert_exit_code "RS46a: crashed needs-human verdict resumes before finalization" "$ec" 0
  printf '{"schema_version":1,"routing_schema_version":%s,"number":42,"updatedAt":"2026-01-01T00:00:00Z","verdict":"needs-human","final_state":"triaged"}\n' \
    "$routing_schema" > "$workdir/.startup/maintain/triage-cache.jsonl"
  ec=0; out=$(cd "$workdir" && GH_ISSUES_JSON='[{"number":42,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' PATH="$workdir/bin:$PATH" bash "$script" maintain 2>&1) || ec=$?
  assert_exit_code "RS46b: nonterminal needs-human state remains resumable" "$ec" 0
  printf '{"schema_version":1,"routing_schema_version":%s,"number":42,"updatedAt":"2026-01-01T00:00:00Z","verdict":"needs-human","final_state":"needs-human:parked"}\n' \
    "$routing_schema" > "$workdir/.startup/maintain/triage-cache.jsonl"
  ec=0; out=$(cd "$workdir" && GH_ISSUES_JSON='[{"number":42,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' PATH="$workdir/bin:$PATH" bash "$script" maintain 2>&1) || ec=$?
  assert_exit_code "RS46c: finalized needs-human verdict is a no-op" "$ec" 3
  printf '{bad\n' > "$workdir/.startup/maintain/triage-cache.jsonl"
  ec=0; out=$(cd "$workdir" && GH_ISSUES_JSON='[{"number":42,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]' PATH="$workdir/bin:$PATH" bash "$script" maintain 2>&1) || ec=$?
  assert_exit_code "RS47: malformed triage cache fails closed" "$ec" 1
  unset SAAS_SUPERVISOR_CHECK_DRIVER
  rm -rf "$workdir"

  # Maintenance probes verify Codex authentication without launching a model.
  workdir=$(make_workdir); mkdir -p "$workdir/bin"
  codex_calls="$workdir/codex-calls"
  probe_issues='[{"number":42,"updatedAt":"2026-01-01T00:00:00Z","labels":[]}]'
  cat > "$workdir/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") printf '%s\n' "${GH_ISSUES_JSON:-[]}" ;;
  "pr list") printf '%s\n' "${GH_PRS_JSON:-[]}" ;;
  "repo view") printf 'main\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$workdir/bin/codex" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_CODEX_CALLS"
if [ "$1" = "sandbox" ] && [ "${2:-}" = "--help" ]; then exit 0; fi
if [ "$1" = "sandbox" ]; then
  printf '%s\n' "bwrap: No permissions to create a new namespace" >&2
  exit 1
fi
if [ "$1" = "login" ] && [ "${2:-}" = "status" ]; then
  [ "${FAKE_CODEX_AUTH_OK:-1}" -eq 1 ]
  exit $?
fi
exit 0
SH
  cat > "$workdir/bin/sysctl" <<'SH'
#!/bin/sh
shift $(( $# - 1 ))
case "$1" in
  kernel.unprivileged_userns_clone) echo "${FAKE_USERNS_CLONE:-1}" ;;
  user.max_user_namespaces) echo 2059994 ;;
  kernel.apparmor_restrict_unprivileged_userns) echo 1 ;;
  *) exit 1 ;;
esac
SH
  cat > "$workdir/bin/python3" <<'SH'
#!/bin/sh
echo "ptrace: Operation not permitted" >&2
exit 1
SH
  chmod +x "$workdir/bin/gh" "$workdir/bin/codex" "$workdir/bin/sysctl" "$workdir/bin/python3"
  ec=0; out=$(cd "$workdir" && FAKE_CODEX_CALLS="$codex_calls" GH_ISSUES_JSON="$probe_issues" PATH="$workdir/bin:$PATH" bash "$script" maintain 2>&1) || ec=$?
  assert_exit_code "RS51: denied lifecycle containment still blocks maintain" "$ec" 4
  assert_output_contains "RS51a: lifecycle containment failure is actionable" "$out" \
    "Linux ptrace support is required"
  assert_file_not_exists "RS51b: failed containment stops before Codex auth" "$codex_calls"
  ec=0; out=$(cd "$workdir" && FAKE_CODEX_CALLS="$codex_calls" GH_ISSUES_JSON="$probe_issues" PATH="$workdir/bin:$PATH" bash "$script" maintain --dry-run 2>&1) || ec=$?
  assert_exit_code "RS51e: read-only dry-run planning pass is not blocked" "$ec" 0
  rm -f "$workdir/bin/python3"
  ec=0; out=$(cd "$workdir" && FAKE_CODEX_CALLS="$codex_calls" SAAS_PREFLIGHT_MISSING=codex GH_ISSUES_JSON="$probe_issues" PATH="$workdir/bin:$PATH" bash "$script" maintain 2>&1) || ec=$?
  assert_exit_code "RS51h: runnable queue without Codex fails before dispatch" "$ec" 4
  assert_output_contains "RS51h1: missing Codex diagnostic is actionable" "$out" \
    'Codex CLI not found'
  assert_file_not_exists "RS51h2: forced-missing Codex runs no auth command" "$codex_calls"
  ec=0; out=$(cd "$workdir" && FAKE_CODEX_CALLS="$codex_calls" FAKE_CODEX_AUTH_OK=0 \
    GH_ISSUES_JSON="$probe_issues" PATH="$workdir/bin:$PATH" \
    bash "$script" maintain 2>&1) || ec=$?
  assert_exit_code "RS51i: unauthenticated Codex blocks a runnable queue" "$ec" 4
  assert_output_contains "RS51i1: unavailable auth diagnostic is actionable" "$out" \
    'Codex authentication is unavailable'
  assert_file_contains "RS51i2: probe checks Codex login status" "$codex_calls" \
    '^login status$'
  : > "$codex_calls"
  ec=0; out=$(cd "$workdir" && FAKE_CODEX_CALLS="$codex_calls" FAKE_CODEX_AUTH_OK=1 \
    GH_ISSUES_JSON="$probe_issues" PATH="$workdir/bin:$PATH" \
    bash "$script" maintain 2>&1) || ec=$?
  assert_exit_code "RS51j: authenticated Codex makes the runnable queue ready" "$ec" 0
  assert_equals "RS51j1: readiness performs only the bounded auth check" \
    "$(cat "$codex_calls")" 'login status'
  rm -rf "$workdir"

  # Artifact hooks reject traversal and isolate the commit from hook-added paths.
  script="$PLUGIN_ROOT/scripts/auto-commit.sh"; workdir=$(make_workdir)
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/docs/research" "$workdir/docs/growth"
  printf 'old\n' > "$workdir/docs/research/a.md"; printf 'safe\n' > "$workdir/secret.md"
  (cd "$workdir" && git add . && git commit -qm init)
  printf 'new\n' > "$workdir/docs/research/a.md"; printf 'changed\n' > "$workdir/secret.md"
  remote=$(mktemp); rm -f "$remote"
  printf '#!/usr/bin/env bash\ntouch %q\ngit add secret.md\n' "$remote" > "$workdir/.git/hooks/pre-commit"
  chmod +x "$workdir/.git/hooks/pre-commit"
  ec=0; out=$(cd "$workdir" && printf '%s\n' '{"tool_input":{"file_path":"docs/research/a.md"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "RS48: artifact helper commits exact file" "$ec" 2
  out="$(git -C "$workdir" show --name-only --format= HEAD)"
  assert_output_contains "RS48a: intended artifact committed" "$out" 'docs/research/a.md'
  assert_output_not_contains "RS48b: hook-added product path excluded" "$out" 'secret.md'
  assert_file_not_exists "RS48b1: artifact commit never executes worker-mutable hooks" "$remote"
  base=$(git -C "$workdir" rev-parse HEAD); printf 'again\n' > "$workdir/secret.md"
  ec=0; out=$(cd "$workdir" && printf '{"tool_input":{"file_path":"%s/docs/research/../../secret.md"}}\n' "$workdir" | bash "$script" 2>&1) || ec=$?
  assert_exit_code "RS48c: generic artifact traversal is ignored" "$ec" 0
  assert_equals "RS48d: traversal creates no commit" "$(git -C "$workdir" rev-parse HEAD)" "$base"
  script="$PLUGIN_ROOT/scripts/auto-commit-growth.sh"
  ec=0; out=$(cd "$workdir" && printf '{"tool_input":{"file_path":"%s/docs/growth/../../secret.md"}}\n' "$workdir" | bash "$script" 2>&1) || ec=$?
  assert_exit_code "RS48e: growth artifact traversal is ignored" "$ec" 0
  assert_equals "RS48f: growth traversal creates no commit" "$(git -C "$workdir" rev-parse HEAD)" "$base"
  rm -rf "$workdir" "$remote"

  # Artifact commits override executable local Git config and every repository hook.
  script="$PLUGIN_ROOT/scripts/commit-artifact.sh"; workdir=$(make_workdir)
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/docs/research"
  printf 'old\n' > "$workdir/docs/research/a.md"
  (cd "$workdir" && git add . && git commit -qm init)
  remote=$(mktemp); patch_file=$(mktemp); rm -f "$remote" "$patch_file"
  cat > "$workdir/fsmonitor" <<SH
#!/usr/bin/env bash
touch $(printf '%q' "$remote")
exit 1
SH
  mkdir -p "$workdir/custom-hooks"
  cat > "$workdir/custom-hooks/reference-transaction" <<SH
#!/usr/bin/env bash
touch $(printf '%q' "$patch_file")
cat >/dev/null
SH
  chmod +x "$workdir/fsmonitor" "$workdir/custom-hooks/reference-transaction"
  git -C "$workdir" config core.fsmonitor "$workdir/fsmonitor"
  git -C "$workdir" config core.hooksPath "$workdir/custom-hooks"
  printf 'new\n' > "$workdir/docs/research/a.md"
  ec=0; out=$(cd "$workdir" && bash "$script" \
    --path docs/research/a.md --message test 2>&1) || ec=$?
  assert_exit_code "RS48g: executable local Git config cannot block artifact commit" "$ec" 0
  assert_file_not_exists "RS48h: configured fsmonitor never executes" "$remote"
  assert_file_not_exists "RS48i: reference-transaction hook never executes" "$patch_file"
  assert_equals "RS48j: hardened artifact path creates one commit" \
    "$(git -C "$workdir" -c core.fsmonitor=false -c core.hooksPath=/dev/null rev-list --count HEAD)" 2
  rm -rf "$workdir" "$remote" "$patch_file"

  # An attributed clean/process filter fails closed before Git can dispatch it.
  workdir=$(make_workdir)
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/docs/research"
  printf 'docs/research/*.md filter=worker\n' > "$workdir/.gitattributes"
  printf 'old\n' > "$workdir/docs/research/a.md"
  (cd "$workdir" && git add . && git commit -qm init)
  remote=$(mktemp); rm -f "$remote"
  cat > "$workdir/clean-filter" <<SH
#!/usr/bin/env bash
touch $(printf '%q' "$remote")
cat
SH
  chmod +x "$workdir/clean-filter"
  git -C "$workdir" config filter.worker.clean "$workdir/clean-filter"
  printf 'new\n' > "$workdir/docs/research/a.md"
  base=$(git -C "$workdir" rev-parse HEAD)
  ec=0; out=$(cd "$workdir" && bash "$script" \
    --path docs/research/a.md --message test 2>&1) || ec=$?
  assert_exit_code "RS48k: filtered artifact path fails closed" "$ec" 1
  assert_output_contains "RS48l: filtered artifact failure is explicit" "$out" 'filtered path'
  assert_file_not_exists "RS48m: configured clean filter never executes" "$remote"
  assert_equals "RS48n: filtered artifact creates no commit" "$(git -C "$workdir" rev-parse HEAD)" "$base"
  rm -rf "$workdir" "$remote"

  assert_file_contains "RS49: growth init lease is released" "$PLUGIN_ROOT/commands/growth.md" '--release "growth:init:${PWD}"'
  assert_file_contains "RS49a: growth work owner is objective-scoped" "$PLUGIN_ROOT/commands/growth.md" 'growth-${channel_slug}.owner'

  # Entrypoints are measured after thinning; ceilings are 120% of landed byte size.
  check_ceiling() {
    local name="$1" ceiling="$2" bytes
    bytes=$(wc -c < "$PLUGIN_ROOT/commands/$name.md" | tr -d ' ')
    [ "$bytes" -le "$ceiling" ] && out=yes || out=no
    assert_equals "RS prompt ceiling:$name ($bytes <= $ceiling)" "$out" yes
  }
  check_ceiling maintain 918
  check_ceiling maintain-loop 2370
  check_ceiling goal-deliver 539
  check_ceiling improve 494
  check_ceiling tweak 453
  rm -rf "$supervisor_bwrap_dir"
}

test_runtime_safety
