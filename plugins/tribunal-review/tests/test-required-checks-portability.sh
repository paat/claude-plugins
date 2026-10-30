#!/usr/bin/env bash
# Stub-only regressions for free-plan configuration reads and explicit absent CI.
test_required_checks_portability() {
  local work sha scenario branch rules checks workflows statuses expected predicate out ec
  work="$(mktemp -d)"
  sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir "$work/bin"
  cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
endpoint=""
for arg in "$@"; do
  case "$arg" in repos/*) endpoint="$arg" ;; esac
done
case "$endpoint" in
  repos/example/fixture/branches/*)
    mode="$FIXTURE_BRANCH_MODE"
    doc='https://docs.github.com/rest/branches/branches#get-a-branch'
    success='{"protected":false}'
    ;;
  repos/example/fixture/rules/branches/*)
    mode="$FIXTURE_RULES_MODE"
    doc='https://docs.github.com/rest/repos/rules#get-rules-for-a-branch'
    success='[]'
    ;;
  repos/example/fixture/actions/workflows*)
    [[ " $* " == *" --paginate "* ]] || exit 1
    case "$FIXTURE_WORKFLOW_MODE" in
      empty) printf '%s\n' '{"total_count":0,"workflows":[]}' ;;
      disabled) printf '%s\n' '{"workflows":[{"state":"disabled_manually"},{"state":"disabled_inactivity"}]}' ;;
      unreadable) printf '%s\n' 'workflows unavailable (HTTP 403)' >&2; exit 1 ;;
      active) printf '%s\n' '{"workflows":[]}' '{"workflows":[{"state":"active"}]}' ;;
    esac
    exit 0
    ;;
  repos/example/fixture/commits/*/status)
    case "$FIXTURE_STATUS_MODE" in
      empty) printf '%s\n' '{"total_count":0,"statuses":[]}' ;;
      failure|pending) jq -nc --arg state "$FIXTURE_STATUS_MODE" '{total_count:1,statuses:[{context:"external-ci",state:$state}]}' ;;
      unreadable) printf '%s\n' 'statuses unavailable (HTTP 403)' >&2; exit 1 ;;
    esac
    exit 0
    ;;
  repos/example/fixture/commits/*/check-runs*)
    case "$FIXTURE_CHECK_MODE" in
      empty) printf '%s\n' '{"check_runs":[]}' ;;
      unreadable) printf '%s\n' 'check-runs unavailable (HTTP 403)' >&2; exit 1 ;;
      *) jq -nc --arg conclusion "$FIXTURE_CHECK_MODE" '{check_runs:[{name:"test",status:"completed",conclusion:$conclusion}]}' ;;
    esac
    exit 0
    ;;
  *) printf 'unexpected endpoint: %s\n' "$endpoint" >&2; exit 1 ;;
esac
case "$mode" in
  ok) printf '%s\n' "$success"; exit 0 ;;
  configured) printf '%s\n' '{"protected":true,"protection":{"required_status_checks":{"contexts":["test"]}}}'; exit 0 ;;
esac
message='Upgrade to GitHub Pro or make this repository public to enable this feature.'
status=403
case "$mode" in
  permission) message='Resource not accessible by integration' ;;
  rate_limit) message='API rate limit exceeded' ;;
  not_found) status=404 ;;
  server_error) status=500 ;;
  wrong_doc) doc='https://docs.github.com/rest/checks/runs#list-check-runs-for-a-git-reference' ;;
  missing_status) status='' ;;
  stderr_only) printf '%s (HTTP 403)\n' "$message" >&2; exit 1 ;;
  partial_page) printf '%s\n' '[]' ;;
esac
jq -nc --arg message "$message" --arg documentation_url "$doc" --arg status "$status" \
  '{message:$message,documentation_url:$documentation_url,status:$status}'
printf '%s (HTTP %s)\n' "$message" "$status" >&2
exit 1
STUB
  chmod +x "$work/bin/gh"
  for scenario in free_success free_failure free_empty free_skipped free_neutral \
      statuses_failure statuses_pending statuses_empty statuses_unreadable \
      free_branch_success free_both_empty ordinary_empty zero_active only_disabled workflows_unreadable configured_empty skipped_only \
      rules_permission rules_rate_limit rules_not_found rules_server_error rules_wrong_doc \
      rules_missing_status rules_stderr_only rules_partial_page branch_permission \
      branch_not_found branch_server_error branch_wrong_doc check_runs_unreadable; do
    branch=ok; rules=free; checks=success; workflows=active; statuses=empty; expected=2; predicate=''
    case "$scenario" in
      free_success) expected=0; predicate='.ok == true' ;;
      free_failure) checks=failure; expected=1; predicate='.ok == false and .ci != "none"' ;;
      free_empty) workflows=empty; checks=empty; expected=1; predicate='.ok == false and .ci == "none" and .reason == "no CI configured"' ;;
      free_skipped|free_neutral) checks="${scenario#free_}"; expected=1; predicate='.ok == false and .ci != "none"' ;;
      free_branch_success) branch=free; rules=ok ;;
      free_both_empty) branch=free; checks=empty ;;
      ordinary_empty) rules=ok; checks=empty; expected=1; predicate='.ok == false and .ci == "checks"' ;;
      zero_active|only_disabled) rules=ok; checks=empty; workflows=empty
        [ "$scenario" != only_disabled ] || workflows=disabled
        expected=1; predicate='.ok == false and .ci == "none" and .reason == "no CI configured"' ;;
      statuses_*) rules=ok; checks=empty; workflows=empty; statuses="${scenario#statuses_}"
        case "$statuses" in
          failure|pending) expected=1; predicate='.ok == false and .ci == "checks"' ;;
          empty) expected=1; predicate='.ok == false and .ci == "none"' ;;
        esac ;;
      workflows_unreadable) rules=ok; checks=empty; workflows=unreadable ;;
      configured_empty) branch=configured; rules=ok; checks=empty; expected=1; predicate='.ok == false and .ci != "none" and .checks[0].status == "missing"' ;;
      skipped_only) rules=ok; checks=skipped; expected=1; predicate='.ok == false and .ci != "none"' ;;
      rules_*) rules="${scenario#rules_}" ;;
      branch_*) branch="${scenario#branch_}"; rules=ok ;;
      check_runs_unreadable) rules=ok; checks=unreadable ;;
    esac
    ec=0
    out="$(PATH="$work/bin:$PATH" FIXTURE_BRANCH_MODE="$branch" FIXTURE_RULES_MODE="$rules" \
      FIXTURE_STATUS_MODE="$statuses" FIXTURE_WORKFLOW_MODE="$workflows" FIXTURE_CHECK_MODE="$checks" bash "$PLUGIN_ROOT/scripts/required-checks.sh" \
      --repo example/fixture --sha "$sha" --base main 2>"$work/error")" || ec=$?
    if [ "$ec" -eq "$expected" ] && {
      if [ "$expected" -eq 2 ]; then
        [ -z "$out" ] && [ -s "$work/error" ] && {
          [ "$scenario" != statuses_unreadable ] || grep -q 'commit statuses API failed' "$work/error"
        } && {
          [ "$scenario" != workflows_unreadable ] || grep -q 'workflows API failed' "$work/error"
        }
      else
        printf '%s' "$out" | jq -e "$predicate" >/dev/null
      fi
    }; then
      printf '  PASS required-checks portability %s\n' "$scenario"; PASS=$((PASS+1))
    else
      printf '  FAIL required-checks portability %s (exit %s, expected %s)\n' "$scenario" "$ec" "$expected"
      FAIL=$((FAIL+1)); FAILURES+=("required-checks portability $scenario")
      printf '%s\n' "$out"; cat "$work/error"
    fi
  done
  rm -rf "$work"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  PASS=0; FAIL=0; FAILURES=()
  test_required_checks_portability
  printf '%s PASS / %s FAIL\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
fi
