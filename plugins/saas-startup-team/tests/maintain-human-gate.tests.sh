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

  out=$(bash "$helper" evaluate --verdict needs-human --reason 'legal judgment required' \
    --labels-file "$dir/labels.json")
  assert_equals "MHG20: ordinary nh parks" "$(jq -r .park <<<"$out")" "true"

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
    --labels-file "$dir/labels.json")
  assert_equals "MHG20h: explicit judgment kind still parks" \
    "$(jq -r .park <<<"$out")" "true"

  out=$(bash "$helper" evaluate --verdict needs-human \
    --reason 'pipeline_error at bank_parse — fix the parser' \
    --labels-file "$dir/labels.json")
  assert_equals "MHG20i: pipeline_error not nh" "$(jq -r .action <<<"$out")" "reject-not-human"

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

  rm -rf "$dir"
}

test_maintain_human_gate
