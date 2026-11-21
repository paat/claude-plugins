---
allowed-tools: Bash, Read, Glob, Grep
description: Route implementation across Claude Code, Codex, Grok Build, and Muse Code with task-sized models and efforts, then review independently
argument-hint: "<implementation request and any provider/model/effort restrictions>"
---

# /multi-model-orchestrator:orchestrate

Load `skills/multi-model-orchestration/SKILL.md` and execute it for `$ARGUMENTS`. The skill owns
the policy (restrictions, YOLO boundary, gates, reviewer selection); this file adds how to read the
request, the preflight, and the exact commands.

## Required interpretation

- Natural wording is authoritative: “only,” “do not use,” allowlists and denylists.
- “Implement with Codex only” means every source edit belongs to a Codex worker. A fresh Codex
  reviewer is allowed; Claude Code, Grok Build, and Muse Code are not.
- An explicit current model or compatible effort overrides the router default for that named leg.
  Reject contradictory restrictions and unsupported effort/model combinations.

## Preflight

1. Resolve the repository root and read its applicable agent instructions.
2. Require a non-empty implementation request, `git`, a clean worktree, and only the CLIs selected
   by the route. Stop with the exact missing or unauthenticated provider unless an allowed fallback
   was declared.
3. Capture `BASE_SHA=$(git rev-parse HEAD)`. This is the review base for the entire run.
4. Inspect only the files needed to decide whether any work remains. Exit immediately when
   the requested state and its tests already hold.

## Execute

1. Load `skills/route-model-task/SKILL.md`, apply its strict catalog and restrictions, and produce
   a compact task ledger: task id, tier, acceptance test, allowed files, dependencies, provider,
   exact model, effort, and one-sentence routing reason. Prefer one pass and shallow fan-out.
2. When the route card asks for Claude advice before implementation:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-claude.sh" --mode advise --repo "$REPO_ROOT" --model "$ROUTED_ADVICE_MODEL" --effort "$ROUTED_ADVICE_EFFORT" <<'PROMPT'
   <one self-contained question; request constraints and a file map, not source edits>
   PROMPT
   ```

3. Dispatch each ready task with the route card's exact arguments: preserve the tier, mode,
   `--prefer`, `--allow`/`--deny` and usage snapshot from selection. A task-specific effort
   differing from the table uses the recorded direct runner after eligibility checks.

   ```bash
   # ROUTED_POOL_ARGS holds preference, restrictions and usage flags; never an eval string.
   "${CLAUDE_PLUGIN_ROOT}/scripts/pool.sh" run --tier "$ROUTED_TIER" "${ROUTED_POOL_ARGS[@]}" --mode implement --repo "$REPO_ROOT" --timeout 1200 \
     --allow-paths '<globs>' --verify-cmd '<exact test command>' --task '<id>' --cycle 1 <<'PROMPT'
   You are one bounded implementation worker. Implement only TASK <id>.
   Acceptance: <observable result>. Test: <the --verify-cmd command>.
   Allowed files: <the --allow-paths globs>. Do not edit any other path or commit.
   Preserve unrelated behavior and existing user work. No speculative abstractions or refactors.
   Run the named test, inspect your diff, and stop when acceptance passes.
   PROMPT
   ```

   The pool names the worker that ran on stderr; record it in the ledger. `8`/`9`/`10` (with
   `check=` on its last line) mean scope, test, or no change failed: a fix cycle; `11` means no
   check ran, so nothing is accepted. Its own `75` means nobody in the tier chain was available:
   report the blocker with the reset it printed. `55` means the failing worker had already edited the tree: salvage or reset before redispatching;
   `76` (a Grok turn cap or Muse step cap on an implement leg) is handled the same way. A pinned
   model calls its runner directly (`run-codex.sh` takes `--dir`); omit `--effort` for Claude
   Haiku 4.5. Local Qwen and agy review only with `--mode review --base <range>`. Never replace
   a current model with an earlier generation when a route is unavailable.

4. Gate each worker and then the whole diff as the skill's Implementation gates say. Do not claim
   completion on model testimony alone.

## Independent final review

Follow the skill's Final review: `tribunal-review:closing-tribunal-loop` on the pushed PR by
default, inline reviewer legs only as its fallback. For the fallback, choose reviewer route cards
after implementation and give each the original request, acceptance criteria, `BASE_SHA`, and a
bounded finding contract. A leg can outlast the host's foreground command limit (Claude Code
Bash: 10 minutes), so dispatch each worker and this reviewer block through the host's background
mechanism (Claude Code: Bash `run_in_background: true`) and continue on its completion notice. Create `RUN_DIR=$(mktemp -d)` before dispatch and remove it
after findings are arbitrated.

```bash
legs=()   # one --leg per reviewer actually launched; each leg takes its model and effort from its own reviewer route card
"${CLAUDE_PLUGIN_ROOT}/scripts/run-claude.sh" --mode review --repo "$REPO_ROOT" --base "$BASE_SHA" --model "$ROUTED_CLAUDE_REVIEW_MODEL" --effort "$ROUTED_CLAUDE_REVIEW_EFFORT" <<'PROMPT' > "$RUN_DIR/claude.txt" &
<task and acceptance criteria; ask for architecture, intent, UX, scope, and integration defects>
PROMPT
claude_pid=$!; legs+=(--leg claude="$RUN_DIR/claude.txt")
"${CLAUDE_PLUGIN_ROOT}/scripts/run-codex.sh" --mode review --dir "$REPO_ROOT" --model "$ROUTED_CODEX_REVIEW_MODEL" --effort "$ROUTED_CODEX_REVIEW_EFFORT" --timeout 1200 <<'PROMPT' > "$RUN_DIR/astra.txt" &
Review the complete diff from BASE_SHA=<sha> to the working tree. Do not modify files.
Return at most 10 actionable findings with severity, file:line, reachable failure, and a test.
Ignore speculative edge cases without a realistic failure path. End with APPROVE or NEEDS_WORK.
PROMPT
astra_pid=$!; legs+=(--leg codex="$RUN_DIR/astra.txt")
"${CLAUDE_PLUGIN_ROOT}/scripts/run-grok.sh" --mode review --repo "$REPO_ROOT" --base "$BASE_SHA" --model "$ROUTED_GROK_REVIEW_MODEL" --effort "$ROUTED_GROK_REVIEW_EFFORT" <<'PROMPT' > "$RUN_DIR/grok.txt" &
<task and acceptance criteria; ask for reachable code defects and a verdict>
PROMPT
grok_pid=$!; legs+=(--leg grok="$RUN_DIR/grok.txt")
review_failed=0
wait "$claude_pid" || review_failed=1
wait "$astra_pid" || review_failed=1
wait "$grok_pid" || review_failed=1
[ "$review_failed" -eq 0 ] || { printf '%s\n' 'One or more reviewers failed; do not arbitrate their output.' >&2; exit 1; }
gate_rc=0
# --author is the implementing provider (an agy worker: agy/<model> from the ledger); drop it only when the request restricts the run to one provider.
verdict="$("${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh" --author "$WORKER_PROVIDER" "${legs[@]}")" || gate_rc=$?
case "$gate_rc" in
  0) ;;                                   # APPROVE: continue to arbitration notes
  1) review_needs_work=1 ;;               # arbitrate to find WHAT to fix; never proceed on this verdict
  3) printf '%s\n' 'No independent reviewer (advisory engine or the author provider only); launch one.' >&2; exit 3 ;;
  *) printf '%s\n' 'A review leg is missing or has no verdict; do not arbitrate.' >&2; exit "$gate_rc" ;;
esac
```

On `review_needs_work=1` the run is not done: arbitrate the findings, fix only the confirmed ones,
rerun the affected tests, and run the reviewers and this gate again. Only a gate exit of 0 ends
review: when that one recheck still does not return 0, stop and report the open findings as a
blocker, never the task as done.

The snippet illustrates all providers; launch only the selected allowed route cards.
