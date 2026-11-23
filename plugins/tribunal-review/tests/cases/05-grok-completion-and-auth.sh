#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

test_grok_deterministic_completion() {
  local work fake state host_grok
  work="$(mktemp -d)"
  fake="$work/bin"
  state="$work/state"
  host_grok="$work/host-grok"
  mkdir -p "$fake" "$state"
  install_grok_auth_fixture "$host_grok"

  # Scenario A: inspect progress-only → finalize resume yields structured review
  cat > "$fake/grok" <<EOF
#!/usr/bin/env bash
# Record phase + tools value for later assertions (NUL-separated fields).
phase=inspect
tools_val=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--tools" ]; then tools_val="\$a"; fi
  if [ "\$a" = "--resume" ]; then phase=finalize; fi
  prev="\$a"
done
printf '%s\t%s\n' "\$phase" "\$tools_val" >> "$state/phases.log"
printf '%s\n' "\$@" >> "$state/args.log"
if [ "\$phase" = finalize ]; then
  cat <<'JSON'
{"text":"done","stopReason":"EndTurn","sessionId":"11111111-1111-1111-1111-111111111111","structuredOutput":{"provider":"grok","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":9,"verdict":"APPROVE"}},"modelUsage":{"grok-fixture-model":{"inputTokens":1,"outputTokens":1}}}
JSON
  exit 0
fi
# Inspect phase: progress-only (no structured review)
cat <<'JSON'
{"text":"I'll review this PR as a read-only senior reviewer...","stopReason":"EndTurn","sessionId":"11111111-1111-1111-1111-111111111111","num_turns":1}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-a.json"
  ) && jq -e '
      .provider=="grok"
      and .summary.verdict=="APPROVE"
      and .model=="grok-fixture-model"
      and ((.findings|length)==0)
      and (has("error")|not)
    ' "$work/out-a.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok progress-only inspect resumes under read-only allowlist for verdict"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok progress-only inspect resumes under read-only allowlist for verdict"; FAIL=$((FAIL+1))
    FAILURES+=("grok progress-only inspect resumes under read-only allowlist for verdict")
    echo "    out: $(cat "$work/out-a.json" 2>/dev/null || true)" >&2
  fi

  # Resume must use --resume; inspect and finalize both pass the read-only allowlist (#721); pin session/max-turns
  # Default sandbox none + bypassPermissions (issue #378).
  if [ -f "$state/args.log" ] \
    && grep -q -- '--session-id' "$state/args.log" \
    && grep -q -- '--max-turns' "$state/args.log" \
    && grep -q -- '--resume' "$state/args.log" \
    && grep -q -- '--permission-mode' "$state/args.log" \
    && grep -q -- 'bypassPermissions' "$state/args.log" \
    && grep -q -- '--sandbox' "$state/args.log" \
    && grep -qE '(^|[[:space:]])none([[:space:]]|$)' "$state/args.log" \
    && grep -qx $'inspect\tread_file,list_dir,grep' "$state/phases.log" \
    && grep -qx $'finalize\tread_file,list_dir,grep' "$state/phases.log" \
    && ! grep -qx $'finalize\t' "$state/phases.log" \
    && ! grep -qx '' "$state/args.log"; then
    echo -e "  ${GREEN}PASS${NC} grok inspect/finalize use session, max-turns, read-only tools allowlist"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok inspect/finalize use session, max-turns, read-only tools allowlist"; FAIL=$((FAIL+1))
    FAILURES+=("grok inspect/finalize use session, max-turns, read-only tools allowlist")
    echo "    phases: $(cat "$state/phases.log" 2>/dev/null | tr '\n' '|')" >&2
    echo "    args: $(tr '\n' ' ' < "$state/args.log" 2>/dev/null | head -c 400)" >&2
  fi

  # Scenario B: both phases incomplete → progress_only / incomplete error with session_id
  rm -f "$state/args.log" "$state/phases.log"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q -- '--resume'; then
  cat <<'JSON'
{"text":"Still gathering context...","stopReason":"EndTurn","sessionId":"22222222-2222-2222-2222-222222222222"}
JSON
  exit 0
fi
cat <<'JSON'
{"text":"I'll start by reading the diff...","stopReason":"EndTurn","sessionId":"22222222-2222-2222-2222-222222222222"}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-b.json"
  ) && jq -e '
      .provider=="grok"
      and (.error | test("incomplete|progress_only"))
      and (.error | test("session_id="))
      and (.error | test("phase=incomplete"))
    ' "$work/out-b.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok double progress-only reports incomplete not success"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok double progress-only reports incomplete not success"; FAIL=$((FAIL+1))
    FAILURES+=("grok double progress-only reports incomplete not success")
    echo "    out: $(cat "$work/out-b.json" 2>/dev/null || true)" >&2
  fi

  # Scenario C: first-pass structuredOutput (camelCase) completes without resume
  rm -f "$state/args.log" "$state/calls"
  cat > "$fake/grok" <<EOF
#!/usr/bin/env bash
count_file="$state/calls"
n=0
[ -f "\$count_file" ] && n="\$(cat "\$count_file")"
n=\$((n+1))
printf '%s\\n' "\$n" > "\$count_file"
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","files_examined":["file.txt"],"findings":[{"severity":"medium","category":"logic","file":"file.txt","line":1,"title":"t","description":"d","suggestion":"s","confidence":0.9}],"summary":{"total_findings":1,"critical":0,"high":0,"medium":1,"low":0,"quality_score":7,"verdict":"NEEDS_WORK"}},"sessionId":"33333333-3333-3333-3333-333333333333","modelUsage":{"grok-fixture-model":{"inputTokens":1}}}
JSON
exit 0
EOF
  chmod +x "$fake/grok"
  : > "$state/calls"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-c.json"
  ) && jq -e '
      .provider=="grok"
      and .summary.verdict=="NEEDS_WORK"
      and (.findings|length)==1
      and .model=="grok-fixture-model"
    ' "$work/out-c.json" >/dev/null \
    && [ "$(cat "$state/calls")" = "1" ]; then
    echo -e "  ${GREEN}PASS${NC} grok camelCase structuredOutput completes in one pass"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok camelCase structuredOutput completes in one pass"; FAIL=$((FAIL+1))
    FAILURES+=("grok camelCase structuredOutput completes in one pass")
    echo "    out: $(cat "$work/out-c.json" 2>/dev/null || true) calls=$(cat "$state/calls" 2>/dev/null)" >&2
  fi

  # Scenario D: inspect times out (124) → finalize recovers verdict
  rm -f "$state/args.log" "$state/calls" "$state/phases.log"
  cat > "$fake/grok" <<EOF
#!/usr/bin/env bash
phase=inspect
tools_val=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--tools" ]; then tools_val="\$a"; fi
  if [ "\$a" = "--resume" ]; then phase=finalize; fi
  prev="\$a"
done
printf '%s\t%s\n' "\$phase" "\$tools_val" >> "$state/phases.log"
printf '%s\n' "\$@" >> "$state/args.log"
if [ "\$phase" = finalize ]; then
  cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":8,"verdict":"APPROVE"}},"sessionId":"44444444-4444-4444-4444-444444444444","modelUsage":{"grok-fixture-model":{}}}
JSON
  exit 0
fi
# Partial envelope before timeout so session_id is known
cat <<'JSON'
{"text":"still reading files...","sessionId":"44444444-4444-4444-4444-444444444444"}
JSON
exit 124
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-d.json"
  ) && jq -e '
      .provider=="grok"
      and .summary.verdict=="APPROVE"
      and (has("error")|not)
    ' "$work/out-d.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok inspect timeout recovers via finalize resume"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok inspect timeout recovers via finalize resume"; FAIL=$((FAIL+1))
    FAILURES+=("grok inspect timeout recovers via finalize resume")
    echo "    out: $(cat "$work/out-d.json" 2>/dev/null || true)" >&2
  fi

  if [ -f "$state/phases.log" ] \
    && grep -qx $'inspect\tread_file,list_dir,grep' "$state/phases.log" \
    && grep -qx $'finalize\tread_file,list_dir,grep' "$state/phases.log" \
    && ! grep -qx $'finalize\t' "$state/phases.log" \
    && ! grep -qx '' "$state/args.log"; then
    echo -e "  ${GREEN}PASS${NC} grok timeout finalize argv carries inspect allowlist and no empty --tools"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok timeout finalize argv carries inspect allowlist and no empty --tools"; FAIL=$((FAIL+1))
    FAILURES+=("grok timeout finalize argv carries inspect allowlist and no empty --tools")
    echo "    phases: $(cat "$state/phases.log" 2>/dev/null | tr '\n' '|')" >&2
  fi

  # Lib helper: camelCase + snake_case extract, payload complete check
  complete_ok='{"provider":"grok","model":"m","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
  if printf '%s' "{\"structuredOutput\":$complete_ok}" \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_extract_grok_result" \
      | jq -e '.summary.verdict=="APPROVE"' >/dev/null \
    && printf '%s' '{"structured_output":{"findings":[],"summary":{"verdict":"BLOCK"}}}' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_extract_grok_result" \
      | jq -e '.summary.verdict=="BLOCK"' >/dev/null \
    && printf '%s' "$complete_ok" \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete" \
    && ! printf '%s' 'I will review this next.' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete" \
    && ! printf '%s' '{"findings":[],"summary":{"verdict":"pending"}}' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete" \
    && ! printf '%s' '{"findings":[],"summary":{"verdict":"APPROVE"}}' \
      | bash -c ". '$PLUGIN_ROOT/scripts/lib.sh'; tribunal_review_payload_complete"; then
    echo -e "  ${GREEN}PASS${NC} grok envelope helpers accept camel/snake and reject weak payloads"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok envelope helpers accept camel/snake and reject weak payloads"; FAIL=$((FAIL+1))
    FAILURES+=("grok envelope helpers accept camel/snake and reject weak payloads")
  fi

  # Scenario E (issue #378): TRIBUNAL_GROK_SANDBOX override reaches the CLI.
  rm -f "$state/args.log" "$state/phases.log"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${ARGS_LOG:?}"
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":9,"verdict":"APPROVE"}},"sessionId":"77777777-7777-7777-7777-777777777777","modelUsage":{"grok-fixture-model":{}}}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" ARGS_LOG="$state/args.log" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_GROK_SANDBOX=read-only \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-e.json"
  ) && jq -e '.provider=="grok" and .summary.verdict=="APPROVE"' "$work/out-e.json" >/dev/null \
    && grep -q -- '--sandbox' "$state/args.log" \
    && grep -qE '(^|[[:space:]])read-only([[:space:]]|$)' "$state/args.log"; then
    echo -e "  ${GREEN}PASS${NC} grok TRIBUNAL_GROK_SANDBOX override reaches CLI"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok TRIBUNAL_GROK_SANDBOX override reaches CLI"; FAIL=$((FAIL+1))
    FAILURES+=("grok TRIBUNAL_GROK_SANDBOX override reaches CLI")
    echo "    out: $(cat "$work/out-e.json" 2>/dev/null || true)" >&2
    echo "    args: $(tr '\n' ' ' < "$state/args.log" 2>/dev/null)" >&2
  fi

  # Scenario F (issue #378): Cancelled stopReason + no verdict is dead_leg, not quiet success.
  rm -f "$state/args.log"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q -- '--resume'; then
  cat <<'JSON'
{"text":"","stopReason":"Cancelled","sessionId":"88888888-8888-8888-8888-888888888888"}
JSON
  exit 0
fi
cat <<'JSON'
{"text":"","stopReason":"Cancelled","sessionId":"88888888-8888-8888-8888-888888888888"}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-f.json"
  ) && jq -e '
      .provider=="grok"
      and (.error | test("stopReason=Cancelled"))
      and (.error | test("dead_leg|progress_only"))
      and (has("summary")|not)
    ' "$work/out-f.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok Cancelled stopReason reports dead leg not success"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok Cancelled stopReason reports dead leg not success"; FAIL=$((FAIL+1))
    FAILURES+=("grok Cancelled stopReason reports dead leg not success")
    echo "    out: $(cat "$work/out-f.json" 2>/dev/null || true)" >&2
  fi

  # Scenario G (issue #378): orphaned script copy (no sibling schemas/) still
  # resolves schema when CLAUDE_PLUGIN_ROOT points at the real plugin.
  local orphan="$work/orphan-plugin/scripts"
  mkdir -p "$orphan"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$PLUGIN_ROOT/scripts/"lib-*.sh "$orphan/"
  cp "$PLUGIN_ROOT/scripts/run-grok-review.sh" "$orphan/run-grok-review.sh"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":8,"verdict":"APPROVE"}},"sessionId":"99999999-9999-9999-9999-999999999999","modelUsage":{"grok-fixture-model":{}}}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY -u TRIBUNAL_PLUGIN_ROOT \
      -u CODEX_PLUGIN_ROOT -u PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u MUSE_PLUGIN_ROOT \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$orphan/run-grok-review.sh" > "$work/out-g.json"
  ) && jq -e '.provider=="grok" and .summary.verdict=="APPROVE" and (has("error")|not)' \
      "$work/out-g.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok schema resolves via CLAUDE_PLUGIN_ROOT"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok schema resolves via CLAUDE_PLUGIN_ROOT"; FAIL=$((FAIL+1))
    FAILURES+=("grok schema resolves via CLAUDE_PLUGIN_ROOT")
    echo "    out: $(cat "$work/out-g.json" 2>/dev/null || true)" >&2
  fi

  # Scenario G2: schema resolves via CODEX_PLUGIN_ROOT, PLUGIN_ROOT (agy), GROK_PLUGIN_ROOT, and MUSE_PLUGIN_ROOT.
  for env_var in CODEX_PLUGIN_ROOT PLUGIN_ROOT GROK_PLUGIN_ROOT MUSE_PLUGIN_ROOT; do
    if (
      set -e
      cd "$work"
      PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY -u TRIBUNAL_PLUGIN_ROOT \
        -u CLAUDE_PLUGIN_ROOT -u CODEX_PLUGIN_ROOT -u PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u MUSE_PLUGIN_ROOT \
        "${env_var}=$PLUGIN_ROOT" \
        TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
        bash "$orphan/run-grok-review.sh" > "$work/out-g2-${env_var}.json"
    ) && jq -e '.provider=="grok" and .summary.verdict=="APPROVE" and (has("error")|not)' \
        "$work/out-g2-${env_var}.json" >/dev/null; then
      echo -e "  ${GREEN}PASS${NC} grok schema resolves via ${env_var}"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} grok schema resolves via ${env_var}"; FAIL=$((FAIL+1))
      FAILURES+=("grok schema resolves via ${env_var}")
      echo "    out: $(cat "$work/out-g2-${env_var}.json" 2>/dev/null || true)" >&2
    fi
  done

  # Scenario H: missing schema file fails before provider run (no silent empty schema).
  local bare="$work/bare-plugin"
  mkdir -p "$bare/scripts" "$bare/schemas"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$PLUGIN_ROOT/scripts/"lib-*.sh "$bare/scripts/"
  cp "$PLUGIN_ROOT/scripts/run-grok-review.sh" "$bare/scripts/run-grok-review.sh"
  # Intentionally omit schemas/review-output.json
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
: > "${GROK_RAN:?}"
exit 99
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" GROK_RAN="$work/provider-ran-h" env -u XAI_API_KEY \
      -u CLAUDE_PLUGIN_ROOT -u TRIBUNAL_PLUGIN_ROOT -u CODEX_PLUGIN_ROOT -u PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u MUSE_PLUGIN_ROOT \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$bare/scripts/run-grok-review.sh" > "$work/out-h.json"
  ) && jq -e '.provider=="grok" and (.error|test("schema missing|cannot load review schema"))' \
      "$work/out-h.json" >/dev/null \
    && [ ! -e "$work/provider-ran-h" ]; then
    echo -e "  ${GREEN}PASS${NC} grok missing schema fails before provider run"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok missing schema fails before provider run"; FAIL=$((FAIL+1))
    FAILURES+=("grok missing schema fails before provider run")
    echo "    out: $(cat "$work/out-h.json" 2>/dev/null || true)" >&2
  fi

  # Scenario I: explicit TRIBUNAL_PLUGIN_ROOT without schema is authoritative —
  # must not fall back to the real install's schema (Codex review / #378).
  local empty_root="$work/empty-root"
  mkdir -p "$empty_root"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
: > "${GROK_RAN:?}"
exit 99
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" GROK_RAN="$work/provider-ran-i" env -u XAI_API_KEY \
      env -u CLAUDE_PLUGIN_ROOT \
      TRIBUNAL_PLUGIN_ROOT="$empty_root" \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-i.json"
  ) && jq -e '.provider=="grok" and (.error|test("schema missing|cannot load review schema"))' \
      "$work/out-i.json" >/dev/null \
    && [ ! -e "$work/provider-ran-i" ]; then
    echo -e "  ${GREEN}PASS${NC} grok explicit empty plugin root does not fall back"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok explicit empty plugin root does not fall back"; FAIL=$((FAIL+1))
    FAILURES+=("grok explicit empty plugin root does not fall back")
    echo "    out: $(cat "$work/out-i.json" 2>/dev/null || true)" >&2
  fi

  # Scenario J: invalid sandbox / permission overrides fail loud (no silent remap).
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
: > "${GROK_RAN:?}"
exit 99
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" GROK_RAN="$work/provider-ran-j1" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_GROK_SANDBOX=read_only \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-j1.json"
  ) && jq -e '.provider=="grok" and (.error|test("invalid Grok sandbox profile"))' \
      "$work/out-j1.json" >/dev/null \
    && [ ! -e "$work/provider-ran-j1" ]; then
    echo -e "  ${GREEN}PASS${NC} grok invalid sandbox fails loud"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok invalid sandbox fails loud"; FAIL=$((FAIL+1))
    FAILURES+=("grok invalid sandbox fails loud")
    echo "    out: $(cat "$work/out-j1.json" 2>/dev/null || true)" >&2
  fi

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" GROK_RAN="$work/provider-ran-j2" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_GROK_PERMISSION_MODE=yolo \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-j2.json"
  ) && jq -e '.provider=="grok" and (.error|test("invalid Grok permission mode"))' \
      "$work/out-j2.json" >/dev/null \
    && [ ! -e "$work/provider-ran-j2" ]; then
    echo -e "  ${GREEN}PASS${NC} grok invalid permission mode fails loud"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok invalid permission mode fails loud"; FAIL=$((FAIL+1))
    FAILURES+=("grok invalid permission mode fails loud")
    echo "    out: $(cat "$work/out-j2.json" 2>/dev/null || true)" >&2
  fi

  # Scenario K (issue #721): run_grok with an empty tools value refuses to invoke
  # grok and yields a failed Grok leg.
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
: > "${GROK_RAN:?}"
exit 0
EOF
  chmod +x "$fake/grok"

  rm -f "$work/provider-ran-k" "$work/out-k1.json" "$work/out-k2.json"
  if (
    set -e
    cd "$work"
    . "$PLUGIN_ROOT/scripts/lib.sh"
    eval "$(sed -n '/^run_grok() {/,/^}/p' "$PLUGIN_ROOT/scripts/run-grok-review.sh")"
    ISOLATED_HOME="$work/k-home"
    GROK_SANDBOX_PROFILE=none
    GROK_PERMISSION_MODE=bypassPermissions
    GROK_MODEL=grok-4.7
    GROK_EFFORT=low
    SCHEMA_JSON='{"type":"object"}'
    SESSION_ID="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    WALK_ROOT="$work"
    mkdir -p "$ISOLATED_HOME/.grok"
    : > "$work/prompt-k.md"
    (
      PATH="$fake:$PATH" GROK_RAN="$work/provider-ran-k" \
        run_grok inspect "" 6 30 "$work/k1.out" "$work/k1.err" "$work/prompt-k.md"
    ) > "$work/out-k1.json"
    (
      PATH="$fake:$PATH" GROK_RAN="$work/provider-ran-k" \
        run_grok finalize "" 6 30 "$work/k2.out" "$work/k2.err" "$work/prompt-k.md"
    ) > "$work/out-k2.json"
  ) && [ ! -e "$work/provider-ran-k" ] \
    && jq -e '
      .provider=="grok"
      and (.error | test("empty --tools|allowlist"))
      and (has("summary")|not)
    ' "$work/out-k1.json" >/dev/null \
    && jq -e '
      .provider=="grok"
      and (.error | test("empty --tools|allowlist"))
      and (has("summary")|not)
    ' "$work/out-k2.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok run_grok refuses empty tools without invoking CLI"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok run_grok refuses empty tools without invoking CLI"; FAIL=$((FAIL+1))
    FAILURES+=("grok run_grok refuses empty tools without invoking CLI")
    echo "    out: $(cat "$work/out-k1.json" "$work/out-k2.json" 2>/dev/null || true)" >&2
  fi

  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}

# Issue #374: copy auth into isolation (not symlink); write back rotated tokens under flock.
test_grok_auth_copy_writeback() {
  local label="grok copies auth and write-backs rotated OIDC tokens" work fake host_grok
  work="$(mktemp -d)"
  fake="$work/bin"
  host_grok="$work/host-grok"
  mkdir -p "$fake"
  install_grok_auth_fixture "$host_grok" "refresh-old" "2026-01-01T00:00:00Z"

  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
auth="${GROK_HOME:?}/auth.json"
# Isolation must present a regular file, not a host symlink (atomic replace severs host).
if [ -L "$auth" ]; then
  printf '%s\n' "auth is symlink" >&2
  exit 97
fi
if [ ! -f "$auth" ]; then
  printf '%s\n' "auth missing under isolation" >&2
  exit 98
fi
# Simulate OIDC refresh_token rotation under the scratch home.
jq '
  walk(
    if type == "object" and has("refresh_token") then
      .refresh_token = "refresh-rotated"
      | .key = "access-rotated"
      | .expires_at = "2099-06-01T00:00:00Z"
    else . end
  )
' "$auth" > "$auth.tmp" && mv "$auth.tmp" "$auth"
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":9,"verdict":"APPROVE"}},"sessionId":"55555555-5555-5555-5555-555555555555","modelUsage":{"grok-fixture-model":{}}}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    PATH="$fake:$PATH" GROK_HOME="$host_grok" env -u XAI_API_KEY \
      TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out.json"
  ) && jq -e '.provider=="grok" and .summary.verdict=="APPROVE" and (has("error")|not)' "$work/out.json" >/dev/null \
    && jq -e '
        .["https://auth.x.ai::fixture"].refresh_token == "refresh-rotated"
        and .["https://auth.x.ai::fixture"].key == "access-rotated"
      ' "$host_grok/auth.json" >/dev/null \
    && [ ! -L "$host_grok/auth.json" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    echo "    out: $(cat "$work/out.json" 2>/dev/null || true)" >&2
    echo "    host auth: $(cat "$host_grok/auth.json" 2>/dev/null || true)" >&2
  fi

  # Stale isolated write-back must not clobber a host session with newer expires_at.
  install_grok_auth_fixture "$host_grok" "refresh-host-fresh" "2099-12-01T00:00:00Z"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
auth="${GROK_HOME:?}/auth.json"
jq '
  walk(
    if type == "object" and has("refresh_token") then
      .refresh_token = "refresh-stale"
      | .key = "access-stale"
      | .expires_at = "2020-01-01T00:00:00Z"
    else . end
  )
' "$auth" > "$auth.tmp" && mv "$auth.tmp" "$auth"
# Concurrent host refresh lands a fresher session while this leg still holds stale tokens.
printf '%s\n' '{"https://auth.x.ai::fixture":{"key":"access-host-fresh","refresh_token":"refresh-host-fresh","expires_at":"2099-12-01T00:00:00Z","auth_mode":"oidc"}}' \
  > "${AUTH_HOST_PATH:?}"
cat <<'JSON'
{"structuredOutput":{"provider":"grok","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":8,"verdict":"APPROVE"}},"sessionId":"66666666-6666-6666-6666-666666666666","modelUsage":{"grok-fixture-model":{}}}
JSON
exit 0
EOF
  chmod +x "$fake/grok"

  if (
    set -e
    cd "$work"
    PATH="$fake:$PATH" GROK_HOME="$host_grok" AUTH_HOST_PATH="$host_grok/auth.json" \
      env -u XAI_API_KEY TRIBUNAL_GROK=on TRIBUNAL_BASE_REF=HEAD~1 \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/out-stale.json"
  ) && jq -e '.["https://auth.x.ai::fixture"].refresh_token == "refresh-host-fresh"' \
      "$host_grok/auth.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} grok write-back refuses to clobber fresher host auth"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} grok write-back refuses to clobber fresher host auth"; FAIL=$((FAIL+1))
    FAILURES+=("grok write-back refuses to clobber fresher host auth")
    echo "    host auth: $(cat "$host_grok/auth.json" 2>/dev/null || true)" >&2
  fi

  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}

test_grok_auth_guard() {
  local label="unsigned Grok session is skipped before provider execution" work fake host_grok
  work="$(mktemp -d)"
  fake="$work/bin"
  host_grok="$work/host-grok"
  mkdir -p "$fake" "$host_grok"
  cat > "$fake/grok" <<'EOF'
#!/usr/bin/env bash
: > "${GROK_RUN_MARKER:?}"
exit 99
EOF
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  printf '%s\n' '{"loggedIn":true,"authMethod":"fixture"}'
  exit 0
fi
exit 0
EOF
  chmod +x "$fake/grok" "$fake/codex" "$fake/claude"
  # Empty/missing auth.json — not signed in.
  : > "$host_grok/auth.json"

  if (
    set -e
    cd "$work"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > file.txt
    git add file.txt
    git commit -q -m base
    printf 'two\n' > file.txt
    git commit -q -am change
    export PATH="$fake:$PATH" GROK_HOME="$host_grok" GROK_RUN_MARKER="$work/provider-ran"
    env -u XAI_API_KEY \
      TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_CODEX=on TRIBUNAL_CLAUDE=on \
      TRIBUNAL_GROK=on TRIBUNAL_GEMINI=off TRIBUNAL_QWEN=off TRIBUNAL_DEEPSEEK=off \
      bash "$PLUGIN_ROOT/scripts/preflight.sh" > "$work/preflight.json"
    env -u XAI_API_KEY GROK_HOME="$host_grok" PATH="$fake:$PATH" \
      TRIBUNAL_BASE_REF=HEAD~1 TRIBUNAL_GROK=on \
      bash "$PLUGIN_ROOT/scripts/run-grok-review.sh" > "$work/review.json"
  ) && jq -e 'any(.providers[]; .name=="grok" and .status=="skipped" and (.note|test("not signed in")))' \
      "$work/preflight.json" >/dev/null \
    && jq -e '.provider=="grok" and (.error|test("not signed in"))' "$work/review.json" >/dev/null \
    && [ ! -e "$work/provider-ran" ]; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    echo "    preflight: $(cat "$work/preflight.json" 2>/dev/null || true)" >&2
    echo "    review: $(cat "$work/review.json" 2>/dev/null || true)" >&2
  fi
  rm -rf "$work"
}


test_grok_auth_guard
test_grok_deterministic_completion
test_grok_auth_copy_writeback
