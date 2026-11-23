#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

test_required_checks() {
  local work fake sha out ec mutated
  local scenario branch rules checks error expected predicate args
  work="$(mktemp -d)"; fake="$work/bin"; mkdir -p "$fake"
  sha="$(python3 -c 'print("a" * 40)')"

  cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
# required-checks.sh must force plain JSON (no ANSI / forced TTY).
if [ "${NO_COLOR:-}" != "1" ] || [ "${CLICOLOR_FORCE:-}" != "0" ] || [ -n "${GH_FORCE_TTY:-}" ]; then
  printf 'gh colour env leaked: NO_COLOR=%s CLICOLOR_FORCE=%s GH_FORCE_TTY=%s\n' \
    "${NO_COLOR-}" "${CLICOLOR_FORCE-}" "${GH_FORCE_TTY-}" >&2
  exit 99
fi
if [ "$1" != api ]; then
  printf 'unexpected gh invocation: %s\n' "$*" >&2
  exit 2
fi
# Reject gh pr checks as the only source — REST check-runs only.
for arg in "$@"; do
  case "$arg" in
    pr|checks)
      printf 'forbidden gh pr checks path: %s\n' "$*" >&2
      exit 2
      ;;
  esac
done
endpoint=""
for arg in "$@"; do
  case "$arg" in
    repos/*) endpoint="$arg" ;;
  esac
done
[ -n "$endpoint" ] || { printf 'missing REST endpoint: %s\n' "$*" >&2; exit 2; }
printf '%s\n' "$endpoint" >> "${FIXTURE_CALLS:-/dev/null}"
case "$endpoint" in
  repos/example/fixture)
    if [ "${FIXTURE_ERROR:-}" = default ]; then
      printf 'repository unavailable\n' >&2; exit 1
    fi
    printf '%s\n' '{"default_branch":"main"}'
    exit 0
    ;;
  repos/example/fixture/rules/branches/*)
    if [ "${FIXTURE_ERROR:-}" = rules ]; then
      printf 'rules unavailable (HTTP 403)\n' >&2; exit 1
    fi
    printf '%s\n' "${FIXTURE_RULES:-[]}"
    exit 0
    ;;
  repos/example/fixture/branches/*)
    if [ "${FIXTURE_ERROR:-}" = protection ]; then
      printf 'branch unavailable (HTTP 404)\n' >&2; exit 1
    fi
    if [ -n "${FIXTURE_BRANCH:-}" ]; then
      printf '%s\n' "$FIXTURE_BRANCH"
    else
      printf '%s\n' '{"protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}'
    fi
    exit 0
    ;;
  repos/example/fixture/actions/workflows*)
    printf '%s\n' '{"workflows":[{"state":"active"}]}'
    exit 0
    ;;
  repos/example/fixture/commits/*/status)
    printf '%s\n' '{"total_count":0,"statuses":[]}'
    exit 0
    ;;
  repos/example/fixture/commits/*/check-runs*) ;;
  *) printf 'unexpected endpoint: %s\n' "$endpoint" >&2; exit 2 ;;
esac

case "${FIXTURE_CHECKS:-empty}" in
  configured_extra_failure)
    jq -nc '{check_runs:[
      {name:"payment-contract",status:"completed",conclusion:"success"},
      {name:"regression-test-gate",status:"completed",conclusion:"success"},
      {name:"full-regression",status:"completed",conclusion:"success"},
      {name:"optional",status:"completed",conclusion:"failure"}
    ]} | .total_count = (.check_runs | length)'
    ;;
  issue_missing|issue_success|issue_pending|issue_failure|issue_skipped|issue_neutral)
    jq -nc --arg fixture "$FIXTURE_CHECKS" '{check_runs:([
      {name:"payment-contract",status:"completed",conclusion:"success"},
      {name:"regression-test-gate",status:"completed",conclusion:"success"}
    ] + (if $fixture == "issue_missing" then [] else [{
      name:"full-regression",
      status:(if $fixture == "issue_pending" then "queued" else "completed" end),
      conclusion:(if $fixture == "issue_pending" then null else ($fixture | sub("issue_"; "")) end)
    }] end))} | .total_count = (.check_runs | length)'
    ;;
  empty)
    jq -nc '{total_count:0,check_runs:[]}'
    ;;
  failed)
    jq -nc '{total_count:2,check_runs:[
      {name:"unit",status:"completed",conclusion:"success"},
      {name:"lint",status:"completed",conclusion:"failure"}
    ]}'
    ;;
  pending)
    jq -nc '{total_count:2,check_runs:[
      {name:"unit",status:"completed",conclusion:"success"},
      {name:"build",status:"in_progress",conclusion:null}
    ]}'
    ;;
  success)
    # Em-dash in a check name must survive JSON output (no ensure_ascii escape).
    jq -nc '{total_count:2,check_runs:[
      {name:"unit — core",status:"completed",conclusion:"success"},
      {name:"lint",status:"completed",conclusion:"success"}
    ]}'
    ;;
  skipped_only)
    jq -nc '{total_count:1,check_runs:[
      {name:"optional",status:"completed",conclusion:"skipped"}
    ]}'
    ;;
  retry_success)
    # Same name twice: older failure, newer success (greater id / later completed_at).
    jq -nc '{total_count:2,check_runs:[
      {id:1001,name:"plugin-checks",status:"completed",conclusion:"failure",
       started_at:"2024-01-01T00:00:00Z",completed_at:"2024-01-01T00:05:00Z"},
      {id:1002,name:"plugin-checks",status:"completed",conclusion:"success",
       started_at:"2024-01-01T01:00:00Z",completed_at:"2024-01-01T01:05:00Z"}
    ]}'
    ;;
  retry_failure)
    # Same name twice: older success, newer failure.
    jq -nc '{total_count:2,check_runs:[
      {id:2001,name:"plugin-checks",status:"completed",conclusion:"success",
       started_at:"2024-01-01T00:00:00Z",completed_at:"2024-01-01T00:05:00Z"},
      {id:2002,name:"plugin-checks",status:"completed",conclusion:"failure",
       started_at:"2024-01-01T01:00:00Z",completed_at:"2024-01-01T01:05:00Z"}
    ]}'
    ;;
  *)
    printf 'unknown FIXTURE_CHECKS=%s\n' "${FIXTURE_CHECKS-}" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$fake/gh"

  ec=0
  out="$(PATH="$fake:$PATH" FIXTURE_CHECKS=empty \
    bash "$PLUGIN_ROOT/scripts/required-checks.sh" --repo example/fixture --sha "$sha" 2>/dev/null)" || ec=$?
  if [ "$ec" -eq 1 ] && printf '%s' "$out" | jq -e --arg sha "$sha" \
      '.sha == $sha and .ok == false and (.checks|length) == 0' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} required-checks exits 1 on empty check-runs"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} required-checks exits 1 on empty check-runs"; FAIL=$((FAIL+1))
    FAILURES+=("required-checks empty"); printf '%s\n' "$out" >&2
  fi

  ec=0
  out="$(PATH="$fake:$PATH" FIXTURE_CHECKS=failed \
    bash "$PLUGIN_ROOT/scripts/required-checks.sh" --repo example/fixture --sha "$sha" 2>/dev/null)" || ec=$?
  if [ "$ec" -eq 1 ] && printf '%s' "$out" | jq -e \
      '.ok == false and any(.checks[]; .conclusion == "failure")' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} required-checks exits 1 when a check failed"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} required-checks exits 1 when a check failed"; FAIL=$((FAIL+1))
    FAILURES+=("required-checks failed"); printf '%s\n' "$out" >&2
  fi

  ec=0
  out="$(PATH="$fake:$PATH" FIXTURE_CHECKS=pending \
    bash "$PLUGIN_ROOT/scripts/required-checks.sh" --repo example/fixture --sha "$sha" 2>/dev/null)" || ec=$?
  if [ "$ec" -eq 1 ] && printf '%s' "$out" | jq -e \
      '.ok == false and any(.checks[]; .status == "in_progress")' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} required-checks exits 1 when a check is pending"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} required-checks exits 1 when a check is pending"; FAIL=$((FAIL+1))
    FAILURES+=("required-checks pending"); printf '%s\n' "$out" >&2
  fi

  ec=0
  out="$(PATH="$fake:$PATH" FIXTURE_CHECKS=success \
    bash "$PLUGIN_ROOT/scripts/required-checks.sh" --repo example/fixture --sha "$sha" 2>/dev/null)" || ec=$?
  if [ "$ec" -eq 0 ] && printf '%s' "$out" | jq -e --arg sha "$sha" \
      '.sha == $sha and .ok == true
       and all(.checks[]; .status == "completed" and .conclusion == "success")
       and any(.checks[]; .name == "unit — core")' >/dev/null \
    && printf '%s' "$out" | grep -q 'unit — core' \
    && ! printf '%s' "$out" | grep -q 'unit \\u2014 core'; then
    echo -e "  ${GREEN}PASS${NC} required-checks exits 0 when all completed success"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} required-checks exits 0 when all completed success"; FAIL=$((FAIL+1))
    FAILURES+=("required-checks success"); printf '%s\n' "$out" >&2
  fi

  ec=0
  out="$(PATH="$fake:$PATH" FIXTURE_CHECKS=skipped_only \
    bash "$PLUGIN_ROOT/scripts/required-checks.sh" --repo example/fixture --sha "$sha" 2>/dev/null)" || ec=$?
  if [ "$ec" -eq 1 ] && printf '%s' "$out" | jq -e '.ok == false' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} required-checks exits 1 when only skipped checks exist"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} required-checks exits 1 when only skipped checks exist"; FAIL=$((FAIL+1))
    FAILURES+=("required-checks skipped-only"); printf '%s\n' "$out" >&2
  fi

  ec=0
  out="$(PATH="$fake:$PATH" FIXTURE_CHECKS=retry_success \
    bash "$PLUGIN_ROOT/scripts/required-checks.sh" --repo example/fixture --sha "$sha" 2>/dev/null)" || ec=$?
  if [ "$ec" -eq 0 ] && printf '%s' "$out" | jq -e '.ok == true' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} required-checks latest-per-name retry success is ok"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} required-checks latest-per-name retry success is ok"; FAIL=$((FAIL+1))
    FAILURES+=("required-checks retry_success"); printf '%s\n' "$out" >&2
  fi

  ec=0
  out="$(PATH="$fake:$PATH" FIXTURE_CHECKS=retry_failure \
    bash "$PLUGIN_ROOT/scripts/required-checks.sh" --repo example/fixture --sha "$sha" 2>/dev/null)" || ec=$?
  if [ "$ec" -eq 1 ] && printf '%s' "$out" | jq -e '.ok == false' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} required-checks latest-per-name retry failure is not ok"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} required-checks latest-per-name retry failure is not ok"; FAIL=$((FAIL+1))
    FAILURES+=("required-checks retry_failure"); printf '%s\n' "$out" >&2
  fi

  ec=0
  PATH="$fake:$PATH" bash "$PLUGIN_ROOT/scripts/required-checks.sh" --repo example/fixture 2>/dev/null || ec=$?
  if [ "$ec" -eq 2 ]; then
    echo -e "  ${GREEN}PASS${NC} required-checks fails loud on missing --sha"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} required-checks fails loud on missing --sha"; FAIL=$((FAIL+1))
    FAILURES+=("required-checks bad args")
  fi

  # Required contexts are configured independently of the currently visible runs.
  for scenario in missing contexts checks rules union rules_pages configured_success \
      configured_extra_failure \
      configured_pending configured_failure configured_skipped configured_neutral \
      retry_configured_success retry_configured_failure default_base explicit_base \
      protection_error rules_error default_error malformed_branch malformed_rules; do
    branch='{"protected":true,"protection":{"enabled":true,"required_status_checks":{"enforcement_level":"non_admins","contexts":["full-regression","regression-test-gate","payment-contract"],"checks":[{"context":"full-regression","app_id":15368},{"context":"regression-test-gate","app_id":15368},{"context":"payment-contract","app_id":15368}]}}}'
    rules='[]'; checks=issue_missing; error=''; expected=1; args=()
    predicate='.ok == false and any(.checks[]; .name == "full-regression" and .status == "missing")'
    case "$scenario" in
      contexts) branch='{"protected":true,"protection":{"required_status_checks":{"contexts":["full-regression"]}}}' ;;
      checks) branch='{"protected":true,"protection":{"required_status_checks":{"checks":[{"context":"full-regression","app_id":15368}]}}}' ;;
      rules|rules_pages)
        branch='{"protected":false,"protection":{"enabled":false,"required_status_checks":{"contexts":[],"checks":[]}}}'
        rules='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"full-regression","integration_id":15368}],"strict_required_status_checks_policy":false}}]'
        if [ "$scenario" = rules_pages ]; then rules="[]
$rules"; fi
        ;;
      union)
        branch='{"protected":true,"protection":{"required_status_checks":{"contexts":["payment-contract"],"checks":[{"context":"regression-test-gate"}]}}}'
        rules='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"full-regression"}]}}]'
        ;;
      configured_success)
        checks=issue_success; expected=0
        predicate='.ok == true and ([.checks[].name] | length == (unique | length))'
        ;;
      configured_extra_failure)
        checks=configured_extra_failure
        predicate='.ok == false and any(.checks[]; .name == "optional" and .conclusion == "failure") and all(.checks[] | select(.name != "optional"); .status == "completed" and .conclusion == "success")'
        ;;
      configured_pending|configured_failure|configured_skipped|configured_neutral)
        checks="issue_${scenario#configured_}"
        predicate='.ok == false and any(.checks[]; .name == "full-regression")'
        ;;
      retry_configured_success|retry_configured_failure)
        branch='{"protected":true,"protection":{"required_status_checks":{"contexts":["plugin-checks"]}}}'
        checks="${scenario/retry_configured/retry}"
        if [ "$scenario" = retry_configured_success ]; then expected=0; predicate='.ok == true'; else predicate='.ok == false'; fi
        ;;
      default_base|explicit_base)
        checks=issue_success; expected=0; predicate='.ok == true'
        if [ "$scenario" = explicit_base ]; then args=(--base 'release/next'); fi
        ;;
      protection_error|rules_error|default_error)
        error="${scenario%_error}"; checks=issue_success; expected=2; predicate=''
        ;;
      malformed_branch) branch='{}'; checks=issue_success; expected=2; predicate='' ;;
      malformed_rules) rules='{}'; checks=issue_success; expected=2; predicate='' ;;
    esac
    : > "$work/calls"
    ec=0
    out="$(PATH="$fake:$PATH" FIXTURE_BRANCH="$branch" FIXTURE_RULES="$rules" \
      FIXTURE_CHECKS="$checks" FIXTURE_ERROR="$error" FIXTURE_CALLS="$work/calls" \
      bash "$PLUGIN_ROOT/scripts/required-checks.sh" --repo example/fixture --sha "$sha" \
      "${args[@]}" 2>"$work/error")" || ec=$?
    if [ "$ec" -eq "$expected" ] && {
      if [ "$expected" -eq 2 ]; then
        [ -z "$out" ] && grep -Eq 'required-checks:.*(protection|branch|rules|default)' "$work/error"
      else
        printf '%s' "$out" | jq -e "$predicate" >/dev/null
      fi
    } && {
      case "$scenario" in
        default_base)
          grep -Fxq 'repos/example/fixture' "$work/calls" &&
          grep -Fxq 'repos/example/fixture/branches/main' "$work/calls" &&
          grep -Eq '^repos/example/fixture/rules/branches/main(\?|$)' "$work/calls"
          ;;
        explicit_base)
          ! grep -Fxq 'repos/example/fixture' "$work/calls" &&
          grep -Fxq 'repos/example/fixture/branches/release%2Fnext' "$work/calls" &&
          grep -Eq '^repos/example/fixture/rules/branches/release%2Fnext(\?|$)' "$work/calls"
          ;;
        *) true ;;
      esac
    }; then
      echo -e "  ${GREEN}PASS${NC} required-checks protection $scenario"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} required-checks protection $scenario (exit $ec, expected $expected)"; FAIL=$((FAIL+1))
      FAILURES+=("required-checks protection $scenario")
      printf '%s\n' "$out" >&2; cat "$work/error" >&2
    fi
  done

  # Mutation RED (one copy): delete only the latest-per-name collapse from a
  # copy of required-checks.sh; retry_success must then exit 1 / ok=false.
  mutated="$work/required-checks.sh"
  cp "$PLUGIN_ROOT/scripts/required-checks.sh" "$mutated"
  python3 - "$mutated" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text2, n = re.subn(
    r"\(\$raw_runs\n\s*\| group_by\(\.name // \"\"\)\n\s*\| map\(max_by\(\[\n"
    r"\s*\(if \(\.id \| type\) == \"number\" then \.id else -1 end\),\n"
    r"\s*\(\.completed_at // \"\"\),\n"
    r"\s*\(\.started_at // \"\"\)\n"
    r"\s*\]\)\)\n\s*\) as \$runs",
    "($raw_runs) as $runs",
    text,
    count=1,
)
if n != 1:
    raise SystemExit(f"latest-per-name collapse needle missing (n={n})")
path.write_text(text2, encoding="utf-8")
PY
  ec=0
  out="$(PATH="$fake:$PATH" FIXTURE_CHECKS=retry_success \
    bash "$mutated" --repo example/fixture --sha "$sha" 2>/dev/null)" || ec=$?
  if [ "$ec" -eq 1 ] && printf '%s' "$out" | jq -e '.ok == false' >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} mutated required-checks treats stale retry as current (RED)"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} mutated required-checks treats stale retry as current (RED)"; FAIL=$((FAIL+1))
    FAILURES+=("required-checks latest-per-name mutation RED"); printf '%s\n' "$out" >&2
  fi

  # Mutation RED (one target): skill copy without refuse-to-merge must fail the
  # assertion that requires the refuse path (exit non-zero / RED on grep).
  mutated="$work/closing-SKILL.md"
  cp "$PLUGIN_ROOT/skills/closing-tribunal-loop/SKILL.md" "$mutated"
  python3 - "$mutated" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
# Strip the refuse-to-merge gate block and any remaining refuse-to-merge wording.
text2, n = re.subn(
    r"### CI-proven green \(refuse-to-merge\).*?(?=^## |\Z)",
    "",
    text,
    count=1,
    flags=re.S | re.M,
)
if n != 1:
    raise SystemExit("refuse-to-merge section missing from skill")
text2 = text2.replace("refuse to merge", "CONTINUE_MERGE_PLACEHOLDER")
text2 = text2.replace("Refuse merge", "Continue merge")
path.write_text(text2, encoding="utf-8")
PY
  ec=0
  grep -Eq 'refuse to merge|Refuse merge|refuse-to-merge' "$mutated" || ec=$?
  if [ "$ec" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${NC} mutated closing skill fails refuse-to-merge assertion (RED)"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} mutated closing skill fails refuse-to-merge assertion (RED)"; FAIL=$((FAIL+1))
    FAILURES+=("required-checks mutation RED")
  fi

  # Live skill must still carry the refuse path the mutation removed.
  if grep -Eq 'refuse to merge|scripts/required-checks\.sh' \
      "$PLUGIN_ROOT/skills/closing-tribunal-loop/SKILL.md"; then
    echo -e "  ${GREEN}PASS${NC} closing skill keeps refuse-to-merge + required-checks.sh"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} closing skill keeps refuse-to-merge + required-checks.sh"; FAIL=$((FAIL+1))
    FAILURES+=("closing skill CI refuse anchors")
  fi

  rm -rf "$work"
}


test_required_checks
