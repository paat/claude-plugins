#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

test_autonomous_demand_infra() {
  echo -e "\n${CYAN}Suite AD: autonomous demand/preflight infrastructure${NC}"
  local health="$PLUGIN_ROOT/scripts/health-preflight.sh"
  local v3="$PLUGIN_ROOT/scripts/maintain-v3.sh"
  local packs="$PLUGIN_ROOT/scripts/acceptance-packs.sh"
  local demand="$PLUGIN_ROOT/scripts/demand-discovery.sh"
  local market="$PLUGIN_ROOT/scripts/market-scout.sh"
  local closure="$PLUGIN_ROOT/scripts/issue-closure-audit.sh"
  local workdir ec output count fault_bin real_mktemp real_sort real_tr
  local bad_public_route="$PLUGIN_ROOT/tests/fixtures/public-route-destination-only.md"
  local empty_locale_public_route="$PLUGIN_ROOT/tests/fixtures/public-route-empty-locale.md"
  local good_public_route="$PLUGIN_ROOT/tests/fixtures/public-route-entry-path.md"
  local partial_public_route="$PLUGIN_ROOT/tests/fixtures/public-route-partial-locale.md"

  assert_file_exists "AD1: health-preflight exists" "$health"
  assert_file_exists "AD2: maintain-v3 exists" "$v3"
  assert_file_not_exists "AD2b: single-flight deleted" "$PLUGIN_ROOT/scripts/single-flight.sh"
  assert_file_exists "AD3: acceptance-packs exists" "$packs"
  assert_file_exists "AD4: demand-discovery exists" "$demand"
  assert_file_exists "AD4b: market-scout exists" "$market"
  assert_file_exists "AD4c: issue-closure-audit exists" "$closure"
  assert_file_contains "AD4d: Codex smoke uses supported permission flag" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" "--permission-profile"
  assert_file_not_contains "AD4e: Codex smoke drops obsolete plural flag" "$health" "--permissions-profile"
  assert_file_contains "AD4f: shell smoke enables the limited network proxy" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" "--enable network_proxy"
  assert_file_contains "AD4f1: shell smoke declares no outbound destinations" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" 'network.mode="limited"'
  assert_file_not_contains "AD4f2: shell smoke preserves anonymous socketpairs" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" "--sandbox-state-disable-network"
  assert_file_contains "AD4g: Codex capability check is bounded" \
    "$health" 'timeout 10 codex exec --help'
  assert_file_contains "AD4h: Codex capability check requires sandbox modes" \
    "$health" 'workspace-write'
  assert_file_contains "AD4i: Codex authentication check is bounded" \
    "$health" 'timeout 10 codex login status'
  assert_file_not_contains "AD4j: health preflight ignores stale sandbox configuration" \
    "$health" 'CODEX_SANDBOX'
  for s in "$health" "$v3" "$packs" "$demand" "$market" "$closure" \
    "$PLUGIN_ROOT/scripts/codex-network-off-sandbox.sh" \
    "$PLUGIN_ROOT/scripts/supervisor-commit.sh" \
    "$PLUGIN_ROOT/scripts/hooks-paused.sh" \
    "$PLUGIN_ROOT/scripts/legacy-drain.sh"; do
    ec=0; bash -n "$s" || ec=$?
    assert_exit_code "AD syntax: $(basename "$s")" "$ec" 0
  done

  workdir=$(make_workdir)
  mkdir -p "$workdir/plugin/hooks"
  printf '{"hooks":{}}\n' > "$workdir/plugin/hooks/hooks.json"
  ec=0; output=$(SAAS_PREFLIGHT_MISSING=jq bash "$health" --json --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD5: missing jq is blocking" "$ec" 1
  assert_output_contains "AD5b: reports missing jq" "$output" '"check": "tool:jq"'
  rm -rf "$workdir"

  workdir=$(make_workdir)
  mkdir -p "$workdir/plugin/hooks"
  cat > "$workdir/plugin/hooks/hooks.json" <<'JSON'
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"p=scripts/missing.sh; \"$p\""}]}]}}
JSON
  ec=0; output=$(bash "$health" --json --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6: broken hook target blocks" "$ec" 1
  assert_output_contains "AD6b: names missing hook target" "$output" "missing hook target"
  rm -rf "$workdir"

  workdir=$(make_workdir)
  mkdir -p "$workdir/plugin/hooks" "$workdir/bin"
  printf '{"hooks":{}}\n' > "$workdir/plugin/hooks/hooks.json"
  cat > "$workdir/bin/codex" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$CODEX_CALL_LOG"
if [ "${1:-}" = exec ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: codex exec [OPTIONS]'
  if [ "${FAKE_CODEX_SANDBOX_HELP:-1}" -eq 1 ]; then
    printf '%s\n' '  -s, --sandbox <SANDBOX_MODE>'
    printf '%s\n' '          [possible values: read-only, workspace-write, danger-full-access]'
    printf '%s\n' '  -o, --output-last-message <FILE>'
  fi
  exit 0
fi
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  if [ "${FAKE_CODEX_AUTH_OK:-1}" -eq 1 ]; then
    printf '%s\n' 'Logged in'
    exit 0
  fi
  printf '%s\n' 'Not logged in' >&2
  exit 1
fi
exit 64
SH
  chmod +x "$workdir/bin/codex"
  : > "$workdir/codex-calls.log"
  ec=0; output=$(CODEX_CALL_LOG="$workdir/codex-calls.log" \
    CODEX_SANDBOX=stale-restricted-setting PATH="$workdir/bin:$PATH" \
    bash "$health" --json --require-codex --repo-root "$workdir" \
      --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6c: authenticated sandboxed Codex passes preflight" "$ec" 0
  assert_output_contains "AD6d: reports cast sandbox readiness" "$output" \
    'Codex authentication and sandbox modes required by codex-cast are available'
  assert_file_contains "AD6e: preflight inspects exec capability" \
    "$workdir/codex-calls.log" '^exec --help$'
  assert_file_contains "AD6f: preflight checks Codex authentication" \
    "$workdir/codex-calls.log" '^login status$'

  : > "$workdir/codex-calls.log"
  ec=0; output=$(CODEX_CALL_LOG="$workdir/codex-calls.log" FAKE_CODEX_SANDBOX_HELP=0 \
    PATH="$workdir/bin:$PATH" bash "$health" --json --require-codex \
      --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6g: missing sandbox capability blocks preflight" "$ec" 1
  assert_output_contains "AD6h: missing capability names sandbox modes" "$output" \
    'lacks --sandbox read-only/workspace-write'
  assert_file_not_contains "AD6i: capability failure skips auth" \
    "$workdir/codex-calls.log" 'login status'

  : > "$workdir/codex-calls.log"
  ec=0; output=$(CODEX_CALL_LOG="$workdir/codex-calls.log" FAKE_CODEX_AUTH_OK=0 \
    PATH="$workdir/bin:$PATH" bash "$health" --json --require-codex \
      --repo-root "$workdir" --plugin-root "$workdir/plugin" 2>&1) || ec=$?
  assert_exit_code "AD6j: unavailable Codex authentication blocks preflight" "$ec" 1
  assert_output_contains "AD6k: authentication failure is explicit" "$output" \
    'Codex authentication is unavailable: Not logged in'
  rm -rf "$workdir"

  # Short maintain-v3 locks replace single-flight whole-pass leases (#389).
  workdir=$(mktemp -d)
  ec=0; output=$(bash "$v3" lock acquire --kind issue --key issue-42 --state-dir "$workdir" \
    --owner one --ttl-seconds 60 2>&1) || ec=$?
  assert_exit_code "AD7: issue lock acquire exits 0" "$ec" 0
  ec=0; output=$(bash "$v3" lock acquire --kind issue --key issue-42 --state-dir "$workdir" \
    --owner two --ttl-seconds 60 2>&1) || ec=$?
  assert_exit_code "AD8: second active owner refused" "$ec" 3
  bash "$v3" lock release --kind issue --key issue-42 --state-dir "$workdir" --owner one >/dev/null
  ec=0; output=$(bash "$v3" lock acquire --kind scheduler --key sched-1 --state-dir "$workdir" \
    --owner two --ttl-seconds 30 2>&1) || ec=$?
  assert_exit_code "AD9: scheduler lock acquire exits 0" "$ec" 0
  bash "$v3" lock release --kind scheduler --key sched-1 --state-dir "$workdir" --owner two >/dev/null
  ec=0; output=$(bash "$v3" lock acquire --kind release --key rel-1 --state-dir "$workdir" \
    --owner two --ttl-seconds 30 2>&1) || ec=$?
  assert_exit_code "AD10: release lock acquire exits 0" "$ec" 0
  bash "$v3" lock release --kind release --key rel-1 --state-dir "$workdir" --owner two >/dev/null
  ec=0; output=$(bash "$v3" lock status --kind issue --key issue-42 --state-dir "$workdir" \
    --owner two 2>&1) || ec=$?
  assert_exit_code "AD11: lock status exits 0" "$ec" 0
  assert_output_contains "AD11b: released lock not held" "$output" '"held":false'
  rm -rf "$workdir"

  ec=0; output=$(bash "$packs" --select --category report_output_quality --text "customer report has citations and remedies" --json 2>&1) || ec=$?
  assert_exit_code "AD12: pack select exits 0" "$ec" 0
  assert_output_contains "AD12b: selects report pack" "$output" "report_output_product"
  assert_output_not_contains "AD12c: does not match Estonian pack through generic words" "$output" "estonian_saas_context"
  ec=0; output=$(bash "$packs" --select --text "Add a public SEO guide page" --json 2>&1) || ec=$?
  assert_exit_code "AD12d: public-page pack selection exits 0" "$ec" 0
  assert_output_contains "AD12e: public-page text selects discoverability" "$output" \
    "public_route_discoverability"
  output=$(bash "$packs" --render public_route_discoverability)
  assert_output_contains "AD12f: rendered pack rejects direct-only QA" "$output" \
    "direct navigation alone cannot pass"
  ec=0; output=$(bash "$packs" --verify-public-route "$bad_public_route" 2>&1) || ec=$?
  assert_exit_code "AD12g: destination-only QA fixture fails" "$ec" 1
  assert_output_contains "AD12h: destination-only failure names missing click path" "$output" \
    "no clicked customer entry path"
  ec=0; output=$(bash "$packs" --verify-public-route "$good_public_route" 2>&1) || ec=$?
  assert_exit_code "AD12i: clicked entry-path fixture passes" "$ec" 0
  assert_output_contains "AD12j: public-route verifier reports success" "$output" \
    "public-route discoverability gate passed"
  ec=0; output=$(bash "$packs" --verify-public-route "$partial_public_route" 2>&1) || ec=$?
  assert_exit_code "AD12k: missing locale entry path fails" "$ec" 1
  assert_output_contains "AD12l: partial-locale failure is explicit" "$output" \
    "for every locale"
  ec=0; output=$(bash "$packs" --verify-public-route "$empty_locale_public_route" 2>&1) || ec=$?
  assert_exit_code "AD12m: empty locale list fails" "$ec" 1
  assert_output_contains "AD12n: empty-locale failure is explicit" "$output" \
    "for every locale"
  workdir=$(mktemp -d)
  printf 'Finding: STATUS_PENDING\nNo citation.\n' > "$workdir/bad.md"
  ec=0; output=$(bash "$packs" --verify-report "$workdir/bad.md" 2>&1) || ec=$?
  assert_exit_code "AD13: bad report fixture fails" "$ec" 1
  cat > "$workdir/good.md" <<'MD'
Finding: Payment status is still pending.
Citation: https://example.invalid/source
Recommendation: Next step is to retry the payment status check in the dashboard.
MD
  ec=0; output=$(bash "$packs" --verify-report "$workdir/good.md" 2>&1) || ec=$?
  assert_exit_code "AD14: good report fixture passes" "$ec" 0
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  cat > "$workdir/codex.jsonl" <<'JSONL'
{"message":{"content":"Customers abandon onboarding because the generated report shows raw STATUS_PENDING, has no citation, and gives no next step."}}
JSONL
  ec=0; output=$(bash "$demand" --project "demo-product" --codex-jsonl "$workdir/codex.jsonl" --out "$workdir/candidates.jsonl" --report "$workdir/report.md" 2>&1) || ec=$?
  assert_exit_code "AD15: demand discovery exits 0" "$ec" 0
  count=$(wc -l < "$workdir/candidates.jsonl" | tr -d ' ')
  assert_equals "AD15b: one demand candidate emitted" "$count" "1"
  assert_file_contains "AD15c: includes Codex evidence" "$workdir/candidates.jsonl" "codex-session"
  assert_file_contains "AD15d: includes acceptance packs" "$workdir/candidates.jsonl" "acceptance_packs"
  assert_file_contains "AD15e: report notes no external research" "$workdir/report.md" "external research: not used"
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  cat > "$workdir/sources.json" <<'JSON'
[
  {
    "source_type": "public-review",
    "title": "Micro-OÜ owners complain about manual VAT evidence collection",
    "url": "https://example.invalid/reviews/vat-gap",
    "date": "2026-06-30",
    "snippet": "Estonian e-resident micro-OÜ operators say pricing is unclear, report collection is too manual, and exports leak /srv/customer/data.csv paths."
  }
]
JSON
  ec=0; output=$(bash "$market" --project "demo-product" --source-json "$workdir/sources.json" --out "$workdir/market.jsonl" --report "$workdir/market.md" 2>&1) || ec=$?
  assert_exit_code "AD16: market scout external source exits 0" "$ec" 0
  count=$(wc -l < "$workdir/market.jsonl" | tr -d ' ')
  assert_equals "AD16b: one market candidate emitted" "$count" "1"
  assert_file_contains "AD16c: candidate includes source link" "$workdir/market.jsonl" "https://example.invalid/reviews/vat-gap"
  assert_file_contains "AD16d: candidate includes source date" "$workdir/market.jsonl" "2026-06-30"
  assert_file_contains "AD16e: candidate includes confidence" "$workdir/market.jsonl" "confidence"
  assert_file_contains "AD16f: report notes external research used" "$workdir/market.md" "external research: used"
  assert_file_contains "AD16g: de-identifies path placeholders cleanly" "$workdir/market.jsonl" "{{PATH}}"
  assert_file_not_contains "AD16h: no stray bracket before path placeholder" "$workdir/market.jsonl" "[ {{PATH}}"
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  ec=0; output=$(cd "$workdir" && bash "$market" --project "demo-product" --out "$workdir/fallback.jsonl" --report "$workdir/fallback.md" 2>&1) || ec=$?
  assert_exit_code "AD17: market scout fallback exits 0" "$ec" 0
  assert_file_contains "AD17b: fallback report notes unavailable external research" "$workdir/fallback.md" "external research: unavailable"
  assert_file_contains "AD17c: fallback report notes internal discovery" "$workdir/fallback.md" "fallback: internal demand discovery"
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  cat > "$workdir/pr.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\n## Changes\nFrontend default selection only."}
JSON
  cat > "$workdir/issue.json" <<'JSON'
{"number":55,"state":"OPEN","title":"Use actual prior dates","body":"Acceptance requires `backend/app/services/xbrl_generator.py` and `frontend/step2.tsx`.\nClosure-Audit-Split: #55 backend/app/services/pdf_renderer.py -> #56\nClosure-Audit-Split: #55 backend/app/services/xbrl_generator.py -> #56","comments":[{"body":"Also check `backend/app/services/pdf_renderer.py` labels."}]}
JSON
  cat > "$workdir/issue-followup.json" <<'JSON'
{"number":56,"state":"OPEN","title":"Complete deferred document rendering","body":"Track the explicitly split rendering acceptance.","comments":[]}
JSON
  printf 'frontend/step2.tsx\n' > "$workdir/files.txt"
  printf 'frontend/step2.tsx\nbackend/app/services/xbrl_generator.py\nbackend/app/services/pdf_renderer.py\n' > "$workdir/files-all.txt"
  fault_bin="$workdir/fault-bin"; mkdir "$fault_bin"
  real_mktemp=$(command -v mktemp); real_sort=$(command -v sort); real_tr=$(command -v tr)
  cat > "$fault_bin/mktemp" <<'SH'
#!/usr/bin/env bash
[ "${CLOSURE_FAULT:-}" != mktemp ] || exit 73
exec "$REAL_MKTEMP" "$@"
SH
  cat > "$fault_bin/sort" <<'SH'
#!/usr/bin/env bash
if [ "${CLOSURE_FAULT:-}" = audit-sort ] && [ "$*" = -nu ]; then exit 73; fi
exec "$REAL_SORT" "$@"
SH
  cat > "$fault_bin/tr" <<'SH'
#!/usr/bin/env bash
[ "${CLOSURE_FAULT:-}" != path-tr ] || exit 73
exec "$REAL_TR" "$@"
SH
  chmod +x "$fault_bin/mktemp" "$fault_bin/sort" "$fault_bin/tr"
  ec=0; output=$(PATH="$fault_bin:$PATH" CLOSURE_FAULT=mktemp \
    REAL_MKTEMP="$real_mktemp" REAL_SORT="$real_sort" REAL_TR="$real_tr" \
    bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue.json" \
      --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD17d: audit workspace creation failure fails closed" "$ec" 1
  assert_output_contains "AD17e: audit workspace failure is explicit" "$output" \
    "cannot create private audit workspace"
  ec=0; output=$(PATH="$fault_bin:$PATH" CLOSURE_FAULT=audit-sort \
    REAL_MKTEMP="$real_mktemp" REAL_SORT="$real_sort" REAL_TR="$real_tr" \
    bash "$closure" --pr-json "$workdir/pr.json" --audit-issue 55 \
      --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD17f: issue normalization producer failure fails closed" "$ec" 1
  assert_output_contains "AD17g: issue normalization failure is explicit" "$output" \
    "cannot normalize audited issue numbers"
  ec=0; output=$(PATH="$fault_bin:$PATH" CLOSURE_FAULT=path-tr \
    REAL_MKTEMP="$real_mktemp" REAL_SORT="$real_sort" REAL_TR="$real_tr" \
    bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue.json" \
      --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD17h: named-surface producer failure fails closure closed" "$ec" 1
  assert_output_contains "AD17i: named-surface producer failure is explicit" "$output" \
    "cannot extract named issue surfaces"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD18: closure audit fails missing named surfaces" "$ec" 1
  assert_output_contains "AD18b: closure audit names missing backend path" "$output" "backend/app/services/xbrl_generator.py"
  cat > "$workdir/pr-ok.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\n## Closure audit\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #56: PDF rendering acceptance remains separately tracked\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | follow-up #56: XBRL date emission remains separately tracked"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-ok.json" \
    --issue-json "$workdir/issue.json" --issue-json "$workdir/issue-followup.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19: closure audit accepts an authorized OPEN follow-up" "$ec" 0
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-ok.json" \
    --issue-json "$workdir/issue.json" --issue-json "$workdir/issue.json" \
    --issue-json "$workdir/issue-followup.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19a0: duplicate issue fixtures fail closed" "$ec" 1
  assert_output_contains "AD19a01: duplicate fixture refusal is explicit" "$output" \
    "duplicate issue JSON for #55"
  cat > "$workdir/issue-no-split-auth.json" <<'JSON'
{"number":55,"state":"OPEN","title":"Use actual prior dates","body":"Acceptance requires `backend/app/services/xbrl_generator.py` and `frontend/step2.tsx`.","comments":[{"body":"Also check `backend/app/services/pdf_renderer.py` labels."}]}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-ok.json" \
    --issue-json "$workdir/issue-no-split-auth.json" --issue-json "$workdir/issue-followup.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19a02: PR mapping cannot invent split authorization" "$ec" 1
  assert_output_contains "AD19a03: missing original authorization is explicit" "$output" \
    "original issue #55 needs exactly one split authorization"
  cat > "$workdir/pr-generic-override.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\n## Closure audit\n#55 remaining scope has follow-up #56.\nRefs #55"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-generic-override.json" --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19aa: a generic closure heading cannot waive named surfaces" "$ec" 1
  assert_output_contains "AD19ab: generic waiver failure names the exact missing path" "$output" \
    "backend/app/services/xbrl_generator.py"
  cat > "$workdir/pr-partial-override.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\n## Closure audit\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #56: PDF rendering acceptance remains separately tracked"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-partial-override.json" \
    --issue-json "$workdir/issue.json" --issue-json "$workdir/issue-followup.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ac: a per-path disposition cannot waive another path" "$ec" 1
  assert_output_contains "AD19ad: partial disposition failure names the unbound path" "$output" \
    "backend/app/services/xbrl_generator.py"
  cat > "$workdir/pr-same-followup.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #55: PDF rendering acceptance remains separately tracked\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | follow-up #55: XBRL date emission remains separately tracked"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-same-followup.json" \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ae: original issue cannot be its own follow-up" "$ec" 1
  assert_output_contains "AD19af: same-issue refusal is explicit" "$output" \
    "must differ from original issue #55"
  cat > "$workdir/issue-closed-followup-auth.json" <<'JSON'
{"number":55,"state":"OPEN","title":"Use actual prior dates","body":"Acceptance requires `backend/app/services/xbrl_generator.py` and `frontend/step2.tsx`.\nClosure-Audit-Split: #55 backend/app/services/pdf_renderer.py -> #57\nClosure-Audit-Split: #55 backend/app/services/xbrl_generator.py -> #57","comments":[{"body":"Also check `backend/app/services/pdf_renderer.py` labels."}]}
JSON
  cat > "$workdir/issue-followup-closed.json" <<'JSON'
{"number":57,"state":"CLOSED","title":"Deferred rendering","body":"No longer open.","comments":[]}
JSON
  cat > "$workdir/pr-closed-followup.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #57: PDF rendering acceptance remains separately tracked\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | follow-up #57: XBRL date emission remains separately tracked"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-closed-followup.json" \
    --issue-json "$workdir/issue-closed-followup-auth.json" \
    --issue-json "$workdir/issue-followup-closed.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ag: a closed follow-up cannot authorize closure" "$ec" 1
  assert_output_contains "AD19ah: closed follow-up refusal requires OPEN state" "$output" \
    "follow-up issue #57 is CLOSED, not OPEN"
  cat > "$workdir/pr-duplicate-deferral.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #56: PDF rendering acceptance remains separately tracked\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | follow-up #56: PDF rendering acceptance remains separately tracked\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | follow-up #56: XBRL date emission remains separately tracked"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-duplicate-deferral.json" \
    --issue-json "$workdir/issue.json" --issue-json "$workdir/issue-followup.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ai: duplicate path deferrals fail closed" "$ec" 1
  assert_output_contains "AD19aj: duplicate deferral refusal is explicit" "$output" \
    "must appear exactly once"
  cat > "$workdir/pr-malformed-deferral.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Closes #55\n\nClosure-Audit-Path: #55 backend/app/services/pdf_renderer.py | not applicable: PDF rendering is outside this change\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | covered by: existing date emission code"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-malformed-deferral.json" \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ak: non-follow-up dispositions cannot waive scope" "$ec" 1
  assert_output_contains "AD19al: malformed deferral refusal is explicit" "$output" \
    "must name one follow-up issue"
  cat > "$workdir/issue-duplicate-auth.json" <<'JSON'
{"number":55,"state":"OPEN","title":"Use actual prior dates","body":"Acceptance requires `backend/app/services/xbrl_generator.py` and `frontend/step2.tsx`.\nClosure-Audit-Split: #55 backend/app/services/pdf_renderer.py -> #56\nClosure-Audit-Split: #55 backend/app/services/pdf_renderer.py -> #56\nClosure-Audit-Split: #55 backend/app/services/xbrl_generator.py -> #56","comments":[{"body":"Also check `backend/app/services/pdf_renderer.py` labels."}]}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-ok.json" \
    --issue-json "$workdir/issue-duplicate-auth.json" --issue-json "$workdir/issue-followup.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19am: duplicate original split authorization fails closed" "$ec" 1
  assert_output_contains "AD19an: original split authorization must be singular" "$output" \
    "needs exactly one split authorization"
  cat > "$workdir/pr-refs.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\n## Changes\nFrontend default selection only."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-refs.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19a: prospective audit checks a non-closing maintain-loop PR" "$ec" 1
  assert_output_contains "AD19b: prospective audit names missing scope" "$output" \
    "backend/app/services/xbrl_generator.py"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-refs.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19c: prospective audit accepts exact metadata and complete scope" "$ec" 0
  cat > "$workdir/pr-prospective-override.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\n## Closure audit\nClosure-Audit-Path: #55 backend/app/services/xbrl_generator.py | not applicable: the requested backend surface is intentionally excluded"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-prospective-override.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ca: prospective audit cannot defer a named surface" "$ec" 1
  assert_output_contains "AD19cb: prospective deferral refusal is explicit" "$output" \
    "prospective audits cannot defer named surfaces"
  cat > "$workdir/pr-closing.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\nCloses #55"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-closing.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d: prospective audit rejects a body closing reference" "$ec" 1
  assert_output_contains "AD19e: closing-reference refusal is explicit" "$output" \
    "closing issue reference"
  cat > "$workdir/pr-qualified-closing.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\nCloses example/example#55"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-qualified-closing.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d0a: prospective audit rejects a qualified closing reference" "$ec" 1
  assert_output_contains "AD19d0b: qualified closing-reference refusal is explicit" "$output" \
    "closing issue reference"
  cat > "$workdir/pr-url-closing.json" <<'JSON'
{"title":"Resolves: https://github.com/example/example/issues/55","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-url-closing.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d0c: prospective audit rejects a URL closing reference" "$ec" 1
  assert_output_contains "AD19d0d: URL closing-reference refusal is explicit" "$output" \
    "closing issue reference"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-qualified-closing.json" \
    --repo example/example --issue-json "$workdir/issue.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d0e: qualified closing references enter the normal closure audit" "$ec" 1
  assert_output_contains "AD19d0f: qualified closure audit names missing scope" "$output" \
    "backend/app/services/xbrl_generator.py"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-qualified-closing.json" \
    --repo current/repository --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d0g: live audit rejects a cross-repository closing target" "$ec" 1
  assert_output_contains "AD19d0h: cross-repository refusal is explicit" "$output" \
    "cross-repository closing references are not auditable"
  ec=0; output=$(bash "$closure" \
    --pr https://github.com/example/example/pull/7 --repo different/repository 2>&1) || ec=$?
  assert_exit_code "AD19d0i: pull request URL cannot conflict with --repo" "$ec" 2
  assert_output_contains "AD19d0j: URL/repository mismatch is explicit" "$output" \
    "--repo conflicts with the pull request URL"
  cat > "$workdir/pr-title-closing.json" <<'JSON'
{"title":"Fixes #55","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-title-closing.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d1: prospective audit rejects a title closing reference" "$ec" 1
  cat > "$workdir/pr-prose-fixed.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #55\n\nThe race is fixed and the scope is complete."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-prose-fixed.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19d2: prospective audit permits non-closing fix prose" "$ec" 0
  cat > "$workdir/pr-missing-ref.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Maintain-Loop-Issue: #55\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-missing-ref.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19f: prospective audit rejects missing exact ref" "$ec" 1
  assert_output_contains "AD19g: missing ref names the exact required line" "$output" "exact line: Refs #55"
  cat > "$workdir/pr-mismatched-ref.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #54\n\nMaintain-Loop-Issue: #55\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-mismatched-ref.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19h: prospective audit rejects mismatched ref" "$ec" 1
  assert_output_contains "AD19i: mismatched ref cannot satisfy exact audited ref" "$output" "exact line: Refs #55"
  cat > "$workdir/pr-missing-marker.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-missing-marker.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19j: prospective audit rejects missing exact marker" "$ec" 1
  assert_output_contains "AD19k: missing marker names the exact required line" "$output" \
    "exact line: Maintain-Loop-Issue: #55"
  cat > "$workdir/pr-mismatched-marker.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\n\nMaintain-Loop-Issue: #54\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-mismatched-marker.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19l: prospective audit rejects mismatched marker" "$ec" 1
  assert_output_contains "AD19m: mismatched marker cannot satisfy audited marker" "$output" \
    "exact line: Maintain-Loop-Issue: #55"
  cat > "$workdir/pr-duplicate-bindings.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\nRefs #55\n\nMaintain-Loop-Issue: #55\nMaintain-Loop-Issue: #55\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-duplicate-bindings.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19ma: prospective audit rejects duplicate metadata bindings" "$ec" 1
  assert_output_contains "AD19mb: duplicate refs cannot expand the audit set" "$output" \
    "Refs lines must bind exactly once"
  cat > "$workdir/pr-extra-bindings.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55\nRefs #56\n\nMaintain-Loop-Issue: #55\nMaintain-Loop-Issue: #56\n\n## Changes\nComplete scope."}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-extra-bindings.json" --audit-issue 55 \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD19mc: prospective audit rejects extra issue bindings" "$ec" 1
  assert_output_contains "AD19md: extra markers cannot exceed the audit set" "$output" \
    "Maintain-Loop-Issue lines must bind exactly once"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-ok.json" --audit-issue nope \
    --issue-json "$workdir/issue.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19n: prospective audit rejects invalid issue numbers" "$ec" 2
  printf '{"title":' > "$workdir/pr-malformed.json"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-malformed.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19o: malformed PR JSON fails closed" "$ec" 1
  assert_output_contains "AD19p: malformed PR JSON is explicit" "$output" "malformed PR JSON"
  cat > "$workdir/pr-bad-body.json" <<'JSON'
{"title":"fix: covered-stub selection","body":["Refs #55"]}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-bad-body.json" \
    --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD19q: invalid PR body shape fails closed" "$ec" 1
  assert_output_contains "AD19r: invalid PR body shape is explicit" "$output" "invalid body shape"
  cat > "$workdir/pr-bad-files.json" <<'JSON'
{"title":"fix: covered-stub selection","body":"Refs #55","files":"frontend/step2.tsx"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-bad-files.json" 2>&1) || ec=$?
  assert_exit_code "AD19s: invalid fetched PR files shape fails closed" "$ec" 1
  assert_output_contains "AD19t: invalid PR files shape is explicit" "$output" "invalid files shape"
  mkdir -p "$workdir/bin"
  printf '#!/bin/sh\nexit 1\n' > "$workdir/bin/gh"
  chmod +x "$workdir/bin/gh"
  cat > "$workdir/issue-mismatch.json" <<'JSON'
{"number":54,"state":"OPEN","title":"Different issue","body":"Acceptance requires `frontend/step2.tsx`.","comments":[]}
JSON
  ec=0; output=$(PATH="$workdir/bin:$PATH" bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue-mismatch.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD20: closure audit rejects mismatched single fixture" "$ec" 1
  assert_output_contains "AD20b: mismatched issue payload is explicit" "$output" "does not match audited issue #55"
  cat > "$workdir/issue-closed.json" <<'JSON'
{"number":55,"state":"CLOSED","title":"Closed issue","body":"Acceptance requires `frontend/step2.tsx`.","comments":[]}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-refs.json" --audit-issue 55 \
    --issue-json "$workdir/issue-closed.json" --changed-files "$workdir/files-all.txt" 2>&1) || ec=$?
  assert_exit_code "AD20c: closure audit rejects a closed audited issue" "$ec" 1
  assert_output_contains "AD20d: closed issue refusal requires OPEN state" "$output" "CLOSED, not OPEN"
  printf '{"number":55,"state":"OPEN"' > "$workdir/issue-malformed.json"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr.json" \
    --issue-json "$workdir/issue-malformed.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD20e: malformed issue JSON fails closed" "$ec" 1
  assert_output_contains "AD20f: malformed issue JSON is explicit" "$output" "malformed issue JSON"
  cat > "$workdir/issue-anon.json" <<'JSON'
{"state":"OPEN","title":"Anonymous fixture","body":"Acceptance requires `frontend/step2.tsx`.","comments":[]}
JSON
  ec=0; output=$(PATH="$workdir/bin:$PATH" bash "$closure" --pr-json "$workdir/pr.json" --issue-json "$workdir/issue-anon.json" --changed-files "$workdir/files.txt" 2>&1) || ec=$?
  assert_exit_code "AD21: closure audit rejects issue JSON without a number" "$ec" 1
  rm -rf "$workdir"

  workdir=$(mktemp -d)
  cat > "$workdir/pr-bracket.json" <<'JSON'
{"title":"fix: download flow","body":"Closes #200\n\n## Changes\nUpdated dynamic route page and step component."}
JSON
  cat > "$workdir/issue-bracket.json" <<'JSON'
{"number":200,"state":"OPEN","title":"Fix download","body":"Acceptance requires `frontend/src/app/[locale]/download/[token]/page.tsx` and `frontend/src/app/[locale]/report/components/Step6Download.tsx`.","comments":[]}
JSON
  printf 'frontend/src/app/[locale]/download/[token]/page.tsx\nfrontend/src/app/[locale]/report/components/Step6Download.tsx\n' > "$workdir/files-bracket.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-bracket.json" --issue-json "$workdir/issue-bracket.json" --changed-files "$workdir/files-bracket.txt" 2>&1) || ec=$?
  assert_exit_code "AD22: bracketed Next.js dynamic-route path does not false-fail" "$ec" 0
  rm -rf "$workdir"

  # #1604 — bare basename dedupe when a full path with the same basename is present
  workdir=$(mktemp -d)
  cat > "$workdir/pr-basename.json" <<'JSON'
{"title":"fix: verifier tweak","body":"Closes #201\n\n## Changes\nTouched the full path only."}
JSON
  cat > "$workdir/issue-basename.json" <<'JSON'
{"number":201,"state":"OPEN","title":"Update verifier","body":"Change `scripts/verify_finding.py` (also referred to as bare `verify_finding.py`).","comments":[]}
JSON
  printf 'scripts/verify_finding.py\n' > "$workdir/files-basename.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-basename.json" --issue-json "$workdir/issue-basename.json" --changed-files "$workdir/files-basename.txt" 2>&1) || ec=$?
  assert_exit_code "AD23: bare basename covered by full path does not false-fail" "$ec" 0
  # Without the full path, the bare basename alone is still a real surface
  cat > "$workdir/issue-bare-only.json" <<'JSON'
{"number":201,"state":"OPEN","title":"Bare only","body":"Must update `verify_finding.py` narrative checks.","comments":[]}
JSON
  printf 'frontend/src/app/report/storage.ts\n' > "$workdir/files-other.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-basename.json" --issue-json "$workdir/issue-bare-only.json" --changed-files "$workdir/files-other.txt" 2>&1) || ec=$?
  assert_exit_code "AD23b: bare basename alone still requires a PR surface" "$ec" 1
  assert_output_contains "AD23c: bare basename is named as missing" "$output" "verify_finding.py"
  # #416 — bare filenames match an exact basename in nested changed paths.
  cat > "$workdir/pr-nested-basename.json" <<'JSON'
{"title":"fix: VAT fixture assertions","body":"Closes #203"}
JSON
  cat > "$workdir/issue-nested-basename.json" <<'JSON'
{"number":203,"state":"OPEN","title":"Update assertions","body":"Update `assertions.json`.","comments":[]}
JSON
  printf '%s\n' 'backend/tests/fixtures/engine_sessions/vat_payable_year_end/expected/assertions.json' > "$workdir/files-nested-basename.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-nested-basename.json" --issue-json "$workdir/issue-nested-basename.json" --changed-files "$workdir/files-nested-basename.txt" 2>&1) || ec=$?
  assert_exit_code "AD23d: bare basename matches nested changed path" "$ec" 0
  rm -rf "$workdir"

  # #1604 — Closure-Audit-Unchanged disposition
  workdir=$(mktemp -d)
  cat > "$workdir/pr-unchanged.json" <<'JSON'
{"title":"fix: storage isolation","body":"Closes #202\n\n## Closure audit\nClosure-Audit-Unchanged: #202 scripts/verify_finding.py | narrative verifier must stay byte-identical; covered by existing regression tests"}
JSON
  cat > "$workdir/issue-unchanged.json" <<'JSON'
{"number":202,"state":"OPEN","title":"Keep verifier","body":"Touch storage and leave `scripts/verify_finding.py` behaviorally unchanged.","comments":[]}
JSON
  printf 'frontend/src/app/report/storage.ts\n' > "$workdir/files-unchanged.txt"
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-unchanged.json" --issue-json "$workdir/issue-unchanged.json" --changed-files "$workdir/files-unchanged.txt" 2>&1) || ec=$?
  assert_exit_code "AD24: Closure-Audit-Unchanged accepts negative-requirement surface" "$ec" 0
  cat > "$workdir/pr-unchanged-short.json" <<'JSON'
{"title":"fix: storage isolation","body":"Closes #202\n\nClosure-Audit-Unchanged: #202 scripts/verify_finding.py | too short"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-unchanged-short.json" --issue-json "$workdir/issue-unchanged.json" --changed-files "$workdir/files-unchanged.txt" 2>&1) || ec=$?
  assert_exit_code "AD24b: short unchanged reason fails closed" "$ec" 1
  assert_output_contains "AD24c: short reason refusal is explicit" "$output" "concrete reason"
  # Without disposition, the unchanged surface still fails
  cat > "$workdir/pr-no-disp.json" <<'JSON'
{"title":"fix: storage isolation","body":"Closes #202"}
JSON
  ec=0; output=$(bash "$closure" --pr-json "$workdir/pr-no-disp.json" --issue-json "$workdir/issue-unchanged.json" --changed-files "$workdir/files-unchanged.txt" 2>&1) || ec=$?
  assert_exit_code "AD24d: missing unchanged disposition still fails" "$ec" 1
  assert_output_contains "AD24e: missing surface named" "$output" "scripts/verify_finding.py"
  rm -rf "$workdir"
}


test_autonomous_demand_infra
