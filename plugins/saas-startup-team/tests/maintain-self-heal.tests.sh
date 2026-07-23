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

  # Dirty foreign worktree with no unique commits must not be force-removed.
  git -C "$repo" worktree add --detach "$(dirname "$repo")/msh-foreign-dirty" HEAD >/dev/null 2>&1
  foreign="$(cd -- "$(dirname "$repo")/msh-foreign-dirty" && pwd -P)"
  printf 'dirty-uncommitted\n' > "$foreign/dirty.txt"
  ec=0
  out=$(bash "$script" worktrees --repo-root "$repo" 2>&1) || ec=$?
  assert_exit_code "MSH6: dirty merged worktree remains residual" "$ec" 1
  assert_file_exists "MSH6b: dirty worktree not force-deleted" "$foreign"
  assert_output_contains "MSH6c: refuse dirty remove" "$out" "refuse remove dirty"
  git -C "$repo" worktree remove --force -- "$foreign" >/dev/null 2>&1 || true

  # Cleanup leftover worktrees so make_workdir tmpdir can die cleanly.
  git -C "$repo" worktree remove --force -- "$foreign" >/dev/null 2>&1 || true
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  rm -rf -- "$(dirname "$repo")/msh-foreign-ahead" "$(dirname "$repo")/msh-foreign-merged" \
    "$(dirname "$repo")/msh-foreign-dry" "$(dirname "$repo")/msh-foreign-dirty" 2>/dev/null || true
  rm -rf -- "$repo"
}

test_maintain_self_heal

test_strict_dotenv_parser() {
  echo -e "\n${CYAN}Suite MSH-DOTENV: strict dotenv parser${NC}"
  local dir script
  dir=$(mktemp -d)
  script="$dir/parser.sh"
  python3 - "$PLUGIN_ROOT/scripts/maintain-delivery.sh" "$script" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
chunks = ["#!/usr/bin/env bash\nset -euo pipefail\n"]
for name in ("strict_dotenv_get", "load_named_env_from_dotenv"):
    start = src.find(f"{name}() {{")
    assert start >= 0, name
    i = src.find("{", start)
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                chunks.append(src[start : j + 1] + "\n")
                break
out.write_text("".join(chunks))
PY
  printf 'FOO=bar\nexport BAZ=qux\nEVIL=$(whoami)\nGOOD="ok"\n' > "$dir/.env"
  # shellcheck disable=SC1090
  . "$script"
  assert_equals "DOT1: plain assignment" "$(strict_dotenv_get "$dir/.env" FOO)" "bar"
  assert_equals "DOT2: export assignment" "$(strict_dotenv_get "$dir/.env" BAZ)" "qux"
  assert_equals "DOT3: quoted assignment" "$(strict_dotenv_get "$dir/.env" GOOD)" "ok"
  ec=0; strict_dotenv_get "$dir/.env" EVIL >/dev/null 2>&1 || ec=$?
  assert_exit_code "DOT4: command substitution rejected" "$ec" 1
  ec=0; FOO=; load_named_env_from_dotenv "$dir/.env" FOO || ec=$?
  assert_exit_code "DOT5: load_named exports" "$ec" 0
  assert_equals "DOT6: FOO exported" "${FOO:-}" "bar"
  rm -rf -- "$dir"
}

test_strict_dotenv_parser
