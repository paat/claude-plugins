# tribunal-review

Multi-provider code review plugin for Claude Code. **By default** it runs Codex (GPT-5.3), DeepSeek-V4-Pro on the **direct DeepSeek API**, and **Qwen** (qwen3.7-plus) via the Qwen Code CLI, then uses Opus as the final arbiter to deduplicate findings, resolve conflicts, and issue a single authoritative verdict. **Gemini** (3 Pro Preview, web/CVE search) and the **OpenCode Go GLM-5.1** leg are available **opt-in** (`TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on`) but off by default — GLM shares architectural lineage with DeepSeek and tends to fail in lockstep, so the default panel keeps the decorrelated set. DeepSeek is the one leg that **walks the repo** read-only; Qwen runs diff-only on its own CLI/transport.

## Prerequisites

- [OpenAI Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`)
- [Google Gemini CLI](https://github.com/google-gemini/gemini-cli) — **optional**, only for the Gemini leg (opt-in via `TRIBUNAL_GEMINI=on`; off by default)
- [OpenCode CLI](https://opencode.ai) (≥ 1.15) — harness for **two** legs (required for DeepSeek, which is on by default):
  - **DeepSeek** via the **direct DeepSeek API** (model `deepseek/deepseek-v4-pro`, pay-as-you-go) — authenticate once with `opencode auth login` (select DeepSeek), or set `DEEPSEEK_API_KEY`. On by default.
  - **GLM** via an [OpenCode Go](https://opencode.ai/go) subscription (model `opencode-go/glm-5.1`) — **opt-in** (`TRIBUNAL_GLM=on`), off by default.
- [Qwen Code CLI](https://github.com/QwenLM/qwen-code) (`npm install -g @qwen-code/qwen-code`, Node 20+) — needed for the **Qwen leg, which runs by default** (disable with `TRIBUNAL_QWEN=off`). Auth via `DASHSCOPE_API_KEY` (pay-as-you-go DashScope; new accounts get a free 1M+1M-token tier), an OpenAI-compatible / OpenRouter key, or a credential stored in `~/.qwen/settings.json`.
- `jq` (used to parse and validate reviewer JSON output)
- `timeout` (GNU coreutils; on macOS install coreutils for `gtimeout` or it will fall back to an error-JSON for that reviewer) — caps Codex/Gemini at 10 minutes and each OpenCode leg (GLM, DeepSeek) at 6 minutes (single attempt, no retry) — and since GLM and DeepSeek are serialized in one call, that OpenCode call can take up to ~12 minutes combined; a leg that exceeds its cap simply degrades to the available quorum. OpenCode runs the GLM/DeepSeek reasoning models via `opencode run --agent plan`; their latency is inherent generation time with a heavy tail (the `--variant` reasoning-effort flag does **not** meaningfully change it), so the genuine speed lever is swapping in faster non-reasoning models for those slots — a quality/reliability tradeoff left to you
- Valid API keys / auth configured for each CLI

Each reviewer degrades gracefully: if a CLI is missing or a model fails, that reviewer emits an error object and the arbiter proceeds with the remaining reviewers.

## Installation

```bash
claude plugin add paat/claude-plugins/plugins/tribunal-review
```

## Usage

On a feature branch with changes vs `origin/main`:

```
/tribunal-loop
```

The skill will verify you're on a feature branch, run the reviews, and produce an arbitrated verdict.

When the verdict comes back `NEEDS_WORK` or `BLOCK`, the `closing-tribunal-loop` skill guides the iterative close-out: per-finding triage (fix-in-PR vs file-follow-up vs reject), committing fixes one finding at a time, and re-running the tribunal until the arbiter returns `APPROVE` with zero findings on the latest diff.

## Configuration

The Gemini, DeepSeek, and Qwen reviewers are configurable via environment variables (export
them in your shell before launching `claude`). All default to the current behavior, so leaving
them unset changes nothing — the default panel is **Codex + DeepSeek + Qwen**; Gemini and GLM stay **off** until you opt in (`TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on`).

| Variable | Default | Effect |
|---|---|---|
| `TRIBUNAL_GEMINI` | `off` | Set to `on` to enable the Gemini leg (web/CVE search). **Off by default**; when off the arbiter reports Gemini as `disabled`, not failed. Only the literal `on` enables. |
| `TRIBUNAL_GEMINI_MODEL` | `gemini-3-pro-preview` | Model passed to `gemini --model`. Point it at a faster/cheaper slot to keep a full quorum while controlling latency/cost. |
| `TRIBUNAL_DEEPSEEK` | `on` | Set to `off` to skip the DeepSeek leg. The run degrades to the remaining quorum; the arbiter reports DeepSeek as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_DEEPSEEK_MODEL` | `deepseek/deepseek-v4-pro` | Model passed to `opencode run -m`. Use `deepseek/deepseek-v4-flash` for a cheaper/faster per-commit review. |
| `TRIBUNAL_GLM` | `off` | Set to `on` to enable the OpenCode Go GLM leg. **Off by default** — it shares lineage with DeepSeek and tends to fail in lockstep (issue #41), so the default panel drops it. Only the literal `on` enables. |
| `TRIBUNAL_GLM_MODEL` | `opencode-go/glm-5.1` | Model passed to `opencode run -m` for the GLM leg. |
| `DEEPSEEK_API_KEY` | _(unset)_ | DeepSeek direct-API credential (alternative to `opencode auth login`). |
| `TRIBUNAL_QWEN` | `on` | Set to `off` to skip the Qwen leg. **On by default**; when off the arbiter reports Qwen as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_QWEN_MODEL` | `qwen3.7-plus` | Model passed to `qwen --model` (newest Plus model, validated on DashScope Intl). Qwen ids change often through 2026 **and vary by account/region**; qwen-code **silently downgrades an unknown id to its default with no error** (the leg surfaces the model that actually ran in its output `model` field, and Step-1 preflight warns on a fallback). Override with a valid id for your account — e.g. `qwen3.6-plus` for a 1M-context window, or a coder slot like `qwen3-coder-plus` if your account enables it. |
| `DASHSCOPE_API_KEY` | _(unset)_ | Qwen DashScope credential (primary transport). The Qwen Code CLI also accepts `OPENAI_API_KEY`+`OPENAI_BASE_URL` (OpenAI-compatible) or `OPENROUTER_API_KEY` (`qwen/...` ids), or a credential stored via `~/.qwen/settings.json`. |

```bash
export TRIBUNAL_GEMINI=on                           # add the opt-in Gemini leg (web/CVE search)
export TRIBUNAL_GLM=on                              # add the opt-in OpenCode GLM leg
export TRIBUNAL_DEEPSEEK_MODEL=deepseek/deepseek-v4-flash  # cheaper/faster DeepSeek leg
export DASHSCOPE_API_KEY=sk-...                     # Qwen auth (Qwen runs by default)
```

These knobs apply to the `tribunal-loop` workflow. The standalone `gemini-reviewer` and
`deepseek-reviewer` agents honor their `_MODEL` overrides but have no disable switch —
invoking the agent always means a review is wanted. The standalone `qwen-reviewer` additionally
honors `TRIBUNAL_QWEN` (and `TRIBUNAL_QWEN_MODEL`): since Qwen is on by default it runs unless
`TRIBUNAL_QWEN=off`, in which case it emits the `disabled` marker.

## How It Works

### Step 1: Pre-flight
Verifies you're on a feature branch (not main) and that there are changes to review, then runs an **environment preflight** — checks each reviewer CLI is on `PATH`, free disk space, and that the OpenCode model IDs resolve in the (warmed) registry. Problems are reported up front so a missing CLI, full disk, or cold model cache fails fast here instead of hanging a launched reviewer; affected reviewers are skipped and the run degrades to the available quorum. Only if **zero** providers are usable does it stop.

### Step 2: Parallel Review
Runs Codex, Gemini, OpenCode, and Qwen as **four parallel Bash calls** — though by default only Codex, the OpenCode **DeepSeek** leg, and **Qwen** actually review (Gemini and the OpenCode **GLM** leg are opt-in via `TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on`; each disabled leg self-emits a `disabled` marker). Qwen reviews the diff only, on its own CLI/transport, decorrelated from the OpenCode legs. Each analyzes the `git diff origin/main...HEAD` and returns structured JSON findings covering logic errors, security vulnerabilities, edge cases, performance issues, and architectural concerns. The two OpenCode legs run read-only (`opencode run --agent plan`) and **sequentially within the single OpenCode call** — running them concurrently deadlocks on OpenCode's shared data dir (issue #31), so they are serialized back-to-back. They are otherwise decoupled: **GLM** uses the OpenCode Go backend, diff-only, from a scratch dir; **DeepSeek** uses the **direct DeepSeek API**, runs **from the repo root**, and is the one leg permitted to **walk the repo** (open related files, trace cross-file effects) rather than reviewing the diff in isolation. The diff is passed to OpenCode as a **file attachment** (`-f`) rather than inline, which avoids the `MAX_ARG_STRLEN` (128 KiB single-argument) limit that previously made large diffs fail with "Argument list too long". If the repo has an `AGENTS.md`, it is injected into every reviewer's prompt (capped at 16KB) as a shared **Project Conventions** block, so all assess the diff against the same standards.

### Step 3: Inline Arbitration (Opus)
Opus deduplicates findings, resolves severity conflicts (always using the highest severity), marks any issue flagged by ≥2 reviewers as CONSENSUS, evaluates each finding for validity, and issues a final verdict: **APPROVE**, **NEEDS_WORK**, or **BLOCK**.

## Output Format

The tribunal produces a JSON verdict:

```json
{
  "tribunal_verdict": {
    "decision": "APPROVE|NEEDS_WORK|BLOCK",
    "confidence": 0.92,
    "rationale": "Multiple reviewers agree code is production-ready..."
  },
  "findings": [
    {
      "id": "T-001",
      "consensus": "CONSENSUS",
      "providers": ["codex", "qwen"],
      "severity": "medium",
      "category": "security",
      "file": "src/auth/login.ts",
      "line": 42,
      "title": "Missing input sanitization",
      "description": "User input passed directly to query...",
      "suggestion": "Add parameterized query...",
      "confidence": 0.90,
      "arbiter_notes": "Flagged independently by codex and qwen"
    }
  ],
  "provider_assessment": {
    "codex":    { "findings_accepted": 2, "findings_rejected": 1, "status": "ok" },
    "gemini":   { "findings_accepted": 0, "findings_rejected": 0, "status": "disabled" },
    "glm":      { "findings_accepted": 0, "findings_rejected": 0, "status": "disabled" },
    "deepseek": { "findings_accepted": 1, "findings_rejected": 1, "status": "ok" },
    "qwen":     { "findings_accepted": 1, "findings_rejected": 0, "status": "ok" }
  },
  "summary": "Code quality is good with one medium-severity finding to address."
}
```

## Trust Hierarchy

```
Opus (Final authority, runs inline)
  |
Codex · Gemini · GLM · DeepSeek · Qwen (equal advisory peers — verify findings)
```

The reviewers are equal peers (up to five; by default Codex + DeepSeek + Qwen, with Gemini and GLM opt-in); a finding flagged by ≥2 is CONSENSUS. Opus can override any reviewer finding.

## License

MIT
