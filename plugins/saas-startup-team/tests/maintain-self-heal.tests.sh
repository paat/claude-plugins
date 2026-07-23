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

  # Foreign worktree with unique commits: pin branch on primary, remove worktree.
  git -C "$repo" worktree add -b msh-ahead "$(dirname "$repo")/msh-foreign-ahead" HEAD >/dev/null 2>&1
  foreign="$(cd -- "$(dirname "$repo")/msh-foreign-ahead" && pwd -P)"
  printf 'ahead\n' > "$foreign/app.txt"
  git -C "$foreign" add app.txt
  git -C "$foreign" commit -q -m ahead
  ahead_sha=$(git -C "$foreign" rev-parse HEAD)
  ec=0
  out=$(bash "$script" all --repo-root "$repo" 2>&1) || ec=$?
  assert_exit_code "MSH4: unique-commit foreign worktree expedited" "$ec" 0
  assert_file_not_exists "MSH4b: ahead worktree removed after pin" "$foreign"
  assert_equals "MSH4c: primary branch pins unique commits" \
    "$(git -C "$repo" rev-parse msh-ahead 2>/dev/null || true)" "$ahead_sha"
  if grep -qE 'pinned|fast-forwarded|preserved-on-primary' <<<"$out"; then
    echo -e "  ${GREEN}PASS${NC} MSH4d: heal mentions pin/fast-forward/preserve"
    PASS_COUNT=$((PASS_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} MSH4d: heal log missing pin/fast-forward"
    FAIL_COUNT=$((FAIL_COUNT + 1)); TOTAL_COUNT=$((TOTAL_COUNT + 1))
    FAILURES+=("MSH4d: heal log missing pin/fast-forward")
  fi

  # Dry-run on a fresh unique worktree does not destroy commits without pinning plan.
  git -C "$repo" worktree add -b msh-dry "$(dirname "$repo")/msh-foreign-dry" HEAD >/dev/null 2>&1
  foreign="$(cd -- "$(dirname "$repo")/msh-foreign-dry" && pwd -P)"
  printf 'dry\n' >> "$foreign/app.txt"
  git -C "$foreign" add app.txt
  git -C "$foreign" commit -q -m dry
  ec=0
  out=$(bash "$script" worktrees --repo-root "$repo" --dry-run 2>&1) || ec=$?
  assert_exit_code "MSH5: dry-run unique WIP exits 0 (would preserve)" "$ec" 0
  assert_output_contains "MSH5b: dry-run would pin" "$out" "dry-run: would pin"
  assert_file_exists "MSH5c: dry-run left worktree in place" "$foreign"

  # Cleanup leftover worktrees so make_workdir tmpdir can die cleanly.
  git -C "$repo" worktree remove --force -- "$foreign" >/dev/null 2>&1 || true
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  rm -rf -- "$(dirname "$repo")/msh-foreign-ahead" "$(dirname "$repo")/msh-foreign-merged" \
    "$(dirname "$repo")/msh-foreign-dry" 2>/dev/null || true
  rm -rf -- "$repo"
}

test_maintain_self_heal
