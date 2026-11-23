#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

# ---------------------------------------------------------------------------
# Suite G2: Staged-size / package-store guard (check-staged-size.sh) — issue #90
# ---------------------------------------------------------------------------

test_check_staged_size() {
  echo -e "\n${CYAN}Suite G2: Large-file / package-store commit guard${NC}"
  local script="$PLUGIN_ROOT/scripts/check-staged-size.sh"
  local workdir ec output

  # G1: script exists
  assert_file_exists "G1: check-staged-size.sh exists" "$script"

  # G2: clean small staged tree passes (exit 0)
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  echo "hello" > "$workdir/README.md"
  (cd "$workdir" && git add README.md)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "G2: clean staged tree passes" "$ec" 0
  rm -rf "$workdir"

  # G3: staged node_modules/ is rejected by name (exit 1)
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/node_modules/pkg"; echo "x" > "$workdir/node_modules/pkg/index.js"
  (cd "$workdir" && git add -A node_modules/)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "G3: staged node_modules rejected" "$ec" 1
  assert_output_contains "G3b: names dependency/store path" "$output" "dependency/store"
  rm -rf "$workdir"

  # G4: staged .pnpm-store/ is rejected (the exact issue #90 failure)
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  mkdir -p "$workdir/.pnpm-store/v11/files/0a"; echo "blob" > "$workdir/.pnpm-store/v11/files/0a/x"
  (cd "$workdir" && git add -A .pnpm-store/)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "G4: staged .pnpm-store rejected" "$ec" 1
  rm -rf "$workdir"

  # G5: oversized blob rejected (threshold lowered to 1 MB for the test)
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  head -c 2097152 /dev/zero > "$workdir/big.bin"
  (cd "$workdir" && git add big.bin)
  ec=0; output=$(cd "$workdir" && STARTUP_MAX_STAGED_MB=1 bash "$script" 2>&1) || ec=$?
  assert_exit_code "G5: oversized blob rejected" "$ec" 1
  assert_output_contains "G5b: names the size limit" "$output" "limit"
  rm -rf "$workdir"

  # G6: same blob passes when the limit is raised above its size (override works)
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  head -c 2097152 /dev/zero > "$workdir/big.bin"
  (cd "$workdir" && git add big.bin)
  ec=0; output=$(cd "$workdir" && STARTUP_MAX_STAGED_MB=5 bash "$script" 2>&1) || ec=$?
  assert_exit_code "G6: oversized blob passes under raised limit" "$ec" 0
  rm -rf "$workdir"

  # G7: outside a git repo it is a silent no-op (exit 0)
  workdir=$(mktemp -d)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "G7: non-git dir is a no-op" "$ec" 0
  rm -rf "$workdir"

  # G8: /bootstrap gitignores dependency trees and package stores (issue #90 primary fix).
  # The ignore rules live in templates/gitignore-block.txt, applied by bootstrap.md.
  local bootstrap="$PLUGIN_ROOT/skills/bootstrap/SKILL.md"
  local gitignore_block="$PLUGIN_ROOT/templates/gitignore-block.txt"
  assert_file_contains "G8-ref: bootstrap applies the gitignore block" "$bootstrap" "templates/gitignore-block.txt"
  assert_file_contains "G8a: gitignore block has node_modules/" "$gitignore_block" "node_modules/"
  assert_file_contains "G8b: gitignore block has .pnpm-store/" "$gitignore_block" ".pnpm-store/"
  assert_file_contains "G8c: gitignore block has build output (dist/)" "$gitignore_block" "dist/"

  # G9: the guard is wired into the bootstrap commit and the /improve catch-all commit
  assert_file_contains "G9a: bootstrap runs the guard before commit" "$bootstrap" "check-staged-size.sh"
  assert_file_contains "G9b: improve uses supervisor commit guard" "$PLUGIN_ROOT/references/delivery-playbook.md" "supervisor-commit.sh"
  assert_file_contains "G9c: tweak uses trapped commit guard" "$PLUGIN_ROOT/references/delivery-playbook.md" "tweak-run.sh"

  # G10: measures the STAGED blob, not the working tree — stage a big blob, then truncate the
  # working-tree copy. The commit would still carry the big blob, so the guard must still reject.
  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  head -c 2097152 /dev/zero > "$workdir/big.bin"
  (cd "$workdir" && git add big.bin)
  : > "$workdir/big.bin"   # working tree now 0 bytes; index still holds the 2 MB blob
  ec=0; output=$(cd "$workdir" && STARTUP_MAX_STAGED_MB=1 bash "$script" 2>&1) || ec=$?
  assert_exit_code "G10: sizes the staged blob, not the working tree" "$ec" 1
  rm -rf "$workdir"

  workdir=$(mktemp -d); git init -q "$workdir"
  (cd "$workdir" && git config user.email t@t.t && git config user.name t)
  printf 'candidate\n' > "$workdir/README.md"; git -C "$workdir" add README.md
  fake_bin="$workdir/fake-bin"; mkdir "$fake_bin"; real_git=$(command -v git)
  cat > "$fake_bin/git" <<'SH'
#!/usr/bin/env bash
is_diff=0; is_cached=0; is_names=0; is_z=0
for arg in "$@"; do
  [ "$arg" != diff ] || is_diff=1
  [ "$arg" != --cached ] || is_cached=1
  [ "$arg" != --name-only ] || is_names=1
  [ "$arg" != -z ] || is_z=1
done
if [ "$is_diff$is_cached$is_names$is_z" = 1111 ]; then
  printf 'README.md\0'
  exit 73
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fake_bin/git"
  ec=0; output=$(cd "$workdir" && REAL_GIT="$real_git" PATH="$fake_bin:$PATH" \
    bash "$script" 2>&1) || ec=$?
  assert_exit_code "G11: partial staged inventory fails closed" "$ec" 1
  assert_output_contains "G11a: staged inventory failure is explicit" "$output" \
    'Cannot inspect the staged path inventory'
  assert_file_not_contains "G11b: staged inventory avoids process-substitution status loss" \
    "$script" 'done < <(git diff'
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite L: Tone Enforcement Hook
# ---------------------------------------------------------------------------

test_tone_enforcement_hook() {
  echo -e "\n${CYAN}Suite: enforce-tone removed (#391)${NC}"
  assert_file_not_exists "tone: script removed" "$PLUGIN_ROOT/scripts/enforce-tone.sh"
}

# ---------------------------------------------------------------------------
# Suite M: JSON Validation Hook
# ---------------------------------------------------------------------------

test_json_validation_hook() {
  echo -e "\n${CYAN}Suite M: JSON Validation Hook${NC}"
  local script="$PLUGIN_ROOT/scripts/validate-json.sh"
  local hooks_file="$PLUGIN_ROOT/hooks/hooks.json"

  # M1: dispatch.sh exists
  assert_file_exists "M1: validate-json.sh exists" "$script"

  # M2: dispatch.sh is executable
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -x "$script" ]; then
    echo -e "  ${GREEN}PASS${NC} M2: dispatch.sh is executable"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} M2: dispatch.sh is not executable"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("M2: dispatch.sh is not executable")
  fi

  # M3: hooks.json references dispatch.sh
  local hook_refs
  hook_refs=$(jq -r '.hooks.PostToolUse[].hooks[].command' "$hooks_file" 2>/dev/null)
  assert_output_contains "M3: hooks.json references dispatch.sh" "$hook_refs" "dispatch.sh"

  # M4: Exits 0 for non-JSON file
  local ec=0 output
  output=$(echo '{"tool_input":{"file_path":"/workspace/src/main.py"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M4: exits 0 for non-JSON file" "$ec" 0

  # M5: Exits 0 for valid JSON file
  local workdir
  workdir=$(mktemp -d)
  echo '{"key": "value", "count": 1}' > "$workdir/test.json"
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/test.json"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M5: exits 0 for valid JSON" "$ec" 0
  rm -rf "$workdir"

  # M6: Exits 2 for JSON with trailing comma
  workdir=$(mktemp -d)
  cat > "$workdir/bad.json" <<'EOF'
{
  "key": "value",
  "count": 1,
}
EOF
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/bad.json"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M6: exits 2 for JSON with trailing comma" "$ec" 2
  assert_output_contains "M6b: systemMessage in output" "$output" "systemMessage"
  rm -rf "$workdir"

  # M7: Exits 2 for JSON with missing closing bracket
  workdir=$(mktemp -d)
  echo '{"key": "value"' > "$workdir/unclosed.json"
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"'"$workdir"'/unclosed.json"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M7: exits 2 for unclosed JSON" "$ec" 2
  rm -rf "$workdir"

  # M8: Exits 0 for empty file_path
  ec=0; output=""
  output=$(echo '{"tool_input":{}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M8: exits 0 for empty file_path" "$ec" 0

  # M9: Exits 0 for nonexistent JSON file (file deleted after edit)
  ec=0; output=""
  output=$(echo '{"tool_input":{"file_path":"/tmp/nonexistent-test-12345.json"}}' | bash "$script" 2>&1) || ec=$?
  assert_exit_code "M9: exits 0 for nonexistent file" "$ec" 0
}

# ---------------------------------------------------------------------------
# Suite N: Delegation Enforcement Hook
# ---------------------------------------------------------------------------

test_delegation_enforcement_hook() {
  echo -e "\n${CYAN}Suite: enforce-delegation removed (#391)${NC}"
  assert_file_not_exists "delegation: script removed" "$PLUGIN_ROOT/scripts/enforce-delegation.sh"
}

# ---------------------------------------------------------------------------
# Suite O: Duplicate Handoff Prevention Hook
# ---------------------------------------------------------------------------

test_duplicate_handoff_hook() {
  echo -e "\n${CYAN}Suite: check-duplicate-handoff removed (#391)${NC}"
  assert_file_not_exists "dup: script removed" "$PLUGIN_ROOT/scripts/check-duplicate-handoff.sh"
}

test_handoff_secret_redaction() {
  echo -e "\n${CYAN}Suite: handoff secret redaction removed (#391)${NC}"
  assert_file_not_exists "secrets: script removed" "$PLUGIN_ROOT/scripts/check-handoff-secrets.sh"
  # Pre-write secret block via gate
  ec=0
  printf '%s' '{"tool_input":{"file_path":"x.md","content":"token sk-abcdefghijklmnopqrstuv"}}' \
    | bash "$PLUGIN_ROOT/scripts/gate.sh" pii --hook-stdin --mode secrets >/dev/null 2>&1 || ec=$?
  assert_exit_code "secrets: gate blocks secret token pre-write" "$ec" 2
}


test_compact_state() {
  echo -e "\n${CYAN}Suite P: compact-state.sh removed (#386)${NC}"
  assert_file_not_exists "P1: compact-state.sh removed" "$PLUGIN_ROOT/scripts/compact-state.sh"
}


test_migrate_state() {
  echo -e "\n${CYAN}Suite Q: migrate-state.sh removed (#386)${NC}"
  assert_file_not_exists "Q1: migrate-state.sh removed" "$PLUGIN_ROOT/scripts/migrate-state.sh"
}


# ---------------------------------------------------------------------------
# Suite Q: Handoff Index Hook (index-handoff.sh)
# ---------------------------------------------------------------------------

test_index_handoff_hook() {
  echo -e "\n${CYAN}Suite: index-handoff removed (#391)${NC}"
  assert_file_not_exists "index: script removed" "$PLUGIN_ROOT/scripts/index-handoff.sh"
}

test_enforce_handoff_naming_hook() {
  echo -e "\n${CYAN}Suite R: handoff naming hook removed (#391)${NC}"
  assert_file_not_exists "R1: hooks/dispatch.sh removed" "$PLUGIN_ROOT/scripts/hooks/dispatch.sh"
  assert_file_exists "R2: dispatch.sh present" "$PLUGIN_ROOT/hooks/dispatch.sh"
  assert_file_exists "R3: gate.sh present" "$PLUGIN_ROOT/scripts/gate.sh"
}

# ---------------------------------------------------------------------------
# Suite S: Migrate Handoff Names (migrate-handoff-names.sh)
# ---------------------------------------------------------------------------

test_migrate_handoff_names() {
  echo -e "\n${CYAN}Suite: handoff migration removed (#391)${NC}"
  assert_file_not_exists "migrate: enforce-handoff removed" "$PLUGIN_ROOT/scripts/enforce-handoff-naming.sh"
}


test_check_staged_size
test_tone_enforcement_hook
test_json_validation_hook
test_delegation_enforcement_hook
test_duplicate_handoff_hook
test_handoff_secret_redaction
test_compact_state
test_migrate_state
test_index_handoff_hook
test_enforce_handoff_naming_hook
test_migrate_handoff_names
