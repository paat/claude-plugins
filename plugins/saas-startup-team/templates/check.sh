#!/usr/bin/env bash
# check.sh — canonical full-suite entrypoint for this project.
#
# This ONE script is what CI runs, what the tech-founder runs before every
# handoff, and what /improve runs. Local and CI cannot diverge because they
# call the same script by name.
#
# VERIFY COMPLETE: wire REQUIRED_SUITES + each suite below to your real
# commands — this gate FAILS until you do. Declare every suite your project
# has (backend, frontend, lint, typecheck, golden/integration). A suite you
# declare but leave unwired fails the run on purpose.
#
# LIMITATION: this proves each declared suite RAN and its command SUCCEEDED.
# It cannot prove a command was meaningful (e.g. a runner that exits 0 on
# "0 tests collected"). Wire real commands and add golden tests for
# computed-output correctness.

set -uo pipefail

# --- Declare which suites this project has (edit me) --------------------------
REQUIRED_SUITES=()

# --- Suite functions: replace each stub body with run_suite <label> '<cmd>' --
# Examples (uncomment + adapt):
#   frontend_tests() { run_suite frontend_tests 'npm test'; }
#   lint()           { run_suite lint 'npm run lint && npm run format:check'; }
#   backend_tests()  { run_suite backend_tests 'pytest -q'; }
#   typecheck()      { run_suite typecheck 'npx tsc --noEmit'; }
#   golden_tests()   { run_suite golden_tests 'npm run test:golden'; }
backend_tests()  { suite_stub backend_tests; }
frontend_tests() { suite_stub frontend_tests; }
lint()           { suite_stub lint; }
typecheck()      { suite_stub typecheck; }
golden_tests()   { suite_stub golden_tests; }

# --- Machinery (do not edit below) -------------------------------------------
RAN=()                 # suites that actually invoked run_suite
FAILED=()              # suites that failed (red command, or never ran)
declare -A STATUS      # label -> pass|fail (only set by run_suite)

suite_stub() {
  echo "  ✗ SUITE '$1' is declared in REQUIRED_SUITES but not wired up — edit check.sh"
  return 1
}

ran_contains() {
  local x="$1" r
  for r in "${RAN[@]:-}"; do [ "$r" = "$x" ] && return 0; done
  return 1
}

run_suite() {
  local label="$1" cmd="$2"
  RAN+=("$label")
  echo "  ▶ $label: $cmd"
  if bash -c "$cmd"; then
    echo "  ✓ $label passed"
    STATUS[$label]="pass"
    return 0
  else
    echo "  ✗ $label failed"
    STATUS[$label]="fail"
    return 1
  fi
}

main() {
  local suite

  # Guard 1: anti-vacuous — nothing declared at all (the freshly-scaffolded
  # state). Triggers before running so an empty manifest can never look green.
  local declared=0
  for suite in "${REQUIRED_SUITES[@]:-}"; do [ -n "$suite" ] && declared=$((declared+1)); done
  if [ "$declared" -eq 0 ]; then
    echo "check.sh: no suites ran — refusing to report success."
    echo "Declare and wire suites in REQUIRED_SUITES (see VERIFY COMPLETE banner)."
    exit 1
  fi

  # Run each declared suite. We judge by RAN + STATUS, not the function's raw
  # return, so a suite that returns 0 WITHOUT calling run_suite cannot slip by.
  for suite in "${REQUIRED_SUITES[@]:-}"; do
    [ -z "$suite" ] && continue
    "$suite" || true
  done

  # Guard 2: every declared suite must have actually run a command via
  # run_suite (catches both unwired suite_stub and a hand-edited `{ true; }`),
  # and any suite whose command failed is a failure.
  for suite in "${REQUIRED_SUITES[@]:-}"; do
    [ -z "$suite" ] && continue
    if ! ran_contains "$suite"; then
      echo "  ✗ SUITE '$suite' declared but never ran a command (Guard 2)"
      FAILED+=("$suite")
    elif [ "${STATUS[$suite]:-}" = "fail" ]; then
      FAILED+=("$suite")
    fi
  done

  if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "check.sh: FAILED suites: ${FAILED[*]}"
    exit 1
  fi

  echo "check.sh: all ${#RAN[@]} suite(s) passed: ${RAN[*]}"
  exit 0
}

main "$@"
