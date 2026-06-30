# tribunal-review

Multi-provider code review plugin for Claude Code. **By default** it runs Codex (GPT-5.5), DeepSeek-V4-Pro via the **OpenCode Go** backend (subscription, then credits on overage), and **Claude** (sonnet) via the host Claude Code CLI, then uses Opus as the final arbiter to deduplicate findings, resolve conflicts, and issue a single authoritative verdict. **Gemini** (3 Pro Preview, web/CVE search), the **OpenCode Go GLM-5.1** leg, and **Qwen** (qwen3.7-plus) via the Qwen Code CLI are available **opt-in** (`TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on` / `TRIBUNAL_QWEN=on`) but off by default — GLM shares architectural lineage with DeepSeek and tends to fail in lockstep, and Qwen reasons over the diff text rather than grounding in files, producing repeated false positives (phantom whitespace, nonexistent symbols, hallucinated line numbers; see [issue #46](https://github.com/paat/claude-plugins/issues/46)), so the default panel keeps the low-false-positive set. (For an independent transport that survives an OpenCode Go quota/429, point `TRIBUNAL_DEEPSEEK_MODEL` at the direct API — `deepseek/deepseek-v4-pro`.) Two of the three default legs — Codex and DeepSeek — **walk the repo** read-only (Codex runs in-container with no `--sandbox` flag); the third, **Claude**, is the panel's **diff-only** lens (run from a scratch dir with all tools disabled), restoring the harness/context diversity the walking legs give up. The opt-in GLM/Gemini legs are also diff-only; the opt-in Qwen leg walks the repo on its own CLI/transport.

## Prerequisites

- [OpenAI Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`)
- [Google Gemini CLI](https://github.com/google-gemini/gemini-cli) — **optional**, only for the Gemini leg (opt-in via `TRIBUNAL_GEMINI=on`; off by default)
- [OpenCode CLI](https://opencode.ai) (≥ 1.15) — harness for **two** legs (required for DeepSeek, which is on by default):
  - **DeepSeek** via an [OpenCode Go](https://opencode.ai/go) subscription (model `opencode-go/deepseek-v4-pro`; subscription first, then credits on overage) — authenticate once with `opencode auth login` (select OpenCode Go). On by default. To use the direct DeepSeek API instead (pay-as-you-go, decorrelated transport), set `TRIBUNAL_DEEPSEEK_MODEL=deepseek/deepseek-v4-pro` and authenticate DeepSeek (`opencode auth login` → DeepSeek, or `DEEPSEEK_API_KEY`).
  - **GLM** via the same [OpenCode Go](https://opencode.ai/go) subscription (model `opencode-go/glm-5.1`) — **opt-in** (`TRIBUNAL_GLM=on`), off by default.
- [Qwen Code CLI](https://github.com/QwenLM/qwen-code) (`npm install -g @qwen-code/qwen-code`, Node 20+) — **optional**, only for the **Qwen leg, which is opt-in** (`TRIBUNAL_QWEN=on`; off by default pending the issue #46 false-positive fix). Auth via `DASHSCOPE_API_KEY` (pay-as-you-go DashScope; new accounts get a free 1M+1M-token tier), an OpenAI-compatible / OpenRouter key, or a credential stored in `~/.qwen/settings.json`.
- [Claude Code CLI](https://docs.claude.com/claude-code) (`claude`) — needed for the **Claude diff-only leg, which runs by default** (disable with `TRIBUNAL_CLAUDE=off`). This is the same CLI you launch the tribunal from, so it is already present and authenticated; the leg just invokes `claude -p` with the configured `TRIBUNAL_CLAUDE_MODEL` (default `sonnet`).
- `jq` (used to parse and validate reviewer JSON output)
- `timeout` (GNU coreutils; on macOS install coreutils for `gtimeout` or it will fall back to an error-JSON for that reviewer) — caps Codex/Gemini at 10 minutes and each OpenCode leg (GLM, DeepSeek) at 6 minutes (single attempt, no retry) — and since GLM and DeepSeek are serialized in one call, that OpenCode call can take up to ~12 minutes combined; a leg that exceeds its cap simply degrades to the available quorum. OpenCode runs the GLM/DeepSeek reasoning models via `opencode run --agent plan`; their latency is inherent generation time with a heavy tail (the `--variant` reasoning-effort flag does **not** meaningfully change it), so the genuine speed lever is swapping in faster non-reasoning models for those slots — a quality/reliability tradeoff left to you
- Valid API keys / auth configured for each CLI

Each reviewer degrades gracefully: if a CLI is missing or a model fails, that reviewer emits an error object and the arbiter proceeds with the remaining reviewers.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install tribunal-review@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit
  `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in
  `.claude/settings.local.json`.

## Usage

On a feature branch with changes vs the repository default branch:

```
/tribunal-loop
```

The skill will verify you're on a feature branch, run the reviews, and produce an arbitrated verdict.

When the verdict comes back `NEEDS_WORK` or `BLOCK`, the `closing-tribunal-loop` skill guides the iterative close-out: per-finding triage (fix-in-PR vs file-follow-up vs reject), committing fixes one finding at a time, and re-running the tribunal until the arbiter returns a verdict with **zero critical and high findings** on the latest diff (see Convergence governor below).

## Convergence governor

The closing loop is **capped and severity-honest** so it cannot spiral:

- **Blocking-finding standard** — a finding is critical/high only if it proves
  a production-reachable path, material impact, and that it is caused/exposed
  by the change under review. Otherwise it is capped at medium.
- **Stop condition** — the loop closes on **zero critical/high** (not zero
  findings). Leftover medium/low go to YAGNI triage (filed only if real and
  worth acting on; else dropped with a PR-body note).
- **Step-back at round 3** — stop adding guards; simplify, descope, or
  down-rate the finding *class*. A step-back round may not increase the net
  count of defensive mechanisms.
- **Grind to a ceiling** — keep looping while any critical/high remains;
  investor checkpoint at round 10; hard escalation at round 20.
- **`reachability.md`** — an optional per-repo file (worker model, concurrency,
  single-user assumptions, money paths) injected into reviewers + arbiter as
  rebuttable context.

## Configuration

The Gemini, DeepSeek, Qwen, and Claude reviewers are configurable via environment variables (export
them in your shell before launching `claude`). All default to the current behavior, so leaving
them unset changes nothing — the default panel is **Codex + DeepSeek + Claude**; Gemini, GLM, and Qwen stay **off** until you opt in (`TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on` / `TRIBUNAL_QWEN=on`).

| Variable | Default | Effect |
|---|---|---|
| `TRIBUNAL_BASE_BRANCH` | resolved default branch | Override the default branch name used to build `origin/<branch>` when reviewing. Normally unnecessary; Codex resolves GitHub default branch, `git remote show origin`, then `origin/HEAD`. |
| `TRIBUNAL_BASE_REF` | `origin/<resolved-default>` | Override the exact base ref used for `git diff "$BASE_REF"...HEAD`. Use this for unusual remotes or review bases. |
| `TRIBUNAL_CODEX` | `on` | Set to `off` to skip the Codex leg. The run degrades to the remaining quorum; the arbiter reports Codex as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_CODEX_MODEL` | _(codex CLI default)_ | Model passed to `codex exec -m`. **Unset by default** — the leg passes no `-m`, so codex uses its own configured default (kept current by the codex CLI, no stale pinned id). Set it to pin a specific model. |
| `TRIBUNAL_GEMINI` | `off` | Set to `on` to enable the Gemini leg (web/CVE search). **Off by default**; when off the arbiter reports Gemini as `disabled`, not failed. Only the literal `on` enables. |
| `TRIBUNAL_GEMINI_MODEL` | `gemini-3-pro-preview` | Model passed to `gemini --model`. Point it at a faster/cheaper slot to keep a full quorum while controlling latency/cost. |
| `TRIBUNAL_DEEPSEEK` | `on` | Set to `off` to skip the DeepSeek leg. The run degrades to the remaining quorum; the arbiter reports DeepSeek as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_DEEPSEEK_MODEL` | `opencode-go/deepseek-v4-pro` | Model passed to `opencode run -m` — runs through the OpenCode Go subscription (then credits). Use `opencode-go/deepseek-v4-flash` for a cheaper/faster per-commit review, or `deepseek/deepseek-v4-pro` to switch to the direct DeepSeek API (independent transport; needs `DEEPSEEK_API_KEY` or `opencode auth login` → DeepSeek). |
| `TRIBUNAL_GLM` | `off` | Set to `on` to enable the OpenCode Go GLM leg. **Off by default** — it shares lineage with DeepSeek and tends to fail in lockstep (issue #41), so the default panel drops it. Only the literal `on` enables. |
| `TRIBUNAL_GLM_MODEL` | `opencode-go/glm-5.1` | Model passed to `opencode run -m` for the GLM leg. |
| `DEEPSEEK_API_KEY` | _(unset)_ | DeepSeek direct-API credential (alternative to `opencode auth login`). |
| `TRIBUNAL_QWEN` | `off` | Set to `on` to enable the Qwen leg. **Off by default** — a real-world audit found it reasons over the diff text rather than grounding in files, emitting repeated false positives (phantom whitespace, nonexistent symbols/SQL, hallucinated line numbers; [issue #46](https://github.com/paat/claude-plugins/issues/46)); disabled pending the mandatory-verification fix. When off the arbiter reports Qwen as `disabled`, not failed. Only the literal `on` enables. |
| `TRIBUNAL_QWEN_MODEL` | `qwen3.7-plus` | Model passed to `qwen --model` (newest Plus model, validated on DashScope Intl). Qwen ids change often through 2026 **and vary by account/region**; qwen-code **silently downgrades an unknown id to its default with no error** (the leg surfaces the model that actually ran in its output `model` field, and Step-1 preflight warns on a fallback). Override with a valid id for your account — e.g. `qwen3.6-plus` for a 1M-context window, or a coder slot like `qwen3-coder-plus` if your account enables it. |
| `DASHSCOPE_API_KEY` | _(unset)_ | Qwen DashScope credential (primary transport). The Qwen Code CLI also accepts `OPENAI_API_KEY`+`OPENAI_BASE_URL` (OpenAI-compatible) or `OPENROUTER_API_KEY` (`qwen/...` ids), or a credential stored via `~/.qwen/settings.json`. |
| `TRIBUNAL_CLAUDE` | `on` | Set to `off` to skip the Claude diff-only leg. **On by default**; when off the arbiter reports Claude as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_CLAUDE_MODEL` | `sonnet` | Model passed to `claude -p --model` for the diff-only leg. Accepts an alias (`sonnet`, `haiku`, `opus`) or a full id (e.g. `claude-sonnet-4-6`). Defaults to `sonnet` — fast/cheap and decorrelated from the Opus arbiter; setting it to `opus` maximizes reviewer↔arbiter correlation. |
| `TRIBUNAL_SCOPE_LENS` | `off` | Set to `on` to add the minimal-diff scope-control lens. The arbiter reports unrelated file changes, opportunistic refactors, unnecessary abstractions, and unrelated churn in a separate `scope_findings` section. |

```bash
export TRIBUNAL_GEMINI=on                           # add the opt-in Gemini leg (web/CVE search)
export TRIBUNAL_GLM=on                              # add the opt-in OpenCode GLM leg
export TRIBUNAL_DEEPSEEK_MODEL=opencode-go/deepseek-v4-flash  # cheaper/faster DeepSeek leg (still OpenCode Go)
export TRIBUNAL_QWEN=on                              # add the opt-in Qwen leg (see issue #46)
export DASHSCOPE_API_KEY=sk-...                     # Qwen auth (needed when TRIBUNAL_QWEN=on)
export TRIBUNAL_SCOPE_LENS=on                       # add minimal-diff scope-control findings
```

### Minimal-diff scope lens

Enable `TRIBUNAL_SCOPE_LENS=on` for bug fixes, hotfixes, incident patches, and plan-driven Codex implementation where reviewability matters. The lens is not a style/nit reviewer. It flags changed files or hunks that do not appear required by the named task, unrelated refactors, new abstractions before repeated call sites exist, defensive branches for impossible internal states, rename/reformat/import churn, and tests that assert unrelated implementation details.

Scope findings are reported separately from correctness/security findings. `must-remove-before-merge` scope findings make the verdict at least `NEEDS_WORK`; `follow-up-only` findings document cleanup without blocking approval.

These knobs apply to the `tribunal-loop` workflow. The standalone `gemini-reviewer` and
`deepseek-reviewer` agents honor their `_MODEL` overrides but have no disable switch —
invoking the agent always means a review is wanted. The standalone `qwen-reviewer` additionally
honors `TRIBUNAL_QWEN` (and `TRIBUNAL_QWEN_MODEL`): since Qwen is off by default it only runs when
`TRIBUNAL_QWEN=on`; otherwise it emits the `disabled` marker.

## How It Works

### Step 1: Pre-flight
Verifies you're on a feature branch (not the resolved default branch) and that there are changes to review against `origin/<default>`, then runs `scripts/preflight.sh`. The default branch is resolved from GitHub first, then `git remote show origin`, then `origin/HEAD`, with `TRIBUNAL_BASE_BRANCH` / `TRIBUNAL_BASE_REF` as overrides. Preflight checks each enabled reviewer leg, free disk space, and that the OpenCode model IDs resolve in the warmed registry. Problems are reported up front so a missing CLI, full disk, or cold model cache fails fast here instead of hanging a launched reviewer; affected reviewers are marked skipped/failed and the run degrades to the available quorum. Only if **zero** active reviewer legs are usable does it stop.

### Step 2: Parallel Review
Runs Codex, Gemini, OpenCode, Qwen, and Claude as **five parallel Bash calls** through `scripts/run-codex-review.sh`, `scripts/run-gemini-review.sh`, `scripts/run-opencode-review.sh`, `scripts/run-qwen-review.sh`, and `scripts/run-claude-review.sh` — though by default only Codex, the OpenCode **DeepSeek** leg, and the **Claude** diff-only leg actually review (Gemini, the OpenCode **GLM** leg, and **Qwen** are opt-in via `TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on` / `TRIBUNAL_QWEN=on`; each disabled leg self-emits a `disabled` marker). Codex walks the repo read-only (in-container with no `--sandbox` flag), like DeepSeek; the opt-in Qwen leg also walks, on its own CLI/transport decorrelated from the OpenCode legs. The **Claude** leg (host `claude -p`) is the one diff-only reviewer in the default panel: it runs from a scratch dir with all tools disabled, so it reviews the diff in isolation and restores the harness/context diversity the walking legs give up — at the cost of sharing model lineage with the Opus arbiter (default model `sonnet` keeps them decorrelated on capability). Each analyzes `git diff "$BASE_REF"...HEAD`, where `BASE_REF` defaults to the resolved `origin/<default>` branch, and returns structured JSON findings covering logic errors, security vulnerabilities, edge cases, performance issues, and architectural concerns. The two OpenCode legs run read-only (`opencode run --agent plan`) and **sequentially within the single OpenCode call** — running them concurrently deadlocks on OpenCode's shared data dir (issue #31), so they are serialized back-to-back. They differ in cwd/context: **GLM** is diff-only, from a scratch dir; **DeepSeek** runs **from the repo root** and — of the two OpenCode-call legs — is the one that **walks the repo** (open related files, trace cross-file effects) rather than reviewing the diff in isolation (Codex and Qwen also walk, in their own calls). Both default to the **OpenCode Go backend** (`opencode-go/…`), so DeepSeek bills against the OpenCode Go subscription, then credits; set `TRIBUNAL_DEEPSEEK_MODEL=deepseek/deepseek-v4-pro` to put DeepSeek on the independent direct API instead. The diff is passed to OpenCode as a **file attachment** (`-f`) rather than inline, which avoids the `MAX_ARG_STRLEN` (128 KiB single-argument) limit that previously made large diffs fail with "Argument list too long". If the repo has an `AGENTS.md`, it is injected into every reviewer's prompt (capped at 16KB) as a shared **Project Conventions** block, so all assess the diff against the same standards.

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
      "blocking_proof": {
        "reachable_path": "...",
        "material_impact": "...",
        "caused_by_change": "..."
      },
      "arbiter_notes": "Flagged independently by codex and qwen"
    }
  ],
  "scope_findings": [],
  "provider_assessment": {
    "codex":    { "findings_accepted": 2, "findings_rejected": 1, "status": "ok" },
    "gemini":   { "findings_accepted": 0, "findings_rejected": 0, "status": "disabled" },
    "glm":      { "findings_accepted": 0, "findings_rejected": 0, "status": "disabled" },
    "deepseek": { "findings_accepted": 1, "findings_rejected": 1, "status": "ok" },
    "qwen":     { "findings_accepted": 1, "findings_rejected": 0, "status": "ok" },
    "claude":   { "findings_accepted": 0, "findings_rejected": 0, "status": "ok" }
  },
  "summary": "Code quality is good with one medium-severity finding to address."
}
```

## Trust Hierarchy

```
Opus (Final authority, runs inline)
  |
Codex · Gemini · GLM · DeepSeek · Qwen · Claude (equal advisory peers — verify findings)
```

The reviewers are equal peers (up to six; by default Codex + DeepSeek + Claude, with Gemini, GLM, and Qwen opt-in); a finding flagged by ≥2 is CONSENSUS. Opus can override any reviewer finding. The Claude diff-only leg shares model lineage with the Opus arbiter, so the arbiter treats it as one peer among many and weighs its findings on the evidence, not the brand.

## License

MIT
