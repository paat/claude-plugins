# Sourced by run-tests.sh — UX/design live-quality gate (#203): ui-touch.sh
# classifier + design-review leg wiring. Uses harness assert_* helpers.
test_ui_gate() {
  echo -e "\n${CYAN}Suite: UX/design live-quality gate (#203)${NC}"
  local script="$PLUGIN_ROOT/scripts/ui-touch.sh"
  local leg="$PLUGIN_ROOT/skills/ux-tester/references/design-review-leg.md"
  local policy="$PLUGIN_ROOT/templates/merge-policy.md"
  local ec range_repo odd_path

  assert_file_exists "UG0: ui-touch.sh present" "$script"

  # classify via --files (stdin); no git needed
  classify() { printf '%s' "$1" | bash "$script" --files; }

  assert_equals "UG1: css → ui"              "$(classify 'styles/app.css')" "ui"
  assert_equals "UG2: components/*.tsx → ui" "$(classify 'src/components/Button.tsx')" "ui"
  assert_equals "UG3: scripts/*.sh → no-ui"  "$(classify 'scripts/deploy.sh')" "no-ui"
  assert_equals "UG4: locale json → ui"      "$(classify 'locales/et.json')" "ui"
  assert_equals "UG5: empty → no-ui"         "$(classify '')" "no-ui"
  assert_equals "UG5b: index.html → ui"      "$(classify 'index.html')" "ui"
  assert_equals "UG5c: public asset jpg → ui" "$(classify 'public/hero.jpg')" "ui"
  assert_equals "UG5d: assets/ dir → ui"     "$(classify 'assets/logo.svg')" "ui"
  assert_equals "UG5e: bad git range → ui (fail-closed)" "$(cd "$(mktemp -d)" && git init -q . && bash "$script" --range 'nosuch...HEAD' 2>/dev/null)" "ui"
  assert_equals "UG6: mixed (md+css) → ui"   "$(printf 'README.md\nstyles/app.css\n' | bash "$script" --files)" "ui"
  assert_equals "UG7: docs-only → no-ui"     "$(printf 'README.md\nsrc/util.go\n' | bash "$script" --files)" "no-ui"
  assert_equals "UG7a: locale path → ui"      "$(classify 'config/locales/et.yml')" "ui"
  assert_equals "UG7b: binary web-font path → ui" "$(classify 'src/fonts/site.woff2')" "ui"
  assert_equals "UG7c: Tailwind config → ui"  "$(classify 'TAILWIND.config.ts')" "ui"
  assert_equals "UG7d: theme config → ui"     "$(classify 'config/dark-theme.json')" "ui"
  assert_equals "UG7e: uppercase MDX → ui"    "$(classify 'docs/landing.MDX')" "ui"
  assert_equals "UG7f: uppercase PO → ui"     "$(classify 'messages/ET.PO')" "ui"
  assert_equals "UG7g: template extension → ui" "$(classify 'mail/receipt.hbs')" "ui"
  assert_equals "UG7h: unusual non-UI path stays no-ui" \
    "$(printf '%s\0' 'src/-odd source.go' | bash "$script" --files0)" "no-ui"

  range_repo=$(mktemp -d)
  git -C "$range_repo" init -q
  git -C "$range_repo" config user.email test@example.invalid
  git -C "$range_repo" config user.name Test
  git -C "$range_repo" commit -qm base --allow-empty
  odd_path=$'docs/ordinary\nsource.go'
  mkdir -p "$range_repo/docs"
  printf 'package docs\n' > "$range_repo/$odd_path"
  git -C "$range_repo" add -- "$odd_path"
  git -C "$range_repo" commit -qm 'odd filename'
  assert_equals "UG7i: newline filename is ambiguous/UI (fail-closed)" \
    "$(cd "$range_repo" && bash "$script" --range 'HEAD^..HEAD')" "ui"
  rm -rf -- "$range_repo"

  # usage errors → exit 2
  ec=0; bash "$script" >/dev/null 2>&1 || ec=$?
  assert_exit_code "UG8: no args → exit 2" "$ec" 2
  ec=0; bash "$script" --range >/dev/null 2>&1 || ec=$?
  assert_exit_code "UG8b: --range without value → exit 2" "$ec" 2
  ec=0; bash "$script" --files0 extra >/dev/null 2>&1 || ec=$?
  assert_exit_code "UG8c: --files0 with extra arg → exit 2" "$ec" 2

  # design-review-leg.md: verdict block contract + both sections
  assert_file_exists "UG9: design-review-leg.md present" "$leg"
  assert_file_contains "UG10: verdict block contract" "$leg" "## Design-review: PASS|FAIL"
  assert_file_contains "UG11: pre-merge section" "$leg" "## Pre-merge design-review leg"
  assert_file_contains "UG12: post-deploy section" "$leg" "## Post-deploy visual smoke"
  assert_file_contains "UG12a: transport loss is not a product verdict" "$leg" \
    'is `tool-unavailable`, not product PASS or FAIL'
  assert_file_contains "UG12b: transport retry starts evidence from scratch" "$leg" \
    'repeat the complete page,'
  assert_file_contains "UG12c: partial browser sessions cannot prove PASS" "$leg" \
    'combine partial sessions'
  assert_file_contains "UG12d: maintenance browser failure stays issue-local" "$leg" \
    'continue independent work'
  assert_file_contains "UG12e: baseline audit uses fetched default SHA" "$leg" \
    'baseline audit use the fetched default-branch SHA'
  assert_file_contains "UG12f: unproven shared dev is not pre-merge evidence" "$leg" \
    'shared dev URL is not pre-merge evidence'
  assert_file_contains "UG12g: post-deploy evidence uses public URL" "$leg" \
    'deployed public URL'
  assert_file_contains "UG12h: baseline and candidate preserve caller workspace" "$leg" \
    'never switch or'

  # merge-policy names the classifier
  assert_file_contains "UG13: merge-policy names ui-touch.sh" "$policy" "scripts/ui-touch.sh"
  assert_file_contains "UG14: merge-policy requires Design-review PASS" "$policy" "## Design-review: PASS"

  # commands reference the leg + classifier
  assert_file_contains "UG15: improve playbook runs ui-touch.sh" "$PLUGIN_ROOT/references/workflows/improve.md" "scripts/ui-touch.sh"
  assert_file_contains "UG16: improve playbook references the leg" "$PLUGIN_ROOT/references/workflows/improve.md" "design-review-leg.md"
  assert_file_contains "UG17: maintain playbook references the leg" "$PLUGIN_ROOT/references/workflows/maintain.md" "design-review-leg.md"
  assert_file_contains "UG18: goal playbook references the leg" "$PLUGIN_ROOT/references/workflows/goal-deliver.md" "design-review-leg.md"
}
test_ui_gate
