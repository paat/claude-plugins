---
allowed-tools: Bash, Read, Glob, Grep
description: Route implementation across Claude Code, Codex, and Grok Build with task-sized models and efforts, then review independently
argument-hint: "<implementation request and any provider/model/effort restrictions>"
---

# /multi-model-orchestrator:orchestrate

Load `skills/multi-model-orchestration/SKILL.md` and execute it for `$ARGUMENTS`.

## Required interpretation

- Natural wording is authoritative. Apply “only,” “do not use,” and provider/model allowlists or
  denylists before routing. Never dispatch a forbidden provider.
- “Implement with Codex only” means every source edit belongs to a GPT-5.6 worker. A fresh Codex
  reviewer is allowed; Claude Code and Grok Build are not.
- An explicit current model or compatible effort overrides the router default for that named leg.
  Reject contradictory restrictions and unsupported effort/model combinations.
- Every selected CLI runs in YOLO mode. Do not downgrade the runner flags; the development
  container is the security boundary. Reviewer/adviser prompts and tool lists remain read-only.

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
   a compact task ledger: task id, acceptance test, allowed files, dependencies, provider, exact
   model, effort, and one-sentence routing reason. Prefer one pass and shallow fan-out.
2. When the route card asks for Claude advice before implementation:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-claude.sh" --mode advise --repo "$REPO_ROOT" --model claude-opus-5 --effort high <<'PROMPT'
   <one self-contained question; request constraints and a file map, not source edits>
   PROMPT
   ```

3. Dispatch each ready task with the runner named by its route card. Default to sequential
   execution; parallel writes require disjoint declared files and no shared generated state.

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-codex.sh" --mode implement --dir "$REPO_ROOT" --model "$ROUTED_MODEL" --effort "$ROUTED_EFFORT" --timeout 1200 <<'PROMPT'
   You are one bounded implementation worker. Implement only TASK <id>.
   Acceptance: <observable result and exact test>.
   Allowed files: <paths>. Do not edit any other path or commit.
   Preserve unrelated behavior and existing user work. No speculative abstractions or refactors.
   Run the named test, inspect your diff, and stop when acceptance passes.
   PROMPT
   ```

   Claude Code route:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-claude.sh" --mode implement --repo "$REPO_ROOT" --model "$ROUTED_MODEL" --effort "$ROUTED_EFFORT" <<'PROMPT'
   <same bounded worker contract>
   PROMPT
   ```

   Grok Build route:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-grok.sh" --mode implement --repo "$REPO_ROOT" --model grok-4.5 --effort "$ROUTED_EFFORT" <<'PROMPT'
   <same bounded worker contract>
   PROMPT
   ```

   For Claude Haiku 4.5, omit `--effort`; its current reasoning control is not supported by this
   runner. Never replace a current model with an earlier generation when a route is unavailable.

4. After every worker, inspect the diff, reject out-of-scope paths, and run its named test.
   Do not launch the next dependent task until this gate passes. Allow one targeted correction;
   otherwise report the blocker.
5. Run the complete directly affected deterministic test set. Do not claim completion on model
   testimony alone.

## Independent final review

Default: push the branch, open (or update) the PR, and chain
`tribunal-review:closing-tribunal-loop` on it — that skill owns preflight, rounds, PR comments,
and the zero-critical/high exit; you arbitrate as calling context and never restate its
protocol.

Fallback — inline reviewer legs, only when `tribunal-review` is not installed or the caller
explicitly asked for a local no-PR run. Choose reviewer route cards after implementation. Use
one different provider for ordinary nontrivial work and two only for high risk or conflicting
evidence, subject to provider restrictions. Give each the original request, acceptance criteria,
`BASE_SHA`, and a bounded finding contract. Reviewers must not edit. Run multiple reviewers
concurrently and independently. Create `RUN_DIR=$(mktemp -d)` before dispatch and remove it
after findings are arbitrated.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/run-claude.sh" --mode review --repo "$REPO_ROOT" --base "$BASE_SHA" --model claude-opus-5 --effort high <<'PROMPT' > "$RUN_DIR/claude.txt" &
<task and acceptance criteria; ask for architecture, intent, UX, scope, and integration defects>
PROMPT
claude_pid=$!
"${CLAUDE_PLUGIN_ROOT}/scripts/run-codex.sh" --mode review --dir "$REPO_ROOT" --model gpt-5.6-sol --effort "$ROUTED_REVIEW_EFFORT" --timeout 1200 <<'PROMPT' > "$RUN_DIR/sol.txt" &
Review the complete diff from BASE_SHA=<sha> to the working tree. Do not modify files.
Return at most 10 actionable findings with severity, file:line, reachable failure, and a test.
Ignore speculative edge cases without a realistic failure path. End with APPROVE or NEEDS_WORK.
PROMPT
sol_pid=$!
"${CLAUDE_PLUGIN_ROOT}/scripts/run-grok.sh" --mode review --repo "$REPO_ROOT" --base "$BASE_SHA" --model grok-4.5 --effort high <<'PROMPT' > "$RUN_DIR/grok.txt" &
<task and acceptance criteria; ask for reachable code defects and a verdict>
PROMPT
grok_pid=$!
review_failed=0
wait "$claude_pid" || review_failed=1
wait "$sol_pid" || review_failed=1
wait "$grok_pid" || review_failed=1
[ "$review_failed" -eq 0 ] || { printf '%s\n' 'One or more reviewers failed; do not arbitrate their output.' >&2; exit 1; }
```

The snippet illustrates all providers; launch only the selected allowed route cards. Verify every
finding against the repository. Fix only confirmed task-blocking defects, rerun affected tests,
and permit at most one bounded recheck. Report the ledger, tests, reviewer verdicts,
accepted/rejected findings, and final diff scope.
