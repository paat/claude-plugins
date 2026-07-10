# Sourced by run-tests.sh — pre-authorized spend envelope (#204).
# Covers scripts/check-ad-budget.sh envelope resolution + digest spend scrape.
# Uses the harness assert_* helpers and make_workdir.
test_growth_envelope() {
  echo -e "\n${CYAN}Suite: spend envelope (#204)${NC}"
  local hook="$PLUGIN_ROOT/scripts/check-ad-budget.sh"
  local digest="$PLUGIN_ROOT/scripts/digest.sh"
  local wd ads ec

  setup_ads() {  # $1=workdir → prints ads.md path
    mkdir -p "$1/docs/growth/channels"
    printf '%s/docs/growth/channels/ads.md' "$1"
  }
  run_hook() {  # $1=ads.md abs path → hook exit code via $ec
    printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$hook" >/dev/null 2>&1
  }

  # E1: active envelope, spend under monthly cap → allow. The envelope cap (200) is in
  # force, not the text line — text approved=100 < spend=150 would block on its own.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $150\n' > "$ads"
  printf '{"monthly_cap_eur":200,"expires_at":"2099-12-31T23:59:59Z"}' > "$wd/docs/growth/envelope.json"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E1: under envelope monthly cap allows write" "$ec" 0

  # E2: active envelope, spend at/over monthly cap → block (exit 2).
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Total spend: $150\n' > "$ads"
  printf '{"monthly_cap_eur":100,"expires_at":"2099-12-31T23:59:59Z"}' > "$wd/docs/growth/envelope.json"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E2: over envelope monthly cap blocks write" "$ec" 2

  # E3: expired envelope → ignored, falls back to the ads.md text line. The envelope cap
  # (500) would have allowed; the text cap (100) blocks — proving the fallback path.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $150\n' > "$ads"
  printf '{"monthly_cap_eur":500,"expires_at":"2000-01-01T00:00:00Z"}' > "$wd/docs/growth/envelope.json"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E3: expired envelope falls back to text cap (blocks)" "$ec" 2

  # E4: malformed envelope JSON → treated as absent, fall back to text; no crash. Text
  # approved=100, spend=50 → allow (exit 0).
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $50\n' > "$ads"
  printf '{ this is not json' > "$wd/docs/growth/envelope.json"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E4: malformed envelope treated as absent (no crash, allows)" "$ec" 0

  # E5: no envelope at all → unchanged text-line behavior (fail closed). spend=150 >= 100.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $150\n' > "$ads"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E5: no envelope keeps text-line hard stop (blocks)" "$ec" 2

  # E7: EUR-formatted spend line must still be parsed (regression: a currency token before
  # the number used to yield spend=0 and silently bypass the hard stop). cap 100, spend 150.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Total spend: EUR 150\n' > "$ads"
  printf '{"monthly_cap_eur":100,"expires_at":"2099-12-31T23:59:59Z"}' > "$wd/docs/growth/envelope.json"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E7: EUR-formatted spend is parsed and blocks over cap" "$ec" 2

  # E8: a valid envelope with monthly_cap_eur:0 is authoritative (zero budget) and must NOT
  # fall back to a nonzero Approved budget: line — any spend is blocked.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $500\nTotal spend: $50\n' > "$ads"
  printf '{"monthly_cap_eur":0,"expires_at":"2099-12-31T23:59:59Z"}' > "$wd/docs/growth/envelope.json"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E8: zero-cap envelope blocks (no fallback to text cap)" "$ec" 2

  # E6: the daily digest (#194) scrapes the growth pass's `- Spend:` line from a run
  # artifact into its Spend summary.
  wd="$(make_workdir)"
  mkdir -p "$wd/.startup/growth/runs"
  printf '# growth pass\n- Spend: EUR 12.50 — ads:acme-commercial-ee (envelope 20/200)\n' \
    > "$wd/.startup/growth/runs/run-1.md"
  bash "$digest" assemble --root "$wd" --date 2026-07-09 >/dev/null 2>&1 || true
  assert_file_contains "E6: growth spend line reaches the daily digest" \
    "$wd/.startup/digests/2026-07-09.md" "Spend: EUR 12.50 — ads:acme-commercial-ee"
}
test_growth_envelope
