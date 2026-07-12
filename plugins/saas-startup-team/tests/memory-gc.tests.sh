# Sourced by run-tests.sh — memory lifecycle gc (#196): expiring-grant retirement,
# stale/contradiction flagging, weekly cursor, and the grant/sweep-back conventions.
# Uses the harness assert_* helpers + make_workdir. Date pinned via SAAS_GC_TODAY.
test_memory_gc() {
  echo -e "\n${CYAN}Suite: memory lifecycle gc (#196)${NC}"
  local gc="$PLUGIN_ROOT/scripts/memory-gc.sh"
  local wd report

  assert_file_exists "MG0: memory-gc.sh present" "$gc"

  # MG1: expired grant → retired; unexpired grant + ambiguous stale entry → untouched, flagged.
  wd=$(make_workdir)
  cat > "$wd/CLAUDE.md" <<'EOF'
# Project Learnings

## Learnings
- Grant: deploy prod access — scope: onboarding, expires: 2020-01-01
- Grant: keep this one — scope: durable, expires: 2999-01-01
- Old note: incident on 2000-05-05 long ago — context.
EOF
  report=$(SAAS_GC_TODAY=2026-07-09 bash "$gc" --root "$wd")
  assert_equals "MG1: report path echoed" "$report" "$wd/.startup/memory-gc/2026-07-09.md"
  assert_file_exists "MG1b: report written" "$report"
  assert_file_contains "MG1c: report lists retired grant" "$report" "Retired: expired grants — 1"
  assert_file_contains "MG1d: report flags stale entry" "$report" "Flagged: stale"
  assert_file_exists "MG1e: retired.md created" "$wd/docs/learnings/retired.md"
  assert_file_contains "MG1f: expired grant moved to retired.md" "$wd/docs/learnings/retired.md" "deploy prod access"
  assert_file_not_contains "MG1g: expired grant deleted from source" "$wd/CLAUDE.md" "deploy prod access"
  assert_file_contains "MG1h: unexpired grant untouched" "$wd/CLAUDE.md" "keep this one"
  assert_file_contains "MG1i: stale entry not deleted (flag-only)" "$wd/CLAUDE.md" "incident on 2000-05-05"

  # MG2: two bullets sharing a Label in one file → contradiction/near-duplicate flag.
  wd=$(make_workdir)
  cat > "$wd/CLAUDE.md" <<'EOF'
# Project Learnings

## Learnings
- Idempotency: retry only idempotent methods — safe.
- Idempotency: never retry POST — unsafe.
EOF
  report=$(SAAS_GC_TODAY=2026-07-09 bash "$gc" --root "$wd")
  assert_file_contains "MG2: near-duplicate labels flagged" "$report" "contradiction / near-duplicate — 2"

  # MG3: clean memory → no report file, exit 0, near-zero.
  wd=$(make_workdir)
  printf '# P\n\n## Learnings\n- Clean rule: do the thing — because reasons.\n' > "$wd/CLAUDE.md"
  local ec=0
  report=$(SAAS_GC_TODAY=2026-07-09 bash "$gc" --root "$wd") || ec=$?
  assert_exit_code "MG3: clean memory exit 0" "$ec" 0
  assert_equals "MG3b: clean memory prints no report path" "$report" ""
  assert_file_not_exists "MG3c: no report file on clean memory" "$wd/.startup/memory-gc/2026-07-09.md"

  # MG4: --weekly cursor — a second run inside 7 days is a no-op.
  wd=$(make_workdir)
  cat > "$wd/CLAUDE.md" <<'EOF'
# Project Learnings

## Learnings
- Grant: temp access — scope: x, expires: 2020-01-01
EOF
  SAAS_GC_TODAY=2026-07-09 bash "$gc" --root "$wd" --weekly >/dev/null
  assert_file_contains "MG4: weekly cursor recorded" "$wd/.startup/memory-gc/state.json" "2026-07-09"
  local out
  out=$(SAAS_GC_TODAY=2026-07-11 bash "$gc" --root "$wd" --weekly)
  assert_output_contains "MG4b: second run same week skips" "$out" "skipping"
  # A run past the 7-day window proceeds again.
  out=$(SAAS_GC_TODAY=2026-07-20 bash "$gc" --root "$wd" --weekly)
  assert_output_not_contains "MG4c: run after 7d not skipped" "$out" "skipping"

  # MG5: CLAUDE.md scope — grants outside '## Learnings' are ignored.
  wd=$(make_workdir)
  cat > "$wd/CLAUDE.md" <<'EOF'
# Project Learnings

## Setup
- Grant: unrelated — scope: x, expires: 2020-01-01

## Learnings
- Real rule: keep — because.
EOF
  ec=0
  report=$(SAAS_GC_TODAY=2026-07-09 bash "$gc" --root "$wd") || ec=$?
  assert_file_not_exists "MG5: no report — out-of-scope grant ignored" "$wd/.startup/memory-gc/2026-07-09.md"
  assert_file_contains "MG5b: out-of-scope grant left in place" "$wd/CLAUDE.md" "unrelated"

  # MG6: grant convention documented once in learnings-style.md.
  assert_file_contains "MG6: grant format documented" \
    "$PLUGIN_ROOT/templates/learnings-style.md" "expires:"

  # MG7: auto-learn hook carries grant-expiry + sweep-back instructions.
  assert_file_contains "MG7: auto-learn mentions grant expiry format" \
    "$PLUGIN_ROOT/scripts/auto-learn.sh" "expires:"
  assert_file_contains "MG7b: auto-learn spawns sweep-back task" \
    "$PLUGIN_ROOT/scripts/auto-learn.sh" "human-tasks.md"

  # MG8: /maintain runs the weekly gc leg.
  assert_file_contains "MG8: maintain invokes memory-gc" \
    "$PLUGIN_ROOT/references/workflows/maintain.md" "memory-gc.sh"

  # MG9: retirement is gated on the '- Grant:' shape — a durable rule merely mentioning an
  # 'expires:' date is flagged, never deleted (data-loss guard).
  wd=$(make_workdir)
  cat > "$wd/CLAUDE.md" <<'EOF'
# Project Learnings

## Learnings
- Token policy: rotate creds before they expires: 2020-01-01 — durable.
EOF
  report=$(SAAS_GC_TODAY=2026-07-09 bash "$gc" --root "$wd")
  assert_file_contains "MG9: non-grant expiry entry preserved" "$wd/CLAUDE.md" "Token policy"
  assert_file_not_exists "MG9b: no retired.md for non-grant" "$wd/docs/learnings/retired.md"
  assert_file_not_contains "MG9c: report has no retired section" "$report" "Retired: expired grants"

  # MG10: flagged line numbers point at the post-GC file (adjusted for deleted grants above).
  wd=$(make_workdir)
  cat > "$wd/CLAUDE.md" <<'EOF'
# Project Learnings

## Learnings
- Grant: temp — scope: x, expires: 2020-01-01
- Old note: incident on 2000-01-01 — context.
EOF
  report=$(SAAS_GC_TODAY=2026-07-09 bash "$gc" --root "$wd")
  assert_file_contains "MG10: stale line re-numbered post-deletion" "$report" "CLAUDE.md:4 — - Old note"

  # MG11: a flag without its value exits 2 (not a set -u crash).
  ec=0; SAAS_GC_TODAY=2026-07-09 bash "$gc" --root >/dev/null 2>&1 || ec=$?
  assert_exit_code "MG11: --root without value → exit 2" "$ec" 2
}
test_memory_gc
