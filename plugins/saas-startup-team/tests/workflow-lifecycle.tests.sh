# Workflow-level lifecycle/state safety regressions.
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "workflow-lifecycle.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_workflow_lifecycle_safety() {
  echo -e "\n${CYAN}Suite WL: workflow lifecycle safety${NC}"
  local goal maintain startup improve lessons design first second count guardian lease workdir owner pid_file failure ec before after
  goal="$PLUGIN_ROOT/references/workflows/goal-deliver.md"
  maintain="$PLUGIN_ROOT/references/workflows/maintain.md"
  startup="$PLUGIN_ROOT/commands/startup.md"
  improve="$PLUGIN_ROOT/references/workflows/improve.md"
  lessons="$PLUGIN_ROOT/commands/lessons-deliver.md"
  design="$PLUGIN_ROOT/docs/design/lessons-deliver.md"

  assert_before() {
    local label="$1" file="$2" earlier="$3" later="$4"
    first=$(grep -nF -- "$earlier" "$file" | head -1 | cut -d: -f1 || true)
    second=$(grep -nF -- "$later" "$file" | head -1 | cut -d: -f1 || true)
    if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then
      assert_equals "$label" yes yes
    else
      assert_equals "$label" no yes
    fi
  }

  assert_before "WL1: goal lease precedes every route path" "$goal" \
    '## Step 1.25: Claim the Delivery Scope' \
    '## Step 1.5: Autonomous Light Fast Path'
  assert_file_contains "WL2: goal uses durable lease owner" "$goal" 'GOAL_OWNER_FILE='
  assert_file_contains "WL3: goal blocks contaminated deep retry" "$goal" \
    'never launch a deep worker from'
  assert_file_contains "WL4: goal verifies merge state" "$goal" \
    'query that exact PR before doing anything else'
  assert_file_contains "WL5: goal releases terminal lease" "$goal" \
    'release `$GOAL_LEASE_KEY` with `$GOAL_OWNER_FILE`'

  assert_before "WL6: maintain pass lease precedes worktree mutation" "$maintain" \
    '## Whole-Pass Lease' '## Workspace — Dedicated Worktree'
  assert_file_contains "WL7: maintain lease is common-worktree scoped" "$maintain" \
    'MAINTAIN_LEASE_DIR="$GIT_COMMON/saas-startup-team/leases"'
  assert_file_contains "WL8: maintain runner has signal trap cleanup" "$maintain" \
    '`EXIT INT TERM HUP` trap'
  assert_file_contains "WL9: maintain scheduler uses flock" "$maintain" \
    'maintain-scheduler.lock'
  assert_file_contains "WL10: split child is resolved by exact marker" "$maintain" \
    'resolve_split_child()'
  assert_file_contains "WL11: split child id is verified numeric" "$maintain" \
    'split child id is not numeric'
  assert_file_not_contains "WL12: issue create uses no unsupported JSON flag" "$maintain" \
    '--json number -q .number'
  assert_file_contains "WL12a: split list failure is captured" "$maintain" \
    'split_json=$(gh issue list'
  assert_file_contains "WL12b: split view failure is captured" "$maintain" \
    'child_body=$(gh issue view'

  assert_before "WL13: startup lease precedes idea capture" "$startup" \
    'Before any command that may write project state' '## Step 1: Capture the SaaS Idea'
  count=$(grep -cF -- '--acquire "startup:${PWD}"' "$startup" || true)
  assert_equals "WL14: startup acquires one session identity" "$count" 1
  assert_file_contains "WL15: startup heartbeats stable owner file" "$startup" \
    '--owner-file .startup/leases/.owners/startup.owner'

  assert_before "WL16: improve lease precedes branch mutation" "$improve" \
    '## Claim Work Unit' '## Establish Branch'
  assert_before "WL17: improve lease precedes role mutation" "$improve" \
    '## Claim Work Unit' '## Reset active_role'
  assert_file_contains "WL18: improve snapshots exact state" "$improve" \
    'state.before'
  assert_file_contains "WL19: improve refusal restores original branch" "$improve" \
    'git checkout "$ORIGINAL_BRANCH"'
  assert_file_contains "WL20: improve refusal verifies clean state" "$improve" \
    'test -z "$(git status --porcelain)"'

  assert_file_contains "WL21: lessons records exact attempt base" "$lessons" \
    'ATTEMPT_BASE=$(git rev-parse'
  assert_file_contains "WL22: lessons unstages failed attempt" "$lessons" \
    'git reset --hard "$ATTEMPT_BASE"'
  assert_file_contains "WL23: lessons removes only clean-start untracked files" "$lessons" \
    'git clean -fd'
  assert_file_contains "WL24: lessons reruns tribunal on generated HEAD" "$lessons" \
    '**Final-head tribunal gate.**'
  assert_file_contains "WL25: lessons pins verdict to HEAD" "$lessons" \
    'TRIBUNAL_HEAD=$(git rev-parse HEAD)'
  assert_file_contains "WL26: lessons preserves supervisor commits" "$lessons" \
    'supervisor-commit.sh'
  assert_file_contains "WL27: design documents final-head tribunal" "$design" \
    '**Final-head tribunal gate:**'

  guardian="$PLUGIN_ROOT/scripts/lease-guardian.sh"
  lease="$PLUGIN_ROOT/scripts/single-flight.sh"
  assert_file_exists "WL28: persistent lease guardian exists" "$guardian"
  workdir=$(mktemp -d)
  owner="$workdir/owners/test.owner"
  pid_file="$workdir/owners/guardian.json"
  failure="$workdir/heartbeat-failed"
  mkdir -p "$workdir/owners"
  bash "$lease" --acquire guardian:test --state-dir "$workdir" --owner-file "$owner" \
    --ttl-seconds 10 >/dev/null
  bash "$guardian" start --state-dir "$workdir" --pid-file "$pid_file" \
    --failure-file "$failure" --interval-seconds 1 --max-seconds 10 \
    --lease guardian:test "$owner" >/dev/null
  ec=0; bash "$guardian" check --pid-file "$pid_file" --failure-file "$failure" || ec=$?
  assert_exit_code "WL29: guardian survives its starting shell" "$ec" 0
  before=$(stat -c %Y "$workdir/guardian-test/heartbeat")
  sleep 2
  after=$(stat -c %Y "$workdir/guardian-test/heartbeat")
  if [ "$after" -gt "$before" ]; then assert_equals "WL30: guardian advances heartbeat" yes yes
  else assert_equals "WL30: guardian advances heartbeat" no yes; fi
  ec=0; bash "$guardian" stop --pid-file "$pid_file" --failure-file "$failure" || ec=$?
  assert_exit_code "WL31: guardian stops explicitly" "$ec" 0
  assert_file_not_exists "WL32: guardian PID receipt is removed" "$pid_file"
  bash "$lease" --release guardian:test --state-dir "$workdir" --owner-file "$owner" >/dev/null
  rm -rf "$workdir"
}

test_workflow_lifecycle_safety
