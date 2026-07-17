---
allowed-tools: Bash, Read, Glob, Grep
description: Route implementation through bounded Codex workers with task-sized effort, then run independent Opus and Sol reviews
argument-hint: "<implementation request> [--final-codex-effort low|medium|high|xhigh|max|ultra]"
---

# /multi-model-orchestrator:orchestrate

Load `skills/multi-model-orchestration/SKILL.md` and execute it for `$ARGUMENTS`.

## Required interpretation

- Natural wording is authoritative. “Implement with Codex subagents” means all source edits
  are assigned to fresh Codex workers. Opus may advise or review but does not take those edits.
- “Review with Opus and GPT-5.6 Sol Ultra” means one fresh Opus/xhigh review and one fresh
  `gpt-5.6-sol`/`ultra` review after implementation and deterministic checks pass.
- An explicit model or effort overrides the router default for that named leg.

## Preflight

1. Resolve the repository root and read its applicable agent instructions.
2. Require a non-empty implementation request, `git`, `codex`, and a clean worktree. Also
   require `claude` when the route includes an Opus pass. Stop with the exact missing item.
3. Capture `BASE_SHA=$(git rev-parse HEAD)`. This is the review base for the entire run.
4. Inspect only the files needed to decide whether any work remains. Exit immediately when
   the requested state and its tests already hold.

## Execute

1. Produce a compact task ledger: task id, acceptance test, allowed files, dependencies,
   assigned model, effort, and one-sentence routing reason. Prefer one pass and shallow fan-out.
2. For ambiguity in product intent, UX, architecture, or environment diagnosis, get a bounded
   Opus advice pass before implementation:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-opus.sh" --mode advise --repo "$REPO_ROOT" --effort xhigh <<'PROMPT'
   <one self-contained question; request constraints and a file map, not source edits>
   PROMPT
   ```

3. Dispatch each ready implementation task to a fresh Codex worker. Default to sequential
   execution; parallel writes require disjoint declared files and no shared generated state.

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/run-codex.sh" --dir "$REPO_ROOT" --effort <routed-effort> --timeout 1200 <<'PROMPT'
   You are one bounded implementation worker. Implement only TASK <id>.
   Acceptance: <observable result and exact test>.
   Allowed files: <paths>. Do not edit any other path or commit.
   Preserve unrelated behavior and existing user work. No speculative abstractions or refactors.
   Run the named test, inspect your diff, and stop when acceptance passes.
   PROMPT
   ```

4. After every worker, inspect the diff, reject out-of-scope paths, and run its named test.
   Do not launch the next dependent task until this gate passes. Allow one targeted correction;
   otherwise report the blocker.
5. Run the complete directly affected deterministic test set. Do not claim completion on model
   testimony alone.

## Independent final review

Run the reviewers concurrently when both were requested. Give both the original request,
acceptance criteria, `BASE_SHA`, and a bounded finding contract. Reviewers must not edit.
Create `RUN_DIR=$(mktemp -d)` for their outputs before dispatch.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/run-opus.sh" --mode review --repo "$REPO_ROOT" --base "$BASE_SHA" --effort xhigh <<'PROMPT' > "$RUN_DIR/opus.txt" &
<task and acceptance criteria; ask for architecture, intent, UX, scope, and integration defects>
PROMPT
"${CLAUDE_PLUGIN_ROOT}/scripts/run-codex.sh" --dir "$REPO_ROOT" --effort <requested-or-routed-final-effort> --timeout 1200 <<'PROMPT' > "$RUN_DIR/sol.txt" &
Review the complete diff from BASE_SHA=<sha> to the working tree. Do not modify files.
Return at most 10 actionable findings with severity, file:line, reachable failure, and a test.
Ignore speculative edge cases without a realistic failure path. End with APPROVE or NEEDS_WORK.
PROMPT
wait
```

Verify every finding against the repository. Fix only confirmed task-blocking defects, rerun
affected tests, and permit at most one bounded recheck. Report the ledger, tests, both reviewer
verdicts, accepted/rejected findings, and final diff scope.
