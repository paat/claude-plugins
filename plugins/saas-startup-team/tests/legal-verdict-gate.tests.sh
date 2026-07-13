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
    verdict: CONFIRMED
    evidence_tier: A
    value: "2026-09-01"
    source_url: https://www.riigiteataja.ee/akt/123
    quote: "Seadus jõustub 2026. aasta 1. septembril."
    verified_at: 2026-07-10
    review_by: 2026-09-02
---

# Analysis

Body text. No verdict claim here.

## Inimülesanded

Puuduvad.
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

## Human Tasks

- Verify § 5 in primary source
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

  cat > "$dir/confirmed-ellipsized.md" <<'EOF'
---
verdict: UNCONFIRMED
evidence_tier: A
blocking_human_tasks: []
claims:
  - id: truncated-primary-quote
    verdict: CONFIRMED
    evidence_tier: A
    value: "required"
    source_url: https://www.riigiteataja.ee/akt/123
    quote: "Vastutav töötleja peab … rakendama meetmeid."
    verified_at: 2026-07-13
    review_by: 2026-10-13
---

# Analysis
EOF

  cat > "$dir/confirmed-bracketed-omission.md" <<'EOF'
---
verdict: UNCONFIRMED
evidence_tier: A
blocking_human_tasks: []
claims:
  - id: bracketed-primary-quote
    verdict: CONFIRMED
    evidence_tier: A
    value: "required"
    source_url: https://www.riigiteataja.ee/akt/123
    quote: "Vastutav töötleja peab [...] rakendama meetmeid."
---

# Analysis
EOF

  cat > "$dir/confirmed-fragment.md" <<'EOF'
---
verdict: UNCONFIRMED
evidence_tier: A
blocking_human_tasks: []
claims:
  - id: fragment-primary-quote
    verdict: CONFIRMED
    evidence_tier: A
    value: "required"
    source_url: https://eur-lex.europa.eu/example
    quote: "an online identifier"
---

# Analysis
EOF

  cat > "$dir/confirmed-colon-fragment.md" <<'EOF'
---
verdict: UNCONFIRMED
evidence_tier: A
blocking_human_tasks: []
claims:
  - id: colon-fragment
    verdict: CONFIRMED
    evidence_tier: A
    value: "required"
    source_url: https://eur-lex.europa.eu/example
    quote: "The controller shall provide:"
    verified_at: 2026-07-13
    review_by: 2026-10-13
---

# Analysis
EOF

  cat > "$dir/missing-claim-schema.md" <<'EOF'
---
verdict: UNCONFIRMED
evidence_tier: B
blocking_human_tasks: []
claims:
  - id: inherited-fields-are-invalid
    value: "pending"
    source_url: https://example.com/source
    quote: "Evidence remains pending."
    verified_at: 2026-07-13
    review_by: 2026-10-13
---

# Analysis
EOF

  cat > "$dir/confirmed-with-pending-claim.md" <<'EOF'
---
verdict: CONFIRMED
evidence_tier: A
blocking_human_tasks: []
claims:
  - id: pending-claim
    verdict: UNCONFIRMED
    evidence_tier: B
    value: "pending"
    source_url: https://example.com/source
    quote: "Evidence remains pending."
    verified_at: 2026-07-13
    review_by: 2026-10-13
---

# Analysis
EOF

  cat > "$dir/confirmed-tier-b.md" <<'EOF'
---
verdict: CONFIRMED
evidence_tier: B
blocking_human_tasks: []
claims:
  - id: confirmed-primary
    verdict: CONFIRMED
    evidence_tier: A
    value: "required"
    source_url: https://example.com/source
    quote: "Evidence is complete."
    verified_at: 2026-07-13
    review_by: 2026-10-13
---

# Analysis
EOF

  cat > "$dir/blank-claim-values.md" <<'EOF'
---
verdict: CONFIRMED
evidence_tier: A
blocking_human_tasks: []
claims:
  - id: blank-values
    verdict: CONFIRMED
    evidence_tier: A
    value: ""
    source_url: https://
    quote: "Evidence is complete."
    verified_at: ""
    review_by: ""
---

# Analysis
EOF

  cat > "$dir/malformed-claim-dates.md" <<'EOF'
---
verdict: UNCONFIRMED
evidence_tier: B
blocking_human_tasks: []
claims:
  - id: malformed-dates
    verdict: UNCONFIRMED
    evidence_tier: B
    value: "pending"
    source_url: https://example.com/source
    quote: "Evidence remains pending."
    verified_at: 2026-13-40
    review_by: tomorrow
---

# Analysis
EOF

  cat > "$dir/unbalanced-claim-scalars.md" <<'EOF'
---
verdict: CONFIRMED
evidence_tier: A
blocking_human_tasks: []
claims:
  - id: "unbalanced
    verdict: "CONFIRMED
    evidence_tier: "A
    value: "required
    source_url: "https://example.com/source
    quote: "Evidence is complete.
    verified_at: "2026-07-13
    review_by: "2026-10-13
---

# Analysis
EOF

  cat > "$dir/hostless-claim-source.md" <<'EOF'
---
verdict: CONFIRMED
evidence_tier: A
blocking_human_tasks: []
claims:
  - id: hostless-source
    verdict: CONFIRMED
    evidence_tier: A
    value: "required"
    source_url: https://?
    quote: "Evidence is complete."
    verified_at: 2026-07-13
    review_by: 2026-10-13
---

# Analysis
EOF

  cat > "$dir/body-human-task-mismatch.md" <<'EOF'
---
verdict: UNCONFIRMED
evidence_tier: A
blocking_human_tasks: []
claims: []
---

# Analysis

### Päriselt inimese otsused

- **[INIMENE — release owner]** Kinnita live-enable otsus.
EOF

  {
    printf '%s\n' '---' 'verdict: UNCONFIRMED' 'evidence_tier: B' \
      'blocking_human_tasks: []' 'claims: []' '---' '' '# Analysis'
    for _ in $(seq 1 151); do printf '%s\n' 'Evidence line.'; done
  } > "$dir/over-budget.md"

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
  assert_json_field "LVG1c2: confirmed-clean quote is valid" "$dir/out1.json" '.invalid_tier_a_quote' "false"

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
  assert_json_field "LVG4d: no-frontmatter is structurally invalid" "$dir/out4.json" '.schema_invalid' "true"

  # LVG5: missing file -> fail-closed, no crash
  ec=0; bash "$script" "$dir/does-not-exist.md" > "$dir/out5.json" 2>&1 || ec=$?
  assert_exit_code "LVG5: missing file does not crash" "$ec" 0
  assert_json_field "LVG5b: missing file hedged=true" "$dir/out5.json" '.hedged' "true"
  ec=0; bash "$script" --validate "$dir/does-not-exist.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG5c: validate rejects missing file" "$ec" 2

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
  ec=0; bash "$script" --validat "$dir/confirmed-clean.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG9b: misspelled option is a usage error" "$ec" 2

  # LVG10: CRLF line endings parse identically to LF
  printf -- '%s\r\n' '---' 'verdict: CONFIRMED' 'evidence_tier: A' \
    'blocking_human_tasks: []' 'claims:' '  - id: crlf-evidence' \
    '    verdict: CONFIRMED' '    evidence_tier: A' '    value: "required"' \
    '    source_url: https://example.com/source' '    quote: "Evidence is complete."' \
    '    verified_at: 2026-07-13' '    review_by: 2026-10-13' '---' '' \
    '# Analysis' > "$dir/crlf.md"
  bash "$script" "$dir/crlf.md" > "$dir/out10.json"
  assert_json_field "LVG10: CRLF doc verdict parsed" "$dir/out10.json" '.verdict' "CONFIRMED"
  assert_json_field "LVG10b: CRLF doc hedged=false" "$dir/out10.json" '.hedged' "false"

  cat > "$dir/empty-claims.md" <<'EOF'
---
verdict: CONFIRMED
evidence_tier: A
blocking_human_tasks: []
claims: []
---

# Analysis
EOF
  bash "$script" "$dir/empty-claims.md" > "$dir/out10c.json"
  assert_json_field "LVG10c: empty claims are structurally invalid" "$dir/out10c.json" '.schema_invalid' "true"
  ec=0; bash "$script" --validate "$dir/empty-claims.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG10d: validate rejects empty claims" "$ec" 2

  cat > "$dir/malformed-human-tasks.md" <<'EOF'
---
verdict: UNCONFIRMED
evidence_tier: B
blocking_human_tasks: null
claims:
  - id: pending
    verdict: UNCONFIRMED
    evidence_tier: B
    value: "pending"
    source_url: https://example.com/source
    quote: "Evidence remains pending."
    verified_at: 2026-07-13
    review_by: 2026-10-13
---

# Analysis
EOF
  bash "$script" "$dir/malformed-human-tasks.md" > "$dir/out10e.json"
  assert_json_field "LVG10e: malformed human-task list is invalid" "$dir/out10e.json" '.schema_invalid' "true"
  ec=0; bash "$script" --validate "$dir/malformed-human-tasks.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG10f: validate rejects malformed human-task list" "$ec" 2

  cat > "$dir/empty-inline-human-task.md" <<'EOF'
---
verdict: UNCONFIRMED
evidence_tier: B
blocking_human_tasks: [""]
claims:
  - id: pending
    verdict: UNCONFIRMED
    evidence_tier: B
    value: "pending"
    source_url: https://example.com/source
    quote: "Evidence remains pending."
    verified_at: 2026-07-13
    review_by: 2026-10-13
---

# Analysis
EOF
  bash "$script" "$dir/empty-inline-human-task.md" > "$dir/out10f.json"
  assert_json_field "LVG10f1: empty inline human task is invalid" "$dir/out10f.json" '.schema_invalid' "true"

  for item in 'task: approve' '123' ''; do
    file_tag=${item//[^a-z0-9]/-}
    [ -n "$file_tag" ] || file_tag=null
    {
      printf '%s\n' '---' 'verdict: UNCONFIRMED' 'evidence_tier: B' \
        'blocking_human_tasks:' "  - $item" 'claims:' '  - id: pending' \
        '    verdict: UNCONFIRMED' '    evidence_tier: B' '    value: "pending"' \
        '    source_url: https://example.com/source' '    quote: "Evidence remains pending."' \
        '    verified_at: 2026-07-13' '    review_by: 2026-10-13' '---' '' \
        '# Analysis' '' '## Human Tasks' '' "- $item"
    } > "$dir/block-item-$file_tag.md"
    bash "$script" "$dir/block-item-$file_tag.md" > "$dir/out-block-$file_tag.json"
    assert_json_field "LVG10g: non-string block item '$file_tag' is invalid" \
      "$dir/out-block-$file_tag.json" '.schema_invalid' "true"
  done

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

  # LVG13: omission marks cannot satisfy the verbatim Tier A quote contract.
  bash "$script" "$dir/confirmed-ellipsized.md" > "$dir/out13.json"
  assert_json_field "LVG13: ellipsized Tier A quote is invalid" "$dir/out13.json" '.invalid_tier_a_quote' "true"
  assert_json_field "LVG13b: ellipsized CONFIRMED claim is hedged" "$dir/out13.json" '.hedged' "true"
  ec=0; bash "$script" --enforce "$dir/confirmed-ellipsized.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG13c: enforce rejects ellipsized CONFIRMED claim" "$ec" 2

  bash "$script" "$dir/confirmed-bracketed-omission.md" > "$dir/out14.json"
  assert_json_field "LVG14: bracketed omission is invalid" "$dir/out14.json" '.invalid_tier_a_quote' "true"

  bash "$script" "$dir/confirmed-fragment.md" > "$dir/out15.json"
  assert_json_field "LVG15: sentence fragment is invalid" "$dir/out15.json" '.invalid_tier_a_quote' "true"

  bash "$script" "$dir/confirmed-colon-fragment.md" > "$dir/out15b.json"
  assert_json_field "LVG15b: colon fragment is invalid" "$dir/out15b.json" '.invalid_tier_a_quote' "true"

  bash "$script" "$dir/missing-claim-schema.md" > "$dir/out15c.json"
  assert_json_field "LVG15c: claims cannot inherit verdict or tier" "$dir/out15c.json" '.schema_invalid' "true"
  ec=0; bash "$script" --validate "$dir/missing-claim-schema.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG15d: validate rejects incomplete claim schema" "$ec" 2

  bash "$script" "$dir/confirmed-with-pending-claim.md" > "$dir/out15e.json"
  assert_json_field "LVG15e: pending nested claim propagates hedge" "$dir/out15e.json" '.claim_hedged' "true"
  assert_json_field "LVG15f: mixed claim verdicts cannot report clean confirmation" "$dir/out15e.json" '.hedged' "true"
  ec=0; bash "$script" --enforce "$dir/confirmed-with-pending-claim.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG15g: enforce rejects a pending nested claim" "$ec" 2

  bash "$script" "$dir/confirmed-tier-b.md" > "$dir/out15h.json"
  assert_json_field "LVG15h: document confirmation requires Tier A" "$dir/out15h.json" '.schema_invalid' "true"
  ec=0; bash "$script" --validate "$dir/confirmed-tier-b.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG15i: validate rejects confirmed Tier B summary" "$ec" 2

  bash "$script" "$dir/blank-claim-values.md" > "$dir/out15j.json"
  assert_json_field "LVG15j: blank claim values are schema-invalid" "$dir/out15j.json" '.schema_invalid' "true"
  assert_json_field "LVG15k: hostless confirmed source is invalid evidence" "$dir/out15j.json" '.invalid_tier_a_quote' "true"
  ec=0; bash "$script" --validate "$dir/blank-claim-values.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG15l: validate rejects blank claim values" "$ec" 2

  bash "$script" "$dir/malformed-claim-dates.md" > "$dir/out15m.json"
  assert_json_field "LVG15m: malformed claim dates are schema-invalid" "$dir/out15m.json" '.schema_invalid' "true"
  ec=0; bash "$script" --validate "$dir/malformed-claim-dates.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG15n: validate rejects malformed claim dates" "$ec" 2

  bash "$script" "$dir/unbalanced-claim-scalars.md" > "$dir/out15o.json"
  assert_json_field "LVG15o: unbalanced quoted scalars are invalid" "$dir/out15o.json" '.schema_invalid' "true"
  ec=0; bash "$script" --enforce "$dir/unbalanced-claim-scalars.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG15p: enforce rejects unbalanced quoted scalars" "$ec" 2

  bash "$script" "$dir/hostless-claim-source.md" > "$dir/out15q.json"
  assert_json_field "LVG15q: hostless HTTPS authority is invalid" "$dir/out15q.json" '.schema_invalid' "true"
  assert_json_field "LVG15r: hostless confirmed source is invalid evidence" "$dir/out15q.json" '.invalid_tier_a_quote' "true"
  ec=0; bash "$script" --validate "$dir/hostless-claim-source.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG15s: validate rejects hostless HTTPS authority" "$ec" 2

  bash "$script" "$dir/body-human-task-mismatch.md" > "$dir/out16.json"
  assert_json_field "LVG16: body-only human task mismatches frontmatter" "$dir/out16.json" '.human_task_mismatch' "true"
  ec=0; bash "$script" --validate "$dir/body-human-task-mismatch.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG16b: validate rejects human-task mismatch" "$ec" 2

  bash "$script" "$dir/confirmed-blocking.md" > "$dir/out17.json"
  assert_json_field "LVG17: matching human tasks pass parity" "$dir/out17.json" '.human_task_mismatch' "false"

  bash "$script" "$dir/over-budget.md" > "$dir/out18.json"
  assert_json_field "LVG18: oversized decision brief is reported" "$dir/out18.json" '.over_budget' "true"
  ec=0; bash "$script" --validate "$dir/over-budget.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG18b: validate rejects oversized decision brief" "$ec" 2

  ec=0; bash "$script" --validate "$dir/confirmed-clean.md" >/dev/null 2>&1 || ec=$?
  assert_exit_code "LVG19: validate accepts a structurally clean brief" "$ec" 0

  rm -rf "$dir"
}
test_legal_verdict_gate
