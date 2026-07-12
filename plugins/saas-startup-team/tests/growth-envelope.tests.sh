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
  write_envelope() {  # $1=root $2=monthly $3=expiry [$4=daily]
    jq -n --argjson monthly "$2" --argjson daily "${4:-20}" --arg expires "$3" '{
      monthly_cap_eur: $monthly,
      daily_cap_eur: $daily,
      channels: ["ads"],
      buyer_intent_only: true,
      authorized_by: "owner",
      authorized_at: "2026-01-01T00:00:00Z",
      expires_at: $expires
    }' > "$1/docs/growth/envelope.json"
  }

  # E1: active envelope, spend under monthly cap → allow. The envelope cap (200) is in
  # force, not the text line — text approved=100 < spend=150 would block on its own.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $150\n' > "$ads"
  write_envelope "$wd" 200 "2099-12-31T23:59:59Z"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E1: under envelope monthly cap allows write" "$ec" 0

  # E2: active envelope, spend at/over monthly cap → block (exit 2).
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Total spend: $150\n' > "$ads"
  write_envelope "$wd" 100 "2099-12-31T23:59:59Z"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E2: over envelope monthly cap blocks write" "$ec" 2

  # E3: expired envelope → ignored, falls back to the ads.md text line. The envelope cap
  # (500) would have allowed; the text cap (100) blocks — proving the fallback path.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $150\n' > "$ads"
  write_envelope "$wd" 500 "2000-01-01T00:00:00Z"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E3: expired envelope falls back to text cap (blocks)" "$ec" 2

  # E4: malformed envelope JSON → fail CLOSED (an existing-but-broken authorization file
  # must never fall back to a possibly-higher text cap). Spend is under the text cap, so
  # only the fail-closed path can block; no crash either way.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $50\n' > "$ads"
  printf '{ this is not json' > "$wd/docs/growth/envelope.json"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E4: malformed envelope fails closed (hard stop, no text fallback)" "$ec" 2

  # E5: no envelope at all → unchanged text-line behavior (fail closed). spend=150 >= 100.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $150\n' > "$ads"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E5: no envelope keeps text-line hard stop (blocks)" "$ec" 2

  # E7: EUR-formatted spend line must still be parsed (regression: a currency token before
  # the number used to yield spend=0 and silently bypass the hard stop). cap 100, spend 150.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Total spend: EUR 150\n' > "$ads"
  write_envelope "$wd" 100 "2099-12-31T23:59:59Z"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E7: EUR-formatted spend is parsed and blocks over cap" "$ec" 2

  # E8: a valid envelope with monthly_cap_eur:0 is authoritative (zero budget) and must NOT
  # fall back to a nonzero Approved budget: line — any spend is blocked.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $500\nTotal spend: $50\n' > "$ads"
  write_envelope "$wd" 0 "2099-12-31T23:59:59Z" 0
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E8: zero-cap envelope blocks (no fallback to text cap)" "$ec" 2

  # E9-E12: incomplete or relative authorization metadata never activates the envelope.
  # The high envelope cap would allow; the fallback text cap proves each case is rejected.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $150\n' > "$ads"
  write_envelope "$wd" 500 "tomorrow"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E9: relative expiry is rejected" "$ec" 2

  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $150\n' > "$ads"
  write_envelope "$wd" 500 "2099-12-31T23:59:59Z"
  jq 'del(.authorized_by)' "$wd/docs/growth/envelope.json" > "$wd/e" && mv "$wd/e" "$wd/docs/growth/envelope.json"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E10: missing owner authorization is rejected" "$ec" 2

  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $150\n' > "$ads"
  write_envelope "$wd" 500 "2099-12-31T23:59:59Z"
  jq '.authorized_at = "2099-01-01T00:00:00Z"' "$wd/docs/growth/envelope.json" > "$wd/e" && mv "$wd/e" "$wd/docs/growth/envelope.json"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E11: future authorization is rejected" "$ec" 2

  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $100\nTotal spend: $150\n' > "$ads"
  write_envelope "$wd" 500 "2099-12-31T23:59:59Z"
  jq '.channels = ["seo"]' "$wd/docs/growth/envelope.json" > "$wd/e" && mv "$wd/e" "$wd/docs/growth/envelope.json"
  ec=0; run_hook "$ads" || ec=$?
  assert_exit_code "E12: envelope without ads channel is rejected" "$ec" 2

  # E13: a legacy-shape envelope (pre-canonical fields) must fail CLOSED — never fall
  # back to a higher Approved-budget line. Spend is UNDER the text cap, so only the
  # fail-closed path can block here.
  wd="$(make_workdir)"; ads="$(setup_ads "$wd")"
  printf 'Approved budget: $500\nTotal spend: $50\n' > "$ads"
  printf '{"monthly_cap_eur":100,"expires_at":"2099-12-31T23:59:59Z"}\n' > "$wd/docs/growth/envelope.json"
  ec=0; out=$(printf '{"tool_input":{"file_path":"%s"}}' "$ads" | bash "$hook" 2>&1 >/dev/null) || ec=$?
  assert_exit_code "E13: legacy envelope fails closed, no text-cap fallback" "$ec" 2
  assert_output_contains "E13b: message names the invalid envelope" "$out" "invalid spend envelope"

  # E14/E15: validator contract directly — bounds and exit codes.
  wd="$(make_workdir)"
  mkdir -p "$wd/docs/growth"
  write_envelope "$wd" 200 "2099-12-31T23:59:59Z"
  ec=0; out=$(bash "$PLUGIN_ROOT/scripts/validate-spend-envelope.sh" --channel ads "$wd/docs/growth/envelope.json") || ec=$?
  assert_exit_code "E14: valid envelope exits 0" "$ec" 0
  assert_output_contains "E14b: normalized JSON is printed" "$out" '"monthly_cap_eur":200'
  jq '.monthly_cap_eur = 100000000000000000000' "$wd/docs/growth/envelope.json" > "$wd/e" && mv "$wd/e" "$wd/docs/growth/envelope.json"
  ec=0; bash "$PLUGIN_ROOT/scripts/validate-spend-envelope.sh" "$wd/docs/growth/envelope.json" >/dev/null 2>&1 || ec=$?
  assert_exit_code "E15: absurd cap beyond bounds is rejected" "$ec" 2

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
