# Sourced by run-tests.sh — Hedge-propagation gate (issue #225 task 2):
# legal-verdict-gate.sh parses docs/legal/*.md verdict frontmatter and reports
# whether each doc is hedged. Uses harness assert_* helpers.
test_legal_verdict_gate() {
  echo -e "\n${CYAN}Suite: Hedge-propagation gate (legal-verdict-gate.sh)${NC}"
  local script="$PLUGIN_ROOT/scripts/legal-verdict-gate.sh"
  local dir out ec

  assert_file_exists "LVG0: legal-verdict-gate.sh present" "$script"

  dir=$(mktemp -d)

  cat > "$dir/confirmed-clean.md" <<'EOF'
---
verdict: CONFIRMED
evidence_tier: A
blocking_human_tasks: []
claims:
  - id: example
    value: "2026-09-01"
    source_url: https://www.riigiteataja.ee/akt/123
    quote: "Seadus jõustub 2026. aasta 1. septembril."
    verified_at: 2026-07-10
    review_by: 2026-09-02
---

# Analysis

Body text. No verdict claim here.
EOF

  cat > "$dir/confirmed-blocking.md" <<'EOF'
---
verdict: CONFIRMED
evidence_tier: A
blocking_human_tasks:
  - "Verify § 5 in primary source"
claims: []
---

# Analysis
EOF

  cat > "$dir/unverifiable.md" <<'EOF'
---
verdict: UNVERIFIABLE-IN-CORPUS
evidence_tier: B
blocking_human_tasks: []
claims: []
---

# Analysis
EOF

  cat > "$dir/no-frontmatter.md" <<'EOF'
# Analysis

No frontmatter at all here. verdict: CONFIRMED (this is prose, not YAML).
EOF

  cat > "$dir/body-verdict-string.md" <<'EOF'
---
verdict: UNCONFIRMED
evidence_tier: C
blocking_human_tasks: []
claims: []
---

# Analysis

An earlier draft said "verdict: CONFIRMED" here — this must not be parsed as
the real verdict since it is outside the frontmatter block.
EOF

  # LVG1: CONFIRMED + empty blocking list -> not hedged, --enforce exit 0
  bash "$script" "$dir/confirmed-clean.md" > "$dir/out1.json"
  assert_json_field "LVG1: confirmed-clean verdict" "$dir/out1.json" '.verdict' "CONFIRMED"
  assert_json_field "LVG1b: confirmed-clean blocking count" "$dir/out1.json" '.blocking_human_tasks' "0"
  assert_json_field "LVG1c: confirmed-clean hedged=false" "$dir/out1.json" '.hedged' "false"

  ec=0; bash "$script" --enforce "$dir/confirmed-clean.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG1d: --enforce exit 0 on clean CONFIRMED" "$ec" 0

  # LVG2: CONFIRMED + non-empty (block-list) blocking tasks -> hedged
  bash "$script" "$dir/confirmed-blocking.md" > "$dir/out2.json"
  assert_json_field "LVG2: confirmed-blocking verdict" "$dir/out2.json" '.verdict' "CONFIRMED"
  assert_json_field "LVG2b: confirmed-blocking count=1" "$dir/out2.json" '.blocking_human_tasks' "1"
  assert_json_field "LVG2c: confirmed-blocking hedged=true" "$dir/out2.json" '.hedged' "true"

  # LVG3: UNVERIFIABLE-IN-CORPUS -> hedged
  bash "$script" "$dir/unverifiable.md" > "$dir/out3.json"
  assert_json_field "LVG3: unverifiable verdict" "$dir/out3.json" '.verdict' "UNVERIFIABLE-IN-CORPUS"
  assert_json_field "LVG3b: unverifiable hedged=true" "$dir/out3.json" '.hedged' "true"

  # LVG4: no frontmatter -> fail-closed, no crash
  ec=0; bash "$script" "$dir/no-frontmatter.md" > "$dir/out4.json" 2>&1 || ec=$?
  assert_exit_code "LVG4: no-frontmatter does not crash" "$ec" 0
  assert_json_field "LVG4b: no-frontmatter verdict fail-closed" "$dir/out4.json" '.verdict' "UNCONFIRMED"
  assert_json_field "LVG4c: no-frontmatter hedged=true" "$dir/out4.json" '.hedged' "true"

  # LVG5: missing file -> fail-closed, no crash
  ec=0; bash "$script" "$dir/does-not-exist.md" > "$dir/out5.json" 2>&1 || ec=$?
  assert_exit_code "LVG5: missing file does not crash" "$ec" 0
  assert_json_field "LVG5b: missing file hedged=true" "$dir/out5.json" '.hedged' "true"

  # LVG6: a "verdict:" string in the body (outside frontmatter) must not be picked up
  bash "$script" "$dir/body-verdict-string.md" > "$dir/out6.json"
  assert_json_field "LVG6: body verdict string ignored" "$dir/out6.json" '.verdict' "UNCONFIRMED"

  # LVG7: --enforce exit 2 on a hedged doc
  ec=0; bash "$script" --enforce "$dir/confirmed-blocking.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG7: --enforce exit 2 on hedged doc" "$ec" 2

  # LVG8: multiple docs, mixed hedged/clean -> one JSON line per doc; enforce
  # reflects any hedged doc in the set
  bash "$script" "$dir/confirmed-clean.md" "$dir/confirmed-blocking.md" > "$dir/out8.jsonl"
  assert_equals "LVG8: two docs -> two JSON lines" "$(wc -l < "$dir/out8.jsonl" | tr -d ' ')" "2"
  ec=0; bash "$script" --enforce "$dir/confirmed-clean.md" "$dir/confirmed-blocking.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG8b: --enforce exit 2 when any doc in the set is hedged" "$ec" 2

  # LVG9: usage error (no docs given) -> non-zero exit, no crash
  ec=0; bash "$script" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG9: no docs given -> exit 2" "$ec" 2

  # LVG10: CRLF line endings parse identically to LF
  printf -- '---\r\nverdict: CONFIRMED\r\nevidence_tier: A\r\nblocking_human_tasks: []\r\nclaims: []\r\n---\r\n\r\n# Analysis\r\n' > "$dir/crlf.md"
  bash "$script" "$dir/crlf.md" > "$dir/out10.json"
  assert_json_field "LVG10: CRLF doc verdict parsed" "$dir/out10.json" '.verdict' "CONFIRMED"
  assert_json_field "LVG10b: CRLF doc hedged=false" "$dir/out10.json" '.hedged' "false"

  # LVG11: inline non-empty blocking_human_tasks list -> hedged
  cat > "$dir/inline-blocking.md" <<'EOF'
---
verdict: CONFIRMED
evidence_tier: A
blocking_human_tasks: ["verify paragraph in RT", "confirm date with EMTA"]
claims: []
---

# Analysis
EOF
  bash "$script" "$dir/inline-blocking.md" > "$dir/out11.json"
  assert_json_field "LVG11: inline list count=2" "$dir/out11.json" '.blocking_human_tasks' "2"
  assert_json_field "LVG11b: inline list hedged=true" "$dir/out11.json" '.hedged' "true"

  # LVG12: inline single-item list whose task string contains a comma ->
  # must count as 1, not 2 (a plain awk -F',' split would miscount this).
  cat > "$dir/inline-comma-task.md" <<'EOF'
---
verdict: CONFIRMED
evidence_tier: A
blocking_human_tasks: ["confirm with counsel, then file with EMTA"]
claims: []
---

# Analysis
EOF
  bash "$script" "$dir/inline-comma-task.md" > "$dir/out12.json"
  assert_json_field "LVG12: inline single task with comma -> count=1" "$dir/out12.json" '.blocking_human_tasks' "1"
  assert_json_field "LVG12b: inline single task with comma -> hedged=true" "$dir/out12.json" '.hedged' "true"

  rm -rf "$dir"
}
test_legal_verdict_gate
