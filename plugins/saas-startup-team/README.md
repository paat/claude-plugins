# saas-startup-team

A SaaS startup orchestration plugin for Claude Code and Codex. A non-technical business co-founder and a technical developer co-founder iterate via file-based handoffs until both agree the product is ready to go live.

## Mission Fit

`saas-startup-team` is the core mission plugin. It owns the demand -> requirements ->
implementation -> browser QA -> go-live -> growth -> operations -> maintenance loop for
generic SaaS projects, with Estonian SaaS context available where relevant.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install saas-startup-team@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in `.claude/settings.local.json`.

## Codex Compatibility

Codex installs expose the command workflows as plugin-bundled skills, so `/startup`,
`/growth`, `/improve`, `/lawyer`, `/ux-test`, `/status`, and the other command-style flows
travel with the plugin. No user-local `~/.codex/prompts` wrappers are required.

In Codex, implementation is Codex-only:

- Do not install or switch to Claude Code for the startup workflow.
- Do not invoke `claude`, `claude-code`, TeamCreate, or Claude subagent workflows.
- Run business-founder, tech-founder, growth-hacker, lawyer, UX tester, and review work as Codex role phases backed by `.startup/` files.
- Use Codex skills or direct Codex sequencing in the current session. Separate workers
  go through `scripts/codex-run-role.sh` with an explicit role and semantic profile.

The shared hook bundle intentionally contains only Codex-supported lifecycle keys:
`PreToolUse`, `PostToolUse`, and `Stop`. Handoff and task-completion checks that used to
depend on Claude-only `TeammateIdle` / `TaskCompleted` events are enforced as explicit
workflow gates in the Codex orchestration skill.

## How It Works

The human user is a **silent investor** — they describe a SaaS idea and watch two AI co-founders build it:

- **Business Founder** (blue): Does all real-world research (web, Reddit, browser). Defines requirements, verifies implementations via browser. Speaks Estonian to the investor, English to the developer.
- **Tech Founder** (green): Pure builder. No web access — relies only on LLM training knowledge and the business founder's handoff documents. Stops and asks when the "why" is unclear.
- **Lawyer** (magenta): On-demand legal consultant. Reviews compliance, GDPR, contracts, and Estonian business law. Invoked via `/lawyer`.
- **UX Tester** (cyan): On-demand usability auditor. Runs browser-based accessibility and UX audits against live pages. Invoked via `/ux-test`.

The founders iterate through structured file-based handoffs until the business founder declares the product ready for customers.

### Lean direct-feature planning

Concrete architecture and implementation requests apply the shared delivery scope before
research expansion: one targeted repository pass, repository-conventional defaults, and
specialist input only for an evidence gap that can materially change `Done`. New products
and major pivots retain the full founder research loop. The lean path preserves all
triggered production, privacy, correctness, regression, and deployment gates.

## Architecture

```
Human (Silent Investor)
  ↓ describes SaaS idea
  ↓ /saas-startup-team:startup
Team Lead (Orchestrator)
  ├── Business Founder (role phase, web + browser research)
  ├── Tech Founder (role phase, code tools)
  ├── Shared state.json
  └── File-based handoffs in .startup/
```

## Commands

| Command | Purpose |
|---------|---------|
| `/saas-startup-team:startup` | Initialize project, start founder role phases, start the loop |
| `/saas-startup-team:status` | Show iteration count, handoff history, human tasks |
| `/saas-startup-team:nudge` | Unstick a deadlock or redirect a founder |
| `/saas-startup-team:lawyer` | Spawn lawyer agent for legal/compliance review |
| `/saas-startup-team:ux-test` | Spawn UX tester for accessibility and usability audit |
| `/saas-startup-team:improve` | One-shot improvements on a completed product |
| `/saas-startup-team:operate` | Post-launch operations entry point. Routes live monitoring, incident investigation, abandoned-session replay, and support triage from the shared `operate:` config block. |
| `/saas-startup-team:monitor` | On-demand operations report using the existing `monitor:` engine plus configured `operate:` sources. Read-only unless `--file-issues` is passed. |
| `/saas-startup-team:harvest` | Internal evidence harvester for self-improvement and market-need candidates. `--events` uses the authoritative root-terminal projection; harvesting stays local, while public filing remains separately repo-pinned and gated. |
| `/saas-startup-team:market-scout` | External market-demand scout. Converts configured public evidence, source links, and dates into ranked SaaS improvement candidates; falls back to internal demand discovery when browsing/source data is unavailable. |
| `/saas-startup-team:investigate` | Investigate a correlation ID or recent sessions, write redacted RCA artifacts, and file/update a deduplicated GitHub issue by default. |
| `/saas-startup-team:replay-abandoned` | Replay configured abandoned funnel sessions via browser tooling, emit structured findings, and file actionable findings by default. |
| `/saas-startup-team:goal-deliver` | Deliver a set of tasks (issues, milestone, spec, or free text) end-to-end: plan into chunks, ship each via `/improve` + closing tribunal loop + merge to main, then monitor and fix the GitHub Actions deploy. Pairs with built-in `/goal` for autonomy. Requires the `tribunal-review` plugin. |
| `/saas-startup-team:ads` | Design a Google Ads campaign — spawns the `google-ads-strategist` plugin's `ads-strategist` (hard dependency) to design, browser-verify, and create the campaign in PAUSED state for investor review. The `/growth` loop also delegates here automatically. |
| `/saas-startup-team:maintain` | Scheduled autonomous maintenance pass: triage open issues, fence human-gated ones into `human-tasks.md`, and deliver the rest to production via inline `/goal-deliver`, one-at-a-time in dependency order. An external scheduler owns repetition and backoff. Flags: `--once`, `--dry-run`, `--max-issues`, `--max-merges`, `--max-pass-minutes`, `--max-run-minutes`. Requires the `tribunal-review` plugin. |
| `/saas-startup-team:maintain-loop` | Thin sequential coordinator: model-free probe, then one fresh `/maintain --once` subagent per bounded pass. The caller retains only compact outcomes and never loads issue or delivery context. Codex invocation: `$saas-startup-team:maintain-loop`. Accepts `/maintain` limits plus outer `--once`. |
| `/saas-startup-team:lessons-review` | Optional manual inspection/override for the lesson queue: list candidates, approve, close, or quarantine a verified issue. Normal review is automatic through `lesson-auto-review.sh`. |
| `/saas-startup-team:lessons-deliver` | Autonomously implements automatically approved `lesson-approved` issues end-to-end (claim → implement → diff firewall → tribunal → test suite → dual version bump → PR `Closes #N` → merge on green). Plugin-native (not `/goal-deliver`). Flags: `--once`, `--dry-run`, `--max-issues`, `--max-merges`, `--max-pass-minutes`, `--max-run-minutes`, `--repo`. Requires the `tribunal-review` plugin. |

## Agents

| Agent | Purpose |
|-------|---------|
| `browser-operator` | Haiku-powered mechanical browser driver; executes judgment-free legs (navigate, auth, fill, resize, extract) for the QA orchestrators and returns raw state only — never a verdict. |
| `browser-operator-pro` | Sonnet variant of `browser-operator` for mechanically fiddly legs (multi-page wizards, ambiguous page snapshots); same raw-state-only contract — the orchestrator, not the operator, makes every QA judgment. |
| `business-founder` | Business context research and browser-based requirement validation. |
| `tech-founder` | Implementation from handoff documents. |
| `growth-hacker` | Growth and sales strategy. |
| `lawyer` | Legal compliance review. |
| `ux-tester` | Accessibility and usability audit. |
| `maintain-triage` | Low-cost, read-only GitHub issue classification for `/maintain`. |

### Legal verdict rigor

Every `docs/legal/õiguslik-*.md` analysis carries YAML verdict frontmatter (`verdict`, `evidence_tier`, `blocking_human_tasks`) per the Evidence-Tier Policy in `skills/lawyer/SKILL.md` — `CONFIRMED` requires a verbatim Tier A (Riigi Teataja/EUR-Lex) quote; corpus silence is `UNVERIFIABLE-IN-CORPUS`, never proof a claim is wrong.

- **`scripts/legal-verdict-gate.sh`** — mechanically parses that frontmatter and flags a doc as hedged whenever `verdict != CONFIRMED` or `blocking_human_tasks` is non-empty. Wired into `/improve`, `/startup`, and `templates/merge-policy.md`; `--enforce` exits 2 on any hedged doc.
- **Future-effective-date watch** — the law registry's `expected_effective_date` field lets `scripts/lawyer-check.sh` poll Riigi Teataja's `blob-html` endpoint directly for not-yet-in-force acts and flag a postponement the `/changes/feed` doesn't itself surface, re-baselining so the same change isn't re-flagged after ack.

### Dual-Surface Note

Claude Code supports bounded nested browser operators: founder/UX agents may delegate
mechanical browser legs to Haiku/Sonnet operators while retaining every judgment and
verdict. Codex keeps the equivalent browser flow flattened in its current role phase.
Per-agent `model:`/`effort:` frontmatter is Claude-Code-only; Codex launchers pin their
own model and effort explicitly.

### Model routing

Judgment seats run on the frontier tier, execution volume on cheaper tiers — spec quality up, token burn down:

| Seat | Model / effort |
|------|----------------|
| Business founder (spec, QA verdicts) | Claude Fable 5, `effort: high` |
| Tech founder — Claude engine (architecture, frontend, surgical edits; architect pass) | Opus, `effort: xhigh` |
| Tech founder — Codex engine (standard/deep implementation) | GPT-5.6 Sol, `high` |
| UX tester, incident investigator | Sonnet, `effort: high` |
| Session replay, browser-operator-pro | Sonnet, `effort: low` |
| Browser operator, support triage, maintain triage | Haiku, `effort: low` |
| Growth hacker, lawyer | Opus, `effort: high` |
| Codex-controller agents | Sonnet, `effort: medium` |

`scripts/delivery-route.sh` assigns execution profiles before dispatch:

| Profile | Work | Codex default |
|---------|------|---------------|
| `mechanical` | Exact existing scripts only; no model worker | none |
| `light` | Bounded read-only work or autonomous docs/comments/typos/literal links | GPT-5.6 Terra, `medium` |
| `standard` | Routine scoped delivery | GPT-5.6 Sol, `high` |
| `deep` | Product/legal/architecture/security/auth/payment/data/migration/concurrency judgment or arbitration | GPT-5.6 Sol, `high` |

Interactive `/tweak` additionally permits explicitly requested non-behavioral copy and
small CSS edits, always behind post-diff containment and a reviewable PR. Autonomous
light routing excludes CSS, UI/product copy, localization, tests, dependencies,
workflows, and behavioral changes.

Every separate worker goes through `scripts/codex-run-role.sh`, which passes an explicit
model and reasoning effort so user-level Codex configuration cannot silently select
either. Profile overrides use `SAAS_CODEX_<PROFILE>_MODEL` and
`SAAS_CODEX_<PROFILE>_EFFORT`; they remain explicit launch arguments. Terra falls back
once to Sol/medium only when Codex reports that Terra itself is unavailable. Every
Codex role launches with `--dangerously-bypass-approvals-and-sandbox` inside the
dev-container security boundary. Read-only and writer distinctions remain prompt and
mutation-guard contracts, not nested Codex sandboxes. Legacy `CODEX_SANDBOX` and
`SAAS_CODEX_NETWORK_ACCESS` values cannot narrow or block that fixed launch policy.

On Claude hosts, non-trivial Codex-routed handoffs first run a plan-only **architect pass** through the registered Claude role (interface contracts, file map, invariants, test plan → `NNN-tech-plan.md`), then Codex implements from handoff + plan. Codex hosts run the equivalent model-neutral architect role phase without launching Claude — see `skills/startup-orchestration/SKILL.md` §1c.

### Convergence governor (`/goal-deliver`)

`/goal-deliver` integrates with the `tribunal-review` plugin's convergence governor to prevent review spirals. The governor enforces a hard ceiling of 5 rounds, triggers an investor checkpoint at round 3, and closes the loop automatically once the arbiter returns zero critical and zero high findings. The reachability convention (`skills/tech-founder/references/reachability-convention.md`) defines what counts as a reachable path for tribunal reviewers and is updated alongside the governor; the `last-verified:` field — documented by the convention but written into each consumer repo's own `reachability.md` — tracks when that repo's assumptions were last confirmed against production traffic.

## The Loop

```
Business Founder: research → requirements → handoff
  ↓
Tech Founder: read handoff → implement → handoff back
  ↓
Business Founder: browser verification → signoff or feedback
  ↓
[repeat for each feature]
  ↓
Business Founder: solution signoff → GO LIVE
```

## Signoff System

Two levels:
1. **Roundtrip Signoff**: Per-feature validation (requirement → implementation → browser QA → signoff)
2. **Solution Signoff**: The business founder declares the entire product customer-ready

Only the business founder can end the loop — they are the customer's voice.

## File Structure

The startup loop creates git-tracked durable docs plus ephemeral `.startup/` state:

```
docs/
├── human-tasks.md        # Tasks only the human can do (non-blocking, git-tracked)
└── ...

.startup/
├── brief.md              # Investor's SaaS idea
├── state.json            # Loop state (iteration, phase, active role) — auto-compacted
├── state-archive.json    # Historical keys moved out of state.json (append-only)
├── workflows/            # Git-trackable workflow registry/specs
├── handoffs/             # Structured handoff documents
├── docs/                 # Research documents (Estonian)
├── signoffs/             # Per-feature roundtrip signoffs
├── reviews/              # Browser verification notes
└── go-live/              # Solution signoff (ends the loop)
```

### Workflow registry

`.startup/workflows/` is the shared test oracle for non-trivial product behavior. `/bootstrap` creates:

- `.startup/workflows/registry.md`
- `.startup/workflows/WORKFLOW-template.md`

Create `WORKFLOW-<slug>.md` when a handoff introduces or changes routes, jobs, workers, webhooks, checkout/payment, LLM pipelines, support intake, operator workflows, entity states, or handoff contracts. Specs cover trigger, actors, happy path, validation failures, transient/permanent failures, cleanup/compensation, concurrent conflicts, customer/operator/system states, logs/artifacts, and QA cases. Missing workflows discovered in code should be marked `Missing` in `registry.md` instead of silently ignored.

Tech-founder handoffs reference affected workflow spec files. UX tester derives test cases from those specs and reports missing coverage back to the registry.

### state.json compaction

`state.json` uses schema v2. A PostToolUse hook runs `compact-state.sh` after every Write and archives old handoff keys (`handoff_NNN_*`) plus other non-allowlisted entries into `state-archive.json` once the inline window (last 10 handoffs) is exceeded. The inline state stays under ~30 lines regardless of project age. Run `/status --compact --yes` on existing projects to migrate one-shot (a timestamped `.bak` is written first). Tune the window with `STARTUP_INLINE_HANDOFFS=N` if needed.

### Learnings capture

A PostToolUse hook (`auto-learn.sh`) supplies non-blocking additional context after every handoff/review/signoff/go-live write under `.startup/`, asking the agent to extract up to 3 reusable project learnings into the project guidance file (`CLAUDE.md` in Claude Code projects; Codex projects may mirror this into `AGENTS.md` with `agent-sync`). Entries that clearly fit an existing `docs/learnings/<topic>.md` file are routed there directly; uncertain or new-topic learnings stage in the `### Recent (unsorted)` section.

To keep the guidance file lean, the hook caps `### Recent (unsorted)` at **10 entries** (tune with `SAAS_LEARNINGS_MAX=N`). It counts the staged bullets deterministically in bash, and once the section nears the cap the assistant migrates the surplus (oldest first) into the best-fit `docs/learnings/` topic file — creating the file and a `## Domain Learnings` index line when no topic fits — so the staging area self-heals back to ≤ cap. Run `/saas-startup-team:learnings-migrate` for a human-in-the-loop sweep of whatever remains.

### Google Ads records

Google Ads campaigns live under `docs/ads/<campaign>/` (owned by the `google-ads-strategist` plugin — briefs, iterations, verification screenshots, learnings). `docs/growth/channels/ads.md` is a lightweight index into them (campaign slug, status, link) and retains the `Approved budget:` / `Total spend:` summary lines the budget hard-stop hook reads. Meta/LinkedIn ads are logged inline in `ads.md`.

## Nightly monitor (`/monitor-nightly`)

`/monitor-nightly` is an optional stand-alone command that runs a nightly health-check loop against your product repo and files GitHub issues for recurring failures. It delegates all GitHub operations to `scripts/monitor-dedup.sh` — the command itself never calls `gh` directly. Pass `--dry-run` to preview what would be filed without writing state or touching GitHub.

### Configuration

All keys live under `monitor:` in `.claude/saas-startup-team.local.md`. Every key is optional; defaults apply when omitted.

| Key | Default | Meaning |
|-----|---------|---------|
| `repo` | resolved via `gh repo view` | GitHub repo in `owner/name` form |
| `labels` | `[monitor, customer-issue]` | Base labels applied to every created issue; the finding's severity is appended as an additional label |
| `marker_dir` | `.monitor` | Directory where marker files are written by producers (see contract below) |
| `state_file` | `.startup/monitor-state.json` | Persisted dedup state (issue numbers, seen entities, last-run timestamp) |
| `custom_checks` | `.startup/monitor-checks.sh` | Path to a custom-checks executable (see contract below) |
| `repro_recipe` | _(none)_ | Single-line shell snippet appended to every issue body; `{entity}` is substituted with the finding's entity value. Example: `ssh <readonly-host> "session-tar {entity}"`. Must be a single line — no newlines. |

### Marker producer contract

A marker producer writes `<marker_dir>/<kind>-last-failure.txt` on failure and deletes the file on recovery. `kind` must be kebab-case. When the failure file is present, `/monitor-nightly` files (or comments on) a GitHub issue. When the file is absent, the engine attempts verified recovery — it closes and re-opens if needed. Human closes the GitHub issue when the root cause is fixed; a recurrence after close always opens a fresh issue.

### Custom-checks contract

The file at `custom_checks` must be executable. It is invoked with two environment variables:

- `MONITOR_SINCE` — ISO-8601 timestamp of the previous run's start time
- `MONITOR_SINCE_MINUTES` — integer minutes since the previous run (minimum 1)

The script writes zero or more findings as JSONL to **stdout**. A non-zero exit code does not suppress findings already written — those are kept, and an additional `ops:monitor-checks:failure` tracking issue is filed automatically. `entity` must be a single-line identifier (no newlines, no backticks) so that recovery-search marker matching stays reliable. The default filename for this script is `.startup/monitor-checks.sh` (matching the `custom_checks` config default, so teams can commit it alongside `.startup/` state).

### Findings JSONL schema

Each line written to stdout by the engine or by `custom_checks` (the script is also named `monitor-checks.sh` by convention) must be a JSON object with these fields:

| Field | Required | Description |
|-------|----------|-------------|
| `pattern_key` | yes | Stable identifier for this finding type. Regex: `^[a-z0-9][a-z0-9:_-]*$` |
| `severity` | yes | Severity label appended to `labels` (e.g. `high`, `low`) |
| `entity` | yes | Single-line identifier for the affected entity, or `null` (entities containing newlines or backticks are rejected as malformed) |
| `title` | yes | Issue title |
| `body` | yes | Issue body (Markdown) |
| `summary` | no | One-line summary appended to comment when recurrence is detected |

`pattern_key` must match `^[a-z0-9][a-z0-9:_-]*$`. Invalid keys are treated as malformed and filed as `monitor-input:malformed` tracking issues.

### Cron setup

```cron
0 6 * * * cd <product-repo> && PLUGIN_ROOT=<installed-plugin-path>; export PLUGIN_ROOT; if bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" monitor-nightly; then <assistant-command> "/monitor-nightly" >> <log-path> 2>&1; else test $? -eq 3; fi
```

### Dependencies

Authenticated `gh` (GitHub CLI), `jq`, GNU coreutils `date` (for `date -d` relative time parsing), `sha256sum` (coreutils; `shasum -a 256` fallback — used by `/bootstrap`'s plan-file provenance), and `curl` (used by `notify.sh` for the optional `/digest` and blocker push channel).

`notify.sh` exit contract (callers gate the digest cursor on it): `0` = sent, `3` = no channel configured / `kind=none` (clean no-op, not an error), `2` = usage error, `1` = config error (unknown kind or malformed `notify.json`), `10` = send attempted but failed (fixed code — curl's raw exit never leaks into the `0`–`3` sentinel space). `/digest` advances its run cursor only on `0`, so a no-op or a failed send re-appears in a later digest.

## Operate phase (`/operate`, `/monitor`, `/investigate`, `/replay-abandoned`)

Operate is the post-launch track for live-product signals. It is config-driven and does not introduce `.startup/operate.yml`; use `.claude/saas-startup-team.local.md`.

`monitor:` remains the source for recurring failure dedup (`marker_dir`, `custom_checks`, labels, state). `operate:` adds live-product sources:

| Key | Meaning |
|-----|---------|
| `api_base_url` / `app_base_url` | Base API/app URLs for configured operations. |
| `auth_header` / `auth_env_var` | Header name and env var name for API auth. |
| `incidents.repo`, `incidents.labels`, `incidents.issue_template_path` | GitHub issue conventions for investigation/replay findings. |
| `funnel.steps` | Step names and abandonment warning/critical bands. |
| `funnel.abandoned_sessions_source` | Command, file, or URL/path used by `/replay-abandoned`. |
| `support_api.*` | Support feedback/session/log source, auth, and response path hints. |
| `log_sources[]` | Named command/path/URL sources for `/monitor`. |
| `analytics_sources[]` | Named command/path/URL sources for traffic/funnel/cost reporting. |

`/monitor` writes reports under `docs/operate/` and is read-only unless `--file-issues` is used. `/investigate` writes redacted RCA artifacts under `.startup/operate/investigations/` and files or updates a deduplicated GitHub issue by default. `/replay-abandoned` writes `finding.json`/`finding.md` under `.startup/operate/replay/` and files actionable findings by default. For both commands, `--no-file-issues` skips filing and `--dry-run` previews it without mutating GitHub. `support-triage` writes `docs/operate/support-triage-YYYY-MM-DD.md` and routes patterns into `/investigate`, `/replay-abandoned`, `/improve`, or `docs/human-tasks.md`.

All operate commands treat logs/support text as untrusted customer-controlled input. Raw PII stays in `.startup/operate/`; reports and issues should link redacted local artifacts or summaries.

## Demand Signal Intake

The maintenance loop consumes GitHub issues, but `/startup`, `/growth`, `/improve`,
`/tweak`, and `/goal-deliver` can also start from discovered evidence when no fresh
investor instruction is provided. The market-scout entrypoint uses configured external
market evidence when available, and falls back to internal discovery when browsing/source
data is unavailable:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/market-scout.sh"
```

`market-scout.sh` accepts public evidence as source JSON/URLs and emits
`.startup/demand/market-scout.jsonl` plus `.startup/demand/market-scout-report.md`. Each
candidate includes evidence, source links, source dates, confidence, acceptance criteria,
non-goals, rollout checks, and ranking scores for customer pain, willingness to pay,
urgency, implementation complexity, and Estonian small-business fit. It converts findings
into generic customer needs rather than copying competitor-specific features.

When external evidence is unavailable, it runs the internal fallback:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/demand-discovery.sh"
```

The fallback ingests configured local sources: Claude Code session JSONL, Codex
session/history JSONL, GitHub issue/PR JSON exports, local docs/learnings, test logs,
runtime/error logs, and analytics exports. It clusters repeated signals into customer pain
areas, ranks them, de-identifies project names/paths/issue IDs, and records the limitation
in the market-scout report.

External signal plugins should bridge into issues rather than directly invoking
implementation:

- `analyst-companion` can mirror approved meeting work items into issues when trusted
  bridge mode is explicitly configured.
- `emails-to-github-issues` turns support, bug, and feature-request threads into deduped
  issues after confirmation or trusted allowlisted sender processing.
- `reddit-fetch` can file `market-signal` / `customer-issue` issues only for repeated,
  objectively-checkable public pain points.
- `monitor-nightly`, `/investigate`, and `/replay-abandoned` file recurring failure and
  funnel issues from configured live-product sources.

`/maintain` then triages those issues as `agent-fixable`, `partially-fixable`, or
`needs-human`. Signal plugins should preserve evidence, acceptance hints, source labels,
and dedupe keys; they should not decide that every signal is implementation-ready.

## Product QA Gates

Founder handoffs, UX review, and solution signoff include triggered gates. The reusable
pack surface is:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/acceptance-packs.sh" --select --category <category> --text <need>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/acceptance-packs.sh" --render paid_async_workflow,report_output_product
```

Available packs cover:

- async paid/background flows: progress, ETA or honest indeterminate state, close-browser behavior, terminal `DONE`/`FAILED`/still-working states, and slow-job evidence;
- customer-facing copy/value units: public copy, metadata, pricing, checkout, onboarding, empty states, and generated customer text avoid internal implementation terms;
- structured-result UI: display labels/fallbacks for statuses, enums, categories, and result domains; no `undefined`, `null`, `NaN`, `[object Object]`, raw enum keys, or empty joins;
- checkout UX: required fields and the payment CTA stay together in the natural desktop/mobile flow, with accessible validation;
- LLM products: model/provider tier, fallback metadata, parse-failure evidence, structured-output hardening, and customer-critical quality checks;
- compliance/risk products: facts, signals, automated findings, violations, drafts, recommendations, and needs-review claims have separate evidence rules;
- go-live CI/CD: deploy workflow, environment approvals, separated permissions, managed secrets, visible logs, migration/restart docs, and runner recovery instructions.

Report/output products can be fixture-checked with:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/acceptance-packs.sh" --verify-report path/to/report.md
```

## Maintenance loop (`/maintain`)

`/maintain` is a **stateless supervisor** that executes one unattended maintenance pass per scheduler tick: it re-reads GitHub issues and triage state from disk, classifies open issues into `agent-fixable`, `partially-fixable`, or `needs-human`, and delivers eligible issues to production via inline `/goal-deliver` calls, one issue at a time in dependency order. The supervisor holds no durable context — every pass reconstructs its working state from disk and GitHub, making context loss or compaction harmless.

### Operation model

The supervisor is watched remotely via `/rc` (the human is a silent investor). An
external scheduler invokes one `--once` pass per tick and owns cadence/backoff; a
foreground model turn is not a long-lived daemon. The supervisor runs one
`/goal-deliver` inline per issue and retains mutation/merge ownership. Fresh bounded
founder, implementation, QA, and tribunal roles return compact results without moving
supervisor ownership into a nested `/goal-deliver` context.

Codex CLI automation must start `/maintain-loop` in a collaboration-capable,
non-ephemeral coordinator session so the fresh pass returns a stable child identity.

**No worktrees except maintain.** Linked worktrees are disallowed except one:
`.worktrees/maintain` for autonomous delivery (`/maintain` and `/maintain-loop`,
detached off the default-branch tip, sequential). Never
`.worktrees/maintain-loop`, improve trees, or per-issue trees. `/improve` and
other one-shots run on the **primary checkout** (main repo dir). Never set
`core.worktree` on the primary. (`--dry-run` is read-only and creates no worktree.)

### Triage verdicts

- **`agent-fixable`** → enters the delivery queue and is delivered like any other work, gated only by the mandatory green gate (zero critical/high tribunal findings + required CI checks).
- **`needs-human`** → genuine human decision required; labelled `needs-human` and escalated to `docs/human-tasks.md`.
- **`blocked`** (supervisor-set, not a triage verdict) → transiently un-deliverable (no-progress, deploy-blocked, or cooldown); auto-retried after cooldown, never silently promoted to human work.

### Dependency ordering

An issue is delivered only **after** its explicitly-declared prerequisites (`depends on #N`, `blocked by #N`) have merged. The supervisor builds a DAG per pass; a cycle or a prerequisite that is itself `needs-human` / blocked → defer the dependent. Within the dependency-eligible set, order by severity (`critical` → `high` → `medium` → `low`); absent or unlabelled → oldest-first.

Queue construction runs through `scripts/maintain-queue.sh`, so no-dependency issues are preserved, linked PRs and excluded labels are accounted for, and an unexplained empty queue fails the pass instead of silently no-oping.

### Merge safety gate

**The green gate is mandatory:** every PR that clears it is merged immediately. The gate comprises latest-HEAD tribunal clearance with zero critical/high findings, required CI checks passing, and recurrence proof. Bug, monitor, customer, accounting, replay, and incident-class issues must fix the recurrence class and add a regression/contract/monitor guard that would fail on the old behavior, or explicitly record why no durable guard is possible. No human-hold tier — the merged diff is the authority on whether the fix is correct.

### Safe rollout and circuit breakers

Start with `--dry-run` (read-only: classify issues, print the planned queue, then stop — no mutations). Once confident, use `--once` (single pass, then report). Default flags:

- `--max-issues N` — cap delivered issues per pass (default 10).
- `--max-merges N` — cap merges per pass (default 5).
- `--max-pass-minutes N` — wall-clock budget per pass (default 90 minutes).
- `--max-run-minutes N` — optional wall-clock cap for this invocation (default 0 = no separate cap beyond the pass budget).

The supervisor also stops on deploy failure (unrecoverable infra/flaky issues halt further merges that pass) or the hard tribunal round ceiling (notify investor at round 3, hard-stop at round 5 per issue). The external scheduler owns cadence and backoff between `--once` invocations.

### Prerequisites and integration

- **Requires the `tribunal-review` plugin** (hard dependency).
- **Reusable health preflight:** `/improve` and `/goal-deliver` call
  `scripts/health-preflight.sh` before autonomous work. It reports blocking, warning, and
  auto-fixed states as both human-readable Markdown and machine-readable JSON, checks
  `bash` 4+, `git`, `gh`, `jq`, `awk`, `sed`, `timeout`, Codex CLI when required,
  a model-free check for Codex unrestricted-worker support when Codex is required,
  GitHub auth, hook targets, dirty worktree classification, and Codex/Claude surface sync.
- **Issue-closure audit:** `/improve` and `/goal-deliver` call
  `scripts/issue-closure-audit.sh` for PRs using `Closes`, `Fixes`, or `Resolves`. It
  compares closing issue body/comments against PR files and requires a closure-audit
  explanation, follow-up issue, `Refs #N`, or implementation of any explicitly named
  surface that was not touched.
- **Single-flight leases:** `scripts/single-flight.sh` owns issue/job/scan/report/deploy
  work units with owner, heartbeat, stale replacement audit notes, and release/status
  commands. Long-running work is treated as alive when the heartbeat/logs advance. The
  lease holder uses Linux ptrace to contain detached descendants without changing the
  command's `/proc` view. This reserves the process's tracer slot, so held commands cannot
  run ptrace-dependent tools such as `strace`, `gdb`, `rr`, or LeakSanitizer stop-the-world,
  and stop-signal job control is not preserved. Containment assumes cooperative checks
  inside the dev-container boundary: raw `CLONE_UNTRACED` can evade tracing, with the
  retained process-token sweep serving only as a cleanup backstop.
- **Authenticated `gh` (GitHub CLI)** and standard tooling: `bash` 4+, `git`, `jq`,
  `awk`, `sed`, OpenSSL, GNU coreutils `date`/`timeout`/`realpath`/`sha256sum`, and
  util-linux `flock` and `setpriv`, GNU findutils, Python 3, and
  `tar`. The fresh Codex delivery gate uses Python
  to seal preinstalled dependency trees before copying them into read-only check volumes.
- **Codex unrestricted-mode support plus Docker CLI/socket access** from the dev container.
  Supervisor checks run from the sealed current dev-container image with private process
  and network namespaces; the commit path fails closed when these controls are unavailable.
  Required system toolchains must be baked into that image: lifecycle installs made only
  in the running container's writable layer are deliberately excluded from trusted checks.
- **Optional `curl`** for `market-scout.sh --source-url`; without it, market scouting still
  runs source JSON ingestion or the internal discovery fallback.
- **Dev container only** (inherits the plugin's dev-container-only design).

### Fresh maintenance passes (`/maintain-loop`)

`/maintain-loop` keeps its caller small: it runs the model-free `/maintain` probe,
launches one fresh isolated `/maintain --once` subagent, waits for the bounded pass,
retains only its compact result, and repeats sequentially. The child owns the complete
maintenance policy and may batch related small issues normally. The parent never reads
issues or source and never falls back to inline delivery when isolated dispatch fails.

Claude Code invokes `/maintain-loop`; Codex invokes
`$saas-startup-team:maintain-loop` or selects it from `/skills`. Codex does not support
plugin-defined slash commands.

### Delivery telemetry and local evaluation

Versioned, append-only events stay local in `.startup/runs/agent-events.jsonl`. They
contain profile/model/effort, opaque writer/run IDs, timing/token fields when available,
gate statuses, and outcomes—never prompts, issue text, diffs, secrets, customer/project
names, URLs, or paths. `scripts/agent-events-export.sh` runs the secret/PII gate and
exports only anonymous counts, rates, durations, profile/model/effort, and outcomes.
`scripts/agent-events-aggregate.sh` combines sanitized exports without project identity.
Provider/model labels such as Gemini are telemetry categories, not CLI dependencies.

`scripts/standard-medium-eval.sh` supports local high-versus-medium replay for 20–50
standard deliveries. AI workers run unrestricted inside the development-container
boundary, in detached worktrees at recorded base SHAs with isolated Codex configuration,
sanitized credentials, and wrappers for common remote tools. Only the deterministic
`check.sh` harness uses the credentialless network-off sandbox. Replays fingerprint the
primary checkout, including ignored files, and record remote or production mutation as
unknown because local repository state cannot prove either absence. Raw material stays
under `.startup/evaluation/`. A schema-3 assessment verifies each base and check harness
against its source repository, validates non-empty patches, and binds each unique opaque
sample, task, result, diff, blinded input, mapping receipt, and tribunal result by hash;
older corpora require a fresh replay. Mapping receipts contain no model/effort identity,
and marked candidate content is rejected. Persisted same-user artifacts are not a
sufficient authorization boundary: assessments remain metrics-only `no-go` until a
supervisor-owned end-to-end controller can issue receipts unavailable to workers and
reviewers. Standard therefore remains Sol/high; unverified provenance or economics cannot
authorize a downgrade.

## Self-improvement loop (`/lessons-deliver`)

The plugin improves itself: it harvests genuine, generic lessons from authoritative root
workflow outcomes and session history, files them as de-identified, PII-gated
`lesson-candidate` issues in a pinned plugin repo (`SAAS_PLUGIN_REPO`), and reviews them
automatically with a fresh isolated Opus/xhigh verdict. Only an unresolved verdict invokes
independent GPT-5.6 Sol/xhigh arbitration. High-confidence decisions approve or reject;
unresolved pairs quarantine the candidate. Model transport failures and timeouts leave it
for retry. A zero-exit malformed Opus verdict invokes Sol; a zero-exit malformed final Sol
verdict is unresolved and quarantined. Each pass reviews at most three candidates. `/lessons-review` remains an optional
manual inspection/override surface, not an implementation prerequisite.

`/lessons-deliver` is the implementer. Because lessons land in a *plugin monorepo* (no
`.startup/`, no `solution-signoff.md`, no GitHub Actions deploy), it is **not**
`/goal-deliver`: it borrows `/maintain`'s safety skeleton (stateless supervisor,
primary-checkout delivery with no extra worktree, circuit breakers, GitHub-native
claim/idempotency, merge-on-green, run digest) but uses a plugin-native delivery body —
claim → implement (fresh implementer subagent) → **mechanical diff firewall** → tribunal
gate → `run-tests.sh` → dual version bump (`plugin.json` **and** `marketplace.json`) →
PR with `Closes #N` → merge on green → ship. The deterministic, fail-closed surface lives
in `scripts/lessons-deliver.sh` (tested by Suite L with a mock-`gh` harness).

**The mechanical firewall** treats lesson bodies as untrusted: it blocks any change outside
`plugins/` (+ the root marketplace manifest), any change to the loop's own safety
infrastructure (self-modification → `lessons:needs-human`), and any secret in the diff
(`pii-gate.sh`). Deletion or renaming of any discovered test file is blocked, as are
reductions in assertion/test counts; the firewall itself is self-protected.

**Autonomy.** The production runner is a nightly `flock` cron (the loop's "deploy"):

```
0 3 * * * /usr/bin/flock -n /tmp/lessons-deliver.lock -c \
  'cd <plugin-repo> && PLUGIN_ROOT=<installed-plugin-path>; export PLUGIN_ROOT; if bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" lessons-deliver; then <assistant-command> "/lessons-deliver --once" >> <log-path> 2>&1; else test $? -eq 3; fi'
```

For supervised/dev ticks, run `workflow-probe.sh lessons-deliver` first and invoke
`/loop 5m /lessons-deliver --once` only on exit 0. Note this runs in the
**plugin repo** (cwd = where the plugin source lives), independently of `/maintain` which
runs in each **product** repo.

## Prerequisites

- Codex or Claude Code. Codex runs the command-style workflows as plugin-bundled skills and does not require Claude Code.
- Playwright MCP (`@playwright/mcp`) — automatically configured via plugin `.mcp.json`, runs headless
- Web access enabled (for business founder's market research)
- **Dev container only (by design)** — this plugin is meant to run **only inside a disposable dev container**, never on a host. Launch the primary Codex session and every delegated Codex worker with `--dangerously-bypass-approvals-and-sandbox`; the container is their security boundary. Hooks also use `/proc/` for process-tree detection.
- **`jq`, `awk`, `sed`, `curl`, OpenSSL, GNU coreutils (`timeout`, `realpath`, `readlink`, `stat`, `sha256sum`),
  `flock` and `setpriv` (util-linux), GNU findutils, `python3`, and Node.js** — required by hook scripts,
  JSON validation, monitor/lawyer workflows, preflight checks, Codex marketplace sync, and
  datalake API checks.
- **Linux ptrace support** — required by the lease holder, subject to the compatibility
  limits under **Single-flight leases** above.
- **Linux Landlock ABI 5–10** — required for fail-closed filesystem containment of tracked QA and live-proof commands.
- **est-saas-datalake API (required for `/lawyer`)** — the Lawyer's Estonian legal analysis and law-change monitoring query an external est-saas-datalake service. Two environment variables control access:
  - `DATALAKE_URL` — API base URL. Defaults to `https://datalake.r-53.com`; export it to point `/lawyer` (command, agent, and `scripts/lawyer-*.sh`) at your own datalake deployment.
  - `EST_DATALAKE_API_KEY` — API key sent as the `X-API-Key` header. **Required** — `/lawyer` pre-flight hard-fails if it is unset. Set it with `export EST_DATALAKE_API_KEY=your-key`.

  `/lawyer` pre-flight also hard-fails if `DATALAKE_URL/api/v1/health/ready` does not return `200`; there is no offline fallback. The rest of the plugin works without the datalake.
- **google-ads-strategist plugin** — required for any Google Ads work (hard dependency). Google Ads is delegated to its `ads-strategist` agent; `growth-hacker` no longer creates Google Ads campaigns itself. There is no manifest-level dependency field, so this is enforced behaviorally: `/ads` and the `/growth` loop fail with an install instruction if the plugin is absent.
- **`codex` CLI (optional in interactive Codex, required for separate worker dispatch)** — only needed for `scripts/codex-run-role.sh` or its `codex-implement.sh` compatibility wrapper. When required, preflight checks Codex authentication and support for `--dangerously-bypass-approvals-and-sandbox` without starting a model turn. Without it, Codex continues inline or asks for an environment fix; it never falls back to a Claude implementation engine.

## Implementation Engine

For Codex installs, the tech-founder implementation role uses Codex only (`active_role` stays `tech-founder`):

- Use the `tech-founder` skill for implementation standards and handoff requirements.
- Implement inline in the current Codex session when that is simplest.
- Use `scripts/codex-run-role.sh` with an explicit role/profile/task file, or the
  `scripts/codex-implement.sh` compatibility wrapper, for a separate worker.
- For extra review, use Codex-native review passes or the `tribunal-review` plugin.

Claude Code installs may still use their Claude-specific command and agent files, but the Codex marketplace surface does not depend on them.

## Key Design Decisions

- **Information asymmetry**: Tech founder has no web access, forcing the business founder to be thorough
- **File-based state**: Handoff documents carry context between iterations, not LLM memory
- **Quality gates**: Codex-supported hooks enforce file/tool gates and solution signoff; handoff and deliverable validation are explicit workflow gates
- **Pre-merge safety net**: `/bootstrap` scaffolds a canonical `check.sh` full-suite entrypoint and a `pull_request` CI workflow, and queues a branch-protection task.
- **Non-blocking human tasks**: Tasks for the investor are documented but don't stop the loop
- **Estonian working language**: Business founder thinks and researches in Estonian, translates for handoffs
