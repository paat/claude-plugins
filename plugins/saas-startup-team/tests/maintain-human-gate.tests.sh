# Sourced by run-tests.sh — maintain-human-gate park decisions (#332).
declare -F assert_exit_code >/dev/null 2>&1 || {
  echo "maintain-human-gate.tests.sh must be sourced by tests/run-tests.sh" >&2
  return 2 2>/dev/null || exit 2
}

test_maintain_human_gate() {
  echo -e "\n${CYAN}Suite MHG: human-gate park decisions${NC}"
  local helper="$PLUGIN_ROOT/scripts/maintain-human-gate.sh"
  local dir out ec

  assert_file_exists "MHG1: helper exists" "$helper"
  dir=$(mktemp -d)

  printf '%s\n' '["epic","needs-human"]' > "$dir/labels.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'epic / tracking' \
    --labels-file "$dir/labels.json" --has-needs-human true)
  assert_equals "MHG2: epic never parks" "$(jq -r .park <<<"$out")" "false"
  assert_equals "MHG3: epic action" "$(jq -r .action <<<"$out")" "exclude-epic"
  assert_equals "MHG4: epic removes stale needs-human" \
    "$(jq -r .remove_needs_human <<<"$out")" "true"
  assert_equals "MHG5: epic digest" "$(jq -r .digest <<<"$out")" "excluded:epic"

  printf '%s\n' '["bug"]' > "$dir/labels.json"
  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'blocked pending epic decision' --labels-file "$dir/labels.json")
  assert_equals "MHG6: mentioning epic in prose does not exclude" \
    "$(jq -r .park <<<"$out")" "true"

  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'child of epic' --reason-kind epic --labels-file "$dir/labels.json")
  assert_equals "MHG6b: reason-kind epic excludes without label" \
    "$(jq -r .action <<<"$out")" "exclude-epic"

  printf '%s\n' $'Please proceed.\nmaintain:human-cleared\n' > "$dir/body.txt"
  body=$(cat "$dir/body.txt")
  jq -n --arg body "$body" \
    '[{body:$body, author_association:"OWNER", user:{login:"paat"}}]' \
    > "$dir/comments.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'product prioritization' \
    --labels-file "$dir/labels.json" --comments-file "$dir/comments.json" \
    --has-needs-human true)
  assert_equals "MHG7: owner standalone line clears" "$(jq -r .action <<<"$out")" "override-cleared"
  assert_equals "MHG8: override by login" "$(jq -r .override_by <<<"$out")" "paat"
  assert_equals "MHG9: override via comment" "$(jq -r .override_via <<<"$out")" "comment"
  assert_equals "MHG10: remove stale label" "$(jq -r .remove_needs_human <<<"$out")" "true"
  assert_equals "MHG11: digest records override" \
    "$(jq -r .digest <<<"$out")" "verdict-overridden-by:paat"

  printf '%s\n' '["bug","maintain:human-cleared"]' > "$dir/labels.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'UX prioritization' \
    --labels-file "$dir/labels.json")
  assert_equals "MHG12: label clears" "$(jq -r .action <<<"$out")" "override-cleared"
  assert_equals "MHG13: via label" "$(jq -r .override_via <<<"$out")" "label"

  printf '%s\n' '["bug"]' > "$dir/labels.json"
  jq -n '[{body:"maintain:human-cleared", author_association:"CONTRIBUTOR", user:{login:"rando"}}]' \
    > "$dir/comments.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'product prioritization' \
    --labels-file "$dir/labels.json" --comments-file "$dir/comments.json")
  assert_equals "MHG14: contributor cannot clear" "$(jq -r .park <<<"$out")" "true"

  jq -n '[{body:"do not use maintain:human-cleared here", author_association:"OWNER", user:{login:"paat"}}]' \
    > "$dir/comments.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'product prioritization' \
    --labels-file "$dir/labels.json" --comments-file "$dir/comments.json")
  assert_equals "MHG14b: negated mention does not clear" "$(jq -r .park <<<"$out")" "true"

  jq -n '[{body:"```\nmaintain:human-cleared\n```", author_association:"OWNER", user:{login:"paat"}}]' \
    > "$dir/comments.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'product prioritization' \
    --labels-file "$dir/labels.json" --comments-file "$dir/comments.json")
  assert_equals "MHG14b2: fenced marker does not clear" "$(jq -r .park <<<"$out")" "true"

  jq -n '[{body:"    maintain:human-cleared", author_association:"OWNER", user:{login:"paat"}}]' \
    > "$dir/comments.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'product prioritization' \
    --labels-file "$dir/labels.json" --comments-file "$dir/comments.json")
  assert_equals "MHG14b3: indented marker does not clear" "$(jq -r .park <<<"$out")" "true"

  jq -n '[{body:"<!-- maintain:bot:12 -->\nmaintain:human-cleared\n", author_association:"OWNER", user:{login:"botty"}}]' \
    > "$dir/comments.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'product prioritization' \
    --labels-file "$dir/labels.json" --comments-file "$dir/comments.json")
  assert_equals "MHG14c: bot park comment cannot clear" "$(jq -r .park <<<"$out")" "true"

  jq -n '[{body:"maintain:human-cleared", author_association:"MEMBER", user:{login:"teammate"}}]' \
    > "$dir/comments.json"
  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'need credentials for production DB' --reason-kind credentials \
    --labels-file "$dir/labels.json" --comments-file "$dir/comments.json")
  assert_equals "MHG16: credentials ignore override" "$(jq -r .park <<<"$out")" "true"
  assert_equals "MHG17: credential digest" \
    "$(jq -r .digest <<<"$out")" "needs-human:credential-override-ignored"

  # Free-text "credentials" without kind does not force credential mode; clear works.
  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'no credentials needed — prioritization only' \
    --labels-file "$dir/labels.json" --comments-file "$dir/comments.json")
  # comments still have MEMBER clear from above
  assert_equals "MHG17b: free-text credentials word does not block clear" \
    "$(jq -r .action <<<"$out")" "override-cleared"

  ec=0
  bash "$helper" evaluate --verdict needs-human --reason 'x' 2>/dev/null || ec=$?
  assert_exit_code "MHG17c: needs-human without labels source fails" "$ec" 2

  out=$(bash "$helper" evaluate --verdict agent-fixable --reason 'clear bug' \
    --labels-file "$dir/labels.json")
  assert_equals "MHG18: non-nh verdict is no-op" "$(jq -r .action <<<"$out")" "no-op"

  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'payment disposition: refund vs honour promo' \
    --labels-file "$dir/labels.json")
  assert_equals "MHG20: spend disposition parks" "$(jq -r .park <<<"$out")" "true"

  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'need production DB credentials' --reason-kind credentials \
    --labels-file "$dir/labels.json")
  assert_equals "MHG20cred: credentials kind parks" "$(jq -r .park <<<"$out")" "true"

  # #1668: failing internal jobs are engineering, not needs-human.
  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'nightly-lessons-harvest failed exit=1 — human must authorize re-run' \
    --labels-file "$dir/labels.json" --has-needs-human true)
  assert_equals "MHG20d: nightly job does not park" "$(jq -r .park <<<"$out")" "false"
  assert_equals "MHG20e: reject-not-human action" "$(jq -r .action <<<"$out")" "reject-not-human"
  assert_equals "MHG20f: remove stale nh on reject" \
    "$(jq -r .remove_needs_human <<<"$out")" "true"
  assert_equals "MHG20g: reject digest" \
    "$(jq -r .digest <<<"$out")" "rejected:not-human-decision"

  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'nightly-replay failed exit=80' --reason-kind judgment \
    --labels-file "$dir/labels.json" --has-needs-human true)
  assert_equals "MHG20h: judgment kind goes to Fable" \
    "$(jq -r .action <<<"$out")" "delegate-fable"
  assert_equals "MHG20h2: judgment does not park" "$(jq -r .park <<<"$out")" "false"
  assert_equals "MHG20h3: judgment strips premature nh" \
    "$(jq -r .remove_needs_human <<<"$out")" "true"
  assert_equals "MHG20h4: judgment digest" \
    "$(jq -r .digest <<<"$out")" "delegate-fable:judgment"

  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'pipeline_error at bank_parse — fix the parser' \
    --labels-file "$dir/labels.json")
  assert_equals "MHG20i: pipeline_error not nh" "$(jq -r .action <<<"$out")" "reject-not-human"

  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'legal/compliance judgment on customer-facing tax copy' \
    --labels-file "$dir/labels.json")
  assert_equals "MHG20j: legal free-text to Fable" \
    "$(jq -r .action <<<"$out")" "delegate-fable"

  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'production sign-off required before enable' \
    --reason-kind production-signoff --labels-file "$dir/labels.json")
  assert_equals "MHG20k: production-signoff kind to Fable" \
    "$(jq -r .action <<<"$out")" "delegate-fable"
  assert_equals "MHG20l: production-signoff digest" \
    "$(jq -r .digest <<<"$out")" "delegate-fable:production-signoff"

  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'refund vs honour promo payment disposition' \
    --labels-file "$dir/labels.json")
  assert_equals "MHG20m: spend disposition still parks" \
    "$(jq -r .park <<<"$out")" "true"

  printf '%s\n' 'product prioritization' > "$dir/reason.txt"
  out=$(bash "$helper" evaluate --verdict needs-human --reason-file "$dir/reason.txt" \
    --labels-file "$dir/labels.json")
  assert_equals "MHG20b: reason-file parks" "$(jq -r .park <<<"$out")" "true"

  # Shell-metacharacters in reason-file must not break evaluate.
  printf '%s\n' 'quote " and $(echo hi) and `x`' > "$dir/reason-meta.txt"
  out=$(bash "$helper" evaluate --verdict needs-human --reason-file "$dir/reason-meta.txt" \
    --labels-file "$dir/labels.json")
  assert_equals "MHG20c: metachar reason still parks" "$(jq -r .park <<<"$out")" "true"

  ec=0
  bash "$helper" evaluate --verdict needs-human 2>/dev/null || ec=$?
  assert_exit_code "MHG21: missing reason fails" "$ec" 2

  local protocol="$PLUGIN_ROOT/references/workflows/maintain-protocol.md"
  local maintain="$PLUGIN_ROOT/references/workflows/maintain.md"
  assert_file_contains "MHG22: protocol creates human-cleared label" \
    "$protocol" 'maintain:human-cleared'
  assert_file_contains "MHG23: protocol requires gate evaluate" \
    "$protocol" 'maintain-human-gate.sh'
  assert_file_contains "MHG24: epics are not needs-human" \
    "$protocol" 'Epics are not `needs-human`'
  assert_file_contains "MHG25: maintain pass invokes gate" \
    "$maintain" 'maintain-human-gate.sh evaluate'
  assert_file_contains "MHG26: only gate-approved parks" \
    "$protocol" 'gate-approved'
  if grep -qF -- '--reason-file' "$protocol"; then
    assert_equals "MHG27: reason-file contract" "ok" "ok"
  else
    assert_equals "MHG27: reason-file contract" "missing" "ok"
  fi
  assert_file_contains "MHG28: standalone marker line" \
    "$protocol" 'standalone, unindented line'
  assert_file_contains "MHG29: closed nh definition" \
    "$protocol" 'Closed definition'
  assert_file_contains "MHG30: reject-not-human action table" \
    "$protocol" 'reject-not-human'
  assert_file_contains "MHG31: delegate-fable action table" \
    "$protocol" 'delegate-fable'
  assert_file_contains "MHG32: Fable decision comment marker" \
    "$protocol" '<!-- fable:decision:'
  local fable_agent="$PLUGIN_ROOT/agents/business-founder-maintain.md"
  assert_file_contains "MHG33: Fable agent requires GH comment" \
    "$fable_agent" 'fable:decision:'
  assert_file_contains "MHG34: gate enforces fable-de-gated action" \
    "$protocol" 'fable-de-gated'

  # Mechanical enforcement: marker + Verdict required for park/de-gate after Fable.
  printf '%s\n' '["bug"]' > "$dir/labels.json"
  printf '%s\n' '[]' > "$dir/comments.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'legal judgment on copy' \
    --reason-kind legal --labels-file "$dir/labels.json" --issue 42 \
    --comments-file "$dir/comments.json")
  assert_equals "MHG35: legal without decision comment delegates" \
    "$(jq -r .action <<<"$out")" "delegate-fable"
  assert_equals "MHG36: legal without decision does not park" \
    "$(jq -r .park <<<"$out")" "false"

  body=$'<!-- fable:decision:42 -->\n**Fable decision (2026-07-21):** park for investor\n\n- **Verdict:** `needs-human`\n- **Kind:** legal\n- **Rationale:** Scope needs human counsel.\n- **Investor action (if any):** review counsel memo\n'
  jq -n --arg body "$body" \
    '[{body:$body, author_association:"OWNER", user:{login:"fable-bot"}}]' \
    > "$dir/comments.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'legal judgment on copy' \
    --reason-kind legal --labels-file "$dir/labels.json" --issue 42 \
    --comments-file "$dir/comments.json")
  assert_equals "MHG37: Fable needs-human decision parks" \
    "$(jq -r .action <<<"$out")" "park"
  assert_equals "MHG38: Fable needs-human decision park flag" \
    "$(jq -r .park <<<"$out")" "true"
  assert_equals "MHG39: Fable needs-human digest" \
    "$(jq -r .digest <<<"$out")" "fable-decision:needs-human:legal"

  body=$'<!-- fable:decision:42 -->\n**Fable decision (2026-07-21):** de-gate — agent can ship\n\n- **Verdict:** `agent-fixable`\n- **Kind:** legal\n- **Rationale:** Standard OÜ copy; no novel counsel needed.\n- **Investor action (if any):** none\n'
  jq -n --arg body "$body" \
    '[{body:$body, author_association:"OWNER", user:{login:"fable-bot"}}]' \
    > "$dir/comments.json"
  printf '%s\n' '["bug","needs-human"]' > "$dir/labels.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'legal judgment on copy' \
    --reason-kind legal --labels-file "$dir/labels.json" --issue 42 \
    --comments-file "$dir/comments.json" --has-needs-human true)
  assert_equals "MHG40: Fable agent-fixable de-gates" \
    "$(jq -r .action <<<"$out")" "fable-de-gated"
  assert_equals "MHG41: Fable de-gate removes needs-human" \
    "$(jq -r .remove_needs_human <<<"$out")" "true"
  assert_equals "MHG42: Fable de-gate does not park" \
    "$(jq -r .park <<<"$out")" "false"

  # Prose-only "Fable decision" without HTML marker must not park.
  body=$'**Fable decision (2026-07-21):** needs-human removed. Ship it.\n\n- **Verdict:** `agent-fixable`\n'
  jq -n --arg body "$body" \
    '[{body:$body, author_association:"OWNER", user:{login:"paat"}}]' \
    > "$dir/comments.json"
  printf '%s\n' '["bug"]' > "$dir/labels.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'legal judgment on copy' \
    --reason-kind legal --labels-file "$dir/labels.json" --issue 42 \
    --comments-file "$dir/comments.json")
  assert_equals "MHG43: prose-only Fable decision still delegates" \
    "$(jq -r .action <<<"$out")" "delegate-fable"

  # Wrong issue number in marker does not authorize park.
  body=$'<!-- fable:decision:99 -->\n**Fable decision (2026-07-21):** park\n\n- **Verdict:** `needs-human`\n- **Kind:** legal\n- **Rationale:** x\n- **Investor action (if any):** none\n'
  jq -n --arg body "$body" \
    '[{body:$body, author_association:"OWNER", user:{login:"fable-bot"}}]' \
    > "$dir/comments.json"
  out=$(bash "$helper" evaluate --verdict needs-human --reason 'legal judgment on copy' \
    --reason-kind legal --labels-file "$dir/labels.json" --issue 42 \
    --comments-file "$dir/comments.json")
  assert_equals "MHG44: wrong-issue marker does not authorize" \
    "$(jq -r .action <<<"$out")" "delegate-fable"

  rm -rf "$dir"
}

test_maintain_human_gate
