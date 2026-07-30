# Sourced by run-tests.sh: sensitive-surface risk floor (no model regex routing).

test_delivery_routing() {
  echo -e "\n${CYAN}Suite: delivery risk floor and cast adapter surface${NC}"
  local route="$PLUGIN_ROOT/scripts/delivery-route.sh"
  local cast="$PLUGIN_ROOT/scripts/codex-cast.sh"
  local wd task labels out ec repo

  assert_file_exists "DR1: delivery router exists" "$route"
  assert_file_exists "DR2: codex-cast adapter exists" "$cast"
  assert_file_not_exists "DR2b: codex-run-role removed" "$PLUGIN_ROOT/scripts/codex-run-role.sh"
  assert_file_not_exists "DR2c: codex-implement removed" "$PLUGIN_ROOT/scripts/codex-implement.sh"
  assert_file_not_contains "DR2d: router has no CSS parser" "$route" 'ui_stylesheet_diff'
  assert_file_not_contains "DR2e: router has no markup parser" "$route" 'ui_markup_diff'
  assert_file_not_contains "DR2f: router has no light profile path" "$route" 'profile=light'
  assert_file_not_contains "DR2g: router has no mechanical script route" "$route" 'script_only'
  assert_equals "DR3: routing schema probe" "$(bash "$route" schema-version | jq -r .schema_version)" "1"

  wd=$(mktemp -d)
  task="$wd/task.txt"; labels="$wd/labels.txt"

  printf '%s\n' 'Fix the typo in docs/setup.md.' > "$task"
  out=$(bash "$route" classify --mode autonomous --task-file "$task")
  assert_equals "DR4: non-sensitive is standard (harness picks model)" \
    "$(jq -r .profile <<<"$out")" "standard"
  assert_equals "DR4b: not sensitive" "$(jq -r .sensitive <<<"$out")" "false"

  printf '%s\n' 'Prepare dependencies in a disposable candidate checkout.' \
    'Implementation contract: do not commit.' \
    'Prepare dependencies in a git checkout.' \
    'Prepare dependencies in a disposable checkout.' \
    'Interface contract: do not commit.' \
    'API contract: do not commit.' > "$task"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "DR4c: tooling checkout and contract stay standard" "$ec" 0
  assert_equals "DR4d: tooling checkout and contract are not sensitive" \
    "$(jq -r .sensitive <<<"$out")" "false"
  assert_equals "DR4e: tooling checkout and contract need no product judgment" \
    "$(jq -r .requires_product_judgment <<<"$out")" "false"
  assert_equals "DR4f: tooling checkout and contract need no legal judgment" \
    "$(jq -r .requires_legal_judgment <<<"$out")" "false"
  assert_equals "DR4g: tooling checkout and contract clear the risk floor" \
    "$(jq -r '.reasons | join(",")' <<<"$out")" "risk_floor_clear"

  printf '%s\n' 'Fix typo in payment amount label in a candidate checkout.' > "$task"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "DR5: payment label escalates" "$ec" 20
  assert_equals "DR6: payment precedence is deep" "$(jq -r .profile <<<"$out")" "deep"
  assert_equals "DR7: payment is sensitive" "$(jq -r .sensitive <<<"$out")" "true"

  printf '%s\n' 'Repair the broken link in the auth email.' > "$task"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "DR8: auth email link escalates" "$ec" 20
  assert_equals "DR9: auth is deep" "$(jq -r .profile <<<"$out")" "deep"

  printf '%s\n' 'Adjust two pixels of CSS spacing.' > "$task"
  out=$(bash "$route" classify --mode autonomous --task-file "$task")
  assert_equals "DR10: CSS is standard (no light routing)" "$(jq -r .profile <<<"$out")" "standard"
  out=$(bash "$route" classify --mode interactive-tweak --task-file "$task")
  assert_equals "DR11: interactive CSS is standard" "$(jq -r .profile <<<"$out")" "standard"

  printf '%s\n' 'Update the GDPR implementation contract.' > "$task"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "DR13: legal judgment escalates" "$ec" 20
  assert_equals "DR14: legal judgment is explicit" "$(jq -r .requires_legal_judgment <<<"$out")" "true"

  printf '%s\n' 'Fix a bounded parser bug.' > "$task"
  printf '%s\n' 'security' > "$labels"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task" --labels-file "$labels") || ec=$?
  assert_exit_code "DR15: sensitive label overrides routine task" "$ec" 20

  printf '%s\n' 'Fix a bounded parser bug.' > "$task"
  printf '%s\n' '[{"name":"accounting"},{"name":"andmesild"}]' > "$labels"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task" --labels-file "$labels") || ec=$?
  assert_exit_code "DR15a1: accounting JSON labels escalate" "$ec" 20
  assert_equals "DR15a2: accounting selects deep" "$(jq -r .profile <<<"$out")" "deep"
  assert_equals "DR15a3: accounting reason present" \
    "$(jq -r '.reasons | index("sensitive_accounting_reporting") != null' <<<"$out")" "true"

  for sensitive_signal in XBRL Arelle taxonomy 'financial reporting'; do
    printf 'Repair the %s validation adapter.\n' "$sensitive_signal" > "$task"
    ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
    assert_exit_code "DR15a4: $sensitive_signal escalates" "$ec" 20
  done

  printf '%s\n' 'Fix typo in PII-labelled docs.' > "$task"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "DR15f: PII escalates" "$ec" 20
  assert_equals "DR15g: PII is sensitive" "$(jq -r .sensitive <<<"$out")" "true"

  # check-diff: empty and sensitive
  repo=$(mktemp -d)
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  printf 'base\n' > "$repo/app.txt"
  git -C "$repo" add app.txt
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)

  out=$(cd "$repo" && bash "$route" check-diff --base "$base")
  assert_equals "DR20: empty diff is mechanical" "$(jq -r .profile <<<"$out")" "mechanical"

  printf 'changed\n' > "$repo/app.txt"
  out=$(cd "$repo" && bash "$route" check-diff --base "$base")
  assert_equals "DR21: routine product diff is standard" "$(jq -r .profile <<<"$out")" "standard"

  mkdir -p "$repo/auth"
  printf 'token\n' > "$repo/auth/session.ts"
  git -C "$repo" add auth/session.ts
  # unstaged content still in tree; commit then dirty sensitive path
  git -C "$repo" commit -qm auth
  base2=$(git -C "$repo" rev-parse HEAD)
  printf 'password = secret\n' > "$repo/auth/session.ts"
  ec=0
  out=$(cd "$repo" && bash "$route" check-diff --base "$base2") || ec=$?
  assert_exit_code "DR22: sensitive path/content escalates" "$ec" 20
  assert_equals "DR23: sensitive diff deep" "$(jq -r .profile <<<"$out")" "deep"

  # deliver skill still points at cast, not nested controllers
  assert_file_contains "DR40: deliver graph references codex-cast or host-native" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" 'codex-cast'
  assert_file_not_contains "DR41: no tech-founder-codex controller guidance" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" 'tech-founder-codex'
  assert_file_not_contains "DR42: no codex-run-role in graph" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" 'codex-run-role'
  assert_file_not_contains "DR43: no codex-implement in graph" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" 'codex-implement'
  assert_file_contains "DR44: conductor must not implement" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" 'must not implement'
  assert_file_contains "DR45: isolated-build-assert required" \
    "$PLUGIN_ROOT/references/delivery-playbook.md" 'isolated-build-assert.py'
  assert_file_exists "DR46: isolated-build-assert script" \
    "$PLUGIN_ROOT/scripts/isolated-build-assert.py"

  rm -rf "$wd" "$repo"
}

test_delivery_routing
