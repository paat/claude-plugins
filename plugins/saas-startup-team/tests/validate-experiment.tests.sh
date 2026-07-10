# Sourced by run-tests.sh — demand-validation experiments (#205).
# Covers scripts/validate-experiment.sh: plan validation, fake-door render, the
# ad-smoke envelope gate, and the measured-only results writer.
# Uses the harness assert_* helpers and make_workdir.
test_validate_experiment() {
  echo -e "\n${CYAN}Suite: validate-experiment (#205)${NC}"
  local S="$PLUGIN_ROOT/scripts/validate-experiment.sh"
  local wd ec out

  write_plan() {  # $1=path  $2=extra jq merge (or "{}")
    jq -n --argjson x "$2" '{
      idea_id:"demand-alpha", value_prop:"Cut VAT filing to two minutes",
      audience:"Estonian micro-OU owners", cta:"Join the waitlist",
      signup_endpoint:"https://forms.example.test/waitlist",
      cap_eur:20, duration_days:7
    } * $x' > "$1"
  }

  # VE1: missing cap_eur → non-zero, and no output written (no side effects).
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{"cap_eur":null}'
  ec=0; out=$(bash "$S" validate "$wd/plan.json" 2>&1) || ec=$?
  assert_exit_code "VE1: plan missing cap_eur is rejected" "$ec" 2
  assert_output_contains "VE1b: names the missing field" "$out" "cap_eur"
  assert_file_not_exists "VE1c: validate wrote nothing" "$wd/docs"
  rm -rf "$wd"

  # VE1d: signup_endpoint null AND no fallback → rejected (never invents hosting).
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{"signup_endpoint":null}'
  ec=0; out=$(bash "$S" validate "$wd/plan.json" 2>&1) || ec=$?
  assert_exit_code "VE1d: null endpoint without fallback is rejected" "$ec" 2
  rm -rf "$wd"

  # VE1e: a non-https scheme on the signup target (javascript:) → rejected fail-closed.
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{"signup_endpoint":"javascript:alert(1)"}'
  ec=0; out=$(bash "$S" validate "$wd/plan.json" 2>&1) || ec=$?
  assert_exit_code "VE1e: javascript: signup target rejected" "$ec" 2
  rm -rf "$wd"

  # VE2: render from plan → index.html carries value_prop, cta, form → signup_endpoint.
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{}'
  ec=0; out=$(bash "$S" render "$wd/plan.json" --out-dir "$wd/out" 2>&1) || ec=$?
  assert_exit_code "VE2: render exits 0" "$ec" 0
  assert_file_exists "VE2b: index.html written" "$wd/out/index.html"
  assert_file_contains "VE2c: page carries value_prop" "$wd/out/index.html" "Cut VAT filing to two minutes"
  assert_file_contains "VE2d: page carries cta" "$wd/out/index.html" "Join the waitlist"
  assert_file_contains "VE2e: form targets signup_endpoint" "$wd/out/index.html" 'action="https://forms.example.test/waitlist"'
  # Honesty: a fake-door page must never take payment.
  assert_file_not_contains "VE2f: no password field on the fake-door" "$wd/out/index.html" "type=\"password\""
  assert_file_not_contains "VE2f2: no card-number field" "$wd/out/index.html" "cardnumber"
  assert_file_not_contains "VE2f3: no payment-provider embed" "$wd/out/index.html" "stripe"
  assert_file_contains "VE2g: consent wording present" "$wd/out/index.html" "no payment is taken"
  rm -rf "$wd"

  # VE3: ad-smoke without envelope.json → refused with an explanatory message.
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{}'
  ec=0; out=$(bash "$S" ad-smoke "$wd/plan.json" --landing-url "https://x.test" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "VE3: ad-smoke refuses without envelope" "$ec" 2
  assert_output_contains "VE3b: refusal explains the missing envelope" "$out" "envelope"
  rm -rf "$wd"

  # VE3c: expired envelope → refused (must be UNEXPIRED, per the epic dependency).
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{}'
  mkdir -p "$wd/docs/growth"
  printf '{"monthly_cap_eur":200,"buyer_intent_only":true,"channels":["ads"],"expires_at":"2000-01-01T00:00:00Z"}' \
    > "$wd/docs/growth/envelope.json"
  ec=0; out=$(bash "$S" ad-smoke "$wd/plan.json" --landing-url "https://x.test" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "VE3c: ad-smoke refuses on expired envelope" "$ec" 2
  rm -rf "$wd"

  # VE3d: remaining budget below cap_eur → refused. Monthly 30, already spent 15,
  # remaining 15 < cap 20.
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{}'
  mkdir -p "$wd/docs/growth/channels"
  printf '{"monthly_cap_eur":30,"buyer_intent_only":true,"channels":["ads"],"expires_at":"2099-12-31T23:59:59Z"}' \
    > "$wd/docs/growth/envelope.json"
  printf 'Total spend: EUR 15\n' > "$wd/docs/growth/channels/ads.md"
  ec=0; out=$(bash "$S" ad-smoke "$wd/plan.json" --landing-url "https://x.test" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "VE3d: ad-smoke refuses when remaining < cap" "$ec" 2
  rm -rf "$wd"

  # VE3e: a fractional cap must not authorize on a floored compare. Monthly 30, spent 10 →
  # remaining 20; cap 20.99 ceils to 21 > 20 → refused (fail closed).
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{"cap_eur":20.99}'
  mkdir -p "$wd/docs/growth/channels"
  printf '{"monthly_cap_eur":30,"buyer_intent_only":true,"channels":["ads"],"expires_at":"2099-12-31T23:59:59Z"}' \
    > "$wd/docs/growth/envelope.json"
  printf 'Total spend: EUR 10\n' > "$wd/docs/growth/channels/ads.md"
  ec=0; out=$(bash "$S" ad-smoke "$wd/plan.json" --landing-url "https://x.test" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "VE3e: fractional cap ceils, refuses when remaining below it" "$ec" 2
  rm -rf "$wd"

  # VE4: valid, unexpired, funded envelope → authorized (proves the gate is not always-refuse).
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{}'
  mkdir -p "$wd/docs/growth"
  printf '{"monthly_cap_eur":200,"buyer_intent_only":true,"channels":["ads"],"expires_at":"2099-12-31T23:59:59Z"}' \
    > "$wd/docs/growth/envelope.json"
  ec=0; out=$(bash "$S" ad-smoke "$wd/plan.json" --landing-url "https://x.test" --root "$wd" 2>&1) || ec=$?
  assert_exit_code "VE4: ad-smoke authorized within a funded envelope" "$ec" 0
  assert_output_contains "VE4b: authorization echoes the cap" "$out" "cap 20 EUR"
  rm -rf "$wd"

  # VE5: results writer — schema-exact, computed conversion, absent metric stays null.
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{}'
  # Signals carry visits + signups but NOT ad_spend_eur (unmeasured → must be null).
  printf '{"visits":200,"signups":10}' > "$wd/signals.json"
  ec=0; out=$(bash "$S" results "$wd/plan.json" --signals "$wd/signals.json" \
    --out "$wd/.startup/demand/experiments/demand-alpha-results.json" 2>&1) || ec=$?
  assert_exit_code "VE5: results writer exits 0" "$ec" 0
  local rf="$wd/.startup/demand/experiments/demand-alpha-results.json"
  assert_json_valid "VE5b: results is valid JSON" "$rf"
  assert_json_field "VE5c: idea_id echoed" "$rf" '.idea_id' "demand-alpha"
  assert_json_field "VE5d: evidence is measured-only" "$rf" '.evidence' "measured-only"
  assert_json_field "VE5e: visits measured" "$rf" '.measured.visits' "200"
  assert_json_field "VE5f: signups measured" "$rf" '.measured.signups' "10"
  assert_json_field "VE5g: unmeasured ad_spend stays null" "$rf" '.measured.ad_spend_eur' "null"
  assert_json_field "VE5h: conversion computed from measured values" "$rf" '.measured.conversion' "0.05"
  rm -rf "$wd"

  # VE5i: no visits measured → conversion cannot be computed → null (never estimated).
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{}'
  printf '{"signups":3}' > "$wd/signals.json"
  bash "$S" results "$wd/plan.json" --signals "$wd/signals.json" --out "$wd/r.json" >/dev/null 2>&1
  assert_json_field "VE5i: conversion null without measured visits" "$wd/r.json" '.measured.conversion' "null"
  assert_json_field "VE5j: absent visits stays null" "$wd/r.json" '.measured.visits' "null"
  rm -rf "$wd"

  # VE5k: a negative measured metric is rejected (cannot masquerade as evidence).
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{}'
  printf '{"visits":-5,"signups":2}' > "$wd/signals.json"
  ec=0; out=$(bash "$S" results "$wd/plan.json" --signals "$wd/signals.json" --out "$wd/r.json" 2>&1) || ec=$?
  assert_exit_code "VE5k: negative signal metric rejected" "$ec" 2
  rm -rf "$wd"

  # VE5l: a non-numeric measured metric is rejected.
  wd="$(make_workdir)"
  write_plan "$wd/plan.json" '{}'
  printf '{"visits":"lots"}' > "$wd/signals.json"
  ec=0; out=$(bash "$S" results "$wd/plan.json" --signals "$wd/signals.json" --out "$wd/r.json" 2>&1) || ec=$?
  assert_exit_code "VE5l: non-numeric signal metric rejected" "$ec" 2
  rm -rf "$wd"
}
test_validate_experiment
