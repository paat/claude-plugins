# Epic skill + epic_plan parser + active-epic marker (Phase 1 / 1.1.0).
declare -F assert_file_contains >/dev/null 2>&1 || {
  echo "epic.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_epic() {
  echo -e "\n${CYAN}Suite EP: serial epic conductor (Phase 1)${NC}"
  local skill="$PLUGIN_ROOT/skills/epic/SKILL.md"
  local inv="$PLUGIN_ROOT/docs/legacy/epic-invariants.md"
  local plan="$PLUGIN_ROOT/scripts/epic_plan.py"
  local active="$PLUGIN_ROOT/scripts/epic_active.py"
  local fix="$PLUGIN_ROOT/tests/fixtures/epic"
  local out ec line_count

  assert_file_exists "EP1: epic skill" "$skill"
  assert_file_exists "EP2: epic invariants" "$inv"
  assert_file_exists "EP3: epic_plan.py" "$plan"
  assert_file_exists "EP4: epic_active.py" "$active"
  assert_file_exists "EP5: aruannik fixture" "$fix/aruannik-1766.body.md"
  assert_file_exists "EP6: vastav fixture" "$fix/vastav-579.body.md"

  line_count=$(wc -l < "$skill" | tr -d ' ')
  if [ "$line_count" -le 80 ]; then
    assert_equals "EP7: SKILL.md ≤80 lines" "ok" "ok"
  else
    assert_equals "EP7: SKILL.md ≤80 lines (got $line_count)" "ok" "fail"
  fi

  assert_file_contains "EP8: serial concurrency" "$skill" 'concurrency=1'
  assert_file_contains "EP9: one branch" "$skill" 'epic/<n>-<slug>'
  assert_file_contains "EP10: epic_plan" "$skill" 'epic_plan.py'
  assert_file_contains "EP11: epic_active" "$skill" 'epic_active.py'
  assert_file_contains "EP12: deliver child" "$skill" 'skills/deliver/SKILL.md'
  assert_file_contains "EP13: tribunal hard-require" "$skill" 'tribunal-review must be available'
  assert_file_contains "EP14: no merge mid-child" "$skill" 'no merge to main'
  assert_file_contains "EP15: close after merge" "$skill" 'After merge succeeds'
  assert_file_contains "EP16: SAAS_EPIC_MODE" "$skill" 'SAAS_EPIC_MODE=1'
  assert_file_contains "EP17: honest incomplete" "$skill" '`incomplete`'
  assert_file_contains "EP18: no state machine" "$skill" 'No `.startup` state machine'
  assert_file_contains "EP19: plan-only flag" "$skill" '--plan'
  assert_file_contains "EP20b: invariants say serial only" "$inv" 'Serial only'

  assert_file_contains "EP22: deliver epic guard" \
    "$PLUGIN_ROOT/skills/deliver/SKILL.md" 'epic_active.py check'
  assert_file_contains "EP23: deliver epic mode no main merge" \
    "$PLUGIN_ROOT/skills/deliver/SKILL.md" 'SAAS_EPIC_MODE=1'
  assert_file_contains "EP24: maintain epic guard" \
    "$PLUGIN_ROOT/skills/maintain/SKILL.md" 'epic_active.py check'

  assert_file_contains "EP25: entrypoints has epic" \
    "$PLUGIN_ROOT/integrity/entrypoints.json" '"name": "epic"'
  assert_file_exists "EP26: generated command alias" "$PLUGIN_ROOT/commands/epic.md"
  assert_file_contains "EP27: command is generated alias" \
    "$PLUGIN_ROOT/commands/epic.md" 'GENERATED-ALIAS'
  assert_file_contains "EP28: command points at epic skill" \
    "$PLUGIN_ROOT/commands/epic.md" 'skills/epic/SKILL.md'

  out=$(python3 "$plan" --file "$fix/aruannik-1766.body.md")
  assert_equals "EP30: aruannik ok" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["ok"])')" "True"
  assert_equals "EP31: aruannik total 4" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counts"]["total"])')" "4"
  assert_equals "EP32: aruannik first #1749" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["children"][0]["number"])')" "1749"
  assert_equals "EP33: aruannik order" "$(echo "$out" | python3 -c 'import sys,json; print([c["number"] for c in json.load(sys.stdin)["children"]])')" "[1749, 1748, 1756, 1755]"
  assert_equals "EP34: track A captured" "$(echo "$out" | python3 -c 'import sys,json; print("Track A" in (json.load(sys.stdin)["children"][0]["track"] or ""))')" "True"

  out=$(python3 "$plan" --file "$fix/vastav-579.body.md")
  assert_equals "EP40: vastav ok" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["ok"])')" "True"
  assert_equals "EP41: vastav total 11" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["counts"]["total"])')" "11"
  assert_equals "EP42: vastav first #580" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["children"][0]["number"])')" "580"
  assert_equals "EP43: vastav last #590" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["children"][-1]["number"])')" "590"

  out=$(printf '%s\n' '### Track A' '- [x] #10 done item' '- [ ] #11 open item' | python3 "$plan")
  assert_equals "EP50: checked true" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["children"][0]["checked"])')" "True"
  assert_equals "EP51: unchecked false" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["children"][1]["checked"])')" "False"
  assert_equals "EP52: counts" "$(echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["counts"]["checked"], d["counts"]["unchecked"])')" "1 1"

  out=$(printf '%s\r\n' '- [ ] #42 crlf title' | python3 "$plan")
  assert_equals "EP53: CRLF parses" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["children"][0]["number"])')" "42"

  out=$(printf '%s\n' '```' '- [ ] #99 in fence' '```' '- [ ] #100 real' | python3 "$plan")
  assert_equals "EP54: fence ignored" "$(echo "$out" | python3 -c 'import sys,json; print([c["number"] for c in json.load(sys.stdin)["children"]])')" "[100]"

  out=$(printf '%s\n' '~~~' '- [ ] #98 tilde fence' '~~~' '- [ ] #101 real' | python3 "$plan")
  assert_equals "EP54b: tilde fence ignored" "$(echo "$out" | python3 -c 'import sys,json; print([c["number"] for c in json.load(sys.stdin)["children"]])')" "[101]"

  out=$(printf '%s\n' '```' '- [ ] #97 unclosed fence' | python3 "$plan" 2>/dev/null) || true
  # Unclosed fence → zero children fail-closed (or no #97)
  ec=0
  printf '%s\n' '```' '- [ ] #97 unclosed fence' | python3 "$plan" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EP54c: unclosed fence yields no children" "$ec" 1

  out=$(printf '%s\n' '<!-- - [ ] #77 hidden -->' '- [ ] #78 visible' | python3 "$plan")
  assert_equals "EP55: html comment ignored" "$(echo "$out" | python3 -c 'import sys,json; print([c["number"] for c in json.load(sys.stdin)["children"]])')" "[78]"

  ec=0
  printf '%s\n' '## Child issues' 'No checklist yet' | python3 "$plan" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EP60: zero children fails" "$ec" 1

  ec=0
  printf '%s\n' '- [ ] #1 a' '- [ ] #1 b' | python3 "$plan" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EP61: duplicate fails" "$ec" 1

  ec=0
  printf '%s\n' '- [ ] #1 and #2' | python3 "$plan" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EP62: multi-# fails" "$ec" 1

  ec=0
  printf '%s\n' '- [ ] org/repo#9 x' | python3 "$plan" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EP63: cross-repo fails" "$ec" 1

  ec=0
  printf '%s\n' '- [ ] see also #5 later' | python3 "$plan" >/dev/null 2>&1 || ec=$?
  assert_exit_code "EP64: non-leading # fails" "$ec" 1

  out=$(python3 "$active" marker --epic 1766 --body-sha deadbeef --children 1749,1748 | tr -d '\r')
  expected='<!-- saas-epic: 1766 sha=deadbeef children=1749,1748 -->'
  assert_equals "EP71: marker line" "$(echo "$out" | head -1)" "$expected"

  # --- epic_active check (fixture JSON; no network) ---
  local pr_json ec_out

  # Marked foreign PR → exit 3
  pr_json='[{"number":9,"headRefName":"epic/10-fx","body":"<!-- saas-epic: 10 sha=abc children=1,2 -->","url":"https://example/9"}]'
  ec=0
  out=$(EPIC_ACTIVE_PR_JSON="$pr_json" python3 "$active" check --repo t/r --branch main 2>/dev/null) || ec=$?
  assert_exit_code "EP72: marked foreign PR blocks" "$ec" 3
  assert_equals "EP72b: ok false" "$(echo "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["ok"])')" "False"
  assert_equals "EP72c: one blocker" "$(echo "$out" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["blockers"]))')" "1"

  # Same branch as marked epic → exit 0 (resume)
  pr_json='[{"number":9,"headRefName":"epic/10-fx","body":"<!-- saas-epic: 10 sha=abc children=1,2 -->","url":"https://example/9"}]'
  ec=0
  out=$(EPIC_ACTIVE_PR_JSON="$pr_json" python3 "$active" check --repo t/r --branch epic/10-fx 2>/dev/null) || ec=$?
  assert_exit_code "EP73: same-branch marked is ok" "$ec" 0
  assert_equals "EP73b: mine populated" "$(echo "$out" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["mine"]))')" "1"

  # Unmarked epic/* branch → advisory only, exit 0
  pr_json='[{"number":11,"headRefName":"epic/999-stale","body":"no marker here","url":"https://example/11"}]'
  ec=0
  out=$(EPIC_ACTIVE_PR_JSON="$pr_json" python3 "$active" check --repo t/r --branch main 2>/dev/null) || ec=$?
  assert_exit_code "EP74: unmarked epic/* does not block" "$ec" 0
  assert_equals "EP74b: zero blockers" "$(echo "$out" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["blockers"]))')" "0"
  assert_equals "EP74c: advisory listed" "$(echo "$out" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["advisory"]))')" "1"

  # Empty open list → ok
  ec=0
  out=$(EPIC_ACTIVE_PR_JSON='[]' python3 "$active" check --repo t/r --branch main 2>/dev/null) || ec=$?
  assert_exit_code "EP75: empty list ok" "$ec" 0

  # Malformed JSON → fail closed exit 1
  ec=0
  EPIC_ACTIVE_PR_JSON='not-json' python3 "$active" check --repo t/r --branch main >/dev/null 2>&1 || ec=$?
  assert_exit_code "EP76: malformed JSON fails closed" "$ec" 1

  # Non-list JSON → fail closed
  ec=0
  EPIC_ACTIVE_PR_JSON='{"nope":1}' python3 "$active" check --repo t/r --branch main >/dev/null 2>&1 || ec=$?
  assert_exit_code "EP77: non-list JSON fails closed" "$ec" 1

  out1=$(python3 "$plan" --file "$fix/aruannik-1766.body.md")
  out2=$(python3 "$plan" --file "$fix/aruannik-1766.body.md")
  assert_equals "EP80: deterministic" "$out1" "$out2"
}

test_epic
