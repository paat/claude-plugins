# Sourced by run-tests.sh — maintain-self-heal autonomy regressions.
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "maintain-self-heal.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_maintain_self_heal() {
  echo -e "\n${CYAN}Suite MSH: maintain-self-heal${NC}"
  local repo script ec out foreign primary_sha
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

  # Linked worktrees coexist — never auto-removed (#381).
  mkdir -p "$repo/.worktrees"
  git -C "$repo" worktree add --detach "$repo/.worktrees/maintain" HEAD >/dev/null 2>&1
  ec=0
  out=$(bash "$script" all --repo-root "$repo" 2>&1) || ec=$?
  assert_exit_code "MSH2: linked maintain worktree coexists" "$ec" 0
  assert_file_exists "MSH2b: .worktrees/maintain still present" "$repo/.worktrees/maintain"
  assert_output_contains "MSH2c: reports coexistence" "$out" "coexist"

  git -C "$repo" worktree add --detach "$(dirname "$repo")/msh-foreign-merged" HEAD >/dev/null 2>&1
  foreign="$(cd -- "$(dirname "$repo")/msh-foreign-merged" 2>/dev/null && pwd -P || true)"
  if [ -n "$foreign" ] && [ -d "$foreign" ]; then
    ec=0
    out=$(bash "$script" worktrees --repo-root "$repo" 2>&1) || ec=$?
    assert_exit_code "MSH3: foreign worktree not removed" "$ec" 0
    assert_file_exists "MSH3b: foreign path still present" "$foreign"
    assert_output_contains "MSH3c: automatic removal disabled" "$out" "removal is disabled"
  else
    echo -e "  ${YELLOW}SKIP${NC} MSH3: could not create foreign worktree"
  fi

  # Unique-commit foreign worktree is also left alone.
  git -C "$repo" worktree add -b msh-ahead "$(dirname "$repo")/msh-foreign-ahead" HEAD >/dev/null 2>&1
  foreign="$(cd -- "$(dirname "$repo")/msh-foreign-ahead" && pwd -P)"
  printf 'ahead\n' > "$foreign/app.txt"
  git -C "$foreign" add app.txt
  git -C "$foreign" commit -q -m ahead
  ec=0
  out=$(bash "$script" worktrees --repo-root "$repo" 2>&1) || ec=$?
  assert_exit_code "MSH4: unique-commit worktree coexists" "$ec" 0
  assert_file_exists "MSH4b: ahead worktree still present" "$foreign"
  assert_equals "MSH4c: primary HEAD unchanged" \
    "$(git -C "$repo" rev-parse HEAD)" "$primary_sha"

  # Cleanup leftover worktrees so make_workdir tmpdir can die cleanly.
  git -C "$repo" worktree remove --force -- "$repo/.worktrees/maintain" >/dev/null 2>&1 || true
  git -C "$repo" worktree remove --force -- "$(dirname "$repo")/msh-foreign-ahead" >/dev/null 2>&1 || true
  git -C "$repo" worktree remove --force -- "$(dirname "$repo")/msh-foreign-merged" >/dev/null 2>&1 || true
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  rm -rf -- "$(dirname "$repo")/msh-foreign-ahead" "$(dirname "$repo")/msh-foreign-merged" 2>/dev/null || true
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
