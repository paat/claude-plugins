# Sourced by run-tests.sh: model-free escalation cleanup and restart authority.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "maintain-escalation.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_maintain_escalation() {
  echo -e "\n${CYAN}Suite ME: escalation cleanup authority${NC}"
  local helper="$PLUGIN_ROOT/scripts/maintain-escalation.sh" shipped_helper harness script_dir_q
  local attempt_helper="$PLUGIN_ROOT/scripts/maintain-attempt.sh"
  local leases="$PLUGIN_ROOT/scripts/maintain-leases.sh"
  local repo remote common wt state base branch result_dir receipt_dir receipt
  local legacy_wt legacy_state legacy_result_dir legacy_receipt legacy_branch
  local bin open calls victim out ec mode branch2 receipt2 result2 branch3 result3
  local prompt_dir prompt gate_dir check_oid canonical_remote poison_marker before_calls
  local origin_run controller_run_id child_run_id
  local lease_before lease_after runtime_before runtime_after

  assert_file_exists "ME1: escalation helper exists" "$helper"

  repo=$(mktemp -d); remote=$(mktemp -d)
  origin_run=escalation-run
  controller_run_id=run-66666666666666666666666666666666
  child_run_id=run-77777777777777777777777777777777
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  printf '%s\n' base > "$repo/app.txt"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/check.sh"
  chmod +x "$repo/check.sh"
  git -C "$repo" add app.txt check.sh && git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$remote" init -q --bare
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q -u origin main
  canonical_remote=https://github.com/example/maintain-escalation-fixture.git
  git -C "$repo" config --local "url.$remote.insteadOf" "$canonical_remote"
  git -C "$repo" remote set-url origin "$canonical_remote"
  git -C "$repo" remote set-head origin main

  common=$(git -C "$repo" rev-parse --absolute-git-dir)
  wt="$repo/.worktrees/maintain"
  state="$common/saas-startup-team/maintain-runtime/escalation-run.json"
  bash "$leases" acquire --repo-root "$repo" --mode maintain \
    --run-id "$controller_run_id" --state-file "$state" --worktree "$wt" >/dev/null
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" \
    --base-sha "$base" --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null
  assert_equals "ME1a: escalation fixture uses the exact canonical controller binding" \
    "$(jq -r '(.schema_version|tostring) + ":" + .mode + ":" + .worktree' "$state")" \
    "3:maintain:$wt"

  result_dir="$repo/.startup/maintain-loop/attempt-results/escalation-run"
  receipt_dir="$repo/.startup/maintain-loop/escalations/escalation-run"
  mkdir -p "$result_dir" "$receipt_dir"
  branch=issue/7-escalation-run
  git -C "$wt" switch -q -c "$branch"
  printf '%s\n' candidate > "$wt/app.txt"
  printf '%s\n' untracked > "$wt/untracked.txt"
  git -C "$repo" push -q origin "$branch"
  jq -n --arg run escalation-run --arg base "$base" \
    '{schema_version:1,run_id:$run,attempt:1,status:"escalated",base_sha:$base,
      head_sha:$base,route:{schema_version:1,profile:"deep",
      reasons:["diff_sensitive_surface"],ui_touch:false,sensitive:true,
      requires_product_judgment:false,requires_legal_judgment:false,
      decision:"restart_deep"}}' > "$result_dir/issue-7-attempt-1.json"

  bin=$(mktemp -d); open="$repo/open-pr.json"; calls="$repo/gh-calls"
  shipped_helper=$helper; harness="$bin/maintain-escalation.test.sh"
  script_dir_q=$(printf '%q' "$PLUGIN_ROOT/scripts")
  sed -e "s|^SCRIPT_DIR=.*|SCRIPT_DIR=$script_dir_q|" \
    -e '/^absolute_path_has_no_symlink() {/a\  return 0' \
    -e 's/\[ "$owner" = 0 \]/[ "$owner" = "$(\/usr\/bin\/id -u)" ]/' \
    "$shipped_helper" > "$harness"
  chmod +x "$harness"; helper=$harness
  jq -n --arg branch "$branch" --arg head "$base" \
    '[{number:71,headRefName:$branch,headRefOid:$head,isCrossRepository:false}]' > "$open"
  cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for name in GH_REPO GH_HOST GH_CONFIG_DIR LD_PRELOAD LD_LIBRARY_PATH BASH_ENV ENV; do
  [ "${!name+x}" != x ] || { printf 'poisoned gh environment: %s\n' "$name" >&2; exit 90; }
done
case " $* " in
  *" --repo github.com/example/maintain-escalation-fixture "*) : ;;
  *) printf 'missing canonical repository binding: %s\n' "$*" >&2; exit 91 ;;
esac
printf '%s\n' "$*" >> "$PWD/gh-calls"
case "${1:-} ${2:-}" in
  "repo view") printf '%s\n' main ;;
  "pr list") if [ -e "$PWD/open-pr.json" ]; then cat "$PWD/open-pr.json"; else printf '[]\n'; fi ;;
  "pr close")
    rm -f "$PWD/open-pr.json"
    [ ! -e "$PWD/fail-close" ] || exit 99
    ;;
  *) printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 2 ;;
esac
SH
  chmod 755 "$bin/gh"

  ec=0
  PATH="$bin:$PATH" bash "$helper" cleanup --repo-root "$repo" --worktree "$wt" \
    --lease-state "$state" --run-id "$origin_run" --issue 7 --attempt 1 \
    --base-sha "$base" --branch "$branch" >/dev/null 2>&1 || ec=$?
  assert_exit_code "ME1b: escalation requires an explicit current controller identity" "$ec" 2
  lease_before=$(lease_state_fingerprint "$state")
  runtime_before=$(
    { tar -C "$common/saas-startup-team/maintain-runtime" --sort=name -cf - .
      tar -C "$repo/.startup" --sort=name -cf - maintain-loop; } \
      | sha256sum | awk '{print $1}'
  )
  ec=0
  PATH="$bin:$PATH" bash "$helper" cleanup --repo-root "$repo" --worktree "$wt" \
    --lease-state "$state" --run-id "$origin_run" --controller-run-id wrong-controller \
    --issue 7 --attempt 1 --base-sha "$base" --branch "$branch" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "ME1c: escalation rejects a controller that does not own the lease" "$ec" 1
  assert_file_exists "ME1d: rejected controller cannot close the branch PR" "$open"
  lease_after=$(lease_state_fingerprint "$state")
  runtime_after=$(
    { tar -C "$common/saas-startup-team/maintain-runtime" --sort=name -cf - .
      tar -C "$repo/.startup" --sort=name -cf - maintain-loop; } \
      | sha256sum | awk '{print $1}'
  )
  assert_equals "ME1e: rejected escalation cannot heartbeat another controller's lease" \
    "$lease_after" "$lease_before"
  assert_equals "ME1f: rejected escalation leaves maintenance runtime byte-identical" \
    "$runtime_after" "$runtime_before"

  out=$(PATH="$bin:$PATH" GH_REPO=attacker/wrong GH_HOST=attacker.invalid \
    GH_CONFIG_DIR="$repo/attacker-config" LD_PRELOAD=/nonexistent/escalation-loader.so \
    bash "$helper" cleanup --repo-root "$repo" --worktree "$wt" \
      --lease-state "$state" --run-id "$origin_run" \
      --controller-run-id "$controller_run_id" --issue 7 --attempt 1 \
      --base-sha "$base" --branch "$branch" 2>"$repo/cleanup.err")
  receipt="$receipt_dir/issue-7-attempt-1.json"
  assert_equals "ME2: cleanup writes canonical polarity" \
    "$(jq -c .cleanup "$receipt")" \
    '{"open_pr":false,"remote_branch":false,"head_at_base":true,"worktree_clean":true}'
  assert_equals "ME3: cleanup output is the installed receipt" \
    "$(jq -S . <<<"$out")" "$(jq -S . "$receipt")"
  assert_equals "ME3a: cleanup evidence remains bound to its immutable origin" \
    "$(jq -r .run_id "$receipt")" "$origin_run"
  assert_equals "ME3b: cleanup can run under a different current controller" \
    "$(jq -r .run_id "$state")" "$controller_run_id"
  assert_file_not_exists "ME4: cleanup closes the exact branch PR" "$open"
  assert_equals "ME5: cleanup removes the remote branch" \
    "$(git -C "$repo" ls-remote --heads origin "refs/heads/$branch")" ""
  assert_equals "ME6: cleanup resets exact base and dirt" \
    "$(git -C "$wt" rev-parse HEAD):$(git -C "$wt" status --porcelain=v1 --untracked-files=all)" \
    "$base:"
  ec=0; git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || ec=$?
  assert_exit_code "ME7: cleanup deletes the local attempt branch" "$ec" 1
  mode=$(stat -c '%a' "$receipt")
  assert_equals "ME8: cleanup receipt is private" "$mode" 600
  assert_equals "ME8a: every GitHub call is bound to the canonical origin repository" \
    "$(awk 'index($0,"--repo github.com/example/maintain-escalation-fixture") == 0 { bad=1 } END { print (NR > 0 && !bad ? "true" : "false") }' "$calls")" true

  ec=0
  out=$(PATH="$bin:$PATH" \
    bash "$helper" authorize-restart --repo-root "$repo" --worktree "$wt" \
      --lease-state "$state" --run-id "$origin_run" \
      --controller-run-id "$controller_run_id" --issue 7 --attempt 1 \
      --base-sha "$base" --branch "$branch") || ec=$?
  assert_exit_code "ME9: exact canonical proof authorizes one deep restart" "$ec" 0
  assert_equals "ME10: restart authority returns canonical false/false/true/true" \
    "$(jq -c .cleanup <<<"$out")" \
    '{"open_pr":false,"remote_branch":false,"head_at_base":true,"worktree_clean":true}'

  poison_marker="$repo/repository-gh-ran"
  cat > "$repo/gh" <<SH
#!/usr/bin/env bash
touch $(printf '%q' "$poison_marker")
exit 99
SH
  chmod +x "$repo/gh"; before_calls=$(wc -l < "$calls" | tr -d ' ')
  ec=0
  out=$(PATH="$repo:$PATH" bash "$shipped_helper" authorize-restart \
    --repo-root "$repo" --worktree "$wt" --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" \
    --issue 7 --attempt 1 --base-sha "$base" --branch "$branch" 2>&1) || ec=$?
  assert_exit_code "ME10a: a repository-controlled PATH gh is rejected" "$ec" 1
  assert_output_contains "ME10b: PATH rejection names the trust boundary" "$out" \
    'repository-controlled gh is not trusted'
  assert_file_not_exists "ME10c: rejected PATH gh never executes" "$poison_marker"
  assert_equals "ME10d: rejected PATH gh cannot issue a GitHub call" \
    "$(wc -l < "$calls" | tr -d ' ')" "$before_calls"
  rm -f "$repo/gh"

  cp "$receipt" "$receipt.valid"
  jq '.cleanup.open_pr=true | .cleanup.remote_branch=true' "$receipt.valid" > "$receipt"
  ec=0
  PATH="$bin:$PATH" \
    bash "$helper" authorize-restart --repo-root "$repo" --worktree "$wt" \
      --lease-state "$state" --run-id "$origin_run" \
      --controller-run-id "$controller_run_id" --issue 7 --attempt 1 \
      --base-sha "$base" --branch "$branch" >/dev/null 2>&1 || ec=$?
  assert_exit_code "ME11: inverted cleanup polarity cannot authorize restart" "$ec" 1
  mv -f "$receipt.valid" "$receipt"

  branch2=issue/8-escalation-run
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$wt" \
    --base-sha "$base" --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" >/dev/null
  git -C "$wt" switch -q -c "$branch2"
  printf '%s\n' candidate-2 > "$wt/app.txt"
  git -C "$repo" push -q origin "$branch2"
  result2="$result_dir/issue-8-attempt-1.json"
  jq -n --arg run escalation-run --arg base "$base" \
    '{schema_version:1,run_id:$run,attempt:1,status:"escalated",base_sha:$base,
      head_sha:$base,route:{schema_version:1,profile:"deep",
      reasons:["diff_sensitive_surface"],ui_touch:false,sensitive:true,
      requires_product_judgment:false,requires_legal_judgment:false,
      decision:"restart_deep"}}' > "$result2"
  jq -n --arg branch "$branch2" --arg head "$base" \
    '[{number:81,headRefName:$branch,headRefOid:$head,isCrossRepository:false}]' > "$open"
  receipt2="$receipt_dir/issue-8-attempt-1.json"
  victim="$repo/escalation-victim"; printf '%s\n' unchanged > "$victim"
  ln -s "$victim" "$receipt2"
  ec=0
  PATH="$bin:$PATH" \
    bash "$helper" cleanup --repo-root "$repo" --worktree "$wt" \
      --lease-state "$state" --run-id "$origin_run" \
      --controller-run-id "$controller_run_id" --issue 8 --attempt 1 \
      --base-sha "$base" --branch "$branch2" >/dev/null 2>&1 || ec=$?
  assert_exit_code "ME12: planted escalation receipt symlink fails closed" "$ec" 1
  assert_equals "ME13: symlink target is never overwritten" "$(cat "$victim")" unchanged
  assert_file_exists "ME14: unsafe receipt blocks PR cleanup" "$open"
  assert_equals "ME15: unsafe receipt blocks remote deletion" \
    "$(git -C "$repo" ls-remote --heads origin "refs/heads/$branch2" | awk '{print $1}')" "$base"
  rm -f "$receipt2"

  ec=0
  touch "$repo/fail-close"
  PATH="$bin:$PATH" bash "$helper" cleanup --repo-root "$repo" --worktree "$wt" \
      --lease-state "$state" --run-id "$origin_run" \
      --controller-run-id "$controller_run_id" --issue 8 --attempt 1 \
      --base-sha "$base" --branch "$branch2" >/dev/null 2>&1 || ec=$?
  assert_exit_code "ME16: interrupted PR cleanup fails without a receipt" "$ec" 1
  assert_file_not_exists "ME17: interrupted cleanup cannot publish restart authority" "$receipt2"
  assert_file_not_exists "ME18: simulated close completed before interruption" "$open"
  assert_equals "ME19: interruption preserves the not-yet-cleaned remote branch" \
    "$(git -C "$repo" ls-remote --heads origin "refs/heads/$branch2" | awk '{print $1}')" "$base"

  ec=0
  PATH="$bin:$PATH" \
    bash "$helper" cleanup --repo-root "$repo" --worktree "$wt" \
      --lease-state "$state" --run-id "$origin_run" \
      --controller-run-id "$controller_run_id" --issue 8 --attempt 1 \
      --base-sha "$base" --branch "$branch2" >/dev/null || ec=$?
  assert_exit_code "ME20: retry reconciles a partially completed cleanup" "$ec" 0
  assert_equals "ME21: recovered cleanup publishes canonical authority" \
    "$(jq -c .cleanup "$receipt2")" \
    '{"open_pr":false,"remote_branch":false,"head_at_base":true,"worktree_clean":true}'

  assert_file_contains "ME22: attempt result install uses no-directory atomic replacement" \
    "$attempt_helper" 'mv -T -- "$tmp" "$result"'
  branch3=issue/9-result-leaf
  git -C "$wt" switch -q -c "$branch3"
  prompt_dir="$repo/.startup/maintain-loop/prompts/escalation-run"
  mkdir -p "$prompt_dir"
  prompt="$prompt_dir/issue-9-attempt-1.md"
  printf '%s\n' 'Update the accounting adapter.' > "$prompt"
  check_oid=$(git -C "$repo" rev-parse "$base:check.sh")
  gate_dir="$common/saas-startup-team/maintain-runtime/base-checks/escalation-run"
  mkdir -p "$gate_dir"
  jq -n --arg base "$base" --arg check_oid "$check_oid" \
    '{schema_version:1,run_id:"escalation-run",base_sha:$base,check_rel:"check.sh",
      check_oid:$check_oid,status:"passed"}' > "$gate_dir/$base.json"
  cat > "$bin/codex" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do shift; done
cat >/dev/null
printf '%s\n' 'accounting candidate' > app.txt
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"worker complete"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1,"cached_input_tokens":0}}'
SH
  chmod 755 "$bin/codex"
  result3="$result_dir/issue-9-attempt-1.json"
  mkdir "$result3"
  ec=0
  out=$(PATH="$bin:$PATH" SAAS_INVOCATION_COMMAND=maintain bash "$attempt_helper" deliver \
    --repo-root "$wt" --base-sha "$base" --lease-state "$state" --run-id "$origin_run" \
    --controller-run-id "$controller_run_id" --child-run-id "$child_run_id" \
    --attempt 1 --profile standard --task-file "$prompt" --message test \
    --check ./check.sh --routing-reasons routine --allow app.txt 2>&1) || ec=$?
  assert_exit_code "ME23: directory at attempt-result leaf cannot false-report escalation" "$ec" 1
  assert_equals "ME24: rejected result directory remains a directory" \
    "$([ -d "$result3" ] && [ ! -L "$result3" ] && printf directory || printf unsafe)" directory

  bash "$leases" cleanup --state-file "$state" --repo-root "$repo" --worktree "$wt" \
    --run-id "$controller_run_id" >/dev/null
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true

  legacy_wt="$repo/.worktrees/maintain"
  legacy_state="$common/saas-startup-team/maintain-runtime/legacy-escalation.json"
  bash "$leases" acquire --repo-root "$repo" --mode maintain-loop \
    --run-id legacy-escalation --state-file "$legacy_state" --worktree "$legacy_wt" >/dev/null
  bash "$attempt_helper" reset --repo-root "$repo" --worktree "$legacy_wt" \
    --base-sha "$base" --lease-state "$legacy_state" --run-id legacy-escalation \
    --controller-run-id legacy-escalation >/dev/null
  legacy_result_dir="$repo/.startup/maintain-loop/attempt-results/legacy-escalation"
  mkdir -p "$legacy_result_dir"
  legacy_branch=issue/10-legacy-escalation
  jq -n --arg run legacy-escalation --arg base "$base" \
    '{schema_version:1,run_id:$run,attempt:1,status:"escalated",base_sha:$base,
      head_sha:$base,route:{schema_version:1,profile:"deep",
      reasons:["diff_sensitive_surface"],ui_touch:false,sensitive:true,
      requires_product_judgment:false,requires_legal_judgment:false,
      decision:"restart_deep"}}' > "$legacy_result_dir/issue-10-attempt-1.json"
  rm -f -- "$open"
  ec=0
  out=$(PATH="$bin:$PATH" bash "$helper" cleanup --repo-root "$repo" \
    --worktree "$legacy_wt" --lease-state "$legacy_state" --run-id legacy-escalation \
    --controller-run-id legacy-escalation \
    --issue 10 --attempt 1 --base-sha "$base" --branch "$legacy_branch") || ec=$?
  assert_exit_code "ME25: bounded schema-v2 legacy controller remains accepted" "$ec" 0
  legacy_receipt="$repo/.startup/maintain-loop/escalations/legacy-escalation/issue-10-attempt-1.json"
  assert_equals "ME26: legacy cleanup still proves the canonical cleanup polarity" \
    "$(jq -c .cleanup "$legacy_receipt")" \
    '{"open_pr":false,"remote_branch":false,"head_at_base":true,"worktree_clean":true}'
  ec=0
  PATH="$bin:$PATH" bash "$helper" authorize-restart --repo-root "$repo" \
    --worktree "$legacy_wt" --lease-state "$legacy_state" --run-id legacy-escalation \
    --controller-run-id legacy-escalation \
    --issue 10 --attempt 1 --base-sha "$base" --branch "$legacy_branch" \
    >/dev/null || ec=$?
  assert_exit_code "ME27: legacy cleanup receipt still authorizes its exact adapter run" "$ec" 0
  bash "$leases" cleanup --state-file "$legacy_state" --repo-root "$repo" \
    --worktree "$legacy_wt" --run-id legacy-escalation >/dev/null
  git -C "$repo" worktree remove --force "$legacy_wt" >/dev/null 2>&1 || true
  rm -rf "$repo" "$remote" "$bin"
}

test_maintain_escalation
