# Sourced by run-tests.sh — non-interactive plan-file bootstrap (#206).
# Covers scripts/bootstrap-plan.sh: plan-file brief render, fail-closed on a missing
# idea, provenance.json with the plan sha256, and the existing-brief skip.
# Uses the harness assert_* helpers and make_workdir.
test_bootstrap_plan() {
  echo -e "\n${CYAN}Suite: bootstrap-plan (#206)${NC}"
  local S="$PLUGIN_ROOT/scripts/bootstrap-plan.sh"
  local wd ec out sha

  # BP1: JSON plan → brief rendered with every field, zero prompts (stdin closed).
  wd="$(make_workdir)"
  cat > "$wd/plan.json" <<'JSON'
{"idea_description":"Two-minute VAT filing for micro-OU owners","investor_notes":"Focus on e-residents","budget":"5000 EUR","timeline":"3 months","target_market":"Estonian micro-OU","idea_id":"demand-alpha","validated_confidence":4,"experiment_evidence":"docs/growth/exp-alpha.md"}
JSON
  ec=0; out=$(bash "$S" --plan-file "$wd/plan.json" --root "$wd" </dev/null 2>&1) || ec=$?
  assert_exit_code "BP1: plan-file bootstrap exits 0 with stdin closed" "$ec" 0
  assert_file_exists "BP1b: brief.md rendered" "$wd/docs/business/brief.md"
  assert_file_contains "BP1c: idea substituted" "$wd/docs/business/brief.md" "Two-minute VAT filing for micro-OU owners"
  assert_file_contains "BP1d: investor notes substituted" "$wd/docs/business/brief.md" "Focus on e-residents"
  assert_file_contains "BP1e: budget substituted" "$wd/docs/business/brief.md" "Budget: 5000 EUR"
  assert_file_contains "BP1f: timeline substituted" "$wd/docs/business/brief.md" "Timeline: 3 months"
  assert_file_contains "BP1g: target market substituted" "$wd/docs/business/brief.md" "Target market: Estonian micro-OU"
  # No placeholder token survives the render.
  assert_file_not_contains "BP1h: no unresolved token" "$wd/docs/business/brief.md" "{{"
  rm -rf "$wd"

  # BP2: missing idea_description → non-zero exit, and nothing written (fail closed).
  wd="$(make_workdir)"
  echo '{"budget":"5000 EUR","target_market":"x"}' > "$wd/plan.json"
  ec=0; out=$(bash "$S" --plan-file "$wd/plan.json" --root "$wd" </dev/null 2>&1) || ec=$?
  assert_exit_code "BP2: missing idea_description is rejected" "$ec" 2
  assert_output_contains "BP2b: error names the missing field" "$out" "idea_description"
  assert_file_not_exists "BP2c: no brief written" "$wd/docs/business/brief.md"
  assert_file_not_exists "BP2d: no provenance written" "$wd/.startup/provenance.json"
  rm -rf "$wd"

  # BP3: provenance.json carries source, fields, and the plan file's sha256.
  wd="$(make_workdir)"
  cat > "$wd/plan.json" <<'JSON'
{"idea_description":"Automated invoicing","idea_id":"inv-1","validated_confidence":3,"experiment_evidence":"https://ex.test/e"}
JSON
  sha=$(sha256sum "$wd/plan.json" | awk '{print $1}')
  ec=0; out=$(bash "$S" --plan-file "$wd/plan.json" --root "$wd" </dev/null 2>&1) || ec=$?
  assert_exit_code "BP3: bootstrap exits 0" "$ec" 0
  assert_json_valid "BP3b: provenance is valid JSON" "$wd/.startup/provenance.json"
  assert_json_field "BP3c: source is plan-file" "$wd/.startup/provenance.json" '.source' "plan-file"
  assert_json_field "BP3d: plan sha256 recorded" "$wd/.startup/provenance.json" '.plan_sha256' "$sha"
  assert_json_field "BP3e: idea_id recorded" "$wd/.startup/provenance.json" '.idea_id' "inv-1"
  assert_json_field "BP3f: validated_confidence recorded as number" "$wd/.startup/provenance.json" '.validated_confidence' "3"
  assert_json_field "BP3g: experiment_evidence recorded" "$wd/.startup/provenance.json" '.experiment_evidence' "https://ex.test/e"
  rm -rf "$wd"

  # BP2e: a whitespace-only idea does not satisfy the mandatory field (fail closed).
  wd="$(make_workdir)"
  echo '{"idea_description":"   "}' > "$wd/plan.json"
  ec=0; out=$(bash "$S" --plan-file "$wd/plan.json" --root "$wd" </dev/null 2>&1) || ec=$?
  assert_exit_code "BP2e: whitespace-only idea is rejected" "$ec" 2
  assert_file_not_exists "BP2f: no brief on whitespace idea" "$wd/docs/business/brief.md"
  rm -rf "$wd"

  # BP3h: optional provenance fields absent → recorded as null (never invented).
  wd="$(make_workdir)"
  echo '{"idea_description":"Bare idea"}' > "$wd/plan.json"
  bash "$S" --plan-file "$wd/plan.json" --root "$wd" </dev/null >/dev/null 2>&1
  assert_json_field "BP3h: absent idea_id stays null" "$wd/.startup/provenance.json" '.idea_id' "null"
  assert_json_field "BP3i: absent confidence stays null" "$wd/.startup/provenance.json" '.validated_confidence' "null"
  assert_json_field "BP3j: absent evidence stays null" "$wd/.startup/provenance.json" '.experiment_evidence' "null"
  rm -rf "$wd"

  # BP4: no plan file + existing brief.md → skipped, brief untouched, no provenance.
  wd="$(make_workdir)"
  mkdir -p "$wd/docs/business"
  printf 'PRE-EXISTING BRIEF\n' > "$wd/docs/business/brief.md"
  ec=0; out=$(bash "$S" --root "$wd" </dev/null 2>&1) || ec=$?
  assert_exit_code "BP4: existing brief + no plan → exit 0 (skip)" "$ec" 0
  assert_file_contains "BP4b: existing brief left untouched" "$wd/docs/business/brief.md" "PRE-EXISTING BRIEF"
  assert_file_not_exists "BP4c: no provenance on skip" "$wd/.startup/provenance.json"
  rm -rf "$wd"

  # BP5: no plan file + no brief → fail closed (cannot prompt non-interactively).
  wd="$(make_workdir)"
  ec=0; out=$(bash "$S" --root "$wd" </dev/null 2>&1) || ec=$?
  assert_exit_code "BP5: no plan and no brief is rejected" "$ec" 2
  assert_file_not_exists "BP5b: no brief written on failure" "$wd/docs/business/brief.md"
  rm -rf "$wd"

  # BP6: frontmattered markdown plan → body is the idea, frontmatter supplies metadata.
  wd="$(make_workdir)"
  printf -- '---\nbudget: 2000 EUR\ntarget_market: e-residents\nidea_id: fm-idea\n---\nAutomated invoicing for EU freelancers.\n' > "$wd/plan.md"
  ec=0; out=$(bash "$S" --plan-file "$wd/plan.md" --root "$wd" </dev/null 2>&1) || ec=$?
  assert_exit_code "BP6: frontmatter plan exits 0" "$ec" 0
  assert_file_contains "BP6b: body became the idea" "$wd/docs/business/brief.md" "Automated invoicing for EU freelancers."
  assert_file_contains "BP6c: frontmatter budget applied" "$wd/docs/business/brief.md" "Budget: 2000 EUR"
  assert_json_field "BP6d: frontmatter idea_id in provenance" "$wd/.startup/provenance.json" '.idea_id' "fm-idea"
  rm -rf "$wd"

  # BP7: frontmatter idea_description as a bare block-scalar sigil falls back to the body
  # (the sigil is never rendered as the literal description).
  wd="$(make_workdir)"
  printf -- '---\nidea_description: |\nbudget: 1000 EUR\n---\nReal idea from the body.\n' > "$wd/plan.md"
  ec=0; out=$(bash "$S" --plan-file "$wd/plan.md" --root "$wd" </dev/null 2>&1) || ec=$?
  assert_exit_code "BP7: block-scalar frontmatter idea exits 0" "$ec" 0
  assert_file_contains "BP7b: body used as idea" "$wd/docs/business/brief.md" "Real idea from the body."
  assert_file_not_contains "BP7c: bare sigil not rendered as idea" "$wd/docs/business/brief.md" "|"
  rm -rf "$wd"
}
test_bootstrap_plan
