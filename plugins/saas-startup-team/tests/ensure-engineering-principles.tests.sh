# Sourced by run-tests.sh — ensure-engineering-principles.sh (#329 follow-up).
test_ensure_engineering_principles() {
  echo -e "\n${CYAN}Suite: ensure-engineering-principles.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/ensure-engineering-principles.sh"
  local wd ec out

  assert_file_exists "EP0: script exists" "$script"

  # EP1: empty root → creates CLAUDE.md + AGENTS.md symlink with all three principles
  wd="$(make_workdir)"
  ec=0
  out=$(bash "$script" --root "$wd" --plugin-root "$PLUGIN_ROOT" 2>&1) || ec=$?
  assert_exit_code "EP1: fresh install exit 0" "$ec" 0
  assert_file_exists "EP1b: CLAUDE.md created" "$wd/CLAUDE.md"
  assert_file_exists "EP1c: AGENTS.md created" "$wd/AGENTS.md"
  assert_file_contains "EP1d: KISS in CLAUDE" "$wd/CLAUDE.md" '**KISS**'
  assert_file_contains "EP1e: YAGNI in CLAUDE" "$wd/CLAUDE.md" '**YAGNI**'
  assert_file_contains "EP1f: DRY in CLAUDE" "$wd/CLAUDE.md" '**DRY**'
  assert_file_contains "EP1g: managed start mark" "$wd/CLAUDE.md" 'saas-startup-team:engineering-principles:start'
  # AGENTS should be symlink to CLAUDE when possible
  if [ -L "$wd/AGENTS.md" ]; then
    assert_equals "EP1h: AGENTS.md is symlink" "1" "1"
  else
    assert_file_contains "EP1h: AGENTS.md has KISS when not symlink" "$wd/AGENTS.md" '**KISS**'
  fi

  # EP2: idempotent — second run does not duplicate managed block
  bash "$script" --root "$wd" --plugin-root "$PLUGIN_ROOT" >/dev/null 2>&1 || true
  local count
  count="$(grep -cF 'saas-startup-team:engineering-principles:start' "$wd/CLAUDE.md" || true)"
  assert_equals "EP2: still one managed start marker" "$count" "1"
  count="$(grep -cF '**KISS**' "$wd/CLAUDE.md" || true)"
  assert_equals "EP2b: still one KISS label" "$count" "1"

  # EP3: incomplete heading (missing DRY) gets a complete managed block appended
  wd="$(make_workdir)"
  printf '# X\n\n## Engineering principles\n\n- **KISS** only\n- **YAGNI** only\n' > "$wd/CLAUDE.md"
  bash "$script" --root "$wd" --plugin-root "$PLUGIN_ROOT" >/dev/null 2>&1 || true
  assert_file_contains "EP3: DRY present after incomplete" "$wd/CLAUDE.md" '**DRY**'
  assert_file_contains "EP3b: managed block installed" "$wd/CLAUDE.md" 'engineering-principles:start'

  # EP4: AGENTS.md regular file (not symlink) gets its own block
  wd="$(make_workdir)"
  printf '# Claude\n' > "$wd/CLAUDE.md"
  printf '# Agents separate\n' > "$wd/AGENTS.md"
  bash "$script" --root "$wd" --plugin-root "$PLUGIN_ROOT" >/dev/null 2>&1 || true
  assert_file_contains "EP4: CLAUDE has principles" "$wd/CLAUDE.md" '**KISS**'
  assert_file_contains "EP4b: AGENTS file has principles" "$wd/AGENTS.md" '**KISS**'
  assert_file_contains "EP4c: AGENTS has YAGNI" "$wd/AGENTS.md" '**YAGNI**'
  assert_file_contains "EP4d: AGENTS has DRY" "$wd/AGENTS.md" '**DRY**'

  # EP5: AGENTS.md → CLAUDE.md symlink; only CLAUDE needs content
  wd="$(make_workdir)"
  printf '# Claude\n' > "$wd/CLAUDE.md"
  ln -s CLAUDE.md "$wd/AGENTS.md"
  bash "$script" --root "$wd" --plugin-root "$PLUGIN_ROOT" >/dev/null 2>&1 || true
  assert_file_contains "EP5: principles on CLAUDE via symlink setup" "$wd/CLAUDE.md" '**DRY**'
  assert_equals "EP5b: AGENTS still symlink" "$(readlink "$wd/AGENTS.md")" "CLAUDE.md"

  # EP6: dangling AGENTS.md symlink is repaired
  wd="$(make_workdir)"
  printf '# Claude\n' > "$wd/CLAUDE.md"
  ln -s missing-target.md "$wd/AGENTS.md"
  bash "$script" --root "$wd" --plugin-root "$PLUGIN_ROOT" >/dev/null 2>&1 || true
  # After repair, AGENTS should exist and principles reachable
  assert_file_exists "EP6: AGENTS exists after repair" "$wd/AGENTS.md"
  if [ -L "$wd/AGENTS.md" ]; then
    assert_equals "EP6b: dangling replaced with CLAUDE link" "$(readlink "$wd/AGENTS.md")" "CLAUDE.md"
  fi
  assert_file_contains "EP6c: CLAUDE has principles" "$wd/CLAUDE.md" '**KISS**'

  # EP7: dry-run creates nothing
  wd="$(make_workdir)"
  ec=0
  bash "$script" --root "$wd" --plugin-root "$PLUGIN_ROOT" --dry-run >/dev/null 2>&1 || ec=$?
  assert_exit_code "EP7: dry-run exit 0" "$ec" 0
  assert_file_not_exists "EP7b: no CLAUDE.md on dry-run" "$wd/CLAUDE.md"

  # EP8: bootstrap/startup/hook point at the shared script
  assert_file_contains "EP8: bootstrap calls helper" \
    "$PLUGIN_ROOT/commands/bootstrap.md" 'scripts/ensure-engineering-principles.sh'
  assert_file_contains "EP8b: startup calls helper" \
    "$PLUGIN_ROOT/commands/startup.md" 'scripts/ensure-engineering-principles.sh'
  assert_file_contains "EP8c: SessionStart hook wires helper" \
    "$PLUGIN_ROOT/hooks/hooks.json" 'ensure-engineering-principles.sh'

  # EP9: dangling CLAUDE.md must not write through the link outside ROOT
  wd="$(make_workdir)"
  outside="$(mktemp -d)"
  ln -s "$outside/leaked.md" "$wd/CLAUDE.md"
  ec=0
  bash "$script" --root "$wd" --plugin-root "$PLUGIN_ROOT" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EP9: dangling CLAUDE repair exit 0" "$ec" 0
  assert_file_not_exists "EP9b: no write through dangling CLAUDE.md" "$outside/leaked.md"
  assert_file_exists "EP9c: CLAUDE.md exists after repair" "$wd/CLAUDE.md"
  if [ -L "$wd/CLAUDE.md" ]; then
    assert_equals "EP9d: CLAUDE.md is not still a symlink after repair" "0" "1"
  else
    assert_file_contains "EP9d: repaired CLAUDE has principles" "$wd/CLAUDE.md" '**KISS**'
  fi
  rm -rf "$outside"
}
test_ensure_engineering_principles
