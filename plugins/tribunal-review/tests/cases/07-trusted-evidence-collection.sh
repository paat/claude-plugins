#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

test_trusted_evidence_collection() {
  local label="trusted evidence collection binds PR, providers, arbitration, and proof"
  local work repo fake plugin collection manifest_sha proof_sha base head host_codex real_git
  work="$(mktemp -d)"; repo="$work/repo"; fake="$work/bin"; plugin="$work/plugin"
  mkdir -p "$repo" "$fake" "$work/tmp" "$plugin/scripts" "$plugin/schemas" "$plugin/.claude-plugin" "$plugin/integrity"
  cp "$PLUGIN_ROOT/scripts/collect-review-evidence.sh" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/lib.sh" "$PLUGIN_ROOT/scripts/review-panel.tsv" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/check-runner-bundle.sh" "$PLUGIN_ROOT/scripts/generate-runner-bundle.sh" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/scripts/dsh-review.patch.yml" "$plugin/scripts/"
  cp "$PLUGIN_ROOT/schemas/review-output.json" "$plugin/schemas/"
  cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$plugin/.claude-plugin/plugin.json"

  cat > "$plugin/scripts/run-codex-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_TAMPER_SENSITIVE:-off}" = on ]; then
  read -r host_pid rest < /proc/self/stat
  staging="$(dirname "$(dirname "$(readlink /proc/$host_pid/fd/1)")")"
  printf '[]\n' > "$staging/sensitive-paths.json"
fi
if [ "${FIXTURE_REPLACE_IGNORE:-off}" = on ]; then
  read -r host_pid rest < /proc/self/stat
  staging="$(dirname "$(dirname "$(readlink /proc/$host_pid/fd/1)")")"
  cp "$staging/sensitive-paths.json" "$FIXTURE_SENSITIVE_CAPTURE" 2>/dev/null || true
  blob="$(git rev-parse HEAD:.gitignore)"
  replacement="$(printf '# ordinary artifacts\nscratch/\n' | git hash-object -w --stdin)"
  git replace "$blob" "$replacement"
fi
fixture_stat() {
  local base head
  base="$(git rev-parse --verify "${FIXTURE_STAT_BASE:-${TRIBUNAL_BASE_REF}}^{commit}")"
  head="$(git rev-parse --verify "${FIXTURE_STAT_HEAD:-HEAD}^{commit}")"
  printf '"diff_stat":{"files_changed":1,"insertions":1,"deletions":0,"base":"%s","base_oid":"%s","head_oid":"%s","truncated":false}' \
    "$TRIBUNAL_BASE_REF" "$base" "$head"
}
if [ "${FIXTURE_ZERO_SUCCESS:-off}" = on ]; then
  printf '%s\n' '{"provider":"codex","error":"fixture Codex transport failure"}'
elif [ "${FIXTURE_CODEX_MODE:-ok}" = malformed ]; then
  printf '%s\n' '{"provider":"claude","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"},"caller_owned":true}'
elif [ "${FIXTURE_CODEX_MODE:-ok}" = diagnostic ]; then
  printf '%s\n' '{"provider":"claude","error":"unparseable codex output: no review JSON object found; phase=parse; exit=0; stdout_bytes=12; stdout_truncated=false; stdout_tail=omitted; stderr_bytes=0; stderr_truncated=false; stderr_tail=omitted"}'
elif [ "${FIXTURE_CODEX_MODE:-ok}" = finding ]; then
  printf '%s\n' '{"provider":"claude","model":"fixture","files_examined":["app.txt"],"findings":[{"severity":"medium","category":"logic","file":"app.txt","line":1,"title":"Fixture finding","description":"A concrete fixture defect.","suggestion":"Apply the fixture fix.","confidence":0.9}],"summary":{"total_findings":1,"critical":0,"high":0,"medium":1,"low":0,"quality_score":7,"verdict":"NEEDS_WORK"},'"$(fixture_stat)"'}'
elif [ "${FIXTURE_CODEX_MODE:-ok}" = nostat ]; then
  printf '%s\n' '{"provider":"claude","model":"fixture","files_examined":["file.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
else
  printf '%s\n' '{"provider":"claude","model":"fixture","files_examined":["app.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"},'"$(fixture_stat)"'}'
fi
EOF
  for provider in gemini qwen grok muse; do
    cat > "$plugin/scripts/run-$provider-review.sh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '{"provider":"$provider","status":"disabled","note":"fixture disabled"}'
EOF
  done
  cat > "$plugin/scripts/run-claude-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_ZERO_SUCCESS:-off}" = on ]; then
  printf '%s\n' '{"provider":"claude","error":"fixture Claude transport failure"}'
elif [ "${TRIBUNAL_CLAUDE:-on}" = off ]; then
  printf '%s\n' '{"provider":"claude","status":"disabled","note":"fixture disabled"}'
else
  base="$(git rev-parse --verify "${TRIBUNAL_BASE_REF}^{commit}")"
  head="$(git rev-parse --verify 'HEAD^{commit}')"
  printf '%s\n' "{\"provider\":\"claude\",\"model\":\"fixture\",\"files_examined\":[\"app.txt\"],\"findings\":[],\"summary\":{\"total_findings\":0,\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"quality_score\":10,\"verdict\":\"APPROVE\"},\"diff_stat\":{\"files_changed\":1,\"insertions\":1,\"deletions\":0,\"base\":\"$TRIBUNAL_BASE_REF\",\"base_oid\":\"$base\",\"head_oid\":\"$head\",\"truncated\":false}}"
fi
EOF
  cat > "$plugin/scripts/run-qwen-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_MUTATE_WORKTREE:-off}" = on ]; then printf 'provider mutation\n' >> app.txt; fi
printf '%s\n' '{"provider":"qwen","status":"disabled","note":"fixture disabled"}'
EOF
  cat > "$plugin/scripts/run-grok-review.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${FIXTURE_ZERO_SUCCESS:-off}" = on ]; then
  printf '%s\n' '{"provider":"grok","error":"fixture Grok transport failure"}'
else
  printf '%s\n' '{"provider":"grok","status":"disabled","note":"fixture disabled"}'
fi
EOF
  cat > "$plugin/scripts/run-deepseek-review.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"provider":"deepseek","status":"disabled","note":"fixture disabled"}'
EOF
  chmod +x "$plugin/scripts/"*.sh
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/codex"
  cat > "$fake/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
printf '%s\n' '{"loggedIn":true}'
EOF
  chmod +x "$fake/codex" "$fake/claude"
  "$plugin/scripts/generate-runner-bundle.sh" >/dev/null

  (
    cd "$repo"
    git init -q
    git config user.email test@example.com
    git config user.name "Test User"
    printf 'one\n' > app.txt
    git add app.txt
    git commit -q -m base
    printf 'two\n' > app.txt
    git commit -q -am change
    git remote add origin https://github.com/example/fixture.git
  )
  base="$(git -C "$repo" rev-parse HEAD~1)"; head="$(git -C "$repo" rev-parse HEAD)"
  printf 'Bound PR body' > "$work/pr-body"
  cat > "$fake/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = repo ] && [ "$2" = view ]; then
  jq -nc '{nameWithOwner:"example/fixture",url:"https://github.com/example/fixture"}'
elif [ "$1" = pr ] && [ "$2" = view ]; then
  jq -nc --argjson number "$3" --arg base "$FIXTURE_BASE" --arg head "$FIXTURE_HEAD" \
    --rawfile body "$FIXTURE_BODY_FILE" \
    '{number:$number,url:("https://github.com/example/fixture/pull/"+($number|tostring)),state:"OPEN",
      baseRefName:"main",baseRefOid:$base,headRefName:"feature",headRefOid:$head,body:$body}'
else
  printf 'unexpected gh invocation: %s\n' "$*" >&2
  exit 2
fi
EOF
  chmod +x "$fake/gh"

  cat > "$fake/mv" <<'EOF'
#!/usr/bin/env bash
target=${!#}
if [ -n "${FIXTURE_KILL_PUBLISH:-}" ] && [ "$target" = "$FIXTURE_KILL_PUBLISH" ]; then
  kill -KILL "$PPID"
  exit 137
fi
/usr/bin/mv "$@"
if [ -n "${FIXTURE_KILL_FINALIZE:-}" ] && [ "$target" = "$FIXTURE_KILL_FINALIZE" ]; then
  kill -KILL "$PPID"
fi
EOF
  chmod +x "$fake/mv"

  real_git="$(command -v git)"
  mkdir -p "$work/diff-fail-bin"
  cat > "$work/diff-fail-bin/git" <<'EOF'
#!/usr/bin/env bash
saw_diff=0
for arg in "$@"; do
  [ "$arg" != diff ] || saw_diff=1
  [ "$saw_diff" -eq 0 ] || [ "$arg" != --name-only ] || exit 128
done
exec "$TRIBUNAL_TEST_REAL_GIT" "$@"
EOF
  chmod +x "$work/diff-fail-bin/git"
  local diff_failed_collection="$work/diff-failed-collection" diff_failure_rc=0
  PATH="$work/diff-fail-bin:$fake:$PATH" TRIBUNAL_TEST_REAL_GIT="$real_git" \
    FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$diff_failed_collection" >/dev/null 2>&1 || diff_failure_rc=$?
  if [ "$diff_failure_rc" -ne 0 ] && [ ! -e "$diff_failed_collection" ]; then
    echo -e "  ${GREEN}PASS${NC} collection fails closed when ignored-addition diff fails"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} collection fails closed when ignored-addition diff fails"; FAIL=$((FAIL+1)); FAILURES+=("collection ignored-addition diff failure")
  fi

  if FIXTURE_MUTATE_WORKTREE=on PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/mutated" \
      >/dev/null 2>"$work/mutated.err" \
    && jq -e '.status == "disabled" and (has("error") | not)' "$work/mutated/providers/qwen.json" >/dev/null \
    && ! grep -q 'tribunal evidence: qwen: provider mutated' "$work/mutated.err"; then
    echo -e "  ${GREEN}PASS${NC} disabled provider stays disabled despite an unused worktree mutation"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} disabled provider stays disabled despite an unused worktree mutation"; FAIL=$((FAIL+1)); FAILURES+=("disabled provider worktree mutation")
    rm -rf "$work"; return
  fi

  local killed_collection="$work/killed-collection" interrupted_ec=0
  TMPDIR="$work/tmp" FIXTURE_KILL_PUBLISH="$killed_collection" \
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$killed_collection" >/dev/null 2>&1 || interrupted_ec=$?
  if [ "$interrupted_ec" -ne 0 ] && [ ! -e "$killed_collection" ]; then
    echo -e "  ${GREEN}PASS${NC} killed publication leaves no partial collection"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} killed publication leaves no partial collection"; FAIL=$((FAIL+1)); FAILURES+=("atomic collection publication")
    rm -rf "$work"; return
  fi

  collection="$work/collection"
  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$collection" > "$work/collect.json"; then
    echo -e "  ${RED}FAIL${NC} $label (collection failed)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  manifest_sha="$(jq -r .manifest_sha256 "$work/collect.json")"

  if [ ! -e "$collection/ignored-paths.json" ] \
    && [ ! -e "$collection/deleted-paths.json" ] \
    && jq -e '(has("ignored_paths") | not) and (has("deleted_paths") | not)' "$collection/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} clean collection has no ignored-path or deleted-path artifact noise"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} clean collection has no ignored-path or deleted-path artifact noise"; FAIL=$((FAIL+1)); FAILURES+=("clean collection artifact noise")
  fi

  # The codex fixture claims to be Claude; the aggregate runner owns and
  # rewrites identity before sealing the artifact.
  if ! jq -e '.provider=="codex" and (has("caller_owned")|not)' "$collection/providers/codex.json" >/dev/null; then
    echo -e "  ${RED}FAIL${NC} $label (provider identity/schema not owned by runner)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi

  chmod u+w "$collection/providers/codex.json"
  cp "$collection/providers/codex.json" "$work/codex.saved"
  printf '\n' >> "$collection/providers/codex.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (artifact tamper accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  cp "$work/codex.saved" "$collection/providers/codex.json"; chmod 0444 "$collection/providers/codex.json"

  cp "$plugin/scripts/lib.sh" "$work/lib.saved"
  printf '\n# drift\n' >> "$plugin/scripts/lib.sh"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (runner provenance drift accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  cp "$work/lib.saved" "$plugin/scripts/lib.sh"

  printf 'Changed PR body' > "$work/pr-body"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (PR body drift accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  printf 'Bound PR body' > "$work/pr-body"

  cat > "$work/arbitration.json" <<'EOF'
{
  "tribunal_verdict":{"decision":"APPROVE","confidence":0.95,"rationale":"Two valid reviewers found no defects."},
  "findings":[],"scope_findings":[],
  "provider_assessment":{
    "codex":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"},
    "gemini":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "deepseek":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "qwen":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "grok":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "muse":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "claude":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"}
  },
  "conflicts_resolved":[],"summary":"No blocking findings."
}
EOF
  jq '.provider_assessment.codex.status="failed"' "$work/arbitration.json" > "$work/bad-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/bad-arbitration.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} $label (caller-authored provider status accepted)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi

  interrupted_ec=0
  TMPDIR="$work/tmp" FIXTURE_KILL_FINALIZE="$collection/arbitration.json" \
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" \
      >/dev/null 2>&1 || interrupted_ec=$?
  if [ "$interrupted_ec" -ne 0 ] && [ -f "$collection/arbitration.json" ] \
    && [ ! -e "$collection/proof.json" ] && [ -f "$collection/.finalize.lock" ]; then
    echo -e "  ${GREEN}PASS${NC} killed finalization releases its process lock"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} killed finalization releases its process lock"; FAIL=$((FAIL+1)); FAILURES+=("crash-releasing finalization lock")
    rm -rf "$work"; return
  fi

  if ! PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" > "$work/finalize.json"; then
    echo -e "  ${RED}FAIL${NC} $label (finalization failed)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
    rm -rf "$work"; return
  fi
  proof_sha="$(jq -r .proof_sha256 "$work/finalize.json")"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-proof --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --expected-proof-sha256 "$proof_sha" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} $label"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $label (proof verification failed)"; FAIL=$((FAIL+1)); FAILURES+=("$label")
  fi
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/arbitration.json" > "$work/finalize-repeat.json" \
    && cmp -s "$work/finalize.json" "$work/finalize-repeat.json"; then
    echo -e "  ${GREEN}PASS${NC} identical finalize retry returns the retained proof"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} identical finalize retry returns the retained proof"; FAIL=$((FAIL+1)); FAILURES+=("idempotent finalize retry")
  fi
  jq '.tribunal_verdict.rationale="Conflicting repeat."' "$work/arbitration.json" > "$work/conflicting-repeat.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$collection" \
      --expected-manifest-sha256 "$manifest_sha" --arbitration "$work/conflicting-repeat.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} conflicting finalize retry is rejected"; FAIL=$((FAIL+1)); FAILURES+=("conflicting finalize retry")
  else
    echo -e "  ${GREEN}PASS${NC} conflicting finalize retry is rejected"; PASS=$((PASS+1))
  fi

  FIXTURE_CODEX_MODE=malformed PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/malformed" > "$work/malformed.json"
  if jq -e '.provider=="codex" and has("error")' "$work/malformed/providers/codex.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} strict provider schema rejects caller/model extras"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} strict provider schema rejects caller/model extras"; FAIL=$((FAIL+1)); FAILURES+=("strict provider schema")
  fi
  FIXTURE_CODEX_MODE=nostat PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/nostat" > "$work/nostat.json"
  if jq -e '.provider=="codex" and has("error")' "$work/nostat/providers/codex.json" >/dev/null \
    && jq -e 'any(.providers[]; .provider=="codex" and .status=="failed")' "$work/nostat/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} review leg without wrapper diff_stat is a provider failure"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} review leg without wrapper diff_stat is a provider failure"; FAIL=$((FAIL+1)); FAILURES+=("missing diff_stat rejection")
  fi
  FIXTURE_STAT_HEAD="$base" PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/wrongrev" > "$work/wrongrev.json"
  if jq -e '.provider=="codex" and has("error")' "$work/wrongrev/providers/codex.json" >/dev/null \
    && jq -e 'any(.providers[]; .provider=="codex" and .status=="failed")' "$work/wrongrev/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} review leg stamped over another revision is a provider failure"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} review leg stamped over another revision is a provider failure"; FAIL=$((FAIL+1)); FAILURES+=("wrong-revision diff_stat rejection")
  fi
  jq '.provider_assessment.codex.status="failed"' "$work/arbitration.json" > "$work/no-quorum-approve.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/malformed" \
      --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/malformed.json")" \
      --arbitration "$work/no-quorum-approve.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} no successful provider cannot approve"; FAIL=$((FAIL+1)); FAILURES+=("no-quorum approval")
  else
    echo -e "  ${GREEN}PASS${NC} no successful provider cannot approve"; PASS=$((PASS+1))
  fi

  FIXTURE_ZERO_SUCCESS=on PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/zero-success" > "$work/zero-success.json"
  if jq -e '
      [.providers[] | select(.status != "disabled")]
      | length==3
        and ([.[].provider] | sort == ["claude", "codex", "grok"])
        and all(.[]; .status=="failed")
    ' "$work/zero-success/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} aggregate collection retains zero-success default panel"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} aggregate collection retains zero-success default panel"; FAIL=$((FAIL+1)); FAILURES+=("zero-success default panel")
  fi
  jq '
    .tribunal_verdict={"decision":"NEEDS_WORK","confidence":0,"rationale":"No default reviewer completed successfully."}
    | .summary="No usable reviewer evidence; merge remains blocked."
    | .provider_assessment.codex.status="failed"
    | .provider_assessment.grok.status="failed"
    | .provider_assessment.claude.status="failed"
  ' "$work/arbitration.json" > "$work/zero-success-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/zero-success" \
      --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/zero-success.json")" \
      --arbitration "$work/zero-success-arbitration.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} zero-success default panel fails closed at confidence zero"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} zero-success default panel fails closed at confidence zero"; FAIL=$((FAIL+1)); FAILURES+=("zero-success fail closed")
  fi

  FIXTURE_CODEX_MODE=diagnostic PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/diagnostic" > "$work/diagnostic.json"
  if jq -e '.provider=="codex" and (.error | contains("phase=parse; exit=0"))' \
      "$work/diagnostic/providers/codex.json" >/dev/null \
    && PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$work/diagnostic" \
        --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/diagnostic.json")" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} aggregate evidence retains provider diagnostics"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} aggregate evidence retains provider diagnostics"; FAIL=$((FAIL+1)); FAILURES+=("aggregate diagnostics")
  fi

  FIXTURE_CODEX_MODE=finding PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 --output "$work/finding" > "$work/finding.json"
  cat > "$work/finding-arbitration.json" <<'EOF'
{
  "tribunal_verdict":{"decision":"APPROVE","confidence":0.95,"rationale":"The medium finding is non-blocking."},
  "findings":[{"id":"T-001","consensus":"SINGLE_PROVIDER","providers":["codex"],"severity":"medium",
    "category":"logic","file":"app.txt","line":1,"title":"Fixture finding","description":"A concrete fixture defect.",
    "suggestion":"Apply the fixture fix.","confidence":0.9,"arbiter_notes":"Verified and non-blocking."}],
  "scope_findings":[],
  "provider_assessment":{
    "codex":{"findings_accepted":1,"findings_rejected":0,"false_positives":[],"status":"ok"},
    "gemini":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "deepseek":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "qwen":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "grok":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "muse":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"disabled"},
    "claude":{"findings_accepted":0,"findings_rejected":0,"false_positives":[],"status":"ok"}
  },
  "conflicts_resolved":[],"summary":"One medium finding remains non-blocking."
}
EOF
  jq '.findings[0].severity="high"' "$work/finding-arbitration.json" > "$work/missing-blocking-proof.json"
  local finding_manifest
  finding_manifest="$(jq -r .manifest_sha256 "$work/finding.json")"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/finding" \
      --expected-manifest-sha256 "$finding_manifest" --arbitration "$work/missing-blocking-proof.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} strict arbitration requires blocking proof"; FAIL=$((FAIL+1)); FAILURES+=("strict arbitration blocking proof")
  else
    jq -S . "$work/finding-arbitration.json" > "$work/finding/arbitration.json"
    chmod 0444 "$work/finding/arbitration.json"
  fi
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/finding" \
      --expected-manifest-sha256 "$finding_manifest" --arbitration "$work/finding-arbitration.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} interrupted finalize resumes from identical retained arbitration"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} interrupted finalize resumes from identical retained arbitration"; FAIL=$((FAIL+1)); FAILURES+=("interrupted finalize recovery")
  fi

  printf '# never commit\nscratch/\n' > "$repo/.gitignore"
  mkdir -p "$repo/scratch"
  printf 'ignored addition\n' > "$repo/scratch/note.md"
  git -C "$repo" add .gitignore
  git -C "$repo" add -f scratch/note.md
  git -C "$repo" commit -q -m 'force-add ignored path'
  head="$(git -C "$repo" rev-parse HEAD)"
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/ignored" > "$work/ignored.json"
  local ignored_manifest
  ignored_manifest="$(jq -r .manifest_sha256 "$work/ignored.json")"
  if jq -e '. == [{path:"scratch/note.md",pattern:"scratch/",source:".gitignore",line:2}]' \
      "$work/ignored/ignored-paths.json" >/dev/null 2>&1 \
    && jq -e '.ignored_paths.path == "ignored-paths.json" and (.ignored_paths.sha256 | test("^[0-9a-f]{64}$"))
      and (.ignored_paths.bytes > 0)' "$work/ignored/manifest.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} merge-gate collection seals ignored-path evidence"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} merge-gate collection seals ignored-path evidence"; FAIL=$((FAIL+1)); FAILURES+=("sealed ignored-path evidence")
  fi
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/ignored" \
      --expected-manifest-sha256 "$ignored_manifest" --arbitration "$work/arbitration.json" >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} finalize rejects a forgotten ignored-path signal"; FAIL=$((FAIL+1)); FAILURES+=("forgotten ignored-path signal")
  else
    echo -e "  ${GREEN}PASS${NC} finalize rejects a forgotten ignored-path signal"; PASS=$((PASS+1))
  fi
  jq '.findings=[{
      id:"T-001",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
      category:"security",file:"scratch/note.md",line:1,title:"Force-added ignored path",
      description:"The reviewed diff adds a path matched by scratch/ at .gitignore:2.",
      suggestion:"Remove the file or document why force-adding it is safe.",confidence:1,
      arbiter_notes:"Deterministic repository-policy signal; default medium severity."
    }] | .summary="One deterministic medium repository-policy finding remains non-blocking."' \
    "$work/arbitration.json" > "$work/ignored-arbitration.json"
  cp -a "$work/ignored" "$work/ignored-high"
  jq '
    .tribunal_verdict={decision:"NEEDS_WORK",confidence:1,rationale:"The repository policy finding blocks approval."}
    | .findings[0].severity="high"
    | .findings[0].blocking_proof={
        reachable_path:"The reviewed diff force-adds the sealed ignored path.",
        material_impact:"The ignore policy marks the path as never commit.",
        caused_by_change:"The path is newly added in the reviewed range."
      }
    | .findings[0].arbiter_notes="Deterministic repository-policy signal escalated by a sensitive ignore comment."
    | .summary="One high repository-policy finding blocks approval."
  ' "$work/ignored-arbitration.json" > "$work/ignored-high-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/ignored-high" \
      --expected-manifest-sha256 "$ignored_manifest" --arbitration "$work/ignored-high-arbitration.json" \
      >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} high repository-policy finding overrides vacuous approval"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} high repository-policy finding overrides vacuous approval"; FAIL=$((FAIL+1)); FAILURES+=("repository-policy vacuous approval exemption")
  fi
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/ignored" \
      --expected-manifest-sha256 "$ignored_manifest" --arbitration "$work/ignored-arbitration.json" \
      >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} sensitive ignored-path finding cannot be downgraded to medium"; FAIL=$((FAIL+1)); FAILURES+=("sensitive ignored-path severity floor")
  else
    echo -e "  ${GREEN}PASS${NC} sensitive ignored-path finding cannot be downgraded to medium"; PASS=$((PASS+1))
  fi

  local tamper_ec=0
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    FIXTURE_TAMPER_SENSITIVE=on \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/tampered-sensitive" > "$work/tampered-sensitive.json" 2> "$work/tampered-sensitive.err" || tamper_ec=$?
  if [ "$tamper_ec" -eq 1 ] && [ ! -e "$work/tampered-sensitive" ] \
    && grep -Fq 'sensitive-path evidence changed during review' "$work/tampered-sensitive.err"; then
    echo -e "  ${GREEN}PASS${NC} leg rewriting sensitive-path evidence is rejected with a named error"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} leg rewriting sensitive-path evidence is rejected with a named error"; FAIL=$((FAIL+1)); FAILURES+=("pre-leg sensitive-path digest")
  fi

  # Swap immediately after the pre-seal digest check, without a timing race.
  mkdir "$work/digest-state"
  cat > "$fake/sha256sum" <<'EOF'
#!/usr/bin/env bash
EOF
  printf 'digest="$(%q "$@")" || exit $?\n' "$(command -v sha256sum)" >> "$fake/sha256sum"
  cat >> "$fake/sha256sum" <<'EOF'
if [ -n "${FIXTURE_DIGEST_STATE:-}" ] && [[ "${@: -1}" = */sensitive-paths.json ]]; then
  if [ ! -f "$FIXTURE_DIGEST_STATE/pinned" ]; then
    printf '%s\n' "${digest%% *}" > "$FIXTURE_DIGEST_STATE/pinned"
  elif [ ! -f "$FIXTURE_DIGEST_STATE/swapped" ]; then
    printf '[]\n' > "${@: -1}"
    touch "$FIXTURE_DIGEST_STATE/swapped"
  fi
fi
printf '%s\n' "$digest"
EOF
  chmod +x "$fake/sha256sum"
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    FIXTURE_DIGEST_STATE="$work/digest-state" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/check-to-seal" > "$work/check-to-seal.json"
  rm "$fake/sha256sum"
  local seal_ec=0
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$work/check-to-seal" \
      --expected-manifest-sha256 "$(jq -r .manifest_sha256 "$work/check-to-seal.json")" \
      >/dev/null 2> "$work/check-to-seal.err" || seal_ec=$?
  if [ "$seal_ec" -ne 0 ] && [ -f "$work/digest-state/swapped" ] \
    && [ "$(jq -r .sensitive_paths.sha256 "$work/check-to-seal/manifest.json")" = "$(cat "$work/digest-state/pinned")" ] \
    && grep -Fq 'sensitive-path artifact digest mismatch' "$work/check-to-seal.err"; then
    echo -e "  ${GREEN}PASS${NC} sensitive-path manifest pins the pre-leg digest across check-to-seal swap"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} sensitive-path manifest pins the pre-leg digest across check-to-seal swap"; FAIL=$((FAIL+1)); FAILURES+=("sensitive-path check-to-seal digest")
  fi

  local replace_base="$base" replace_head="$head" replace_manifest replace_ec
  base="$head"
  printf 'another ignored addition\n' > "$repo/scratch/replaced.md"
  printf 'three\n' > "$repo/app.txt"
  git -C "$repo" add app.txt
  git -C "$repo" add -f scratch/replaced.md
  git -C "$repo" commit -q -m 'force-add with unchanged ignore policy'
  head="$(git -C "$repo" rev-parse HEAD)"
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    FIXTURE_REPLACE_IGNORE=on FIXTURE_SENSITIVE_CAPTURE="$work/preleg-sensitive.json" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/replaced-ignore" > "$work/replaced-ignore.json"
  replace_manifest="$(jq -r .manifest_sha256 "$work/replaced-ignore.json")"
  if jq -e '. == ["scratch/replaced.md"]' "$work/preleg-sensitive.json" >/dev/null 2>&1 \
    && cmp -s "$work/preleg-sensitive.json" "$work/replaced-ignore/sensitive-paths.json" \
    && [ "$(sha256sum "$work/preleg-sensitive.json" | awk '{print $1}')" = \
         "$(jq -r .sensitive_paths.sha256 "$work/replaced-ignore/manifest.json")" ]; then
    echo -e "  ${GREEN}PASS${NC} sensitive paths are captured before legs and sealed"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} sensitive paths are captured before legs and sealed"; FAIL=$((FAIL+1)); FAILURES+=("pre-leg sensitive paths")
  fi
  jq '.findings[0].file="scratch/replaced.md"' "$work/ignored-arbitration.json" > "$work/replace-medium.json"
  jq '.findings[0].file="scratch/replaced.md"' "$work/ignored-high-arbitration.json" > "$work/replace-high.json"
  replace_ec=0
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/replaced-ignore" \
      --expected-manifest-sha256 "$replace_manifest" --arbitration "$work/replace-medium.json" \
      > "$work/replace-medium.out" 2> "$work/replace-medium.err" || replace_ec=$?
  if [ "$replace_ec" -ne 0 ] && grep -q 'arbitration.*invalid' "$work/replace-medium.err" \
    && PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/replaced-ignore" \
        --expected-manifest-sha256 "$replace_manifest" --arbitration "$work/replace-high.json" >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} replace ref cannot lower sensitive ignored-path severity"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} replace ref cannot lower sensitive ignored-path severity"; FAIL=$((FAIL+1)); FAILURES+=("replace ref sensitive severity")
  fi
  chmod u+w "$work/replaced-ignore"
  chmod u+w "$work/replaced-ignore/sensitive-paths.json" 2>/dev/null || true
  printf '[]\n' > "$work/replaced-ignore/sensitive-paths.json"
  replace_ec=0
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" verify-collection --collection "$work/replaced-ignore" \
      --expected-manifest-sha256 "$replace_manifest" >/dev/null 2> "$work/replace-tamper.err" || replace_ec=$?
  if [ "$replace_ec" -ne 0 ] && grep -q 'sensitive-path artifact digest mismatch' "$work/replace-tamper.err"; then
    echo -e "  ${GREEN}PASS${NC} sealed sensitive paths reject tampering"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} sealed sensitive paths reject tampering"; FAIL=$((FAIL+1)); FAILURES+=("sensitive paths tampering")
  fi
  git -C "$repo" replace -d "$(git -C "$repo" rev-parse HEAD:.gitignore)" >/dev/null
  git -C "$repo" reset -q --hard "$replace_head"
  base="$replace_base"; head="$replace_head"

  local initial_base="$base"
  base="$(git -C "$repo" rev-parse HEAD)"
  printf '# never commit\nscratch/\n*.log\n' > "$repo/.gitignore"
  printf 'ignored log addition\n' > "$repo/audit.log"
  git -C "$repo" add .gitignore
  git -C "$repo" add -f audit.log
  git -C "$repo" commit -q -m 'add second sensitive ignored pattern'
  head="$(git -C "$repo" rev-parse HEAD)"
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/second-sensitive" > "$work/second-sensitive.json"
  local second_sensitive_manifest
  second_sensitive_manifest="$(jq -r .manifest_sha256 "$work/second-sensitive.json")"
  jq '.findings=[{
      id:"T-001",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
      category:"security",file:"audit.log",line:1,title:"Force-added ignored log",
      description:"The reviewed diff adds a path matched by *.log at .gitignore:3.",
      suggestion:"Remove the file or document why force-adding it is safe.",confidence:1,
      arbiter_notes:"Deterministic repository-policy signal; default medium severity."
    }] | .summary="One deterministic medium repository-policy finding remains non-blocking."' \
    "$work/arbitration.json" > "$work/second-sensitive-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/second-sensitive" \
      --expected-manifest-sha256 "$second_sensitive_manifest" --arbitration "$work/second-sensitive-arbitration.json" \
      >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} second sensitive ignored pattern cannot be downgraded to medium"; FAIL=$((FAIL+1)); FAILURES+=("second sensitive ignored-path severity floor")
  else
    echo -e "  ${GREEN}PASS${NC} second sensitive ignored pattern cannot be downgraded to medium"; PASS=$((PASS+1))
  fi

  base="$(git -C "$repo" rev-parse HEAD)"
  printf '# keyboard build artifacts\n*.tmp\n# secretary exports\n*.csv\n' > "$repo/.gitignore"
  printf 'temporary artifact\n' > "$repo/cache.tmp"
  printf 'export artifact\n' > "$repo/report.csv"
  git -C "$repo" add .gitignore
  git -C "$repo" add -f cache.tmp report.csv
  git -C "$repo" commit -q -m 'add non-sensitive keyword-like ignore comments'
  head="$(git -C "$repo" rev-parse HEAD)"
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/keyword-like" > "$work/keyword-like.json"
  local keyword_like_manifest
  keyword_like_manifest="$(jq -r .manifest_sha256 "$work/keyword-like.json")"
  jq '.findings=[
      {id:"T-001",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
       category:"security",file:"cache.tmp",line:1,title:"Force-added ignored temporary artifact",
       description:"The reviewed diff adds a path matched by *.tmp at .gitignore:2.",
       suggestion:"Remove the file or document why force-adding it is safe.",confidence:1,
       arbiter_notes:"Deterministic repository-policy signal; default medium severity."},
      {id:"T-002",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
       category:"security",file:"report.csv",line:1,title:"Force-added ignored export artifact",
       description:"The reviewed diff adds a path matched by *.csv at .gitignore:4.",
       suggestion:"Remove the file or document why force-adding it is safe.",confidence:1,
       arbiter_notes:"Deterministic repository-policy signal; default medium severity."}
    ] | .summary="Two deterministic medium repository-policy findings remain non-blocking."' \
    "$work/arbitration.json" > "$work/keyword-like-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/keyword-like" \
      --expected-manifest-sha256 "$keyword_like_manifest" --arbitration "$work/keyword-like-arbitration.json" \
      >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} keyboard and secretary ignore comments stay non-sensitive"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} keyboard and secretary ignore comments stay non-sensitive"; FAIL=$((FAIL+1)); FAILURES+=("keyword-like ignore comments")
  fi
  base="$(git -C "$repo" rev-parse HEAD)"
  printf '# API keys\n*.tmp\n\n# credentials\n*.csv\n\n# keyboard shortcuts\n*.log\n' > "$repo/.gitignore"
  printf 'key artifact\n' > "$repo/api.tmp"
  printf 'credential artifact\n' > "$repo/creds.csv"
  printf 'shortcut artifact\n' > "$repo/shortcuts.log"
  git -C "$repo" add .gitignore
  git -C "$repo" add -f api.tmp creds.csv shortcuts.log
  git -C "$repo" commit -q -m 'add plural sensitive ignore comments'
  head="$(git -C "$repo" rev-parse HEAD)"
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/plural-sensitive" > "$work/plural-sensitive.json"
  local plural_manifest
  plural_manifest="$(jq -r .manifest_sha256 "$work/plural-sensitive.json")"
  if jq -e 'index("api.tmp") != null and index("creds.csv") != null and index("shortcuts.log") == null' \
      "$work/plural-sensitive/sensitive-paths.json" >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC} plural keys and credentials comments seal paths, keyboard does not"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} plural keys and credentials comments seal paths, keyboard does not"; FAIL=$((FAIL+1)); FAILURES+=("plural sensitive ignore comments")
  fi
  jq '.findings=[
      {id:"T-001",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
       category:"security",file:"api.tmp",line:1,title:"Force-added ignored key artifact",
       description:"The reviewed diff adds a path matched by *.tmp at .gitignore:2.",
       suggestion:"Remove the file or document why force-adding it is safe.",confidence:1,
       arbiter_notes:"Deterministic repository-policy signal; default medium severity."},
      {id:"T-002",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
       category:"security",file:"creds.csv",line:1,title:"Force-added ignored credential artifact",
       description:"The reviewed diff adds a path matched by *.csv at .gitignore:5.",
       suggestion:"Remove the file or document why force-adding it is safe.",confidence:1,
       arbiter_notes:"Deterministic repository-policy signal; default medium severity."},
      {id:"T-003",consensus:"SINGLE_PROVIDER",providers:["repository-policy"],severity:"medium",
       category:"security",file:"shortcuts.log",line:1,title:"Force-added ignored shortcut artifact",
       description:"The reviewed diff adds a path matched by *.log at .gitignore:8.",
       suggestion:"Remove the file or document why force-adding it is safe.",confidence:1,
       arbiter_notes:"Deterministic repository-policy signal; default medium severity."}
    ] | .summary="Deterministic medium repository-policy findings remain non-blocking."' \
    "$work/arbitration.json" > "$work/plural-arbitration.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/plural-sensitive" \
      --expected-manifest-sha256 "$plural_manifest" --arbitration "$work/plural-arbitration.json" \
      >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} plural-comment sensitive path cannot be downgraded to medium"; FAIL=$((FAIL+1)); FAILURES+=("plural sensitive severity floor")
  else
    echo -e "  ${GREEN}PASS${NC} plural-comment sensitive path cannot be downgraded to medium"; PASS=$((PASS+1))
  fi
  base="$initial_base"

  printf '# ordinary scratch files\nscratch/\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -q -m 'make ignored path non-sensitive'
  head="$(git -C "$repo" rev-parse HEAD)"
  PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/non-sensitive" > "$work/non-sensitive.json"
  local non_sensitive_manifest
  non_sensitive_manifest="$(jq -r .manifest_sha256 "$work/non-sensitive.json")"
  # The ambient worktree is deliberately more sensitive than HEAD. Finalization must use HEAD.
  printf '# never commit\nscratch/\n' > "$repo/.gitignore"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/non-sensitive" \
      --expected-manifest-sha256 "$non_sensitive_manifest" --arbitration "$work/ignored-arbitration.json" \
      > "$work/non-sensitive-finalize.json" \
    && jq -e '.proof_sha256 | test("^[0-9a-f]{64}$")' "$work/non-sensitive-finalize.json" >/dev/null \
    && jq -e '.schema == "tribunal-proof/v1" and .arbitration.decision == "APPROVE"' \
      "$work/non-sensitive/proof.json" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC} non-sensitive ignored path accepts medium severity from HEAD"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} non-sensitive ignored path accepts medium severity from HEAD"; FAIL=$((FAIL+1)); FAILURES+=("non-sensitive ignored-path medium severity")
  fi
  jq '.tribunal_verdict.confidence=0' "$work/ignored-arbitration.json" > "$work/non-sensitive-low-confidence.json"
  if PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    "$plugin/scripts/collect-review-evidence.sh" finalize --collection "$work/non-sensitive" \
      --expected-manifest-sha256 "$non_sensitive_manifest" --arbitration "$work/non-sensitive-low-confidence.json" \
      >/dev/null 2>&1; then
    echo -e "  ${RED}FAIL${NC} APPROVE requires confidence 0.95 with repository policy findings"; FAIL=$((FAIL+1)); FAILURES+=("APPROVE confidence pin")
  else
    echo -e "  ${GREEN}PASS${NC} APPROVE requires confidence 0.95 with repository policy findings"; PASS=$((PASS+1))
  fi

  # The sealed wrapper's 4 GiB file limit must not apply to inherited Codex state.
  cp "$PLUGIN_ROOT/scripts/run-codex-review.sh" "$plugin/scripts/"
  "$plugin/scripts/generate-runner-bundle.sh" >/dev/null
  host_codex="$work/normal-codex-home"
  mkdir -p "$host_codex"
  printf '%s\n' '{"fixture_auth":true}' > "$host_codex/auth.json"
  dd if=/dev/zero of="$host_codex/state_5.sqlite" bs=1 count=1 seek=67108864 2>/dev/null
  cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "${CODEX_HOME:?}" > "${FIXTURE_CODEX_HOME_FILE:?}"
grep -qx '{"fixture_auth":true}' "$CODEX_HOME/auth.json" || exit 1
if [ "$(ulimit -f)" = 4194304 ] && [ -f "$CODEX_HOME/state_5.sqlite" ] \
  && [ "$(wc -c < "$CODEX_HOME/state_5.sqlite")" -gt 67108864 ]; then
  exit 0
fi
printf '%s\n' '{"provider":"codex","model":"fixture","files_examined":["app.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
EOF
  chmod +x "$fake/codex"
  if CODEX_HOME="$host_codex" FIXTURE_CODEX_HOME_FILE="$work/codex-home-used" \
    PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
    TRIBUNAL_CODEX=on TRIBUNAL_GEMINI=off TRIBUNAL_DEEPSEEK=off \
    TRIBUNAL_QWEN=off TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off TRIBUNAL_BACKUP_LEGS=off \
    "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
      --output "$work/oversized-codex-state" > "$work/oversized-codex-state.json" \
    && jq -e '.provider=="codex" and .summary.verdict=="APPROVE"' \
      "$work/oversized-codex-state/providers/codex.json" >/dev/null \
    && jq -e 'any(.providers[]; .provider=="codex" and .status=="ok")' \
      "$work/oversized-codex-state/manifest.json" >/dev/null \
    && [ "$(cat "$work/codex-home-used")" != "$host_codex" ]; then
    echo -e "  ${GREEN}PASS${NC} sealed Codex leg isolates oversized inherited state"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} sealed Codex leg isolates oversized inherited state"; FAIL=$((FAIL+1)); FAILURES+=("sealed Codex state isolation")
  fi
  # A leg may grow its own state past the 64 MiB the old cap allowed; a runaway write into the review worktree is still fatal.
  sigxfsz_collect() {  # sigxfsz_collect NAME TARGET_DIR SEEK_BYTES
    cat > "$fake/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
dd if=/dev/null of="${FIXTURE_TARGET:?}/leg-state.bin" bs=1 count=0 seek="${FIXTURE_SEEK:?}" 2>/dev/null || exit $?
printf '%s\n' '{"provider":"codex","model":"fixture","files_examined":["app.txt"],"findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10,"verdict":"APPROVE"}}'
EOF
    FIXTURE_TARGET="$2" FIXTURE_SEEK="$3" CODEX_HOME="$host_codex" \
      PATH="$fake:$PATH" FIXTURE_BASE="$base" FIXTURE_HEAD="$head" FIXTURE_BODY_FILE="$work/pr-body" \
      TRIBUNAL_CODEX=on TRIBUNAL_GEMINI=off TRIBUNAL_DEEPSEEK=off \
      TRIBUNAL_QWEN=off TRIBUNAL_GROK=off TRIBUNAL_CLAUDE=off TRIBUNAL_BACKUP_LEGS=off \
      "$plugin/scripts/collect-review-evidence.sh" collect --repo-root "$repo" --pr 7 \
        --output "$work/$1" > "$work/$1.json" 2>/dev/null
  }
  leg_own_state_ok() {
    sigxfsz_collect own-state "$own_state" 100000000 \
      && jq -e '.provider=="codex" and .summary.verdict=="APPROVE"' "$work/own-state/providers/codex.json" >/dev/null \
      && [ "$(stat -c %s "$own_state/leg-state.bin")" = 100000000 ]
  }
  leg_worktree_flood_fails() {
    sigxfsz_collect worktree-flood . 5000000000 || true
    jq -e '.provider=="codex" and has("error") and (has("summary")|not)' \
      "$work/worktree-flood/providers/codex.json" >/dev/null
  }
  leg_sigxfsz_named() {
    sigxfsz_collect over-cap "$own_state" 5000000000 || true
    jq -e '.provider=="codex" and has("error") and (.error|contains("file size limit (SIGXFSZ)"))' \
      "$work/over-cap/providers/codex.json" >/dev/null
  }
  own_state="$work/leg-own-state"; mkdir -p "$own_state"
  for label in "leg may write past 64 MiB to its own state outside the worktree:leg_own_state_ok" \
    "leg writing past the process cap into the review worktree fails:leg_worktree_flood_fails" \
    "exit-153 leg error says file size limit (SIGXFSZ):leg_sigxfsz_named"; do
    if "${label##*:}"; then
      echo -e "  ${GREEN}PASS${NC} ${label%:*}"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC} ${label%:*}"; FAIL=$((FAIL+1)); FAILURES+=("${label%:*}")
    fi
  done
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}


test_trusted_evidence_collection
