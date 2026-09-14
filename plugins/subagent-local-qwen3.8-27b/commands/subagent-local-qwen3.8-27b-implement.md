---
allowed-tools: Bash, Read, Edit, Grep
description: Dispatch local llama.cpp Qwen3.8-27B (Qwen Code CLI) as the implementer for ONE named task from a plan file
argument-hint: <plan.md> <taskN> [--model <id>] [--dir <repo>]
---

Dispatch **local Qwen3.8-27B** via the Qwen Code CLI (`--yolo`, llama.cpp OpenAI endpoint) as an **implementer subagent** to implement exactly one task from a written plan, then review what it produced. You are the controller — the worker edits and may commit; you verify.

**Arguments:** $ARGUMENTS

## Steps

1. **Parse arguments.** First token is the plan file path (`<plan.md>`), second is the task identifier (`<taskN>`, e.g. `Task 3`). Optional `--model <id>` overrides the served coding alias; `--dir <repo>` sets the repo (default: current repo root). Read the plan file yourself so you know which files and tests the task touches — but do NOT paste it; the worker reads the plan itself.

2. **Determine the commit trailer.** If this project requires a trailer on commits (check `CLAUDE.md` / project conventions), note its literal text — you'll substitute it for `<COMMIT_TRAILER>` in the prompt below. If none, omit the trailer instruction.

3. **Dispatch with the implementer contract.** Build the prompt below and run it through the wrapper. Pass the prompt on stdin (never as a giant argv string), and set a generous Bash-tool `timeout` (≥ 900000 ms) so the tool does not SIGTERM the worker mid-task:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/subagent-local-qwen3.8-27b-run.sh" --dir <repo> [--model <id>] --yolo --timeout 900 <<'PROMPT'
   You are an implementer. Implement ONLY "<taskN>" from the plan file <plan.md>.
   Read the plan file yourself.

   Rules:
   - Implement ONLY <taskN>. Do NOT touch unrelated lines or any other task.
   - The task's named outcome, acceptance criteria, files, and tests define Done.
   - Use the EXACT code given in the plan. Do not improvise alternatives.
   - Preserve existing behavior outside Done. Do not add features, dependencies,
     abstractions, refactors, fallbacks, or generalized edge-case handling unless
     concrete evidence shows Done cannot pass without them. Report adjacent issues;
     do not investigate or fix them.
   - If any code anchor in the plan (a line/function the plan says to edit) does
     NOT match the real file, STOP and report the mismatch. Do not guess.
   - Run only the named and directly affected tests. After they pass, complete the required commit and report, then stop without further investigation.
   - Commit exactly the files the task names, using the plan's commit message
     plus this required trailer line: <COMMIT_TRAILER>
   - Report ONLY: the final test PASS line(s), the output of
     `git --no-pager show --stat HEAD`, and `Deferred: <uninvestigated adjacent
     issue>` entries when applicable. No other prose or summary.
   PROMPT
   ```

   The heredoc is single-quoted (`<<'PROMPT'`) so the shell does NOT expand `$` or backticks. That also means `<COMMIT_TRAILER>` is **not** auto-substituted: before dispatching, replace it with your project's actual trailer text (from step 2). If the project needs no trailer, drop that bullet entirely.

   Set the Bash-tool `timeout` parameter to at least 900000 (15 min) to match `--timeout 900`. **Both layers must be generous.**

   The wrapper appends `references/implement-contract.md` via `--append-system-prompt` and keeps the Qwen Code built-in system prompt (never `--system-prompt` replace it).

4. **Handle wrapper outcomes:**
   - **Timeout / exit 124 or 143** → killed mid-task; partial uncommitted edits may remain. Follow the recovery steps the wrapper prints, then retry with a larger `--timeout` AND a larger Bash-tool timeout.
   - **Preflight fail (down / busy / wrong-model)** → do not invent a result; report the blocker.
   - **"code anchor doesn't match" report** → reconcile the plan with the actual file, then re-dispatch. Do NOT let the worker guess.

5. **Review the diff.** Run `git --no-pager show HEAD` (or `git -C <repo> ...`). Independently verify:
   - only the named task's files changed, nothing unrelated,
   - the change matches the plan's intent,
   - the commit message + required trailer are present,
   - the reported tests actually correspond to the task.

   **Minimal-diff scope control.** Every changed file and hunk must be required by `<taskN>` or the tests/build plumbing it names. Reject opportunistic refactors, new abstractions, defensive dead code, and unrelated churn. Necessary fixture/test/build updates are allowed only if you can state why `<taskN>` requires them.

6. **Close with at most one correction.** If review finds a task-blocking defect, make one targeted fix or one re-dispatch, then rerun affected tests. Defer non-blocking and adjacent findings. If the correction still fails, report the blocker instead of starting another loop.

## Notes

- One task per invocation. Narrow scope, named test gate, per-task review.
- Bound model is **Qwen3.8-27B** (coding profile). A different local model needs a different plugin.
- For architecture, security, or ambiguous design, keep Codex/Grok instead of this worker.
