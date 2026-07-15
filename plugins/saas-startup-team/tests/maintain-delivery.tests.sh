# Sourced by run-tests.sh — executable maintain-loop delivery lifecycle regressions.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "maintain-delivery.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_maintain_delivery_lifecycle() {
  echo -e "\n${CYAN}Suite MD: maintain-loop delivery receipts${NC}"
  local repo script probe protocol base head merge delivery run pr_open pr_merged issue_open issue_closed
  local result pending events ec out duplicate_pr feature2_base feature2_head feature2_merge
  local rollback_head rollback_merge rollback_pr_open rollback_pr_merged common state_root victim
  local fake_bin fake_head fake_issue fake_mutation fake_log changed_issue bad_rollback_head
  local fake_pr fake_checks fake_run remote qa_command bad_command monitor_command tribunal fake_tribunal
  local live_output live_proof_path test_plugin delivery_impl lease_state lease_run authority_command
  local issue_scope fresh_repo fresh_common fresh_wt fresh_origin_state fresh_resume_state
  local fresh_legacy_state fresh_base fresh_pr_head fresh_scope fresh_drift fresh_receipt_head fresh_ledger
  local fresh_resume_ledger
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
exec bash "${MAINTAIN_TEST_DELIVERY_IMPL:?}" "$action" \
  --lease-state "${MAINTAIN_TEST_LEASE_STATE:?}" "$@"
DELIVERY_WRAPPER
  chmod +x "$script"
  export MAINTAIN_TEST_DELIVERY_IMPL="$delivery_impl"
  probe="$PLUGIN_ROOT/scripts/workflow-probe.sh"
  protocol="$PLUGIN_ROOT/references/workflows/maintain-loop-protocol.md"
  git -C "$repo" branch -m main
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  switch_test_lease() {
    local next_run=$1
    if [ -n "${lease_state:-}" ] && [ -e "$lease_state" ]; then
      bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$lease_state" \
        --run-id "$lease_run" >/dev/null
    fi
    common=$(git -C "$repo" rev-parse --git-common-dir)
    case "$common" in /*) : ;; *) common="$repo/$common" ;; esac
    lease_run=$next_run
    lease_state="$common/saas-startup-team/maintain-runtime/$lease_run-leases.json"
    bash "$test_plugin/maintain-leases.sh" acquire --repo-root "$repo" --mode maintain \
      --run-id "$lease_run" --state-file "$lease_state" >/dev/null
    export MAINTAIN_TEST_LEASE_STATE="$lease_state"
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
      --arg runner_bundle_sha256 89848a71f1d4a57ad071483becfc87b2752735552b930c527e32854e7f617338 \
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
    grep -qF -- "$prefix" "$canonical"
    if [ "$mode" = omit ]; then
      awk -v p="$prefix" 'index($0,p) != 1' "$canonical" > "$bad"
    else
      awk -v p="$prefix" '{if (index($0,p) == 1) print p "contradiction"; else print}' \
        "$canonical" > "$bad"
    fi
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
  chmod +x "$qa_command" "$bad_command" "$authority_command" "$monitor_command"
  printf 'base\n' > "$repo/app.txt"
  git -C "$repo" add app.txt live-proof.sh bad-proof.sh authority-proof.sh .startup/monitor-checks.sh \
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

  run=run-md-1; delivery=delivery-md-1
  pr_open="$repo/pr-open.json"; pr_merged="$repo/pr-merged.json"
  issue_open="$repo/issue-open.json"; issue_closed="$repo/issue-closed.json"
  fake_pr="$repo/fake-gh-pr.json"; fake_checks="$repo/fake-gh-checks.json"; fake_run="$repo/fake-gh-run.json"
  jq -n --arg head "$head" --arg body $'Refs #1\nMaintain-Loop-Issue: #1\nMaintain-Loop-Delivery: delivery-md-1\nMaintain-Loop-Role: normal\nMaintain-Loop-Action: delivery-md-1-normal' \
    '{number:11,state:"OPEN",headRefName:"issue-one",headRefOid:$head,baseRefName:"main",title:"Fix issue one",
      body:$body,mergeCommit:null,files:[{path:"app.txt"}]}' > "$pr_open"
  jq --arg merge "$merge" '.state="MERGED" | .mergeCommit={oid:$merge}' "$pr_open" > "$pr_merged"
  jq -n '{number:1,state:"OPEN",updatedAt:"2026-07-14T10:01:00Z",closedAt:null,
    title:"Issue one",body:"Fix the first issue",labels:[],
    comments:[{id:"IC_1",body:"Acceptance detail",createdAt:"2026-07-14T09:30:00Z",updatedAt:null}]}' > "$issue_open"
  jq --arg at "2099-07-14T10:03:00Z" '.state="CLOSED" | .updatedAt=$at | .closedAt=$at' \
    "$issue_open" > "$issue_closed"
  jq -n '[{name:"unit",bucket:"pass",link:"https://example.invalid/check/11"}]' > "$fake_checks"
  cp -- "$pr_open" "$fake_pr"; cp -- "$issue_open" "$fake_issue"
  write_tribunal_evidence 1 11 "$head" issue-one
  export MAINTAIN_TEST_GH_BIN="$fake_bin/gh" MAINTAIN_TEST_REPO_SLUG=fixture-owner/fixture-repo
  export FAKE_GH_PR_SOURCE="$fake_pr" FAKE_GH_CHECKS_SOURCE="$fake_checks" FAKE_GH_RUN_SOURCE="$fake_run"
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
  fresh_wt="$fresh_repo/.worktrees/maintain-loop"
  fresh_origin_state="$fresh_common/saas-startup-team/maintain-runtime/fresh-order-leases.json"
  fresh_resume_state="$fresh_common/saas-startup-team/maintain-runtime/fresh-resume-leases.json"
  fresh_legacy_state="$fresh_common/saas-startup-team/maintain-runtime/fresh-legacy-leases.json"
  fresh_scope="$fresh_repo/issue-scope.json"
  fresh_drift="$fresh_repo/issue-scope-drift.json"
  fresh_ledger="$fresh_common/saas-startup-team/maintain-runtime/deliveries/run-fresh-order.json"
  fresh_resume_ledger="$fresh_common/saas-startup-team/maintain-runtime/deliveries/run-fresh-resume.json"
  write_issue_scope "$fake_issue" "$fresh_scope"
  pending=$(bash "$delivery_impl" pending --repo-root "$fresh_repo")
  assert_equals "MD0a: fresh pending is readable before the dedicated worktree exists" \
    "$(jq length <<<"$pending")" 0
  bash "$test_plugin/maintain-leases.sh" acquire --repo-root "$fresh_repo" \
    --mode maintain-loop --run-id fresh-order --state-file "$fresh_origin_state" \
    --worktree "$fresh_wt" >/dev/null
  assert_file_not_exists "MD0b: lease acquisition alone does not create the worktree" "$fresh_wt"
  ec=0
  bash "$delivery_impl" begin --repo-root "$fresh_repo" --issue 1 --run-id fresh-order \
    --delivery-id fresh-order-delivery --merge-budget 1 --lease-state "$fresh_origin_state" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0c: begin requires the classified issue scope snapshot" "$ec" 2
  ec=0
  bash "$delivery_impl" begin --repo-root "$fresh_repo" --issue 1 --run-id fresh-order \
    --delivery-id fresh-order-delivery --merge-budget 1 --scope-json "$fresh_scope" \
    --lease-state "$fresh_origin_state" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0d: primary-root begin cannot bypass the dedicated worktree lease" "$ec" 3
  assert_equals "MD0e: rejected primary begin creates no receipt" \
    "$(bash "$delivery_impl" pending --repo-root "$fresh_repo" | jq length)" 0
  bash "$test_plugin/maintain-attempt.sh" reset --repo-root "$fresh_repo" \
    --worktree "$fresh_wt" --base-sha "$fresh_base" --lease-state "$fresh_origin_state" \
    --run-id fresh-order >/dev/null
  assert_equals "MD0f: leased reset creates a clean exact-base worktree" \
    "$(git -C "$fresh_wt" rev-parse HEAD):$(git -C "$fresh_wt" status --porcelain)" \
    "$fresh_base:"
  ec=0
  bash "$delivery_impl" begin --repo-root "$fresh_wt" --issue 1 --run-id fresh-order \
    --delivery-id fresh-order-delivery --merge-budget 1 --scope-json "$fake_issue" \
    --lease-state "$fresh_origin_state" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0g: begin rejects a scope snapshot with extra fields" "$ec" 2
  jq '.title="Issue scope changed during the base gate"' "$fake_issue" > "$fresh_drift"
  cp -- "$fresh_drift" "$fake_issue"
  ec=0
  bash "$delivery_impl" begin --repo-root "$fresh_wt" --issue 1 --run-id fresh-order \
    --delivery-id fresh-order-delivery --merge-budget 1 --scope-json "$fresh_scope" \
    --lease-state "$fresh_origin_state" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0h: begin rejects issue scope drift after classification" "$ec" 1
  assert_equals "MD0i: scope drift creates no receipt" \
    "$(bash "$delivery_impl" pending --repo-root "$fresh_repo" | jq length)" 0
  assert_file_not_exists "MD0j: scope drift creates no origin run ledger" "$fresh_ledger"
  cp -- "$issue_open" "$fake_issue"
  bash "$delivery_impl" begin --repo-root "$fresh_wt" --issue 1 --run-id fresh-order \
    --delivery-id fresh-order-delivery --merge-budget 1 --scope-json "$fresh_scope" \
    --lease-state "$fresh_origin_state" \
    >/dev/null
  assert_equals "MD0k: begin succeeds from the created lease-bound worktree" \
    "$(bash "$delivery_impl" show --repo-root "$fresh_wt" --issue 1 | jq -r .state)" claimed

  printf 'feature\n' > "$fresh_wt/app.txt"
  git -C "$fresh_wt" add app.txt
  git -C "$fresh_wt" commit -qm feature
  fresh_pr_head=$(git -C "$fresh_wt" rev-parse HEAD)
  bash "$delivery_impl" plan-pr --repo-root "$fresh_wt" --issue 1 --role normal \
    --branch fresh-issue --base-sha "$fresh_base" --head-sha "$fresh_pr_head" \
    --lease-state "$fresh_origin_state" >/dev/null
  fresh_receipt_head=$(bash "$delivery_impl" show --repo-root "$fresh_wt" --issue 1 | jq -r .normal.head_sha)
  assert_equals "MD0l: planned receipt binds the exact PR head" "$fresh_receipt_head" "$fresh_pr_head"
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$fresh_origin_state" \
    --run-id fresh-order >/dev/null
  rm -rf "$fresh_wt"
  bash "$test_plugin/maintain-leases.sh" acquire --repo-root "$fresh_repo" \
    --mode maintain-loop --run-id fresh-resume --state-file "$fresh_resume_state" \
    --worktree "$fresh_wt" >/dev/null
  bash "$test_plugin/maintain-attempt.sh" reset --repo-root "$fresh_repo" \
    --worktree "$fresh_wt" --base-sha "$fresh_receipt_head" --lease-state "$fresh_resume_state" \
    --run-id fresh-resume >/dev/null 2>&1
  assert_equals "MD0m: a new run recreates the missing worktree at the receipt PR head" \
    "$(git -C "$fresh_wt" rev-parse HEAD):$(git -C "$fresh_wt" status --porcelain)" \
    "$fresh_receipt_head:"
  bash "$delivery_impl" plan-pr --repo-root "$fresh_wt" --issue 1 --role normal \
    --branch fresh-issue --base-sha "$fresh_base" --head-sha "$fresh_receipt_head" \
    --lease-state "$fresh_resume_state" >/dev/null
  assert_equals "MD0n: the new maintain-loop controller resumes an idempotent mutation" \
    "$(bash "$delivery_impl" show --repo-root "$fresh_wt" --issue 1 | jq -r .origin_run_id)" fresh-order
  assert_equals "MD0o: resumed delivery keeps the origin run merge budget" \
    "$(jq -r .merge_budget "$fresh_ledger")" 1
  assert_file_not_exists "MD0p: resume creates no replacement run ledger" "$fresh_resume_ledger"
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$fresh_resume_state" \
    --run-id fresh-resume >/dev/null
  bash "$test_plugin/maintain-leases.sh" acquire --repo-root "$fresh_repo" \
    --mode maintain --run-id fresh-legacy --state-file "$fresh_legacy_state" >/dev/null
  ec=0
  bash "$delivery_impl" plan-pr --repo-root "$fresh_repo" --issue 1 --role normal \
    --branch fresh-issue --base-sha "$fresh_base" --head-sha "$fresh_receipt_head" \
    --lease-state "$fresh_legacy_state" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD0q: a different-run legacy maintain lease cannot resume the receipt" "$ec" 3
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$fresh_legacy_state" \
    --run-id fresh-legacy >/dev/null
  git -C "$fresh_repo" worktree remove --force "$fresh_wt" >/dev/null
  rm -rf "$fresh_repo"

  switch_test_lease "$run"

  ec=0; out=$(bash "$script" match-pr --repo-root "$repo" --issue 1 --role normal --pr-json "$pr_open" 2>&1) || ec=$?
  assert_exit_code "MD1: public marker without a receipt is not authority" "$ec" 1

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
    --run-id "$lease_run" >/dev/null
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
  ec=0; bash "$script" begin --repo-root "$repo" --issue 2 --run-id "$run" --delivery-id premature-delivery \
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
  assert_output_contains "MD6b: probe reports the pending lifecycle state" "$out" 'pending receipt: closed_observed'
  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$lease_state" \
    --run-id "$lease_run" >/dev/null
  cat > "$fake_bin/setpriv" <<'FAKE_SETPRIV'
#!/bin/sh
[ "${1:-}" = --pdeathsig ] && [ "$#" -ge 3 ] || exit 2
shift 2
exec "$@"
FAKE_SETPRIV
  cat > "$fake_bin/unshare" <<'FAKE_UNSHARE'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = -- ]; then shift; exec "$@"; fi
  shift
done
exit 2
FAKE_UNSHARE
  chmod +x "$fake_bin/setpriv" "$fake_bin/unshare"
  ec=0; out=$(PATH="$fake_bin:$PATH" SAAS_PREFLIGHT_MISSING=codex \
    bash "$probe" maintain-loop --root "$repo" --issue 1 2>&1) || ec=$?
  assert_exit_code "MD6b1: post-source receipt launches without Codex" "$ec" 0
  assert_output_contains "MD6b2: launchable recovery names its state" "$out" 'pending receipt: closed_observed'
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
  bash "$script" finalize --repo-root "$repo" --issue 1 --result-source "$result" --profile standard >/dev/null
  bash "$script" finalize --repo-root "$repo" --issue 1 --result-source "$result" --profile standard >/dev/null
  events="$repo/.startup/runs/agent-events.jsonl"
  assert_equals "MD7: repeated finalization emits one issue outcome" \
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
  switch_test_lease run-md-rb
  bash "$script" begin --repo-root "$repo" --issue 2 --run-id run-md-rb --delivery-id delivery-md-rb \
    --merge-budget 1 --scope-json "$issue_scope" >/dev/null
  bash "$script" plan-pr --repo-root "$repo" --issue 2 --role normal --branch issue-two \
    --base-sha "$feature2_base" --head-sha "$feature2_head" >/dev/null
  jq -n --arg head "$feature2_head" --arg body $'Refs #2\nMaintain-Loop-Issue: #2\nMaintain-Loop-Delivery: delivery-md-rb\nMaintain-Loop-Role: normal\nMaintain-Loop-Action: delivery-md-rb-normal' \
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
  jq -n --arg head "$rollback_head" --arg body $'Refs #2\nMaintain-Loop-Issue: #2\nMaintain-Loop-Delivery: delivery-md-rb\nMaintain-Loop-Role: rollback:1\nMaintain-Loop-Action: delivery-md-rb-rollback-1' \
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
  bash "$script" finalize --repo-root "$repo" --issue 2 --result-source "$result" --profile standard >/dev/null
  bash "$script" finalize --repo-root "$repo" --issue 2 --result-source "$result" --profile standard >/dev/null
  assert_equals "MD14: rollback release is terminal" \
    "$(bash "$script" show --repo-root "$repo" --issue 2 | jq -r .state)" finalized_rolled_back
  ec=0; bash "$script" plan-pr --repo-root "$repo" --issue 2 --role rollback --branch rollback-two \
    --base-sha "$feature2_merge" --head-sha "$rollback_head" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD15: terminal delivery cannot create a duplicate rollback" "$ec" 1
  assert_equals "MD16: receipt owns exactly one rollback action" \
    "$(bash "$script" show --repo-root "$repo" --issue 2 | jq '[.rollback]|length')" 1
  assert_equals "MD17: rollback finalization emits one terminal issue outcome" \
    "$(jq -s '[.[]|select(.phase=="issue-outcome" and .outcome=="failure" and .rollback=="rolled_back")]|length' "$events")" 1

  common=$(git -C "$repo" rev-parse --git-common-dir); case "$common" in /*) : ;; *) common="$repo/$common" ;; esac
  state_root="$common/saas-startup-team/maintain-runtime/deliveries"; victim="$repo/receipt-victim"
  mkdir "$victim"; ln -s "$victim" "$state_root/issue-3"
  jq '.number=3 | .title="Unsafe issue" | .body="Unsafe receipt target" | .state="OPEN" | .closedAt=null' \
    "$issue_open" > "$repo/issue-three.json"
  cp -- "$repo/issue-three.json" "$fake_issue"
  write_issue_scope "$fake_issue" "$issue_scope"
  switch_test_lease unsafe
  ec=0; bash "$script" begin --repo-root "$repo" --issue 3 --run-id unsafe --delivery-id unsafe-delivery \
    --merge-budget 1 --scope-json "$issue_scope" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD18: symlinked receipt directory fails closed" "$ec" 1
  assert_equals "MD19: unsafe receipt target remains untouched" "$(find "$victim" -mindepth 1 | wc -l | tr -d ' ')" 0
  rm "$state_root/issue-3"

  cp -- "$issue_open" "$fake_issue"
  write_issue_scope "$fake_issue" "$issue_scope"
  switch_test_lease run-md-2
  ec=0; bash "$script" begin --repo-root "$repo" --issue 1 --run-id run-md-2 --delivery-id delivery-md-2 \
    --merge-budget 1 --scope-json "$issue_scope" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD20: open state alone cannot reopen finalized history" "$ec" 1
  bash "$script" begin --repo-root "$repo" --issue 1 --run-id run-md-2 --delivery-id delivery-md-2 \
    --merge-budget 1 --scope-json "$issue_scope" \
    --reopen-event-id 901 --reopen-event-at 2099-07-14T10:04:00Z >/dev/null
  assert_equals "MD21: verified reopen starts a new generation" \
    "$(bash "$script" show --repo-root "$repo" --issue 1 | jq -r .generation)" 2
  ec=0; bash "$script" match-pr --repo-root "$repo" --issue 1 --role normal --pr-json "$pr_merged" >/dev/null 2>&1 || ec=$?
  assert_exit_code "MD22: prior-generation marker cannot authorize the new delivery" "$ec" 1

  assert_file_contains "MD23: protocol reconciles receipts before queue work" \
    "$protocol" 'maintain-delivery.sh pending'
  assert_file_contains "MD24: protocol persists premerge authority" \
    "$protocol" 'authorize-merge --role normal'
  assert_file_contains "MD24a: protocol delegates the irreversible merge to the pinned helper" \
    "$protocol" 'gh pr merge --match-head-commit <receipt-head>'
  assert_file_contains "MD24b: protocol gives close helper no stale caller snapshot" \
    "$protocol" 'with no snapshot argument'
  assert_file_contains "MD24c: protocol requires helper-owned post-close verification" \
    "$protocol" 'fetches the full CLOSED'
  assert_file_contains "MD24d: protocol requires exact inverse rollback proof" \
    "$protocol" 'exact expected reverse of the recorded normal merge'
  assert_file_contains "MD24e: protocol records helper-owned proof before merge" \
    "$protocol" 'record-proof --kind tribunal'
  assert_file_contains "MD24f: merge helper accepts no caller PR snapshot" \
    "$protocol" 'pass no PR/default snapshot'
  assert_file_contains "MD24g: closed recovery accepts no caller snapshot" \
    "$protocol" '`observe-closed` with no snapshot'
  assert_file_contains "MD25: protocol has rollback-or-stop recovery" \
    "$protocol" 'recovery is rollback-or-stop'
  assert_file_not_contains "MD26: protocol does not prescribe post-merge corrective delivery" \
    "$protocol" 'use a fresh tech-founder for a minimal fix'

  bash "$test_plugin/maintain-leases.sh" cleanup --state-file "$lease_state" \
    --run-id "$lease_run" >/dev/null
  unset MAINTAIN_TEST_DELIVERY_IMPL MAINTAIN_TEST_LEASE_STATE
  unset MAINTAIN_TEST_GH_BIN MAINTAIN_TEST_REPO_SLUG
  unset FAKE_GH_PR_SOURCE FAKE_GH_CHECKS_SOURCE FAKE_GH_RUN_SOURCE FAKE_GH_ISSUE_SOURCE
  unset FAKE_GH_HEAD_FILE FAKE_GH_MUTATION FAKE_GH_LOG FAKE_GH_CLOSED_AT FAKE_GH_DRIFT_SOURCE
  rm -rf "$repo"
}

test_maintain_delivery_lifecycle
