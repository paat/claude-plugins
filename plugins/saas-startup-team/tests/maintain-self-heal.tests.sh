# Sourced by run-tests.sh — maintain-self-heal autonomy regressions.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "maintain-self-heal.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_maintain_self_heal() {
  echo -e "\n${CYAN}Suite MSH: maintain-self-heal${NC}"
  local repo script ec out foreign branch_sha primary_sha
  script="$PLUGIN_ROOT/scripts/maintain-self-heal.sh"
  assert_file_exists "MSH0: self-heal script exists" "$script"

  repo=$(make_workdir)
  git -C "$repo" config user.email "t@t.t"
  git -C "$repo" config user.name "t"
  printf 'base\n' > "$repo/app.txt"
  git -C "$repo" add app.txt
  git -C "$repo" commit -q -m base
  git -C "$repo" branch -M main
  primary_sha=$(git -C "$repo" rev-parse HEAD)

  # Ready primary with no extras.
  ec=0
  out=$(bash "$script" all --repo-root "$repo" 2>&1) || ec=$?
  assert_exit_code "MSH1: clean primary heals ready" "$ec" 0
  assert_output_contains "MSH1b: ready message" "$out" "ready"

  # Disposable retired maintain worktree is removed.
  mkdir -p "$repo/.worktrees"
  git -C "$repo" worktree add --detach "$repo/.worktrees/maintain" HEAD >/dev/null 2>&1
  ec=0
  out=$(bash "$script" all --repo-root "$repo" 2>&1) || ec=$?
  assert_exit_code "MSH2: disposable maintain worktree removed" "$ec" 0
  assert_file_not_exists "MSH2b: .worktrees/maintain gone" "$repo/.worktrees/maintain"

  # Foreign worktree with no unique commits (same HEAD as main) is removed.
  git -C "$repo" worktree add --detach "$repo/../msh-foreign-merged" HEAD >/dev/null 2>&1 \
    || git -C "$repo" worktree add --detach "$(dirname "$repo")/msh-foreign-merged" HEAD >/dev/null 2>&1
  foreign="$(cd -- "$(dirname "$repo")/msh-foreign-merged" 2>/dev/null && pwd -P || true)"
  if [ -n "$foreign" ] && [ -d "$foreign" ]; then
    ec=0
    out=$(bash "$script" all --repo-root "$repo" 2>&1) || ec=$?
    assert_exit_code "MSH3: merged foreign worktree removed" "$ec" 0
    assert_file_not_exists "MSH3b: merged foreign path gone" "$foreign"
  else
    echo -e "  ${YELLOW}SKIP${NC} MSH3: could not create foreign worktree"
  fi

  # Foreign worktree with unique commits remains residual (no silent data loss).
  git -C "$repo" worktree add -b msh-ahead "$(dirname "$repo")/msh-foreign-ahead" HEAD >/dev/null 2>&1
  foreign="$(cd -- "$(dirname "$repo")/msh-foreign-ahead" && pwd -P)"
  printf 'ahead\n' > "$foreign/app.txt"
  git -C "$foreign" add app.txt
  git -C "$foreign" commit -q -m ahead
  ec=0
  out=$(bash "$script" all --repo-root "$repo" 2>&1) || ec=$?
  assert_exit_code "MSH4: unique-commit foreign worktree is residual" "$ec" 1
  assert_output_contains "MSH4b: residual names foreign-worktree" "$out" "foreign-worktree:"
  assert_file_exists "MSH4c: ahead worktree preserved" "$foreign"

  # Dry-run does not delete the residual tree.
  ec=0
  out=$(bash "$script" worktrees --repo-root "$repo" --dry-run 2>&1) || ec=$?
  assert_exit_code "MSH5: dry-run residual still exits 1" "$ec" 1
  assert_output_contains "MSH5b: dry-run does not claim remove of unique WIP without saying residual" "$out" "residual"
  assert_file_exists "MSH5c: dry-run preserved ahead tree" "$foreign"

  # Cleanup leftover worktrees so make_workdir tmpdir can die cleanly.
  git -C "$repo" worktree remove --force -- "$foreign" >/dev/null 2>&1 || true
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  rm -rf -- "$(dirname "$repo")/msh-foreign-ahead" "$(dirname "$repo")/msh-foreign-merged" 2>/dev/null || true
  rm -rf -- "$repo"
}

test_maintain_self_heal
