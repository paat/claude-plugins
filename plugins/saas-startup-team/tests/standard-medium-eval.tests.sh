# Meta runtime surfaces removed (#390). Sourced by tests/run-tests.sh.
declare -F assert_file_not_exists >/dev/null 2>&1 || {
  echo "standard-medium-eval.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_meta_runtime_removed() {
  echo -e "\n${CYAN}Suite META: self-improvement/telemetry/eval removed (#390)${NC}"

  local missing=(
    scripts/standard-medium-eval.sh
    scripts/agent-events.sh
    scripts/agent-events-export.sh
    scripts/agent-events-aggregate.sh
    scripts/harvest.sh
    scripts/session-insights.sh
    scripts/lesson-auto-review.sh
    scripts/lesson-file.sh
    scripts/lesson-review.sh
    scripts/lesson-review-binding.sh
    scripts/lessons-deliver.sh
    scripts/auto-learn.sh
    commands/harvest.md
    commands/session-insights.md
    commands/lessons-review.md
    commands/lessons-deliver.md
    commands/learnings-migrate.md
    commands/learnings-compress.md
    references/schemas/lesson-auto-review.schema.json
    references/workflows/routing-telemetry.md
    templates/learnings-style.md
    templates/learnings-compress-golden.md
    docs/design/self-improvement-loop.md
    docs/design/lessons-deliver.md
  )
  local p
  for p in "${missing[@]}"; do
    assert_file_not_exists "META: $p deleted" "$PLUGIN_ROOT/$p"
  done

  # Generated aliases / skills for removed commands must not reappear.
  local skills=(
    skills/saas-startup-team-harvest-workflow
    skills/saas-startup-team-session-insights-workflow
    skills/saas-startup-team-lessons-review-workflow
    skills/saas-startup-team-lessons-deliver-workflow
    skills/saas-startup-team-learnings-migrate-workflow
    skills/saas-startup-team-learnings-compress-workflow
  )
  for p in "${skills[@]}"; do
    assert_file_not_exists "META: $p deleted" "$PLUGIN_ROOT/$p"
  done

  # Entrypoint manifest must not list removed names.
  local names
  names=$(jq -r '.entrypoints[].name' "$PLUGIN_ROOT/integrity/entrypoints.json")
  assert_output_not_contains "META: no harvest entrypoint" "$names" "harvest"
  assert_output_not_contains "META: no session-insights entrypoint" "$names" "session-insights"
  assert_output_not_contains "META: no lessons-deliver entrypoint" "$names" "lessons-deliver"
  assert_output_not_contains "META: no lessons-review entrypoint" "$names" "lessons-review"
  assert_output_not_contains "META: no learnings-migrate entrypoint" "$names" "learnings-migrate"
  assert_output_not_contains "META: no learnings-compress entrypoint" "$names" "learnings-compress"

  # Hooks must not call auto-learn.
  local hooks
  hooks=$(cat "$PLUGIN_ROOT/hooks/hooks.json")
  assert_output_not_contains "META: hooks omit auto-learn" "$hooks" "auto-learn.sh"

  # Runtime surfaces (excluding tests/ and docs/) must not reference deleted scripts.
  # Scan all text-like runtime files (sh/md/json/py/yml/toml/txt) so generators and
  # helpers cannot reintroduce silent callers (#390 Codex review).
  local hits
  hits=$(grep -RInE \
    'agent-events(\.sh|-export|-aggregate)|standard-medium-eval\.sh|session-insights\.sh|harvest\.sh|lesson-auto-review\.sh|lesson-file\.sh|lesson-review(-binding)?\.sh|lessons-deliver\.sh|auto-learn\.sh|routing-telemetry\.md|lesson-auto-review\.schema' \
    "$PLUGIN_ROOT" \
    --include='*.sh' --include='*.md' --include='*.json' --include='*.py' \
    --include='*.yml' --include='*.yaml' --include='*.toml' --include='*.txt' \
    --exclude-dir=tests --exclude-dir=docs 2>/dev/null || true)
  # migration note in README may name removed commands; allow only the migration doc path
  # and README "Removed in" notice. Filter those out.
  hits=$(printf '%s\n' "$hits" | grep -vE 'README\.md|migration-1\.0-meta-removed\.md' || true)
  if [ -n "$hits" ]; then
    echo -e "  ${RED}FAIL${NC} META: residual runtime references"
    printf '%s\n' "$hits" | head -40
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    FAILURES+=("META: residual runtime references")
  else
    echo -e "  ${GREEN}PASS${NC} META: no residual runtime script references"
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
  fi

  # Maintain v3 release facts remain the privacy-safe terminal evidence path.
  assert_file_contains "META: maintain-v3 release-facts" \
    "$PLUGIN_ROOT/scripts/maintain-v3.sh" "release-facts"
  assert_file_contains "META: migration lists removed commands" \
    "$PLUGIN_ROOT/docs/legacy/migration-1.0-meta-removed.md" "/harvest"
  assert_file_contains "META: migration states no in-plugin replacement" \
    "$PLUGIN_ROOT/docs/legacy/migration-1.0-meta-removed.md" "no in-plugin replacement"
}

# Keep old name so existing sources still call something if referenced.
test_standard_medium_eval() {
  test_meta_runtime_removed
}

test_standard_medium_eval
