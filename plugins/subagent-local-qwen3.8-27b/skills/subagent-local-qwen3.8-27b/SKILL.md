---
name: subagent-local-qwen3.8-27b
description: "Use local llama.cpp Qwen3.8-27B via Qwen Code for bounded mechanical coding with a named test, or a read-only review walk. Keep Codex/Grok for architecture, security, and ambiguous design."
---

# Local Qwen3.8-27B subagent

Drive **Qwen3.8-27B** on local llama.cpp through the Qwen Code CLI. Claude/Codex/Grok stays the controller; this worker is for well-specified edits.

## When to use

- Bounded mechanical coding from a written plan task
- Exact file/line edits plus a **named test** that gates Done
- Independent read-only review of a named target when a second local model helps

Commands:

- `/subagent-local-qwen3.8-27b-implement <plan.md> <taskN>`
- `/subagent-local-qwen3.8-27b-review [<target>]`

## When not to use

Keep Codex / Grok / Claude for:

- Architecture and API design
- Security-sensitive or payments work
- Ambiguous requirements that need judgment, not a mechanical pass

## Harness (do not reinvent)

Wrapper: `scripts/subagent-local-qwen3.8-27b-run.sh`

- Keeps Qwen Code's **built-in** system prompt (never `--system-prompt` replace it)
- Appends the short contracts via `--append-system-prompt` from the plugin-root files
  implement-contract.md and review-contract.md under the references/ directory
- Isolated `HOME` (does not write host `~/.qwen`)
- `--yolo` for implement; `--approval-mode plan` for review
- Thinking on; `reasoning_effort` is `medium` only (never `high`)

Prefer the slash commands; they call the wrapper with the right contract and timeouts.
