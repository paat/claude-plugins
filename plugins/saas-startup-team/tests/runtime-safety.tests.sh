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
  assert_file_contains "RS14a: shared executable mutation contract" \
    "$PLUGIN_ROOT/references/workflows/mutation-ownership.md" 'delivery-mutation-guard.sh'
  assert_file_contains "RS14b: startup uses mutation ownership gates" \
    "$PLUGIN_ROOT/commands/startup.md" 'references/workflows/mutation-ownership.md'
  assert_file_contains "RS14c: improve uses trusted commit receipt" \
    "$PLUGIN_ROOT/references/workflows/improve.md" '--trust-receipt "$COMMIT_TRUST"'
  assert_file_contains "RS14d: lessons uses trusted commit receipt" \
    "$PLUGIN_ROOT/commands/lessons-deliver.md" '--trust-receipt "$COMMIT_TRUST"'
  assert_file_contains "RS14e: maintain transaction snapshots trusted hooks" \
    "$PLUGIN_ROOT/scripts/maintain-attempt.sh" '--snapshot-trust "$commit_trust"'
  assert_file_contains "RS14f: mutation receipts require supervisor authentication" \
    "$PLUGIN_ROOT/references/workflows/mutation-ownership.md" '--auth-stdin'
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
  assert_file_not_contains "RS14g: lessons never stages the primary checkout" \
    "$PLUGIN_ROOT/commands/lessons-deliver.md" 'git add -A'
  assert_file_contains "RS14h: lessons freezes its isolated firewall" \
    "$PLUGIN_ROOT/commands/lessons-deliver.md" '--firewall-script'
  for guarded_hook in auto-commit.sh auto-commit-growth.sh auto-learn.sh compact-state.sh index-handoff.sh; do
    assert_file_contains "RS14 hook defers:$guarded_hook" \
      "$PLUGIN_ROOT/scripts/$guarded_hook" 'guard-active.sh'
  done

  make_supervisor_sandbox() {
    local root="$1"
    mkdir -p "$root/bin" "$supervisor_bwrap_dir"
    cat > "$root/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = sandbox ] || exit 2
shift
if [ "${1:-}" = --help ]; then
  printf '%s\n' '--permission-profile --enable'
  exit 0
fi
sandbox_cwd=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --permission-profile) shift 2 ;;
    --enable) [ "${2:-}" = network_proxy ] || exit 2; shift 2 ;;
    -c) shift 2 ;;
    -C) sandbox_cwd=$2; shift 2 ;;
    *) break ;;
  esac
done
[ "$#" -gt 0 ]
[ -z "$sandbox_cwd" ] || cd "$sandbox_cwd"
# Codex's :workspace profile denies writes to the workspace .git (issues
# #260/#261); emulate that so in-sandbox Git metadata writes fail here too.
if [ -d .git ] && [ ! -L .git ]; then
  chmod -R a-w .git
  rc=0; "$@" || rc=$?
  chmod -R u+w .git
  exit "$rc"
fi
"$@"
SH
    cat > "$supervisor_bwrap_dir/check-driver" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
image_id=${SAAS_FAKE_CHECK_IMAGE_ID:-sha256:1111111111111111111111111111111111111111111111111111111111111111}
if [ "${1:-}" = --metadata ]; then
  printf '%s\n' "{\"docker\":{\"path\":\"/usr/bin/false\",\"identity\":\"1:1\",\"mode\":\"755\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"},\"daemon_id\":\"test-daemon\",\"image_id\":\"$image_id\",\"container_id\":\"test-container\"}"
  exit 0
fi
if [ "${1:-}" = --probe-tools ]; then
  tools=${2:-}
  missing=${SAAS_FAKE_CHECK_MISSING_TOOLS:-}
  if [ -n "$missing" ]; then
    IFS=',' read -r -a miss_list <<<"$missing"
    for m in "${miss_list[@]}"; do
      m=${m//[[:space:]]/}
      case ",$tools," in *",$m,"*|*" $m,"*|*",$m "*|*" $m "*) 
        echo "supervisor-check-container: sealed image missing required tools: $m" >&2
        exit 1
        ;;
      esac
      # also match when tools list uses commas without spaces
      case "$tools" in *"$m"*) 
        echo "supervisor-check-container: sealed image missing required tools: $m" >&2
        exit 1
        ;;
      esac
    done
  fi
  echo ok
  exit 0
fi
root=
runtime_sources=(); runtime_targets=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C) root=$2; shift 2 ;;
    --docker-bin|--image-id|--daemon-id|--checkout-alias) shift 2 ;;
    --runtime)
      runtime_sources+=("$2"); runtime_targets+=("$3")
      shift 4 ;;
    --) shift; break ;;
    *) echo "fake check driver: unexpected argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$root" ] && [ "$#" -gt 0 ]
mounted=()
command_pid=
cleanup() {
  local target
  if [ -n "$command_pid" ]; then
    kill -KILL "$command_pid" 2>/dev/null || true
    wait "$command_pid" 2>/dev/null || true
  fi
  chmod -R u+w "$root/.git" 2>/dev/null || true
  for ((j=0; j<${#mounted[@]}; j++)); do
    target=${mounted[$j]}
    chmod -R u+w "$target" 2>/dev/null || true
    rm -rf -- "$target"
    mkdir -p "$target"
  done
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
for ((i=0; i<${#runtime_sources[@]}; i++)); do
  target="$root/${runtime_targets[$i]}"
  # Private copy only — never symlink/chmod the primary dependency runtime
  # (writable links let verification mutate sealed primary digests).
  rmdir "$target"
  cp -a -- "${runtime_sources[$i]}" "$target"
  chmod -R a-w "$target"
  mounted+=("$target")
done
translate() {
  case "$1" in
    /dev/shm/saas-check) printf '%s\n' "$root" ;;
    /dev/shm/saas-check/*) printf '%s/%s\n' "$root" "${1#/dev/shm/saas-check/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
command=()
for arg in "$@"; do command+=("$(translate "$arg")"); done
chmod -R a-w "$root/.git"
cd "$root"
set +e
"${command[@]}" &
command_pid=$!
wait "$command_pid"
rc=$?
command_pid=
set -e
exit "$rc"
SH
    chmod +x "$root/bin/codex" "$supervisor_bwrap_dir/check-driver"
    SAAS_SUPERVISOR_CHECK_DRIVER="$supervisor_bwrap_dir/check-driver"
    export SAAS_SUPERVISOR_CHECK_DRIVER
    PATH="$supervisor_bwrap_dir:$root/bin:$PATH"
    export PATH
  }

  supervisor_snapshot() {
    auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
    (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
      --auth-stdin \
      --allow app.txt --allow check.sh --allow test.sh --allow extra.txt \
      --allow fail-check --allow trigger-hook --allow .githooks --allow .gitignore \
      <<<"$auth_token" >/dev/null)
  }

  # A clean base can run the authenticated canonical check without manufacturing
  # a candidate commit, while noisy output stays in a retained local artifact.
  script="$PLUGIN_ROOT/scripts/supervisor-commit.sh"
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"
  git -C "$workdir" config user.email t@t.t; git -C "$workdir" config user.name t
  printf 'base\n' > "$workdir/app.txt"
  cat > "$workdir/check.sh" <<'SH'
#!/usr/bin/env bash
set -e
i=0
while [ "$i" -lt 4000 ]; do
  printf 'noisy-base-check-%04d-abcdefghijklmnopqrstuvwxyz0123456789\n' "$i"
  i=$((i + 1))
done
if [ -n "${SUPERVISOR_TEST_SIGNAL:-}" ]; then
  : > "$SUPERVISOR_TEST_SIGNAL"
  while [ ! -e "$SUPERVISOR_TEST_RELEASE" ]; do sleep 0.01; done
fi
SH
  chmod +x "$workdir/check.sh"
  git -C "$workdir" add .; git -C "$workdir" commit -qm base
  trust_receipt="$workdir/.git/saas-startup-team/base-check.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  ec=0; out=$(cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --check-only --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i1: clean-base check trust snapshot succeeds without an allowlist" "$ec" 0
  assert_equals "RS14i2: check-only receipt is purpose-bound with an empty allowlist" \
    "$(jq -r '.schema_version == 5 and .purpose == "check-only" and (.allow|length == 0)' "$trust_receipt")" true
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --check-only \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i3: empty-diff base check succeeds" "$ec" 0
  assert_equals "RS14i4: base check creates no commit" \
    "$(git -C "$workdir" rev-list --count HEAD)" 1
  assert_file_not_exists "RS14i5: successful base check consumes its trust receipt" "$trust_receipt"
  assert_output_contains "RS14i6: terminal reports base-check success" "$out" 'base checks passed'
  assert_equals "RS14i7: noisy check terminal output stays bounded" \
    "$(awk 'END { print (NR <= 90 && bytes <= 9000) ? "true" : "false" } { bytes += length($0) + 1 }' <<<"$out")" true
  assert_output_not_contains "RS14i8: early raw check output is absent from the terminal" \
    "$out" 'noisy-base-check-0000'
  assert_output_not_contains "RS14i9: successful checks keep final raw output out of the terminal" \
    "$out" 'noisy-base-check-3999'
  assert_equals "RS14i9a: successful checks print one concise status line" \
    "$(awk 'END { print NR }' <<<"$out")" 1
  check_log=$(find "$workdir/.git/saas-startup-team/check-logs" -maxdepth 1 -name '*.log' -print -quit)
  assert_output_contains "RS14i9b: success status names the retained full log" "$out" "$check_log"
  assert_file_contains "RS14i10: full local check log retains early output" \
    "$check_log" 'noisy-base-check-0000'
  assert_file_contains "RS14i11: full local check log retains final output" \
    "$check_log" 'noisy-base-check-3999'
  assert_equals "RS14i12: retained check log is private" "$(stat -c %a "$check_log")" 600
  check_log_dir="$workdir/.git/saas-startup-team/check-logs"
  for ((i=0; i<50; i++)); do
    printf 'old\n' > "$check_log_dir/old-$i.check.fixture.log"
  done
  weird_check_log="$check_log_dir/old-"$'\n'"name.check.fixture.log"
  printf 'weird\n' > "$weird_check_log"

  remote=$(mktemp -d); rm -rf "$remote"; git init -q --bare "$remote"
  branch=$(git -C "$workdir" symbolic-ref --short HEAD)
  git -C "$workdir" remote add origin "$remote"
  git -C "$workdir" push -qu origin "$branch"
  trust_receipt="$workdir/.git/saas-startup-team/origin-base-check.json"
  (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --check-only --auth-stdin <<<"$auth_token" >/dev/null)
  remote_clone=$(mktemp -d); rm -rf "$remote_clone"
  git clone -q -b "$branch" "$remote" "$remote_clone"
  git -C "$remote_clone" config user.email t@t.t; git -C "$remote_clone" config user.name t
  printf 'origin progress\n' > "$remote_clone/app.txt"
  git -C "$remote_clone" add app.txt; git -C "$remote_clone" commit -qm origin-progress
  git -C "$remote_clone" push -q origin "$branch"
  git -C "$workdir" fetch -q origin "$branch"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --check-only \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i12aa: a non-active remote ref does not invalidate check-only" "$ec" 0
  assert_equals "RS14i12aaa: canonical check-log retention stays bounded" \
    "$(find -P "$check_log_dir" -maxdepth 1 -type f -name '*.check.*.log' -printf . \
      | wc -c | tr -d ' ')" 50
  assert_output_contains "RS14i12aab: NUL-safe retention preserves a successful check" \
    "$out" 'base checks passed'
  assert_equals "RS14i12ab: check-only leaves the externally updated tracking ref intact" \
    "$(git -C "$workdir" rev-parse "refs/remotes/origin/$branch")" \
    "$(git --git-dir="$remote" rev-parse "refs/heads/$branch")"
  git -C "$workdir" remote remove origin
  rm -rf "$remote_clone" "$remote"

  # RS14i12 sibling-linked-worktree concurrency suite deleted (primary-only contract).

  trust_receipt="$workdir/.git/saas-startup-team/concurrent-new-ref-check.json"
  (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --check-only --auth-stdin <<<"$auth_token" >/dev/null)
  check_signal=$(mktemp); check_release=$(mktemp); check_output=$(mktemp); check_status=$(mktemp)
  rm -f "$check_signal" "$check_release"
  (
    ec=0
    cd "$workdir"
    SUPERVISOR_TEST_SIGNAL="$check_signal" SUPERVISOR_TEST_RELEASE="$check_release" \
      PATH="$workdir/bin:$PATH" bash "$script" --check-only \
      --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" >"$check_output" 2>&1 || ec=$?
    printf '%s\n' "$ec" > "$check_status"
  ) &
  check_pid=$!
  for ((i=0; i<500; i++)); do
    [ ! -e "$check_signal" ] || break
    sleep 0.01
  done
  assert_file_exists "RS14i12f: new-ref fixture reaches the sealed check" "$check_signal"
  guard_head=$(git -C "$workdir" rev-parse HEAD)
  git -C "$workdir" update-ref refs/heads/worker-created "$guard_head"
  : > "$check_release"
  wait "$check_pid"
  assert_exit_code "RS14i12g: a new external ref does not invalidate check-only" \
    "$(cat "$check_status")" 0
  assert_file_contains "RS14i12h: check-only with an external ref still completes" \
    "$check_output" 'base checks passed'
  git -C "$workdir" update-ref -d refs/heads/worker-created
  rm -f "$check_signal" "$check_release" "$check_output" "$check_status"
  printf 'dirty\n' > "$workdir/app.txt"
  trust_receipt="$workdir/.git/saas-startup-team/dirty-base-check.json"
  ec=0; out=$(cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --check-only --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i13: check-only snapshot rejects a dirty base" "$ec" 1
  assert_output_contains "RS14i14: dirty-base rejection is explicit" "$out" 'requires a clean base worktree'
  assert_file_not_exists "RS14i15: dirty-base rejection creates no receipt" "$trust_receipt"
  rm -rf "$workdir"

  # An outer /proc mount exposes host PIDs, so the check log must be addressed
  # through the inherited descriptor rather than the namespace-local shell PID.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"
  git -C "$workdir" config user.email t@t.t; git -C "$workdir" config user.name t
  printf 'base\n' > "$workdir/app.txt"
  cat > "$workdir/check.sh" <<'SH'
#!/usr/bin/env bash
ulimit -f unlimited
i=0
while [ "$i" -lt 100000 ]; do
  printf 'pid-namespace-check-output-%06d-abcdefghijklmnopqrstuvwxyz0123456789\n' "$i"
  i=$((i + 1))
done
SH
  chmod +x "$workdir/check.sh"
  git -C "$workdir" add .; git -C "$workdir" commit -qm base
  trust_receipt="$workdir/.git/saas-startup-team/pid-namespace-check.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --check-only --auth-stdin <<<"$auth_token" >/dev/null)
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" \
    SAAS_SUPERVISOR_CHECK_LOG_MAX_BYTES=4096 \
    SAAS_SUPERVISOR_CHECK_LOG_RETENTION_BYTES=8192 \
    unshare --user --map-current-user --pid --fork --kill-child=KILL -- \
      bash "$script" --check-only --trust-receipt "$trust_receipt" \
      --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15ns1: bounded check runs inside a PID namespace with the outer procfs" "$ec" 1
  assert_output_contains "RS14i15ns2: namespace check reaches the output-size gate" \
    "$out" 'check output exceeded the 4096-byte budget'
  limit_log=$(find "$workdir/.git/saas-startup-team/check-logs" \
    -maxdepth 1 -type f -name '*.check.*.log' -print -quit)
  assert_equals "RS14i15ns3: namespace check truncates through its inherited descriptor" \
    "$(stat -c %s "$limit_log")" 4096
  rm -rf "$workdir"

  # Check evidence paths and resources fail closed before they can forge success.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"
  git -C "$workdir" config user.email t@t.t; git -C "$workdir" config user.name t
  marker=$(mktemp); rm -f "$marker"
  printf 'base\n' > "$workdir/app.txt"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$marker" > "$workdir/check.sh"
  chmod +x "$workdir/check.sh"
  git -C "$workdir" add .; git -C "$workdir" commit -qm base
  trust_receipt="$workdir/.git/saas-startup-team/unsafe-check-log.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --check-only --auth-stdin <<<"$auth_token" >/dev/null)
  victim_dir=$(mktemp -d)
  ln -s "$victim_dir" "$workdir/.git/saas-startup-team/check-logs"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" --check-only \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15a: symlinked check-log parent is rejected" "$ec" 1
  assert_file_not_exists "RS14i15b: rejected check-log parent never runs checks" "$marker"
  assert_equals "RS14i15c: symlinked check-log target receives no evidence" \
    "$(find "$victim_dir" -mindepth 1 -print -quit)" ""
  rm -f "$workdir/.git/saas-startup-team/check-logs"
  mkdir "$workdir/.git/saas-startup-team/check-logs"
  mkfifo "$workdir/.git/saas-startup-team/check-logs/hostile.check.fixture.log"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" timeout 3s bash "$script" --check-only \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15d: special check-log entry fails without blocking" "$ec" 1
  assert_file_not_exists "RS14i15e: special check-log entry never runs checks" "$marker"
  rm -rf "$workdir" "$victim_dir" "$marker"

  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"
  git -C "$workdir" config user.email t@t.t; git -C "$workdir" config user.name t
  printf 'base\n' > "$workdir/app.txt"
  cat > "$workdir/check.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 100000 ]; do
  printf 'bounded-check-output-%06d-abcdefghijklmnopqrstuvwxyz0123456789\n' "$i"
  i=$((i + 1))
done
SH
  chmod +x "$workdir/check.sh"
  git -C "$workdir" add .; git -C "$workdir" commit -qm base
  trust_receipt="$workdir/.git/saas-startup-team/bounded-check.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --check-only --auth-stdin <<<"$auth_token" >/dev/null)
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" \
    SAAS_SUPERVISOR_CHECK_LOG_MAX_BYTES=4096 \
    SAAS_SUPERVISOR_CHECK_LOG_RETENTION_BYTES=8192 \
    bash "$script" --check-only --trust-receipt "$trust_receipt" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15f: oversized check output cannot produce success" "$ec" 1
  assert_output_contains "RS14i15g: oversized check failure names the byte budget" \
    "$out" 'check output exceeded the 4096-byte budget'
  assert_output_not_contains "RS14i15h: oversized check never reports base-check success" \
    "$out" 'base checks passed'
  limit_log=$(find "$workdir/.git/saas-startup-team/check-logs" \
    -maxdepth 1 -type f -name '*.check.*.log' -print -quit)
  assert_equals "RS14i15i: oversized raw check evidence is truncated to its budget" \
    "$(stat -c %s "$limit_log")" 4096

  rm -rf -- "$trust_receipt" "${trust_receipt}.hooks" "${trust_receipt}.firewall"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  git -C "$workdir" add check.sh; git -C "$workdir" commit -qm quiet-check
  limit_log_dir="$workdir/.git/saas-startup-team/check-logs"
  dd if=/dev/zero of="$limit_log_dir/old-a.check.fixture.log" bs=4096 count=1 status=none
  dd if=/dev/zero of="$limit_log_dir/old-b.check.fixture.log" bs=4096 count=1 status=none
  touch -d @1 "$limit_log_dir/old-a.check.fixture.log"
  touch -d @2 "$limit_log_dir/old-b.check.fixture.log"
  trust_receipt="$workdir/.git/saas-startup-team/bounded-retention.json"
  (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --check-only --auth-stdin <<<"$auth_token" >/dev/null)
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" \
    SAAS_SUPERVISOR_CHECK_LOG_MAX_BYTES=4096 \
    SAAS_SUPERVISOR_CHECK_LOG_RETENTION_BYTES=8192 \
    bash "$script" --check-only --trust-receipt "$trust_receipt" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15j: byte-bounded check retention preserves current success" "$ec" 0
  limit_bytes=$(find -P "$limit_log_dir" -maxdepth 1 -type f -name '*.check.*.log' \
    -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')
  assert_equals "RS14i15k: retained check evidence has a total byte budget" \
    "$([ "$limit_bytes" -le 8192 ] && echo yes || echo no)" yes

  hanging_pid_file=$(mktemp); rm -f "$hanging_pid_file"
  cat > "$workdir/check.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$hanging_pid_file"
trap '' TERM
while :; do sleep 1; done
SH
  chmod +x "$workdir/check.sh"
  git -C "$workdir" add check.sh; git -C "$workdir" commit -qm hanging-check
  trust_receipt="$workdir/.git/saas-startup-team/hanging-check.json"
  (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --check-only --auth-stdin <<<"$auth_token" >/dev/null)
  started=$(date +%s); ec=0
  out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" \
    SAAS_SUPERVISOR_CHECK_TIMEOUT_SECONDS=1 \
    bash "$script" --check-only --trust-receipt "$trust_receipt" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  elapsed=$(($(date +%s) - started))
  assert_exit_code "RS14i15l: hanging checks fail closed" "$ec" 1
  assert_output_contains "RS14i15m: hanging check failure names the deadline" \
    "$out" 'checks exceeded the 1-second deadline'
  assert_equals "RS14i15n: hanging check is killed within a fixed grace period" \
    "$([ "$elapsed" -le 5 ] && echo yes || echo no)" yes
  leaked_check=missing
  if [ -s "$hanging_pid_file" ]; then
    hanging_pid=$(cat "$hanging_pid_file")
    leaked_check=invalid
    if [[ "$hanging_pid" =~ ^[1-9][0-9]*$ ]]; then
      leaked_check=no
      if kill -0 "$hanging_pid" 2>/dev/null; then
        leaked_check=yes
        kill -KILL "$hanging_pid" 2>/dev/null || true
      fi
    fi
  fi
  assert_equals "RS14i15n1: fake driver reaps the timed-out check process" "$leaked_check" no
  rm -f "$hanging_pid_file"
  rm -rf "$workdir"

  # A failed Git inventory is never interpreted as an empty trusted workspace.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"
  git -C "$workdir" config user.email t@t.t; git -C "$workdir" config user.name t
  marker=$(mktemp); rm -f "$marker"
  printf 'base\n' > "$workdir/app.txt"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$marker" > "$workdir/check.sh"
  chmod +x "$workdir/check.sh"
  git -C "$workdir" add .; git -C "$workdir" commit -qm base
  system_git=$(command -v git)
  cat > "$workdir/bin/git" <<'SH'
#!/usr/bin/env bash
is_ls_files=0; is_ls_tree=0; is_check_attr=0; has_others=0; has_unmerged=0; has_recursive=0; has_z=0; has_head=0
last= args=" $* "
for arg in "$@"; do
  last=$arg
  [ "$arg" != ls-files ] || is_ls_files=1
  [ "$arg" != ls-tree ] || is_ls_tree=1
  [ "$arg" != check-attr ] || is_check_attr=1
  [ "$arg" != --others ] || has_others=1
  [ "$arg" != --unmerged ] || has_unmerged=1
  [ "$arg" != -r ] || has_recursive=1
  [ "$arg" != -z ] || has_z=1
  [ "$arg" != HEAD ] || has_head=1
done
case "${FAIL_SUPERVISOR_INVENTORY:-}" in
  snapshot) [ "$is_ls_files" -eq 0 ] || [ "$has_others" -eq 0 ] || exit 73 ;;
  check) [ "$is_ls_files" -eq 0 ] || [ "$has_unmerged" -eq 0 ] || exit 73 ;;
  commit)
    [ "$is_ls_tree" -eq 0 ] || [ "$has_recursive" -eq 0 ] \
      || [ "$has_z" -eq 0 ] || [ "$has_head" -eq 0 ] || exit 73
    ;;
  attributes) [ "$is_check_attr" -eq 0 ] || exit 73 ;;
esac
case "${FAIL_SUPERVISOR_CONFIG:-}" in
  hooks)
    [[ "$args" != *" config --path core.hooksPath "* ]] \
      || { "$SYSTEM_GIT" "$@" || true; exit 73; }
    ;;
  sparse)
    [[ "$args" != *" config --bool core.sparseCheckout "* ]] \
      || { "$SYSTEM_GIT" "$@" || true; exit 73; }
    ;;
  attributes)
    [[ "$args" != *" config --path core.attributesFile "* ]] \
      || { "$SYSTEM_GIT" "$@" || true; exit 73; }
    ;;
  staging)
    [[ "$args" != *" config --get core.autocrlf "* ]] \
      || { "$SYSTEM_GIT" "$@" || true; exit 73; }
    ;;
esac
if [ "${FAIL_SUPERVISOR_FINAL_HASH:-}" = invalid ] \
  && [[ "$args" == *" hash-object --no-filters "* ]] \
  && [[ "$last" == /tmp/tmp.* ]]; then
  printf 'not-a-git-oid\n'
  exit 0
fi
exec "$SYSTEM_GIT" "$@"
SH
  chmod +x "$workdir/bin/git"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  failed_snapshot="$workdir/.git/saas-startup-team/failed-inventory-snapshot.json"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" \
    FAIL_SUPERVISOR_INVENTORY=snapshot PATH="$workdir/bin:$PATH" \
    bash "$script" --snapshot-trust "$failed_snapshot" --check-only \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15o: failed untracked inventory blocks trust snapshot" "$ec" 1
  assert_output_contains "RS14i15p: failed snapshot inventory is explicit" \
    "$out" 'could not inventory untracked base paths'
  assert_file_not_exists "RS14i15q: failed inventory creates no trust receipt" "$failed_snapshot"

  git -C "$workdir" add bin/git; git -C "$workdir" commit -qm inventory-fixture
  check_receipt="$workdir/.git/saas-startup-team/failed-inventory-check.json"
  commit_receipt="$workdir/.git/saas-startup-team/failed-inventory-commit.json"
  (cd "$workdir" && SYSTEM_GIT="$system_git" PATH="$workdir/bin:$PATH" \
    bash "$script" --snapshot-trust "$check_receipt" --check-only \
    --auth-stdin <<<"$auth_token" >/dev/null)
  (cd "$workdir" && SYSTEM_GIT="$system_git" PATH="$workdir/bin:$PATH" \
    bash "$script" --snapshot-trust "$commit_receipt" --allow app.txt \
    --auth-stdin <<<"$auth_token" >/dev/null)
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" \
    FAIL_SUPERVISOR_INVENTORY=check PATH="$workdir/bin:$PATH" \
    bash "$script" --check-only --trust-receipt "$check_receipt" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15r: failed index inventory blocks authenticated checks" "$ec" 1
  assert_output_contains "RS14i15s: failed check inventory is explicit" \
    "$out" 'could not inspect unmerged index entries'
  assert_file_not_exists "RS14i15t: inventory failure never launches the check" "$marker"

  base=$(git -C "$workdir" rev-parse HEAD)
  printf 'candidate\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" \
    FAIL_SUPERVISOR_INVENTORY=commit PATH="$workdir/bin:$PATH" \
    bash "$script" --message candidate --trust-receipt "$commit_receipt" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15u: failed base-tree inventory blocks commit" "$ec" 1
  assert_output_contains "RS14i15v: failed commit inventory is explicit" \
    "$out" 'could not inventory the base tree'
  assert_equals "RS14i15w: inventory failure creates no commit" \
    "$(git -C "$workdir" rev-parse HEAD)" "$base"
  assert_file_not_exists "RS14i15x: failed commit inventory never launches checks" "$marker"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" \
    FAIL_SUPERVISOR_INVENTORY=attributes PATH="$workdir/bin:$PATH" \
    bash "$script" --message candidate --trust-receipt "$commit_receipt" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15x1: failed attribute inspection blocks commit" "$ec" 1
  assert_output_contains "RS14i15x2: failed attribute inspection is explicit" \
    "$out" 'could not inspect attributes for path'
  assert_equals "RS14i15x3: attribute failure creates no commit" \
    "$(git -C "$workdir" rev-parse HEAD)" "$base"
  assert_file_not_exists "RS14i15x4: attribute failure never launches checks" "$marker"
  failed_snapshot="$workdir/.git/saas-startup-team/failed-hooks-config.json"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" \
    FAIL_SUPERVISOR_CONFIG=hooks PATH="$workdir/bin:$PATH" \
    bash "$script" --snapshot-trust "$failed_snapshot" --allow app.txt \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15x4a: hook-path config errors block trust snapshot" "$ec" 1
  assert_file_not_exists "RS14i15x4b: hook-path config error creates no receipt" "$failed_snapshot"
  failed_snapshot="$workdir/.git/saas-startup-team/failed-final-hash.json"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" \
    FAIL_SUPERVISOR_FINAL_HASH=invalid PATH="$workdir/bin:$PATH" \
    bash "$script" --snapshot-trust "$failed_snapshot" --allow app.txt \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15x4c: invalid aggregate hook hash blocks trust snapshot" "$ec" 1
  assert_file_not_exists "RS14i15x4d: invalid final hash creates no receipt" "$failed_snapshot"
  for config_failure in sparse attributes staging; do
    ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" \
      FAIL_SUPERVISOR_CONFIG="$config_failure" PATH="$workdir/bin:$PATH" \
      bash "$script" --message candidate --trust-receipt "$commit_receipt" \
      --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
    assert_exit_code "RS14i15x4 config error blocks commit:$config_failure" "$ec" 1
    assert_equals "RS14i15x4 config error creates no commit:$config_failure" \
      "$(git -C "$workdir" rev-parse HEAD)" "$base"
  done
  assert_file_not_exists "RS14i15x4e: config-query failures never launch checks" "$marker"
  real_jq=$(command -v jq)
  cat > "$workdir/bin/jq" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != '.allow[]' ] || exit 73
done
exec "$REAL_JQ" "$@"
SH
  chmod +x "$workdir/bin/jq"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" REAL_JQ="$real_jq" \
    PATH="$workdir/bin:$PATH" bash "$script" --message candidate \
    --trust-receipt "$commit_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS14i15x5: failed allowlist materialization blocks commit" "$ec" 1
  assert_output_contains "RS14i15x6: failed allowlist materialization is explicit" \
    "$out" 'cannot materialize authenticated allowlist'
  assert_file_exists "RS14i15x7: allowlist failure preserves the trust receipt" "$commit_receipt"
  assert_equals "RS14i15x8: allowlist failure creates no commit" \
    "$(git -C "$workdir" rev-parse HEAD)" "$base"
  assert_file_not_exists "RS14i15x9: allowlist failure never launches checks" "$marker"
  assert_file_not_contains "RS14i15y: Git inventory loops avoid unchecked process substitution" \
    "$script" 'done < <($REAL_GIT'
  assert_file_not_contains "RS14i15z: supervisor uses no Bash-4.1 dynamic descriptors" \
    "$script" 'exec {'
  rm -rf "$workdir" "$marker"

  # Supervisor commit: red checks do not commit; green checks run normal hooks.
  script="$PLUGIN_ROOT/scripts/supervisor-commit.sh"
  workdir=$(make_workdir)
  make_supervisor_sandbox "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t && git config core.hooksPath .githooks)
  printf 'base\n' > "$workdir/app.txt"
  cat > "$workdir/check.sh" <<'SH'
#!/usr/bin/env bash
[ ! -f fail-check ]
SH
  mkdir -p "$workdir/.githooks"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/.githooks/pre-commit"
  chmod +x "$workdir/check.sh" "$workdir/.githooks/pre-commit"
  (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"
  supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  printf 'fail\n' > "$workdir/fail-check"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS15: failed deterministic check blocks commit" "$ec" 1
  assert_equals "RS16: failed check leaves one commit" "$(cd "$workdir" && git rev-list --count HEAD)" "1"
  assert_equals "RS16a: failed check leaves primary index unchanged" \
    "$(git -C "$workdir" diff --cached --quiet && echo clean || echo changed)" clean
  assert_file_exists "RS16b: same-base retry retains trust receipt" "$trust_receipt"
  rm -f "$workdir/fail-check"
  printf '#!/usr/bin/env bash\ntouch worker-selected-check-ran\n' > "$workdir/check.sh"
  chmod +x "$workdir/check.sh"
  mkdir -p "$workdir/.startup/leases/x" "$workdir/.startup/runs" "$workdir/.startup/evaluation" \
    "$workdir/.startup/maintain" "$workdir/.startup/maintain-loop" \
    "$workdir/.startup/operate" "$workdir/.startup/demand"
  printf 'owner\n' > "$workdir/.startup/leases/x/owner"
  printf '{"local":true}\n' > "$workdir/.startup/runs/agent-events.jsonl"
  printf 'private\n' > "$workdir/.startup/evaluation/replay.json"
  printf 'issue facts\n' > "$workdir/.startup/maintain/digest.md"
  printf 'worker output\n' > "$workdir/.startup/maintain-loop/result.md"
  printf 'customer pii\n' > "$workdir/.startup/operate/raw.txt"
  printf 'market evidence\n' > "$workdir/.startup/demand/candidates.jsonl"
  printf 'customer finding\n' > "$workdir/.startup/monitor-state.json.probe-findings"
  mkdir -p "$workdir/.supervisor-check.stale"; printf 'stale\n' > "$workdir/.supervisor-check.stale/private.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS17: green supervisor commit succeeds" "$ec" 0
  assert_equals "RS18: supervisor commit created" "$(cd "$workdir" && git rev-list --count HEAD)" "2"
  assert_file_not_exists "RS19: successful commit consumes trust receipt" "$trust_receipt"
  assert_file_not_exists "RS19a: worker-selected check program never executes" "$workdir/worker-selected-check-ran"
  out="$(cd "$workdir" && git show --name-only --format= HEAD)"
  assert_output_not_contains "RS19b: lease state stays local without gitignore" "$out" ".startup/leases"
  assert_output_not_contains "RS19c: raw events stay local without gitignore" "$out" ".startup/runs"
  assert_output_not_contains "RS19d: evaluation data stays local without gitignore" "$out" ".startup/evaluation"
  assert_output_not_contains "RS19d1: probe findings stay local without gitignore" "$out" ".probe-findings"
  assert_output_not_contains "RS19d2: maintain state stays local without gitignore" "$out" ".startup/maintain"
  assert_output_not_contains "RS19d3: operate evidence stays local without gitignore" "$out" ".startup/operate"
  assert_output_not_contains "RS19d4: demand evidence stays local without gitignore" "$out" ".startup/demand"
  assert_output_not_contains "RS19d5: stale supervisor scratch is never staged" "$out" ".supervisor-check.stale"
  assert_file_contains "RS19e: fresh repos ignore leases" "$PLUGIN_ROOT/templates/gitignore-block.txt" '.startup/leases/'
  assert_file_contains "RS19e1: monitor probe findings stay local" "$PLUGIN_ROOT/templates/gitignore-block.txt" '\.startup/\*\.probe-findings'
  assert_file_contains "RS19e2: maintain artifacts stay local" "$PLUGIN_ROOT/templates/gitignore-block.txt" '.startup/maintain/'
  assert_file_contains "RS19e3: operate evidence stays local" "$PLUGIN_ROOT/templates/gitignore-block.txt" '.startup/operate/'
  rm -rf "$workdir"

  # A failing trusted hook proves hooks execute inside the isolated commit path.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t && git config core.hooksPath .githooks)
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"
  mkdir -p "$workdir/.githooks"; printf '#!/usr/bin/env bash\nexit 41\n' > "$workdir/.githooks/pre-commit"
  chmod +x "$workdir/check.sh" "$workdir/.githooks/pre-commit"
  (cd "$workdir" && git add . && git -c core.hooksPath=/dev/null commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"
  supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19e4: failing trusted product hook blocks commit" "$ec" 1
  assert_equals "RS19e5: failing trusted hook leaves base commit" "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -rf "$workdir"

  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t && git config core.hooksPath .githooks)
  printf 'base\n' > "$workdir/app.txt"; printf 'safe\n' > "$workdir/extra.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  mkdir -p "$workdir/.githooks"
  cat > "$workdir/.githooks/pre-commit" <<'SH'
#!/usr/bin/env bash
if [ -f trigger-hook ]; then printf 'hooked\n' > extra.txt; git add extra.txt; fi
SH
  chmod +x "$workdir/.githooks/pre-commit"
  (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"
  supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  : > "$workdir/trigger-hook"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19f: hook-expanded supervisor tree fails" "$ec" 1
  assert_equals "RS19g: contaminated supervisor commit is rolled back" "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -rf "$workdir"

  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/.githooks"
  git -C "$workdir" config core.hooksPath .githooks
  printf 'base\n' > "$workdir/app.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/.githooks/pre-commit"
  chmod +x "$workdir/check.sh" "$workdir/.githooks/pre-commit"
  (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"
  supervisor_snapshot
  remote=$(mktemp); rm -f "$remote"
  printf 'changed\n' > "$workdir/app.txt"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$remote" > "$workdir/.githooks/pre-commit"
  chmod +x "$workdir/.githooks/pre-commit"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19h: candidate change to active hook is rejected" "$ec" 1
  assert_file_not_exists "RS19i: candidate hook causes no external side effect" "$remote"
  assert_equals "RS19j: rejected hook change creates no commit" "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -rf "$workdir" "$remote"

  # The nested Codex sandbox keeps the candidate clone's .git read-only, so no
  # Git metadata write may run inside sandbox_exec (issues #260/#261).
  assert_file_not_contains "RS19s1: no in-sandbox git invocation remains" "$script" 'sandbox_exec "$SHADOW" "$REAL_GIT"'
  assert_file_contains "RS19s2: staging uses scrubbed trusted git outside the sandbox" "$script" 'trusted_shadow_git add -A'
  assert_file_contains "RS19s3: commit is created by scrubbed trusted git outside the sandbox" "$script" 'trusted_shadow_git commit -q -F "$MSG_FILE"'
  assert_file_contains "RS19s4: frozen hooks still run inside the sandbox" "$script" 'sandbox_exec "$SHADOW" /usr/bin/env GIT_DIR=.git GIT_EDITOR=: "$FROZEN_HOOKS/$hook"'
  assert_file_contains "RS19s5: scrubbed trusted git helper is defined" "$script" 'trusted_shadow_git() {'

  # A base-committed symlink at the reserved commit-message slot must not
  # redirect the supervisor's message write outside the shadow clone.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  remote=$(mktemp); printf 'untouched\n' > "$remote"
  printf 'base\n' > "$workdir/app.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  ln -s "$remote" "$workdir/.supervisor-check.commit-msg"
  (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19s6: planted message-slot symlink does not block delivery" "$ec" 0
  assert_equals "RS19s7: symlink target is never written through" "$(cat "$remote")" untouched
  assert_equals "RS19s8: delivery still creates the commit" "$(git -C "$workdir" rev-list --count HEAD)" 2
  rm -rf "$workdir" "$remote"

  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/.startup"
  printf '.startup/state.json\n' > "$workdir/.gitignore"
  printf '{"active_role":"supervisor"}\n' > "$workdir/.startup/state.json"
  printf 'base\n' > "$workdir/app.txt"
  printf '#!/usr/bin/env bash\nbash test.sh\n' > "$workdir/check.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/test.sh"
  chmod +x "$workdir/check.sh" "$workdir/test.sh"
  (cd "$workdir" && git add .gitignore app.txt check.sh test.sh && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"
  supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  printf '#!/usr/bin/env bash\nrm -f .startup/state.json\nexit 0\n' > "$workdir/test.sh"
  chmod +x "$workdir/test.sh"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19k: isolated candidate helper cannot reach supervisor state" "$ec" 0
  assert_json_field "RS19l: protected supervisor state remains untouched" \
    "$workdir/.startup/state.json" '.active_role' "supervisor"
  assert_equals "RS19m: isolated candidate creates the checked commit" "$(git -C "$workdir" rev-list --count HEAD)" 2
  rm -rf "$workdir"

  # Candidate check symlinks cannot redirect trusted-check materialization.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"
  supervisor_snapshot
  remote=$(mktemp); printf 'outside\n' > "$remote"; printf 'changed\n' > "$workdir/app.txt"
  rm "$workdir/check.sh"; ln -s "$remote" "$workdir/check.sh"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19n: symlinked candidate check is rejected" "$ec" 1
  assert_equals "RS19o: symlink target remains untouched" "$(cat "$remote")" outside
  assert_equals "RS19p: symlink attack creates no commit" "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -rf "$workdir" "$remote"

  # Worker-side Git configuration changes are rejected before any configured helper runs.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"
  supervisor_snapshot
  remote=$(mktemp); rm -f "$remote"; git -C "$workdir" config core.fsmonitor "touch $remote"
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19q: post-snapshot Git config is rejected" "$ec" 1
  assert_file_not_exists "RS19r: rejected fsmonitor never executes" "$remote"
  assert_equals "RS19s: config attack creates no commit" "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -rf "$workdir" "$remote"

  # Filesystem-only receipt replacement cannot forge the supervisor-held HMAC.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  chmod u+w "$trust_receipt"
  jq '.allow=["app.txt","worker-secret.txt"]' "$trust_receipt" > "$trust_receipt.tmp"
  mv "$trust_receipt.tmp" "$trust_receipt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19t: forged trust receipt is rejected" "$ec" 1
  assert_output_contains "RS19u: receipt rejection names authentication" "$out" authentication
  assert_equals "RS19v: forged receipt creates no commit" "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -rf "$workdir"

  # A same-SHA checkout to another branch and worker-created refs invalidate trust.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  git -C "$workdir" switch -q -c worker-branch
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19w: same-SHA branch switch is rejected" "$ec" 1
  assert_equals "RS19x: branch switch creates no commit" "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -rf "$workdir"

  # Commit receipts strictly contain every ref, including sibling and remote refs.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  (cd "$workdir" && git add . && git commit -qm init && git branch -m guarded-active && git branch main)
  remote=$(mktemp -d); rm -rf "$remote"; git init -q --bare "$remote"
  git -C "$workdir" remote add origin "$remote"
  git -C "$workdir" push -qu origin guarded-active
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  assert_equals "RS19x0: commit receipt uses strict schema 4" \
    "$(jq -r '.schema_version' "$trust_receipt")" 4
  guard_head=$(git -C "$workdir" rev-parse HEAD)
  tree=$(git -C "$workdir" rev-parse 'HEAD^{tree}')
  main_next=$(printf 'worker ref rewrite\n' | git -C "$workdir" commit-tree "$tree" -p "$guard_head")
  git -C "$workdir" update-ref refs/heads/main "$main_next" "$guard_head"
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19x1: direct update-ref of a non-active main branch is rejected" "$ec" 1
  assert_output_contains "RS19x2: branch rewrite rejection names the strict ref boundary" \
    "$out" 'Git refs changed after trust snapshot'
  git -C "$workdir" update-ref refs/heads/main "$guard_head" "$main_next"
  git -C "$workdir" update-ref refs/heads/worker-created "$guard_head"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19x3: worker-created ref is rejected with the active branch intact" "$ec" 1
  git -C "$workdir" update-ref -d refs/heads/worker-created
  git -C "$workdir" update-ref refs/remotes/origin/forged "$guard_head"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19x4: a new origin-tracking ref is rejected by schema 4" "$ec" 1
  git -C "$workdir" update-ref -d refs/remotes/origin/forged
  git -C "$workdir" update-ref refs/remotes/origin/guarded-active "$main_next" "$guard_head"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19x5: an existing origin-tracking ref rewrite is rejected by schema 4" "$ec" 1
  git -C "$workdir" update-ref refs/remotes/origin/guarded-active "$guard_head" "$main_next"
  git --git-dir="$remote" update-ref refs/heads/live-new "$guard_head"
  git -C "$workdir" update-ref refs/remotes/origin/live-new "$guard_head"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19x6: a live-matching new tracking ref is still rejected by schema 4" "$ec" 1
  git -C "$workdir" update-ref -d refs/remotes/origin/live-new
  git -C "$workdir" tag worker-tag
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19x7: worker-created tag is rejected" "$ec" 1
  git -C "$workdir" tag -d worker-tag >/dev/null
  # RS19x8 sibling-linked-worktree advance deleted (primary-only contract).
  rm -rf "$workdir" "$remote"

  # Exact authenticated allowlists exclude unrelated pre-existing untracked dirt.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  (cd "$workdir" && git add . && git commit -qm init)
  mkdir -p "$workdir/.claude"; printf 'user-owned\n' > "$workdir/.claude/local.md"
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19y: allowed candidate commits with unrelated dirt present" "$ec" 0
  assert_output_not_contains "RS19z: unrelated untracked path is not committed" \
    "$(git -C "$workdir" show --name-only --format= HEAD)" .claude/local.md
  assert_file_contains "RS19za: user-owned untracked file remains" "$workdir/.claude/local.md" user-owned
  rm -rf "$workdir"

  # A check that tries to plant a hook-slot symlink hits the read-only .git
  # sandbox boundary and fails the delivery; the trusted copy is never redirected.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  remote=$(mktemp -d)
  printf 'base\n' > "$workdir/app.txt"
  printf '#!/usr/bin/env bash\nrm -rf .git/supervisor-hooks\nln -s %q .git/supervisor-hooks\n' "$remote" > "$workdir/check.sh"
  chmod +x "$workdir/check.sh"; (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zb: hook-slot tampering check fails the delivery" "$ec" 1
  assert_equals "RS19zb1: tampering check creates no commit" "$(git -C "$workdir" rev-list --count HEAD)" 1
  assert_equals "RS19zc: external hook target stays empty" "$(find "$remote" -mindepth 1 -print -quit)" ""
  rm -rf "$workdir" "$remote"

  # A gitlink may be deliberately replaced by a regular file.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  (cd "$workdir" && git add check.sh && git commit -qm init)
  sub_tree=$(git -C "$workdir" mktree </dev/null)
  sub_commit=$(printf 'submodule\n' | git -C "$workdir" commit-tree "$sub_tree")
  git -C "$workdir" update-index --add --cacheinfo "160000,$sub_commit,component"
  git -C "$workdir" commit -qm gitlink
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow component <<<"$auth_token" >/dev/null)
  git -C "$workdir" rm -q --cached component
  printf 'regular\n' > "$workdir/component"; git -C "$workdir" add component
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zd: gitlink-to-file conversion commits" "$ec" 0
  assert_equals "RS19ze: converted gitlink has regular-file mode" \
    "$(git -C "$workdir" ls-tree HEAD -- component | awk '{print $1}')" 100644
  rm -rf "$workdir"

  # Firewall workflows must approve the exact isolated diff before commit.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  (cd "$workdir" && git add . && git commit -qm init)
  patch_dir=$(mktemp -d); patch_file="$patch_dir/run.sh"
  cat > "$patch_file" <<'SH'
#!/usr/bin/env bash
[ "$1" = --firewall ] && grep -q '^+approved$' "$2" || exit 3
SH
  chmod +x "$patch_file"
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  ln -s /dev/null "$patch_dir/pii-gate.sh"
  ec=0; out=$(cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow app.txt --require-approved-diff \
    --firewall-script "$patch_file" <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zfa: unsafe firewall companion fails after claiming snapshot slots" "$ec" 1
  assert_file_not_exists "RS19zfb: failed snapshot removes its partial receipt" "$trust_receipt"
  assert_file_not_exists "RS19zfc: failed snapshot removes its partial hook copy" "${trust_receipt}.hooks"
  assert_file_not_exists "RS19zfd: failed snapshot removes its partial firewall copy" "${trust_receipt}.firewall"
  rm -f "$patch_dir/pii-gate.sh"
  ec=0; out=$(cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow app.txt --require-approved-diff \
    --firewall-script "$patch_file" <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zfe: the same snapshot path is retryable after cleanup" "$ec" 0
  printf '#!/usr/bin/env bash\nexit 0\n' > "$patch_file"
  printf 'worker-controlled\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zf: frozen firewall blocks disallowed candidate" "$ec" 3
  assert_equals "RS19zg: blocked firewall creates no commit" "$(git -C "$workdir" rev-list --count HEAD)" 1
  printf 'approved\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zh: exact candidate passes frozen firewall atomically" "$ec" 0
  rm -rf "$workdir" "$patch_dir"

  # Checks run outside the product directory, so parent dependency lookup cannot see
  # a worker-mutated ignored package store in the primary checkout.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"
  cat > "$workdir/check.sh" <<'SH'
#!/usr/bin/env bash
node -e "try { require.resolve('worker-poison'); process.exit(1) } catch (_) {}"
SH
  chmod +x "$workdir/check.sh"; (cd "$workdir" && git add . && git commit -qm init)
  mkdir -p "$workdir/node_modules/worker-poison"
  printf 'module.exports = true;\n' > "$workdir/node_modules/worker-poison/index.js"
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zk: primary ignored dependencies are outside check lookup" "$ec" 0
  rm -rf "$workdir"

  # Primary-only delivery seals its own ignored runtimes and mounts them
  # read-only into the disposable authoritative-check clone (same deps path as
  # the investor on the product primary).
  script="$PLUGIN_ROOT/scripts/supervisor-commit.sh"
  workdir=$(make_workdir); git -C "$workdir" config user.email t@t.t; git -C "$workdir" config user.name t
  mkdir -p "$workdir/frontend/packages/widget" \
    "$workdir/backend/services/api/requirements"
  printf '%s\n' 'frontend/node_modules/' 'backend/venv/' > "$workdir/.gitignore"
  printf '{"workspaces":["frontend/packages/*"]}\n' > "$workdir/package.json"
  printf 'packages:\n  - frontend/packages/*\n' > "$workdir/pnpm-workspace.yaml"
  printf 'node-linker=hoisted\n' > "$workdir/.npmrc"
  printf '[project]\nname = "workspace"\n' > "$workdir/pyproject.toml"
  printf '{}\n' > "$workdir/frontend/package.json"
  printf '{"lockfileVersion":3}\n' > "$workdir/frontend/package-lock.json"
  printf '{"name":"widget"}\n' > "$workdir/frontend/packages/widget/package.json"
  printf '{"lockfileVersion":3}\n' > "$workdir/frontend/packages/widget/package-lock.json"
  printf 'pytest==1\n' > "$workdir/backend/requirements.txt"
  printf 'httpx==1\n' > "$workdir/backend/services/api/requirements/dev.txt"
  printf 'base\n' > "$workdir/app.txt"
  cat > "$workdir/check.sh" <<'SH'
#!/usr/bin/env bash
set -e
test "$(cat frontend/node_modules/runtime.txt)" = sealed-node
test "$(cat backend/venv/runtime.txt)" = sealed-python
! touch frontend/node_modules/worker-write
! touch backend/venv/worker-write
SH
  chmod +x "$workdir/check.sh"
  git -C "$workdir" add .; git -C "$workdir" commit -qm base
  mkdir -p "$workdir/frontend/node_modules/.bin" "$workdir/backend/venv/bin"
  printf 'sealed-node\n' > "$workdir/frontend/node_modules/runtime.txt"
  printf 'sealed-python\n' > "$workdir/backend/venv/runtime.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/backend/venv/bin/python"
  chmod +x "$workdir/backend/venv/bin/python"
  make_supervisor_sandbox "$workdir"
  trust_receipt="$(git -C "$workdir" rev-parse --absolute-git-dir)/saas-startup-team/runtime-trust.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  ec=0; out=$(bash "$script" --repo-root "$workdir" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow app.txt --allow check.sh <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr1: primary runtime trust snapshot succeeds" "$ec" 0
  assert_equals "RS19zkr2: receipt seals both runtime classes" \
    "$(jq '.check_runtimes|length' "$trust_receipt")" 2
  assert_exit_code "RS19zkr2a: receipt seals nested dependency manifests" \
    "$(jq -e '
      ([.check_runtimes[].manifests[].path] | index("package.json")) != null and
      ([.check_runtimes[].manifests[].path] | index("pnpm-workspace.yaml")) != null and
      ([.check_runtimes[].manifests[].path] | index(".npmrc")) != null and
      ([.check_runtimes[].manifests[].path] | index("pyproject.toml")) != null and
      ([.check_runtimes[].manifests[].path] | index("frontend/packages/widget/package.json")) != null and
      ([.check_runtimes[].manifests[].path] | index("backend/services/api/requirements/dev.txt")) != null
    ' "$trust_receipt" >/dev/null 2>&1; echo $?)" 0
  printf 'changed\n' > "$workdir/app.txt"
  real_jq=$(command -v jq)
  cat > "$workdir/bin/jq" <<'SH'
#!/usr/bin/env bash
mode=${FAIL_RUNTIME_JQ:-}
for arg in "$@"; do
  case "$mode:$arg" in
    count:.check_runtimes\|length|items:.check_runtimes\[\]|field:'.source | select(type == "string" and length > 0)')
      "$REAL_JQ" "$@" || true
      exit 73
      ;;
    truncate:.check_runtimes\[\])
      "$REAL_JQ" "$@" | sed -n '1p'
      exit 0
      ;;
  esac
done
exec "$REAL_JQ" "$@"
SH
  chmod +x "$workdir/bin/jq"
  for jq_failure in count items field truncate; do
    ec=0; out=$(REAL_JQ="$real_jq" FAIL_RUNTIME_JQ="$jq_failure" \
      bash "$script" --repo-root "$workdir" --message runtime \
      --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
    assert_exit_code "RS19zkr2 runtime receipt jq failure blocks before checks:$jq_failure" "$ec" 1
  done
  assert_file_exists "RS19zkr2b: runtime jq failures preserve the trust receipt" "$trust_receipt"
  assert_file_not_exists "RS19zkr2c: runtime jq failures create no check evidence" \
    "$(dirname -- "$trust_receipt")/check-logs"
  assert_equals "RS19zkr2d: runtime jq failures create no commit" \
    "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -f -- "$workdir/bin/jq"
  ec=0; out=$(bash "$script" --repo-root "$workdir" --message runtime \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr3: sealed read-only runtimes satisfy the check" "$ec" 0
  assert_file_exists "RS19zkr4: primary keeps ignored node_modules for investor path" \
    "$workdir/frontend/node_modules/runtime.txt"

  trust_receipt="$(git -C "$workdir" rev-parse --absolute-git-dir)/saas-startup-team/runtime-drift.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  bash "$script" --repo-root "$workdir" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow app.txt --allow check.sh <<<"$auth_token" >/dev/null
  printf 'poisoned\n' > "$workdir/frontend/node_modules/runtime.txt"
  printf 'changed-again\n' > "$workdir/app.txt"
  ec=0; out=$(bash "$script" --repo-root "$workdir" --message drift \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr5: runtime drift after snapshot fails closed" "$ec" 1
  assert_output_contains "RS19zkr6: runtime drift is explicit" "$out" 'runtime changed'
  printf 'sealed-node\n' > "$workdir/frontend/node_modules/runtime.txt"
  git -C "$workdir" restore app.txt

  trust_receipt="$(git -C "$workdir" rev-parse --absolute-git-dir)/saas-startup-team/runtime-touch.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  bash "$script" --repo-root "$workdir" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow app.txt <<<"$auth_token" >/dev/null
  touch -m -d '2001-01-01 UTC' "$workdir/frontend/node_modules/runtime.txt"
  printf 'touch-drift\n' > "$workdir/app.txt"
  ec=0; out=$(bash "$script" --repo-root "$workdir" --message touch-drift \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr6a: runtime mtime drift after snapshot fails closed" "$ec" 1
  assert_output_contains "RS19zkr6b: runtime mtime drift is explicit" "$out" 'runtime changed'
  git -C "$workdir" restore app.txt

  trust_receipt="$(git -C "$workdir" rev-parse --absolute-git-dir)/saas-startup-team/runtime-manifest.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  bash "$script" --repo-root "$workdir" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow app.txt \
    --allow package.json --allow pnpm-workspace.yaml --allow .npmrc --allow pyproject.toml \
    --allow frontend/packages/widget/package.json \
    --allow frontend/packages/widget/package-lock.json \
    --allow backend/services/api/requirements/new.txt <<<"$auth_token" >/dev/null
  printf '{"name":"changed-widget"}\n' > "$workdir/frontend/packages/widget/package.json"
  printf 'manifest-change\n' > "$workdir/app.txt"
  ec=0; out=$(bash "$script" --repo-root "$workdir" --message manifest \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr7: nested dependency change rejects stale runtime" "$ec" 1
  assert_output_contains "RS19zkr8: nested change failure is explicit" "$out" 'dependency manifests changed'
  git -C "$workdir" restore app.txt frontend/packages/widget/package.json

  printf 'ruff==1\n' > "$workdir/backend/services/api/requirements/new.txt"
  printf 'manifest-add\n' > "$workdir/app.txt"
  ec=0; out=$(bash "$script" --repo-root "$workdir" --message manifest-add \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr8a: nested dependency addition rejects stale runtime" "$ec" 1
  assert_output_contains "RS19zkr8b: nested addition failure is explicit" "$out" 'dependency manifests changed'
  rm -f "$workdir/backend/services/api/requirements/new.txt"
  git -C "$workdir" restore app.txt

  rm "$workdir/frontend/packages/widget/package-lock.json"
  printf 'manifest-delete\n' > "$workdir/app.txt"
  ec=0; out=$(bash "$script" --repo-root "$workdir" --message manifest-delete \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr8c: nested dependency deletion rejects stale runtime" "$ec" 1
  assert_output_contains "RS19zkr8d: nested deletion failure is explicit" "$out" 'dependency manifests changed'
  git -C "$workdir" restore app.txt frontend/packages/widget/package-lock.json

  printf '{"workspaces":[]}\n' > "$workdir/package.json"
  printf 'root-node-manifest\n' > "$workdir/app.txt"
  ec=0; out=$(bash "$script" --repo-root "$workdir" --message root-node-manifest \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr8e: root Node manifest change rejects stale runtime" "$ec" 1
  assert_output_contains "RS19zkr8f: root Node manifest failure is explicit" "$out" 'dependency manifests changed'
  git -C "$workdir" restore app.txt package.json

  printf '[project]\nname = "changed-workspace"\n' > "$workdir/pyproject.toml"
  printf 'root-python-manifest\n' > "$workdir/app.txt"
  ec=0; out=$(bash "$script" --repo-root "$workdir" --message root-python-manifest \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr8g: root Python manifest change rejects stale runtime" "$ec" 1
  assert_output_contains "RS19zkr8h: root Python manifest failure is explicit" "$out" 'dependency manifests changed'
  git -C "$workdir" restore app.txt pyproject.toml

  printf 'packages: []\n' > "$workdir/pnpm-workspace.yaml"
  printf 'root-workspace-config\n' > "$workdir/app.txt"
  ec=0; out=$(bash "$script" --repo-root "$workdir" --message root-workspace-config \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr8i: root workspace config change rejects stale runtime" "$ec" 1
  assert_output_contains "RS19zkr8j: root workspace config failure is explicit" "$out" 'dependency manifests changed'
  git -C "$workdir" restore app.txt pnpm-workspace.yaml

  printf 'node-linker=isolated\n' > "$workdir/.npmrc"
  printf 'root-package-manager-config\n' > "$workdir/app.txt"
  ec=0; out=$(bash "$script" --repo-root "$workdir" --message root-package-manager-config \
    --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr8k: root package-manager config change rejects stale runtime" "$ec" 1
  assert_output_contains "RS19zkr8l: root package-manager config failure is explicit" "$out" 'dependency manifests changed'
  git -C "$workdir" restore app.txt .npmrc

  ln -s /workspace/secret "$workdir/frontend/node_modules/escape"
  trust_receipt="$(git -C "$workdir" rev-parse --absolute-git-dir)/saas-startup-team/runtime-escape.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  ec=0; out=$(bash "$script" --repo-root "$workdir" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow app.txt <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr9: escaping runtime symlink blocks trust snapshot" "$ec" 1
  assert_output_contains "RS19zkr10: escaping symlink failure is explicit" "$out" 'runtime link escapes'
  rm -f "$workdir/frontend/node_modules/escape"
  rm -rf "$workdir"

  # #342: private dependency view — writes cannot mutate primary runtime digest.
  script="$PLUGIN_ROOT/scripts/bind-dependency-runtime-view.sh"
  workdir=$(make_workdir)
  mkdir -p "$workdir/primary/frontend/node_modules/.bin" "$workdir/disposable"
  printf 'sealed\n' > "$workdir/primary/frontend/node_modules/runtime.txt"
  before=$(bash "$script" --primary-root "$workdir/primary" --digest frontend/node_modules)
  view=$(bash "$script" --primary-root "$workdir/primary" \
    --target-root "$workdir/disposable" --runtime frontend/node_modules)
  assert_file_exists "RS19zkr11: private runtime view materializes" "$view/runtime.txt"
  # Writable verification through the view (simulates Prisma/Jiti writes).
  printf 'mutated-by-verification\n' > "$view/cache-write.bin"
  after=$(bash "$script" --primary-root "$workdir/primary" --digest frontend/node_modules)
  assert_equals "RS19zkr12: primary dependency digest unchanged after view writes" \
    "$after" "$before"
  assert_file_not_exists "RS19zkr13: primary has no verification write-through" \
    "$workdir/primary/frontend/node_modules/cache-write.bin"
  # Writable symlink path is the forbidden anti-pattern (must not be helper output).
  [ ! -L "$view" ]
  assert_equals "RS19zkr14: view is a real directory not a symlink" "ok" "ok"
  # Nested target under primary is rejected (must not write into sealed primary).
  ec=0; out=$(bash "$script" --primary-root "$workdir/primary" \
    --target-root "$workdir/primary/nested-disposable" \
    --runtime frontend/node_modules 2>&1) || ec=$?
  assert_exit_code "RS19zkr14a: nested target under primary fails closed" "$ec" 1
  assert_output_contains "RS19zkr14b: nested target failure is explicit" "$out" 'must not nest'
  assert_file_not_exists "RS19zkr14c: nested target created no view under primary" \
    "$workdir/primary/nested-disposable/frontend/node_modules"
  rm -rf "$workdir"

  # #342: required tool parity fails before writer/commit (snapshot stage).
  script="$PLUGIN_ROOT/scripts/supervisor-commit.sh"
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"
  git -C "$workdir" config user.email t@t.t; git -C "$workdir" config user.name t
  printf 'base\n' > "$workdir/app.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$(git -C "$workdir" rev-parse --absolute-git-dir)/saas-startup-team/tool-parity.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  ec=0; out=$(SAAS_SUPERVISOR_CHECK_REQUIRED_TOOLS='pdftotext pdfinfo' \
    SAAS_FAKE_CHECK_MISSING_TOOLS='pdftotext' \
    bash "$script" --repo-root "$workdir" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow app.txt --allow check.sh <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr15: missing sealed tools block trust snapshot" "$ec" 1
  assert_output_contains "RS19zkr16: tool parity failure is explicit" "$out" 'required tool'
  assert_file_not_exists "RS19zkr17: failed tool parity leaves no receipt" "$trust_receipt"

  # #342: environment-only rebind updates image without rewriting candidate identity.
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  trust_receipt="$(git -C "$workdir" rev-parse --absolute-git-dir)/saas-startup-team/env-rebind.json"
  bash "$script" --repo-root "$workdir" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow app.txt --allow check.sh <<<"$auth_token" >/dev/null
  before_base=$(jq -r .base_head "$trust_receipt")
  before_refs=$(jq -r .refs_fingerprint "$trust_receipt")
  before_image=$(jq -r .check_driver.backend.image_id "$trust_receipt")
  before_tag=$(jq -r .auth_tag "$trust_receipt")
  new_image=sha256:2222222222222222222222222222222222222222222222222222222222222222
  ec=0; out=$(SAAS_FAKE_CHECK_IMAGE_ID="$new_image" \
    bash "$script" --repo-root "$workdir" --rebind-check-environment "$trust_receipt" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr18: environment rebind succeeds on unchanged candidate" "$ec" 0
  assert_equals "RS19zkr19: rebind preserves base_head (no candidate rehash)" \
    "$(jq -r .base_head "$trust_receipt")" "$before_base"
  assert_equals "RS19zkr20: rebind preserves refs fingerprint" \
    "$(jq -r .refs_fingerprint "$trust_receipt")" "$before_refs"
  assert_equals "RS19zkr21: rebind advances sealed image binding" \
    "$(jq -r .check_driver.backend.image_id "$trust_receipt")" "$new_image"
  assert_equals "RS19zkr21b: prior image was the default fake" \
    "$before_image" "sha256:1111111111111111111111111111111111111111111111111111111111111111"
  [ "$(jq -r .auth_tag "$trust_receipt")" != "$before_tag" ]
  assert_equals "RS19zkr22: rebind re-signs the receipt" "ok" "ok"
  # Rebind refuses when HEAD moves (candidate identity changed).
  mkdir -p "$workdir/frontend/node_modules/.bin"
  printf 'runtime\n' > "$workdir/frontend/node_modules/runtime.txt"
  printf 'frontend/node_modules/\n' >> "$workdir/.gitignore"
  printf '{"name":"x"}\n' > "$workdir/package.json"
  (cd "$workdir" && git add .gitignore package.json && git commit -qm 'add manifests for runtime seal')
  ec=0; out=$(bash "$script" --repo-root "$workdir" --rebind-check-environment "$trust_receipt" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr23: rebind refuses when base_head moved" "$ec" 1
  assert_output_contains "RS19zkr24: base mismatch is explicit" "$out" 'base no longer matches'

  # Fresh receipt at new HEAD; runtime digest drift with HEAD fixed refuses rebind.
  trust_receipt="$(git -C "$workdir" rev-parse --absolute-git-dir)/saas-startup-team/env-rebind-rt.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  bash "$script" --repo-root "$workdir" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow app.txt --allow check.sh <<<"$auth_token" >/dev/null
  printf 'runtime-drift\n' > "$workdir/frontend/node_modules/runtime.txt"
  ec=0; out=$(bash "$script" --repo-root "$workdir" --rebind-check-environment "$trust_receipt" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zkr25: rebind refuses when runtime digest drifts" "$ec" 1
  assert_output_contains "RS19zkr26: runtime drift refusal is explicit" "$out" 'runtimes changed'
  rm -rf "$workdir"

  # Filtered paths fail closed instead of staging raw LFS/custom-filter content.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf '*.bin filter=lfs\n' > "$workdir/.gitattributes"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" --auth-stdin \
    --allow asset.bin <<<"$auth_token" >/dev/null)
  printf 'raw-lfs-payload\n' > "$workdir/asset.bin"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zl: filtered path fails closed" "$ec" 1
  assert_output_contains "RS19zm: filtered-path failure is explicit" "$out" 'filtered path'
  assert_equals "RS19zn: filtered path creates no commit" "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -rf "$workdir"

  # An empty filter-driver name still selects filter..clean and must fail closed.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf '*.bin filter=\n' > "$workdir/.gitattributes"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  (cd "$workdir" && git add . && git commit -qm init)
  remote=$(mktemp); rm -f "$remote"
  cat > "$workdir/empty-clean-filter" <<SH
#!/usr/bin/env bash
touch $(printf '%q' "$remote")
cat
SH
  chmod +x "$workdir/empty-clean-filter"
  git -C "$workdir" config filter..clean "$workdir/empty-clean-filter"
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" --auth-stdin \
    --allow asset.bin <<<"$auth_token" >/dev/null)
  printf 'raw-payload\n' > "$workdir/asset.bin"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zna: empty filter name fails closed" "$ec" 1
  assert_output_contains "RS19znb: empty-filter failure is explicit" "$out" 'filtered path'
  assert_file_not_exists "RS19znc: empty-named clean filter never executes" "$remote"
  assert_equals "RS19znd: empty filter creates no commit" \
    "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -rf "$workdir" "$remote"

  # A persisted executable fsmonitor is disabled from the first primary Git call.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"
  chmod +x "$workdir/check.sh"; (cd "$workdir" && git add . && git commit -qm init)
  remote=$(mktemp); rm -f "$remote"
  cat > "$workdir/fsmonitor" <<SH
#!/usr/bin/env bash
touch $(printf '%q' "$remote")
exit 1
SH
  chmod +x "$workdir/fsmonitor"
  git -C "$workdir" config core.fsmonitor "$workdir/fsmonitor"
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zne: persisted fsmonitor cannot block supervisor commit" "$ec" 0
  assert_file_not_exists "RS19znf: persisted fsmonitor never executes" "$remote"
  assert_equals "RS19zng: fsmonitor-safe transaction commits once" \
    "$(git -C "$workdir" -c core.fsmonitor=false rev-list --count HEAD)" 2
  rm -rf "$workdir" "$remote"

  # Final primary ref/index updates suppress hooks already exercised in the frozen clone.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"
  chmod +x "$workdir/check.sh"; (cd "$workdir" && git add . && git commit -qm init)
  remote=$(mktemp); patch_file=$(mktemp); rm -f "$remote" "$patch_file"
  mkdir -p "$workdir/primary-hooks"
  cat > "$workdir/primary-hooks/reference-transaction" <<SH
#!/usr/bin/env bash
if [ "\$(git rev-parse --show-toplevel 2>/dev/null || true)" = $(printf '%q' "$workdir") ]; then
  touch $(printf '%q' "$remote")
fi
cat >/dev/null
SH
  cat > "$workdir/primary-hooks/post-index-change" <<SH
#!/usr/bin/env bash
if [ "\$(git rev-parse --show-toplevel 2>/dev/null || true)" = $(printf '%q' "$workdir") ]; then
  touch $(printf '%q' "$patch_file")
fi
SH
  chmod +x "$workdir/primary-hooks/reference-transaction" "$workdir/primary-hooks/post-index-change"
  git -C "$workdir" config core.hooksPath "$workdir/primary-hooks"
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znh: primary-hook-safe transaction succeeds" "$ec" 0
  assert_file_not_exists "RS19zni: primary reference-transaction hook is suppressed" "$remote"
  assert_file_not_exists "RS19znj: primary post-index-change hook is suppressed" "$patch_file"
  assert_equals "RS19znk: hook-safe transaction commits once" \
    "$(git -C "$workdir" -c core.hooksPath=/dev/null rev-list --count HEAD)" 2
  rm -rf "$workdir" "$remote" "$patch_file"

  # Effective per-worktree hooks are frozen and run, not shadowed by --local lookup.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  git -C "$workdir" config extensions.worktreeConfig true
  git -C "$workdir" config --worktree core.hooksPath .worktree-hooks
  mkdir -p "$workdir/.worktree-hooks"
  printf '#!/usr/bin/env bash\nexit 47\n' > "$workdir/.worktree-hooks/pre-commit"
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"
  chmod +x "$workdir/check.sh" "$workdir/.worktree-hooks/pre-commit"
  (cd "$workdir" && git add . && git -c core.hooksPath=/dev/null commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zo: effective worktree hook blocks commit" "$ec" 1
  assert_equals "RS19zp: worktree hook creates no commit" "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -rf "$workdir"

  # Same-status content drift in the primary checkout is detected before ref update.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"
  printf '#!/usr/bin/env bash\nprintf "drifted\\n" > %q\n' "$workdir/app.txt" > "$workdir/check.sh"
  chmod +x "$workdir/check.sh"; (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  printf 'candidate\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zq: same-status primary content drift blocks commit" "$ec" 1
  assert_equals "RS19zr: drift creates no commit" "$(git -C "$workdir" rev-list --count HEAD)" 1
  rm -rf "$workdir"

  # The review guard also disables a persisted executable fsmonitor end to end.
  script="$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh"
  workdir=$(make_workdir); (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/.startup/reviews"; printf 'base\n' > "$workdir/app.txt"
  (cd "$workdir" && git add app.txt && git commit -qm init)
  remote=$(mktemp); rm -f "$remote"
  cat > "$workdir/fsmonitor" <<SH
#!/usr/bin/env bash
touch $(printf '%q' "$remote")
exit 1
SH
  chmod +x "$workdir/fsmonitor"
  git -C "$workdir" config core.fsmonitor "$workdir/fsmonitor"
  snapshot="$workdir/.git/saas-startup-team/qa.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  ec=0; out=$(cd "$workdir" && bash "$script" --snapshot "$snapshot" \
    --auth-stdin --allow .startup/reviews/result.md <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znl: guard snapshots with persisted fsmonitor" "$ec" 0
  printf 'review\n' > "$workdir/.startup/reviews/result.md"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znm: guard verifies with persisted fsmonitor" "$ec" 0
  assert_file_not_exists "RS19znn: guard never executes persisted fsmonitor" "$remote"
  rm -rf "$workdir" "$remote"

  # Allowed paths are literal even when framework directory names contain pathspec metacharacters.
  script="$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh"
  workdir=$(make_workdir); (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/frontend/src/app/[locale]/report"
  printf 'base\n' > "$workdir/frontend/src/app/[locale]/report/allowed.ts"
  printf 'base\n' > "$workdir/frontend/src/app/[locale]/report/sibling.ts"
  (cd "$workdir" && git add frontend && git commit -qm init)
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  snapshot="$workdir/.git/saas-startup-team/literal-exact.json"
  (cd "$workdir" && bash "$script" --snapshot "$snapshot" --auth-stdin \
    --allow 'frontend/src/app/[locale]/report/allowed.ts' <<<"$auth_token" >/dev/null)
  printf 'allowed change\n' > "$workdir/frontend/src/app/[locale]/report/allowed.ts"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn1: bracketed exact allow path verifies" "$ec" 0
  printf 'base\n' > "$workdir/frontend/src/app/[locale]/report/allowed.ts"
  snapshot="$workdir/.git/saas-startup-team/literal-sibling.json"
  (cd "$workdir" && bash "$script" --snapshot "$snapshot" --auth-stdin \
    --allow 'frontend/src/app/[locale]/report/allowed.ts' <<<"$auth_token" >/dev/null)
  printf 'forbidden sibling change\n' > "$workdir/frontend/src/app/[locale]/report/sibling.ts"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn2: bracketed exact allow path rejects sibling" "$ec" 1
  assert_output_contains "RS19znn3: guard reports generic allowed-path boundary" \
    "$out" 'guarded phase modified files outside its allowed paths'
  printf 'base\n' > "$workdir/frontend/src/app/[locale]/report/sibling.ts"
  mkdir -p "$workdir/frontend/src/app/l/report"
  printf 'base\n' > "$workdir/frontend/src/app/l/report/allowed.ts"
  (cd "$workdir" && git add frontend && git commit -qm wildcard-sibling)
  snapshot="$workdir/.git/saas-startup-team/literal-wildcard.json"
  (cd "$workdir" && bash "$script" --snapshot "$snapshot" --auth-stdin \
    --allow 'frontend/src/app/[locale]/report/allowed.ts' <<<"$auth_token" >/dev/null)
  printf 'forbidden wildcard-match change\n' > "$workdir/frontend/src/app/l/report/allowed.ts"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn4: path matching the bracket as a wildcard is rejected" "$ec" 1
  rm -rf "$workdir"

  # Guarded checks may create disposable ignored output and advance supervisor leases.
  script="$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh"
  workdir=$(make_workdir); (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/.startup/leases"
  printf '%s\n' '.startup/leases/' '.env' '.next/' '__pycache__/' '.pytest_cache/' \
    '*.tsbuildinfo' '*.log' 'test-*.db' 'existing-cache/' > "$workdir/.gitignore"
  printf 'base\n' > "$workdir/app.txt"
  (cd "$workdir" && git add app.txt .gitignore && git commit -qm init)
  bash "$PLUGIN_ROOT/scripts/single-flight.sh" --acquire guarded/test \
    --state-dir "$workdir/.startup/leases" --owner supervisor >/dev/null
  printf '1\n' > "$workdir/.startup/leases/guarded-test/heartbeat"
  mkdir -p "$workdir/backend/app/__pycache__" "$workdir/.pytest_cache/v/cache"
  printf 'old bytecode\n' > "$workdir/backend/app/__pycache__/module.pyc"
  printf 'old optimized bytecode\n' > "$workdir/backend/app/__pycache__/legacy.pyo"
  printf 'old unignored bytecode\n' > "$workdir/backend/baseline.pyc"
  printf '["old"]\n' > "$workdir/.pytest_cache/v/cache/nodeids"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  snapshot="$workdir/.git/saas-startup-team/generated-output.json"
  (cd "$workdir" && bash "$script" --snapshot "$snapshot" --auth-stdin \
    --allow app.txt <<<"$auth_token" >/dev/null)
  printf 'allowed\n' > "$workdir/app.txt"
  bash "$PLUGIN_ROOT/scripts/single-flight.sh" --heartbeat guarded/test \
    --state-dir "$workdir/.startup/leases" --owner supervisor >/dev/null
  mkdir -p "$workdir/frontend/.next/cache" "$workdir/backend/app/__pycache__" \
    "$workdir/.pytest_cache/v/cache" "$workdir/backend/logs" "$workdir/backend/data"
  printf '{}\n' > "$workdir/frontend/.next/build-manifest.json"
  printf 'bytecode\n' > "$workdir/backend/app/__pycache__/module.pyc"
  printf 'optimized bytecode\n' > "$workdir/backend/app/__pycache__/legacy.pyo"
  printf 'unignored bytecode\n' > "$workdir/backend/baseline.pyc"
  printf 'executable bytecode\n' > "$workdir/backend/app/__pycache__/payload.pyc"
  chmod +x "$workdir/backend/app/__pycache__/payload.pyc"
  printf '[]\n' > "$workdir/.pytest_cache/v/cache/nodeids"
  printf '{}\n' > "$workdir/frontend/tsconfig.tsbuildinfo"
  printf 'test log\n' > "$workdir/backend/logs/test.log"
  printf 'sqlite test output\n' > "$workdir/backend/data/test-results.db"
  printf 'SECRET=phase-only\n' > "$workdir/.env"
  mkdir -p "$workdir/.startup/leases/worker-created"
  printf 'fake\n' > "$workdir/.startup/leases/worker-created/heartbeat"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn5: allowed change, lease heartbeat, and generated check output verify" "$ec" 0
  assert_file_not_exists "RS19znn5a: new ignored environment file is removed" "$workdir/.env"
  assert_file_not_exists "RS19znn5b: new ignored build output is removed" \
    "$workdir/frontend/.next/build-manifest.json"
  assert_file_not_exists "RS19znn5c: new ignored test database is removed" \
    "$workdir/backend/data/test-results.db"
  assert_file_exists "RS19znn5d: active lease heartbeat is preserved" \
    "$workdir/.startup/leases/guarded-test/heartbeat"
  # Control-plane paths are outside the product seal (#345); worker-created lease
  # noise is not auto-deleted by the guard (agents may clean; not rewrite tax).
  assert_file_exists "RS19znn5e: control-plane lease path remains outside product seal" \
    "$workdir/.startup/leases/worker-created/heartbeat"
  assert_file_not_exists "RS19znn5f: rewritten baseline bytecode is removed after checks" \
    "$workdir/backend/app/__pycache__/module.pyc"
  assert_file_not_exists "RS19znn5g: rewritten baseline pytest cache is removed after checks" \
    "$workdir/.pytest_cache/v/cache/nodeids"
  assert_file_not_exists "RS19znn5h: newly created executable bytecode is removed" \
    "$workdir/backend/app/__pycache__/payload.pyc"
  assert_file_not_exists "RS19znn5i: rewritten optimized bytecode is removed" \
    "$workdir/backend/app/__pycache__/legacy.pyo"
  assert_file_not_exists "RS19znn5ia: empty bytecode cache directory is removed safely" \
    "$workdir/backend/app/__pycache__"
  assert_file_not_exists "RS19znn5ib: empty pytest cache tree is removed safely" \
    "$workdir/.pytest_cache"
  assert_file_not_exists "RS19znn5ic: rewritten unignored baseline bytecode is removed" \
    "$workdir/backend/baseline.pyc"

  git -C "$workdir" restore app.txt
  snapshot="$workdir/.git/saas-startup-team/empty-cache-only.json"
  (cd "$workdir" && bash "$script" --snapshot "$snapshot" --auth-stdin \
    --allow app.txt <<<"$auth_token" >/dev/null)
  printf 'allowed empty-cache check\n' > "$workdir/app.txt"
  mkdir -p "$workdir/backend/empty/__pycache__" "$workdir/.pytest_cache/empty/tree"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn5id: empty-only Python cache creation verifies" "$ec" 0
  assert_file_not_exists "RS19znn5ie: empty-only bytecode cache tree is removed" \
    "$workdir/backend/empty/__pycache__"
  assert_file_not_exists "RS19znn5if: empty-only pytest cache tree is removed" \
    "$workdir/.pytest_cache"

  git -C "$workdir" restore app.txt
  mkdir -p "$workdir/backend/app/__pycache__"
  printf 'baseline mode\n' > "$workdir/backend/app/__pycache__/mode.pyc"
  snapshot="$workdir/.git/saas-startup-team/cache-mode.json"
  (cd "$workdir" && bash "$script" --snapshot "$snapshot" --auth-stdin \
    --allow app.txt <<<"$auth_token" >/dev/null)
  chmod +x "$workdir/backend/app/__pycache__/mode.pyc"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn5j: baseline Python cache mode changes are rejected" "$ec" 1
  assert_file_not_exists "RS19znn5k: rejected mode-changed cache is removed on failure" \
    "$workdir/backend/app/__pycache__/mode.pyc"

  mkdir -p "$workdir/existing-cache" "$workdir/backend/app/__pycache__"
  printf 'SECRET=baseline\n' > "$workdir/.env"
  printf 'baseline\n' > "$workdir/existing-cache/output.bin"
  printf 'failure cache\n' > "$workdir/backend/app/__pycache__/failure.pyc"
  snapshot="$workdir/.git/saas-startup-team/sensitive-ignored.json"
  (cd "$workdir" && bash "$script" --snapshot "$snapshot" --auth-stdin \
    --allow app.txt <<<"$auth_token" >/dev/null)
  printf 'SECRET=changed\n' > "$workdir/.env"
  printf 'changed\n' > "$workdir/existing-cache/output.bin"
  printf 'new unignored bytecode\n' > "$workdir/backend/unignored.pyc"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn6: pre-existing sensitive ignored mutation is rejected" "$ec" 1
  assert_output_contains "RS19znn7: ignored-state component is explicit" \
    "$out" 'protected ignored state'
  assert_output_contains "RS19znn8: ignored-state diagnostic names the sensitive path" \
    "$out" '.env'
  assert_output_contains "RS19znn9: pre-existing generated output stays protected" \
    "$out" 'existing-cache/output.bin'
  assert_file_not_exists "RS19znn9aa: unrelated guard failure still removes baseline bytecode" \
    "$workdir/backend/app/__pycache__/failure.pyc"
  assert_file_not_exists "RS19znn9ab: unrelated guard failure removes unignored bytecode" \
    "$workdir/backend/unignored.pyc"
  rm -rf "$workdir"

  # Git inventories are observed, not converted to an empty clean set.
  script="$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh"
  workdir=$(make_workdir); git -C "$workdir" config user.email t@t.t; git -C "$workdir" config user.name t
  mkdir -p "$workdir/bin"
  printf '__pycache__/\nignored-special\n' > "$workdir/.gitignore"
  printf 'base\n' > "$workdir/app.txt"
  git -C "$workdir" add app.txt .gitignore; git -C "$workdir" commit -qm base
  system_git=$(command -v git)
  cat > "$workdir/bin/git" <<'SH'
#!/usr/bin/env bash
is_ls_files=0; is_ignored=0; is_directory=0; is_hash=0; is_config=0
show_origin=0; show_scope=0; is_list=0; after_separator=0; target= last= args=" $* "
for arg in "$@"; do
  last=$arg
  [ "$arg" != ls-files ] || is_ls_files=1
  [ "$arg" != --ignored ] || is_ignored=1
  [ "$arg" != --directory ] || is_directory=1
  [ "$arg" != hash-object ] || is_hash=1
  [ "$arg" != config ] || is_config=1
  [ "$arg" != --show-origin ] || show_origin=1
  [ "$arg" != --show-scope ] || show_scope=1
  [ "$arg" != --list ] || is_list=1
  if [ "$after_separator" -eq 1 ]; then target=$arg; fi
  [ "$arg" != -- ] || after_separator=1
done
case "${FAIL_GIT_LS_FILES:-}" in
  untracked) [ "$is_ls_files" -eq 0 ] || [ "$is_ignored" -eq 1 ] || exit 73 ;;
  ignored) [ "$is_ls_files" -eq 0 ] || [ "$is_ignored" -eq 0 ] || exit 73 ;;
  cache)
    [ "$is_ls_files" -eq 0 ] || [ "$is_ignored" -eq 0 ] \
      || [ "$is_directory" -eq 1 ] || [ "$target" != . ] || exit 73
    ;;
esac
[ "${FAIL_GIT_HASH:-}" != outside ] || [ "$is_hash" -eq 0 ] || [ "$target" != outside.txt ] || exit 73
if [ "${FAIL_GIT_CONFIG:-}" = list ] && [ "$is_config" -eq 1 ] \
  && [ "$show_origin" -eq 1 ] && [ "$show_scope" -eq 1 ] && [ "$is_list" -eq 1 ]; then
  exit 73
fi
if [ "${FAIL_GIT_CONFIG:-}" = hooks ] \
  && [[ "$args" == *" config --path core.hooksPath "* ]]; then
  "$SYSTEM_GIT" "$@" || true
  exit 73
fi
if [ "${FAIL_GIT_FINAL_HASH:-}" = invalid ] \
  && [[ "$args" == *" hash-object --no-filters "* ]] \
  && [[ "$last" == /tmp/tmp.* ]]; then
  printf 'not-a-git-oid\n'
  exit 0
fi
exec "$SYSTEM_GIT" "$@"
SH
  chmod +x "$workdir/bin/git"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  snapshot="$workdir/.git/saas-startup-team/cache-inventory-failure.json"
  failed_snapshot="$workdir/.git/saas-startup-team/untracked-inventory-failure.json"
  mkfifo "$workdir/ignored-special"
  ec=0; out=$(cd "$workdir" && bash "$script" --snapshot "$failed_snapshot" \
    --auth-stdin --allow app.txt <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn9ab1: protected ignored special files fail snapshot closed" "$ec" 1
  assert_file_not_exists "RS19znn9ab2: special file creates no constant fingerprint" \
    "$failed_snapshot"
  rm -f -- "$workdir/ignored-special"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" FAIL_GIT_LS_FILES=untracked \
    PATH="$workdir/bin:$PATH" bash "$script" --snapshot "$failed_snapshot" \
    --auth-stdin --allow app.txt <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn9ac0: failed untracked inventory blocks snapshot" "$ec" 1
  assert_output_contains "RS19znn9ac1: snapshot inventory failure is explicit" "$out" \
    'cannot enumerate untracked files'
  assert_file_not_exists "RS19znn9ac2: failed inventory creates no false-clean snapshot" \
    "$failed_snapshot"
  failed_snapshot="$workdir/.git/saas-startup-team/hash-failure.json"
  printf 'outside\n' > "$workdir/outside.txt"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" FAIL_GIT_HASH=outside \
    PATH="$workdir/bin:$PATH" bash "$script" --snapshot "$failed_snapshot" \
    --auth-stdin --allow app.txt <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn9ac2a: failed content hash blocks snapshot" "$ec" 1
  assert_file_not_exists "RS19znn9ac2b: hash failure creates no constant fingerprint" \
    "$failed_snapshot"
  rm -f -- "$workdir/outside.txt"
  failed_snapshot="$workdir/.git/saas-startup-team/config-failure.json"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" FAIL_GIT_CONFIG=list \
    PATH="$workdir/bin:$PATH" bash "$script" --snapshot "$failed_snapshot" \
    --auth-stdin --allow app.txt <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn9ac2c: failed exclusion-config inventory blocks snapshot" "$ec" 1
  assert_file_not_exists "RS19znn9ac2d: config failure creates no false fingerprint" \
    "$failed_snapshot"
  failed_snapshot="$workdir/.git/saas-startup-team/hooks-config-failure.json"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" FAIL_GIT_CONFIG=hooks \
    PATH="$workdir/bin:$PATH" bash "$script" --snapshot "$failed_snapshot" \
    --auth-stdin --allow app.txt <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn9ac2e: hook-path config errors block guard snapshot" "$ec" 1
  assert_file_not_exists "RS19znn9ac2f: hook config error creates no snapshot" "$failed_snapshot"
  failed_snapshot="$workdir/.git/saas-startup-team/final-hash-failure.json"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" FAIL_GIT_FINAL_HASH=invalid \
    PATH="$workdir/bin:$PATH" bash "$script" --snapshot "$failed_snapshot" \
    --auth-stdin --allow app.txt <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn9ac2g: invalid aggregate fingerprint blocks guard snapshot" "$ec" 1
  assert_file_not_exists "RS19znn9ac2h: invalid final hash creates no snapshot" "$failed_snapshot"
  printf 'ignored-baseline-a.txt\nignored-baseline-b.txt\n' >> "$workdir/.gitignore"
  printf 'baseline a\n' > "$workdir/ignored-baseline-a.txt"
  printf 'baseline b\n' > "$workdir/ignored-baseline-b.txt"
  array_snapshot="$workdir/.git/saas-startup-team/authenticated-arrays.json"
  (cd "$workdir" && SYSTEM_GIT="$system_git" PATH="$workdir/bin:$PATH" \
    bash "$script" --snapshot "$array_snapshot" --auth-stdin \
    --allow app.txt --allow second.txt <<<"$auth_token" >/dev/null)
  real_jq=$(command -v jq)
  cat > "$workdir/bin/jq" <<'SH'
#!/usr/bin/env bash
mode=${FAIL_GUARD_JQ:-}
for arg in "$@"; do
  if { [ "$mode" = allow-fail ] && [ "$arg" = '.allow[]' ]; } \
    || { [ "$mode" = ignored-fail ] && [ "$arg" = '.ignored_baseline[]' ]; }; then
    "$REAL_JQ" "$@" || true
    exit 73
  fi
  if { [ "$mode" = allow-truncate ] && [ "$arg" = '.allow[]' ]; } \
    || { [ "$mode" = ignored-truncate ] && [ "$arg" = '.ignored_baseline[]' ]; }; then
    "$REAL_JQ" "$@" | sed -n '1p'
    exit 0
  fi
done
exec "$REAL_JQ" "$@"
SH
  chmod +x "$workdir/bin/jq"
  for jq_failure in allow-fail allow-truncate ignored-fail ignored-truncate; do
    rm -f -- "${array_snapshot}.active"
    printf 'guard-active\n' > "${array_snapshot}.active"; chmod 400 "${array_snapshot}.active"
    ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" REAL_JQ="$real_jq" \
      FAIL_GUARD_JQ="$jq_failure" PATH="$workdir/bin:$PATH" \
      bash "$script" --verify "$array_snapshot" --auth-stdin \
      <<<"$auth_token" 2>&1) || ec=$?
    assert_exit_code "RS19znn9ac2 authenticated array jq failure blocks:$jq_failure" "$ec" 1
  done
  rm -f -- "$workdir/bin/jq" "${array_snapshot}.active"
  printf 'guard-active\n' > "${array_snapshot}.active"; chmod 400 "${array_snapshot}.active"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" PATH="$workdir/bin:$PATH" \
    bash "$script" --verify "$array_snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn9ac2i: complete authenticated arrays still verify" "$ec" 0
  rm -f -- "$workdir/ignored-baseline-a.txt" "$workdir/ignored-baseline-b.txt"
  git -C "$workdir" restore .gitignore
  (cd "$workdir" && SYSTEM_GIT="$system_git" PATH="$workdir/bin:$PATH" \
    bash "$script" --snapshot "$snapshot" --auth-stdin --allow app.txt \
    <<<"$auth_token" >/dev/null)
  printf 'allowed\n' > "$workdir/app.txt"
  mkdir -p "$workdir/backend/__pycache__"
  printf 'generated\n' > "$workdir/backend/__pycache__/module.pyc"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" FAIL_GIT_LS_FILES=ignored \
    PATH="$workdir/bin:$PATH" bash "$script" --verify "$snapshot" --auth-stdin \
    <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn9ac3: failed ignored inventory blocks verification" "$ec" 1
  assert_output_contains "RS19znn9ac4: verify inventory failure is explicit" "$out" \
    'cannot enumerate protected ignored paths'
  assert_file_exists "RS19znn9ac5: failed ignored inventory does not guess cache state" \
    "$workdir/backend/__pycache__/module.pyc"
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  ec=0; out=$(cd "$workdir" && SYSTEM_GIT="$system_git" FAIL_GIT_LS_FILES=cache \
    PATH="$workdir/bin:$PATH" bash "$script" --verify "$snapshot" --auth-stdin \
    <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn9ac: failed cache cleanup inventory fails the guard" "$ec" 1
  assert_output_contains "RS19znn9ad: failed cache cleanup inventory is explicit" "$out" \
    'cannot enumerate Python cache paths'
  assert_file_exists "RS19znn9ae: failed inventory does not guess which cache file to remove" \
    "$workdir/backend/__pycache__/module.pyc"
  assert_file_not_contains "RS19znn9af: guard avoids Bash 4.2-only variable-presence syntax" \
    "$script" '[[ -v'
  assert_file_not_contains "RS19znn9af1: git inventories avoid unobservable process substitution" \
    "$script" '< <(git -c core.fsmonitor=false ls-files'
  assert_file_not_contains "RS19znn9ag: supervisor avoids Bash 4.2-only variable-presence syntax" \
    "$PLUGIN_ROOT/scripts/supervisor-commit.sh" '[[ -v'
  assert_file_not_contains "RS19znn9ah: container checker avoids Bash 4.2-only variable-presence syntax" \
    "$PLUGIN_ROOT/scripts/supervisor-check-container.sh" '[[ -v'
  rm -rf "$workdir"

  # Origin remote-tracking drift is not product seal (#347): allowlisted write still verifies.
  script="$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh"
  workdir=$(make_workdir); git -C "$workdir" config user.email t@t.t; git -C "$workdir" config user.name t
  printf 'base\n' > "$workdir/app.txt"; git -C "$workdir" add app.txt; git -C "$workdir" commit -qm base
  remote=$(mktemp -d); rm -rf "$remote"; git init -q --bare "$remote"
  git -C "$workdir" remote add origin "$remote"; git -C "$workdir" push -qu origin HEAD:main
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  snapshot="$workdir/.git/saas-startup-team/origin-noise.json"
  (cd "$workdir" && bash "$script" --snapshot "$snapshot" --auth-stdin \
    --allow review.md <<<"$auth_token" >/dev/null)
  git -C "$workdir" update-ref refs/remotes/origin/other "$(git -C "$workdir" rev-parse HEAD)"
  printf 'review\n' > "$workdir/review.md"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn9a: unrelated origin remote-tracking drift still verifies" "$ec" 0
  rm -rf "$workdir" "$remote"
  assert_file_not_contains "RS19znn9b: guard no longer ls-remotes origin for seal" \
    "$script" 'ls-remote'

  # Large guard collections are streamed to jq instead of crossing the per-argument limit.
  script="$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh"
  workdir=$(make_workdir); (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/cache" "$workdir/bin"
  printf 'cache/\n' > "$workdir/.gitignore"
  printf 'base\n' > "$workdir/app.txt"
  (cd "$workdir" && git add app.txt .gitignore && git commit -qm init)
  for ((i=0; i<160; i++)); do printf -v path 'entry-%04d' "$i"; : > "$workdir/cache/$path"; done
  large_allow_args=()
  for ((i=0; i<96; i++)); do
    printf -v path 'review-artifact-%04d-abcdefghijklmnopqrstuvwxyz0123456789.txt' "$i"
    large_allow_args+=(--allow "$path")
  done
  real_jq=$(command -v jq)
  cat > "$workdir/bin/jq" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "${#arg}" -le 4096 ] || { echo "simulated per-argument limit" >&2; exit 126; }
done
exec "$REAL_JQ" "$@"
SH
  chmod +x "$workdir/bin/jq"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  snapshot="$workdir/.git/saas-startup-team/large-ignored-baseline.json"
  ec=0; out=$(cd "$workdir" && REAL_JQ="$real_jq" PATH="$workdir/bin:$PATH" \
    bash "$script" --snapshot "$snapshot" --auth-stdin --allow app.txt "${large_allow_args[@]}" \
    <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znn10: large ignored baseline avoids oversized jq arguments" "$ec" 0
  assert_json_field "RS19znn11: streamed snapshot retains every ignored baseline entry" \
    "$snapshot" '.ignored_baseline | length' 160
  assert_json_field "RS19znn12: streamed snapshot retains every allowed path" \
    "$snapshot" '.allow | length' 97
  rm -rf "$workdir"

  # Review artifact paths cannot traverse symlinked ancestors outside the repository.
  script="$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh"
  workdir=$(make_workdir); (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"; (cd "$workdir" && git add app.txt && git commit -qm init)
  state_dir=$(mktemp -d); mkdir -p "$workdir/.startup"
  ln -s "$state_dir" "$workdir/.startup/reviews"
  snapshot="$workdir/.git/saas-startup-team/qa.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  ec=0; out=$(cd "$workdir" && bash "$script" --snapshot "$snapshot" \
    --auth-stdin --allow .startup/reviews/result.md <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zno: guard rejects symlinked artifact ancestor at snapshot" "$ec" 1
  assert_output_contains "RS19znp: unsafe snapshot slot is explicit" "$out" 'unsafe allowed artifact slot'
  assert_file_not_exists "RS19znq: rejected artifact slot creates no snapshot" "$snapshot"
  rm "$workdir/.startup/reviews"; mkdir "$workdir/.startup/reviews"
  (cd "$workdir" && bash "$script" --snapshot "$snapshot" \
    --auth-stdin --allow .startup/reviews/result.md <<<"$auth_token" >/dev/null)
  rmdir "$workdir/.startup/reviews"; ln -s "$state_dir" "$workdir/.startup/reviews"
  printf 'redirected review\n' > "$workdir/.startup/reviews/result.md"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" \
    --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znr: guard rejects artifact ancestor redirected before verify" "$ec" 1
  assert_output_contains "RS19zns: unsafe verified slot is explicit" "$out" 'artifact slot became unsafe'
  rm -rf "$workdir" "$state_dir"

  # RS19znt–znw linked-worktree control identity suite deleted (primary-only).

  # QA guard fingerprints pre-existing product state, not just HEAD.
  script="$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh"
  workdir=$(make_workdir); (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/.startup/reviews" "$workdir/.startup/leases/qa"; printf 'base\n' > "$workdir/app.txt"
  printf '.startup/state.json\n.startup/leases/\nignored-product.txt\n' > "$workdir/.gitignore"
  printf '{"active_role":"team-lead"}\n' > "$workdir/.startup/state.json"
  printf 'supervisor-owner\n' > "$workdir/.startup/leases/qa/owner"
  printf 'ignored baseline\n' > "$workdir/ignored-product.txt"
  (cd "$workdir" && git add app.txt .gitignore && git commit -qm init)
  git -C "$workdir" branch -m guarded-active
  git -C "$workdir" branch main HEAD
  printf 'tech-diff\n' > "$workdir/app.txt"
  snapshot="$workdir/.git/saas-startup-team/qa.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  (cd "$workdir" && bash "$script" --snapshot "$snapshot" \
    --auth-stdin --allow .startup/reviews/result.md <<<"$auth_token" >/dev/null)
  cp "$snapshot" "$snapshot.trusted"
  chmod u+w "$snapshot"
  jq '.allow=["."]' "$snapshot" > "$snapshot.tmp"; mv "$snapshot.tmp" "$snapshot"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zi: forged role guard is rejected" "$ec" 1
  mv "$snapshot.trusted" "$snapshot"; chmod 400 "$snapshot"
  guard_head=$(git -C "$workdir" rev-parse HEAD)
  guard_ref=$(git -C "$workdir" symbolic-ref HEAD)
  guard_index=$(git -C "$workdir" write-tree)
  # Sibling-linked-worktree advance tests removed; primary-only branch rewrites below.
  concurrent_head=$(printf 'concurrent\n' | git -C "$workdir" commit-tree "$(git -C "$workdir" rev-parse 'HEAD^{tree}')" -p "$guard_head")
  git -C "$workdir" update-ref refs/heads/guard-concurrent "$concurrent_head"
  printf 'review\n' > "$workdir/.startup/reviews/result.md"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zj: concurrent branch progress violates the role guard" "$ec" 1
  assert_equals "RS19zj1: unrelated ref advance leaves guarded HEAD unchanged" \
    "$(git -C "$workdir" rev-parse HEAD)" "$guard_head"
  assert_equals "RS19zj2: unrelated ref advance leaves guarded branch unchanged" \
    "$(git -C "$workdir" symbolic-ref HEAD)" "$guard_ref"
  assert_equals "RS19zj3: unrelated ref advance leaves guarded index unchanged" \
    "$(git -C "$workdir" write-tree)" "$guard_index"
  git -C "$workdir" update-ref refs/heads/guard-concurrent "$guard_head" "$concurrent_head"
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  git -C "$workdir" update-ref refs/heads/guard-concurrent "$concurrent_head" "$guard_head"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zj4a: direct update-ref of a sibling branch is rejected" "$ec" 1
  git -C "$workdir" update-ref refs/heads/guard-concurrent "$guard_head" "$concurrent_head"
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  git -C "$workdir" update-ref refs/heads/main "$concurrent_head" "$guard_head"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zj5: direct update-ref of protected main is rejected" "$ec" 1
  git -C "$workdir" update-ref refs/heads/main "$guard_head" "$concurrent_head"
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  git -C "$workdir" update-ref refs/heads/worker-created "$guard_head"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zj6: worker-created branch ref violates role guard" "$ec" 1
  git -C "$workdir" update-ref -d refs/heads/worker-created
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  git -C "$workdir" tag worker-tag
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zj6a: worker-created tag violates role guard" "$ec" 1
  git -C "$workdir" tag -d worker-tag >/dev/null
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  git -C "$workdir" update-ref refs/remotes/origin/guard-concurrent "$concurrent_head"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zj7: worker-created remote ref violates role guard" "$ec" 1
  git -C "$workdir" update-ref -d refs/remotes/origin/guard-concurrent
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/.git/hooks/pre-push"
  chmod +x "$workdir/.git/hooks/pre-push"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zja: worker-created Git hook violates role guard" "$ec" 1
  assert_file_not_exists "RS19zja1: terminal guard failure retires its active marker" "${snapshot}.active"
  rm -f "$workdir/.git/hooks/pre-push"
  guard_snapshot="$workdir/.git/saas-startup-team/qa-retry.json"
  (cd "$workdir" && bash "$script" --snapshot "$guard_snapshot" \
    --auth-stdin --allow .startup/reviews/result.md <<<"$auth_token" >/dev/null)
  assert_equals "RS19zja2: fresh retry sees exactly one live guard" \
    "$(find "$workdir/.git/saas-startup-team" -maxdepth 1 -name '*.active' | wc -l | tr -d ' ')" 1
  (cd "$workdir" && bash "$script" --verify "$guard_snapshot" \
    --auth-stdin <<<"$auth_token" >/dev/null)
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  printf 'worker-owner\n' > "$workdir/.startup/leases/qa/owner"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zjaa: worker lease mutation violates role guard" "$ec" 1
  printf 'supervisor-owner\n' > "$workdir/.startup/leases/qa/owner"
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  printf 'review\n' > "$workdir/.startup/reviews/result.md"
  base=$(git -C "$workdir" rev-parse HEAD)
  ec=0; out=$(cd "$workdir" && printf '%s\n' \
    '{"tool_input":{"file_path":".startup/reviews/result.md"}}' \
    | bash "$PLUGIN_ROOT/scripts/auto-commit.sh" 2>&1) || ec=$?
  assert_exit_code "RS19zjb: guarded artifact hook defers commit" "$ec" 0
  assert_equals "RS19zjc: guarded artifact hook leaves HEAD unchanged" \
    "$(git -C "$workdir" rev-parse HEAD)" "$base"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS20: uncommitted review-only artifact is accepted" "$ec" 0
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  (cd "$workdir" && git add .startup/reviews/result.md && git commit -qm review)
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS20aa: worker-authored review commit is rejected" "$ec" 1
  git -C "$workdir" reset -q --soft HEAD^
  git -C "$workdir" reset -q HEAD -- .startup/reviews/result.md
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  (cd "$workdir" && git add app.txt)
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS20a: staging the same product content is detected" "$ec" 1
  (cd "$workdir" && git reset -q HEAD -- app.txt)
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS20b: restoring the index restores the boundary" "$ec" 0
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  printf '{"active_role":"qa"}\n' > "$workdir/.startup/state.json"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS20c: ignored supervisor state mutation is rejected" "$ec" 1
  printf '{"active_role":"team-lead"}\n' > "$workdir/.startup/state.json"
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  mkdir -p "$workdir/.startup/signoffs"; printf 'not-review\n' > "$workdir/.startup/signoffs/result.md"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS20d: QA signoff mutation is rejected" "$ec" 1
  rm -rf "$workdir/.startup/signoffs"
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  printf 'qa-mutation\n' >> "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS21: QA product mutation is rejected" "$ec" 1
  git -C "$workdir" restore app.txt
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  printf 'ignored mutation\n' > "$workdir/ignored-product.txt"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS21a: QA mutation of an existing ignored file is rejected" "$ec" 1
  printf 'ignored baseline\n' > "$workdir/ignored-product.txt"
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  exclude_path="$(git -C "$workdir" rev-parse --git-path info/exclude)"
  case "$exclude_path" in /*) : ;; *) exclude_path="$workdir/$exclude_path" ;; esac
  mkdir -p "$(dirname "$exclude_path")"; touch "$exclude_path"
  cp "$exclude_path" "$workdir/.startup/reviews/exclude.before"
  printf 'hidden-source.ts\n' >> "$exclude_path"
  printf 'hidden\n' > "$workdir/hidden-source.ts"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS21b: QA cannot hide a source file through Git exclude metadata" "$ec" 1
  cp "$workdir/.startup/reviews/exclude.before" "$exclude_path"
  rm -f "$workdir/.startup/reviews/exclude.before" "$workdir/hidden-source.ts"
  rm -rf "$workdir"

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
