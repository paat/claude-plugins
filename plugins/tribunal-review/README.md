# tribunal-review

Multi-provider code review plugin for Claude Code and Codex. **By default** it runs Codex (GPT-6 Astra at medium effort), **Grok** (grok-4.7) via the xAI Grok CLI, **Muse** (`muse-spark-1.3`) via Meta's Muse Code CLI, and **Claude** (sonnet) via the host Claude Code CLI, then the calling context arbitrates the findings and issues the verdict. **Gemini** (via agy, web/CVE search), **DeepSeek V4 Pro** via DeepSeek Harness (`dsh`), and **Qwen** (qwen3.8-max) via the Qwen Code CLI are available **opt-in**. To enable DeepSeek, set `TRIBUNAL_DEEPSEEK=on`; it defaults to `deepseek-v4-pro` on the direct DeepSeek API. Codex, Grok, and Muse **walk the repo**; Codex uses isolated user configuration and unrestricted execution inside the development-container security boundary while its review prompt prohibits file changes. Grok walks under a tools allowlist with host config isolated (web search off); sandbox defaults to `none` because the development container is the security boundary (kernel `read-only` needs nested user namespaces and fails inside many containers — issue #378; opt in with `TRIBUNAL_GROK_SANDBOX=read-only`). Muse walks with write and shell tools disabled. **Claude** is the panel's **diff-only** lens (run from a scratch dir with all tools disabled), restoring the harness/context diversity the walking legs give up. The opt-in Gemini leg is also diff-only; the opt-in DeepSeek and Qwen legs walk the repo on their own configured transports. When the checkout holds untracked `.env*` files outside ignored directories, every repo-walking leg walks a scratch clone of the reviewed HEAD instead, so it cannot read them and send the values to its provider; the shell-capable Qwen and DeepSeek legs also start with a scrubbed environment (issue [#589](https://github.com/paat/claude-plugins/issues/589)).

## Mission Fit

`tribunal-review` is the production-quality gate for one-shot SaaS delivery. It gives
autonomous implementation loops an independent review quorum and a bounded convergence
process before merge.

## Prerequisites

- Bash 4+, git 2.42+ (sealed collection uses `--attr-source` and `cat-file -Z`), and standard `awk`/`sed`/coreutils commands
- [OpenAI Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`)
- [Antigravity CLI](https://antigravity.google/docs/cli/install/) (`agy`) — **optional**, only for the Gemini leg (opt-in via `TRIBUNAL_GEMINI=on`; off by default). Sign in once with a Google AI Pro/Ultra account, or set `GEMINI_API_KEY` for API-key mode. Gemini CLI no longer serves personal Google accounts
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`, npm package `@deepseek-ai/dsh`; Node `^22.19 || >=24`) — **optional**, for the opt-in DeepSeek leg (`TRIBUNAL_DEEPSEEK=on`). Default model: `deepseek-v4-pro`; override with `TRIBUNAL_DEEPSEEK_MODEL`. Configure the key in the environment (`DEEPSEEK_API_KEY`), in `${DSH_HOME:-$HOME/.dsh}/.credentials.yaml` (`refs.DEEPSEEK_API_KEY`), or in `${DSH_HOME:-$HOME/.dsh}/.env`; dsh resolves the key, and preflight checks presence without printing it. The default model pin is not covered by the repository's daily model-ID refresh (`scripts/refresh-model-versions.sh` has no DeepSeek catalog source); bump `deepseek-v4-pro` by hand when DeepSeek ships a successor.
- [Qwen Code CLI](https://github.com/QwenLM/qwen-code) (`npm install -g @qwen-code/qwen-code`, Node 20+) — **optional**, only for the **Qwen leg, which is opt-in** (`TRIBUNAL_QWEN=on`; off by default pending the issue #46 false-positive fix). Auth via `DASHSCOPE_API_KEY` (pay-as-you-go DashScope; new accounts get a free 1M+1M-token tier), an OpenAI-compatible / OpenRouter key, or a credential stored in `~/.qwen/settings.json`.
- [Grok CLI](https://github.com/xai-org/grok-cli) (`grok`, "Grok Build") — needed for the **Grok leg, which runs by default** (disable with `TRIBUNAL_GROK=off`). Repo-walking under a tools allowlist (`read_file,list_dir,grep`) with `--sandbox none` by default (container is the security boundary; set `TRIBUNAL_GROK_SANDBOX=read-only` where unprivileged user namespaces work) and `--permission-mode bypassPermissions` (issue #378; `dontAsk` cancels multi-turn inspect). Host Claude/Grok user config is isolated to a scratch HOME while `auth.json` is **copied** (not symlinked) and any OIDC refresh is written back under `flock` so Max/SuperGrok autonomous loops keep a live session (issue #374). Web search off. The runner pins a session id, bounds inspect turns, and with `TRIBUNAL_GROK_RECOVERY=permit` (default), on progress-only/timeout **resumes tools-off** for a schema verdict (never reports success on a plan announcement alone; issue #331). Non-`EndTurn` stop reasons without a schema verdict fail as a dead leg (not a quiet empty review). Auth via the CLI's own login (`grok login`, or `grok login --device-code` headless); preflight skips a present CLI with no usable session. Max subscription users should prefer a durable OIDC session (`refresh_token` in `~/.grok/auth.json`) over pasting `XAI_API_KEY` (console billing rail). If the CLI is missing or unsigned-in the leg self-emits an error JSON and the run degrades to the remaining quorum.
- [Muse Code CLI](https://meta.ai) (`muse`) — needed for the **Muse leg, which runs by default** (disable with `TRIBUNAL_MUSE=off`). Runs `muse exec --yolo` (headless exec otherwise blocks on an approval prompt) with `--disable-write --disable-shell --disable-web-tools`, so only read and search tools remain, and `--output-schema` for the review JSON. Requests `muse-spark-1.3` unless `TRIBUNAL_MUSE_MODEL` is set. `TRIBUNAL_MUSE_MODEL=default` passes no `--model` and runs whatever the installed CLI selects; a `-contributor` id lets Meta use the content for product improvement. Auth via `muse login` or `META_API_KEY`.
- [Claude Code CLI](https://docs.claude.com/claude-code) (`claude`) — needed for the **Claude diff-only leg, which runs by default** (disable with `TRIBUNAL_CLAUDE=off`). This is the same CLI you launch the tribunal from, so it is already present and authenticated; the leg just invokes `claude -p` with the configured `TRIBUNAL_CLAUDE_MODEL` (default `sonnet`).
- [GitHub CLI](https://cli.github.com) (`gh`) — optional for standalone branch review (which can fall back to Git), but required for sealed PR delivery evidence
- `jq` (used to parse and validate reviewer JSON output)
- `python3` (fallback UUID generation when `uuidgen` and `/proc/sys/kernel/random/uuid` are unavailable)
- `sha256sum` (used to seal PR delivery manifests and retained artifacts)
- `flock` (used to make proof finalization concurrency- and crash-safe)
- Sealed collection requires Bash 4.3+ (`wait -n`) and Linux: `setsid` (util-linux), procps `ps -o sid`, and GNU `stat -c` for session containment and Git directory identity/config checks. On macOS, run sealed collection in a Linux container; the `gtimeout` guidance below applies only to standalone reviewer legs.
- Optional `unshare --map-current-user` (util-linux ≥ 2.38) with unprivileged user/PID namespaces gives each sealed leg its own PID namespace, preserving the caller's uid. Exiting PID 1 kills all descendants, including detached sessions, before normalization. The collector probes once; unavailable namespaces fall back to session cleanup with a `tribunal evidence: containment degraded:` stderr line. Grok's opt-in `TRIBUNAL_GROK_SANDBOX=read-only` also uses that fallback because its bubblewrap requires host PID visibility. The sealed manifest records `containment: pid-namespace|session` per provider and `session` for the collection if any leg degraded. No private proc mount is required. The PID namespace contains only the leg's own descendants; a leg can still start processes outside it through services reachable as the same user (docker group, tmux, systemd-run, ssh to localhost), so the dev container remains the security boundary.
- `timeout` (GNU coreutils; on macOS install coreutils for `gtimeout` or the reviewer returns an error JSON) — caps Codex, Gemini, Qwen, Grok, Muse, Claude, and DeepSeek at 10 minutes. Each leg has an independent timeout; a failed leg degrades to the available quorum.
- Valid API keys / auth configured for each enabled CLI

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
tails are otherwise omitted by default because provider errors can contain credentials.
Sealed collection does not support `extensions.worktreeConfig=true` (per-worktree config cannot be contained); disable it or run tribunal from a clone without it.

For repeat rounds, `collect --prior-rejections FILE` accepts a JSON list of
`{title,file,reason}` objects; `file` may be empty when unknown. It copies and seals
the list, then reminds every reviewer not to re-raise rejected findings without
new execution evidence. The prompt includes at most 20 entries and 4096 characters
of sanitized rejection text. Omit the flag to preserve existing prompts.

Sealed collection supports main checkouts and linked worktrees. Before legs launch it
pins the root `.git` directory or gitfile, resolved Git/common directories and their
identities, any existing `commondir` bytes (or absence), and the common config.
Resolution changes fail closed before Git runs; changed resolution files are restored.
Only `branch.*` config changes are accepted; other changes name the keys and restore
config bytes and mode. Private `git-surface/` snapshots in the collection let verification
and finalization enforce the same pins. Older surface manifests require recollection.
DeepSeek succeeds only when dsh exits 0, the final `turn_end` reason is `completed`,
and the last `final` event contains a valid review. Missing credentials, invalid models,
timeouts, and incomplete turns produce named failures; rate limits and quota failures
use the `plan limit:` prefix to trigger the existing backup policy.
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

When the verdict comes back `NEEDS_WORK` or `BLOCK`, the `closing-tribunal-loop` skill guides the iterative close-out: per-finding triage (fix-in-PR vs file-follow-up vs reject), committing fixes one finding at a time, and re-running the tribunal until the arbiter returns a verdict with **zero critical and high findings** on the latest diff (see Convergence governor below). **Close-out is PR-only** — an open GitHub PR is required, and **each round is documented as a PR comment** (`<!-- tribunal-round:N -->` marker, verdict, dispositions, HEAD sha).

## Convergence governor

The closing loop is **capped and severity-honest** so it cannot spiral:

- **PR-only trail** — every round (including the final close) is posted as a
  PR comment with dispositions, commits, and follow-ups; session chat is not
  the audit trail.
- **Blocking-finding standard** — a finding is critical/high only if it proves
  a production-reachable path, material impact, and that it is caused/exposed
  by the change under review. Otherwise it is capped at medium.
- **Stop condition** — the loop closes on **zero critical/high** (not zero
  findings). Leftover medium/low go to YAGNI triage (filed only if real and
  worth acting on; else dropped in the closing round PR comment).
- **Frozen scope** — the original outcome, acceptance checks, invariants, and
  exclusions govern every round; reviewer findings do not redefine the task.
- **Step-back at round 3** — stop adding guards; simplify, descope, or
  down-rate the finding *class*. A step-back round may not increase the net
  count of defensive mechanisms.
- **Bounded retry** — keep looping while any critical/high remains;
  checkpoint at round 3; hard escalation at round 5 (both as PR comments).
- **`reachability.md`** — an optional per-repo file (worker model, concurrency,
  single-user assumptions, money paths) injected into reviewers + arbiter as
  rebuttable context.

## Configuration

The reviewer settings and optional caller identity are configurable via environment variables (export
them before launching the host). The default panel is **Codex + Grok + Muse + Claude**; Gemini, DeepSeek,
and Qwen stay **off** until you opt in.
DeepSeek uses the direct DeepSeek API and walks the repository with a read-only sandbox. The sandbox restricts writes; reads remain within the development-container security boundary. For projects with data-residency constraints, enabling this leg is the operator's decision.

| Variable | Default | Effect |
|---|---|---|
| `TRIBUNAL_BASE_BRANCH` | resolved default branch | Override the default branch name used to build `origin/<branch>` when reviewing. Normally unnecessary; Codex resolves GitHub default branch, `git remote show origin`, then `origin/HEAD`. |
| `TRIBUNAL_BASE_REF` | `origin/<resolved-default>` | Override the exact base ref used for `git diff "$BASE_REF"...HEAD`. Use this for unusual remotes or review bases. |
| `TRIBUNAL_CODEX` | `on` | Set to `off` to skip the Codex leg. The run degrades to the remaining quorum; the arbiter reports Codex as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_CODEX_MODEL` | `gpt-6-astra` | Model passed explicitly to `codex exec -m`. An environment value overrides this default. |
| `TRIBUNAL_CODEX_EFFORT` | `medium`, or the `TRIBUNAL_RISK` effort | Reasoning effort passed explicitly through `model_reasoning_effort`. An environment value overrides this default. The Codex leg forces isolated user configuration and always passes `--dangerously-bypass-approvals-and-sandbox`; the development container is the security boundary. |
| `TRIBUNAL_GEMINI` | `off` | Set to `on` to enable the Gemini leg (web/CVE search). **Off by default**; when off the arbiter reports Gemini as `disabled`, not failed. Only the literal `on` enables. |
| `TRIBUNAL_GEMINI_MODEL` | agy default | Model passed to `agy --model` (see `agy models`). Point it at a faster/cheaper slot to keep a full quorum while controlling latency/cost. |
| `TRIBUNAL_DEEPSEEK` | `off` | Set to `on` to enable the DeepSeek leg. **Off by default** (issue [#461](https://github.com/paat/claude-plugins/issues/461)); when off the arbiter reports DeepSeek as `disabled`, not failed. Only the literal `on` enables. |
| `TRIBUNAL_DEEPSEEK_MODEL` | `deepseek-v4-pro` | Model in the dsh `agent-default-model` overlay row; provider stays `deepseek-official`. |
| `DEEPSEEK_API_KEY` | _(unset)_ | DeepSeek direct-API credential; dsh also resolves it from `${DSH_HOME:-$HOME/.dsh}/.credentials.yaml` (`refs.DEEPSEEK_API_KEY`) or `${DSH_HOME:-$HOME/.dsh}/.env`. The wrapper never reads or copies the key. |
| `TRIBUNAL_QWEN` | `off` | Set to `on` to enable the Qwen leg. **Off by default** — a real-world audit found it reasons over the diff text rather than grounding in files, emitting repeated false positives (phantom whitespace, nonexistent symbols/SQL, hallucinated line numbers; [issue #46](https://github.com/paat/claude-plugins/issues/46)); disabled pending the mandatory-verification fix. When off the arbiter reports Qwen as `disabled`, not failed. Only the literal `on` enables. |
| `TRIBUNAL_QWEN_MODEL` | `qwen3.8-max` | Model passed to `qwen --model` (Qwen3.8 flagship, validated on DashScope Intl). With OpenAI-compatible auth, qwen-code runs only ids listed under `modelProviders.openai` in `~/.qwen/settings.json`, so add `qwen3.8-max` there first. Qwen ids change often through 2026 **and vary by account/region**; qwen-code **silently downgrades an unknown id to its default with no error** (the leg surfaces the model that actually ran in its output `model` field and warns on stderr when it differs from the requested id). Override with a valid id for your account — e.g. `qwen3.6-plus` for a 1M-context window, or a coder slot like `qwen3-coder-plus` if your account enables it. |
| `DASHSCOPE_API_KEY` | _(unset)_ | Qwen DashScope credential (primary transport). The Qwen Code CLI also accepts `OPENAI_API_KEY`+`OPENAI_BASE_URL` (OpenAI-compatible) or `OPENROUTER_API_KEY` (`qwen/...` ids), or a credential stored via `~/.qwen/settings.json`. |
| `TRIBUNAL_GROK` | `on` | Set to `off` to skip the Grok leg (xAI Grok CLI; repo-walking with tools allowlist; sandbox default `none` + `bypassPermissions` — issue #378; host config isolated with durable OIDC auth copy/write-back — issue #374; inspect→tools-off finalize resume for deterministic completion — issue #331). **On by default**; when off the arbiter reports Grok as `disabled`, not failed. Only the literal `off` disables. Autonomous Max/OAuth users need a live `grok login` session (refresh token), not re-login every round. |
| `TRIBUNAL_GROK_EFFORT` | the `TRIBUNAL_RISK` effort, else CLI default | Inspect-phase Grok `--reasoning-effort` (`low`, `medium`, `high`, `xhigh`). Tools-off finalize always uses `low` to finish from the diff and session evidence within its shorter budget; high-effort reasoning can exhaust both timeouts (#661). |
| `TRIBUNAL_GROK_MODEL` | `grok-4.7` | Model passed to `grok --model`. The leg surfaces the model that actually ran (from the CLI's `.modelUsage`) in its output `model` field. |
| `TRIBUNAL_GROK_SANDBOX` | `none` | Grok CLI `--sandbox` profile. Defaults to `none` (development container is the boundary). Set `read-only` on hosts with working unprivileged user namespaces. Also honors `GROK_SANDBOX` when this variable is unset. |
| `TRIBUNAL_LEG_ENV` | empty | Space-separated variable names (or `PREFIX*` patterns) passed into the scrubbed Qwen/DeepSeek leg environment, e.g. a custom proxy or auth variable. |
| `TRIBUNAL_ALLOW_ENV_FILES` | `0` | `1` lets repo-walking legs walk a checkout that holds untracked `.env*` files instead of a scratch clone of HEAD. |
| `TRIBUNAL_GROK_PERMISSION_MODE` | `bypassPermissions` | Grok CLI `--permission-mode`. `dontAsk` cancels multi-turn inspect in practice (issue #378). |
| `TRIBUNAL_GROK_TIMEOUT_SECONDS` | `600` | Inspect-phase wall timeout (seconds) before tools-off finalize resume when recovery is `permit`. |
| `TRIBUNAL_GROK_RECOVERY` | `permit` | `permit` allows tools-off finalize recovery; `reject` excludes recovery from quorum. Sealed at collect. |
| `TRIBUNAL_GROK_FINALIZE_TIMEOUT_SECONDS` | `120` | Finalize-phase wall timeout after resume with tools disabled. |
| `TRIBUNAL_GROK_MAX_TURNS` | `8` at T3; otherwise `30` | Inspect-phase `--max-turns` budget; explicit values override the risk-tier default. |
| `TRIBUNAL_GROK_FINALIZE_MAX_TURNS` | `6` | Finalize-phase `--max-turns` budget. |
| `TRIBUNAL_MUSE` | `on` | Set to `off` to skip the Muse leg. When off the arbiter reports Muse as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_MUSE_MODEL` | `muse-spark-1.3` | Model passed to `muse exec --model`. Unset requests `muse-spark-1.3`. `default` passes no `--model` and accepts the model the CLI configures (a `-contributor` id may let Meta use the content for product improvement). Any other id fails when the run configured a different model. The leg reports the configured model in its output `model` field. |
| `TRIBUNAL_MUSE_EFFORT` | the `TRIBUNAL_RISK` effort, else CLI default | Muse `--reasoning-effort` (`minimal` through `max`). |
| `TRIBUNAL_MUSE_TIMEOUT_SECONDS` | `600` | Wall timeout (30..1800). |
| `TRIBUNAL_MUSE_MAX_STEPS` | `40` | `--max-model-steps` budget (1..80). |
| `TRIBUNAL_CLAUDE` | `on` | Set to `off` to skip the Claude diff-only leg. **On by default**; when off the arbiter reports Claude as `disabled`, not failed. Only the literal `off` disables. |
| `TRIBUNAL_CLAUDE_MODEL` | `sonnet` | Model passed to `claude -p --model` for the diff-only leg. Accepts an alias (`sonnet`, `haiku`, `opus`) or a full id (e.g. `claude-sonnet-5-5`). |
| `TRIBUNAL_CLAUDE_EFFORT` | the `TRIBUNAL_RISK` effort, else CLI default | Claude `--effort` for the diff-only leg; never passed to a Haiku model. |
| `TRIBUNAL_SMOKE_PROBE` | `off` | Set to `on` to make preflight verify the actual non-interactive Codex, Claude, and enabled DeepSeek transports with minimal structured responses. Each probe is a real provider request; a failed probe removes that leg from usable quorum. |
| `TRIBUNAL_MIN_OK_LEGS` | `1` | Per-environment APPROVE floor: at least this many provider legs must seal as `ok` before `APPROVE` is valid (integer 1..7; unset/empty ⇒ 1). Set on the container/host only — never read from the repository under review. A documented lower value is the environment's degraded quorum. Membership still uses the `TRIBUNAL_<PROVIDER>` toggles. |
| `TRIBUNAL_RISK` | _(unset)_ | PR risk tier `T1`–`T4` (multi-model-orchestrator's complexity tier). Sets reviewer effort: T1 `low`, T2 `medium`, T3 `high` (Grok `medium`), T4 `high` with Codex at `xhigh`. DeepSeek maps T1 to `low` and T2–T4 to `high`; unset uses `high`. Unset keeps other CLI defaults (Codex `medium`). Environment only; the per-provider `*_EFFORT` variables win. An invalid value fails preflight and collection. |
| `TRIBUNAL_BACKUP_LEGS` | `deepseek` | Comma-separated opt-in legs (`deepseek`, `gemini`, `qwen`) or `off`. When a leg fails on a plan limit (402, usage limit, quota, or balance exhausted), the evidence collector runs one installed backup leg that sat out the run in its place; the limited leg stays `failed` in the manifest. Environment only. |
| `TRIBUNAL_SMOKE_TIMEOUT_SECONDS` | `60` | Per-provider timeout for the opt-in smoke probe; accepted range is 5–300 seconds. |
| `TRIBUNAL_DIAGNOSTIC_TAILS` | `off` | Set to `on` only for local troubleshooting to include printable-ASCII 2 KiB stdout/stderr tails in failed provider artifacts. DeepSeek always omits tails to avoid exposing credentials. Phase, exit code, byte counts, and truncation remain available when tails are omitted. Tails may contain sensitive provider output. |
| `TRIBUNAL_SCOPE_LENS` | `off` | Set to `on` to add the minimal-diff scope-control lens. The arbiter reports unrelated file changes, opportunistic refactors, unnecessary abstractions, and unrelated churn in a separate `scope_findings` section. |
| `TRIBUNAL_CALLER_PROVIDER` | _(unset)_ | Optional informational identity for the inline calling context. It does not select or spawn an arbiter. |
| `TRIBUNAL_CALLER_MODEL` | _(unset)_ | Optional caller model metadata. Standalone runs may leave it unset. |
| `TRIBUNAL_CALLER_EFFORT` | _(unset)_ | Optional caller effort metadata. Standalone runs may leave it unset. |

```bash
export TRIBUNAL_GEMINI=on                           # add the opt-in Gemini leg (web/CVE search)
export TRIBUNAL_DEEPSEEK=on  # add the opt-in DeepSeek leg on the direct API
export TRIBUNAL_QWEN=on                              # add the opt-in Qwen leg (see issue #46)
export DASHSCOPE_API_KEY=sk-...                     # Qwen auth (needed when TRIBUNAL_QWEN=on)
export TRIBUNAL_GROK=off                             # skip the default-on Grok leg
export TRIBUNAL_SCOPE_LENS=on                       # add minimal-diff scope-control findings
```

### Minimal-diff scope lens

Enable `TRIBUNAL_SCOPE_LENS=on` for bug fixes, hotfixes, incident patches, and plan-driven Codex implementation where reviewability matters. The lens is not a style/nit reviewer. It flags changed files or hunks that do not appear required by the named task, unrelated refactors, new abstractions before repeated call sites exist, defensive branches for impossible internal states, rename/reformat/import churn, and tests that assert unrelated implementation details.

Scope findings are reported separately from correctness/security findings. `must-remove-before-merge` scope findings make the verdict at least `NEEDS_WORK`; `follow-up-only` findings document cleanup without blocking approval.

These knobs apply everywhere. Each standalone reviewer agent is a thin wrapper over
its `scripts/run-*.sh` runner, so it honors the same enable/disable switches.
Gemini, DeepSeek, and Qwen emit a `disabled` marker unless their
`TRIBUNAL_<PROVIDER>` setting is `on`.

## How It Works

### Step 1: Pre-flight
Verifies you're on a feature branch (not the resolved default branch) and that there are changes to review against `origin/<default>`, then runs `scripts/preflight.sh`. The default branch is resolved from GitHub first, then `git remote show origin`, then `origin/HEAD`, with `TRIBUNAL_BASE_BRANCH` / `TRIBUNAL_BASE_REF` as overrides. Preflight checks each enabled reviewer leg and free disk space. DeepSeek needs `dsh` on PATH and a configured API key. With `TRIBUNAL_SMOKE_PROBE=on`, it also exercises the real non-interactive default transports using minimal structured responses. Problems are reported up front so a missing CLI, full disk, missing credential, or immediately broken transport fails fast here instead of hanging a launched reviewer; affected reviewers are marked skipped/failed and the run degrades to the available quorum. Preflight stops when zero reviewer legs are usable, or when fewer are usable than `TRIBUNAL_MIN_OK_LEGS`.

### Step 2: Parallel Review
Runs Codex, Gemini, DeepSeek, Qwen, Grok, Muse, and Claude as **seven parallel Bash calls** through their `scripts/run-<provider>-review.sh` runners. By default only Codex, Grok, Muse, and Claude review; Gemini, DeepSeek, and Qwen emit disabled markers unless enabled. Codex, Grok, Muse, DeepSeek, and Qwen walk the repo with the controls described above. Claude is the default panel's diff-only reviewer, launched from a scratch directory with all tools disabled; Gemini adds the opt-in diff and web/CVE lens.

DeepSeek runs `dsh --profile headless --patch <overlay> --json -` from the review checkout, with the prompt on stdin and a scrubbed environment. The committed overlay enforces a read-only sandbox and `approval: never`, disables the permission plugin, session-log uploads, telemetry, and web tools, and sets the model and effort. The wrapper generates a per-run overlay outside the checkout for model overrides. The review prompt carries the JSON contract because dsh has no JSON-schema flag; the wrapper validates the final review and stamps `diff_stat` through the shared emitter.

**Credential exposure.** Repo-walking legs (Codex, Grok, Muse, DeepSeek, Qwen) run as the operator's uid with network egress and can read any file that uid can read, including provider credentials such as `~/.dsh/.env`, `~/.codex/auth.json`, and Qwen Code credentials (settings in `~/.qwen/settings.json`, or DashScope, OpenAI, or OpenRouter keys); a prompt-injected diff could try to exfiltrate them. For repositories that review untrusted PR diffs, give the legs dedicated, low-limit review keys.

Each reviewer analyzes `git diff "$BASE_REF"...HEAD`, where `BASE_REF` defaults to the resolved `origin/<default>` branch, and returns structured findings covering logic, security, edge cases, performance, architecture, and meaningful DRY violations. If present, `AGENTS.md` is injected into each reviewer's prompt (capped at 16KB) as shared project conventions.

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
    "deepseek": { "findings_accepted": 1, "findings_rejected": 1, "false_positives": [], "status": "ok" },
    "qwen":     { "findings_accepted": 1, "findings_rejected": 0, "false_positives": [], "status": "ok" },
    "grok":     { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok" },
    "muse":     { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok" },
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
Codex · Gemini · DeepSeek · Qwen · Grok · Muse · Claude (equal advisory peers — verify findings)
```

The reviewers are equal peers (up to seven; by default Codex + Grok + Muse + Claude, with Gemini, DeepSeek, and Qwen opt-in); a finding flagged by ≥2 is CONSENSUS. The calling context can override a reviewer finding, but must weigh claims on evidence rather than provider identity.

Each review-shaped leg carries a `diff_stat` (`files_changed`, `insertions`,
`deletions`, `base`, `base_oid`, `head_oid`, `truncated`) stamped by the runner
script, not by the provider. A leg missing it did not come from a runner and is
counted as a provider failure regardless of its verdict, so a fabricated clean
pass cannot satisfy a merge gate. Every review-shaped leg also lists
`files_examined`, and an empty-findings APPROVE that names no path changed in
the reviewed range is counted as a provider failure (a truly empty range is
exempt). For every non-empty range, with or without findings, each examined
path must exist in the pinned `base_oid`, `head_oid`, or their merge-base tree
after stripping leading `./` segments. Deleted paths present only at the
merge-base and head-only added paths are valid. `.` and paths through a
symlinked directory are not tree entries and are rejected. An absent path or
an unavailable pinned tree produces a named provider failure excluded from
quorum, with no worktree fallback (issue #671). This checks existence, not
whether a file was read or a conclusion is sound.
For sealed PR evidence,
`collect-review-evidence.sh` additionally requires the stamped `base_oid` and
`head_oid` to be the collection's own — a well-formed leg for another revision
seals as `failed`, not `ok`.

## License

MIT
