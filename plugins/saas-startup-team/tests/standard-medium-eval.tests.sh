# Sourced by run-tests.sh: evidence-bound assessment and isolated replay safety.

test_standard_medium_eval() {
  echo -e "\n${CYAN}Suite: controlled standard-medium evaluation${NC}"
  local script="$PLUGIN_ROOT/scripts/standard-medium-eval.sh"
  local wd pairs pairs19 out ec policy_hash first_dir task_hash base first_row source_repo
  local repo bin task calls corpus result

  assert_file_exists "SM1: evaluation helper exists" "$script"
  wd=$(mktemp -d)
  pairs="$wd/pairs.jsonl"
  : > "$pairs"
  policy_hash=$(printf '%s\n' 'codex-sandbox-policy-v2' 'permission-profile=saas-network-off' \
    'network=limited-proxy' 'outbound-domains=none' 'workspace-write=verified' \
    'outside-write=denied' 'local-tcp=denied' \
    | sha256sum | awk '{print $1}')
  source_repo="$wd/source-repo"
  mkdir -p "$source_repo"
  git init -q "$source_repo"
  git -C "$source_repo" config user.email test@example.invalid
  git -C "$source_repo" config user.name Test
  printf 'base\n' > "$source_repo/base.txt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$source_repo/check.sh"
  chmod +x "$source_repo/check.sh"
  git -C "$source_repo" add base.txt check.sh
  git -C "$source_repo" commit -qm base
  base=$(git -C "$source_repo" rev-parse HEAD)

  make_pair() {
    local n="$1" d id review mapping tribunal_result
    local check_hash high_hash medium_hash input_hash high_result medium_result
    n=$((10#$n))
    d="$wd/evidence/$n"
    id=$(printf 'sample-%016x' "$n")
    mkdir -p "$d"
    printf 'Task %d\n' "$n" > "$d/task.md"
    cp "$source_repo/check.sh" "$d/check.sh"
    printf 'alpha %d\n' "$n" > "$source_repo/alpha-$n.txt"
    (cd "$source_repo" && git diff --no-index -- /dev/null "alpha-$n.txt") > "$d/high.diff" || [ "$?" -eq 1 ]
    rm -f "$source_repo/alpha-$n.txt"
    printf 'beta %d\n' "$n" > "$source_repo/beta-$n.txt"
    (cd "$source_repo" && git diff --no-index -- /dev/null "beta-$n.txt") > "$d/medium.diff" || [ "$?" -eq 1 ]
    rm -f "$source_repo/beta-$n.txt"
    task_hash=$(sha256sum "$d/task.md" | awk '{print $1}')
    check_hash=$(sha256sum "$d/check.sh" | awk '{print $1}')
    high_hash=$(sha256sum "$d/high.diff" | awk '{print $1}')
    medium_hash=$(sha256sum "$d/medium.diff" | awk '{print $1}')
    review="$d/review"
    mapping="$d/private/mapping.json"
    bash "$script" blind --sample-id "$id" --base-sha "$base" --task-sha256 "$task_hash" \
      --high-diff "$d/high.diff" --medium-diff "$d/medium.diff" \
      --out-dir "$review" --mapping-out "$mapping" >/dev/null
    input_hash=$(sha256sum "$review/tribunal-input.json" | awk '{print $1}')
    high_result="$d/high-result.json"
    medium_result="$d/medium-result.json"
    tribunal_result="$d/tribunal-result.json"
    jq -n --arg id "$id" --arg base "$base" --arg task "$task_hash" \
      --arg diff "$high_hash" --arg check "$check_hash" --arg policy "$policy_hash" \
      '{schema_version:2,evidence_kind:"delivery-candidate-result",sample_id:$id,candidate:"high",
        profile:"standard",model:"gpt-5.6-sol",effort:"high",base_sha:$base,task_sha256:$task,
        diff_sha256:$diff,check_harness_sha256:$check,worker_exit:0,check_exit:0,duration_ms:100,
        usage:{tokens:100,cost_microunits:null},safety_evidence:{sandbox_policy:"verified",
          sandbox_policy_sha256:$policy,network_access:"blocked",filesystem_scope:"verified",
          sanitized_environment:true,isolated_config:true,primary_state_intact:true,
          base_harness_intact:true,ignore_policy_intact:true},remote_mutation:false,
        production_mutation:false}' > "$high_result"
    jq -n --arg id "$id" --arg base "$base" --arg task "$task_hash" \
      --arg diff "$medium_hash" --arg check "$check_hash" --arg policy "$policy_hash" \
      '{schema_version:2,evidence_kind:"delivery-candidate-result",sample_id:$id,candidate:"medium",
        profile:"standard",model:"gpt-5.6-sol",effort:"medium",base_sha:$base,task_sha256:$task,
        diff_sha256:$diff,check_harness_sha256:$check,worker_exit:0,check_exit:0,duration_ms:110,
        usage:{tokens:70,cost_microunits:null},safety_evidence:{sandbox_policy:"verified",
          sandbox_policy_sha256:$policy,network_access:"blocked",filesystem_scope:"verified",
          sanitized_environment:true,isolated_config:true,primary_state_intact:true,
          base_harness_intact:true,ignore_policy_intact:true},remote_mutation:false,
        production_mutation:false}' > "$medium_result"
    jq -n --arg id "$id" --arg base "$base" --arg task "$task_hash" --arg input "$input_hash" \
      '{schema_version:2,evidence_kind:"blinded-tribunal-result",sample_id:$id,base_sha:$base,
        task_sha256:$task,tribunal_input_sha256:$input,status:"complete",decision:"accept",findings:[]}' \
      > "$tribunal_result"
    jq -cn --arg id "$id" --arg base "$base" --arg task "$task_hash" --arg repo_root "$source_repo" \
      --arg task_file "$d/task.md" --arg check_harness "$d/check.sh" \
      --arg high_result "$high_result" --arg high_diff "$d/high.diff" \
      --arg medium_result "$medium_result" --arg medium_diff "$d/medium.diff" \
      --arg candidate_a "$review/candidate-a.diff" --arg candidate_b "$review/candidate-b.diff" \
      --arg tribunal_input "$review/tribunal-input.json" --arg tribunal_mapping "$mapping" \
      --arg tribunal_result "$tribunal_result" \
      '{schema_version:2,sample_id:$id,base_sha:$base,task_sha256:$task,repo_root:$repo_root,task_file:$task_file,
        check_harness:$check_harness,high_result:$high_result,high_diff:$high_diff,
        medium_result:$medium_result,medium_diff:$medium_diff,candidate_a:$candidate_a,
        candidate_b:$candidate_b,tribunal_input:$tribunal_input,
        tribunal_mapping:$tribunal_mapping,tribunal_result:$tribunal_result}' >> "$pairs"
  }

  local n
  for n in $(seq 1 20); do make_pair "$n"; done
  first_dir="$wd/evidence/1"
  first_row=$(head -n 1 "$pairs")

  pairs19="$wd/pairs-19.jsonl"
  head -n 19 "$pairs" > "$pairs19"
  out="$wd/assessment-19.json"
  ec=0
  bash "$script" assess --pairs "$pairs19" --out "$out" >/dev/null || ec=$?
  assert_exit_code "SM2: fewer than 20 bound pairs is a no-go" "$ec" 20
  assert_json_field "SM3: insufficient corpus reports no-go" "$out" '.decision' "no-go"

  out="$wd/assessment-20.json"
  ec=0
  bash "$script" assess --pairs "$pairs" --out "$out" >/dev/null || ec=$?
  assert_exit_code "SM4: unauthenticated local evidence remains no-go" "$ec" 20
  assert_json_field "SM5: metrics cannot authorize a downgrade" "$out" '.decision' "no-go"
  assert_json_field "SM5a: trusted controller receipts are required" "$out" \
    '.criteria.trusted_controller_receipts' "false"
  assert_json_field "SM6: measured token improvement is retained" "$out" \
    '.metrics.median_economic_improvement' "0.3"
  assert_file_not_contains "SM7: sanitized assessment omits sample identity" "$out" 'sample-'
  assert_file_not_contains "SM7a: sanitized assessment omits repository path" "$out" "$source_repo"

  cp "$pairs" "$wd/duplicate.jsonl"
  printf '%s\n' "$first_row" >> "$wd/duplicate.jsonl"
  ec=0
  bash "$script" assess --pairs "$wd/duplicate.jsonl" --out "$wd/duplicate-out.json" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "SM8: duplicate delivery evidence is rejected" "$ec" 2

  cp "$first_dir/medium.diff" "$wd/original-medium.diff"
  printf 'tampered patch\n' > "$first_dir/medium.diff"
  ec=0
  bash "$script" assess --pairs "$pairs" --out "$wd/tampered-out.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "SM9: changed diff evidence is rejected" "$ec" 2
  cp "$wd/original-medium.diff" "$first_dir/medium.diff"

  jq '.effort="high"' "$first_dir/medium-result.json" > "$first_dir/bad-effort.json"
  jq -c --arg p "$first_dir/bad-effort.json" '.medium_result=$p' <<< "$first_row" \
    > "$wd/bad-effort.jsonl"
  ec=0
  bash "$script" assess --pairs "$wd/bad-effort.jsonl" --out "$wd/bad-effort-out.json" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "SM10: unpinned medium provenance is rejected" "$ec" 2

  jq '.remote_mutation=true' "$first_dir/high-result.json" > "$first_dir/remote-result.json"
  awk -v replacement="$(jq -c --arg p "$first_dir/remote-result.json" '.high_result=$p' <<< "$first_row")" \
    'NR == 1 {print replacement; next} {print}' "$pairs" > "$wd/remote-pairs.jsonl"
  ec=0
  bash "$script" assess --pairs "$wd/remote-pairs.jsonl" --out "$wd/remote-out.json" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "SM10a: recorded remote mutation forces no-go" "$ec" 20
  assert_json_field "SM10b: remote mutation criterion fails" "$wd/remote-out.json" \
    '.criteria.no_remote_or_production_mutation' "false"

  cp "$first_dir/private/mapping.json" "$first_dir/review/exposed-mapping.json"
  chmod 400 "$first_dir/review/exposed-mapping.json"
  jq -c --arg p "$first_dir/review/exposed-mapping.json" '.tribunal_mapping=$p' <<< "$first_row" \
    > "$wd/exposed.jsonl"
  ec=0
  bash "$script" assess --pairs "$wd/exposed.jsonl" --out "$wd/exposed-out.json" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "SM11: reviewer-visible private mapping is rejected" "$ec" 2
  rm -f "$first_dir/review/exposed-mapping.json"

  printf '%s\n' '{"profile":"standard","high_check_pass":true,"medium_check_pass":true}' \
    > "$wd/self-reported.jsonl"
  ec=0
  bash "$script" assess --pairs "$wd/self-reported.jsonl" --out "$wd/self-out.json" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "SM12: self-reported booleans cannot authorize a downgrade" "$ec" 2

  ec=0
  bash "$script" blind --sample-id sample-00000000000000ff \
    --base-sha "$base" --task-sha256 "$task_hash" \
    --high-diff "$first_dir/high.diff" --medium-diff "$first_dir/medium.diff" \
    --out-dir "$wd/contained" --mapping-out "$wd/contained/mapping.json" \
    >/dev/null 2>&1 || ec=$?
  assert_exit_code "SM13: mapping cannot be reviewer-visible" "$ec" 2
  assert_equals "SM14: private mapping has owner-only mode" \
    "$(stat -c %a "$first_dir/private/mapping.json")" "400"
  assert_equals "SM15: reviewer files contain no effort identity" \
    "$(grep -RliE 'high|medium' "$first_dir/review" 2>/dev/null | wc -l | tr -d ' ')" "0"
  assert_file_not_contains "SM15a: persisted mapping contains no source identity" \
    "$first_dir/private/mapping.json" 'source'
  printf 'diff --git a/a b/a\n+Sol/high\n' > "$wd/identified-high.diff"
  ec=0
  bash "$script" blind --sample-id sample-00000000000000fe --base-sha "$base" \
    --task-sha256 "$task_hash" --high-diff "$wd/identified-high.diff" \
    --medium-diff "$first_dir/medium.diff" --out-dir "$wd/identity-review" \
    --mapping-out "$wd/identity-private/mapping.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "SM15b: explicit model or effort identity is rejected" "$ec" 2

  # A fake Codex exercises the replay safety seams without network or a model call.
  repo="$wd/repo"
  bin="$wd/bin"
  mkdir -p "$repo" "$bin"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  printf 'base bytes\n' > "$repo/product.txt"
  printf '.startup/evaluation/\nhidden.txt\n' > "$repo/.gitignore"
  printf '#!/usr/bin/env bash\ntest -f generated.txt\n' > "$repo/check.sh"
  chmod +x "$repo/check.sh"
  git -C "$repo" add product.txt .gitignore check.sh
  git -C "$repo" commit -qm init
  task="$wd/replay-task.md"
  printf 'Create generated.txt.\n' > "$task"
  calls="$wd/replay-calls.log"
  : > "$calls"

  cat > "$bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_CODEX_CALLS:=/dev/null}"
case "${1:-}" in
  exec)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' '--strict-config --disable'
      exit 0
    fi
    ;;
  features)
    [ "${2:-}" = list ] || exit 2
    printf '%s\n' 'apps stable' 'plugins stable' 'hooks stable' 'multi_agent stable'
    exit 0
    ;;
  sandbox)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' '--permission-profile --enable'
      exit 0
    fi
    shift
    command=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --permission-profile|-C) shift 2 ;;
        --enable) [ "${2:-}" = network_proxy ] || exit 2; shift 2 ;;
        -c) shift 2 ;;
        *) command=("$@"); break ;;
      esac
    done
    printf 'sandbox %s\n' "${command[*]}" >> "$FAKE_CODEX_CALLS"
    [ "${#command[@]}" -gt 0 ] || exit 2
    if [ "${command[0]}" = /bin/bash ] && [ "${command[1]:-}" = -c ]; then
      [ "${FAKE_CODEX_MODE:-}" != sandbox_fail ] || exit 96
      : > "${command[4]}"
      printf '%s\n' "${command[7]}"
      exit 0
    fi
    "${command[@]}"
    exit
    ;;
esac

printf 'exec %s\n' "$*" >> "$FAKE_CODEX_CALLS"
[ -z "${AWS_SECRET_ACCESS_KEY:-}" ] || exit 88
root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C) root="$2"; shift 2; continue ;;
  esac
  shift
done
[ -n "$root" ]
printf 'generated\n' > "$root/generated.txt"
case "${FAKE_CODEX_MODE:-}" in
  tamper_check) printf '#!/usr/bin/env bash\nexit 0\n' > "$root/check.sh" ;;
  tamper_ignore) printf 'extra-ignore\n' >> "$root/.gitignore" ;;
  hidden_output) printf 'hidden\n' > "$root/hidden.txt" ;;
esac
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"fake final role message"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":80,"output_tokens":20,"cached_input_tokens":0}}'
SH
  chmod +x "$bin/codex"
  corpus="$repo/.startup/evaluation/standard-medium"

  ec=0
  PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" AWS_SECRET_ACCESS_KEY=must-not-leak \
    bash "$script" replay --repo-root "$repo" --base HEAD --task-file "$task" \
      --sample-id sample-0000000000000101 --corpus-dir "$corpus" >/dev/null || ec=$?
  assert_exit_code "SM16: behaviorally verified isolated replay passes" "$ec" 0
  result="$corpus/samples/sample-0000000000000101/result.json"
  assert_json_field "SM17: replay emits evidence schema 2" "$result" '.schema_version' "2"
  assert_json_field "SM18: replay pins medium effort" "$result" '.effort' "medium"
  assert_json_field "SM19: replay records verified network blocking" "$result" \
    '.safety_evidence.network_access' "blocked"
  assert_file_not_exists "SM20: primary checkout is not edited" "$repo/generated.txt"
  assert_file_contains "SM20b: replay selects the network-off profile" "$calls" \
    'default_permissions="saas-network-off"'
  assert_file_contains "SM21: replay uses a limited network profile" "$calls" \
    'permissions.saas-network-off.network.mode="limited"'
  assert_file_contains "SM21b: replay enables the enforcing network proxy" "$calls" \
    '--enable network_proxy'
  assert_file_contains "SM22: replay ignores user Codex config" "$calls" '--ignore-user-config'
  assert_file_contains "SM22b: replay disables model-backed web search" "$calls" \
    'web_search="disabled"'
  assert_file_contains "SM23: candidate diff captures output" \
    "$corpus/samples/sample-0000000000000101/medium.diff" 'generated.txt'

  : > "$calls"
  ec=0
  PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=sandbox_fail \
    bash "$script" replay --repo-root "$repo" --base HEAD --task-file "$task" \
      --sample-id sample-0000000000000102 --corpus-dir "$corpus" >/dev/null || ec=$?
  assert_exit_code "SM24: unverifiable sandbox fails closed" "$ec" 1
  assert_equals "SM25: unverified sandbox launches no worker" \
    "$(grep -c '^exec ' "$calls" 2>/dev/null || true)" "0"
  assert_json_field "SM26: unknown network safety remains null" \
    "$corpus/samples/sample-0000000000000102/result.json" '.safety_evidence.network_access' "null"

  ec=0
  PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=tamper_check \
    bash "$script" replay --repo-root "$repo" --base HEAD --task-file "$task" \
      --sample-id sample-0000000000000103 --corpus-dir "$corpus" >/dev/null || ec=$?
  assert_exit_code "SM27: worker-modified check harness fails replay" "$ec" 1

  ec=0
  PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=tamper_ignore \
    bash "$script" replay --repo-root "$repo" --base HEAD --task-file "$task" \
      --sample-id sample-0000000000000104 --corpus-dir "$corpus" >/dev/null || ec=$?
  assert_exit_code "SM28: worker-modified ignore policy fails replay" "$ec" 1

  ec=0
  PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=hidden_output \
    bash "$script" replay --repo-root "$repo" --base HEAD --task-file "$task" \
      --sample-id sample-0000000000000105 --corpus-dir "$corpus" >/dev/null || ec=$?
  assert_exit_code "SM29: ignored output remains reviewable and can pass" "$ec" 0
  assert_file_contains "SM30: ignored output is forced into the candidate diff" \
    "$corpus/samples/sample-0000000000000105/medium.diff" 'hidden.txt'
  assert_equals "SM31: primary repository remains clean" "$(git -C "$repo" status --porcelain)" ""

  printf '#!/usr/bin/env bash\ntest -f generated.txt\nprintf "check mutation\\n" >> generated.txt\n' \
    > "$repo/check.sh"
  chmod +x "$repo/check.sh"
  git -C "$repo" add check.sh
  git -C "$repo" commit -qm mutating-check
  ec=0
  PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" \
    bash "$script" replay --repo-root "$repo" --base HEAD --task-file "$task" \
      --sample-id sample-0000000000000106 --corpus-dir "$corpus" >/dev/null || ec=$?
  assert_exit_code "SM32: check-mutated candidate fails replay" "$ec" 1
  assert_file_contains "SM33: tested-tree mismatch is explicit" \
    "$corpus/samples/sample-0000000000000106/check.log" 'checks changed the candidate tree'
  assert_equals "SM34: mutating-check replay leaves primary clean" \
    "$(git -C "$repo" status --porcelain)" ""

  rm -rf "$wd"
}

test_standard_medium_eval
