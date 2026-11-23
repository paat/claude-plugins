#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

# ---------------------------------------------------------------------------
# Suite B: check-task-complete.sh
# ---------------------------------------------------------------------------

test_check_task_complete() {
  echo -e "
${CYAN}Suite B: check-task-complete removed (#391)${NC}"
  assert_file_not_exists "B1: check-task-complete.sh removed" "$PLUGIN_ROOT/scripts/check-task-complete.sh"
}

# ---------------------------------------------------------------------------
# Suite C: status.sh
# ---------------------------------------------------------------------------

test_status_script() {
  echo -e "\n${CYAN}Suite C: status.sh${NC}"
  local script="$PLUGIN_ROOT/scripts/status.sh"
  local workdir ec output

  # C1: no .startup dir
  workdir=$(make_workdir)
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "C1: no .startup exits 0" "$ec" 0
  assert_output_contains "C1: shows no-session message" "$output" "No project artifacts found"
  rm -rf "$workdir"

  # C2: empty minimal .startup
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 0
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "C2: minimal setup exits 0" "$ec" 0
  assert_output_contains "C2: shows zero handoffs" "$output" "Total handoffs: 0"
  rm -rf "$workdir"

  # C3: with handoffs
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 2
  echo "h1" > "$workdir/.startup/handoffs/001-business-to-tech.md"
  echo "h2" > "$workdir/.startup/handoffs/002-tech-to-business.md"
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "C3: with handoffs exits 0" "$ec" 0
  assert_output_contains "C3: shows handoff count" "$output" "Total handoffs: 2"
  assert_output_contains "C3: lists first handoff" "$output" "001-business-to-tech.md"
  assert_output_contains "C3: lists second handoff" "$output" "002-tech-to-business.md"
  rm -rf "$workdir"

  # C4: with solution signoff
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 5
  echo "signoff" > "$workdir/.startup/go-live/solution-signoff.md"
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "C4: go-live status exits 0" "$ec" 0
  assert_output_contains "C4: shows ready for go-live" "$output" "Ready for go-live"
  rm -rf "$workdir"

  # C5: with human tasks
  workdir=$(make_workdir)
  setup_startup_dir "$workdir" 3
  cat > "$workdir/docs/human-tasks.md" <<'TASKS'
# Human Tasks
## Pending
- [ ] Register OÜ
- [ ] Open bank account
- [ ] Get domain name
## Completed
- [x] Review business plan
TASKS
  ec=0; output=$(cd "$workdir" && bash "$script" 2>&1) || ec=$?
  assert_exit_code "C5: human tasks exits 0" "$ec" 0
  assert_output_contains "C5: shows pending count" "$output" "Pending: 3"
  assert_output_contains "C5: shows completed count" "$output" "Completed: 1"
  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite D: Template Validation
# ---------------------------------------------------------------------------

test_templates() {
  echo -e "\n${CYAN}Suite D: Template Validation${NC}"
  local tmpl_dir="$PLUGIN_ROOT/templates"

  # D1-D5: startup-brief.md
  assert_file_exists "D1: startup-brief.md exists" "$tmpl_dir/startup-brief.md"
  assert_file_contains "D2: has IDEA_DESCRIPTION placeholder" "$tmpl_dir/startup-brief.md" "{{IDEA_DESCRIPTION}}"
  assert_file_contains "D3: has INVESTOR_NOTES placeholder" "$tmpl_dir/startup-brief.md" "{{INVESTOR_NOTES}}"
  assert_file_contains "D4: has BUDGET placeholder" "$tmpl_dir/startup-brief.md" "{{BUDGET}}"
  assert_file_contains "D5: has TIMELINE placeholder" "$tmpl_dir/startup-brief.md" "{{TIMELINE}}"
  assert_file_contains "D5b: has TARGET_MARKET placeholder" "$tmpl_dir/startup-brief.md" "{{TARGET_MARKET}}"

  # D6-D10: handoff-business-to-tech.md
  assert_file_exists "D6: handoff-business-to-tech.md exists" "$tmpl_dir/handoff-business-to-tech.md"
  assert_file_contains "D7: has from frontmatter" "$tmpl_dir/handoff-business-to-tech.md" "^from:"
  assert_file_contains "D8: has to frontmatter" "$tmpl_dir/handoff-business-to-tech.md" "^to:"
  assert_file_contains "D9: has iteration frontmatter" "$tmpl_dir/handoff-business-to-tech.md" "^iteration:"
  assert_file_contains "D10: has type frontmatter" "$tmpl_dir/handoff-business-to-tech.md" "^type:"
  assert_file_contains "D10b: has ITERATION placeholder" "$tmpl_dir/handoff-business-to-tech.md" "{{ITERATION}}"
  assert_file_contains "D10c: has DATE placeholder" "$tmpl_dir/handoff-business-to-tech.md" "{{DATE}}"
  assert_file_contains "D10c1: handoff names Done explicitly" \
    "$tmpl_dir/handoff-business-to-tech.md" "### Done / Feature Requirements"
  assert_file_contains "D10d: handoff declares preserved behavior" \
    "$tmpl_dir/handoff-business-to-tech.md" "### Preserve"
  assert_file_contains "D10e: handoff declares explicit exclusions" \
    "$tmpl_dir/handoff-business-to-tech.md" "### Out of Scope"
  assert_file_contains "D10f: return handoff quarantines adjacent findings" \
    "$tmpl_dir/handoff-tech-to-business.md" "### Not Addressed"
  assert_file_contains "D10g: Claude build role loads shared scope contract" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "templates/delivery-scope-contract.md"
  assert_file_contains "D10g1: Claude architecture planning applies shared scope" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Before architecture planning or implementation"
  assert_file_contains "D10h: Claude maintenance role loads shared scope contract" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "templates/delivery-scope-contract.md"
  assert_file_contains "D10h1: Claude maintenance planning applies shared scope" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Before architecture planning or implementation"
  assert_file_contains "D10i: Codex-native tech skill loads shared scope contract" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "../../templates/delivery-scope-contract.md"
  assert_file_contains "D10i1: Codex-native architecture planning applies shared scope" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Before architecture planning or implementation"
  assert_file_exists "D10j: Codex-native scope contract path resolves" \
    "$PLUGIN_ROOT/skills/tech-founder/../../templates/delivery-scope-contract.md"
  assert_file_contains "D10k: scope stop preserves required handoff" \
    "$tmpl_dir/delivery-scope-contract.md" "complete the required handoff or report, then exit"
  assert_file_contains "D10k1: shared scope requires a finished solo-founder product" \
    "$tmpl_dir/delivery-scope-contract.md" "finished production product operated by one founder"
  assert_file_contains "D10k2: KISS preserves product completeness" \
    "$tmpl_dir/delivery-scope-contract.md" "KISS trims operational complexity, never product completeness"
  assert_file_contains "D10k2a: shared scope rejects MVP delivery" \
    "$tmpl_dir/delivery-scope-contract.md" "never an MVP"
  assert_file_contains "D10k2b: enterprise exceptions allow preventive controls" \
    "$tmpl_dir/delivery-scope-contract.md" "concrete documented security, legal, reliability, or operability need"
  assert_file_contains "D10k3: Codex-native skill applies solo-founder KISS" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Solo-Founder KISS Rule"
  assert_file_contains "D10k4: architecture reference keeps solo-operator defaults" \
    "$PLUGIN_ROOT/references/tech-founder/architecture.md" \
    "one deployable application, one primary datastore"
  assert_file_contains "D10l: maintenance founder writes explicit brief scope" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" '`Done`, `Preserve`, and `Out of Scope`'
  assert_file_contains "D10m: Codex-native founder writes explicit brief scope" \
    "$PLUGIN_ROOT/skills/product-discovery/SKILL.md" '`Done`, `Preserve`, and `Out of Scope`'
  assert_file_contains "D10n: quality gate distinguishes unrelated failures" \
    "$PLUGIN_ROOT/references/tech-founder/quality-standards.md" \
    "Report unrelated or pre-existing failures as blockers"
  assert_file_exists "D10o: lean planning golden eval exists" \
    "$tmpl_dir/lean-planning-golden.md"
  assert_file_contains "D10o1: lean eval is a scheduled-report feature" \
    "$tmpl_dir/lean-planning-golden.md" "weekly internal operations report"
  assert_file_contains "D10o2: lean eval requires reuse-first planning" \
    "$tmpl_dir/lean-planning-golden.md" "Reuse the existing scheduled-job ritual"
  assert_file_contains "D10o3: lean eval needs no mandatory questions" \
    "$tmpl_dir/lean-planning-golden.md" "No mandatory user questions are needed"
  assert_file_exists "D10p0: planner-only scope file exists" \
    "$tmpl_dir/delivery-scope-planning.md"
  assert_file_contains "D10p: shared scope defines direct feature planning" \
    "$tmpl_dir/delivery-scope-planning.md" "# Direct Feature Planning"
  assert_file_contains "D10p1: shared scope defaults to one discovery pass" \
    "$tmpl_dir/delivery-scope-planning.md" "one targeted repository-discovery pass"
  assert_file_contains "D10p2: shared scope asks only material blockers" \
    "$tmpl_dir/delivery-scope-planning.md" "Ask only when a missing choice would materially change"
  assert_file_contains "D10p3: shared scope requires reuse before new machinery" \
    "$tmpl_dir/delivery-scope-planning.md" "scheduler, delivery framework, evidence store, or control plane"
  assert_file_contains "D10p4: shared scope bounds topic evidence" \
    "$tmpl_dir/delivery-scope-planning.md" "not a product-wide audit"
  assert_file_contains "D10p5: direct Why does not force new research" \
    "$tmpl_dir/delivery-scope-planning.md" "do not require a new research artifact"
  assert_file_contains "D10p6: implement contract omits planner-only Direct Feature Planning" \
    "$tmpl_dir/delivery-scope-contract.md" "Delivery Scope Contract"
  assert_file_not_contains "D10p7: implement contract has no Direct Feature Planning section" \
    "$tmpl_dir/delivery-scope-contract.md" "Direct Feature Planning"
  assert_file_contains "D10q: Claude business founder loads shared scope" \
    "$PLUGIN_ROOT/skills/product-discovery/SKILL.md" "templates/delivery-scope-contract.md"
  assert_file_contains "D10q1: Claude maintenance founder loads shared scope" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" "templates/delivery-scope-contract.md"
  assert_file_contains "D10q2: Codex-native business skill loads shared scope" \
    "$PLUGIN_ROOT/skills/product-discovery/SKILL.md" "../../templates/delivery-scope-contract.md"
  assert_file_contains "D10q3: lifecycle scopes planning before discovery expansion" \
    "$PLUGIN_ROOT/skills/lifecycle/SKILL.md" "Skip broad market research"
  assert_file_contains "D10q4: goal delivery defaults to its primary planner" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" "Do not dispatch a planning role by default"
  assert_file_contains "D10q5: improve brief applies scope before research" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" "Before reading product or research docs, read and apply"
  assert_file_contains "D10q6: project guidance exposes lean direct planning" \
    "$tmpl_dir/claude-md-workflow-guidance.md" "Lean direct-feature planning"
  assert_file_contains "D10q6a: project guidance stops after file-only issue asks" \
    "$tmpl_dir/claude-md-workflow-guidance.md" "Do not auto-start delivery when filing issues"
  assert_file_contains "D10q7: Claude tech gate points at brief acceptance" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "brief-acceptance-gate.md"
  assert_file_contains "D10q8: maintenance tech gate points at brief acceptance" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "brief-acceptance-gate.md"
  assert_file_contains "D10q9: Codex-native tech skill points at brief acceptance" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "brief-acceptance-gate.md"
  assert_file_contains "D10q9b: brief acceptance accepts direct request evidence" \
    "$PLUGIN_ROOT/references/brief-acceptance-gate.md" "does not require a new research document"
  assert_file_contains "D10q10: handoff template accepts direct request evidence" \
    "$tmpl_dir/handoff-business-to-tech.md" "For a direct feature"
  assert_file_contains "D10q11: delivery-scope planning accepts direct request evidence" \
    "$tmpl_dir/delivery-scope-planning.md" \
    "do not require a new research artifact"

  # D11-D15: handoff-tech-to-business.md
  assert_file_exists "D11: handoff-tech-to-business.md exists" "$tmpl_dir/handoff-tech-to-business.md"
  assert_file_contains "D12: has from frontmatter" "$tmpl_dir/handoff-tech-to-business.md" "^from:"
  assert_file_contains "D13: has to frontmatter" "$tmpl_dir/handoff-tech-to-business.md" "^to:"
  assert_file_contains "D14: has iteration frontmatter" "$tmpl_dir/handoff-tech-to-business.md" "^iteration:"
  assert_file_contains "D15: has type frontmatter" "$tmpl_dir/handoff-tech-to-business.md" "^type:"
  assert_file_contains "D15b: has ITERATION placeholder" "$tmpl_dir/handoff-tech-to-business.md" "{{ITERATION}}"
  assert_file_contains "D15c: has DATE placeholder" "$tmpl_dir/handoff-tech-to-business.md" "{{DATE}}"

  # D16-D20: roundtrip-signoff.md
  assert_file_exists "D16: roundtrip-signoff.md exists" "$tmpl_dir/roundtrip-signoff.md"
  assert_file_contains "D17: has feature frontmatter" "$tmpl_dir/roundtrip-signoff.md" "^feature:"
  assert_file_contains "D18: has roundtrip frontmatter" "$tmpl_dir/roundtrip-signoff.md" "^roundtrip:"
  assert_file_contains "D19: has signed_by frontmatter" "$tmpl_dir/roundtrip-signoff.md" "^signed_by:"
  assert_file_contains "D20: has status frontmatter" "$tmpl_dir/roundtrip-signoff.md" "^status:"
  assert_file_contains "D20b: has FEATURE_NAME placeholder" "$tmpl_dir/roundtrip-signoff.md" "{{FEATURE_NAME}}"
  assert_file_contains "D20c: has ROUNDTRIP_NUMBER placeholder" "$tmpl_dir/roundtrip-signoff.md" "{{ROUNDTRIP_NUMBER}}"
  assert_file_contains "D20d: has DATE placeholder" "$tmpl_dir/roundtrip-signoff.md" "{{DATE}}"

  # D21-D25: solution-signoff.md
  assert_file_exists "D21: solution-signoff.md exists" "$tmpl_dir/solution-signoff.md"
  assert_file_contains "D22: has date frontmatter" "$tmpl_dir/solution-signoff.md" "^date:"
  assert_file_contains "D23: has signed_by frontmatter" "$tmpl_dir/solution-signoff.md" "^signed_by:"
  assert_file_contains "D24: has status frontmatter" "$tmpl_dir/solution-signoff.md" "^status:"
  assert_file_contains "D25: has iteration_count frontmatter" "$tmpl_dir/solution-signoff.md" "^iteration_count:"
  assert_file_contains "D25b: has TOTAL_ITERATIONS placeholder" "$tmpl_dir/solution-signoff.md" "{{TOTAL_ITERATIONS}}"
  assert_file_contains "D25c: has ESTONIAN_SUMMARY placeholder" "$tmpl_dir/solution-signoff.md" "{{ESTONIAN_SUMMARY}}"
  assert_file_contains "D25d: has DATE placeholder" "$tmpl_dir/solution-signoff.md" "{{DATE}}"

  # D26-D28: human-tasks.md
  assert_file_exists "D26: human-tasks.md exists" "$tmpl_dir/human-tasks.md"
  assert_file_contains "D27: has Pending section" "$tmpl_dir/human-tasks.md" "## Pending"
  assert_file_contains "D28: has Completed section" "$tmpl_dir/human-tasks.md" "## Completed"
}


# ---------------------------------------------------------------------------
# Suite W: check.sh template (canonical full-suite entrypoint)
# ---------------------------------------------------------------------------

test_check_sh_template() {
  echo -e "\n${CYAN}Suite W: check.sh template${NC}"
  local tmpl="$PLUGIN_ROOT/templates/check.sh"
  local workdir ec output

  # W1: template exists and has the bash shebang
  assert_file_exists "W1: check.sh template exists" "$tmpl"
  assert_file_contains "W2: uses env bash shebang" "$tmpl" '#!/usr/bin/env bash'
  assert_file_contains "W3: has REQUIRED_SUITES array" "$tmpl" 'REQUIRED_SUITES='
  assert_file_contains "W4: has run_suite helper" "$tmpl" 'run_suite()'
  assert_file_contains "W5: has suite_stub helper" "$tmpl" 'suite_stub()'
  assert_file_contains "W6: VERIFY COMPLETE banner present" "$tmpl" 'VERIFY COMPLETE'

  # W7: vacuous run (no suites declared) → non-zero, refuses to report success
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W7: vacuous run fails (non-zero)" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  assert_output_contains "W7b: refuses to report success" "$output" "no suites ran"
  rm -rf "$workdir"

  # W8: a wired, green suite → exit 0
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  # declare + wire frontend_tests to a trivially-green command.
  # NOTE: the wiring seds match `^name().*` so they are agnostic to the
  # template's column-aligned spacing between `()` and `{`.
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(frontend_tests)/' "$workdir/check.sh"
  sed -i "s|^frontend_tests().*|frontend_tests() { run_suite frontend_tests 'true'; }|" "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_exit_code "W8: wired green suite passes" "$ec" 0
  rm -rf "$workdir"

  # W9: a declared-but-unwired suite → non-zero (Guard 2)
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(backend_tests)/' "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W9: unwired declared suite fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  assert_output_contains "W9b: names the unwired suite" "$output" "backend_tests"
  rm -rf "$workdir"

  # W9c: declared suite hand-edited to return 0 WITHOUT run_suite → still fails (Guard 2)
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(backend_tests)/' "$workdir/check.sh"
  sed -i 's|^backend_tests().*|backend_tests() { true; }|' "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W9c: declared-but-never-ran suite fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  assert_output_contains "W9d: Guard 2 names never-ran suite" "$output" "never ran a command"
  rm -rf "$workdir"

  # W10: a wired, RED suite → non-zero
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(lint)/' "$workdir/check.sh"
  sed -i "s|^lint().*|lint() { run_suite lint 'false'; }|" "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W10: wired red suite fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  rm -rf "$workdir"

  # W11: mid-command failure in an &&-chain propagates (no pipefail masking)
  workdir=$(mktemp -d)
  cp "$tmpl" "$workdir/check.sh"; chmod +x "$workdir/check.sh"
  sed -i 's/^REQUIRED_SUITES=()/REQUIRED_SUITES=(typecheck)/' "$workdir/check.sh"
  sed -i "s|^typecheck().*|typecheck() { run_suite typecheck 'false \&\& true'; }|" "$workdir/check.sh"
  ec=0; output=$(cd "$workdir" && ./check.sh 2>&1) || ec=$?
  assert_equals "W11: &&-chain mid failure fails" "$([ "$ec" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  rm -rf "$workdir"

  # W12-W16: CI workflow template
  local ci="$PLUGIN_ROOT/templates/ci-workflow.yml"
  assert_file_exists "W12: ci-workflow.yml exists" "$ci"
  assert_file_contains "W13: workflow name is CI" "$ci" '^name: CI'
  assert_file_contains "W14: pull_request trigger" "$ci" '^  pull_request:'
  assert_file_contains "W15: job id check" "$ci" '^  check:'
  assert_file_contains "W16: runs ./check.sh" "$ci" 'run: ./check.sh'
  assert_file_contains "W17: STACK_SETUP token alone on its own comment line" "$ci" '^      # {{STACK_SETUP}}$'
}

# ---------------------------------------------------------------------------
# Suite X: bootstrap pre-merge safety-net scaffolding
# ---------------------------------------------------------------------------

test_bootstrap_safety_net() {
  echo -e "\n${CYAN}Suite X: bootstrap safety-net scaffolding${NC}"
  local cmd="$PLUGIN_ROOT/skills/bootstrap/SKILL.md"
  local workdir ec output

  # Scaffold lives in scripts/bootstrap-scaffold.sh (#391)
  local script
  workdir=$(mktemp -d)
  cp "$PLUGIN_ROOT/scripts/bootstrap-scaffold.sh" "$workdir/scaffold.sh"
  chmod +x "$workdir/scaffold.sh"

  # X1: the script is non-empty
  assert_equals "X1: scaffold block extracted" "$([ -s "$workdir/scaffold.sh" ] && echo yes || echo no)" "yes"

  # X2-X5: no stack present → scaffolds files with the placeholder marker
  mkdir -p "$workdir/repo"; (cd "$workdir/repo" && git init -q)
  mkdir -p "$workdir/repo/.startup"
  ec=0; output=$(cd "$workdir/repo" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" 2>&1) || ec=$?
  assert_exit_code "X2: scaffold runs cleanly" "$ec" 0
  assert_file_exists "X3: ci.yml created" "$workdir/repo/.github/workflows/ci.yml"
  assert_file_exists "X4: check.sh created" "$workdir/repo/check.sh"
  assert_equals "X5: check.sh executable" "$([ -x "$workdir/repo/check.sh" ] && echo yes || echo no)" "yes"
  assert_file_contains "X6: human-tasks has branch-protection task" "$workdir/repo/docs/human-tasks.md" "branch protection"
  assert_file_contains "X7: human task is sequenced after green CI" "$workdir/repo/docs/human-tasks.md" "first CI run"
  # no stack detected → placeholder marker remains in ci.yml
  assert_file_contains "X8: no-stack keeps TECH-FOUNDER marker" "$workdir/repo/.github/workflows/ci.yml" "TECH-FOUNDER"

  # X9: idempotent — re-run does not duplicate the human task or error
  ec=0; output=$(cd "$workdir/repo" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" 2>&1) || ec=$?
  assert_exit_code "X9: re-run is idempotent (clean exit)" "$ec" 0
  local count
  # Count the unique idempotency-guard heading (the phrase "branch protection"
  # itself appears twice per block: in the heading and in the UI instructions).
  count=$(grep -c "Require the CI check (branch protection)" "$workdir/repo/docs/human-tasks.md")
  assert_equals "X10: branch-protection task not duplicated" "$count" "1"

  # X11-X13: node stack detected → STACK_SETUP substituted with setup-node
  rm -rf "$workdir/repo2"; mkdir -p "$workdir/repo2/.startup"; (cd "$workdir/repo2" && git init -q)
  echo '{"scripts":{"test":"jest"}}' > "$workdir/repo2/package.json"
  ec=0; output=$(cd "$workdir/repo2" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" 2>&1) || ec=$?
  assert_exit_code "X11: node scaffold runs cleanly" "$ec" 0
  assert_file_contains "X12: node setup injected" "$workdir/repo2/.github/workflows/ci.yml" "setup-node"
  assert_file_contains "X13: check.sh has node detection hint" "$workdir/repo2/check.sh" "DETECTED"

  # X14-X15: node WITHOUT lockfile → npm install, not npm ci
  assert_file_contains "X14: no-lockfile uses npm install" "$workdir/repo2/.github/workflows/ci.yml" "npm install"
  assert_file_not_contains "X15: no-lockfile avoids npm ci" "$workdir/repo2/.github/workflows/ci.yml" "npm ci"

  # X16-X17: node WITH lockfile → npm ci + cache
  rm -rf "$workdir/repo3"; mkdir -p "$workdir/repo3/.startup"; (cd "$workdir/repo3" && git init -q)
  echo '{"scripts":{"test":"jest"}}' > "$workdir/repo3/package.json"
  echo '{}' > "$workdir/repo3/package-lock.json"
  (cd "$workdir/repo3" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" >/dev/null 2>&1)
  assert_file_contains "X16: lockfile uses npm ci" "$workdir/repo3/.github/workflows/ci.yml" "npm ci"
  assert_file_contains "X17: lockfile sets cache npm" "$workdir/repo3/.github/workflows/ci.yml" "cache: npm"

  # X18: python WITH requirements.txt → pip install -r
  rm -rf "$workdir/repo4"; mkdir -p "$workdir/repo4/.startup"; (cd "$workdir/repo4" && git init -q)
  echo 'pytest' > "$workdir/repo4/requirements.txt"
  (cd "$workdir/repo4" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" >/dev/null 2>&1)
  assert_file_contains "X18: requirements uses pip -r" "$workdir/repo4/.github/workflows/ci.yml" "pip install -r requirements.txt"
  assert_file_contains "X18b: python setup injected" "$workdir/repo4/.github/workflows/ci.yml" "setup-python"

  # X19: python pyproject-only (no requirements.txt) → pip install -e .
  rm -rf "$workdir/repo5"; mkdir -p "$workdir/repo5/.startup"; (cd "$workdir/repo5" && git init -q)
  printf '[project]\nname = "x"\n' > "$workdir/repo5/pyproject.toml"
  (cd "$workdir/repo5" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$workdir/scaffold.sh" >/dev/null 2>&1)
  assert_file_contains "X19: pyproject-only uses pip install -e ." "$workdir/repo5/.github/workflows/ci.yml" "pip install -e \."

  # X20: the extracted Step 6.5 block has NO nested triple-backtick fences
  fence_cnt=$(grep -c '^```' "$workdir/scaffold.sh" || true)
  assert_equals "X20: scaffold script has no markdown fences" "$fence_cnt" "0"

  rm -rf "$workdir"
}

# ---------------------------------------------------------------------------
# Suite Y: canonical entrypoint wiring (plugin-self drift guard)
# ---------------------------------------------------------------------------

test_canonical_entrypoint_wiring() {
  echo -e "\n${CYAN}Suite Y: canonical entrypoint wiring${NC}"
  assert_file_contains "Y1: improve.md names check.sh" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" "check.sh"
  assert_file_contains "Y2: tech-founder SKILL names check.sh" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "check.sh"
  assert_file_contains "Y3: ci-workflow names check.sh" \
    "$PLUGIN_ROOT/templates/ci-workflow.yml" "check.sh"
  assert_file_contains "Y4: tech-founder names canonical entrypoint" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Canonical entrypoint"
  assert_file_contains "Y5: tech-founder has derived-output guidance" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "Derived-output correctness"
  assert_file_contains "Y6: tech-founder names green-but-wrong risk" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "green-but-wrong"
  assert_file_contains "Y7: tech-founder mentions golden suite" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "golden"
  assert_file_contains "Y7a: tech-founder requires recurrence class" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "root cause / recurrence class"
  assert_file_contains "Y7b: tech-founder fixes failure class" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "fix the class"
  assert_file_contains "Y7c: tech-founder requires mechanical guard" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "durable mechanical guard"
  assert_file_contains "Y7d: tech-founder records red-green proof" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "red-before/green-after proof"
  assert_file_contains "Y7e: tech-founder follow-ups go through issue-file" \
    "$PLUGIN_ROOT/skills/tech-founder/SKILL.md" "issue-file"
  assert_file_contains "Y8: quality-standards has single-source-of-truth principle" \
    "$PLUGIN_ROOT/references/tech-founder/quality-standards.md" "Single source of truth"
  assert_file_contains "Y9: quality-standards warns about re-derived rules" \
    "$PLUGIN_ROOT/references/tech-founder/quality-standards.md" "re-derive"
  assert_file_contains "Y10: maintain agent has independent spot-check" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" "independent source"
  assert_file_contains "Y11: build agent has independent spot-check" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" "independent source"
  assert_file_contains "Y12: maintain agent has duplicated-rule awareness" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" "another layer"
  assert_file_contains "Y13: build agent has duplicated-rule awareness" \
    "$PLUGIN_ROOT/skills/product-acceptance/SKILL.md" "another layer"
  assert_file_contains "Y14: quality-standards handoff checklist names check.sh" \
    "$PLUGIN_ROOT/references/tech-founder/quality-standards.md" "check.sh"
}

# ---------------------------------------------------------------------------
# Suite E: Plugin Configuration
# ---------------------------------------------------------------------------

test_plugin_config() {
  echo -e "\n${CYAN}Suite E: Plugin Configuration${NC}"

  # E1-E4: plugin.json
  assert_json_valid "E1: plugin.json is valid JSON" "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  assert_json_field "E2: plugin.json has name" "$PLUGIN_ROOT/.claude-plugin/plugin.json" ".name" "saas-startup-team"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  local ver
  ver=$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
  if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "  ${GREEN}PASS${NC} E3: plugin.json version is valid semver ($ver)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} E3: plugin.json version is not valid semver ($ver)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("E3: plugin.json version not valid semver: $ver")
  fi
  local desc
  desc=$(jq -r '.description' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -n "$desc" ] && [ "$desc" != "null" ]; then
    echo -e "  ${GREEN}PASS${NC} E4: plugin.json has description"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} E4: plugin.json missing description"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("E4: plugin.json missing description")
  fi

  # E5-E6: settings.json
  assert_json_valid "E5: settings.json is valid JSON" "$PLUGIN_ROOT/settings.json"
  # Experimental Agent Teams disabled (#381): startup forbids TeamCreate; do not
  # enable a conflicting experimental team surface by default.
  assert_json_valid "E6: settings.json remains valid after team-flag removal" "$PLUGIN_ROOT/settings.json"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if jq -e '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == "1"' "$PLUGIN_ROOT/settings.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} E6b: experimental agent teams must stay disabled"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("E6b: experimental agent teams must stay disabled")
  else
    echo -e "  ${GREEN}PASS${NC} E6b: experimental agent teams disabled"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi

  # E7-E12: hooks.json
  assert_json_valid "E7: hooks.json is valid JSON" "$PLUGIN_ROOT/hooks/hooks.json"
  local hooks_keys
  hooks_keys=$(jq -r '.hooks | keys[]' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null)
  assert_output_contains "E8: hooks.json has PreToolUse" "$hooks_keys" "PreToolUse"
  assert_output_contains "E9: hooks.json has PostToolUse" "$hooks_keys" "PostToolUse"
  assert_output_not_contains "E10: hooks.json has no Stop (lifecycle #386)" "$hooks_keys" "Stop"
  assert_output_not_contains "E11: hooks.json omits Codex-unsupported TeammateIdle" "$hooks_keys" "TeammateIdle"
  assert_output_not_contains "E12: hooks.json omits Codex-unsupported TaskCompleted" "$hooks_keys" "TaskCompleted"

  local repo_root grok_interpolations hooks_file
  repo_root="$(cd "$PLUGIN_ROOT/../.." && pwd)"
  grok_interpolations=$(
    for hooks_file in "$repo_root"/plugins/*/hooks/hooks.json; do
      jq -r '.. | objects | .command? // empty' "$hooks_file" \
        | sed -E 's/\$\{([[:alpha:]_][[:alnum:]_]*):-/\{\1:-/g' \
        | grep -nF '$' \
        | sed "s#^#$hooks_file:#" || true
    done
  )
  assert_equals "E13: hook commands default every Grok interpolation" "$grok_interpolations" ""

  # C-enforce: PreToolUse hooks/dispatch.sh is registered
  local enforce_cmd
  enforce_cmd=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // empty' "$PLUGIN_ROOT/hooks/hooks.json" | grep -F "hooks/dispatch.sh" || true)
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [ -n "$enforce_cmd" ]; then
    echo -e "  ${GREEN}PASS${NC} C-enforce: PreToolUse hook registers hooks/dispatch.sh"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  ${RED}FAIL${NC} C-enforce: PreToolUse hook does not register hooks/dispatch.sh"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("C-enforce: missing hooks/dispatch.sh in PreToolUse")
  fi

  # C-enforce-matcher: the entry uses matcher "Write"
  local enforce_matcher
  enforce_matcher=$(jq -r '.hooks.PreToolUse[]? | select(.hooks[]?.command | test("hooks/dispatch.sh")) | select(.matcher | test("Write")) | .matcher // empty' "$PLUGIN_ROOT/hooks/hooks.json" | head -1)
  assert_output_contains "C-dispatch-matcher: Write matcher" "$enforce_matcher" "Write"
}


test_check_task_complete
test_status_script
test_templates
test_check_sh_template
test_bootstrap_safety_net
test_canonical_entrypoint_wiring
test_plugin_config
