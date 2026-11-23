#!/usr/bin/env bash
# Sourced by tests/run-tests.sh.

SK=skills/tribunal-loop/SKILL.md
CL=skills/closing-tribunal-loop/SKILL.md
LIB=scripts/lib.sh
PF=scripts/preflight.sh

echo "Extracted script surface:"
for script in \
  scripts/lib.sh \
  scripts/lib-provider.sh \
  scripts/lib-panel.sh \
  scripts/lib-policy-gates.sh \
  scripts/lib-prompt.sh \
  scripts/lib-output.sh \
  scripts/preflight.sh \
  scripts/run-codex-review.sh \
  scripts/run-gemini-review.sh \
  scripts/run-deepseek-review.sh \
  scripts/run-qwen-review.sh \
  scripts/run-grok-review.sh \
  scripts/run-muse-review.sh \
  scripts/run-claude-review.sh \
  scripts/collect-review-evidence.sh \
  scripts/collector-git-surface.sh \
  scripts/collector-containment.sh \
  scripts/collector-validate.sh \
  scripts/collector-proof.sh \
  scripts/check-runner-bundle.sh \
  scripts/generate-runner-bundle.sh \
  scripts/required-checks.sh
do
  assert_file "$script exists" "$script"
  assert_executable "$script executable" "$script"
  assert_bash_n "$script parses" "$script"
done
assert_file "review panel table exists" "scripts/review-panel.tsv"
assert_grep "diff_stat oid schema accepts sha256 ids" "scripts/collector-validate.sh" '{64}'
assert_file "structured review schema exists" "schemas/review-output.json"
assert_json_field "structured review schema is valid JSON" "jq -e '.type==\"object\" and .additionalProperties==false' '$PLUGIN_ROOT/schemas/review-output.json'"
assert_file "static runner bundle manifest exists" "integrity/runner-bundle.json"
assert_json_field "static runner bundle validates" "bash '$PLUGIN_ROOT/scripts/check-runner-bundle.sh' | jq -e '.status==\"valid\" and (.version|not)'"
assert_json_field "static runner bundle is current" "bash '$PLUGIN_ROOT/scripts/generate-runner-bundle.sh' --check"

echo "Skill is orchestration-focused:"
line_count="$(wc -l < "$PLUGIN_ROOT/$SK" | tr -d ' ')"
if [ "$line_count" -le 260 ]; then
  echo -e "  ${GREEN}PASS${NC} compact tribunal skill ($line_count<=260)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC} compact tribunal skill ($line_count>260)"; FAIL=$((FAIL+1)); FAILURES+=("compact tribunal skill")
fi
assert_grep "skill references preflight script" "$SK" "scripts/preflight.sh"
assert_grep "skill references codex runner" "$SK" "scripts/run-codex-review.sh"
assert_grep "skill references DeepSeek runner" "$SK" "scripts/run-deepseek-review.sh"
assert_grep "skill references grok runner" "$SK" "scripts/run-grok-review.sh"
assert_grep "skill references claude runner" "$SK" "scripts/run-claude-review.sh"
assert_grep "merge gate uses trusted aggregate runner" "$SK" "scripts/collect-review-evidence.sh"
assert_grep "caller provider JSON is not merge evidence" "$SK" "caller-created provider JSON as merge evidence"
assert_no_grep "skill no inline provider command bloat" "$SK" "timeout -k 10 600 codex exec"
assert_grep "skill default panel references review-panel.tsv" "$SK" "scripts/review-panel.tsv"

echo "Preflight/base-ref behavior:"
assert_grep "resolves GitHub default branch" "scripts/lib-policy-gates.sh" "defaultBranchRef"
assert_grep "supports base-ref override" "scripts/lib-policy-gates.sh" "TRIBUNAL_BASE_REF"
assert_grep "resolves the base ref before diffing" "scripts/lib-prompt.sh" 'git rev-parse --verify "$base_ref^{commit}"'
assert_grep "diffs the pinned range" "scripts/lib-prompt.sh" 'git diff "$base_oid...$head_oid"'
assert_grep "pinned range JSON is built by jq, not string interpolation" "scripts/lib-prompt.sh" 'jq -Rn --arg base "$base_ref"'
assert_grep "numstat failure is fail-closed" "scripts/lib-prompt.sh" 'git diff --numstat "$base_oid...$head_oid" --no-ext-diff --no-textconv > "$out.numstat" || return 1'
assert_grep "tracks active reviewer legs" "$PF" "zero active reviewer legs"
assert_grep "Claude auth probe is bounded" "scripts/lib-provider.sh" 'timeout -k 1 "$timeout_s" claude auth status --json'
assert_grep "Claude auth timeout defaults to 20s and is overridable" "$LIB" 'TRIBUNAL_AUTH_TIMEOUT_SECONDS:-20'
assert_grep "preflight checks Claude auth" "$PF" "tribunal_claude_authenticated"
assert_grep "preflight checks Grok auth" "$PF" "tribunal_grok_authenticated"
assert_grep "lib defines Grok auth write-back" "$LIB" "tribunal_grok_auth_writeback"
assert_grep "preflight discloses invocation limitation" "$PF" "non-interactive invocation not probed"
assert_grep "preflight offers bounded non-interactive smoke" "$PF" "TRIBUNAL_SMOKE_PROBE"
assert_no_grep "skill has no hardcoded origin/main" "$SK" "origin/main"
assert_no_grep "lib has no hardcoded origin/main" "scripts/lib-policy-gates.sh" "origin/main"

echo "Context and large-diff guards:"
assert_grep "AGENTS.md capped" "scripts/lib-prompt.sh" "head -c 4096"
assert_grep "reachability.md capped" "scripts/lib-prompt.sh" "head -c 8192"
assert_no_grep "reviewer prompt has no DRY instruction" "scripts/lib-prompt.sh" "DRY: flag meaningful duplication"
assert_grep "diff limit env" "scripts/lib-prompt.sh" "TRIBUNAL_DIFF_LIMIT_BYTES"
assert_grep "large diff uses head -c" "scripts/lib-prompt.sh" 'head -c "$max"'
assert_grep "Codex writes its final response independently of stdout" "scripts/run-codex-review.sh" "--output-last-message"
assert_grep "Codex requests the shared output schema" "scripts/run-codex-review.sh" "--output-schema"
assert_grep "Claude requests the shared output schema" "scripts/run-claude-review.sh" "--json-schema"
assert_grep "Claude smoke disables the complete tool surface" "scripts/run-claude-review.sh" '--tools ""'
assert_grep "Grok requests the shared output schema" "scripts/run-grok-review.sh" "--json-schema"
assert_grep "Grok tools allowlist is read-only" "scripts/run-grok-review.sh" "read_file,list_dir,grep"
assert_grep "Grok sandbox profile is configurable" "scripts/run-grok-review.sh" 'GROK_SANDBOX_PROFILE='
assert_grep "Grok defaults sandbox to none (container boundary)" "scripts/run-grok-review.sh" 'GROK_SANDBOX_PROFILE=none'
assert_grep "Grok honors TRIBUNAL_GROK_SANDBOX" "scripts/run-grok-review.sh" 'TRIBUNAL_GROK_SANDBOX'
assert_grep "Grok rejects invalid sandbox profile" "scripts/run-grok-review.sh" "invalid Grok sandbox profile"
assert_grep "Grok rejects invalid permission mode" "scripts/run-grok-review.sh" "invalid Grok permission mode"
assert_no_grep "Grok does not unset host GROK_SANDBOX" "scripts/run-grok-review.sh" "env -u GROK_SANDBOX"
assert_grep "Grok propagates GROK_SANDBOX into child" "scripts/run-grok-review.sh" 'GROK_SANDBOX="$GROK_SANDBOX_PROFILE"'
assert_grep "Grok isolates host HOME" "scripts/run-grok-review.sh" 'HOME="$ISOLATED_HOME"'
assert_grep "Grok isolates host GROK_HOME" "scripts/run-grok-review.sh" 'GROK_HOME="$ISOLATED_HOME/.grok"'
assert_grep "Grok copies auth into isolation" "scripts/run-grok-review.sh" 'cp -a "$AUTH_SRC" "$AUTH_ISOLATED"'
assert_no_grep "Grok does not symlink auth into isolation" "scripts/run-grok-review.sh" 'ln -s "$AUTH_SRC"'
assert_grep "Grok write-backs auth on cleanup" "scripts/run-grok-review.sh" "tribunal_grok_auth_writeback"
assert_grep "Grok requires signed-in session" "scripts/run-grok-review.sh" "tribunal_grok_authenticated"
assert_grep "Grok disables web search" "scripts/run-grok-review.sh" "--disable-web-search"
assert_grep "Grok pins a session id for resume" "scripts/run-grok-review.sh" "--session-id"
assert_grep "Grok finalize resumes the same session" "scripts/run-grok-review.sh" "--resume"
assert_grep "Grok bounds inspect turns" "scripts/run-grok-review.sh" "--max-turns"
assert_grep "Grok uses bypassPermissions for headless multi-turn" "scripts/run-grok-review.sh" "bypassPermissions"
assert_no_grep "Grok does not hardcode dontAsk" "scripts/run-grok-review.sh" "--permission-mode dontAsk"
assert_grep "Grok rejects progress-only as incomplete" "scripts/run-grok-review.sh" "completion_state=progress_only"
assert_grep "Grok marks non-EndTurn stop as dead_leg" "scripts/run-grok-review.sh" "completion_state=dead_leg"
assert_grep "Grok fails loud on missing schema" "scripts/run-grok-review.sh" "review schema missing"
assert_grep "Grok resolves schema via plugin root helper" "scripts/lib.sh" "tribunal_plugin_root"
assert_grep "Grok finalize re-inlines the authoritative diff" "scripts/run-grok-review.sh" "Base the verdict on the unified diff"
assert_grep "Grok clamps T3 inspect timeout upper bound" "scripts/run-grok-review.sh" "INSPECT_TIMEOUT=2400"
assert_grep "Grok clamps non-T3 inspect timeout at 1800" "scripts/run-grok-review.sh" "INSPECT_TIMEOUT=1800"
assert_grep "Grok extracts camelCase structuredOutput" "scripts/lib-output.sh" "structuredOutput"
assert_grep "Grok payload completeness helper" "scripts/lib-output.sh" "tribunal_review_payload_complete"
assert_grep "Grok payload requires enum verdict" "scripts/lib-output.sh" 'APPROVE" or $v == "NEEDS_WORK" or $v == "BLOCK"'

echo "Disabled-provider markers:"
assert_json_field "deepseek defaults to disabled JSON" "env -u TRIBUNAL_DEEPSEEK bash '$PLUGIN_ROOT/scripts/run-deepseek-review.sh' | jq -e ' .provider==\"deepseek\" and .status==\"disabled\"'"
assert_json_field "codex disabled JSON" "TRIBUNAL_CODEX=off bash '$PLUGIN_ROOT/scripts/run-codex-review.sh' | jq -e '.provider==\"codex\" and .status==\"disabled\"'"
assert_json_field "gemini disabled JSON" "bash '$PLUGIN_ROOT/scripts/run-gemini-review.sh' | jq -e '.provider==\"gemini\" and .status==\"disabled\"'"
assert_json_field "qwen disabled JSON" "bash '$PLUGIN_ROOT/scripts/run-qwen-review.sh' | jq -e '.provider==\"qwen\" and .status==\"disabled\"'"
assert_json_field "grok disabled JSON" "TRIBUNAL_GROK=off bash '$PLUGIN_ROOT/scripts/run-grok-review.sh' | jq -e '.provider==\"grok\" and .status==\"disabled\"'"
assert_json_field "claude disabled JSON" "TRIBUNAL_CLAUDE=off bash '$PLUGIN_ROOT/scripts/run-claude-review.sh' | jq -e '.provider==\"claude\" and .status==\"disabled\"'"

echo "Finding position validation:"
assert_grep "lib defines line-bounds validator" "scripts/lib-output.sh" "tribunal_line_check()"
assert_grep "line check derives NUL-delimited changed paths from pinned range" "scripts/lib-output.sh" 'diff --name-only -z "$base_oid...$head_oid"'
for runner in run-codex-review.sh run-claude-review.sh run-gemini-review.sh run-qwen-review.sh run-grok-review.sh run-muse-review.sh run-deepseek-review.sh; do
  assert_grep "$runner passes pinned range to line check" "scripts/$runner" 'tribunal_line_check "$REPO_ROOT" "$DIFF_STAT"'
  assert_grep "$runner stamps the reviewed range" "scripts/$runner" "tribunal_stamp_diff_stat"
  assert_grep "$runner takes the range off disk before the provider runs" "scripts/$runner" 'DIFF_STAT="$(tribunal_take_diff_stat "$DIFF_FILE")"'
done
assert_grep "arbiter told to distrust marked positions" "$SK" "line_check"
assert_grep "ignored-path signal must become a finding" "$SK" "must become a finding"
assert_grep "ignored-path finding defaults medium" "$SK" "default.*medium"
assert_grep "sensitive ignore comments escalate high" "$SK" "secret.*PII.*credential.*key.*never commit"
assert_grep "high ignored-path finding blocks gate" "$SK" "high.*blocks the gate"
assert_grep "zero-finding approval excludes ignored-path signals" "$SK" "sealed ignored-path signals"
assert_grep "deleted-path signal must become a finding" "$SK" "deleted-paths.json"
assert_grep "deleted-path finding defaults medium" "$SK" "medium .repository-policy. finding"
assert_grep "zero-finding approval excludes deleted-path signals" "$SK" "deleted-path signals"
assert_grep "mutation-gate config needle" "scripts/lib-policy-gates.sh" ".tribunal-mutation-gate"
assert_grep "mutation-gate vacuous result needle" "scripts/lib-policy-gates.sh" "vacuous"
assert_grep "mutation-gate artifact needle" "scripts/collect-review-evidence.sh" "mutation-gate.json"
assert_grep "vacuous mutation-gate must become a finding" "$SK" "vacuous mutation-gate results must become a finding"

echo "Arbitration contract:"
assert_grep "3b-0 in SKILL" "$SK" "3b-0: Blocking-Finding Standard"
assert_grep "standard overrides highest-severity" "$SK" "never override 3b-0"
assert_grep "same-class merge" "$SK" "Same-Class Merge (Every Round)"
assert_grep "reachability read by arbiter" "$SK" "Also read .reachability.md"
assert_grep "blocking_proof schema" "$SK" '"blocking_proof"'
assert_grep "arbiter applies KISS/YAGNI filter" "$SK" "3c: KISS / YAGNI Filter (Arbiter)"
assert_grep "arbiter rewrites over-engineered suggestions" "$SK" "smallest sufficient fix"
assert_grep "KISS/YAGNI alone cannot block" "$SK" "Never promote to critical/high for a KISS/YAGNI violation alone"
assert_grep "scope lens switch" "$SK" "TRIBUNAL_SCOPE_LENS"
assert_grep "scope findings schema" "$SK" "scope_findings"
assert_grep "calling context arbitrates" "$SK" "calling context arbitrates"
assert_grep "caller provider metadata optional" "$SK" "TRIBUNAL_CALLER_PROVIDER"
assert_grep "caller model metadata optional" "$SK" "TRIBUNAL_CALLER_MODEL"
assert_grep "caller effort metadata optional" "$SK" "TRIBUNAL_CALLER_EFFORT"
assert_grep "sealed proof rechecks live PR drift" "$SK" "rechecks live PR drift"
assert_grep "standalone caller identity is optional" "$SK" "standalone runs may leave all three unset"
assert_no_grep "tribunal skill has no Opus authority claim" "$SK" "Opus"
assert_no_grep "closing skill has no Opus authority claim" "$CL" "Opus"
assert_no_grep "README has no Opus authority claim" "README.md" "Opus"
assert_no_grep "README no longer claims preflight stops only at zero usable legs" "README.md" \
  'Only if \*\*zero\*\* active reviewer legs are usable does it stop.'
assert_grep "README documents preflight stop at TRIBUNAL_MIN_OK_LEGS" "README.md" \
  'Preflight stops when zero reviewer legs are usable, or when fewer are usable than `TRIBUNAL_MIN_OK_LEGS`.'
assert_no_grep "Claude reviewer has no Opus authority claim" "agents/claude-reviewer.md" "Opus"

echo "Closing loop governor:"
assert_grep "stop on no crit/high" "$CL" "zero .critical. and"
assert_grep "YAGNI triage" "$CL" "YAGNI triage"
assert_grep "closing loop freezes delivery scope" "$CL" "Frozen Delivery Contract"
assert_grep "scope comes from explicit task text" "$CL" "using only explicit user, issue, PR, or plan text"
assert_grep "missing scope is not invented" "$CL" "Never invent missing"
assert_grep "findings do not redefine task" "$CL" "do not redefine the task"
assert_grep "fixes remain causal and minimal" "$CL" "smallest causal fix"
assert_grep "adjacent concerns do not expand investigation" "$CL" "beyond evidence already present"
assert_grep "step-back preserves architecture" "$CL" "existing architecture"
assert_grep "step-back workflow" "$CL" "Step-back workflow (anti-spiral)"
assert_grep "step-back descope accepts covering issue" "$CL" 'Descope.*covering issue'
assert_grep "falsifiable output accepts covering issue" "$CL" 'follow-up or covering issue'
assert_grep "no-net-increase guard" "$CL" "no-net-increase"
assert_grep "round 3 checkpoint" "$CL" "Round 3 — checkpoint"
assert_grep "round 5 ceiling" "$CL" "Round 5 — hard ceiling"
assert_grep "closing loop is PR-only" "$CL" "PR prerequisite (hard)"
assert_grep "closing loop requires open PR" "$CL" "requires an open GitHub PR"
assert_grep "each round posts a PR comment" "$CL" "the round PR comment"
assert_grep "round comments use stable marker" "$CL" "<!-- tribunal-round:N -->"
assert_grep "round comments post via body-file" "$CL" "gh pr comment"
assert_grep "YAGNI drops land on PR comment" "$CL" "closing round PR comment"
assert_grep "HEAD must match PR headRefOid" "$CL" 'LOCAL_HEAD'
assert_grep "resume derives round from existing markers" "$CL" "PRIOR_MAX"
assert_grep "ceiling is cumulative on the PR" "$CL" "cumulative on the PR"
assert_grep "post comment before applying fixes" "$CL" "applying code fixes for that verdict"
assert_grep "follow-up filing gate with machinery bypass" "$CL" "tribunal/review-machinery follow-ups bypass"
assert_grep "covering-issue or skip recorded in round comment" "$CL" "covering-issue link or the skip reason"
assert_file "round comment template exists" "skills/closing-tribunal-loop/references/round-comment.md"
assert_file "follow-up issue template exists" "skills/closing-tribunal-loop/references/follow-up-issue.md"
assert_grep "round comment template has marker" "skills/closing-tribunal-loop/references/round-comment.md" "<!-- tribunal-round:N -->"
assert_grep "round comment posts with body-file" "skills/closing-tribunal-loop/references/round-comment.md" "gh pr comment"
assert_grep "round comment uses will-fix before commits" "skills/closing-tribunal-loop/references/round-comment.md" "Will-fix"
assert_grep "round comment template has CI line" "skills/closing-tribunal-loop/references/round-comment.md" 'CI:'
assert_grep "round comment CI line cites required-checks" "skills/closing-tribunal-loop/references/round-comment.md" 'required-checks.sh'
assert_grep "closing skill references required-checks script" "$CL" "scripts/required-checks.sh"
assert_grep "closing skill refuses merge on CI failure" "$CL" "refuse to merge"
assert_grep "closing skill runs required-checks before DONE" "$CL" "required-checks.sh on LOCAL_HEAD"
assert_grep "closing skill captures CI exit under set -e" "$CL" '|| CI_EC=$?'
assert_grep "closing skill prefers TRIBUNAL_PLUGIN_ROOT" "$CL" "TRIBUNAL_PLUGIN_ROOT"
assert_grep "required-checks queries REST check-runs" "scripts/required-checks.sh" "check-runs"
assert_no_grep "required-checks is not sealed collector bundle input" "scripts/generate-runner-bundle.sh" "required-checks.sh"

