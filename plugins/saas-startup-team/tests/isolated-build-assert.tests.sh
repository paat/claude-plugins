# isolated-build-assert conductor/worker boundary (sourced by run-tests.sh).
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "isolated-build-assert.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_isolated_build_assert() {
  echo -e "\n${CYAN}Suite IB: isolated-build-assert conductor boundary${NC}"
  local assert="$PLUGIN_ROOT/scripts/isolated-build-assert.py"
  local repo base ec out receipt

  assert_file_exists "IB0: script exists" "$assert"
  assert_file_contains "IB0b: playbook wires preflight" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" 'isolated-build-assert.py preflight'
  assert_file_contains "IB0c: playbook wires post receipt" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" 'isolated-build-assert.py post'
  assert_file_contains "IB0d: deliver forbids parent product edit" \
    "$PLUGIN_ROOT/skills/deliver/SKILL.md" 'edit product source'
  assert_file_contains "IB0e: epic meta-orchestrator" \
    "$PLUGIN_ROOT/skills/epic/SKILL.md" 'Meta-orchestrator'
  assert_file_contains "IB0f: epic never product edit" \
    "$PLUGIN_ROOT/skills/epic/SKILL.md" 'edit product source, product tests'
  assert_file_contains "IB0g: epic-compose meta-orchestrate" \
    "$PLUGIN_ROOT/skills/epic-compose/SKILL.md" 'meta-orchestrate'
  assert_file_contains "IB0h: invariants conductor" \
    "$PLUGIN_ROOT/docs/legacy/epic-invariants.md" 'Meta-orchestrator ≠ implementer'

  repo=$(mktemp -d)
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  mkdir -p "$repo/backend"
  printf 'ok\n' > "$repo/backend/app.py"
  git -C "$repo" add backend/app.py
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)

  # Clean tree preflight ok
  out=$(cd "$repo" && python3 "$assert" preflight --base "$base")
  assert_equals "IB1: clean preflight ok" "$(jq -r .ok <<<"$out")" "true"

  # Conductor allowlist dirty still ok
  printf 'prompt\n' > "$repo/.codex-cast-1.md"
  printf 'draft\n' > "$repo/.epic-compose-draft.md"
  out=$(cd "$repo" && python3 "$assert" preflight --base "$base")
  assert_equals "IB2: allowlist dirty preflight ok" "$(jq -r .ok <<<"$out")" "true"

  # Product dirty preflight fails
  printf 'dirty\n' > "$repo/backend/app.py"
  ec=0
  out=$(cd "$repo" && python3 "$assert" preflight --base "$base" 2>/dev/null) || ec=$?
  assert_exit_code "IB3: product dirty preflight exit 20" "$ec" 20

  # post without product mutation ok even with a dummy receipt
  git -C "$repo" checkout -- backend/app.py
  receipt=$(mktemp)
  printf '%s\n' '{"mode":"implement","outcome":"success","exit_code":0,"commit_sha":"dead"}' > "$receipt"
  out=$(cd "$repo" && python3 "$assert" post --base "$base" --receipt "$receipt")
  assert_equals "IB4: no product mutation post ok" "$(jq -r .product_dirty <<<"$out")" "false"

  # product mutation without matching receipt fails
  printf 'worker\n' > "$repo/backend/app.py"
  ec=0
  out=$(cd "$repo" && python3 "$assert" post --base "$base" --receipt "$receipt" 2>/dev/null) || ec=$?
  assert_exit_code "IB5: bad commit_sha exit 20" "$ec" 20

  # matching success receipt passes (repo-local cast receipt path is allowlisted)
  jq -cn --arg sha "$base" \
    '{mode:"implement",outcome:"success",exit_code:0,commit_sha:$sha}' > "$receipt"
  printf '%s\n' "$(cat "$receipt")" > "$repo/.codex-cast-1725.json"
  out=$(cd "$repo" && python3 "$assert" post --base "$base" --receipt "$repo/.codex-cast-1725.json")
  assert_equals "IB6: good receipt ok" "$(jq -r .ok <<<"$out")" "true"
  assert_equals "IB7: product dirty true" "$(jq -r .product_dirty <<<"$out")" "true"

  # review-mode receipt rejected
  jq -cn --arg sha "$base" \
    '{mode:"review",outcome:"success",exit_code:0,commit_sha:$sha}' > "$receipt"
  ec=0
  out=$(cd "$repo" && python3 "$assert" post --base "$base" --receipt "$receipt" 2>/dev/null) || ec=$?
  assert_exit_code "IB8: review receipt exit 20" "$ec" 20

  # failed implement rejected
  jq -cn --arg sha "$base" \
    '{mode:"implement",outcome:"failure",exit_code:1,commit_sha:$sha}' > "$receipt"
  ec=0
  out=$(cd "$repo" && python3 "$assert" post --base "$base" --receipt "$receipt" 2>/dev/null) || ec=$?
  assert_exit_code "IB9: failed implement exit 20" "$ec" 20

  rm -f "$receipt"
  rm -rf "$repo"
}

test_isolated_build_assert
