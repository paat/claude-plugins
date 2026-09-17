# subagent-local-qwen3.8-27b

Drive **local llama.cpp Qwen3.8-27B** as a coding implementer/reviewer subagent from Claude Code / Codex / Grok, using the **Qwen Code CLI** against a host OpenAI-compatible endpoint.

This plugin is bound to **Qwen3.8-27B**. A different local model is a different `subagent-local-<modelname>-<version>` plugin (prompts, sampling, and preflight aliases stay per-plugin).

## Prerequisites

1. **Qwen Code CLI >= 0.23.4** on `PATH` as `qwen` (needs `--yolo` / `--approval-mode`).
2. **llama.cpp** (or compatible) serving the **Qwen3.8-27B coding** profile on an OpenAI endpoint. Default base URL: `http://127.0.0.1:8000/v1`; when `OPENAI_BASE_URL` is unset and that is unreachable, the wrapper also tries the container gateway (`host.docker.internal`, then the default route) — llama.cpp usually runs on the host, not in the dev container. Default alias: `Qwen3.8-27B-UD-Q6_K_XL-coding`.
3. Standard tools: `bash` 4+, `curl`, `jq`, `timeout` (GNU coreutils), `mktemp`, `git`.

The wrapper uses an **isolated HOME** and writes `settings.json` only there — it never writes the host `~/.qwen` (so tribunal DashScope credentials stay untouched).

## Commands

| Command | Role | FS access | Use it for |
|---------|------|-----------|------------|
| `/subagent-local-qwen3.8-27b-implement <plan.md> <taskN>` | implementer | yes (edits + commits) | implement ONE plan task with a named test gate, then review the diff |
| `/subagent-local-qwen3.8-27b-review [<target>]` | reviewer | yes (read-only walk) | independent second-model review of a diff / plan / file |

Both call `scripts/subagent-local-qwen3.8-27b-run.sh`:

- implement → `--yolo` + implement contract
- review → `--approval-mode plan` + review contract
- Keep Qwen Code's built-in system prompt; append only the short contract (`--append-system-prompt`)
- `-o json`, `--output-style Concise`, `--exclude-tools agent`
- Prompt on **stdin**; dual timeouts (wrapper `--timeout` + host Bash-tool timeout)

## The wrapper

```bash
scripts/subagent-local-qwen3.8-27b-run.sh [--dir D] [--model M] [--effort medium] \
  [--timeout S] [--max-session-turns N] [--max-wall-time 15m] \
  [--yolo | --approval-mode plan] [--diff BASE] [--out F] [--prompt-file F] [PROMPT]
```

`--diff BASE` writes `git diff BASE` to a temp dir **outside** the repo, shares it with the worker via `--include-directories`, and points the prompt at it — nothing is ever written into the target repo. Name both ends of the range — `--diff 'HEAD~1..HEAD'` for a commit, `--diff 'origin/main...HEAD'` for a branch, `--diff HEAD` for the uncommitted working tree — and note it requires `--approval-mode plan` — review mode (`--approval-mode plan`) has **no shell**, so the worker cannot run git and would otherwise review only the current files and miss regressions.

Exit codes: `0` ok, `2` usage, `75` transient (llama.cpp down or busy — retry, or route the task to another engine), `1` wrong model or other refusal, `124`/`143` timeout, `127` CLI missing.

`--print-cmd` shows the `qwen` argv without executing; it prints the base command, without the `--diff` patch wiring (no patch is produced for a preview).

`--diff HEAD` covers tracked changes only — `git diff` never reports untracked files, so commit or stage a brand-new file before reviewing it. Preflight fails closed when llama.cpp is down, busy (one in-flight GPU request), or serving a non-coding / `longctx` alias.

`reasoning_effort` is `medium` only (`xhigh|medium|low` — never `high`). Thinking-mode sampling: temp 1.0, top_p 0.95, top_k 20.

## Skill

`subagent-local-qwen3.8-27b` — when to use this worker (bounded mechanical coding + named test) vs when to keep Codex/Grok (architecture, security, ambiguous design).

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install subagent-local-qwen3.8-27b@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in `.claude/settings.local.json`.

## Tests

```bash
bash plugins/subagent-local-qwen3.8-27b/tests/run-tests.sh
```

Stub `qwen` on `PATH` (no live llama.cpp). Covers print-cmd flags, isolated HOME, missing binary, down/wrong-model preflight, yolo vs plan, stdin prompt, and timeout.

## License

MIT
