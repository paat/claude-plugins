# Sourced by run-tests.sh — executable maintain-loop delivery lifecycle regressions.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "maintain-delivery.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_maintain_delivery_lifecycle() {
  echo -e "\n${CYAN}Suite MD: maintain-loop delivery receipts${NC}"
  local repo script probe protocol base head merge delivery run pr_open pr_merged issue_open issue_closed
  local result pending events ec out duplicate_pr feature2_base feature2_head feature2_merge parent_run
  local rollback_head rollback_merge rollback_pr_open rollback_pr_merged common state_root victim
  local fake_bin fake_head fake_issue fake_mutation fake_log changed_issue bad_rollback_head
  local fake_pr fake_prs fake_checks fake_run remote qa_command bad_command monitor_command tribunal fake_tribunal
  local live_output live_proof_path test_plugin delivery_impl lease_state lease_run authority_command
  local issue_scope fresh_repo fresh_common fresh_wt fresh_origin_state fresh_resume_state
  local fresh_legacy_state fresh_base fresh_pr_head fresh_scope fresh_drift fresh_receipt_head fresh_ledger
  local fresh_resume_ledger legacy_delivery legacy_state legacy_base legacy_cache legacy_wt legacy_check_oid
  local legacy_mode legacy_recovery_delivery
  local legacy_receipt
  local controller_root state_before state_after alternate_parent fresh_state_root fresh_delivery
  local fresh_controller fresh_origin external_before external_after
  local fresh_runtime runtime_before runtime_after lease_before lease_after
  local heartbeat_before heartbeat_after
  local legacy_claimed_at rollback_parent rollback_delivery
  repo=$(make_workdir)
  test_plugin="$repo/.test-plugin"; mkdir "$test_plugin"; cp -a "$PLUGIN_ROOT/scripts/." "$test_plugin/"
  delivery_impl="$test_plugin/maintain-delivery.sh"
  sed -i '/^resolve_repo_slug() {$/a\
  if [ -n "${MAINTAIN_TEST_REPO_SLUG:-}" ]; then printf "%s\\n" "$MAINTAIN_TEST_REPO_SLUG"; return 0; fi' "$delivery_impl"
  sed -i '/^ensure_gh_bin() {$/a\
  if [ -n "${MAINTAIN_TEST_GH_BIN:-}" ]; then GH_BIN=$MAINTAIN_TEST_GH_BIN; return 0; fi' "$delivery_impl"
  sed -i '/^trusted_gh() ($/a\
  if [ -n "${MAINTAIN_TEST_GH_BIN:-}" ]; then "$MAINTAIN_TEST_GH_BIN" "$@"; exit $?; fi' "$delivery_impl"
  sed -i '/^validate_tribunal_plugin() {$/a\
  if [ -n "${MAINTAIN_TEST_TRIBUNAL_ROOT:-}" ]; then TRIBUNAL_ROOT=$MAINTAIN_TEST_TRIBUNAL_ROOT; TRIBUNAL_COLLECTOR="$TRIBUNAL_ROOT/scripts/collect-review-evidence.sh"; TRIBUNAL_PATH=$ORIGINAL_PATH; return 0; fi' "$delivery_impl"
  script="$repo/maintain-delivery-test-wrapper.sh"
  cat > "$script" <<'DELIVERY_WRAPPER'
#!/bin/bash
set -euo pipefail
action=${1:?}; shift
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root) [ "$#" -ge 2 ]; args+=(--repo-root "${MAINTAIN_TEST_CONTROLLER_ROOT:?}"); shift 2 ;;
    --command-file)
      [ "$#" -ge 2 ]; command_file=$2
      case "$command_file" in
        "${MAINTAIN_TEST_PRIMARY_ROOT:?}"/*) command_file=${command_file#"$MAINTAIN_TEST_PRIMARY_ROOT"/} ;;
      esac
      args+=(--command-file "$command_file"); shift 2
      ;;
    *) args+=("$1"); shift ;;
  esac
done
exec bash "${MAINTAIN_TEST_DELIVERY_IMPL:?}" "$action" \
  --lease-state "${MAINTAIN_TEST_LEASE_STATE:?}" \
  --controller-run-id "${MAINTAIN_TEST_CONTROLLER_RUN:?}" "${args[@]}"
DELIVERY_WRAPPER
  chmod +x "$script"
  export MAINTAIN_TEST_DELIVERY_IMPL="$delivery_impl"
  probe="$PLUGIN_ROOT/scripts/workflow-probe.sh"
  protocol="$PLUGIN_ROOT/references/workflows/goal-deliver-maintain-receipts.md"
  git -C "$repo" branch -m main
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  controller_root="$repo/.worktrees/maintain"
  export MAINTAIN_TEST_CONTROLLER_ROOT="$controller_root" MAINTAIN_TEST_PRIMARY_ROOT="$repo"
  switch_test_lease() {
    local next_run=$1
    if [ -n "${lease_state:-}" ] && [ -e "$lease_state" ]; then
      bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$lease_state" \
        --repo-root "$repo" --worktree "$controller_root" --run-id "$lease_run" >/dev/null
    fi
    common=$(git -C "$repo" rev-parse --git-common-dir)
    case "$common" in /*) : ;; *) common="$repo/$common" ;; esac
    lease_run=$next_run
    lease_state="$common/saas-startup-team/maintain-runtime/$lease_run-leases.json"
    if [ ! -e "$controller_root" ]; then
      git -C "$repo" worktree add --detach "$controller_root" HEAD >/dev/null
    else
      git -C "$controller_root" checkout -q --detach "$(git -C "$repo" rev-parse HEAD)"
    fi
    bash "$test_plugin/maintain-leases.sh" acquire --repo-root "$repo" --mode maintain \
      --worktree "$controller_root" \
      --run-id "$lease_run" --state-file "$lease_state" >/dev/null
    export MAINTAIN_TEST_LEASE_STATE="$lease_state" MAINTAIN_TEST_CONTROLLER_RUN="$lease_run"
  }
  fake_bin="$repo/fake-bin"; fake_head="$repo/fake-gh-head"; fake_issue="$repo/fake-gh-issue.json"
  fake_mutation="$repo/fake-gh-mutation"; fake_log="$repo/fake-gh.log"
  mkdir "$fake_bin"
  cat > "$fake_bin/gh" <<'FAKE_GH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "${1:-} ${2:-}" in
  "repo view")
    printf '%s\n' 'fixture-owner/fixture-repo'
    ;;
  "pr view")
    cat "$FAKE_GH_PR_SOURCE"
    ;;
  "pr list")
    cat "$FAKE_GH_PRS_SOURCE"
    ;;
  "pr checks")
    cat "$FAKE_GH_CHECKS_SOURCE"
    ;;
  "pr merge")
    shift 3
    pin=""; method=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --match-head-commit) pin=$2; shift 2 ;;
        --merge|--squash) method=$1; shift ;;
        --repo) shift 2 ;;
        *) exit 90 ;;
      esac
    done
    [ -n "$pin" ] && [ -n "$method" ] || exit 91
    [ "$pin" = "$(cat "$FAKE_GH_HEAD_FILE")" ] || exit 41
    printf '%s %s\n' "$pin" "$method" > "$FAKE_GH_MUTATION"
    ;;
  "run view")
    cat "$FAKE_GH_RUN_SOURCE"
    ;;
  "issue view")
    if [[ "$*" == *"--json number,state,title,body,updatedAt"* ]]; then
      jq '{number,state,title,body,updatedAt}' "$FAKE_GH_ISSUE_SOURCE"
    else
      cat "$FAKE_GH_ISSUE_SOURCE"
    fi
    if [ -n "${FAKE_GH_DRIFT_SOURCE:-}" ] && jq -e '.state == "OPEN"' "$FAKE_GH_ISSUE_SOURCE" >/dev/null; then
      cp -- "$FAKE_GH_DRIFT_SOURCE" "$FAKE_GH_ISSUE_SOURCE"
    fi
    ;;
  "issue close")
    tmp="${FAKE_GH_ISSUE_SOURCE}.tmp"
    jq --arg at "${FAKE_GH_CLOSED_AT:?}" '.state="CLOSED" | .closedAt=$at | .updatedAt=$at' \
      "$FAKE_GH_ISSUE_SOURCE" > "$tmp"
    mv -- "$tmp" "$FAKE_GH_ISSUE_SOURCE"
    printf 'issue-closed\n' > "$FAKE_GH_MUTATION"
    ;;
  *) exit 92 ;;
esac
FAKE_GH
  chmod +x "$fake_bin/gh"

  fake_tribunal="$repo/fake-tribunal"; mkdir -p "$fake_tribunal/scripts"
  cat > "$fake_tribunal/scripts/collect-review-evidence.sh" <<'FAKE_TRIBUNAL'
#!/bin/bash
set -euo pipefail
sha() { sha256sum -- "$1" | awk '{print $1}'; }
command=${1:?}; shift
root=""; pr=""; output=""; collection=""; manifest_sha=""; arbitration=""; proof_sha=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root) root=$2; shift 2 ;;
    --pr) pr=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --collection) collection=$2; shift 2 ;;
    --expected-manifest-sha256) manifest_sha=$2; shift 2 ;;
    --arbitration) arbitration=$2; shift 2 ;;
    --expected-proof-sha256) proof_sha=$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
case "$command" in
  collect)
    mkdir -- "$output"
    head=$(jq -r .headRefOid "$FAKE_GH_PR_SOURCE")
    body=$(printf body | sha256sum | awk '{print $1}')
    diff=$(printf diff | sha256sum | awk '{print $1}')
    jq -S -n --argjson pr "$pr" --arg head "$head" --arg body "$body" --arg diff "$diff" \
      '{pull_request:{number:$pr,head_oid:$head,body:{sha256:$body}},diff:{sha256:$diff}}' > "$output/manifest.json"
    manifest_sha=$(sha "$output/manifest.json")
    jq -nc --arg collection "$output" --arg manifest_sha256 "$manifest_sha" \
      --arg runner_bundle_sha256 772148ee2c99214cf9d6d56bcf3389160997e885d388936ffd7783f75d42e0b5 \
      --arg head_oid "$head" \
      '{collection:$collection,manifest_sha256:$manifest_sha256,runner_bundle_sha256:$runner_bundle_sha256,head_oid:$head_oid}'
    ;;
  verify-collection)
    [ "$(sha "$collection/manifest.json")" = "$manifest_sha" ]
    jq -nc --arg collection "$collection" --arg manifest_sha256 "$manifest_sha" \
      '{collection:$collection,manifest_sha256:$manifest_sha256,status:"valid"}'
    ;;
  finalize)
    [ "$(sha "$collection/manifest.json")" = "$manifest_sha" ]
    jq -e 'type == "object"
      and keys == ["conflicts_resolved","findings","provider_assessment","scope_findings","summary","tribunal_verdict"]
      and .tribunal_verdict.decision == "APPROVE" and (.findings|type == "array")
      and (.scope_findings|type == "array") and (.provider_assessment|type == "object")' \
      "$arbitration" >/dev/null
    canonical=$(mktemp); jq -S . "$arbitration" > "$canonical"
    if [ -f "$collection/arbitration.json" ]; then cmp -s "$canonical" "$collection/arbitration.json"; else mv "$canonical" "$collection/arbitration.json"; fi
    rm -f "$canonical"
    if [ ! -f "$collection/proof.json" ]; then
      head=$(jq -r .pull_request.head_oid "$collection/manifest.json")
      pr=$(jq -r .pull_request.number "$collection/manifest.json")
      body=$(jq -r .pull_request.body.sha256 "$collection/manifest.json")
      diff=$(jq -r .diff.sha256 "$collection/manifest.json")
      arbitration_sha=$(sha "$collection/arbitration.json")
      jq -S -n --arg finalized "$(date -u +%FT%TZ)" --arg manifest "$manifest_sha" \
        --argjson pr "$pr" --arg head "$head" --arg body "$body" --arg diff "$diff" \
        --arg arbitration_sha "$arbitration_sha" \
        '{schema:"tribunal-proof/v1",finalized_at:$finalized,manifest_sha256:$manifest,
          pull_request:{number:$pr,head_oid:$head,body_sha256:$body,diff_sha256:$diff},
          arbitration:{path:"arbitration.json",sha256:$arbitration_sha,decision:"APPROVE",
            confidence:0.95,critical_count:0,high_count:0}}' > "$collection/proof.json"
    fi
    jq -nc --arg collection "$collection" --arg manifest_sha256 "$manifest_sha" \
      --arg proof_sha256 "$(sha "$collection/proof.json")" \
      --arg arbitration_sha256 "$(sha "$collection/arbitration.json")" \
      '{collection:$collection,manifest_sha256:$manifest_sha256,proof_sha256:$proof_sha256,
        arbitration_sha256:$arbitration_sha256}'
    ;;
  verify-proof)
    [ "$(sha "$collection/manifest.json")" = "$manifest_sha" ]
    [ "$(sha "$collection/proof.json")" = "$proof_sha" ]
    jq -nc --arg collection "$collection" --arg proof_sha256 "$proof_sha" \
      '{collection:$collection,proof_sha256:$proof_sha256,status:"valid"}'
    ;;
  *) exit 2 ;;
esac
FAKE_TRIBUNAL
  chmod +x "$fake_tribunal/scripts/collect-review-evidence.sh"
  export MAINTAIN_TEST_TRIBUNAL_ROOT="$fake_tribunal"

  assert_result_rejected() {
    local label=$1 issue=$2 canonical=$3 mode=$4 prefix=$5 bad="$repo/bad-result-$2-$RANDOM.md" ec=0
    local event_run controller_run invocation_command
    grep -qF -- "$prefix" "$canonical"
    if [ "$mode" = omit ]; then
      awk -v p="$prefix" 'index($0,p) != 1' "$canonical" > "$bad"
    else
      awk -v p="$prefix" '{if (index($0,p) == 1) print p "contradiction"; else print}' \
        "$canonical" > "$bad"
    fi
    event_run=$(bash "$script" show --repo-root "$repo" --issue "$issue" | jq -r .delivery_id)
    controller_run=$(jq -r .run_id "$MAINTAIN_TEST_LEASE_STATE")
    invocation_command=$(jq -r .mode "$MAINTAIN_TEST_LEASE_STATE")
    SAAS_RUN_ID="$event_run" SAAS_PARENT_RUN_ID="$controller_run" \
      SAAS_INVOCATION_COMMAND="$invocation_command" \
      bash "$script" finalize --repo-root "$repo" --issue "$issue" \
        --result-source "$bad" --profile standard >/dev/null 2>&1 || ec=$?
    assert_exit_code "$label" "$ec" 1
    rm -f -- "$bad"
  }
  write_tribunal_evidence() {
    local issue=$1 pr=$2 reviewed_head=$3 prefix=$4
    tribunal="$repo/$prefix-tribunal.json"
    jq -n '
      def assessment($status): {findings_accepted:0,findings_rejected:0,false_positives:[],status:$status};
      {tribunal_verdict:{decision:"APPROVE",confidence:0.95,rationale:"Collector-owned review cleared the bound diff"},
       findings:[],scope_findings:[],provider_assessment:{codex:assessment("ok"),gemini:assessment("disabled"),
         glm:assessment("disabled"),deepseek:assessment("disabled"),qwen:assessment("disabled"),claude:assessment("disabled")},
       conflicts_resolved:[],summary:"Current-head review approved"}' > "$tribunal"
  }
  write_issue_scope() {
    jq '{number,state,title,body,updatedAt}' "$1" > "$2"
  }
  qa_command="$repo/live-proof.sh"; bad_command="$repo/bad-proof.sh"
  authority_command="$repo/authority-proof.sh"
  monitor_command="$repo/.startup/monitor-checks.sh"
  mkdir -p "$repo/.startup" "$repo/.claude" "$repo/.github/workflows"
  cat > "$qa_command" <<'PROOF_COMMAND'
#!/bin/bash
set -euo pipefail
detail=$(printf '%s\n' "$MAINTAIN_MERGE_SHA:$MAINTAIN_DEPLOY_RUN_ID:$MAINTAIN_LIVE_TARGET_SOURCE" | sha256sum | awk '{print $1}')
jq -n --argjson issue "$MAINTAIN_ISSUE_NUMBER" --arg merge "$MAINTAIN_MERGE_SHA" \
  --arg run "$MAINTAIN_DEPLOY_RUN_ID" --arg source "$MAINTAIN_LIVE_TARGET_SOURCE" \
  --arg observed "$(date -u +%FT%TZ)" --arg detail "$detail" \
  '{schema_version:1,kind:"live",issue_number:$issue,merge_sha:$merge,deploy_run_id:$run,
    target_source:$source,status:"passed",observed_at:$observed,
    assertions:[{id:"production-smoke",status:"passed",detail_digest:$detail}]}'
PROOF_COMMAND
  cat > "$bad_command" <<'BAD_PROOF_COMMAND'
#!/bin/sh
printf '%s\n' '{"status":"passed"}'
BAD_PROOF_COMMAND
  cat > "$authority_command" <<'AUTHORITY_PROOF_COMMAND'
#!/bin/sh
exit 1
AUTHORITY_PROOF_COMMAND
  cat > "$monitor_command" <<'MONITOR_COMMAND'
#!/bin/bash
set -euo pipefail
# maintain-proof-env: LEGACY_PROOF_SECRET
[ -z "${LEGACY_PROOF_SECRET:-}" ] || exit 97
printf '%s\n' 'monitor authenticated' >&2
if [ "$FIXTURE_MONITOR_MODE" = finding ]; then
  jq -nc '{pattern_key:"test:failed",severity:"high",entity:null,title:"Failure",body:"Bound live check failed"}'
fi
MONITOR_COMMAND
  cat > "$repo/.claude/saas-startup-team.local.md" <<'MONITOR_CONFIG'
monitor:
  custom_checks: .startup/monitor-checks.sh
MONITOR_CONFIG
  cat > "$repo/.github/workflows/deploy.yml" <<'DEPLOY_WORKFLOW'
name: Fixture Deploy
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: true
DEPLOY_WORKFLOW
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/check.sh"
  chmod +x "$qa_command" "$bad_command" "$authority_command" "$monitor_command" "$repo/check.sh"
  printf 'base\n' > "$repo/app.txt"
  git -C "$repo" add app.txt check.sh live-proof.sh bad-proof.sh authority-proof.sh .startup/monitor-checks.sh \
    .claude/saas-startup-team.local.md .github/workflows/deploy.yml
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  remote="$repo/remote.git"; git init -q --bare "$remote"; git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q origin main
  git -C "$repo" checkout -qb issue-one
  printf 'fixed\n' >> "$repo/app.txt"
  git -C "$repo" commit -qam fix
  head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --squash issue-one
  git -C "$repo" commit -qm 'merge issue one'
  merge=$(git -C "$repo" rev-parse HEAD)

  run=run-0123456789abcdef0123456789abcdef
  delivery=run-11111111111111111111111111111111
  pr_open="$repo/pr-open.json"; pr_merged="$repo/pr-merged.json"
  issue_open="$repo/issue-open.json"; issue_closed="$repo/issue-closed.json"
  fake_pr="$repo/fake-gh-pr.json"; fake_prs="$repo/fake-gh-prs.json"
  fake_checks="$repo/fake-gh-checks.json"; fake_run="$repo/fake-gh-run.json"
  jq -n --arg head "$head" \
    --arg body $'Refs #1\nMaintain-Loop-Issue: #1\nMaintain-Loop-Delivery: run-11111111111111111111111111111111\nMaintain-Loop-Role: normal\nMaintain-Loop-Action: run-11111111111111111111111111111111-normal' \
    '{number:11,state:"OPEN",headRefName:"issue-one",headRefOid:$head,baseRefName:"main",title:"Fix issue one",
      body:$body,mergeCommit:null,files:[{path:"app.txt"}]}' > "$pr_open"
  jq --arg merge "$merge" '.state="MERGED" | .mergeCommit={oid:$merge}' "$pr_open" > "$pr_merged"
  jq -n '{number:1,state:"OPEN",updatedAt:"2026-07-14T10:01:00Z",closedAt:null,
    title:"Issue one",body:"Fix the first issue",labels:[],
    comments:[{id:"IC_1",body:"Acceptance detail",createdAt:"2026-07-14T09:30:00Z",updatedAt:null}]}' > "$issue_open"
  jq --arg at "2099-07-14T10:03:00Z" '.state="CLOSED" | .updatedAt=$at | .closedAt=$at' \
    "$issue_open" > "$issue_closed"
  jq -n '[{name:"unit",bucket:"pass",link:"https://example.invalid/check/11"}]' > "$fake_checks"
  printf '[]\n' > "$fake_prs"
  cp -- "$pr_open" "$fake_pr"; cp -- "$issue_open" "$fake_issue"
  write_tribunal_evidence 1 11 "$head" issue-one
  export MAINTAIN_TEST_GH_BIN="$fake_bin/gh" MAINTAIN_TEST_REPO_SLUG=fixture-owner/fixture-repo
  export FAKE_GH_PR_SOURCE="$fake_pr" FAKE_GH_PRS_SOURCE="$fake_prs"
  export FAKE_GH_CHECKS_SOURCE="$fake_checks" FAKE_GH_RUN_SOURCE="$fake_run"
  export FAKE_GH_ISSUE_SOURCE="$fake_issue" FAKE_GH_HEAD_FILE="$fake_head" FAKE_GH_MUTATION="$fake_mutation"
  export FAKE_GH_LOG="$fake_log" FAKE_GH_CLOSED_AT="2099-07-14T10:03:00Z"
  issue_scope="$repo/issue-scope.json"
  write_issue_scope "$fake_issue" "$issue_scope"

  fresh_repo=$(make_workdir)
  git -C "$fresh_repo" config user.email test@example.invalid
  git -C "$fresh_repo" config user.name Test
  git -C "$fresh_repo" branch -m main
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fresh_repo/check.sh"
  printf 'base\n' > "$fresh_repo/app.txt"
  chmod +x "$fresh_repo/check.sh"
  git -C "$fresh_repo" add check.sh app.txt
  git -C "$fresh_repo" commit -qm base
  fresh_base=$(git -C "$fresh_repo" rev-parse HEAD)
  fresh_common=$(git -C "$fresh_repo" rev-parse --absolute-git-dir)
  fresh_wt="$fresh_repo/.worktrees/maintain"
  fresh_origin_state="$fresh_common/saas-startup-team/maintain-runtime/fresh-order-leases.json"
  fresh_resume_state="$fresh_common/saas-startup-team/maintain-runtime/fresh-resume-leases.json"
  fresh_legacy_state="$fresh_common/saas-startup-team/maintain-runtime/fresh-legacy-leases.json"
  fresh_scope="$fresh_repo/issue-scope.json"
  fresh_drift="$fresh_repo/issue-scope-drift.json"
  fresh_controller=run-cccccccccccccccccccccccccccccccc
  fresh_origin=fresh-origin
  fresh_runtime="$fresh_common/saas-startup-team/maintain-runtime"
  fresh_state_root="$fresh_runtime/deliveries"
  fresh_ledger="$fresh_common/saas-startup-team/maintain-runtime/deliveries/run-$fresh_origin.json"
  fresh_resume_ledger="$fresh_common/saas-startup-team/maintain-runtime/deliveries/run-fresh-resume.json"
  write_issue_scope "$fake_issue" "$fresh_scope"
  parent_run=$run
  fresh_delivery=run-22222222222222222222222222222222
  bash "$test_plugin/maintain-leases.sh" acquire --repo-root "$fresh_repo" \
    --mode maintain --run-id "$fresh_controller" --state-file "$fresh_origin_state" \
    --worktree "$fresh_wt" >/dev/null
  assert_file_not_exists "MD0b: lease acquisition alone does not create the worktree" "$fresh_wt"
  assert_file_not_exists "MD0f0: fresh lease has no delivery runtime directory" "$fresh_state_root"
  : > "$fake_log"
  rm -f -- "$fake_mutation"
  external_before=$(wc -l < "$fake_log")
  runtime_before=$(/usr/bin/tar -C "$fresh_runtime" --sort=name -cf - . \
    | /usr/bin/sha256sum | /usr/bin/awk '{print $1}')
  lease_before=$(/usr/bin/sha256sum -- "$fresh_origin_state" | /usr/bin/awk '{print $1}')
  heartbeat_before=$(lease_state_fingerprint "$fresh_origin_state")
  ec=0
  env -u SAAS_PARENT_RUN_ID -u SAAS_RUN_ID -u SAAS_INVOCATION_COMMAND \
    bash "$delivery_impl" begin --repo-root "$fresh_repo" --issue 1 \
      --run-id "$fresh_origin" --delivery-id "$fresh_controller" --merge-budget 1 \
      --scope-json "$fresh_scope" --lease-state "$fresh_origin_state" \
      --controller-run-id "$fresh_controller" \
      >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0f1: delivery child cannot equal its active controller" "$ec" 2
  runtime_after=$(/usr/bin/tar -C "$fresh_runtime" --sort=name -cf - . \
    | /usr/bin/sha256sum | /usr/bin/awk '{print $1}')
  lease_after=$(/usr/bin/sha256sum -- "$fresh_origin_state" | /usr/bin/awk '{print $1}')
  heartbeat_after=$(lease_state_fingerprint "$fresh_origin_state")
  assert_equals "MD0f2: collision leaves the complete maintenance runtime tree unchanged" \
    "$runtime_after" "$runtime_before"
  assert_equals "MD0f3: collision leaves the lease state byte-identical" \
    "$lease_after" "$lease_before"
  assert_equals "MD0f4: collision does not heartbeat the active lease" \
    "$heartbeat_after" "$heartbeat_before"
  assert_file_not_exists "MD0f5: collision does not create the deliveries directory" "$fresh_state_root"
  assert_file_not_exists "MD0f6: collision does not create a delivery lock" "$fresh_state_root/.lock"
  assert_file_not_exists "MD0f7: collision creates no receipt" \
    "$fresh_state_root/issue-1/current.json"
  assert_file_not_exists "MD0f8: collision creates no run ledger" "$fresh_ledger"
  external_after=$(wc -l < "$fake_log")
  assert_equals "MD0f9: collision performs no GitHub call" "$external_after" "$external_before"
  assert_file_not_exists "MD0f10: collision performs no external mutation" "$fake_mutation"
  ec=0
  SAAS_PARENT_RUN_ID="$parent_run" bash "$delivery_impl" begin --repo-root "$fresh_repo" \
    --issue 1 --run-id "$fresh_controller" --delivery-id "$parent_run" --merge-budget 1 \
    --scope-json "$fresh_scope" --lease-state "$fresh_origin_state" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0: parent run identity cannot equal the delivery ID" "$ec" 2
  rm -f -- "$fresh_state_root/.lock"
  state_before=absent
  if [ -d "$fresh_state_root" ]; then
    state_before=$(find -P "$fresh_state_root" -printf '%P\t%y\t%s\t%m\n' | sort)
  fi
  pending=$(bash "$delivery_impl" pending --repo-root "$fresh_repo")
  assert_equals "MD0a: fresh pending is readable before the dedicated worktree exists" \
    "$(jq length <<<"$pending")" 0
  state_after=absent
  if [ -d "$fresh_state_root" ]; then
    state_after=$(find -P "$fresh_state_root" -printf '%P\t%y\t%s\t%m\n' | sort)
  fi
  assert_equals "MD0a1: unlocked empty pending is state-preserving" "$state_after" "$state_before"
  assert_file_not_exists "MD0a2: unlocked empty pending does not create a lock" "$fresh_state_root/.lock"
  ec=0
  bash "$delivery_impl" begin --repo-root "$fresh_repo" --issue 1 --run-id "$fresh_controller" \
    --delivery-id "$fresh_delivery" --merge-budget 1 --lease-state "$fresh_origin_state" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0c: begin requires the classified issue scope snapshot" "$ec" 2
  ec=0
  bash "$delivery_impl" begin --repo-root "$fresh_repo" --issue 1 --run-id "$fresh_controller" \
    --delivery-id "$fresh_delivery" --merge-budget 1 --scope-json "$fresh_scope" \
    --lease-state "$fresh_origin_state" --controller-run-id "$fresh_controller" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0d: primary-root begin cannot bypass the dedicated worktree lease" "$ec" 3
  assert_equals "MD0e: rejected primary begin creates no receipt" \
    "$(bash "$delivery_impl" pending --repo-root "$fresh_repo" | jq length)" 0
  bash "$test_plugin/maintain-attempt.sh" reset --repo-root "$fresh_repo" \
    --worktree "$fresh_wt" --base-sha "$fresh_base" --lease-state "$fresh_origin_state" \
    --run-id "$fresh_controller" --controller-run-id "$fresh_controller" >/dev/null
  assert_equals "MD0f: leased reset creates a clean exact-base worktree" \
    "$(git -C "$fresh_wt" rev-parse HEAD):$(git -C "$fresh_wt" status --porcelain)" \
    "$fresh_base:"
  ec=0
  bash "$delivery_impl" begin --repo-root "$fresh_wt" --issue 1 --run-id "$fresh_controller" \
    --delivery-id "$fresh_delivery" --merge-budget 1 --scope-json "$fake_issue" \
    --lease-state "$fresh_origin_state" --controller-run-id "$fresh_controller" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0g: begin rejects a scope snapshot with extra fields" "$ec" 2
  jq '.title="Issue scope changed during the base gate"' "$fake_issue" > "$fresh_drift"
  cp -- "$fresh_drift" "$fake_issue"
  ec=0
  bash "$delivery_impl" begin --repo-root "$fresh_wt" --issue 1 --run-id "$fresh_controller" \
    --delivery-id "$fresh_delivery" --merge-budget 1 --scope-json "$fresh_scope" \
    --lease-state "$fresh_origin_state" --controller-run-id "$fresh_controller" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0h: begin rejects issue scope drift after classification" "$ec" 1
  assert_equals "MD0i: scope drift creates no receipt" \
    "$(bash "$delivery_impl" pending --repo-root "$fresh_repo" | jq length)" 0
  assert_file_not_exists "MD0j: scope drift creates no origin run ledger" "$fresh_ledger"
  cp -- "$issue_open" "$fake_issue"
  bash "$delivery_impl" begin --repo-root "$fresh_wt" --issue 1 --run-id "$fresh_origin" \
    --delivery-id "$fresh_delivery" --merge-budget 1 --scope-json "$fresh_scope" \
    --lease-state "$fresh_origin_state" --controller-run-id "$fresh_controller" \
    >/dev/null
  assert_equals "MD0k: begin succeeds from the created lease-bound worktree" \
    "$(bash "$delivery_impl" show --repo-root "$fresh_wt" --issue 1 | jq -r .state)" claimed
  assert_equals "MD0k1: new receipt binds the canonical maintain controller" \
    "$(bash "$delivery_impl" show --repo-root "$fresh_wt" --issue 1 \
      | jq -r '[.schema_version,.controller.mode,.controller.worktree] | @tsv')" \
    $'2\tmaintain\t'"$fresh_wt"
  assert_equals "MD0k1aa: immutable receipt origin may differ from its active controller" \
    "$(bash "$delivery_impl" show --repo-root "$fresh_wt" --issue 1 | jq -r .origin_run_id)" \
    "$fresh_origin"
  pending=$(bash "$delivery_impl" pending --repo-root "$fresh_repo")
  assert_equals "MD0k1a: pending inventory exposes one canonical route object" \
    "$(jq -cS '.[0].controller_route' <<<"$pending")" \
    "$(jq -cnS --arg worktree "$fresh_wt" \
      '{kind:"canonical",mode:"maintain",worktree:$worktree}')"
  ec=0; out=$(bash "$probe" maintain --root "$fresh_repo" --dry-run 2>&1) || ec=$?
  assert_exit_code "MD0k1b: public maintain probe reaches canonical receipt work" "$ec" 0
  assert_output_contains "MD0k1c: public maintain selects the canonical controller" "$out" \
    'workflow-probe: maintain controller-route=canonical'
  ec=0; out=$(bash "$probe" maintain-loop --root "$fresh_repo" --dry-run 2>&1) || ec=$?
  assert_exit_code "MD0k1d: public maintain-loop probe reaches the same canonical work" "$ec" 0
  assert_output_contains "MD0k1e: public maintain-loop selects the canonical controller" "$out" \
    'workflow-probe: maintain-loop controller-route=canonical'

  rm -f -- "$fresh_state_root/.lock"
  printf 'preserve\n' > "$fresh_state_root/.orphan.tmp"
  state_before=$(find -P "$fresh_state_root" -printf '%P\t%y\t%s\t%m\n' | sort)
  ec=0; bash "$delivery_impl" pending --repo-root "$fresh_repo" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0k2: unlocked pending with receipts fails closed" "$ec" 1
  ec=0; bash "$delivery_impl" show --repo-root "$fresh_wt" --issue 1 >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0k3: unlocked show with receipts fails closed" "$ec" 1
  state_after=$(find -P "$fresh_state_root" -printf '%P\t%y\t%s\t%m\n' | sort)
  assert_equals "MD0k4: rejected read-only inspection does not mutate receipt state" \
    "$state_after" "$state_before"
  assert_file_not_exists "MD0k5: read-only inspection never creates the lock" "$fresh_state_root/.lock"
  assert_file_contains "MD0k6: read-only inspection never deletes unrelated temp state" \
    "$fresh_state_root/.orphan.tmp" preserve
  : > "$fresh_state_root/.lock"

  printf 'feature\n' > "$fresh_wt/app.txt"
  git -C "$fresh_wt" add app.txt
  git -C "$fresh_wt" commit -qm feature
  fresh_pr_head=$(git -C "$fresh_wt" rev-parse HEAD)
  runtime_before=$(/usr/bin/tar -C "$fresh_runtime" --sort=name -cf - . \
    | /usr/bin/sha256sum | /usr/bin/awk '{print $1}')
  heartbeat_before=$(lease_state_fingerprint "$fresh_origin_state")
  external_before=$(wc -l < "$fake_log")
  ec=0
  bash "$delivery_impl" plan-pr --repo-root "$fresh_wt" --issue 1 --role normal \
    --branch fresh-issue --base-sha "$fresh_base" --head-sha "$fresh_pr_head" \
    --lease-state "$fresh_origin_state" \
    --controller-run-id run-dddddddddddddddddddddddddddddddd \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0k7: root A cannot resume through controller B's lease" "$ec" 3
  runtime_after=$(/usr/bin/tar -C "$fresh_runtime" --sort=name -cf - . \
    | /usr/bin/sha256sum | /usr/bin/awk '{print $1}')
  heartbeat_after=$(lease_state_fingerprint "$fresh_origin_state")
  assert_equals "MD0k8: rejected controller leaves delivery runtime byte-identical" \
    "$runtime_after" "$runtime_before"
  assert_equals "MD0k9: rejected controller cannot heartbeat another root's lease" \
    "$heartbeat_after" "$heartbeat_before"
  external_after=$(wc -l < "$fake_log")
  assert_equals "MD0k10: rejected controller performs no GitHub call" \
    "$external_after" "$external_before"
  bash "$delivery_impl" plan-pr --repo-root "$fresh_wt" --issue 1 --role normal \
    --branch fresh-issue --base-sha "$fresh_base" --head-sha "$fresh_pr_head" \
    --lease-state "$fresh_origin_state" --controller-run-id "$fresh_controller" >/dev/null
  fresh_receipt_head=$(bash "$delivery_impl" show --repo-root "$fresh_wt" --issue 1 | jq -r .normal.head_sha)
  assert_equals "MD0l: planned receipt binds the exact PR head" "$fresh_receipt_head" "$fresh_pr_head"
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$fresh_origin_state" \
    --repo-root "$fresh_repo" --worktree "$fresh_wt" --run-id "$fresh_controller" >/dev/null
  jq 'del(.controller,.event_binding) | .schema_version = 1' \
    "$fresh_state_root/issue-1/current.json" > "$fresh_state_root/issue-1/current.json.tmp"
  mv -- "$fresh_state_root/issue-1/current.json.tmp" "$fresh_state_root/issue-1/current.json"
  legacy_claimed_at=$(jq -r .updated_at "$fresh_state_root/issue-1/current.json")
  pending=$(bash "$delivery_impl" pending --repo-root "$fresh_repo")
  assert_equals "MD0l1: historical v1 inventory selects the bounded legacy route" \
    "$(jq -cS '.[0].controller_route' <<<"$pending")" \
    "$(jq -cnS --arg worktree "$fresh_repo/.worktrees/maintain" \
      '{kind:"legacy-recovery",mode:"maintain-loop",worktree:$worktree}')"
  ec=0; out=$(bash "$probe" maintain --root "$fresh_repo" --dry-run 2>&1) || ec=$?
  assert_exit_code "MD0l2: public maintain probe reaches historical v1 recovery" "$ec" 0
  assert_output_contains "MD0l3: public maintain exposes the legacy recovery route" "$out" \
    'workflow-probe: maintain controller-route=legacy-recovery'
  ec=0; out=$(bash "$probe" maintain-loop --root "$fresh_repo" --dry-run 2>&1) || ec=$?
  assert_exit_code "MD0l4: public maintain-loop probe reaches historical v1 recovery" "$ec" 0
  assert_output_contains "MD0l5: public maintain-loop exposes the same legacy route" "$out" \
    'workflow-probe: maintain-loop controller-route=legacy-recovery'
  rm -rf "$fresh_wt"
  bash "$test_plugin/maintain-leases.sh" acquire --repo-root "$fresh_repo" \
    --mode maintain --run-id fresh-resume --state-file "$fresh_resume_state" \
    --worktree "$fresh_wt" >/dev/null
  bash "$test_plugin/maintain-attempt.sh" reset --repo-root "$fresh_repo" \
    --worktree "$fresh_wt" --base-sha "$fresh_receipt_head" --lease-state "$fresh_resume_state" \
    --run-id "$fresh_controller" --controller-run-id fresh-resume >/dev/null 2>&1
  assert_equals "MD0m: a new run recreates the missing worktree at the receipt PR head" \
    "$(git -C "$fresh_wt" rev-parse HEAD):$(git -C "$fresh_wt" status --porcelain)" \
    "$fresh_receipt_head:"
  ec=0
  bash "$delivery_impl" plan-pr --repo-root "$fresh_wt" --issue 1 --role normal \
    --branch fresh-issue --base-sha "$fresh_base" --head-sha "$fresh_receipt_head" \
    --lease-state "$fresh_resume_state" --controller-run-id fresh-resume \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0n: canonical maintain cannot adopt an unbound legacy v1 receipt" "$ec" 3
  assert_equals "MD0n1: rejected cross-route adoption leaves the legacy receipt unchanged" \
    "$(bash "$delivery_impl" show --repo-root "$fresh_wt" --issue 1 \
      | jq -r '[.schema_version,.updated_at] | @tsv')" \
    $'1\t'"$legacy_claimed_at"
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$fresh_resume_state" \
    --repo-root "$fresh_repo" --worktree "$fresh_wt" --run-id fresh-resume >/dev/null
  pending=$(bash "$delivery_impl" pending --repo-root "$fresh_repo")
  legacy_mode=$(jq -er '.[0].controller_route.mode' <<<"$pending")
  legacy_wt=$(jq -er '.[0].controller_route.worktree' <<<"$pending")
  bash "$test_plugin/maintain-leases.sh" acquire --repo-root "$fresh_repo" \
    --mode "$legacy_mode" --run-id fresh-legacy --state-file "$fresh_legacy_state" \
    --worktree "$legacy_wt" >/dev/null
  bash "$test_plugin/maintain-attempt.sh" reset --repo-root "$fresh_repo" \
    --worktree "$legacy_wt" --base-sha "$fresh_receipt_head" --lease-state "$fresh_legacy_state" \
    --run-id "$fresh_controller" --controller-run-id fresh-legacy >/dev/null 2>&1
  legacy_recovery_delivery=run-66666666666666666666666666666666
  ec=0
  bash "$delivery_impl" begin --repo-root "$legacy_wt" --issue 2 --run-id fresh-legacy \
    --delivery-id "$legacy_recovery_delivery" --merge-budget 1 --scope-json "$fresh_scope" \
    --lease-state "$fresh_legacy_state" --controller-run-id fresh-legacy \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0n2: legacy recovery controller cannot begin new delivery work" "$ec" 3
  assert_file_not_exists "MD0n3: rejected legacy begin creates no second receipt" \
    "$fresh_state_root/issue-2/current.json"
  bash "$delivery_impl" plan-pr --repo-root "$legacy_wt" --issue 1 --role normal \
    --branch fresh-issue --base-sha "$fresh_base" --head-sha "$fresh_receipt_head" \
    --lease-state "$fresh_legacy_state" --controller-run-id fresh-legacy >/dev/null
  assert_equals "MD0o: only the historical legacy controller can promote a v1 receipt" \
    "$(bash "$delivery_impl" show --repo-root "$legacy_wt" --issue 1 \
      | jq -r '[.schema_version,.controller.mode,.controller.worktree] | @tsv')" \
    $'2\tmaintain-loop\t'"$legacy_wt"
  assert_equals "MD0p: schema-only legacy promotion preserves the original claim timestamp" \
    "$(bash "$delivery_impl" show --repo-root "$legacy_wt" --issue 1 | jq -r .updated_at)" \
    "$legacy_claimed_at"
  assert_equals "MD0p1: promoted legacy receipt retains its recovery-only route" \
    "$(bash "$delivery_impl" pending --repo-root "$fresh_repo" \
      | jq -r '.[0].controller_route.kind')" legacy-recovery
  assert_equals "MD0q: resumed delivery keeps the origin run merge budget" \
    "$(jq -r .merge_budget "$fresh_ledger")" 1
  assert_file_not_exists "MD0r: resume creates no replacement run ledger" "$fresh_resume_ledger"
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$fresh_legacy_state" \
    --repo-root "$fresh_repo" --worktree "$legacy_wt" --run-id fresh-legacy >/dev/null
  git -C "$fresh_repo" worktree remove --force "$legacy_wt" >/dev/null
  rm -rf "$fresh_repo"

  switch_test_lease "$run"

  ec=0; out=$(bash "$script" match-pr --repo-root "$repo" --issue 1 --role normal --pr-json "$pr_open" 2>&1) || ec=$?
  assert_exit_code "MD1: public marker without a receipt is not authority" "$ec" 1

  legacy_delivery=run-33333333333333333333333333333333
  legacy_base=$(git -C "$repo" rev-parse HEAD)
  bash "$delivery_impl" begin --repo-root "$controller_root" --issue 1 --run-id "$run" \
    --delivery-id "$legacy_delivery" --merge-budget 1 --scope-json "$issue_scope" \
    --lease-state "$lease_state" --controller-run-id "$run" >/dev/null
  legacy_receipt="$common/saas-startup-team/maintain-runtime/deliveries/issue-1/current.json"
  jq 'del(.controller,.event_binding) | .schema_version = 1' "$legacy_receipt" \
    > "$legacy_receipt.tmp"
  mv -- "$legacy_receipt.tmp" "$legacy_receipt"
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$lease_state" \
    --repo-root "$repo" --worktree "$controller_root" --run-id "$lease_run" >/dev/null
  lease_state=""
  legacy_wt="$repo/.worktrees/maintain"
  legacy_state="$common/saas-startup-team/maintain-runtime/$run-legacy-leases.json"
  legacy_cache="$common/saas-startup-team/maintain-runtime/base-checks/$run"
  bash "$test_plugin/maintain-leases.sh" acquire --repo-root "$repo" --mode maintain-loop \
    --run-id "$run" --state-file "$legacy_state" --worktree "$legacy_wt" >/dev/null
  bash "$test_plugin/maintain-attempt.sh" reset --repo-root "$repo" --worktree "$legacy_wt" \
    --base-sha "$legacy_base" --lease-state "$legacy_state" --run-id "$run" \
    --controller-run-id "$run" >/dev/null
  legacy_check_oid=$(git -C "$legacy_wt" rev-parse HEAD:check.sh)
  mkdir -p "$legacy_cache"
  jq -n --arg run_id "$run" --arg base_sha "$legacy_base" --arg check_oid "$legacy_check_oid" \
    --arg checked_at "2026-07-14T10:00:00Z" \
    '{schema_version:1,run_id:$run_id,base_sha:$base_sha,check_rel:"check.sh",check_oid:$check_oid,
      status:"passed",checked_at:$checked_at}' > "$legacy_cache/$legacy_base.json"
  assert_equals "MD1a0: historical v1 receipt remains readable" \
    "$(bash "$delivery_impl" show --repo-root "$repo" --issue 1 | jq -r .schema_version)" 1
  ec=0
  bash "$delivery_impl" archive-claimed --repo-root "$repo" --issue 1 >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD1a: active claimed receipt cleanup is refused" "$ec" 3
  assert_equals "MD1b: refused active cleanup leaves the receipt claimed" \
    "$(bash "$delivery_impl" show --repo-root "$repo" --issue 1 | jq -r .state)" claimed
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$legacy_state" \
    --repo-root "$repo" --worktree "$legacy_wt" --run-id "$run" >/dev/null
  cp -- "$issue_closed" "$fake_issue"
  printf 'uncommitted source state\n' >> "$legacy_wt/app.txt"
  ec=0
  bash "$delivery_impl" archive-claimed --repo-root "$repo" --issue 1 >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD1b1: a dirty legacy worktree blocks claimed-receipt archival" "$ec" 1
  assert_equals "MD1b2: dirty-state refusal leaves the v1 receipt claimed" \
    "$(bash "$delivery_impl" show --repo-root "$repo" --issue 1 \
      | jq -r '[.schema_version,.state] | @tsv')" $'1\tclaimed'
  git -C "$legacy_wt" restore --worktree -- app.txt
  git -C "$legacy_wt" checkout -qb legacy-claimed-source
  ec=0
  bash "$delivery_impl" archive-claimed --repo-root "$repo" --issue 1 >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD1c: a branch-attached worktree makes claimed cleanup ambiguous" "$ec" 1
  assert_equals "MD1d: branch-state refusal leaves the receipt claimed" \
    "$(bash "$delivery_impl" show --repo-root "$repo" --issue 1 | jq -r .state)" claimed
  git -C "$legacy_wt" checkout -q --detach "$legacy_base"
  # Local-only leftover after claim epoch: archive deletes it (human-salvage path).
  bash "$delivery_impl" archive-claimed --repo-root "$repo" --issue 1 >/dev/null
  assert_equals "MD1e: local-only leftover claim branch is deleted and archived" \
    "$(bash "$delivery_impl" show --repo-root "$repo" --issue 1 | jq -r .state)" archived_claim
  assert_equals "MD1f: local-only leftover claim branch is gone after archive" \
    "$(git -C "$repo" show-ref --verify --quiet refs/heads/legacy-claimed-source; echo $?)" 1

  # --- Second generation: remote branch / delivery PR / eligible archive ---
  cp -- "$issue_open" "$fake_issue"
  write_issue_scope "$fake_issue" "$issue_scope"
  switch_test_lease "$run"
  legacy_delivery=run-44444444444444444444444444444444
  bash "$delivery_impl" begin --repo-root "$controller_root" --issue 1 --run-id "$run" \
    --delivery-id "$legacy_delivery" --merge-budget 1 \
    --scope-json "$issue_scope" --lease-state "$lease_state" \
    --controller-run-id "$run" >/dev/null
  legacy_receipt="$common/saas-startup-team/maintain-runtime/deliveries/issue-1/current.json"
  jq 'del(.controller,.event_binding) | .schema_version = 1' "$legacy_receipt" \
    > "$legacy_receipt.tmp"
  mv -- "$legacy_receipt.tmp" "$legacy_receipt"
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$lease_state" \
    --repo-root "$repo" --worktree "$controller_root" --run-id "$lease_run" >/dev/null
  lease_state=""
  bash "$test_plugin/maintain-leases.sh" acquire --repo-root "$repo" --mode maintain-loop \
    --run-id "$run" --state-file "$legacy_state" --worktree "$legacy_wt" >/dev/null
  bash "$test_plugin/maintain-attempt.sh" reset --repo-root "$repo" --worktree "$legacy_wt" \
    --base-sha "$legacy_base" --lease-state "$legacy_state" --run-id "$run" \
    --controller-run-id "$run" >/dev/null
  legacy_check_oid=$(git -C "$legacy_wt" rev-parse HEAD:check.sh)
  mkdir -p "$legacy_cache"
  jq -n --arg run_id "$run" --arg base_sha "$legacy_base" --arg check_oid "$legacy_check_oid" \
    --arg checked_at "2026-07-14T10:00:00Z" \
    '{schema_version:1,run_id:$run_id,base_sha:$base_sha,check_rel:"check.sh",check_oid:$check_oid,
      status:"passed",checked_at:$checked_at}' > "$legacy_cache/$legacy_base.json"
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$legacy_state" \
    --repo-root "$repo" --worktree "$legacy_wt" --run-id "$run" >/dev/null
  cp -- "$issue_closed" "$fake_issue"
  # Ensure worktree is clean detached at validated base before remaining checks.
  git -C "$legacy_wt" checkout -q --detach "$legacy_base"
  jq -n --arg body "Maintain-Loop-Delivery: $legacy_delivery" \
    '[{number:91,state:"MERGED",body:$body}]' > "$fake_prs"
  ec=0
  bash "$delivery_impl" archive-claimed --repo-root "$repo" --issue 1 >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD1g: a delivery-marked PR makes claimed cleanup ambiguous" "$ec" 1
  assert_equals "MD1h: PR ambiguity leaves the receipt claimed" \
    "$(bash "$delivery_impl" show --repo-root "$repo" --issue 1 | jq -r .state)" claimed
  printf '[]\n' > "$fake_prs"
  bash "$delivery_impl" archive-claimed --repo-root "$repo" --issue 1 >/dev/null
  assert_equals "MD1i: eligible legacy claim becomes terminal" \
    "$(bash "$delivery_impl" show --repo-root "$repo" --issue 1 | jq -r .state)" archived_claim
  assert_equals "MD1j: archived legacy claim disappears from pending" \
    "$(bash "$delivery_impl" pending --repo-root "$repo" | jq length)" 0
  cp -- "$issue_open" "$fake_issue"
  switch_test_lease "$run"

  bash "$script" begin --repo-root "$repo" --issue 1 --run-id "$run" --delivery-id "$delivery" \
    --merge-budget 1 --scope-json "$issue_scope" >/dev/null
  pending=$(bash "$script" pending --repo-root "$repo")
  assert_equals "MD2: claimed receipt is pending" "$(jq -r '.[0].state' <<<"$pending")" claimed
  ec=0; out=$(SAAS_PREFLIGHT_MISSING=codex \
    bash "$probe" maintain-loop --root "$repo" --issue 1 2>&1) || ec=$?
  assert_exit_code "MD2b: claimed receipt still requires Codex" "$ec" 4
  ec=0; bash "$delivery_impl" plan-pr --repo-root "$repo" --issue 1 --role normal \
    --branch issue-one --base-sha "$base" --head-sha "$head" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD2c: mutating delivery action requires controller lease state" "$ec" 2
  bash "$script" plan-pr --repo-root "$repo" --issue 1 --role normal --branch issue-one \
    --base-sha "$base" --head-sha "$head" >/dev/null
  duplicate_pr="$repo/pr-duplicate-marker.json"
  jq '.body += "\nMaintain-Loop-Issue: #1"' "$pr_open" > "$duplicate_pr"
  ec=0; bash "$script" match-pr --repo-root "$repo" --issue 1 --role normal --pr-json "$duplicate_pr" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD2a: repeated public marker line is ambiguous" "$ec" 1
  ec=0; bash "$script" match-pr --repo-root "$repo" --issue 1 --role normal --pr-json "$pr_merged" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD3: merged discovery lacks premerge authority" "$ec" 1
  bash "$script" bind-pr --repo-root "$repo" --issue 1 --role normal --pr-json "$pr_open" >/dev/null
  jq '.body += "\nUnreviewed validation claim"' "$pr_open" > "$repo/pr-body-drift.json"
  ec=0; bash "$script" match-pr --repo-root "$repo" --issue 1 --role normal \
    --pr-json "$repo/pr-body-drift.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD3a: PR body drift invalidates the delivery binding" "$ec" 1
  ec=0; bash "$script" match-pr --repo-root "$repo" --issue 1 --role normal --pr-json "$pr_merged" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD4: an open binding still cannot authorize merged resume" "$ec" 1
  printf '%s\n' '{"status":"passed"}' > "$repo/forged-evidence.json"
  ec=0; bash "$script" authorize-merge --repo-root "$repo" --issue 1 --role normal \
    --evidence-json "$repo/forged-evidence.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD4a: caller-authored passed JSON is not an authorization input" "$ec" 2
  ec=0; bash "$script" authorize-merge --repo-root "$repo" --issue 1 --role normal >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD4b: merge authorization requires helper-owned QA and tribunal proofs" "$ec" 1
  cp -- "$test_plugin/ui-touch.sh" "$repo/ui-touch.backup"
  printf '%s\n' '#!/bin/sh' 'printf "%s\\n" ui' > "$test_plugin/ui-touch.sh"
  ec=0; bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal \
    --kind qa --not-applicable >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD4b1: QA N/A delegates UI paths to ui-touch.sh" "$ec" 1
  printf '%s\n' '#!/bin/sh' 'printf "%s\\n" ambiguous' > "$test_plugin/ui-touch.sh"
  ec=0; bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal \
    --kind qa --not-applicable >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD4b2: ambiguous classifier output fails closed" "$ec" 1
  cp -- "$repo/ui-touch.backup" "$test_plugin/ui-touch.sh"
  out=$(bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal --kind qa --not-applicable)
  assert_equals "MD4b3: ordinary non-UI diff keeps helper-owned QA N/A" \
    "$(jq -r .status "$out")" not_applicable
  cat > "$repo/hostile-bash-env.sh" <<'HOSTILE_BASH_ENV'
if [ "${0:-}" = "${MAINTAIN_TEST_TRIBUNAL_COLLECTOR:-}" ]; then
  printf compromised > "${MAINTAIN_TEST_LOADER_MARKER:?}"
  exit 77
fi
HOSTILE_BASH_ENV
  BASH_ENV="$repo/hostile-bash-env.sh" \
    MAINTAIN_TEST_TRIBUNAL_COLLECTOR="$fake_tribunal/scripts/collect-review-evidence.sh" \
    MAINTAIN_TEST_LOADER_MARKER="$repo/tribunal-loader-ran" \
    bash -p "$script" collect-tribunal --repo-root "$repo" --issue 1 --role normal \
      --tribunal-plugin-root "$fake_tribunal" >/dev/null
  assert_file_not_exists "MD4b4: tribunal runner ignores ambient Bash loaders" \
    "$repo/tribunal-loader-ran"
  printf '%s\n' '{"status":"passed"}' > "$repo/narrow-tribunal.json"
  ec=0; bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal --kind tribunal \
    --artifact "$repo/narrow-tribunal.json" --tribunal-plugin-root "$fake_tribunal" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD4c: narrow tribunal pass assertion cannot become authority" "$ec" 1
  ec=0; bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal --kind tribunal \
    --artifact "$repo/narrow-tribunal.json" --provider-evidence "$repo/narrow-tribunal.json" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD4c0: caller-supplied provider evidence is rejected" "$ec" 2
  write_tribunal_evidence 1 11 "$head" issue-one
  bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal --kind tribunal \
    --artifact "$tribunal" --tribunal-plugin-root "$fake_tribunal" >/dev/null
  bash "$script" authorize-merge --repo-root "$repo" --issue 1 --role normal >/dev/null
  bash "$script" authorize-merge --repo-root "$repo" --issue 1 --role normal >/dev/null
  assert_equals "MD4d: repeated authorization revalidates without changing lifecycle state" \
    "$(bash "$script" show --repo-root "$repo" --issue 1 | jq -r .state)" normal_merge_authorized
  ec=0; bash "$script" match-pr --repo-root "$repo" --issue 1 --role normal --pr-json "$pr_merged" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5: authorization alone cannot adopt an externally merged PR" "$ec" 1
  ec=0; MAINTAIN_TEST_GH_BIN= PATH="$fake_bin:/usr/bin:/bin" \
    bash "$script" merge-pr --repo-root "$repo" --issue 1 --role normal \
    --merge-method squash >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5a0: repository-controlled PATH gh cannot authorize a mutation" "$ec" 1
  printf '%s\n' "$base" > "$fake_head"; rm -f "$fake_mutation"
  ec=0; PATH="$fake_bin:$PATH" FAKE_GH_HEAD_FILE="$fake_head" FAKE_GH_MUTATION="$fake_mutation" \
    FAKE_GH_LOG="$fake_log" bash "$script" merge-pr --repo-root "$repo" --issue 1 --role normal \
    --merge-method squash >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5a: changed head rejects the irreversible merge" "$ec" 1
  assert_file_not_exists "MD5b: a head race performs no merge mutation" "$fake_mutation"
  printf '%s\n' "$head" > "$fake_head"
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$lease_state" \
    --repo-root "$repo" --worktree "$controller_root" --run-id "$lease_run" >/dev/null
  ec=0; PATH="$fake_bin:$PATH" FAKE_GH_HEAD_FILE="$fake_head" FAKE_GH_MUTATION="$fake_mutation" \
    FAKE_GH_LOG="$fake_log" bash "$script" merge-pr --repo-root "$repo" --issue 1 --role normal \
    --merge-method squash >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5b1: lost controller lease blocks the merge" "$ec" 3
  assert_file_not_exists "MD5b2: lost lease performs no merge mutation" "$fake_mutation"
  switch_test_lease "$run"
  PATH="$fake_bin:$PATH" FAKE_GH_HEAD_FILE="$fake_head" FAKE_GH_MUTATION="$fake_mutation" \
    FAKE_GH_LOG="$fake_log" bash "$script" merge-pr --repo-root "$repo" --issue 1 --role normal \
    --merge-method squash >/dev/null
  assert_file_contains "MD5c: helper pins the authorized head at merge" "$fake_log" \
    "pr merge 11 --match-head-commit $head --squash"
  ec=0; bash "$script" match-pr --repo-root "$repo" --issue 1 --role normal --pr-json "$pr_merged" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5d: exact merged PR resumes after pinned merge intent" "$ec" 0
  cp -- "$pr_merged" "$fake_pr"; git -C "$repo" push -q --force origin "${merge}:refs/heads/main"
  ec=0; bash "$script" record-merge --repo-root "$repo" --issue 1 --role normal \
    --merge-count 3 --merge-budget 2 >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5d1: caller cannot assert run merge accounting" "$ec" 2
  bash "$script" record-merge --repo-root "$repo" --issue 1 --role normal >/dev/null
  jq -n --arg head "$merge" '{databaseId:1111,headSha:$head,status:"completed",conclusion:"success",
    updatedAt:"2026-07-14T00:00:00Z",name:"Fixture Deploy",workflowName:"Fixture Deploy",event:"push"}' > "$fake_run"
  ec=0; bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal --kind live \
    --command-file /bin/true --deploy-run-id 1111 --live-target-source production >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5d2: arbitrary true executable cannot become a proof producer" "$ec" 1
  ec=0; bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal --kind live \
    --command-file "$bad_command" --deploy-run-id 1111 --live-target-source production >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5e: a command that only prints passed cannot become live authority" "$ec" 1
  jq --arg head "$base" '.headSha=$head' "$fake_run" > "$repo/wrong-run.json"; cp -- "$repo/wrong-run.json" "$fake_run"
  ec=0; bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal --kind live \
    --command-file "$qa_command" --deploy-run-id 1111 --live-target-source production >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5e1: successful run for another SHA cannot authorize live proof" "$ec" 1
  jq --arg head "$merge" '.headSha=$head' "$fake_run" > "$repo/right-run.json"; cp -- "$repo/right-run.json" "$fake_run"
  ec=0; OPENAI_API_KEY=secret SAAS_MAINTAIN_LIVE_PROOF_ENV=OPENAI_API_KEY \
    bash "$script" record-proof --repo-root "$repo" --issue 1 \
    --role normal --kind live --command-file "$authority_command" --deploy-run-id 1111 \
    --live-target-source production >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5e1a: proof allowlist rejects agent credentials" "$ec" 1
  ec=0; bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal --kind live \
    --command-file "$bad_command" --live-command-contract monitor-hook \
    --deploy-run-id 1111 --live-target-source production \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5e2: monitor capture accepts only configured custom_checks" "$ec" 1
  ec=0; out=$(FIXTURE_MONITOR_MODE=finding SAAS_MAINTAIN_LIVE_PROOF_ENV=FIXTURE_MONITOR_MODE \
    bash "$script" record-proof --repo-root "$repo" \
    --issue 1 --role normal --kind live --command-file "$monitor_command" \
    --live-command-contract monitor-hook --deploy-run-id 1111 \
    --live-target-source production 2>&1) || ec=$?
  assert_exit_code "MD5e2b: monitor findings block live proof" "$ec" 1
  assert_output_contains "MD5e2c: rejected findings retain diagnostic count" "$out" \
    "monitor hook reported 1 finding(s)"
  mkdir "$repo/hostile-python"
  cat > "$repo/hostile-python/sitecustomize.py" <<'HOSTILE_PYTHON'
import os
from pathlib import Path

marker = os.environ.get("MAINTAIN_TEST_LOADER_MARKER")
if marker:
    Path(marker).write_text("compromised", encoding="utf-8")
HOSTILE_PYTHON
  live_proof_path=$(FIXTURE_MONITOR_MODE=healthy LEGACY_PROOF_SECRET=secret \
    SAAS_MAINTAIN_QA_PROOF_ENV=LEGACY_PROOF_SECRET \
    SAAS_MAINTAIN_LIVE_PROOF_ENV=FIXTURE_MONITOR_MODE \
    PYTHONPATH="$repo/hostile-python" \
    MAINTAIN_TEST_LOADER_MARKER="$repo/python-loader-ran" \
    bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal --kind live \
      --command-file "$monitor_command" --live-command-contract monitor-hook \
      --deploy-run-id 1111 --live-target-source production)
  assert_file_exists "MD5e2d: tracked legacy directive cannot select an ambient variable" \
    "$live_proof_path"
  assert_file_not_exists "MD5e2a: proof sandbox starts before ambient Python loaders" \
    "$repo/python-loader-ran"
  live_output="$(dirname -- "$live_proof_path")/$(jq -r .output_path "$live_proof_path")"
  assert_equals "MD5e3: helper seals the monitor-hook contract" \
    "$(jq -r .capture.contract "$live_output")" monitor-hook
  assert_equals "MD5e4: successful monitor proof has no findings" \
    "$(jq -r .capture.finding_count "$live_output")" 0
  assert_equals "MD5e5: helper retains only a concrete stdout digest" \
    "$(jq -r '.capture.stdout_digest | length' "$live_output")" 64
  ec=0; bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal --kind live \
    --command-file "$qa_command" --deploy-run-id 1111 --live-target-source production >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5e6: idempotent proof cannot switch producers" "$ec" 1
  ec=0; bash "$script" record-proof --repo-root "$repo" --issue 1 --role normal --kind live \
    --command-file "$monitor_command" --deploy-run-id 1111 --live-target-source production >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5e7: idempotent proof cannot switch command contracts" "$ec" 1
  cp -- "$live_output" "$repo/live-output.backup"; printf 'tamper\n' >> "$live_output"
  ec=0; bash "$script" record-release --repo-root "$repo" --issue 1 --role normal \
    --deploy-run-id 1111 --live-target-source production >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5f: changed helper-owned live output cannot authorize release" "$ec" 1
  cp -- "$repo/live-output.backup" "$live_output"
  ec=0; bash "$script" record-release --repo-root "$repo" --issue 1 --role normal \
    --deploy-run-id 1111 --deploy-sha "$merge" --live-target-source production \
    --live-evidence-digest "$(printf forged | sha256sum | awk '{print $1}')" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5g: caller-authored deploy SHA and digest are not release inputs" "$ec" 2
  bash "$script" record-release --repo-root "$repo" --issue 1 --role normal \
    --deploy-run-id 1111 --live-target-source production >/dev/null
  bash "$script" record-release --repo-root "$repo" --issue 1 --role normal \
    --deploy-run-id 1111 --live-target-source production >/dev/null
  cp -- "$pr_merged" "$fake_pr"; cp -- "$issue_open" "$fake_issue"
  ec=0; bash "$script" close-intent --repo-root "$repo" --issue 1 --pr-json "$pr_merged" \
    --issue-json "$issue_open" --audit-json "$repo/forged-evidence.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5h: caller snapshots and audit assertions are not close authority" "$ec" 2
  jq '.title="Changed scope"' "$issue_open" > "$repo/issue-scope-drift.json"
  cp -- "$repo/issue-scope-drift.json" "$fake_issue"
  ec=0; bash "$script" close-intent --repo-root "$repo" --issue 1 >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD5i: issue scope drift invalidates close authority" "$ec" 1
  cp -- "$issue_open" "$fake_issue"
  bash "$script" close-intent --repo-root "$repo" --issue 1 >/dev/null
  bash "$script" close-intent --repo-root "$repo" --issue 1 >/dev/null
  assert_equals "MD5f: helper binds audit to the exact issue updatedAt" \
    "$(bash "$script" show --repo-root "$repo" --issue 1 | jq -r .close.audit.issue_updated_at)" \
    "2026-07-14T10:01:00Z"
  assert_equals "MD5g: helper owns the canonical issue digest" \
    "$(bash "$script" show --repo-root "$repo" --issue 1 | jq -r '.close.issue_digest | length')" 64
  pending=$(bash "$script" pending --repo-root "$repo")
  assert_equals "MD6: close intent survives the close crash window" "$(jq -r '.[0].state' <<<"$pending")" close_intent
  jq '.number=2 | .title="Premature issue" | .body="Must wait" | .state="OPEN" | .closedAt=null' \
    "$issue_open" > "$repo/premature-issue.json"
  cp -- "$repo/premature-issue.json" "$fake_issue"
  write_issue_scope "$fake_issue" "$issue_scope"
  ec=0; bash "$script" begin --repo-root "$repo" --issue 2 --run-id "$run" \
    --delivery-id run-99999999999999999999999999999999 \
    --merge-budget 1 --scope-json "$issue_scope" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD6c: another issue cannot bypass pending reconciliation" "$ec" 3
  cp -- "$issue_open" "$fake_issue"
  changed_issue="$repo/issue-changed.json"
  jq '.updatedAt="2026-07-14T10:02:00Z" | .comments += [{id:"IC_2",body:"New scope",
    createdAt:"2026-07-14T10:02:00Z",updatedAt:null}]' "$issue_open" > "$changed_issue"
  cp -- "$changed_issue" "$fake_issue"; rm -f "$fake_mutation"
  ec=0; PATH="$fake_bin:$PATH" FAKE_GH_ISSUE_SOURCE="$fake_issue" FAKE_GH_MUTATION="$fake_mutation" \
    FAKE_GH_LOG="$fake_log" FAKE_GH_CLOSED_AT="2099-07-14T10:03:00Z" \
    bash "$script" close-issue --repo-root "$repo" --issue 1 >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD6d: pre-close refetch rejects an intervening issue update" "$ec" 1
  assert_file_not_exists "MD6e: stale issue authority performs no close mutation" "$fake_mutation"
  cp -- "$issue_open" "$fake_issue"; rm -f "$fake_mutation"
  ec=0; PATH="$fake_bin:$PATH" FAKE_GH_ISSUE_SOURCE="$fake_issue" FAKE_GH_MUTATION="$fake_mutation" \
    FAKE_GH_LOG="$fake_log" FAKE_GH_CLOSED_AT="2099-07-14T10:03:00Z" FAKE_GH_DRIFT_SOURCE="$changed_issue" \
    bash "$script" close-issue --repo-root "$repo" --issue 1 >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD6f: post-close refetch rejects content changed inside the close window" "$ec" 1
  assert_equals "MD6g: drift cannot advance the durable receipt" \
    "$(bash "$script" show --repo-root "$repo" --issue 1 | jq -r .state)" close_intent
  cp -- "$issue_open" "$fake_issue"; rm -f "$fake_mutation"
  PATH="$fake_bin:$PATH" FAKE_GH_ISSUE_SOURCE="$fake_issue" FAKE_GH_MUTATION="$fake_mutation" \
    FAKE_GH_LOG="$fake_log" FAKE_GH_CLOSED_AT="2099-07-14T10:03:00Z" \
    bash "$script" close-issue --repo-root "$repo" --issue 1 >/dev/null
  cp -- "$fake_issue" "$issue_closed"
  bash "$script" observe-closed --repo-root "$repo" --issue 1 >/dev/null
  ec=0; out=$(bash "$probe" maintain-loop --root "$repo" --issue 1 --dry-run 2>&1) || ec=$?
  assert_exit_code "MD6a: model-free probe sees closed-but-unfinalized receipt" "$ec" 0
  assert_output_contains "MD6b: probe reports the pending lifecycle state" "$out" \
    'pending receipt: issue #1 (closed_observed)'
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$lease_state" \
    --repo-root "$repo" --worktree "$controller_root" --run-id "$lease_run" >/dev/null
  cat > "$fake_bin/setpriv" <<'FAKE_SETPRIV'
#!/bin/sh
[ "${1:-}" = --pdeathsig ] && [ "$#" -ge 3 ] || exit 2
shift 2
exec "$@"
FAKE_SETPRIV
  chmod +x "$fake_bin/setpriv"
  ec=0; out=$(PATH="$fake_bin:$PATH" SAAS_PREFLIGHT_MISSING=codex \
    bash "$probe" maintain-loop --root "$repo" --issue 1 2>&1) || ec=$?
  assert_exit_code "MD6b1: post-source receipt launches without Codex" "$ec" 0
  assert_output_contains "MD6b2: launchable recovery names its state" "$out" \
    'pending receipt: issue #1 (closed_observed)'
  switch_test_lease "$run"

  result="$repo/result.md"
  bash "$script" render-result --repo-root "$repo" --issue 1 > "$result"
  assert_result_rejected "MD6h: success result requires exact PR head" 1 "$result" omit 'pr_head_sha:'
  assert_result_rejected "MD6i: success result requires default ancestry" 1 "$result" contradict 'default_ancestry:'
  assert_result_rejected "MD6j: success result requires tied checks evidence" 1 "$result" omit 'checks_evidence_id:'
  assert_result_rejected "MD6k: success result requires exact QA reason" 1 "$result" contradict 'qa_reason_code:'
  assert_result_rejected "MD6l: success result requires current-head tribunal proof" 1 "$result" omit 'tribunal_head_sha:'
  assert_result_rejected "MD6m: success result requires merged PR state" 1 "$result" contradict 'pr:merged'
  assert_result_rejected "MD6n: success result requires bounded merge count" 1 "$result" omit 'merge_count:'
  assert_result_rejected "MD6o: success result requires exact deploy head" 1 "$result" contradict 'deploy_head_sha:'
  assert_result_rejected "MD6p: success result requires timestamped live proof" 1 "$result" omit 'live_verified_at:'
  assert_result_rejected "MD6q: success result requires exact close receipt" 1 "$result" contradict 'close_issue_digest:'
  assert_result_rejected "MD6r: success result requires rollback state" 1 "$result" omit 'rollback:not_run'
  ec=0; SAAS_PARENT_RUN_ID=not-canonical bash "$script" show --repo-root "$repo" --issue 1 \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD6s: invalid telemetry parent fails closed" "$ec" 2
  ec=0; SAAS_INVOCATION_COMMAND=unknown bash "$script" show --repo-root "$repo" --issue 1 \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD6t: invalid invocation command fails closed" "$ec" 2
  ec=0
  bash "$script" finalize --repo-root "$repo" --issue 1 --result-source "$result" \
    --profile standard >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD6u: a fresh event binding requires explicit invocation context" "$ec" 2
  ec=0
  SAAS_RUN_ID="$delivery" SAAS_PARENT_RUN_ID="$parent_run" SAAS_INVOCATION_COMMAND=goal-deliver \
    bash "$script" finalize --repo-root "$repo" --issue 1 --result-source "$result" \
      --profile standard >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD6v: fresh event command must name an embedded maintenance root" "$ec" 3
  alternate_parent=run-fedcba9876543210fedcba9876543210
  ec=0
  SAAS_RUN_ID="$delivery" SAAS_PARENT_RUN_ID="$alternate_parent" SAAS_INVOCATION_COMMAND=maintain \
    bash "$script" finalize --repo-root "$repo" --issue 1 --result-source "$result" \
      --profile standard >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD6w: fresh event parent must be the active lease controller" "$ec" 3
  ec=0
  SAAS_RUN_ID=run-44444444444444444444444444444444 \
    SAAS_PARENT_RUN_ID="$parent_run" SAAS_INVOCATION_COMMAND=maintain \
    bash "$script" finalize --repo-root "$repo" --issue 1 --result-source "$result" \
      --profile standard >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD6x: fresh child run must equal the receipt issue-event identity" "$ec" 3
  assert_equals "MD6y: rejected context cannot bind the receipt" \
    "$(bash "$script" show --repo-root "$repo" --issue 1 | jq -r .event_binding)" null
  mv -- "$test_plugin/agent-events.sh" "$test_plugin/agent-events-real.sh"
  cat > "$test_plugin/agent-events.sh" <<'CRASH_AFTER_EVENT'
#!/bin/bash
set -euo pipefail
bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/agent-events-real.sh" "$@"
exit 73
CRASH_AFTER_EVENT
  chmod +x "$test_plugin/agent-events.sh"
  ec=0
  SAAS_RUN_ID="$delivery" SAAS_PARENT_RUN_ID="$parent_run" SAAS_INVOCATION_COMMAND=maintain-loop \
    bash "$script" finalize --repo-root "$repo" --issue 1 --result-source "$result" \
    --profile standard >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD7: post-append crash leaves finalization retryable" "$ec" 1
  assert_equals "MD7a: crash window persists immutable event identity before append" \
    "$(bash "$script" show --repo-root "$repo" --issue 1 \
      | jq -r '[.state,.event_binding.command,.event_binding.parent_run_id,.event_binding.profile] | @tsv')" \
    $'closed_observed\tmaintain-loop\t'"$parent_run"$'\tstandard'
  mv -- "$test_plugin/agent-events-real.sh" "$test_plugin/agent-events.sh"
  SAAS_RUN_ID=run-55555555555555555555555555555555 \
    SAAS_PARENT_RUN_ID="$alternate_parent" SAAS_INVOCATION_COMMAND=maintain \
    bash "$script" finalize --repo-root "$repo" --issue 1 --result-source "$result" \
    --profile mechanical >/dev/null
  events="$repo/.startup/runs/agent-events.jsonl"
  assert_equals "MD7b: crash retry emits one issue outcome" \
    "$(jq -s '[.[]|select(.phase=="issue-outcome" and .outcome=="success")]|length' "$events")" 1
  assert_equals "MD7c: crash retry reuses the persisted parent" \
    "$(jq -sr 'map(select(.phase=="issue-outcome" and .outcome=="success"))[0].parent_run_id' "$events")" \
    "$parent_run"
  assert_equals "MD7d: crash retry reuses the persisted invocation command" \
    "$(jq -sr 'map(select(.phase=="issue-outcome" and .outcome=="success"))[0].command' "$events")" \
    maintain-loop
  assert_equals "MD7d1: crash retry reuses the persisted profile" \
    "$(jq -sr 'map(select(.phase=="issue-outcome" and .outcome=="success"))[0].profile' "$events")" \
    standard
  SAAS_RUN_ID=run-55555555555555555555555555555555 \
    SAAS_PARENT_RUN_ID="$alternate_parent" SAAS_INVOCATION_COMMAND=maintain \
    bash "$script" finalize --repo-root "$repo" --issue 1 --result-source "$result" \
    --profile light >/dev/null
  assert_equals "MD7e: repeated terminal finalization remains exactly once" \
    "$(jq -s '[.[]|select(.phase=="issue-outcome" and .outcome=="success")]|length' "$events")" 1
  assert_equals "MD8: finalized receipt leaves no pending work" \
    "$(bash "$script" pending --repo-root "$repo" | jq length)" 0
  assert_file_exists "MD9: finalization writes the existing run artifact" \
    "$repo/.startup/maintain-loop/runs/$run/issue-1.md"
  ec=0; bash "$script" match-pr --repo-root "$repo" --issue 1 --role normal --pr-json "$pr_merged" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD10: finalized historical PR is not interrupted work" "$ec" 1

  git -C "$repo" push -q origin main
  feature2_base=$(git -C "$repo" rev-parse main)
  git -C "$repo" checkout -qb issue-two main
  printf 'second\n' >> "$repo/app.txt"; git -C "$repo" commit -qam second
  feature2_head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main; git -C "$repo" merge -q --squash issue-two; git -C "$repo" commit -qm 'merge issue two'
  feature2_merge=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -qb not-a-rollback main
  printf 'unrelated\n' > "$repo/unrelated.txt"; git -C "$repo" add unrelated.txt
  git -C "$repo" commit -qm 'not a rollback'
  bad_rollback_head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -qb rollback-two main; git -C "$repo" revert --no-edit "$feature2_merge" >/dev/null
  rollback_head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main; git -C "$repo" merge -q --squash rollback-two; git -C "$repo" commit -qm 'rollback issue two'
  rollback_merge=$(git -C "$repo" rev-parse HEAD)
  jq '.number=2 | .title="Issue two" | .body="Fix the second issue" | .state="OPEN" | .closedAt=null |
    .updatedAt="2026-07-14T12:00:30Z"' "$issue_open" > "$repo/issue-two.json"
  cp -- "$repo/issue-two.json" "$fake_issue"
  write_issue_scope "$fake_issue" "$issue_scope"
  rollback_parent=run-66666666666666666666666666666666
  rollback_delivery=run-77777777777777777777777777777777
  switch_test_lease "$rollback_parent"
  bash "$script" begin --repo-root "$repo" --issue 2 --run-id "$rollback_parent" \
    --delivery-id "$rollback_delivery" \
    --merge-budget 1 --scope-json "$issue_scope" >/dev/null
  bash "$script" plan-pr --repo-root "$repo" --issue 2 --role normal --branch issue-two \
    --base-sha "$feature2_base" --head-sha "$feature2_head" >/dev/null
  jq -n --arg head "$feature2_head" \
    --arg body $'Refs #2\nMaintain-Loop-Issue: #2\nMaintain-Loop-Delivery: run-77777777777777777777777777777777\nMaintain-Loop-Role: normal\nMaintain-Loop-Action: run-77777777777777777777777777777777-normal' \
    '{number:12,state:"OPEN",headRefName:"issue-two",headRefOid:$head,baseRefName:"main",title:"Fix issue two",
      body:$body,mergeCommit:null,files:[{path:"app.txt"}]}' > "$pr_open"
  jq --arg merge "$feature2_merge" '.state="MERGED" | .mergeCommit={oid:$merge}' "$pr_open" > "$pr_merged"
  bash "$script" bind-pr --repo-root "$repo" --issue 2 --role normal --pr-json "$pr_open" >/dev/null
  cp -- "$pr_open" "$fake_pr"; cp -- "$repo/issue-two.json" "$fake_issue"
  write_tribunal_evidence 2 12 "$feature2_head" issue-two
  bash "$script" record-proof --repo-root "$repo" --issue 2 --role normal --kind qa --not-applicable >/dev/null
  bash "$script" collect-tribunal --repo-root "$repo" --issue 2 --role normal \
    --tribunal-plugin-root "$fake_tribunal" >/dev/null
  bash "$script" record-proof --repo-root "$repo" --issue 2 --role normal --kind tribunal \
    --artifact "$tribunal" --tribunal-plugin-root "$fake_tribunal" >/dev/null
  bash "$script" authorize-merge --repo-root "$repo" --issue 2 --role normal >/dev/null
  printf '%s\n' "$feature2_head" > "$fake_head"; rm -f "$fake_mutation"
  PATH="$fake_bin:$PATH" FAKE_GH_HEAD_FILE="$fake_head" FAKE_GH_MUTATION="$fake_mutation" \
    FAKE_GH_LOG="$fake_log" bash "$script" merge-pr --repo-root "$repo" --issue 2 --role normal \
    --merge-method squash >/dev/null
  cp -- "$pr_merged" "$fake_pr"; git -C "$repo" push -q --force origin "${feature2_merge}:refs/heads/main"
  bash "$script" record-merge --repo-root "$repo" --issue 2 --role normal >/dev/null
  ec=0; bash "$script" plan-pr --repo-root "$repo" --issue 2 --role rollback --branch not-a-rollback \
    --base-sha "$feature2_merge" --head-sha "$bad_rollback_head" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD13a: arbitrary corrective commit is not a rollback" "$ec" 1
  bash "$script" plan-pr --repo-root "$repo" --issue 2 --role rollback --branch rollback-two \
    --base-sha "$feature2_merge" --head-sha "$rollback_head" >/dev/null
  bash "$script" plan-pr --repo-root "$repo" --issue 2 --role rollback --branch rollback-two \
    --base-sha "$feature2_merge" --head-sha "$rollback_head" >/dev/null
  rollback_pr_open="$repo/rollback-open.json"; rollback_pr_merged="$repo/rollback-merged.json"
  jq -n --arg head "$rollback_head" \
    --arg body $'Refs #2\nMaintain-Loop-Issue: #2\nMaintain-Loop-Delivery: run-77777777777777777777777777777777\nMaintain-Loop-Role: rollback:1\nMaintain-Loop-Action: run-77777777777777777777777777777777-rollback-1' \
    '{number:13,state:"OPEN",headRefName:"rollback-two",headRefOid:$head,baseRefName:"main",title:"Rollback issue two",
      body:$body,mergeCommit:null,files:[{path:"app.txt"}]}' > "$rollback_pr_open"
  jq --arg merge "$rollback_merge" '.state="MERGED" | .mergeCommit={oid:$merge}' "$rollback_pr_open" > "$rollback_pr_merged"
  bash "$script" bind-pr --repo-root "$repo" --issue 2 --role rollback --pr-json "$rollback_pr_open" >/dev/null
  cp -- "$rollback_pr_open" "$fake_pr"
  write_tribunal_evidence 2 13 "$rollback_head" rollback-two
  bash "$script" record-proof --repo-root "$repo" --issue 2 --role rollback --kind qa --not-applicable >/dev/null
  bash "$script" collect-tribunal --repo-root "$repo" --issue 2 --role rollback \
    --tribunal-plugin-root "$fake_tribunal" >/dev/null
  bash "$script" record-proof --repo-root "$repo" --issue 2 --role rollback --kind tribunal \
    --artifact "$tribunal" --tribunal-plugin-root "$fake_tribunal" >/dev/null
  bash "$script" authorize-merge --repo-root "$repo" --issue 2 --role rollback >/dev/null
  printf '%s\n' "$rollback_head" > "$fake_head"; rm -f "$fake_mutation"
  PATH="$fake_bin:$PATH" FAKE_GH_HEAD_FILE="$fake_head" FAKE_GH_MUTATION="$fake_mutation" \
    FAKE_GH_LOG="$fake_log" bash "$script" merge-pr --repo-root "$repo" --issue 2 --role rollback \
    --merge-method squash >/dev/null
  cp -- "$rollback_pr_merged" "$fake_pr"; git -C "$repo" push -q --force origin "${rollback_merge}:refs/heads/main"
  bash "$script" record-merge --repo-root "$repo" --issue 2 --role rollback >/dev/null
  jq -n --arg head "$rollback_merge" '{databaseId:1313,headSha:$head,status:"completed",conclusion:"success",
    updatedAt:"2026-07-14T00:00:00Z",name:"Fixture Deploy",workflowName:"Fixture Deploy",event:"push"}' > "$fake_run"
  bash "$script" record-proof --repo-root "$repo" --issue 2 --role rollback --kind live \
    --command-file "$qa_command" --deploy-run-id 1313 --live-target-source production >/dev/null
  bash "$script" record-release --repo-root "$repo" --issue 2 --role rollback \
    --deploy-run-id 1313 --live-target-source production >/dev/null
  result="$repo/rollback-result.md"
  bash "$script" render-result --repo-root "$repo" --issue 2 > "$result"
  assert_file_not_contains "MD13b0: rollback canonical result never claims fixed" "$result" 'fixed:'
  assert_file_contains "MD13b1: rollback budget overage is explicit" "$result" 'merge_budget_overage:rollback'
  assert_result_rejected "MD13b: rollback result requires normal PR head" 2 "$result" omit 'pr_head_sha:'
  assert_result_rejected "MD13c: rollback result requires exact rollback head" 2 "$result" contradict 'rollback_pr_head_sha:'
  assert_result_rejected "MD13d: rollback result requires default ancestry" 2 "$result" omit 'default_ancestry:'
  assert_result_rejected "MD13e: rollback result requires tied checks evidence" 2 "$result" contradict 'checks_evidence_id:'
  assert_result_rejected "MD13f: rollback result requires exact QA reason" 2 "$result" omit 'qa_reason_code:'
  assert_result_rejected "MD13g: rollback result requires current tribunal head" 2 "$result" contradict 'tribunal_head_sha:'
  assert_result_rejected "MD13h: rollback result requires merged rollback state" 2 "$result" omit 'rollback_merge:merged'
  assert_result_rejected "MD13i: rollback result requires bounded merge count" 2 "$result" contradict 'merge_count:'
  assert_result_rejected "MD13j: rollback result requires exact deploy head" 2 "$result" omit 'deploy_head_sha:'
  assert_result_rejected "MD13k: rollback result requires timestamped live proof" 2 "$result" contradict 'live_verified_at:'
  assert_result_rejected "MD13l: rollback result requires explicit no-close state" 2 "$result" omit 'ready_to_close:not_run'
  assert_result_rejected "MD13m: rollback result requires rolled-back outcome" 2 "$result" contradict 'rollback:rolled_back'
  SAAS_RUN_ID="$rollback_delivery" SAAS_PARENT_RUN_ID="$rollback_parent" \
    SAAS_INVOCATION_COMMAND=maintain \
    bash "$script" finalize --repo-root "$repo" --issue 2 --result-source "$result" \
      --profile standard >/dev/null
  SAAS_RUN_ID=run-88888888888888888888888888888888 \
    SAAS_PARENT_RUN_ID="$alternate_parent" SAAS_INVOCATION_COMMAND=goal-deliver \
    bash "$script" finalize --repo-root "$repo" --issue 2 --result-source "$result" \
      --profile standard >/dev/null
  assert_equals "MD14: rollback release is terminal" \
    "$(bash "$script" show --repo-root "$repo" --issue 2 | jq -r .state)" finalized_rolled_back
  ec=0; bash "$script" plan-pr --repo-root "$repo" --issue 2 --role rollback --branch rollback-two \
    --base-sha "$feature2_merge" --head-sha "$rollback_head" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD15: terminal delivery cannot create a duplicate rollback" "$ec" 1
  assert_equals "MD16: receipt owns exactly one rollback action" \
    "$(bash "$script" show --repo-root "$repo" --issue 2 | jq '[.rollback]|length')" 1
  assert_equals "MD17: rollback finalization emits one terminal issue outcome" \
    "$(jq -s '[.[]|select(.phase=="issue-outcome" and .outcome=="failure" and .rollback=="rolled_back")]|length' "$events")" 1
  assert_equals "MD17a: rollback finalization binds the active controller parent" \
    "$(jq -sr 'map(select(.phase=="issue-outcome" and .outcome=="failure"))[0].parent_run_id' "$events")" \
    "$rollback_parent"
  assert_equals "MD17b: rollback finalization binds the active controller command" \
    "$(jq -sr 'map(select(.phase=="issue-outcome" and .outcome=="failure"))[0].command' "$events")" maintain

  common=$(git -C "$repo" rev-parse --git-common-dir); case "$common" in /*) : ;; *) common="$repo/$common" ;; esac
  state_root="$common/saas-startup-team/maintain-runtime/deliveries"; victim="$repo/receipt-victim"
  mkdir "$victim"; ln -s "$victim" "$state_root/issue-3"
  jq '.number=3 | .title="Unsafe issue" | .body="Unsafe receipt target" | .state="OPEN" | .closedAt=null' \
    "$issue_open" > "$repo/issue-three.json"
  cp -- "$repo/issue-three.json" "$fake_issue"
  write_issue_scope "$fake_issue" "$issue_scope"
  switch_test_lease unsafe
  ec=0; bash "$script" begin --repo-root "$repo" --issue 3 --run-id unsafe \
    --delivery-id run-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --merge-budget 1 --scope-json "$issue_scope" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD18: symlinked receipt directory fails closed" "$ec" 1
  assert_equals "MD19: unsafe receipt target remains untouched" "$(find "$victim" -mindepth 1 | wc -l | tr -d ' ')" 0
  rm "$state_root/issue-3"

  cp -- "$issue_open" "$fake_issue"
  write_issue_scope "$fake_issue" "$issue_scope"
  switch_test_lease run-md-2
  ec=0; bash "$script" begin --repo-root "$repo" --issue 1 --run-id run-md-2 \
    --delivery-id run-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --merge-budget 1 --scope-json "$issue_scope" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD20: open state alone cannot reopen finalized history" "$ec" 1
  bash "$script" begin --repo-root "$repo" --issue 1 --run-id run-md-2 \
    --delivery-id run-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --merge-budget 1 --scope-json "$issue_scope" \
    --reopen-event-id 901 --reopen-event-at 2099-07-14T10:04:00Z >/dev/null
  assert_equals "MD21: verified reopen starts a new generation" \
    "$(bash "$script" show --repo-root "$repo" --issue 1 | jq -r .generation)" 4
  ec=0; bash "$script" match-pr --repo-root "$repo" --issue 1 --role normal --pr-json "$pr_merged" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD22: prior-generation marker cannot authorize the new delivery" "$ec" 1

  assert_file_contains "MD23: protocol reconciles receipts before queue work" \
    "$protocol" '## Recovery before new work'
  assert_file_contains "MD24: protocol persists premerge authority" \
    "$protocol" 'authorize-merge --role normal'
  assert_file_contains "MD24a: protocol delegates the irreversible merge to the pinned helper" \
    "$protocol" 'gh pr merge --match-head-commit <receipt-head>'
  assert_file_contains "MD24b: protocol gives close helper no stale caller snapshot" \
    "$protocol" 'no snapshot argument'
  assert_file_contains "MD24c: protocol requires helper-owned post-close verification" \
    "$protocol" 'verifies the complete closed revision'
  assert_file_contains "MD24d: protocol requires exact inverse rollback proof" \
    "$protocol" 'exact expected inverse tree of the recorded normal merge'
  assert_file_contains "MD24e: protocol records helper-owned proof before merge" \
    "$protocol" 'record-proof --kind tribunal'
  assert_file_contains "MD24f: merge helper accepts no caller PR snapshot" \
    "$protocol" 'Pass no PR/default snapshot'
  assert_file_contains "MD24g: closed recovery accepts no caller snapshot" \
    "$protocol" '`observe-closed` with no snapshot'
  assert_file_contains "MD25: protocol has rollback-or-stop recovery" \
    "$protocol" 'recovery is rollback-or-stop'
  assert_file_not_contains "MD26: protocol does not prescribe post-merge corrective delivery" \
    "$protocol" 'use a fresh tech-founder for a minimal fix'

  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$lease_state" \
    --repo-root "$repo" --worktree "$controller_root" --run-id "$lease_run" >/dev/null
  unset MAINTAIN_TEST_DELIVERY_IMPL MAINTAIN_TEST_LEASE_STATE
  unset MAINTAIN_TEST_CONTROLLER_ROOT MAINTAIN_TEST_PRIMARY_ROOT
  unset MAINTAIN_TEST_GH_BIN MAINTAIN_TEST_REPO_SLUG
  unset FAKE_GH_PR_SOURCE FAKE_GH_CHECKS_SOURCE FAKE_GH_RUN_SOURCE FAKE_GH_ISSUE_SOURCE
  unset FAKE_GH_HEAD_FILE FAKE_GH_MUTATION FAKE_GH_LOG FAKE_GH_CLOSED_AT FAKE_GH_DRIFT_SOURCE
  rm -rf "$repo"
}

test_maintain_delivery_lifecycle
