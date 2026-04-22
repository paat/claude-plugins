# Plan: saas-startup-team operate phase (issue #11)

> **Universality rule (overrides everything below):** The plugin MUST NOT contain Aruannik-specific logic, strings, endpoint URLs, funnel step names, locale assumptions, or domain vocabulary. Aruannik appears in this plan only as (a) evidence of the problem and (b) smoke-test target during implementation. Every example below uses fictional `Acme` product. All project-specific values flow through `.startup/operate.yml` at runtime — never hardcoded in commands/agents/scripts/templates.

## Goal & scope

Add a generic, post-launch **operate phase** to `plugins/saas-startup-team/` alongside `build` (`/startup`), `growth` (`/growth`), and `improve` (`/improve`). This phase owns everything that happens once a product has paying customers: monitoring, incident RCA, session-replay on abandoned funnels, and user-reported support triage.

Implementation is informed by the battle-tested DIY layer a downstream project built locally (5 commands + 2 agents + 1 skill). The job is to extract the skeleton, push every project-specific string (API URLs, env var names, funnel step indexes, abandonment band labels, locale codes, host integrations, identifier regexes) into a per-project config file — `.startup/operate.yml` — that the investor fills in once.

Out of scope for this issue:
- Reddit-scout-nightly — too tightly coupled to growth + brand/voice docs; belongs in `/growth`, not `/operate`. (Open Q: defer or fold into growth.)
- Any plugin-hosted infra (no ngrok, no webhook servers) — everything runs via the investor's cron on their own box.
- Auto-migration of any existing downstream project. We document a migration path; we do not touch user files.

**Non-goal: the plugin does not dictate the user's observability stack.** `operate.yml` is a descriptor that tells generic agents where to look — it does not ship any vendor-specific clients (no Cloudflare, Hetzner, Stripe, etc. in plugin code).

## Proposed config schema

New file: `.startup/operate.yml` (created by `/operate init`, gitignored by default — it can reference env vars but shouldn't hold secrets directly). YAML (not JSON) because investors will hand-edit it and YAML tolerates comments.

```yaml
# .startup/operate.yml — describes the live product so generic
# operate-phase agents/commands can monitor, investigate, and replay.
# Edited by the investor. Env vars are referenced by name, never inlined.

version: 1

product:
  name: "Acme Reports"
  locales: [en]                         # first entry = default for replay
  base_url: "https://acme.example.com"
  local_url: "http://127.0.0.1:3001"    # used by session-replay
  repo: "acme-corp/acme"                # {org}/{repo} for gh issue create

# --- Data sources generic commands can call ---------------------------
apis:
  admin:
    kind: http
    base_url_env: ACME_ADMIN_URL
    auth:
      type: bearer                      # bearer | cookie-login | x-api-key
      token_env: ACME_ADMIN_KEY
      login_path: /api/admin/login      # required if type=cookie-login
      cookie_name: admin_token          # required if type=cookie-login
    endpoints:                          # logical name -> relative path
      sessions_recent: /api/admin/sessions/recent
      session_detail: /api/admin/sessions/{cid}
      session_logs:   /api/admin/sessions/{cid}/logs
      pipeline_logs:  /api/admin/logs/sessions
      payment_logs:   /api/admin/logs/payments
      health:         /api/admin/logs/health
      costs:          /api/admin/logs/costs
      funnel:         /api/admin/funnel
      revenue:        /api/admin/revenue
  support:
    kind: http
    base_url_env: ACME_SUPPORT_URL
    auth: { type: x-api-key, header: X-API-Key, token_env: ACME_SUPPORT_KEY }
    endpoints:
      feedback_list:    /api/support/feedback
      feedback_resolve: /api/support/feedback/{id}/resolve
      session_files:    /api/support/sessions/{cid}/files/{filename}
  traffic:                              # optional — skip section if unset
    kind: cloudflare                    # cloudflare | plausible | matomo | none
    zone_id_env: CLOUDFLARE_ZONE_ID
    token_env:   CLOUDFLARE_API_TOKEN
  host:                                 # optional
    kind: hcloud                        # hcloud | aws | gcp | ssh-only | none
    token_env: HCLOUD_API_TOKEN
    ssh_alias: "acme-live-readonly"     # forced-command readonly wrapper

# --- Funnel definition (drives /replay-abandoned + /monitor funnel) ---
funnel:
  identifier_regex: "ACME-[0-9]{8}-[A-Za-z0-9]+"
  steps:
    - { index: 0, slug: "signup",   name: "Sign up" }
    - { index: 1, slug: "onboard",  name: "Onboarding" }
    - { index: 2, slug: "upload",   name: "Upload data" }
    - { index: 3, slug: "review",   name: "Review" }
    - { index: 4, slug: "pay",      name: "Payment" }
    - { index: 5, slug: "download", name: "Download" }
  abandonment_bands:
    - band: A
      label: "Abandoned after upload, before pay"
      entered_step: 2
      dropped_before_step: 4
      priority: 2
    - band: B
      label: "Paid, never downloaded"
      entered_step: 4
      dropped_before_step: 5
      priority: 1

# --- Session replay behaviour -----------------------------------------
replay:
  enabled: true
  scratch_dir: "/tmp/acme-replay"
  max_cids_per_run: 10
  max_concurrent: 3
  max_wall_clock_seconds: 180
  max_screenshots: 20
  redaction_rules:
    - "Strip {cid}, customer names, email, phone, document numbers, account numbers"
    - "Describe UX, not data values"
  verdicts: [pass, ux_bug, functional_bug, infra_error]

# --- Incident response conventions ------------------------------------
incidents:
  issue_labels: [monitor, customer-issue]
  severity_labels: { high: high, medium: medium, low: low }
  create_gist_for_pii: true
  gist_desc_template: "Session data for {cid} (contains PII)"
  pattern_key_templates:
    pipeline: "pipeline:{category}:{stage}"
    payment:  "payment:{status}"
    feedback: "feedback:{feedback_id}"
    funnel:   "funnel:drop:{step_slug}"
    replay:   "replay:{band}:step{step_index}:{slug}"
    ops:      "ops:{kind}:failure"
  thresholds:
    cpu_high_pct: 80
    cpu_medium_pct: 60
    memory_high_pct: 85
    funnel_drop_high_pct: 40
    funnel_drop_medium_pct: 25
    conversion_low_pct: 20

# --- Nightly monitor behavior -----------------------------------------
monitor:
  state_file: "${HOME}/.acme-nightly-state.json"
  default_window_minutes: 1440
  max_window_minutes: 2880
  failure_marker_dir: "/workspace/.monitor"
  sections_enabled: [sessions, payments, health, costs, customers, revenue, funnel, traffic, server]

# --- Voice / locale notes (freeform prose the agents read) ------------
locale_notes: |
  Freeform notes that the agents read for brand/UX alignment during replay.
  e.g. preferred customer-facing terminology, tone constraints, regional
  compliance sensitivities. No plugin logic consumes structured data here.
```

Every project-specific concept maps onto one of these keys. A new investor fills this file in once (or `/operate init` populates it from prompts) and the generic agents start working.

## New files (plugins/saas-startup-team/)

**Commands** (under `commands/`):
- `operate.md` — entry point router. Pre-flight: check `solution-signoff.md` exists, check `.startup/operate.yml` exists; if not, offer `/operate init`. Subcommands: `init`, `monitor`, `investigate`, `replay-abandoned`, `support`, `monitor-nightly`, `replay-abandoned-nightly`, `status`.
- `operate-init.md` — interactive wizard that writes `.startup/operate.yml` by asking ~10 questions. Also updates `.gitignore` and adds a `phase: operate` field in `state.json`.
- `monitor.md` — generic monitoring command. Reads `.startup/operate.yml`, authenticates per `apis.admin.auth.type`, iterates `monitor.sections_enabled`, emits the structured report. All URLs, env-var names, and thresholds come from the config.
- `monitor-nightly.md` — nightly variant with dedup state machine and GH issue creation.
- `investigate.md` — accepts `{identifier}` (validated against `funnel.identifier_regex`) or `--recent N`. Delegates to `incident-investigator` agent.
- `replay-abandoned.md` — on-demand replay for one or more identifiers. Dispatches `session-replay` agent.
- `replay-abandoned-nightly.md` — nightly variant with detector + dedup + aggregation.
- `support.md` — on-demand feedback triage. Wraps `support-triage` agent.

**Agents** (under `agents/`):
- `incident-investigator.md` — takes an identifier, pulls session context from `apis.admin`, does RCA against `incidents.pattern_key_templates`, drafts a GH issue body, waits for confirmation.
- `session-replay.md` — generic replay agent. Role-plays a first-time user. Reads `funnel.steps` to know the walkthrough, `funnel.abandonment_bands` for band semantics, `replay.redaction_rules` before writing `finding.json`. Fully parameterised by config — no hardcoded step names.
- `support-triage.md` — reads `apis.support`, pulls feedback, fetches session details, writes resolution draft, optionally posts back via `feedback_resolve`.

**Skills** (under `skills/`):
- `operate/SKILL.md` — "how to operate a live SaaS product with this plugin."
- `skills/operate/references/config-schema.md` — annotated schema reference (spec for `operate.yml`)
- `skills/operate/references/pattern-keys.md` — incident dedup key conventions
- `skills/operate/references/redaction.md` — PII rules for replay + investigate output

**Templates** (under `templates/`):
- `operate.yml.example` — the filled-in fictional Acme example from above. Copied by `/operate init` as scaffolding. **No domain-specific content beyond the structure.**
- `operate-incident-issue.md` — GH issue body template with `{identifier}`, `{timeline}` placeholders.
- `operate-replay-issue.md` — GH issue body for replay findings.

**Scripts** (under `scripts/`):
- `operate-auth.sh` — auth indirection; centralises bearer vs cookie-login vs x-api-key.
- `operate-collect-session.sh` — given identifier, fetches session detail + logs + results into `/tmp/{product-slug}-sessions/{identifier}/`. `product-slug` derived from `product.name`.
- `operate-validate-config.sh` — schema check on `.startup/operate.yml`.

**Tests** (under `tests/`):
- `tests/operate/config-parse.sh` — load the example config, assert every documented key is read.
- `tests/operate/monitor-dryrun.sh` — run `/monitor` against a stubbed admin API (python `http.server`), assert report sections match.

## Modified files

- `plugins/saas-startup-team/hooks/hooks.json` — add PreToolUse hook matching `operate-*` commands: run `operate-validate-config.sh`. Fail closed if `.startup/operate.yml` missing or schema-invalid (whitelist `operate init`).
- `plugins/saas-startup-team/commands/bootstrap.md` — add `.startup/operate.yml` to gitignore block; add "Operate Phase" bullet to Workflow Guidance.
- `plugins/saas-startup-team/commands/startup.md` — after solution signoff, team lead announces `Product is live. Run /operate init to set up post-launch monitoring.` (nudge only; never auto-runs).
- `plugins/saas-startup-team/commands/status.md` + `scripts/status.sh` — add "Operate Phase" section.
- `plugins/saas-startup-team/commands/improve.md` — cross-ref: "If the issue was discovered via `/operate monitor-nightly`, reference the GH issue number in the improvement description."
- `plugins/saas-startup-team/README.md` — new "Operate" section in commands table.
- `plugins/saas-startup-team/templates/human-tasks.md` — note that after solution-signoff the investor should set operate env vars in their environment.

## State-machine integration

**Opt-in, never auto-run.** Post-launch ops touches production; silently running monitors would be a safety footgun.

- `.startup/state.json` gets a new optional `operate_phase` field. Values: `not-initialised | configured | active`. Set by `/operate init` (→ `configured`) and by `/operate monitor-nightly` / `/replay-abandoned-nightly` on first successful run (→ `active`). Never set automatically.
- **Suggestion, not coercion.** After `solution-signoff.md` is written, `/startup`'s team lead prints a one-line suggestion. `/status` surfaces it on subsequent runs. `/improve` does not block on operate being configured.
- **Guard in `/operate` itself.** Pre-flight checks (in order): `.startup/state.json` exists → `solution-signoff.md` exists → `.startup/operate.yml` exists & valid → required env vars present. If `solution-signoff.md` is missing, warn but allow `--pre-launch`.
- **Phase independence.** Operate runs alongside `/improve` and `/growth` — all three are post-launch tracks.

## Migration path for existing downstream projects

- **Do not auto-migrate.** Leave the project's existing local `.claude/commands/*.md` and `.claude/agents/*.md` intact.
- **Ship a migration doc**: `plugins/saas-startup-team/skills/operate/references/migration-from-diy.md`. It shows how to fill in `operate.yml` to reproduce the DIY behaviour and which pieces (forced-command SSH wrappers, vendor-specific scripts, per-project domain glue) remain project-local and SHOULD stay outside the plugin.
- **Parallel running period** (recommended): for ~2 weeks, the project runs BOTH the plugin `/operate monitor-nightly` and their local version, diffs the GitHub issue output, then retires the local one.

## Step-by-step implementation order

Each step is independently testable.

1. **Config schema + validator** — add `templates/operate.yml.example`, `scripts/operate-validate-config.sh`, `tests/operate/config-parse.sh`. Test: passes on example, fails clearly on bad config.
2. **`/operate init` wizard** — writes `.startup/operate.yml`, updates `.gitignore`. Test: run in scratch dir; resulting YAML validates.
3. **Auth helper** — `scripts/operate-auth.sh`. Test: mock each auth type with a tiny Python `http.server`.
4. **`/operate status` + hook wiring** — smallest command that reads the config. Test: no-config clear error; invalid-config fail-closed; valid-config clean output.
5. **`/operate monitor` (on-demand)** — config-driven report, no GH side effects yet. Test: stub admin API; assert section layout.
6. **`/operate investigate` + `incident-investigator` agent** — starts in `--dry-run` mode until tuned. Test: canned session fixture → structured RCA + issue-body draft.
7. **`/operate monitor-nightly`** — dedup state machine + GH issue creation. Ship with `--dry-run` default for 3 days. Test: two consecutive runs on same fixture; second must comment, not re-create.
8. **`/operate support` + `support-triage` agent** — stays read-only until tested.
9. **`/operate replay-abandoned` + `session-replay` agent** — hardest piece. Gate on `replay.enabled: true`. Test: point at `tests/fixtures/sample-wizard/`; verify `finding.json` matches schema + redaction rules.
10. **`/operate replay-abandoned-nightly`** — detector + dedup + aggregation. Same `--dry-run` shakedown.
11. **Integrate with state machine and docs** — update `status.sh`, `startup.md` end-of-loop nudge, README, bootstrap gitignore.
12. **Migration doc** — write the DIY-migration reference. Only after this, mark phase GA in README.

## Trade-offs / decisions that need investor sign-off

- **YAML config vs `.local.md` convention.** The plugin-dev `plugin-settings` skill advocates `.claude/<plugin>.local.md` with YAML frontmatter. Proposing `.startup/operate.yml` instead. Reason: operate config is multi-hundred-line, structured, has arrays — frontmatter gets unwieldy. Breaks the convention.
- **yq dependency.** Every operate command needs to read YAML. Either add `yq` as required tool or write a pure-Python shim. Prefer `yq`.
- **Scope of replay.** Support `replay.target: local | production` via config; default `local` with required `replay.local_stack.up_cmd` / `down_cmd`.
- **Nightly scheduling.** Ship cron + GH Actions templates under `templates/nightly-schedules/`; investor installs preferred one.
- **Severity threshold defaults.** Conservative defaults in the example; investor overrides per product.
- **Auto-apply-fix.** Explicit plugin-wide rule: `/operate` commands never edit code. Enforce via hook if `state.json.operate_phase=active` and inside an `/operate investigate` session.

## Open questions

1. Is `.startup/operate.yml` git-tracked or gitignored? Default tracked (no secrets, env-var references only); wizard could ask.
2. Multi-repo support. Single repo for v1. `product.repo` stays scalar.
3. Authentication via plugin-provided MCP server derived from `operate.yml.apis` — architecturally cleaner but v2. Ship `curl` via Bash now.
4. Redaction enforcement via PostToolUse hook scanning `finding.json` — v2 add-on. v1 ships agent-prompt rules only.
5. `/operate` vs `/monitor` etc as top-level. Use `/operate` router; register shorthand aliases (`/monitor`, `/investigate`, `/replay-abandoned`, `/support`) that forward.
6. Multi-tenant SaaS (staging/prod/regional). v1 single-environment; v2 if asked.

## Critical files for implementation

- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/commands/operate.md` (new)
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/agents/session-replay.md` (new)
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/agents/incident-investigator.md` (new)
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/templates/operate.yml.example` (new — schema source-of-truth)
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/operate-auth.sh` (new)
