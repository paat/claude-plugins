# tribunal-review

Multi-provider code review plugin for Claude Code and Codex. **By default** it selects **3 distinct available reviewer legs** (`TRIBUNAL_PANEL_SIZE`, default `3`) for the PR risk tier (`TRIBUNAL_RISK`: `T1`–`T4`, default `T2`) from `scripts/review-panel.tsv` — e.g. at `T2`, **Codex** (`gpt-6.1-sol` at `medium` effort), **Claude** (`claude-sonnet-5-5` at `medium`), and **OpenCode Go** (`opencode-go/glm-5.3#high` via OpenCode v2), falling back in table order through **Grok** (`grok-4.7`), **Muse** (`muse-spark-1.3`), **DeepSeek V4 Pro** (`dsh`), **Gemini** (`agy`, web/CVE search), and **Qwen** (`qwen3.8-max`). At least **2 `ok` legs** (`TRIBUNAL_MIN_OK_LEGS`, default `2`, range `2..8`) are required for `APPROVE`. Set `TRIBUNAL_<PROVIDER>=on|off` to force a leg in or out, and `TRIBUNAL_<PROVIDER>_MODEL` / `TRIBUNAL_<PROVIDER>_EFFORT` to override its selected row. Codex, OpenCode, Grok, Muse, DeepSeek, and Qwen **walk the repo**: Codex runs inside the development-container security boundary while its review prompt prohibits file changes; OpenCode v2 runs `--agent plan` (edit tool denied); Grok walks under a read-only tools allowlist with host config isolated (web search off, `--sandbox none` by default — issue #378; opt in with `TRIBUNAL_GROK_SANDBOX=read-only`); Muse walks with write and shell tools disabled; DeepSeek walks under `dsh`'s read-only sandbox. **Claude** and **Gemini** are **diff-only** lenses. When the checkout holds untracked `.env*` files outside ignored directories, every repo-walking leg walks a scratch clone of the reviewed HEAD instead, and shell-capable OpenCode, Muse, Qwen, and DeepSeek legs start with a scrubbed environment (issue [#589](https://github.com/paat/claude-plugins/issues/589)).

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
- [Muse Code CLI](https://meta.ai) (`muse`) — **optional**, for the Muse leg (`muse exec --yolo` with `--disable-write --disable-shell --disable-web-tools` and `--output-schema`; default `muse-spark-1.3`; `TRIBUNAL_MUSE_MODEL=default` passes no `--model`, where a `-contributor` id may use content for product improvement; auth via `muse login` or `META_API_KEY`).
- [OpenCode CLI v2+](https://opencode.ai) (`opencode`, `opencode --version` major >= 2) — **optional**, for the **OpenCode Go** leg (`opencode run --standalone --format json --agent plan -m "opencode-go/<model>[#<effort>]"`). OpenCode v1 is refused.
- [Claude Code CLI](https://docs.claude.com/claude-code) (`claude`) — for the **Claude diff-only leg** (`claude -p` from a scratch directory with tools disabled).
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
them before launching the host). By default `tribunal_select_panel` picks `TRIBUNAL_PANEL_SIZE` (`3`)
available legs for `TRIBUNAL_RISK` (default `T2`) from `scripts/review-panel.tsv`, and remaining
available rows serve as backups when a leg hits a plan limit or `ok` legs fall below
`TRIBUNAL_MIN_OK_LEGS` (`2`).
DeepSeek uses the direct DeepSeek API and walks the repository with a read-only sandbox. The sandbox restricts writes; reads remain within the development-container security boundary. For projects with data-residency constraints, enabling this leg is the operator's decision.

| Variable | Default | Effect |
|---|---|---|
| `TRIBUNAL_BASE_BRANCH` | resolved default branch | Override the default branch name used to build `origin/<branch>` when reviewing. Normally unnecessary; Codex resolves GitHub default branch, `git remote show origin`, then `origin/HEAD`. |
| `TRIBUNAL_BASE_REF` | `origin/<resolved-default>` | Override the exact base ref used for `git diff "$BASE_REF"...HEAD`. Use this for unusual remotes or review bases. |
| `TRIBUNAL_RISK` | _(unset, selects `T2` rows)_ | PR risk tier `T1`–`T4` (multi-model-orchestrator complexity tier). Selects the tier's rows, models, and efforts from `scripts/review-panel.tsv` (only Codex reaches `xhigh` at `T4`). Environment only; explicit `TRIBUNAL_<PROVIDER>_MODEL` / `*_EFFORT` win. |
| `TRIBUNAL_PANEL_SIZE` | `3` | Number of reviewer legs selected from the active tier (`2..8`; forced `TRIBUNAL_<PROVIDER>=on` legs count toward seats and all run even if they exceed `TRIBUNAL_PANEL_SIZE`). Sealed in `panel_policy`. |
| `TRIBUNAL_REVIEW_PANEL` | `scripts/review-panel.tsv` | Override path for the `tier<TAB>provider<TAB>model<TAB>effort` preference table (`-` passes no effort). Environment only. |
| `TRIBUNAL_MIN_OK_LEGS` | `2` | Per-environment APPROVE floor (`2..8`; `1` is rejected because a one-leg `APPROVE` is not allowed). Environment only; sealed into `manifest.json` under `panel_policy`. |
| `TRIBUNAL_BACKUP_LEGS` | remaining available rows | Comma-separated backup leg order (any of the 8 providers) or `off`. Runs idle installed backups for `plan limit:` failures and when `ok` legs after pass 1 are below `TRIBUNAL_MIN_OK_LEGS`; original failed legs stay `failed`. |
| `TRIBUNAL_CODEX` | selected by panel (`on` standalone) | `on` forces Codex into the panel; `off` excludes it (`disabled`). |
| `TRIBUNAL_CODEX_MODEL` | tier row (`gpt-6-astra` standalone) | Model passed to `codex exec -m`; overrides the panel table row. |
| `TRIBUNAL_CODEX_EFFORT` | tier row (`medium` standalone) | Reasoning effort passed through `model_reasoning_effort`; overrides the panel table row. |
| `TRIBUNAL_OPENCODE` | selected by panel (`off` standalone) | `on` forces the OpenCode Go leg into the panel; `off` excludes it (`disabled`). Requires OpenCode v2+. |
| `TRIBUNAL_OPENCODE_MODEL` | tier row (`kimi-k3.1-pro` standalone) | OpenCode Go model id passed as `opencode-go/<model>[#<effort>]` (e.g. `glm-5.3`, `kimi-k3.1-pro`). |
| `TRIBUNAL_OPENCODE_EFFORT` | tier row (`high` standalone) | OpenCode Go variant appended after `#` (`low`, `high`, `max`, or `-` for none). |
| `TRIBUNAL_OPENCODE_TIMEOUT_SECONDS` | `900` | OpenCode wall timeout in seconds (clamped `30..1800`). |
| `TRIBUNAL_GEMINI` | selected by panel (`off` standalone) | `on` forces the Gemini (`agy`, web/CVE search) leg into the panel; `off` excludes it. |
| `TRIBUNAL_GEMINI_MODEL` | tier row (`default`) | Model passed to `agy --model` (`default` uses agy's default). |
| `TRIBUNAL_DEEPSEEK` | selected by panel (`off` standalone) | `on` forces the DeepSeek (`dsh`) leg into the panel; `off` excludes it. |
| `TRIBUNAL_DEEPSEEK_MODEL` | tier row (`deepseek-v4-pro`) | Model in the dsh `agent-default-model` overlay row; provider stays `deepseek-official`. |
| `TRIBUNAL_DEEPSEEK_EFFORT` | tier row (`low` at T1, else `high`) | Effort in the dsh `agent-default-model` overlay row. |
| `DEEPSEEK_API_KEY` | _(unset)_ | DeepSeek direct-API credential; dsh also resolves it from `${DSH_HOME:-$HOME/.dsh}/.credentials.yaml` (`refs.DEEPSEEK_API_KEY`) or `${DSH_HOME:-$HOME/.dsh}/.env`. |
| `TRIBUNAL_QWEN` | selected by panel (`off` standalone) | `on` forces the Qwen leg into the panel; `off` excludes it. |
| `TRIBUNAL_QWEN_MODEL` | tier row (`qwen3.8-max`) | Model passed to `qwen --model`. |
| `DASHSCOPE_API_KEY` | _(unset)_ | Qwen DashScope credential (also accepts OpenAI-compatible, OpenRouter, or `~/.qwen/settings.json`). |
| `TRIBUNAL_GROK` | selected by panel (`on` standalone) | `on` forces the Grok leg into the panel; `off` excludes it. |
| `TRIBUNAL_GROK_EFFORT` | tier row | Inspect-phase Grok `--reasoning-effort` (`low`, `medium`, `high`, `xhigh`); finalize always uses `low`. |
| `TRIBUNAL_GROK_MODEL` | tier row (`grok-4.7`) | Model passed to `grok --model`. |
| `TRIBUNAL_GROK_SANDBOX` | `none` | Grok CLI `--sandbox` profile (`none` or `read-only`). |
| `TRIBUNAL_LEG_ENV` | empty | Space-separated variable names (or `PREFIX*` patterns) passed into scrubbed leg environments (`opencode`, `muse`, `qwen`, `deepseek`). |
| `TRIBUNAL_ALLOW_ENV_FILES` | `0` | `1` lets repo-walking legs walk a checkout that holds untracked `.env*` files instead of a scratch clone of HEAD. |
| `TRIBUNAL_GROK_PERMISSION_MODE` | `bypassPermissions` | Grok CLI `--permission-mode`. |
| `TRIBUNAL_GROK_TIMEOUT_SECONDS` | `600` | Inspect-phase wall timeout (seconds). |
| `TRIBUNAL_GROK_RECOVERY` | `permit` | `permit` allows tools-off finalize recovery; `reject` excludes recovery from quorum. Sealed at collect. |
| `TRIBUNAL_GROK_FINALIZE_TIMEOUT_SECONDS` | `120` | Finalize-phase wall timeout after resume with tools disabled. |
| `TRIBUNAL_GROK_MAX_TURNS` | `8` at T3; otherwise `30` | Inspect-phase `--max-turns` budget. |
| `TRIBUNAL_GROK_FINALIZE_MAX_TURNS` | `6` | Finalize-phase `--max-turns` budget. |
| `TRIBUNAL_MUSE` | selected by panel (`on` standalone) | `on` forces the Muse leg into the panel; `off` excludes it. |
| `TRIBUNAL_MUSE_MODEL` | tier row (`muse-spark-1.3`) | Model passed to `muse exec --model` (`default` passes no `--model`). |
| `TRIBUNAL_MUSE_EFFORT` | tier row | Muse `--reasoning-effort` (`minimal` through `max`). |
| `TRIBUNAL_MUSE_TIMEOUT_SECONDS` | `600` | Muse wall timeout (`30..1800`). |
| `TRIBUNAL_MUSE_MAX_STEPS` | `40` | Muse `--max-model-steps` budget (`1..80`). |
| `TRIBUNAL_CLAUDE` | selected by panel (`on` standalone) | `on` forces the Claude diff-only leg into the panel; `off` excludes it. |
| `TRIBUNAL_CLAUDE_MODEL` | tier row (`sonnet` standalone) | Model passed to `claude -p --model` (alias or full id such as `claude-sonnet-5-5` or `claude-opus-5-5`). |
| `TRIBUNAL_CLAUDE_EFFORT` | tier row | Claude `--effort` for the diff-only leg; never passed to a Haiku model. |
| `TRIBUNAL_SMOKE_PROBE` | `off` | Set to `on` to make preflight probe usable selected Codex, Claude, OpenCode, and DeepSeek transports with minimal structured responses. |
| `TRIBUNAL_SMOKE_TIMEOUT_SECONDS` | `60` | Per-provider timeout for the opt-in smoke probe; accepted range is 5–300 seconds. |
| `TRIBUNAL_DIAGNOSTIC_TAILS` | `off` | Set to `on` only for local troubleshooting to include printable-ASCII 2 KiB stdout/stderr tails in failed provider artifacts (DeepSeek always omits tails). |
| `TRIBUNAL_SCOPE_LENS` | `off` | Set to `on` to add the minimal-diff scope-control lens (`scope_findings`). |
| `TRIBUNAL_CALLER_PROVIDER` | _(unset)_ | Optional informational identity for the inline calling context. |
| `TRIBUNAL_CALLER_MODEL` | _(unset)_ | Optional caller model metadata. |
| `TRIBUNAL_CALLER_EFFORT` | _(unset)_ | Optional caller effort metadata. |

```bash
export TRIBUNAL_RISK=T3                              # select T3 panel rows and efforts
export TRIBUNAL_PANEL_SIZE=3                         # default: 3 distinct legs
export TRIBUNAL_CODEX=off                            # exclude Codex; next available row fills its seat
export TRIBUNAL_GEMINI=on                            # force Gemini into the panel
export TRIBUNAL_SCOPE_LENS=on                        # add minimal-diff scope-control findings
```

### Minimal-diff scope lens

Enable `TRIBUNAL_SCOPE_LENS=on` for bug fixes, hotfixes, incident patches, and plan-driven Codex implementation where reviewability matters. The lens is not a style/nit reviewer. It flags changed files or hunks that do not appear required by the named task, unrelated refactors, new abstractions before repeated call sites exist, defensive branches for impossible internal states, rename/reformat/import churn, and tests that assert unrelated implementation details.

Scope findings are reported separately from correctness/security findings. `must-remove-before-merge` scope findings make the verdict at least `NEEDS_WORK`; `follow-up-only` findings document cleanup without blocking approval.

These knobs apply everywhere. Each standalone reviewer agent is a thin wrapper over
its `scripts/run-*.sh` runner, so it honors the same `TRIBUNAL_<PROVIDER>` switches
(OpenCode, Gemini, DeepSeek, and Qwen emit a `disabled` marker when invoked standalone
without `TRIBUNAL_<PROVIDER>=on`).

## How It Works

### Step 1: Pre-flight
Verifies you're on a feature branch (not the resolved default branch) and that there are changes to review against `origin/<default>`, then runs `scripts/preflight.sh`. The default branch is resolved from GitHub first, then `git remote show origin`, then `origin/HEAD`, with `TRIBUNAL_BASE_BRANCH` / `TRIBUNAL_BASE_REF` as overrides. Preflight checks each enabled reviewer leg and free disk space. DeepSeek needs `dsh` on PATH and a configured API key. With `TRIBUNAL_SMOKE_PROBE=on`, it also exercises the real non-interactive default transports using minimal structured responses. Problems are reported up front so a missing CLI, full disk, missing credential, or immediately broken transport fails fast here instead of hanging a launched reviewer; affected reviewers are marked skipped/failed and the run degrades to the available quorum. Preflight stops when zero reviewer legs are usable, or when fewer are usable than `TRIBUNAL_MIN_OK_LEGS`.

### Step 2: Parallel Review
Selects the active panel via `tribunal_select_panel` (`scripts/review-panel.tsv`) and runs Codex, Gemini, DeepSeek, Qwen, Grok, Muse, OpenCode, and Claude as **eight parallel Bash calls** through their `scripts/run-<provider>-review.sh` runners. Unselected legs emit `disabled` markers. Codex, OpenCode, Grok, Muse, DeepSeek, and Qwen walk the repo with the controls described above; Claude and Gemini are diff-only lenses.

DeepSeek runs `dsh --profile headless --patch <overlay> --json -` from the review checkout, with the prompt on stdin and a scrubbed environment. The committed overlay enforces a read-only sandbox and `approval: never`, disables the permission plugin, session-log uploads, telemetry, and web tools, and sets the model and effort. The wrapper generates a per-run overlay outside the checkout for model overrides. The review prompt carries the JSON contract because dsh has no JSON-schema flag; the wrapper validates the final review and stamps `diff_stat` through the shared emitter.

**Credential exposure.** Repo-walking legs (Codex, OpenCode, Grok, Muse, DeepSeek, Qwen) run as the operator's uid with network egress and can read any file that uid can read, including provider credentials such as `~/.dsh/.env`, `~/.codex/auth.json`, and Qwen Code credentials (settings in `~/.qwen/settings.json`, or DashScope, OpenAI, or OpenRouter keys); a prompt-injected diff could try to exfiltrate them. For repositories that review untrusted PR diffs, give the legs dedicated, low-limit review keys.

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
    "grok":     { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "disabled" },
    "muse":     { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "disabled" },
    "opencode": { "findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok" },
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
Codex · Gemini · DeepSeek · Qwen · Grok · Muse · OpenCode · Claude (equal advisory peers — verify findings)
```

The reviewers are equal peers (eight supported providers; 3 selected by default per tier from `scripts/review-panel.tsv`, with at least 2 `ok` legs required for `APPROVE`); a finding flagged by ≥2 is CONSENSUS. The calling context can override a reviewer finding, but must weigh claims on evidence rather than provider identity.

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
