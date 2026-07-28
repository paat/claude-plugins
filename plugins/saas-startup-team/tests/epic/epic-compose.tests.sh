# epic-scan + epic-compose-validate (upstream of /epic)
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "epic-compose.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_epic_compose() {
  echo -e "\n${CYAN}Suite EC: epic compose scan/validate${NC}"
  local skill="$PLUGIN_ROOT/skills/epic-compose/SKILL.md"
  local scan="$PLUGIN_ROOT/scripts/epic_scan.py"
  local val="$PLUGIN_ROOT/scripts/epic_compose_validate.py"
  local fix="$PLUGIN_ROOT/tests/fixtures/epic"
  local work out ec

  assert_file_exists "EC1: skill" "$skill"
  assert_file_exists "EC2: epic_scan.py" "$scan"
  assert_file_exists "EC3: epic_compose_validate.py" "$val"
  assert_file_exists "EC4: compose docs" "$PLUGIN_ROOT/docs/legacy/epic-compose.md"
  assert_file_contains "EC5: hands off to epic" "$skill" '/epic <n>'
  assert_file_contains "EC6: dry-run" "$skill" '--dry-run'
  assert_file_contains "EC7: no product implement" "$skill" 'No product implementation'
  assert_file_contains "EC8: entrypoint" \
    "$PLUGIN_ROOT/integrity/entrypoints.json" '"name": "epic-compose"'
  assert_file_exists "EC8b: command alias" "$PLUGIN_ROOT/commands/epic-compose.md"

  work=$(mktemp -d)
  cat > "$work/issues.json" <<'JSON'
[
  {"number": 10, "title": "Epic old", "body": "- [ ] #20\n- [ ] #21", "labels": [{"name": "epic"}], "state": "OPEN"},
  {"number": 20, "title": "child on epic", "body": "", "labels": [{"name": "bug"}], "state": "OPEN"},
  {"number": 30, "title": "FX zero row", "body": "", "labels": [{"name": "accounting"}, {"name": "bug"}], "state": "OPEN"},
  {"number": 31, "title": "FX skip reval", "body": "", "labels": [{"name": "accounting"}], "state": "OPEN"},
  {"number": 32, "title": "FX band", "body": "", "labels": [{"name": "accounting"}, {"name": "replay"}], "state": "OPEN"},
  {"number": 40, "title": "needs person", "body": "", "labels": [{"name": "needs-human"}], "state": "OPEN"},
  {"number": 50, "title": "lonely seo", "body": "", "labels": [{"name": "seo"}], "state": "OPEN"}
]
JSON

  out=$(python3 "$scan" --issues-file "$work/issues.json" --repo t/r)
  assert_equals "EC10: scan ok" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["ok"])')" "True"
  assert_equals "EC11: eligible count" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counts"]["eligible"])')" "4"
  # 30,31,32,50 — 20 claimed, 40 needs-human, 10 epic
  assert_equals "EC12: claimed" "$(echo "$out" | python3 -c 'import sys,json; print(sorted(json.load(sys.stdin)["excluded"]["on_open_epic"]))')" "[20]"
  assert_equals "EC13: open epics" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counts"]["open_epics"])')" "1"
  assert_equals "EC14: accounting cluster" "$(echo "$out" | python3 -c 'import sys,json; c=[x for x in json.load(sys.stdin)["suggested_clusters"] if x["label"]=="accounting"][0]; print(c["size"], c["children"])')" "3 [30, 31, 32]"

  echo "$out" > "$work/scan.json"
  cat > "$work/body.md" <<'MD'
# Epic: FX integrity cluster

## Why this epic
Shared FX unit safety.

## Done when / acceptance
- All three FX defects locked with tests

## Out of scope
- SEO

## Delivery order

### Track A — engine
- [ ] #30 — FX zero row
- [ ] #31 — FX skip reval

### Track B — reconciler
- [ ] #32 — FX band
MD

  out=$(python3 "$val" --body-file "$work/body.md" --scan-file "$work/scan.json")
  assert_equals "EC20: validate ok" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["ok"])')" "True"
  assert_equals "EC21: children" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["children"])')" "[30, 31, 32]"

  # claimed child rejected
  cat > "$work/bad.md" <<'MD'
# Epic: bad

## Done when
- x

## Delivery
- [ ] #20 — claimed
- [ ] #30 — ok
MD
  ec=0
  python3 "$val" --body-file "$work/bad.md" --scan-file "$work/scan.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EC22: claimed child fails validate" "$ec" 1

  # too few children
  cat > "$work/one.md" <<'MD'
# Epic: one

## Done when
- x

## Delivery
- [ ] #30 — only one
MD
  ec=0
  python3 "$val" --body-file "$work/one.md" --scan-file "$work/scan.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EC23: single child fails" "$ec" 1

  # monitor-nightly slimmed
  assert_file_contains "EC30: monitor cron moved" \
    "$PLUGIN_ROOT/skills/monitor-nightly/SKILL.md" 'monitor-nightly-cron.md'
  assert_file_exists "EC31: cron doc" "$PLUGIN_ROOT/docs/legacy/monitor-nightly-cron.md"

  rm -rf "$work"
}

test_epic_compose
