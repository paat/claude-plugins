# Runtime role, mutation ownership, lifecycle, and prompt-budget regressions.
declare -F make_workdir >/dev/null 2>&1 || {
  echo "runtime-safety.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_runtime_safety() {
  echo -e "\n${CYAN}Suite RS: runtime role and lifecycle safety${NC}"
  local workdir ec out count script owner_file state_dir snapshot patch_file remote base old_owner trust_receipt auth_token
  local linked git_dir common_dir raw_commondir guard_snapshot guard_auth

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
  assert_file_contains "RS11: scoped browser operator" "$PLUGIN_ROOT/agents/business-founder.md" 'saas-startup-team:browser-operator'

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
  assert_file_contains "RS14e: maintain loop snapshots trusted hooks" \
    "$PLUGIN_ROOT/references/workflows/maintain-loop.md" '--snapshot-trust "$COMMIT_TRUST"'
  assert_file_contains "RS14f: mutation receipts require supervisor authentication" \
    "$PLUGIN_ROOT/references/workflows/mutation-ownership.md" '--auth-stdin'
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
    mkdir -p "$root/bin"
    cat > "$root/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = sandbox ] || exit 2
shift
if [ "${1:-}" = --help ]; then
  printf '%s\n' '--permission-profile --sandbox-state-disable-network'
  exit 0
fi
sandbox_cwd=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --permission-profile) shift 2 ;;
    -C) sandbox_cwd=$2; shift 2 ;;
    --sandbox-state-disable-network) shift ;;
    *) break ;;
  esac
done
[ "$#" -gt 0 ]
[ -z "$sandbox_cwd" ] || cd "$sandbox_cwd"
"$@"
SH
    chmod +x "$root/bin/codex"
  }

  supervisor_snapshot() {
    auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
    (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
      --auth-stdin \
      --allow app.txt --allow check.sh --allow test.sh --allow extra.txt \
      --allow fail-check --allow trigger-hook --allow .githooks --allow .gitignore \
      <<<"$auth_token" >/dev/null)
  }

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

  # A check-created hook-slot symlink is removed without following it.
  workdir=$(make_workdir); make_supervisor_sandbox "$workdir"; (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  remote=$(mktemp -d)
  printf 'base\n' > "$workdir/app.txt"
  printf '#!/usr/bin/env bash\nrm -rf .git/supervisor-hooks\nln -s %q .git/supervisor-hooks\n' "$remote" > "$workdir/check.sh"
  chmod +x "$workdir/check.sh"; (cd "$workdir" && git add . && git commit -qm init)
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; supervisor_snapshot
  printf 'changed\n' > "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zb: hook-slot symlink cannot redirect trusted copy" "$ec" 0
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
  patch_file=$(mktemp)
  cat > "$patch_file" <<'SH'
#!/usr/bin/env bash
[ "$1" = --firewall ] && grep -q '^+approved$' "$2" || exit 3
SH
  chmod +x "$patch_file"
  trust_receipt="$workdir/.git/saas-startup-team/supervisor-trust.json"; auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  (cd "$workdir" && bash "$script" --snapshot-trust "$trust_receipt" \
    --auth-stdin --allow app.txt --require-approved-diff \
    --firewall-script "$patch_file" <<<"$auth_token" >/dev/null)
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
  rm -rf "$workdir" "$patch_file"

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

  # Raw linked-worktree control files are identity-bound, not just semantically resolved.
  workdir=$(make_workdir); (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'base\n' > "$workdir/app.txt"; printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/check.sh"
  chmod +x "$workdir/check.sh"; (cd "$workdir" && git add . && git commit -qm init)
  linked=$(mktemp -d); rmdir "$linked"; git -C "$workdir" worktree add -q -b guard-control "$linked"
  make_supervisor_sandbox "$linked"
  git_dir=$(git -C "$linked" rev-parse --absolute-git-dir)
  raw_commondir=$(cat "$git_dir/commondir")
  common_dir=$(cd "$git_dir/$raw_commondir" && pwd -P)
  guard_snapshot="$git_dir/saas-startup-team/qa.json"
  guard_auth=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  script="$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh"
  (cd "$linked" && bash "$script" --snapshot "$guard_snapshot" \
    --auth-stdin --allow .startup/reviews/result.md <<<"$guard_auth" >/dev/null)
  script="$PLUGIN_ROOT/scripts/supervisor-commit.sh"; trust_receipt="$git_dir/saas-startup-team/supervisor-trust.json"
  auth_token=$(bash "$PLUGIN_ROOT/scripts/mutation-auth-token.sh")
  (cd "$linked" && bash "$script" --snapshot-trust "$trust_receipt" --auth-stdin \
    --allow app.txt --allow check.sh <<<"$auth_token" >/dev/null)
  printf 'changed\n' > "$linked/app.txt"
  printf '%s\n' "$common_dir" > "$git_dir/commondir"
  script="$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh"
  ec=0; out=$(cd "$linked" && bash "$script" --verify "$guard_snapshot" \
    --auth-stdin <<<"$guard_auth" 2>&1) || ec=$?
  assert_exit_code "RS19znt: guard rejects equivalent raw commondir rewrite" "$ec" 1
  assert_output_contains "RS19znu: guard reports linked-worktree control drift" "$out" 'Git hooks or control metadata'
  script="$PLUGIN_ROOT/scripts/supervisor-commit.sh"
  ec=0; out=$(cd "$linked" && PATH="$linked/bin:$PATH" bash "$script" \
    --message test --trust-receipt "$trust_receipt" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19znv: supervisor rejects equivalent raw commondir rewrite" "$ec" 1
  assert_output_contains "RS19znw: supervisor reports linked-worktree metadata drift" "$out" 'Git metadata changed'
  printf '%s\n' "$raw_commondir" > "$git_dir/commondir"
  git -C "$workdir" worktree remove --force "$linked"
  rm -rf "$workdir"

  # QA guard fingerprints pre-existing product state, not just HEAD.
  script="$PLUGIN_ROOT/scripts/delivery-mutation-guard.sh"
  workdir=$(make_workdir); (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/.startup/reviews" "$workdir/.startup/leases/qa"; printf 'base\n' > "$workdir/app.txt"
  printf '.startup/state.json\n.startup/leases/\nignored-product.txt\n' > "$workdir/.gitignore"
  printf '{"active_role":"team-lead"}\n' > "$workdir/.startup/state.json"
  printf 'supervisor-owner\n' > "$workdir/.startup/leases/qa/owner"
  printf 'ignored baseline\n' > "$workdir/ignored-product.txt"
  (cd "$workdir" && git add app.txt .gitignore && git commit -qm init)
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
  git -C "$workdir" branch worker-ref
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zj: worker-created ref violates role guard" "$ec" 1
  git -C "$workdir" branch -D worker-ref >/dev/null
  printf '#!/usr/bin/env bash\nexit 0\n' > "$workdir/.git/hooks/pre-push"
  chmod +x "$workdir/.git/hooks/pre-push"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zja: worker-created Git hook violates role guard" "$ec" 1
  rm -f "$workdir/.git/hooks/pre-push"
  printf 'worker-owner\n' > "$workdir/.startup/leases/qa/owner"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS19zjaa: worker lease mutation violates role guard" "$ec" 1
  printf 'supervisor-owner\n' > "$workdir/.startup/leases/qa/owner"
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
  (cd "$workdir" && git add app.txt)
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS20a: staging the same product content is detected" "$ec" 1
  (cd "$workdir" && git reset -q HEAD -- app.txt)
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS20b: restoring the index restores the boundary" "$ec" 0
  printf 'guard-active\n' > "${snapshot}.active"; chmod 400 "${snapshot}.active"
  printf '{"active_role":"qa"}\n' > "$workdir/.startup/state.json"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS20c: ignored supervisor state mutation is rejected" "$ec" 1
  printf '{"active_role":"team-lead"}\n' > "$workdir/.startup/state.json"
  mkdir -p "$workdir/.startup/signoffs"; printf 'not-review\n' > "$workdir/.startup/signoffs/result.md"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS20d: QA signoff mutation is rejected" "$ec" 1
  rm -rf "$workdir/.startup/signoffs"
  printf 'qa-mutation\n' >> "$workdir/app.txt"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS21: QA product mutation is rejected" "$ec" 1
  git -C "$workdir" restore app.txt
  printf 'ignored mutation\n' > "$workdir/ignored-product.txt"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS21a: QA mutation of an existing ignored file is rejected" "$ec" 1
  printf 'ignored baseline\n' > "$workdir/ignored-product.txt"
  cp "$(git -C "$workdir" rev-parse --git-path info/exclude)" "$workdir/.startup/reviews/exclude.before"
  printf 'hidden-source.ts\n' >> "$(git -C "$workdir" rev-parse --git-path info/exclude)"
  printf 'hidden\n' > "$workdir/hidden-source.ts"
  ec=0; out=$(cd "$workdir" && bash "$script" --verify "$snapshot" --auth-stdin <<<"$auth_token" 2>&1) || ec=$?
  assert_exit_code "RS21b: QA cannot hide a source file through Git exclude metadata" "$ec" 1
  cp "$workdir/.startup/reviews/exclude.before" "$(git -C "$workdir" rev-parse --git-path info/exclude)"
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
  rm -rf "$workdir" "$remote" "$patch_file"

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
    "$PLUGIN_ROOT/references/workflows/maintain-loop.md" \
    "$PLUGIN_ROOT/commands/startup.md" \
    "$PLUGIN_ROOT/commands/lessons-deliver.md" \
    "$PLUGIN_ROOT/docs/design/lessons-deliver.md" 2>/dev/null || true)"
  assert_equals "RS35zi: active mutation flows never guess a default branch" "$out" ""
  assert_file_contains "RS35zj: queue builder uses shared default resolver" "$PLUGIN_ROOT/scripts/maintain-queue.sh" 'default-branch.sh'

  # Model-free probe paths: no script contains an assistant launch.
  script="$PLUGIN_ROOT/scripts/workflow-probe.sh"
  assert_file_not_contains "RS36: probe never launches Claude" "$script" 'claude -p'
  assert_file_not_contains "RS37: probe never launches Codex" "$script" 'codex exec'
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
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" maintain 2>&1) || ec=$?
  assert_exit_code "RS38: empty maintain queue is model-free no-op" "$ec" 3
  ec=0; out=$(cd "$workdir" && PATH="$workdir/bin:$PATH" bash "$script" maintain-loop 2>&1) || ec=$?
  assert_exit_code "RS39: empty maintain-loop queue is no-op" "$ec" 3
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
  check_ceiling maintain 744
  check_ceiling maintain-loop 698
  check_ceiling goal-deliver 539
  check_ceiling improve 494
  check_ceiling tweak 453
}

test_runtime_safety
