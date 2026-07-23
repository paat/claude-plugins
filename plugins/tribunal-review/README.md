# tribunal-review

Multi-provider code review plugin for Claude Code and Codex. **By default** it runs Codex (GPT-5.6 Sol at medium effort), DeepSeek-V4-Pro via the **OpenCode Go** backend (subscription, then credits on overage), **Grok** (grok-4.5) via the xAI Grok CLI, and **Claude** (sonnet) via the host Claude Code CLI, then the calling context arbitrates the findings and issues the verdict. **Gemini** (3 Pro Preview, web/CVE search), the **OpenCode Go GLM-5.1** leg, and **Qwen** (qwen3.7-plus) via the Qwen Code CLI are available **opt-in** (`TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on` / `TRIBUNAL_QWEN=on`) but off by default — GLM shares architectural lineage with DeepSeek and tends to fail in lockstep, and Qwen reasons over the diff text rather than grounding in files, producing repeated false positives (phantom whitespace, nonexistent symbols, hallucinated line numbers; see [issue #46](https://github.com/paat/claude-plugins/issues/46)), so the default panel keeps the low-false-positive set. (For an independent transport that survives an OpenCode Go quota/429, point `TRIBUNAL_DEEPSEEK_MODEL` at the direct API — `deepseek/deepseek-v4-pro`.) Three of the four default legs — Codex, DeepSeek, and Grok — **walk the repo**; Codex uses isolated user configuration and unrestricted execution inside the development-container security boundary while its review prompt prohibits file changes. Grok walks under a tools allowlist + kernel read-only sandbox with host config isolated (web search off). The fourth, **Claude**, is the panel's **diff-only** lens (run from a scratch dir with all tools disabled), restoring the harness/context diversity the walking legs give up. The opt-in GLM/Gemini legs are also diff-only; the opt-in Qwen leg walks the repo on its own CLI/transport.

## Mission Fit

`tribunal-review` is the production-quality gate for one-shot SaaS delivery. It gives
autonomous implementation loops an independent review quorum and a bounded convergence
process before merge.

## Prerequisites

- Bash 4+, Git, and standard `awk`/`sed`/coreutils commands
- [OpenAI Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`)
- [Google Gemini CLI](https://github.com/google-gemini/gemini-cli) — **optional**, only for the Gemini leg (opt-in via `TRIBUNAL_GEMINI=on`; off by default)
- [OpenCode CLI](https://opencode.ai) (≥ 1.15) — harness for **two** legs (required for DeepSeek, which is on by default):
  - **DeepSeek** via an [OpenCode Go](https://opencode.ai/go) subscription (model `opencode-go/deepseek-v4-pro`; subscription first, then credits on overage) — authenticate once with `opencode auth login` (select OpenCode Go). On by default. To use the direct DeepSeek API instead (pay-as-you-go, decorrelated transport), set `TRIBUNAL_DEEPSEEK_MODEL=deepseek/deepseek-v4-pro` and authenticate DeepSeek (`opencode auth login` → DeepSeek, or `DEEPSEEK_API_KEY`).
  - **GLM** via the same [OpenCode Go](https://opencode.ai/go) subscription (model `opencode-go/glm-5.1`) — **opt-in** (`TRIBUNAL_GLM=on`), off by default.
- [Qwen Code CLI](https://github.com/QwenLM/qwen-code) (`npm install -g @qwen-code/qwen-code`, Node 20+) — **optional**, only for the **Qwen leg, which is opt-in** (`TRIBUNAL_QWEN=on`; off by default pending the issue #46 false-positive fix). Auth via `DASHSCOPE_API_KEY` (pay-as-you-go DashScope; new accounts get a free 1M+1M-token tier), an OpenAI-compatible / OpenRouter key, or a credential stored in `~/.qwen/settings.json`.
- [Grok CLI](https://github.com/xai-org/grok-cli) (`grok`, "Grok Build") — needed for the **Grok leg, which runs by default** (disable with `TRIBUNAL_GROK=off`). Repo-walking under a tools allowlist (`read_file,list_dir,grep`) plus kernel `--sandbox read-only` (project tree not writable); host Claude/Grok user config is isolated to a scratch HOME while auth is linked. Web search off. The runner pins a session id, bounds inspect turns, and on progress-only/timeout **resumes tools-off** for a schema verdict (never reports success on a plan announcement alone; issue #331). Auth via the CLI's own login (`grok login`). If the CLI is missing the leg self-emits an error JSON and the run degrades to the remaining quorum.
- [Claude Code CLI](https://docs.claude.com/claude-code) (`claude`) — needed for the **Claude diff-only leg, which runs by default** (disable with `TRIBUNAL_CLAUDE=off`). This is the same CLI you launch the tribunal from, so it is already present and authenticated; the leg just invokes `claude -p` with the configured `TRIBUNAL_CLAUDE_MODEL` (default `sonnet`).
- [GitHub CLI](https://cli.github.com) (`gh`) — optional for standalone branch review (which can fall back to Git), but required for sealed PR delivery evidence
- `jq` (used to parse and validate reviewer JSON output)
- `python3` (fallback UUID generation when `uuidgen` and `/proc/sys/kernel/random/uuid` are unavailable)
- `sha256sum` (used to seal PR delivery manifests and retained artifacts)
- `flock` (used to make proof finalization concurrency- and crash-safe)
- `timeout` (GNU coreutils; on macOS install coreutils for `gtimeout` or it will fall back to an error-JSON for that reviewer) — caps Codex, Gemini, Qwen, Grok, and Claude at 10 minutes and each OpenCode leg (GLM, DeepSeek) at 12 minutes (single attempt, no retry) — and since GLM and DeepSeek are serialized in one call, that OpenCode call can take up to ~24 minutes combined; a leg that exceeds its cap simply degrades to the available quorum. OpenCode runs the GLM/DeepSeek reasoning models via `opencode run --agent plan`; their latency is inherent generation time with a heavy tail (the `--variant` reasoning-effort flag does **not** meaningfully change it), so the genuine speed lever is swapping in faster non-reasoning models for those slots — a quality/reliability tradeoff left to you
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

Automated PR delivery uses `scripts/collect-review-evidence.sh` instead of
caller-assembled JSON. Its `collect` phase launches the provider wrappers and
seals the canonical repository, PR body/base/head/diff, runner/wrapper versions,
artifacts, statuses, and timestamps. The delivery controller retains the
manifest digest. After inline arbitration, its `finalize` phase rechecks live PR
drift and every retained digest, validates the exact finding/arbitration schema,
and emits a `tribunal-proof/v1` digest. Provider artifacts supplied by a caller
are never merge authority. Failed provider artifacts retain the failure phase,
exit code, byte counts, and truncation flags. Set `TRIBUNAL_DIAGNOSTIC_TAILS=on`
only for local troubleshooting to add printable-ASCII 2 KiB stdout/stderr tails;
tails are omitted by default because provider errors can contain credentials.
Preflight `usable` status confirms discovery/authentication only; it does not
claim that a non-interactive reviewer invocation has succeeded. Set
`TRIBUNAL_SMOKE_PROBE=on` to make preflight issue one minimal, timeout-bounded
structured-output request through each usable default transport before review.

Controllers can pin the installed runner bundle with one digest:

```bash
bundle_sha="$(sha256sum "$TRIBUNAL_PLUGIN_ROOT/integrity/runner-bundle.json" | awk '{print $1}')"
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/check-runner-bundle.sh" \
  --expected-manifest-sha256 "$bundle_sha"
```

Regenerate it after an intentional runner change with
`scripts/generate-runner-bundle.sh`; `--check` is the CI no-drift check.
`finalize` is crash-idempotent: an identical retry returns the retained proof,
while a different arbitration for that collection is rejected.

When the verdict comes back `NEEDS_WORK` or `BLOCK`, the `closing-tribunal-loop` skill guides the iterative close-out: per-finding triage (fix-in-PR vs file-follow-up vs reject), committing fixes one finding at a time, and re-running the tribunal until the arbiter returns a verdict with **zero critical and high findings** on the latest diff (see Convergence governor below).

## Convergence governor

The closing loop is **capped and severity-honest** so it cannot spiral:

- **Blocking-finding standard** — a finding is critical/high only if it proves
  a production-reachable path, material impact, and that it is caused/exposed
  by the change under review. Otherwise it is capped at medium.
- **Stop condition** — the loop closes on **zero critical/high** (not zero
  findings). Leftover medium/low go to YAGNI triage (filed only if real and
  worth acting on; else dropped with a PR-body note).
- **Frozen scope** — the original outcome, acceptance checks, invariants, and
  exclusions govern every round; reviewer findings do not redefine the task.
- **Step-back at round 3** — stop adding guards; simplify, descope, or
  down-rate the finding *class*. A step-back round may not increase the net
  count of defensive mechanisms.
- **Bounded retry** — keep looping while any critical/high remains;
  checkpoint at round 3; hard escalation at round 5.
- **`reachability.md`** — an optional per-repo file (worker model, concurrency,
  single-user assumptions, money paths) injected into reviewers + arbiter as
  rebuttable context.

## Configuration

The reviewer settings and optional caller identity are configurable via environment variables (export
them before launching the host). The default panel is **Codex + DeepSeek + Grok + Claude**; Gemini, GLM,
and Qwen stay **off** until you opt in (`TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on` / `TRIBUNAL_QWEN=on`).

| Variable | Default | Effect |
|---|---|---|
| `TRIBUNAL_BASE_BRANCH` | resolved default branch | Override the default branch name used to build `origin/<branch>` when reviewing. Normally unnecessary; Codex resolves GitHub default branch, `git remote show origin`, then `origin/HEAD`. |
| `TRIBUNAL_BASE_REF` | `origin/<resolved-default>` | Override the exact base ref used for `git diff "$BASE_REF"...HEAD`. Use this for unusual remotes or review bases. |
| `TRIBUNAL_CODEX` | `on` | Set to `off` to skip the Codex leg. The run degrades to the remaining quorum; the arbiter reports Codex as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_CODEX_MODEL` | `gpt-5.6-sol` | Model passed explicitly to `codex exec -m`. An environment value overrides this default. |
| `TRIBUNAL_CODEX_EFFORT` | `medium` | Reasoning effort passed explicitly through `model_reasoning_effort`. An environment value overrides this default. The Codex leg forces isolated user configuration and always passes `--dangerously-bypass-approvals-and-sandbox`; the development container is the security boundary. |
| `TRIBUNAL_GEMINI` | `off` | Set to `on` to enable the Gemini leg (web/CVE search). **Off by default**; when off the arbiter reports Gemini as `disabled`, not failed. Only the literal `on` enables. |
| `TRIBUNAL_GEMINI_MODEL` | `gemini-3-pro-preview` | Model passed to `gemini --model`. Point it at a faster/cheaper slot to keep a full quorum while controlling latency/cost. |
| `TRIBUNAL_DEEPSEEK` | `on` | Set to `off` to skip the DeepSeek leg. The run degrades to the remaining quorum; the arbiter reports DeepSeek as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_DEEPSEEK_MODEL` | `opencode-go/deepseek-v4-pro` | Model passed to `opencode run -m` — runs through the OpenCode Go subscription (then credits). OpenCode uses its read-only `plan` agent with permission prompts bypassed for non-interactive execution; as with Codex, the development container is the security boundary. Use `opencode-go/deepseek-v4-flash` for a cheaper/faster per-commit review, or `deepseek/deepseek-v4-pro` to switch to the direct DeepSeek API (independent transport; needs `DEEPSEEK_API_KEY` or `opencode auth login` → DeepSeek). |
| `TRIBUNAL_GLM` | `off` | Set to `on` to enable the OpenCode Go GLM leg. **Off by default** — it shares lineage with DeepSeek and tends to fail in lockstep (issue #41), so the default panel drops it. Only the literal `on` enables. |
| `TRIBUNAL_GLM_MODEL` | `opencode-go/glm-5.1` | Model passed to `opencode run -m` for the GLM leg. |
| `DEEPSEEK_API_KEY` | _(unset)_ | DeepSeek direct-API credential (alternative to `opencode auth login`). |
| `TRIBUNAL_QWEN` | `off` | Set to `on` to enable the Qwen leg. **Off by default** — a real-world audit found it reasons over the diff text rather than grounding in files, emitting repeated false positives (phantom whitespace, nonexistent symbols/SQL, hallucinated line numbers; [issue #46](https://github.com/paat/claude-plugins/issues/46)); disabled pending the mandatory-verification fix. When off the arbiter reports Qwen as `disabled`, not failed. Only the literal `on` enables. |
| `TRIBUNAL_QWEN_MODEL` | `qwen3.7-plus` | Model passed to `qwen --model` (newest Plus model, validated on DashScope Intl). Qwen ids change often through 2026 **and vary by account/region**; qwen-code **silently downgrades an unknown id to its default with no error** (the leg surfaces the model that actually ran in its output `model` field, and Step-1 preflight warns on a fallback). Override with a valid id for your account — e.g. `qwen3.6-plus` for a 1M-context window, or a coder slot like `qwen3-coder-plus` if your account enables it. |
| `DASHSCOPE_API_KEY` | _(unset)_ | Qwen DashScope credential (primary transport). The Qwen Code CLI also accepts `OPENAI_API_KEY`+`OPENAI_BASE_URL` (OpenAI-compatible) or `OPENROUTER_API_KEY` (`qwen/...` ids), or a credential stored via `~/.qwen/settings.json`. |
| `TRIBUNAL_GROK` | `on` | Set to `off` to skip the Grok leg (xAI Grok CLI; repo-walking with tools allowlist + kernel read-only sandbox; host config isolated; inspect→tools-off finalize resume for deterministic completion — issue #331). **On by default**; when off the arbiter reports Grok as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_GROK_MODEL` | `grok-4.5` | Model passed to `grok --model`. The leg surfaces the model that actually ran (from the CLI's `.modelUsage`) in its output `model` field. |
| `TRIBUNAL_GROK_TIMEOUT_SECONDS` | `600` | Inspect-phase wall timeout (seconds) before automatic tools-off finalize resume. |
| `TRIBUNAL_GROK_FINALIZE_TIMEOUT_SECONDS` | `120` | Finalize-phase wall timeout after resume with tools disabled. |
| `TRIBUNAL_GROK_MAX_TURNS` | `30` | Inspect-phase `--max-turns` budget. |
| `TRIBUNAL_GROK_FINALIZE_MAX_TURNS` | `6` | Finalize-phase `--max-turns` budget. |
| `TRIBUNAL_CLAUDE` | `on` | Set to `off` to skip the Claude diff-only leg. **On by default**; when off the arbiter reports Claude as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_CLAUDE_MODEL` | `sonnet` | Model passed to `claude -p --model` for the diff-only leg. Accepts an alias (`sonnet`, `haiku`, `opus`) or a full id (e.g. `claude-sonnet-5`). |
| `TRIBUNAL_SMOKE_PROBE` | `off` | Set to `on` to make preflight verify the actual non-interactive Codex, Claude, and enabled OpenCode transports with minimal structured responses. Each probe is a real provider request; a failed probe removes that leg from usable quorum. |
| `TRIBUNAL_SMOKE_TIMEOUT_SECONDS` | `60` | Per-provider timeout for the opt-in smoke probe; accepted range is 5–300 seconds. |
| `TRIBUNAL_DIAGNOSTIC_TAILS` | `off` | Set to `on` only for local troubleshooting to include printable-ASCII 2 KiB stdout/stderr tails in failed provider artifacts. Phase, exit code, byte counts, and truncation remain available when tails are omitted. Tails may contain sensitive provider output. |
| `TRIBUNAL_SCOPE_LENS` | `off` | Set to `on` to add the minimal-diff scope-control lens. The arbiter reports unrelated file changes, opportunistic refactors, unnecessary abstractions, and unrelated churn in a separate `scope_findings` section. |
| `TRIBUNAL_CALLER_PROVIDER` | _(unset)_ | Optional informational identity for the inline calling context. It does not select or spawn an arbiter. |
| `TRIBUNAL_CALLER_MODEL` | _(unset)_ | Optional caller model metadata. Standalone runs may leave it unset. |
| `TRIBUNAL_CALLER_EFFORT` | _(unset)_ | Optional caller effort metadata. Standalone runs may leave it unset. |

```bash
export TRIBUNAL_GEMINI=on                           # add the opt-in Gemini leg (web/CVE search)
export TRIBUNAL_GLM=on                              # add the opt-in OpenCode GLM leg
export TRIBUNAL_DEEPSEEK_MODEL=opencode-go/deepseek-v4-flash  # cheaper/faster DeepSeek leg (still OpenCode Go)
export TRIBUNAL_QWEN=on                              # add the opt-in Qwen leg (see issue #46)
export DASHSCOPE_API_KEY=sk-...                     # Qwen auth (needed when TRIBUNAL_QWEN=on)
export TRIBUNAL_GROK=off                             # skip the default-on Grok leg
export TRIBUNAL_SCOPE_LENS=on                       # add minimal-diff scope-control findings
```

### Minimal-diff scope lens

Enable `TRIBUNAL_SCOPE_LENS=on` for bug fixes, hotfixes, incident patches, and plan-driven Codex implementation where reviewability matters. The lens is not a style/nit reviewer. It flags changed files or hunks that do not appear required by the named task, unrelated refactors, new abstractions before repeated call sites exist, defensive branches for impossible internal states, rename/reformat/import churn, and tests that assert unrelated implementation details.

Scope findings are reported separately from correctness/security findings. `must-remove-before-merge` scope findings make the verdict at least `NEEDS_WORK`; `follow-up-only` findings document cleanup without blocking approval.

These knobs apply everywhere. The standalone Codex/Gemini/Qwen/Grok/Claude reviewer agents are thin
wrappers over the same `scripts/run-*.sh` runners (DeepSeek/OpenCode remain documentation pointers
to the combined OpenCode runner), so runner invocations honor every variable identically to the
loop — including the enable/disable switches. An off-by-default leg (Gemini, GLM, Qwen) therefore emits its `disabled`
marker when invoked standalone unless you opt in (`TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on` /
`TRIBUNAL_QWEN=on`).

## How It Works

### Step 1: Pre-flight
Verifies you're on a feature branch (not the resolved default branch) and that there are changes to review against `origin/<default>`, then runs `scripts/preflight.sh`. The default branch is resolved from GitHub first, then `git remote show origin`, then `origin/HEAD`, with `TRIBUNAL_BASE_BRANCH` / `TRIBUNAL_BASE_REF` as overrides. Preflight checks each enabled reviewer leg, free disk space, and that the OpenCode model IDs resolve in the warmed registry. With `TRIBUNAL_SMOKE_PROBE=on`, it also exercises the real non-interactive default transports using minimal structured responses. Problems are reported up front so a missing CLI, full disk, cold model cache, or immediately broken transport fails fast here instead of hanging a launched reviewer; affected reviewers are marked skipped/failed and the run degrades to the available quorum. Only if **zero** active reviewer legs are usable does it stop.

### Step 2: Parallel Review
Runs Codex, Gemini, OpenCode, Qwen, Grok, and Claude as **six parallel Bash calls** through `scripts/run-codex-review.sh`, `scripts/run-gemini-review.sh`, `scripts/run-opencode-review.sh`, `scripts/run-qwen-review.sh`, `scripts/run-grok-review.sh`, and `scripts/run-claude-review.sh` — though by default Codex, the OpenCode **DeepSeek** leg, **Grok**, and the **Claude** diff-only leg actually review (Gemini, the OpenCode **GLM** leg, and **Qwen** are opt-in via `TRIBUNAL_GEMINI=on` / `TRIBUNAL_GLM=on` / `TRIBUNAL_QWEN=on`; each disabled leg self-emits a `disabled` marker). Codex walks the repo with isolated user configuration and unrestricted execution inside the development-container security boundary; its prompt still limits the task to review and prohibits file changes. The default-on **Grok** leg also walks (tools allowlist + kernel read-only sandbox + isolated host config; web search off); disable with `TRIBUNAL_GROK=off`. The opt-in Qwen leg walks on its own CLI/transport. The **Claude** leg (host `claude -p`) is the one diff-only reviewer in the default panel: it runs from a scratch dir with all tools disabled, so it reviews the diff in isolation and restores the harness/context diversity the walking legs give up. Each analyzes `git diff "$BASE_REF"...HEAD`, where `BASE_REF` defaults to the resolved `origin/<default>` branch, and returns structured JSON findings covering logic errors, security vulnerabilities, edge cases, performance issues, architectural concerns, and meaningful DRY violations. The two OpenCode legs use the read-only `plan` agent (`opencode run --agent plan`) and run **sequentially within the single OpenCode call** — running them concurrently deadlocks on OpenCode's shared data dir (issue #31), so they are serialized back-to-back. Permission prompts are bypassed for non-interactive execution; the development container is their security boundary, while the `plan` agent remains the mutation-control layer. They differ in cwd/context: **GLM** is diff-only, from a scratch dir; **DeepSeek** runs **from the repo root** and — of the two OpenCode-call legs — is the one that **walks the repo** (open related files, trace cross-file effects) rather than reviewing the diff in isolation (Codex, Grok, and Qwen also walk, in their own calls). Both default to the **OpenCode Go backend** (`opencode-go/…`), so DeepSeek bills against the OpenCode Go subscription, then credits; set `TRIBUNAL_DEEPSEEK_MODEL=deepseek/deepseek-v4-pro` to put DeepSeek on the independent direct API instead. The diff is passed to OpenCode as a **file attachment** (`-f`) rather than inline, which avoids the `MAX_ARG_STRLEN` (128 KiB single-argument) limit that previously made large diffs fail with "Argument list too long". If the repo has an `AGENTS.md`, it is injected into every reviewer's prompt (capped at 16KB) as a shared **Project Conventions** block, so all assess the diff against the same standards.

For a PR merge gate, the aggregate evidence runner owns these launches and runs
them from a clean detached worktree at the exact PR head. This keeps local dirty
state and caller-authored evidence out of the delivery decision.

### Step 3: Inline Arbitration
The calling context deduplicates findings, resolves severity conflicts, marks any issue flagged by ≥2 reviewers as CONSENSUS, evaluates each finding for validity (including a KISS/YAGNI filter on findings and suggested fixes), and issues a final verdict: **APPROVE**, **NEEDS_WORK**, or **BLOCK**.

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
    "codex":    { "findings_accepted": 2, "findings_rejected": 1, "false_positives": [], "status": "ok" },
    "gemini":   { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "disabled" },
    "glm":      { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "disabled" },
    "deepseek": { "findings_accepted": 1, "findings_rejected": 1, "false_positives": [], "status": "ok" },
    "qwen":     { "findings_accepted": 1, "findings_rejected": 0, "false_positives": [], "status": "ok" },
    "claude":   { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok" }
  },
  "conflicts_resolved": [],
  "summary": "Code quality is good with one medium-severity finding to address."
}
```

## Trust Hierarchy

```
Calling context (final decision, runs inline)
  |
Codex · Gemini · GLM · DeepSeek · Qwen · Grok · Claude (equal advisory peers — verify findings)
```

The reviewers are equal peers (up to seven; by default Codex + DeepSeek + Grok + Claude, with Gemini, GLM, and Qwen opt-in); a finding flagged by ≥2 is CONSENSUS. The calling context can override a reviewer finding, but must weigh claims on evidence rather than provider identity.

## License

MIT
