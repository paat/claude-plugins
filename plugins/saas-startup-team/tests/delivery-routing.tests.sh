# Sourced by run-tests.sh: semantic routing, pinned Codex launcher, and static pin audit.

test_delivery_routing() {
  echo -e "\n${CYAN}Suite: semantic delivery routing and Codex role launcher${NC}"
  local route="$PLUGIN_ROOT/scripts/delivery-route.sh"
  local launcher="$PLUGIN_ROOT/scripts/codex-run-role.sh"
  local wrapper="$PLUGIN_ROOT/scripts/codex-implement.sh"
  local wd task labels out ec repo bin calls events auth_signal sensitive_signal parity_signal ui_file artifact_role login_home summary log_file

  assert_file_exists "DR1: delivery router exists" "$route"
  assert_file_exists "DR2: pinned role launcher exists" "$launcher"
  assert_file_contains "DR2a: generated workflows abandon failed thread handles" \
    "$PLUGIN_ROOT/skills/saas-startup-team-growth-workflow/SKILL.md" \
    "do not wait or poll that handle"
  assert_file_contains "DR2a1: generated workflows inspect the artifact before fallback" \
    "$PLUGIN_ROOT/skills/saas-startup-team-growth-workflow/SKILL.md" \
    "Check its expected artifact once"
  assert_file_contains "DR2a2: generated workflows prohibit concurrent fallback writers" \
    "$PLUGIN_ROOT/skills/saas-startup-team-growth-workflow/SKILL.md" \
    "Never let an original and fallback worker write the same artifact concurrently"
  assert_file_contains "DR2a3: generated workflows reject stale fallback artifacts" \
    "$PLUGIN_ROOT/skills/saas-startup-team-growth-workflow/SKILL.md" \
    "a stale or unproven artifact counts as absent"
  assert_file_exists "DR2b: compatibility wrapper exists" "$wrapper"
  assert_file_contains "DR2c: wrapper delegates to the shared launcher" "$wrapper" 'codex-run-role.sh'
  assert_file_not_contains "DR2d: wrapper never launches Codex directly" "$wrapper" 'codex exec'
  assert_file_contains "DR2e: generated workflows prohibit fixed checkout roots" \
    "$PLUGIN_ROOT/skills/saas-startup-team-growth-workflow/SKILL.md" \
    'Never emit a hardcoded checkout root such as `/workspace`'
  assert_file_contains "DR2f: growth handoffs prohibit fixed checkout roots" \
    "$PLUGIN_ROOT/agents/growth-hacker.md" \
    'NEVER.*fixed checkout root such as `/workspace`'
  assert_file_contains "DR2g: current-session implementation loads tech-founder skill" \
    "$PLUGIN_ROOT/skills/saas-startup-team-growth-workflow/SKILL.md" \
    'load the `tech-founder` skill for every current-session architecture or implementation phase'
  assert_file_not_contains "DR2h: startup orchestration has no direct implementation bypass" \
    "$PLUGIN_ROOT/skills/startup-orchestration/SKILL.md" \
    'skill or direct Codex implementation'
  assert_equals "DR3: routing schema probe" "$(bash "$route" schema-version | jq -r .schema_version)" "1"

  wd=$(mktemp -d)
  task="$wd/task.txt"; labels="$wd/labels.txt"
  printf '%s\n' 'Fix the typo in docs/setup.md.' > "$task"
  out=$(bash "$route" classify --mode autonomous --task-file "$task")
  assert_equals "DR4: autonomous docs typo is light" "$(jq -r .profile <<< "$out")" "light"

  printf '%s\n' 'Fix typo in payment amount label.' > "$task"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "DR5: payment label escalates" "$ec" 20
  assert_equals "DR6: payment precedence is deep" "$(jq -r .profile <<< "$out")" "deep"
  assert_equals "DR7: payment is sensitive" "$(jq -r .sensitive <<< "$out")" "true"

  printf '%s\n' 'Repair the broken link in the auth email.' > "$task"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "DR8: auth email link escalates" "$ec" 20
  assert_equals "DR9: auth beats broken-link keyword" "$(jq -r .profile <<< "$out")" "deep"

  printf '%s\n' 'Adjust two pixels of CSS spacing.' > "$task"
  out=$(bash "$route" classify --mode autonomous --task-file "$task")
  assert_equals "DR10: autonomous CSS is not light" "$(jq -r .profile <<< "$out")" "standard"
  out=$(bash "$route" classify --mode interactive-tweak --task-file "$task")
  assert_equals "DR11: interactive small CSS remains light" "$(jq -r .profile <<< "$out")" "light"
  assert_equals "DR12: interactive CSS reports UI touch" "$(jq -r .ui_touch <<< "$out")" "true"

  printf '%s\n' 'Fix typo on homepage title.' > "$task"
  out=$(bash "$route" classify --mode autonomous --task-file "$task")
  assert_equals "DR12b: autonomous homepage copy is not light" "$(jq -r .profile <<< "$out")" "standard"
  assert_equals "DR12c: autonomous homepage copy reports UI touch" "$(jq -r .ui_touch <<< "$out")" "true"

  printf '%s\n' 'Update the GDPR consent rule.' > "$task"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "DR13: legal judgment escalates" "$ec" 20
  assert_equals "DR14: legal judgment is explicit" "$(jq -r .requires_legal_judgment <<< "$out")" "true"

  printf '%s\n' 'Fix a bounded parser bug.' > "$task"
  printf '%s\n' 'security' > "$labels"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task" --labels-file "$labels") || ec=$?
  assert_exit_code "DR15: sensitive label overrides routine task" "$ec" 20

  printf '%s\n' 'Fix a bounded parser bug.' > "$task"
  printf '%s\n' '[{"name":"accounting"},{"name":"andmesild"}]' > "$labels"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task" --labels-file "$labels") || ec=$?
  assert_exit_code "DR15a1: accounting JSON labels escalate before implementation" "$ec" 20
  assert_equals "DR15a2: accounting JSON labels select deep" "$(jq -r .profile <<< "$out")" "deep"
  assert_equals "DR15a3: accounting JSON labels have a stable reason" \
    "$(jq -r '.reasons | index("sensitive_accounting_reporting") != null' <<< "$out")" "true"

  for sensitive_signal in XBRL Arelle taxonomy 'financial reporting'; do
    printf 'Repair the %s validation adapter.\n' "$sensitive_signal" > "$task"
    ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
    assert_exit_code "DR15a4: $sensitive_signal task escalates before implementation" "$ec" 20
    assert_equals "DR15a5: $sensitive_signal task is sensitive accounting/reporting" \
      "$(jq -r '.reasons | index("sensitive_accounting_reporting") != null' <<< "$out")" "true"
  done

  printf '%s\n' 'Fix a typo after the RCA: docs incident.' > "$task"
  : > "$labels"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task" --labels-file "$labels") || ec=$?
  assert_exit_code "DR15b: POSIX-delimited RCA keeps sensitive precedence" "$ec" 20
  assert_equals "DR15c: punctuation-delimited RCA is deep" "$(jq -r .profile <<< "$out")" "deep"

  printf '%s\n' 'Fix typo in liquid docs.' > "$task"
  out=$(bash "$route" classify --mode autonomous --task-file "$task")
  assert_equals "DR15d: UI substring is not a UI boundary match" "$(jq -r .profile <<< "$out")" "light"

  printf '%s\n' 'Run setup.sh.' > "$task"
  out=$(bash "$route" classify --mode autonomous --task-file "$task")
  assert_equals "DR15e: POSIX-delimited shell extension stays mechanical" "$(jq -r .profile <<< "$out")" "mechanical"

  printf '%s\n' 'Fix typo in PII-labelled docs.' > "$task"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "DR15f: POSIX-delimited PII keeps sensitive precedence" "$ec" 20
  assert_equals "DR15g: punctuation-delimited PII is sensitive" "$(jq -r .sensitive <<< "$out")" "true"

  printf '%s\n' 'Fix typo in REST API.' > "$task"
  out=$(bash "$route" classify --mode interactive-tweak --task-file "$task")
  assert_equals "DR15h: POSIX-delimited API excludes interactive light" "$(jq -r .profile <<< "$out")" "standard"

  printf '%s\n' 'Fix typo in rapid docs.' > "$task"
  out=$(bash "$route" classify --mode interactive-tweak --task-file "$task")
  assert_equals "DR15i: API substring is not an API boundary match" "$(jq -r .profile <<< "$out")" "light"

  printf '%s\n' 'Fix typo in UI.' > "$task"
  out=$(bash "$route" classify --mode autonomous --task-file "$task")
  assert_equals "DR15j: POSIX-delimited UI reports UI touch" "$(jq -r .ui_touch <<< "$out")" "true"

  printf '%s\n' 'Fix a syntax typo in docs.' > "$task"
  out=$(bash "$route" classify --mode autonomous --task-file "$task")
  assert_equals "DR15k: syntax does not match the tax signal" "$(jq -r .profile <<< "$out")" "light"

  printf '%s\n' 'Correct a typo in the DPA.' > "$task"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "DR15l: POSIX-delimited DPA escalates" "$ec" 20
  assert_equals "DR15m: DPA requires legal judgment" "$(jq -r .requires_legal_judgment <<< "$out")" "true"

  printf '%s\n' 'Correct wording for a DSAR.' > "$task"
  ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
  assert_exit_code "DR15n: POSIX-delimited DSAR escalates" "$ec" 20

  for auth_signal in SSO SAML MFA auth OAuth2 OIDC 2FA WebAuthn passkey; do
    printf 'Fix a typo in the %s guide.\n' "$auth_signal" > "$task"
    ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
    assert_exit_code "DR15o: POSIX-delimited $auth_signal escalates" "$ec" 20
    assert_equals "DR15p: $auth_signal is sensitive" "$(jq -r .sensitive <<< "$out")" "true"
  done

  for sensitive_signal in encryption crypto TLS SSL certificate RBAC ACL \
      'credit card' 'debit card' cardholder 'PCI DSS' SEPA chargeback \
      'bank account' 'bank details'; do
    printf 'Fix a typo in the %s guide.\n' "$sensitive_signal" > "$task"
    ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
    assert_exit_code "DR15pa: $sensitive_signal escalates" "$ec" 20
    assert_equals "DR15pb: $sensitive_signal is sensitive" \
      "$(jq -r .sensitive <<< "$out")" "true"
  done

  for auth_signal in 'Terms & Conditions' 'cookie notice'; do
    printf 'Fix a typo in the %s.\n' "$auth_signal" > "$task"
    ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
    assert_exit_code "DR15q: $auth_signal escalates" "$ec" 20
    assert_equals "DR15r: $auth_signal requires legal review" \
      "$(jq -r .requires_legal_judgment <<< "$out")" "true"
  done

  printf '%s\n' 'Make navigation unclickable using pointer-events CSS.' > "$task"
  out=$(bash "$route" classify --mode interactive-tweak --task-file "$task")
  assert_equals "DR15s: behavioral CSS is excluded from interactive light" \
    "$(jq -r .profile <<< "$out")" "standard"

  printf '%s\n' 'Set navigation font-size to zero.' > "$task"
  out=$(bash "$route" classify --mode interactive-tweak --task-file "$task")
  assert_equals "DR15t: zero font size is excluded from interactive light" \
    "$(jq -r .profile <<< "$out")" "standard"
  assert_equals "DR15ta: font-size task reports a UI touch" \
    "$(jq -r .ui_touch <<< "$out")" "true"

  printf '%s\n' 'Set the navigation margin to -9999px.' > "$task"
  out=$(bash "$route" classify --mode interactive-tweak --task-file "$task")
  assert_equals "DR15u: extreme negative spacing is excluded from interactive light" \
    "$(jq -r .profile <<< "$out")" "standard"

  printf '%s\n' 'Make the navigation text transparent.' > "$task"
  out=$(bash "$route" classify --mode interactive-tweak --task-file "$task")
  assert_equals "DR15v: transparent text is excluded from interactive light" \
    "$(jq -r .profile <<< "$out")" "standard"

  : > "$task"
  ec=0; bash "$route" classify --mode autonomous --task-file "$task" >/dev/null 2>&1 || ec=$?
  assert_exit_code "DR16: empty task is invalid" "$ec" 2
  rm -rf "$wd"

  repo=$(mktemp -d)
  git init -q "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  printf '%s\n' '# Guide' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm init
  out=$(cd "$repo" && bash "$route" check-diff --base HEAD)
  assert_equals "DR17: empty diff is mechanical" "$(jq -r .profile <<< "$out")" "mechanical"
  printf '%s\n' '# Guide fixed' > "$repo/README.md"
  out=$(cd "$repo" && bash "$route" check-diff --base HEAD)
  assert_equals "DR18: bounded docs diff is light" "$(jq -r .profile <<< "$out")" "light"
  git -C "$repo" restore README.md
  printf '%s\n' '# Syntax typo fixed' > "$repo/README.md"
  out=$(cd "$repo" && bash "$route" check-diff --base HEAD)
  assert_equals "DR18a: syntax in a docs diff does not match tax" "$(jq -r .profile <<< "$out")" "light"
  git -C "$repo" restore README.md
  task=$(mktemp)
  for parity_signal in src/auth/session.ts src/billing/invoice.ts db/migrations/001.sql \
      src/privacy/consent.ts src/accounting/xbrl.ts src/financial/reporting.ts \
      src/taxonomy/loader.ts src/andmesild/client.ts config/.env; do
    printf 'Repair bounded behavior in %s.\n' "$parity_signal" > "$task"
    ec=0; out=$(bash "$route" classify --mode autonomous --task-file "$task") || ec=$?
    assert_exit_code "DR18a1: pre-route recognizes $parity_signal as sensitive" "$ec" 20
    printf '# Surface: %s\n' "$parity_signal" > "$repo/README.md"
    ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD) || ec=$?
    assert_exit_code "DR18a2: post-diff matches pre-route for $parity_signal" "$ec" 20
    assert_equals "DR18a3: post-diff marks $parity_signal sensitive" \
      "$(jq -r .sensitive <<< "$out")" "true"
    git -C "$repo" restore README.md
  done
  rm -f "$task"
  for sensitive_signal in encryption crypto TLS SSL certificate RBAC ACL \
      'credit card' 'debit card' cardholder 'PCI DSS' SEPA chargeback \
      'bank account' 'bank details'; do
    printf '# %s guide\n' "$sensitive_signal" > "$repo/README.md"
    ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD) || ec=$?
    assert_exit_code "DR18b: $sensitive_signal diff escalates" "$ec" 20
    assert_equals "DR18c: $sensitive_signal diff is sensitive" \
      "$(jq -r .sensitive <<< "$out")" "true"
    git -C "$repo" restore README.md
  done
  mkdir -p "$repo/src/auth"
  printf '%s\n' 'export const session = true;' > "$repo/src/auth/session.ts"
  ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD) || ec=$?
  assert_exit_code "DR19: untracked sensitive file escalates" "$ec" 20
  assert_equals "DR20: untracked auth file is sensitive" "$(jq -r .sensitive <<< "$out")" "true"
  rm -rf "$repo"

  repo=$(mktemp -d)
  git init -q "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  mkdir -p "$repo/src"
  printf '%s\n' '<button>Save</button>' > "$repo/src/Button.tsx"
  printf '%s\n' '<button disabled={false}>Save</button>' > "$repo/src/Button.jsx"
  printf '%s\n' '<button disabled="false">Save</button>' > "$repo/src/button.html"
  printf '%s\n' '<button :disabled="false">Save</button>' > "$repo/src/Button.vue"
  printf '%s\n' '<button disabled={false}>Save</button>' > "$repo/src/Button.svelte"
  printf '%s\n' '<button>' '  Save changes' '</button>' > "$repo/src/TextButton.tsx"
  printf '%s\n' '.button { color: red; }' > "$repo/src/button.css"
  printf '%s\n' '.navigation { font-size: 16px; }' > "$repo/src/size.css"
  printf '%s\n' '.navigation { margin: 4px; }' > "$repo/src/space.css"
  git -C "$repo" add src && git -C "$repo" commit -qm init

  printf '%s\n' '<button>Continue</button>' > "$repo/src/Button.tsx"
  out=$(cd "$repo" && bash "$route" check-diff --base HEAD)
  assert_equals "DR20a: unchanged TSX structure with literal text is light" "$(jq -r .profile <<< "$out")" "light"
  git -C "$repo" restore src/Button.tsx

  printf '%s\n' '<button>' '  Continue safely' '</button>' > "$repo/src/TextButton.tsx"
  out=$(cd "$repo" && bash "$route" check-diff --base HEAD)
  assert_equals "DR20aa: bounded TSX text-node substitution is light" "$(jq -r .profile <<< "$out")" "light"
  git -C "$repo" restore src/TextButton.tsx

  printf '%s\n' '.button { color: blue; }' > "$repo/src/button.css"
  out=$(cd "$repo" && bash "$route" check-diff --base HEAD)
  assert_equals "DR20b: stylesheet-only UI change is light" "$(jq -r .profile <<< "$out")" "light"
  git -C "$repo" restore src/button.css

  printf '%s\n' '.button { color: transparent; }' > "$repo/src/button.css"
  ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD) || ec=$?
  assert_exit_code "DR20b1: transparent color escalates" "$ec" 20
  git -C "$repo" restore src/button.css

  printf '%s\n' '.navigation { font-size: 0; }' > "$repo/src/size.css"
  ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD) || ec=$?
  assert_exit_code "DR20b2: zero font size escalates" "$ec" 20
  git -C "$repo" restore src/size.css

  printf '%s\n' '.navigation { margin: -9999px; }' > "$repo/src/space.css"
  ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD) || ec=$?
  assert_exit_code "DR20b3: extreme negative spacing escalates" "$ec" 20
  git -C "$repo" restore src/space.css

  printf '%s\n' '.navigation { margin: 2rem; }' > "$repo/src/space.css"
  out=$(cd "$repo" && bash "$route" check-diff --base HEAD)
  assert_equals "DR20b4: bounded relative-unit spacing stays light" \
    "$(jq -r .profile <<< "$out")" "light"
  git -C "$repo" restore src/space.css

  printf '%s\n' '.navigation { margin: 64rem; }' > "$repo/src/space.css"
  ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD) || ec=$?
  assert_exit_code "DR20b5: extreme relative-unit spacing escalates" "$ec" 20
  git -C "$repo" restore src/space.css

  printf '%s\n' '.button { pointer-events: none; }' > "$repo/src/button.css"
  ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD) || ec=$?
  assert_exit_code "DR20ba: interaction-changing CSS escalates" "$ec" 20
  assert_equals "DR20bb: behavioral stylesheet reason is explicit" \
    "$(jq -r '.reasons | index("diff_behavioral_ui_code") != null' <<< "$out")" "true"
  git -C "$repo" restore src/button.css

  for ui_file in Button.jsx button.html Button.vue Button.svelte; do
    sed 's/false/true/' "$repo/src/$ui_file" > "$repo/src/$ui_file.next"
    mv "$repo/src/$ui_file.next" "$repo/src/$ui_file"
    ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD) || ec=$?
    assert_exit_code "DR20c: $ui_file attribute/expression change escalates" "$ec" 20
    assert_equals "DR20d: $ui_file is behavioral UI" \
      "$(jq -r '.reasons | index("diff_behavioral_ui_code") != null' <<< "$out")" "true"
    git -C "$repo" restore "src/$ui_file"
  done

  printf '%s\n' '<button>{canSubmit}</button>' > "$repo/src/Button.tsx"
  ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD) || ec=$?
  assert_exit_code "DR20e: TSX expression change escalates" "$ec" 20
  git -C "$repo" restore src/Button.tsx
  rm -rf "$repo"

  repo=$(mktemp -d)
  git init -q "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  printf '%s\n' '.env' 'cache/' > "$repo/.gitignore"
  printf '%s\n' '# baseline copy' > "$repo/README.md"
  git -C "$repo" add .gitignore README.md && git -C "$repo" commit -qm init
  mkdir -p "$repo/cache"
  printf '%s\n' 'harmless' > "$repo/cache/result.txt"
  out=$(cd "$repo" && bash "$route" check-diff --base HEAD)
  assert_equals "DR20f: ignored nonsensitive path keeps an empty diff mechanical" "$(jq -r .profile <<< "$out")" "mechanical"
  printf '%s\n' 'CUSTOMER_NAME=private-fixture' > "$repo/.env"
  printf '%s\n' '# bounded copy change' > "$repo/README.md"
  ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD) || ec=$?
  assert_exit_code "DR20g: unguarded ignored sensitive state escalates" "$ec" 20
  assert_equals "DR20g1: unguarded escalation names ignored sensitive state" \
    "$(jq -r '.reasons | index("diff_ignored_sensitive_path") != null' <<< "$out")" "true"
  assert_output_not_contains "DR20g2: ignored sensitive contents are never exposed" "$out" "private-fixture"
  ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD --guard-verified) || ec=$?
  assert_exit_code "DR20g3: verified mutation guard permits changed-path routing" "$ec" 0
  assert_equals "DR20h: guarded routing is based on changed paths only" \
    "$(jq -r '.reasons | index("diff_ignored_sensitive_path") == null' <<< "$out")" "true"
  assert_output_not_contains "DR20i: ignored sensitive file contents are never exposed" "$out" "private-fixture"
  rm -rf "$repo"

  repo=$(mktemp -d)
  git init -q "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  mkdir -p "$repo/frontend/src/app/[locale]/report" "$repo/frontend/src/hooks"
  printf '%s\n' '.env' 'cache/' > "$repo/.gitignore"
  printf '%s\n' 'export default function Report() { return <p>Before</p>; }' \
    > "$repo/frontend/src/app/[locale]/report/page.tsx"
  printf '%s\n' 'export const wizardEvent = "before";' \
    > "$repo/frontend/src/hooks/useWizardAnalytics.ts"
  printf '%s\n' 'export const expectedEvent = "before";' \
    > "$repo/frontend/src/hooks/useWizardAnalytics.test.ts"
  git -C "$repo" add .gitignore frontend && git -C "$repo" commit -qm init
  mkdir -p "$repo/cache/database"
  printf '%s\n' 'TRANSIENT_PRIVATE_FIXTURE=hidden' > "$repo/.env"
  printf '%s\n' 'transient' > "$repo/cache/database/result.txt"
  printf '%s\n' 'export default function Report() { return <p>After</p>; }' \
    > "$repo/frontend/src/app/[locale]/report/page.tsx"
  printf '%s\n' 'export const wizardEvent = "after";' \
    > "$repo/frontend/src/hooks/useWizardAnalytics.ts"
  printf '%s\n' 'export const expectedEvent = "after";' \
    > "$repo/frontend/src/hooks/useWizardAnalytics.test.ts"
  ec=0; out=$(cd "$repo" && bash "$route" check-diff --base HEAD --guard-verified) || ec=$?
  assert_exit_code "DR20i1: exact report and analytics paths retain their semantic route" "$ec" 20
  assert_equals "DR20i2: exact normal paths are not classified from transient ignored state" \
    "$(jq -r '.reasons | index("diff_ignored_sensitive_path") == null' <<< "$out")" "true"
  assert_equals "DR20i3: exact source diff retains its real behavioral UI reason" \
    "$(jq -r '.reasons | index("diff_behavioral_ui_code") != null' <<< "$out")" "true"
  assert_output_not_contains "DR20i4: transient ignored contents remain private" \
    "$out" 'TRANSIENT_PRIVATE_FIXTURE'
  rm -rf "$repo"

  repo=$(mktemp -d); bin="$repo/bin"; mkdir -p "$bin"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name Test
  printf '%s\n' 'base' > "$repo/base.txt"
  git -C "$repo" add base.txt && git -C "$repo" commit -qm init
  printf '%s\n' 'Make the bounded change.' > "$repo/task.md"
  calls="$repo/calls.log"; events="$repo/events.jsonl"
  cat > "$bin/codex" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_CODEX_CALLS"
bypass_count=0
for arg in "$@"; do
  [ "$arg" = "--dangerously-bypass-approvals-and-sandbox" ] \
    && bypass_count=$((bypass_count + 1))
  if [ "$arg" = "-s" ]; then
    echo "role launch used a legacy -s sandbox selector" >&2
    exit 97
  fi
  case "$arg" in
    *saas-network-off*|*network_proxy*|*sandbox_workspace_write.network_access*)
      echo "role launch used a legacy network-off profile or proxy: $arg" >&2
      exit 97
      ;;
  esac
done
if [ "$bypass_count" -ne 1 ]; then
  echo "role launch requires exactly one --dangerously-bypass-approvals-and-sandbox" >&2
  exit 97
fi
args=("$@")
emit_message() {
  jq -cn --arg text "$1" \
    '{type:"item.completed",item:{type:"agent_message",text:$text}}'
}
[ -z "${FAKE_CODEX_PROMPT:-}" ] || cat > "$FAKE_CODEX_PROMPT"
[ -z "${FAKE_CODEX_ENV:-}" ] || printf '%s\t%s\t%s\n' \
  "${TRIBUNAL_CALLER_PROVIDER:-}" "${TRIBUNAL_CALLER_MODEL:-}" \
  "${TRIBUNAL_CALLER_EFFORT:-}" > "$FAKE_CODEX_ENV"
case "${FAKE_CODEX_MODE:-success}" in
  verbose_stream)
    message=$(
      {
        printf '%s\n' 'bounded final agent response'
        i=0
        while [ "$i" -lt 400 ]; do
          printf 'final-detail-%03d-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\n' "$i"
          i=$((i + 1))
        done
      }
    )
    i=0
    while [ "$i" -lt 4000 ]; do
      printf '{"type":"item.completed","item":{"type":"command_execution","text":"raw-stream-marker-%04d-abcdefghijklmnopqrstuvwxyz0123456789"}}\n' "$i"
      i=$((i + 1))
    done
    emit_message "$message"
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":700,"output_tokens":80,"cached_input_tokens":30}}'
    exit 0
    ;;
  terra_unavailable)
    if printf '%s\n' "$*" | grep -q 'gpt-5.6-terra'; then
      echo 'model gpt-5.6-terra is unavailable' >&2
      exit 1
    fi
    ;;
  terra_unavailable_reverse)
    if printf '%s\n' "$*" | grep -q 'gpt-5.6-terra'; then
      echo 'model unavailable: gpt-5.6-terra' >&2
      exit 1
    fi
    ;;
  sol_unavailable)
    if printf '%s\n' "$*" | grep -q 'gpt-5.6-sol'; then
      echo 'model gpt-5.6-sol is unavailable' >&2
      exit 1
    fi
    ;;
  unrelated_unavailable)
    echo 'tool failed after observing that gpt-4-legacy is unavailable' >&2
    exit 1
    ;;
  same_model_task_failure)
    echo 'task failed while checking whether model gpt-5.6-terra is unavailable in documentation' >&2
    exit 1
    ;;
  task_failure)
    echo 'local tests failed' >&2
    exit 1
    ;;
  timeout_failure)
    exit 124
    ;;
esac
emit_message 'final agent response'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":20,"cached_input_tokens":10}}'
SH
  chmod +x "$bin/codex"

  login_home="$repo/login-home"
  mkdir -p "$login_home" "$repo/login-elsewhere"
  printf 'cd "%s"\n' "$repo/login-elsewhere" > "$login_home/.profile"
  : > "$calls"; ec=0
  out=$(cd "$repo" && HOME="$login_home" PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" \
    bash "$launcher" --role analyst --profile standard --task-file task.md 2>&1) || ec=$?
  assert_exit_code "DR20j: login startup cwd change fails closed" "$ec" 4
  assert_output_contains "DR20k: login startup failure is actionable" "$out" \
    'login startup changes cwd'
  assert_equals "DR20l: login startup cwd change launches no worker" \
    "$(wc -l < "$calls" | tr -d ' ')" "0"
  rm -rf "$login_home" "$repo/login-elsewhere"

  login_home="$repo/login-home"
  mkdir -p "$login_home"
  printf '%s\n' 'sleep 30' > "$login_home/.profile"
  : > "$calls"; ec=0
  out=$(cd "$repo" && HOME="$login_home" PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" \
    bash "$launcher" --role analyst --profile standard --task-file task.md 2>&1) || ec=$?
  assert_exit_code "DR20m: hanging login startup fails closed" "$ec" 4
  assert_output_contains "DR20n: hanging login startup failure is actionable" "$out" \
    'could not verify the login-shell working directory'
  assert_equals "DR20o: hanging login startup launches no worker" \
    "$(wc -l < "$calls" | tr -d ' ')" "0"
  rm -rf "$login_home"

  : > "$calls"
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_PROMPT="$repo/tech-prompt.txt" SAAS_AGENT_EVENTS_FILE="$events" \
    bash "$launcher" --role tech-founder --profile standard --task-file task.md >/dev/null)
  assert_equals "DR21: standard launch calls Codex once" "$(wc -l < "$calls" | tr -d ' ')" "1"
  assert_file_contains "DR22: standard launch pins Sol" "$calls" '-m gpt-5.6-sol'
  assert_file_contains "DR23: standard launch pins high effort" "$calls" 'model_reasoning_effort="high"'
  assert_file_contains "DR23a0: source writer uses unrestricted container execution" "$calls" \
    '--dangerously-bypass-approvals-and-sandbox'
  assert_equals "DR23a: source writer passes the unrestricted flag exactly once" \
    "$(grep -o -- '--dangerously-bypass-approvals-and-sandbox' "$calls" | wc -l | tr -d ' ')" "1"
  assert_equals "DR23b: source writer has no workspace sandbox selector" \
    "$(awk 'index($0, "-s workspace-write") { n++ } END { print n + 0 }' "$calls")" "0"
  assert_equals "DR23b1: source writer has no read-only sandbox selector" \
    "$(awk 'index($0, "-s read-only") { n++ } END { print n + 0 }' "$calls")" "0"
  assert_file_not_contains "DR23b2: source writer has no network-off profile" "$calls" \
    'saas-network-off'
  assert_file_not_contains "DR23b3: source writer has no network proxy" "$calls" \
    'network_proxy'
  assert_file_contains "DR23c: role launcher ignores user configuration" "$calls" '--ignore-user-config'
  assert_file_contains "DR23c1: actual launch disables subagent fan-out" "$calls" '--disable multi_agent'
  assert_file_contains "DR23d: role launcher disables MCP configuration" "$calls" 'mcp_servers={}'
  assert_file_contains "DR23e: role launcher disables native web-search tooling" "$calls" \
    '--disable standalone_web_search'
  assert_equals "DR24: start event leaves effective model null" "$(head -n1 "$events" | jq -r '.effective_model == null')" "true"
  assert_equals "DR25: terminal event records token use" "$(tail -n1 "$events" | jq -r .input_tokens)" "100"
  assert_file_contains "DR25b: tech writer leaves commit to supervisor" "$repo/tech-prompt.txt" 'Leave working-tree changes for the supervisor'
  assert_file_contains "DR25c: tech role receives scoped source writer contract" "$repo/tech-prompt.txt" 'source writer for this task'
  assert_file_contains "DR25c1: tech role receives evidence-gated scope expansion" \
    "$repo/tech-prompt.txt" 'causally blocks `Done`'
  assert_file_contains "DR25c2: tech role quarantines adjacent findings" \
    "$repo/tech-prompt.txt" 'under `Not Addressed`; do not investigate or fix it'
  assert_file_contains "DR25c3: tech role stops instead of recursively auditing" \
    "$repo/tech-prompt.txt" 'Do not begin a general or recursive audit'
  assert_file_contains "DR25c4: tech role receives solo-founder production scope" \
    "$repo/tech-prompt.txt" 'finished production product operated by one founder, never an MVP'

  : > "$calls"; : > "$events"
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_PROMPT="$repo/supervisor-prompt.txt" SAAS_AGENT_EVENTS_FILE="$events" \
    bash "$launcher" --role maintain-loop-supervisor --profile deep --task-file task.md >/dev/null)
  assert_file_contains "DR25d: removed composite supervisor retains its semantic mutation guard" "$repo/supervisor-prompt.txt" 'no mutation grant and must remain read-only'

  : > "$calls"; : > "$events"
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_PROMPT="$repo/business-prompt.txt" SAAS_AGENT_EVENTS_FILE="$events" \
    bash "$launcher" --role business-founder-maintain --profile standard --task-file task.md >/dev/null)
  assert_file_contains "DR25e: business role is brief and proposal only" "$repo/business-prompt.txt" 'write only business/product briefs and proposed workflow-spec deltas'
  assert_file_contains "DR25f: business role cannot mutate source tests or registry" "$repo/business-prompt.txt" 'Never modify product source, tests, or the canonical workflow-spec registry'
  assert_file_contains "DR25f0: business role writes explicit scope fields" \
    "$repo/business-prompt.txt" 'Done, Preserve, and Out of Scope'
  assert_file_contains "DR25f0a: business role receives the resolved handoff template" \
    "$repo/business-prompt.txt" "$PLUGIN_ROOT/templates/handoff-business-to-tech.md"
  assert_file_contains "DR25f0b: business role receives one-pass lean planning" \
    "$repo/business-prompt.txt" 'one targeted repository-discovery pass'
  assert_file_contains "DR25f0c: business role asks only material blockers" \
    "$repo/business-prompt.txt" 'Ask only when a missing choice would materially change'

  for artifact_role in growth-hacker lawyer ux-tester incident-investigator session-replay support-triage; do
    : > "$calls"; : > "$events"
    (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" \
      FAKE_CODEX_PROMPT="$repo/$artifact_role-prompt.txt" SAAS_AGENT_EVENTS_FILE="$events" \
      bash "$launcher" --role "$artifact_role" --profile standard --task-file task.md >/dev/null)
    assert_file_contains "DR25f1: $artifact_role runs unrestricted in the container" \
      "$calls" '--dangerously-bypass-approvals-and-sandbox'
    assert_file_contains "DR25f2: $artifact_role may write local artifacts" \
      "$repo/$artifact_role-prompt.txt" 'write only task-designated local artifacts'
  done

  : > "$calls"; : > "$events"
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" \
    FAKE_CODEX_PROMPT="$repo/maintain-triage-prompt.txt" SAAS_AGENT_EVENTS_FILE="$events" \
    bash "$launcher" --role maintain-triage --profile standard --task-file task.md >/dev/null)
  assert_file_contains "DR25f3: maintain triage remains read-only" \
    "$repo/maintain-triage-prompt.txt" 'This is a read-only/review role'
  assert_file_contains "DR25f4: maintain triage runs unrestricted with a semantic read-only guard" \
    "$calls" '--dangerously-bypass-approvals-and-sandbox'

  : > "$calls"; : > "$events"
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_PROMPT="$repo/qa-prompt.txt" SAAS_AGENT_EVENTS_FILE="$events" \
    bash "$launcher" --role qa --profile standard --task-file task.md >/dev/null)
  assert_file_contains "DR25g: QA role is read-only" "$repo/qa-prompt.txt" 'This is a read-only/review role'
  assert_file_contains "DR25g1: QA runs unrestricted with a semantic read-only guard" \
    "$calls" '--dangerously-bypass-approvals-and-sandbox'

  : > "$calls"; : > "$events"; ec=0
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" SAAS_AGENT_EVENTS_FILE="$events" \
    CODEX_SANDBOX=workspace-write bash "$launcher" --role qa --profile standard \
      --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "DR25g2: QA ignores the legacy writable sandbox value" "$ec" 0
  assert_equals "DR25g3: ignored QA sandbox value still launches one worker" \
    "$(wc -l < "$calls" | tr -d ' ')" "1"
  assert_file_contains "DR25g4: ignored QA sandbox value cannot replace unrestricted mode" \
    "$calls" '--dangerously-bypass-approvals-and-sandbox'
  assert_equals "DR25g5: ignored QA sandbox value is not forwarded" \
    "$(awk 'index($0, "-s workspace-write") { n++ } END { print n + 0 }' "$calls")" "0"

  : > "$calls"; : > "$events"
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_PROMPT="$repo/unknown-prompt.txt" SAAS_AGENT_EVENTS_FILE="$events" \
    bash "$launcher" --role analyst --profile standard --task-file task.md >/dev/null)
  assert_file_contains "DR25h: unknown role retains its semantic mutation guard" "$repo/unknown-prompt.txt" 'no mutation grant and must remain read-only'
  assert_file_contains "DR25h1: unknown role still runs unrestricted in the container" \
    "$calls" '--dangerously-bypass-approvals-and-sandbox'

  : > "$calls"; : > "$events"
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=terra_unavailable \
    SAAS_AGENT_EVENTS_FILE="$events" bash "$launcher" --role tech-founder --profile light --task-file task.md >/dev/null)
  assert_equals "DR26: Terra unavailable retries exactly once" "$(wc -l < "$calls" | tr -d ' ')" "2"
  assert_equals "DR27: fallback uses Sol/medium" "$(tail -n1 "$calls" | grep -c -- '-m gpt-5.6-sol .*model_reasoning_effort="medium"')" "1"
  assert_equals "DR28: fallback reason recorded" "$(tail -n1 "$events" | jq -r '.routing_reasons | index("terra_unavailable_fallback") != null')" "true"
  assert_equals "DR29: fallback effective model recorded" "$(tail -n1 "$events" | jq -r .effective_model)" "gpt-5.6-sol"

  : > "$calls"; : > "$events"
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=terra_unavailable_reverse \
    SAAS_AGENT_EVENTS_FILE="$events" bash "$launcher" --role tech-founder --profile light --task-file task.md >/dev/null)
  assert_equals "DR29b: reversed explicit Terra error retries once" "$(wc -l < "$calls" | tr -d ' ')" "2"

  : > "$calls"; : > "$events"; ec=0
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=sol_unavailable \
    SAAS_AGENT_EVENTS_FILE="$events" bash "$launcher" --role tech-founder --profile standard --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "DR29c: explicit Sol unavailability returns original failure" "$ec" 1
  assert_equals "DR29d: explicit Sol unavailability never falls back" "$(wc -l < "$calls" | tr -d ' ')" "1"
  assert_equals "DR29e: unavailable Sol has no effective execution identity" \
    "$(tail -n1 "$events" | jq '[.effective_provider,.effective_model,.effective_effort] | all(.[]; . == null)')" "true"
  assert_equals "DR29f: unavailable Sol remains the requested model" \
    "$(tail -n1 "$events" | jq -r .requested_model)" "gpt-5.6-sol"

  : > "$calls"; : > "$events"; ec=0
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=unrelated_unavailable \
    SAAS_AGENT_EVENTS_FILE="$events" bash "$launcher" --role tech-founder --profile light --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "DR30: unrelated unavailable-model mention remains failure" "$ec" 1
  assert_equals "DR31: unrelated model mention never falls back" "$(wc -l < "$calls" | tr -d ' ')" "1"
  assert_equals "DR31b: unrelated failure retains actual requested execution identity" \
    "$(tail -n1 "$events" | jq -r .effective_model)" "gpt-5.6-terra"

  : > "$calls"; : > "$events"; ec=0
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=same_model_task_failure \
    SAAS_AGENT_EVENTS_FILE="$events" bash "$launcher" --role tech-founder --profile light --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "DR31c: same-model task wording remains a failure" "$ec" 1
  assert_equals "DR31d: same-model task wording cannot spoof fallback" "$(wc -l < "$calls" | tr -d ' ')" "1"

  : > "$calls"; : > "$events"; ec=0
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=task_failure \
    SAAS_AGENT_EVENTS_FILE="$events" bash "$launcher" --role tech-founder --profile light --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "DR32: task failure propagates" "$ec" 1
  assert_equals "DR33: task failure never falls back" "$(wc -l < "$calls" | tr -d ' ')" "1"

  : > "$calls"; : > "$events"; ec=0
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=timeout_failure \
    SAAS_AGENT_EVENTS_FILE="$events" bash "$launcher" --role tech-founder --profile light --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "DR33b: timeout propagates" "$ec" 124
  assert_equals "DR33c: timeout never triggers fallback" "$(wc -l < "$calls" | tr -d ' ')" "1"

  : > "$calls"; : > "$events"
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" SAAS_AGENT_EVENTS_FILE="$events" \
    SAAS_CODEX_STANDARD_MODEL=custom-model SAAS_CODEX_STANDARD_EFFORT=medium \
    bash "$launcher" --role tech-founder --profile standard --task-file task.md >/dev/null)
  assert_file_contains "DR34: profile model override stays explicit" "$calls" '-m custom-model'
  assert_file_contains "DR35: profile effort override stays explicit" "$calls" 'model_reasoning_effort="medium"'

  : > "$calls"; : > "$events"
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" \
    FAKE_CODEX_ENV="$repo/caller-env.txt" SAAS_AGENT_EVENTS_FILE="$events" \
    bash "$wrapper" --task 'Make the bounded change.' --profile standard \
      --model wrapper-model --effort medium --log wrapper-output.jsonl >/dev/null)
  assert_equals "DR35b: compatibility wrapper launches exactly once" \
    "$(wc -l < "$calls" | tr -d ' ')" "1"
  assert_file_contains "DR35c: wrapper model override remains explicit" "$calls" '-m wrapper-model'
  assert_file_contains "DR35d: wrapper effort override remains explicit" "$calls" 'model_reasoning_effort="medium"'
  assert_equals "DR35e: launcher propagates actual tribunal caller identity" \
    "$(cat "$repo/caller-env.txt")" $'openai\twrapper-model\tmedium'

  : > "$calls"; : > "$events"
  summary="$repo/codex-summary.txt"
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" FAKE_CODEX_MODE=verbose_stream \
    SAAS_AGENT_EVENTS_FILE="$events" SAAS_CODEX_LOG_DIR="$repo/codex-logs" \
    bash "$launcher" --role analyst --profile standard --task-file task.md > "$summary" 2>&1)
  log_file=$(find "$repo/codex-logs" -maxdepth 1 -name '*.jsonl' -print -quit)
  assert_equals "DR35f: terminal worker output stays bounded" \
    "$(awk 'END { print (NR <= 100 && bytes <= 9000) ? "true" : "false" } { bytes += length($0) + 1 }' "$summary")" "true"
  assert_file_contains "DR35g: terminal output includes the trailing verdict detail" \
    "$summary" 'codex-worker: final-detail-399'
  assert_file_contains "DR35h: terminal output includes compact usage" \
    "$summary" 'usage\[input=700 output=80 cached=30\]'
  assert_file_not_contains "DR35i: raw JSON events never reach terminal output" \
    "$summary" 'raw-stream-marker'
  assert_file_contains "DR35j: raw JSON events remain in the configured log directory" \
    "$log_file" 'raw-stream-marker-3999'
  assert_file_contains "DR35k: untruncated last message remains beside the raw log" \
    "$log_file.last-message" 'final-detail-399'

  : > "$calls"; ec=0
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" bash "$launcher" \
    --role tech-founder --profile mechanical --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "DR36: mechanical profile refuses a model worker" "$ec" 2
  assert_equals "DR37: mechanical profile launches zero workers" "$(wc -l < "$calls" | tr -d ' ')" "0"

  : > "$calls"; ec=0
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" SAAS_CODEX_NETWORK_ACCESS=legacy-invalid \
    bash "$launcher" --role tech-founder --profile standard --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "DR37a: source writer ignores legacy network-access values" "$ec" 0
  assert_equals "DR37b: ignored network-access value launches one unrestricted worker" \
    "$(wc -l < "$calls" | tr -d ' ')" "1"
  assert_file_contains "DR37b1: ignored network-access value keeps unrestricted mode" \
    "$calls" '--dangerously-bypass-approvals-and-sandbox'
  assert_file_not_contains "DR37b2: ignored network-access value creates no network-off profile" \
    "$calls" 'saas-network-off'
  assert_file_not_contains "DR37b3: ignored network-access value enables no network proxy" \
    "$calls" 'network_proxy'

  : > "$calls"; ec=0
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" CODEX_SANDBOX=legacy-invalid \
    bash "$launcher" --role tech-founder --profile standard --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "DR37c: source writer ignores legacy sandbox values" "$ec" 0
  assert_equals "DR37d: ignored sandbox value launches one unrestricted worker" \
    "$(wc -l < "$calls" | tr -d ' ')" "1"
  assert_file_contains "DR37d1: ignored sandbox value keeps exact unrestricted mode" \
    "$calls" '--dangerously-bypass-approvals-and-sandbox'
  assert_equals "DR37d2: ignored sandbox value is not forwarded" \
    "$(awk 'index($0, "-s ") { n++ } END { print n + 0 }' "$calls")" "0"

  : > "$calls"; ec=0
  (cd "$repo" && PATH="$bin:$PATH" FAKE_CODEX_CALLS="$calls" SAAS_CODEX_ISOLATED_CONFIG=0 \
    bash "$launcher" --role qa --profile standard --task-file task.md >/dev/null 2>&1) || ec=$?
  assert_exit_code "DR37e: roles cannot re-enable user Codex configuration" "$ec" 2
  assert_equals "DR37f: rejected configuration override launches zero workers" \
    "$(wc -l < "$calls" | tr -d ' ')" "0"
  rm -rf "$repo"

  local root static_ec=0
  root=$(cd "$PLUGIN_ROOT/../.." && pwd)
  python3 - "$root" <<'PY' || static_ec=$?
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
targets = [root / "plugins/saas-startup-team", root / "plugins/tribunal-review"]
bad = []
for target in targets:
    paths = [p for p in target.rglob("*") if p.suffix in {".sh", ".md", ".py"}
             and "tests" not in p.parts
             and not ("docs" in p.parts and "superpowers" in p.parts)]
    for path in paths:
        lines = path.read_text(encoding="utf-8").splitlines()
        fenced = False
        for i, line in enumerate(lines):
            stripped = line.strip()
            if path.suffix == ".md" and stripped.startswith("```"):
                fenced = not fenced
                continue
            executable = path.suffix == ".sh" and not stripped.startswith("#")
            executable = executable or (path.suffix == ".md" and fenced)
            if not executable:
                continue
            if not (re.search(r"\bcodex\s+exec\b", line) or re.search(r"CODEX[^ ]*.*\bexec\b", line)):
                continue
            if re.search(r"\bcodex\s+exec\s+--help\b", line):
                continue
            window = " ".join(lines[max(0, i-4):i+4])
            if not re.search(r"(^|[\s(])-m(\s|\")", window) or "model_reasoning_effort" not in window:
                bad.append(f"{path.relative_to(root)}:{i+1}")
if bad:
    print("unpinned codex exec: " + ", ".join(bad), file=sys.stderr)
    raise SystemExit(1)
PY
  assert_exit_code "DR38: affected plugins contain no unpinned executable codex exec" "$static_ec" 0

  static_ec=0
  python3 - "$root" <<'PY' || static_ec=$?
import pathlib, sys
root = pathlib.Path(sys.argv[1])
plugin = root / "plugins/saas-startup-team"
paths = [plugin / "README.md"]
for folder in ("commands", "agents", "references", "skills"):
    paths.extend((plugin / folder).rglob("*.md"))
bad = []
for path in paths:
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if "codex exec" in line.lower():
            bad.append(f"{path.relative_to(root)}:{line_no}")
if bad:
    print("direct Codex guidance bypasses codex-run-role.sh: " + ", ".join(bad), file=sys.stderr)
    raise SystemExit(1)
PY
  assert_exit_code "DR38b: SaaS operational guidance never bypasses the pinned launcher" "$static_ec" 0

  static_ec=0
  python3 - "$root" <<'PY' || static_ec=$?
import importlib.util, pathlib, sys
root = pathlib.Path(sys.argv[1])
path = root / "scripts/sync-codex-marketplace.py"
spec = importlib.util.spec_from_file_location("sync_codex_marketplace", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
command = root / "plugins/saas-startup-team/commands/improve.md"
metadata = module.read_command_metadata(command)
rendered = module.render_command_skill(
    plugin_name="saas-startup-team", command_name="improve", command_path=command,
    metadata=metadata, skill_name="saas-startup-team-improve-workflow"
)
assert "scripts/codex-run-role.sh" in rendered
assert "gpt-5" not in rendered
PY
  assert_exit_code "DR39: generated SaaS adapter points to model-neutral pinned launcher" "$static_ec" 0

  local refs="$PLUGIN_ROOT/references/workflows"
  assert_file_contains "DR40: tweak selects interactive versus autonomous mode" "$refs/tweak.md" '--mode "$route_mode"'
  assert_file_contains "DR41: tweak passes mode to post-diff helper" "$refs/tweak.md" '--routing-mode "$route_mode"'
  assert_file_contains "DR42: goal fast path classifies autonomous intent" "$refs/goal-deliver.md" '--mode autonomous'
  assert_file_contains "DR43: goal fast path excludes UI touch" "$refs/goal-deliver.md" 'ui_touch=false'
  assert_file_contains "DR44: improve loads shared routing/event contract" "$refs/improve.md" 'routing-telemetry.md'
  assert_file_contains "DR45: improve uses pinned separate-role launcher" "$refs/improve.md" 'codex-run-role.sh --role tech-founder'
  assert_file_contains "DR46: maintain cheap triage is a registered role" "$refs/maintain.md" 'saas-startup-team:maintain-triage'
  assert_file_contains "DR47: maintain uncertainty escalates to Fable role" "$refs/maintain.md" 'saas-startup-team:business-founder-maintain'
  assert_file_contains "DR48: maintain-loop preserves attempt escalation evidence" "$refs/maintain-loop-protocol.md" 'issue-<N>-attempt-<A>.json'
  assert_file_contains "DR49: startup routes handoffs semantically" "$PLUGIN_ROOT/commands/startup.md" 'delivery-route.sh classify --mode autonomous'
  assert_file_contains "DR50: lessons uses supervisor-owned commit gate" "$PLUGIN_ROOT/commands/lessons-deliver.md" 'scripts/supervisor-commit.sh'
  assert_file_contains "DR50a: lessons current-session implementation loads tech-founder skill" \
    "$PLUGIN_ROOT/commands/lessons-deliver.md" 'load and use the `tech-founder` skill'
}

test_delivery_routing
