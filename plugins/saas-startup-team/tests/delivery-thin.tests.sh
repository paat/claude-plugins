# Thin delivery and hook-pause regressions.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "delivery-thin.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_delivery_thin() {
  echo -e "\n${CYAN}Suite DT: thin delivery${NC}"
  local pause="$PLUGIN_ROOT/scripts/hooks-paused.sh"
  local commit="$PLUGIN_ROOT/scripts/supervisor-commit.sh"
  local route="$PLUGIN_ROOT/scripts/delivery-route.sh"
  local attempt="$PLUGIN_ROOT/scripts/maintain-attempt.sh"
  local repo base ec out

  ec=0; SAAS_PHASE=implementation bash "$pause" || ec=$?
  assert_exit_code "DT1: implementation phase pauses hooks" "$ec" 0
  ec=0; SAAS_PHASE=qa bash "$pause" || ec=$?
  assert_exit_code "DT2: QA phase pauses hooks" "$ec" 0
  ec=0; SAAS_PHASE= bash "$pause" || ec=$?
  assert_exit_code "DT3: empty phase leaves hooks active" "$ec" 1

  repo=$(make_workdir)
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  printf 'base\n' > "$repo/app.txt"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$repo/check.sh"
  chmod +x "$repo/check.sh"
  git -C "$repo" add app.txt check.sh
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'changed\n' > "$repo/app.txt"
  ec=0
  bash "$commit" --repo-root "$repo" --check ./check.sh --message test >/dev/null 2>&1 || ec=$?
  assert_exit_code "DT4: failed check creates no commit" "$ec" 1
  assert_equals "DT5: failed check leaves HEAD at base" "$(git -C "$repo" rev-parse HEAD)" "$base"

  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/check.sh"
  mkdir -p "$repo/.startup" "$repo/.git/hooks"
  printf 'local\n' > "$repo/.startup/state.json"
  printf '%s\n' '#!/usr/bin/env bash' 'touch .git/hook-ran' > "$repo/.git/hooks/pre-commit"
  chmod +x "$repo/.git/hooks/pre-commit"
  bash "$commit" --repo-root "$repo" --check ./check.sh --message test >/dev/null
  assert_equals "DT6: thin commit has expected parent" "$(git -C "$repo" rev-parse HEAD^)" "$base"
  assert_file_exists "DT7: normal pre-commit hook runs" "$repo/.git/hook-ran"
  out=$(git -C "$repo" show --name-only --format= HEAD)
  assert_output_not_contains "DT8: thin commit excludes startup state" "$out" ".startup"

  printf '.env\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -qm ignore
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'secret-local\n' > "$repo/.env"
  printf 'again\n' > "$repo/app.txt"
  ec=0
  out=$(cd "$repo" && bash "$route" check-diff --base "$base" 2>&1) || ec=$?
  assert_exit_code "DT9: ignored-file change preserves the product diff route" "$ec" 20
  assert_output_not_contains "DT10: ignored path is absent from route reasons" "$out" "ignored"
  out=$(sed -n '/git -C "\$worktree" clean/p' "$attempt")
  assert_output_contains "DT11: reset quotes startup exclusions against caller glob expansion" \
    "$out" "-e '.startup' -e '.startup/**'"

  # Firewall must receive a real staged-diff path (lessons-deliver --firewall DIFF_FILE).
  repo=$(make_workdir)
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  printf 'base\n' > "$repo/app.txt"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/check.sh"
  chmod +x "$repo/check.sh"
  git -C "$repo" add app.txt check.sh
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'changed\n' > "$repo/app.txt"
  fw=$(mktemp)
  cat > "$fw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = --firewall ] || exit 2
[ -f "${2:-}" ] || exit 3
grep -q 'diff --git' "$2" || exit 3
exit 0
EOF
  chmod +x "$fw"
  bash "$commit" --repo-root "$repo" --check ./check.sh --message fw \
    --firewall-script "$fw" >/dev/null
  assert_equals "DT12: firewall path still commits on clean firewall" \
    "$(git -C "$repo" rev-parse HEAD^)" "$base"
  after_fw=$(git -C "$repo" rev-parse HEAD)
  printf 'blocked\n' > "$repo/app.txt"
  cat > "$fw" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
  chmod +x "$fw"
  ec=0
  bash "$commit" --repo-root "$repo" --check ./check.sh --message no \
    --firewall-script "$fw" >/dev/null 2>&1 || ec=$?
  assert_exit_code "DT13: firewall block prevents commit" "$ec" 3
  assert_equals "DT14: firewall block leaves HEAD unchanged" \
    "$(git -C "$repo" rev-parse HEAD)" "$after_fw"
  assert_equals "DT15: no extra commit after firewall block" \
    "$(git -C "$repo" rev-list --count HEAD)" "2"
  rm -f -- "$fw"
  rm -rf "$repo"
}

test_delivery_thin
