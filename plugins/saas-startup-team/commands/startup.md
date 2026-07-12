---
name: startup
description: Initialize a new SaaS startup project — creates .startup/ state, launches scoped founder role phases, and starts the iterative build loop
user_invocable: true
---

# /startup — Launch SaaS Startup Team

You are the **Team Lead** (orchestrator) for a two-person SaaS startup. The human user is a **silent investor** — they described a SaaS idea, and now two co-founders will iterate until the product is ready for customers.

## Step 0: Load Orchestration Skill

Before anything else, load the startup orchestration skill for loop management guidance:
```
Skill('saas-startup-team:startup-orchestration')
```

Run the reusable health preflight before any discovery or implementation dispatch:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/health-preflight.sh" --require-gh --check-sync
```

In Codex, add `--require-codex`. Treat blocker findings as environment blockers with the
reported remediation; warnings can be logged and the workflow may continue when the
affected capability is not needed.

Before any command that may write project state (including market scouting, `/bootstrap`,
state initialization, or Git initialization), claim the startup-session lease:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --acquire "startup:${PWD}" --state-dir .startup/leases \
  --owner-file .startup/leases/.owners/startup.owner --ttl-seconds 1800
```

The owner file is the session identity. Every later heartbeat and release uses this exact
key, state directory, and owner file, even when those operations run in different shell
processes. If acquisition refuses because another owner is live, do not run market
scouting, bootstrap, change state, initialize Git, or dispatch a worker. Resume from its
artifacts or stop. Replace a stale owner only with `--replace-stale --reason
"<heartbeat/log evidence>"` after inspecting its heartbeat and output files.

Heartbeat after idea capture, mutable initialization/commit, every founder phase, and
every verified handoff transition:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --heartbeat "startup:${PWD}" --state-dir .startup/leases \
  --owner-file .startup/leases/.owners/startup.owner
```

On solution signoff and every handled terminal failure or cancellation, release with the
same arguments and `--release`. Do not leave an acquired startup lease to expire merely
because initialization or a worker failed.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --release "startup:${PWD}" --state-dir .startup/leases \
  --owner-file .startup/leases/.owners/startup.owner
```

After a concrete idea or handoff exists, load
`${CLAUDE_PLUGIN_ROOT}/references/workflows/routing-telemetry.md`. Reuse one run ID per
delivery attempt; Codex launch events are automatic, while Claude role phases use the
privacy-safe event contract from that reference.

## Step 1: Capture the SaaS Idea

If the user hasn't already described their SaaS idea, first try market scouting instead of
blocking on new feedback. The scout uses configured external market evidence when available
and falls back to internal demand discovery when browsing/source data is unavailable:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/market-scout.sh"
```

If `.startup/demand/market-scout.jsonl` contains candidates, use the top-ranked candidate
as the initial SaaS/customer need and write `docs/business/brief.md` from its
`target_customer_segment`, `discovered_need`, evidence, desired outcome, selected
acceptance packs, and non-goals. Only ask the investor when no demand evidence exists:

Before yielding for that answer, release the startup-session lease. After the investor
responds, reacquire it with the same command from Step 0 before writing the brief or
initializing state. Do not hold a live lease across an unbounded human wait.

> What SaaS product should we build? Describe the core idea, target customers, and the problem it solves.

Once a concrete need is selected, mint/export `SAAS_RUN_ID` with `agent-events.sh
new-run-id`. The initial product/architecture work is deep; later implementation
handoffs are classified separately and reuse the same ID only within that attempt.

## Step 2: Initialize Project Directory

**Re-initialization guard (MED-4):** If `.startup/state.json` already exists, show the current state (iteration, phase, handoff count, and `status`) and ask the investor:
> An existing startup session was found at iteration N (phase: X, status: Y). Would you like to:
> 1. **Resume** the existing session
> 2. **Reset** and start fresh (this will delete all previous progress)

If resuming, run `/bootstrap` first (idempotent — ensures docs/ structure exists for migrated projects). If `status == "paused"`, clear the paused flag before continuing:

```bash
if [ "$(jq -r '.status // empty' .startup/state.json)" = "paused" ]; then
  jq 'del(.paused_at, .paused_reason) | .status = "active" | .resumed = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
    .startup/state.json > .startup/state.json.tmp \
    && mv .startup/state.json.tmp .startup/state.json
fi
```

Then skip to Step 3 with the existing state.

Run `/bootstrap` first (idempotent — safe to re-run). This creates:
- `docs/` subdirectories: `research/`, `legal/`, `architecture/`, `ux/`, `seo/`, `business/`
- `.startup/` subdirectories: `handoffs/`, `reviews/`, `signoffs/`, `go-live/`
- `.startup/workflows/` registry/spec files (git-trackable workflow contracts)
- `.gitignore` entries for ephemeral `.startup/` state
- `## Project Knowledge` and `## Workflow Guidance` sections in CLAUDE.md

Then create the loop-specific files in `.startup/` and the durable human task file in `docs/`:

```
.startup/
├── state.json            ← Initialize loop state
├── workflows/            ← Git-trackable workflow registry/specs
├── handoffs/             ← Ephemeral, not git-tracked
├── signoffs/             ← Ephemeral, not git-tracked
├── reviews/              ← Ephemeral, not git-tracked
└── go-live/              ← Ephemeral, not git-tracked

docs/
└── human-tasks.md        ← Git-tracked investor action list
```

Initialize `state.json`:
```json
{
  "schema_version": 2,
  "iteration": 0,
  "max_iterations": 20,
  "phase": "research",
  "active_role": "business-founder",
  "status": "active",
  "started": "<current ISO timestamp>",
  "archived_through": 0,
  "latest_handoff": 0
}
```

`schema_version: 2` opts in to the compaction system: old `handoff_NNN_*` keys get archived to `.startup/state-archive.json` automatically once the inline window (last 10 handoffs by default) is exceeded. See the State Management section of each founder agent for the full list of keys allowed inline — anything outside the allowlist is eligible for archival.

**Never write `active_role: "team-lead"`.** The orchestrator (you) is implicit, not a tracked role. `active_role` must always name the next acting founder/agent — `business-founder`, `tech-founder`, `lawyer`, `ux-tester`, `growth-hacker`, or the `-maintain` variants. Writing `team-lead` triggers `enforce-delegation` on subsequent edits during `/improve`, `/lawyer`, `/ux-test`, and `/growth`, derailing those flows.

Write `docs/business/brief.md` using the user's SaaS idea description (skip if `/bootstrap` already created it).

`/bootstrap` (run first in this step) already created `docs/human-tasks.md` and scaffolded the `.startup/workflows/` registry and spec templates — both idempotent, so there is nothing more to scaffold here. Handoff and brief templates live at `${CLAUDE_PLUGIN_ROOT}/templates/`.

## Step 2b: Initialize CLAUDE.md for Auto-Learning

The PostToolUse hook will auto-populate a `## Learnings` section in the project's CLAUDE.md as agents write handoffs, reviews, and signoffs. Ensure the section exists:

1. If no `CLAUDE.md` exists at git root, create it with:
   ```markdown
   # Project Learnings

   ## Learnings

   <!-- Auto-populated by the saas-startup-team plugin PostToolUse hook -->
   ```
2. If `CLAUDE.md` exists but has no `## Learnings` section, append:
   ```markdown

   ## Learnings

   <!-- Auto-populated by the saas-startup-team plugin PostToolUse hook -->
   ```
3. If `CLAUDE.md` already has a `## Learnings` section, do nothing.

## Step 2c: Ensure Git Repository

The auto-commit hook requires a git repo. Ensure one exists:

1. Check if in a git repo: `git rev-parse --show-toplevel`
2. If **not** in a git repo, guard the broad initial `git add -A` so a stray >50 MB file (or a
   package store the `.gitignore` from `/bootstrap` didn't already cover) can't land in the very
   first commit and make the repo unpushable:
   ```bash
   git init && git add -A
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-staged-size.sh" || {
     echo "Aborting: staged tree has oversized/ignored files (see above). Fix .gitignore + git rm -r --cached, then retry." >&2
     exit 1
   }
   git commit -m "Initial commit before startup loop"
   ```
3. If **already** in a git repo, stage only the startup artifacts, run the staged-size guard, and commit with normal hooks:
   ```bash
   git add -A -- .startup/workflows/ docs/human-tasks.md docs/business/brief.md
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-staged-size.sh"
   git commit -m "Initialize startup loop"
   ```

## Step 2d: Reset Session State

Clean up state from previous sessions to prevent stale data:

1. Remove idle counter files:
   ```bash
   rm -f .startup/.idle-count-* .startup/.idle-handoff-snapshot-*
   ```
2. If resuming an existing session, skip this step (idle counters reflect real state).

## Step 3: Launch Initial Role Phases

The startup-session lease was acquired before Step 1. Heartbeat it now, before the first
dispatch. Do not mint or acquire a second session identity here.

Launch the initial role pair using the **Task tool** (one-shot agents, NOT TeamCreate).
Persistent Agent Teams cannot be dismissed and accumulate as zombie processes. All
dispatches use the same one-shot pattern described in Step 5.

Read `${CLAUDE_PLUGIN_ROOT}/references/workflows/mutation-ownership.md` first. Run the
initial business and architecture phases sequentially under separate role guards: the
business allowlist is its exact research/brief/handoff outputs, and the architecture
allowlist is only `docs/architecture/architecture.md`. Verify each guard before starting
the next phase. After each successful verification, the supervisor must persist every
verified durable `docs/` file with `commit-artifact.sh`, replay `index-handoff.sh` for
the exact handoff, and run `compact-state.sh` before the next dispatch.

Append started/terminal events around the initial Fable/high business phase and the
Opus/xhigh architecture phase. A separate Codex architecture launch records itself;
record any Sonnet/medium controller phase separately and never credit it with code edits.

1. **Business Founder** — spawn via Task tool with `subagent_type: "saas-startup-team:business-founder"`:
   - Task: Read `brief.md`, research the market (web + Reddit + browser), break the idea into features, write the first handoff to tech founder
   - Has web access, browser access, research tools

2. **Tech Founder** — on Claude Code, spawn via Task tool with `subagent_type: "saas-startup-team:tech-founder-claude"` for this architecture-planning phase. For later implementation handoffs, choose exactly one registered type: `saas-startup-team:tech-founder-claude` or `saas-startup-team:tech-founder-codex`.
   - **Claude Code surface:** pick the engine per **"1c. Choosing the implementation engine"** in the startup-orchestration skill. This initial spawn is architecture planning → default to the Claude engine.
   - **Codex surface:** do not route to `tech-founder-claude*` or invoke Claude Code primitives. Run the tech-founder role in the current session using the `tech-founder` skill, or use `scripts/codex-run-role.sh` with the classified profile and a task file for a separate worker.
   - Task: Read `docs/business/brief.md` to understand the product vision. Plan preliminary architecture ideas and write initial thoughts to `docs/architecture/architecture.md`. Do NOT start implementing until you receive a handoff from the business founder. Handoff and brief templates are at `${CLAUDE_PLUGIN_ROOT}/templates/`.
   - Has code tools only, no web access

The initial architecture phase is `PROFILE=deep`; it contains product and architecture
judgment. On Codex, a separate process uses `codex-run-role.sh --role tech-founder
--profile deep` with a task file. Do not downgrade this phase.

**IMPORTANT: Do NOT use TeamCreate.** Agent Teams persistent teammates cannot be terminated once spawned. Use the Task tool for ALL agent dispatches — initial and subsequent. Each Task agent exits cleanly when done.

## Step 4: Start the Loop

Send the initial message to the business founder:

> Read `docs/business/brief.md`. This is our investor's SaaS idea. Your job:
> 1. Research the market, competition, and customer pain points (save to `docs/research/` in Estonian)
> 2. Research similar solutions in other countries — extract features, UX patterns, and pricing from international competitors (save to `docs/research/rahvusvaheline-analuus.md`)
> 3. Check Estonian legal requirements for this type of business
> 4. Break the idea into prioritized features
> 5. Describe proposed workflow-spec deltas for non-trivial routes, jobs, state machines, payments, onboarding, support intake, or operator workflows in the handoff. The tech founder writes the specs.
> 6. Write the first handoff to tech founder: `.startup/handoffs/001-business-to-tech.md`.
> 7. Add any human-only tasks to `docs/human-tasks.md`
> 8. After writing the handoff, send a message to the team lead: "Handoff 001 ready for tech founder." The supervisor updates state.
>
> Handoff and brief templates are at `${CLAUDE_PLUGIN_ROOT}/templates/`.

## Step 5: Relay Handoffs Between Founders

**This is your core loop responsibility.** When a founder signals "Handoff NNN ready for [other founder]", you MUST relay it with an explicit, self-contained task message. The receiving founder's context accumulates across iterations — they may have auto-compacted and lost earlier details. Every relay message must be complete enough to act on WITHOUT relying on prior conversation history.

**NEVER write handoffs yourself.** The team lead is an orchestrator, not a founder. Even when the investor gives specific technical instructions, ALWAYS route them through the appropriate founder. The business founder has accumulated product context (UX patterns, competitor analysis, Estonian nuances, edge cases from browser testing) that the team lead does not have. Pass investor instructions to the business founder and let them write the handoff — they will enrich it with context you lack.

### Agent Lifecycle — Always Fresh, Right-Sized

**Always spawn a fresh agent for every relay.** Never reuse agents — context bloat from prior handoffs degrades agent quality. Each dispatch starts with a clean context window.

Before spawning a new agent, claim a lease for the exact relay/work unit:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/single-flight.sh" \
  --acquire "handoff:${handoff_number}:${target_role}" \
  --state-dir .startup/leases \
  --owner-file ".startup/leases/.owners/handoff-${handoff_number}-${target_role}.owner" \
  --ttl-seconds 1800
```

If the lease is active, do not re-dispatch. Check its heartbeat, logs, and expected output
artifact; long-running LLM, report, browser, test, or deploy work is expected when the
heartbeat advances or logs show progress. Replace a stale owner only with
`--replace-stale --reason "<heartbeat/log evidence>"`, which writes an audit note. Never
terminate broad process patterns as a routine recovery step; exact process termination is
allowed only after the lease and heartbeat prove staleness.

After each worker returns, heartbeat with the same key and `--owner-file`. Once its
expected artifact is verified, release that relay lease. Release the startup-session
lease when solution signoff is reached or on any handled terminal failure; acquisition,
heartbeat, and release may run in separate shell processes because the owner token is
persisted in the owner file.

**Do NOT use TeamCreate for relays.** TeamCreate spawns persistent teammates that cannot be dismissed — they accumulate as zombie processes eating ~500MB each. Use the **Task tool** which spawns one-shot agents that exit cleanly when done.

**Fresh spawn via Task tool** — select the exact registered type for the role:
`saas-startup-team:business-founder`, `saas-startup-team:tech-founder-claude`, or
`saas-startup-team:tech-founder-codex`. Pass all of the following in the Task prompt:
- The agent's role identity: "You are the {role} of an Estonian SaaS startup. You speak {language}."
- The full relay message (same self-contained message you'd send to a persistent teammate)
- The token-frugality instruction: read only what the task needs, in targeted ranges (not whole-file dumps), and never re-read content already in context
- Instruction: "After completing your work and writing the handoff/review/signoff file, report back with a summary of what you did and the filename."

Every Claude dispatch gets a privacy-safe started and terminal event using the actual
registered model/effort and the current semantic profile. After each supervisor check,
commit, QA guard, and state transition, append a progress status event. Do not include a
handoff path, prompt, project name, issue text, or diff.

### Sync vs. async dispatch

Agent/Task tool calls default to **synchronous** — the call returns when the subagent finishes, and you act on the result immediately. This is the correct default for the relay loop. **Do not pass `run_in_background: true` unless you genuinely need to fire-and-forget.**

If you *do* run a subagent in the background (long-running browser test, heavy research), you must yield control correctly while waiting:

1. Launch with `run_in_background: true` — note the returned `agentId`.
2. Use `ScheduleWakeup` with `delaySeconds: 270` (stays inside the 5-min prompt-cache window) to poll for completion.
3. On wakeup, check the agent's output file or re-read `state.json`. If still running, schedule the next poll.

The Stop hook recognizes the yield two ways: a `ScheduleWakeup` PostToolUse hook drops a short-lived `.startup/.yielding` marker the moment you schedule the wakeup, and the hook also inspects the transcript. The marker is authoritative — it survives the transcript flush race that used to make the hook block every yield anyway — and self-expires when the wake fires, so it can't disable the block. You don't manage the marker; just call `ScheduleWakeup`. Skip the ScheduleWakeup step and the hook will block you on every end-of-turn until a solution signoff exists.

**Never dispatch async subagents in a tight loop without `ScheduleWakeup`.** Without it, the orchestrator has no way to wait and will thrash against `check-stop.sh`, burning tokens on keepalive chatter.

**Right-size the task.** Each agent dispatch must be a cohesive unit of work that produces exactly ONE deliverable file (handoff, review, or signoff). The sweet spot is 15-30 minutes of agent time.

| Scenario | Dispatches |
|----------|-----------|
| 1-2 feature handoff | 1 agent |
| Feedback with 3-4 independent fixes | 1 agent (fixes are small, bundle them) |
| 2 large independent features | 2 agents, one per feature, each writes its own handoff |
| Browser review of implementation | 1 agent |

**NEVER micro-delegate.** Do NOT spawn separate agents for each individual fix. Bundle all fixes from a review into a single agent dispatch. If a task doesn't produce a file (handoff, review, signoff, or doc), it shouldn't be a separate agent — fold it into the next real task.

### When Business Founder signals "Handoff NNN ready for tech founder":

The supervisor updates `.startup/state.json` for the completed brief (iteration/phase/
active role only), heartbeats and releases the business relay lease, then classifies the
handoff file with `delivery-route.sh classify --mode autonomous`. Exit 2 stops; exit 20
sets `PROFILE=deep`. A mechanical result may run only an exact named script. Pass the
accepted profile and stable routing reasons to the selected tech role, then send:

Before this tech dispatch, execute the tech role-guard and trusted-commit preflights in
`${CLAUDE_PLUGIN_ROOT}/references/workflows/mutation-ownership.md`. Allow only the exact
source/test/workflow-spec paths approved by the handoff plus the expected tech handoff.
After return, verify the role guard before diff containment.

> **New task: Implement handoff NNN.**
> Execution profile: `{PROFILE}`. A Codex controller must pass this exact profile to
> `scripts/codex-implement.sh`; a separate Codex role uses `codex-run-role.sh`.
> Read `.startup/handoffs/NNN-business-to-tech.md` for full requirements.
> Read affected `.startup/workflows/WORKFLOW-*.md` files. Implement any proposed workflow-spec delta from the handoff; the tech founder is the spec writer.
> Read `.startup/state.json` for current iteration and phase.
> Check `docs/architecture/architecture.md` for your previous architecture decisions.
> Implement the features, then write your handoff to `.startup/handoffs/{NNN+1}-tech-to-business.md`.
> In your handoff, list affected workflow spec files and any route/job/state/handoff-contract changes you made.
> Set 10s timeouts on all HTTP calls. If a service is unreachable after 3 retries, document the failure and move on.
> After writing the handoff, message the team lead: "Handoff {NNN+1} ready for business founder."

### When Tech Founder signals "Handoff NNN ready for business founder":

Before QA, the supervisor commits the exact implementation diff after deterministic
checks, then opens a review-only mutation window:

For a light autonomous attempt, inspect the guarded working tree with shared
`check-diff --base "$ATTEMPT_BASE"` before committing. Continue only when it remains light and
`ui_touch=false`. Otherwise write a versioned escalation artifact, discard only this
clean-start delivery diff, and rerun the tech phase once with `PROFILE=deep`; do not
dispatch QA or repeat the light-to-deep transition.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/supervisor-commit.sh" \
  --message "tech-founder: handoff ${handoff_number}" --check ./check.sh \
  --trust-receipt "$COMMIT_TRUST" --auth-stdin <<<"$MUTATION_AUTH"
QA_AUTH=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/mutation-auth-token.sh")
QA_GUARD="$(git rev-parse --git-path "saas-startup-team/qa-handoff-${handoff_number}.json")"
QA_REVIEW=".startup/reviews/handoff-${handoff_number}-${run_id}.md"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-mutation-guard.sh" \
  --snapshot "$QA_GUARD" --auth-stdin --allow "$QA_REVIEW" <<<"$QA_AUTH"
```

If the gate fails, do not dispatch QA. Otherwise update state as supervisor, read the
handoff to extract the localhost URL and port, then send to business founder with
`subagent_type: "saas-startup-team:business-founder"`:

Before that QA dispatch, the supervisor must replay `index-handoff.sh` for the verified
tech handoff and run `compact-state.sh`; guarded PostToolUse hooks deliberately deferred
both operations.
> **New task: Review handoff NNN.**
> Read `.startup/handoffs/NNN-tech-to-business.md` for implementation details.
> Read any workflow specs referenced by the handoff and use their QA cases as a test oracle. If code reveals an undocumented workflow, record the missing-spec finding in the review; do not edit the registry.
> If the handoff is built on a `docs/legal/` analysis, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/legal-verdict-gate.sh" <doc>...` on it and apply the same hedged-verdict rules as `/improve`'s QA step (conditional wording only — never state a hedged claim as fact).
> Read `.startup/state.json` for current iteration and phase.
> Open browser to `{localhost URL from handoff}` and verify the implementation visually using Playwright.
> Write exactly one review artifact at the supervisor-provided `$QA_REVIEW` path. Do
> not replace or delete any other review. Include an explicit
> `PASS` or `FAIL` verdict and, for `FAIL`, all feedback needed for the next brief.
> After writing, message the team lead: "Review complete."
> This is review-only: do not write a handoff or signoff and do not modify source,
> tests, workflow specs, or state.

Immediately after the reviewer returns, run
`delivery-mutation-guard.sh --verify "$QA_GUARD" --auth-stdin <<<"$QA_AUTH"`. Reject any unauthorized mutation;
only then read the verdict. On `FAIL`, dispatch a fresh business-founder brief phase to
turn the verified review into the next business-to-tech feedback handoff; that separate
phase uses a business role guard and may write only the exact brief/handoff with proposed
workflow-spec deltas. On `PASS`, the
supervisor mechanically materializes the roundtrip signoff from the verified PASS review,
updates supervisor-owned state, and releases the relay lease.

Append one authoritative terminal handoff event only after the implementation commit,
QA guard, and PASS/FAIL outcome agree. Every handled failure, blocked relay, or cancelled
session receives an explicit terminal outcome; a worker process exit is not completion.

### After Roundtrip Signoff

When the verified business-founder review is PASS and the supervisor has materialized the
roundtrip signoff:
1. Announce the signoff result to the investor (brief one-liner)
2. **Immediately dispatch the business founder** to write the next feature handoff — do NOT wait for investor input
3. The business founder should read their research docs and the brief to decide the next priority feature
4. Only pause the loop if iteration limit is approaching or the business founder signals solution signoff

Every next-feature dispatch uses and verifies a business role guard from
`mutation-ownership.md`; only its exact new handoff/brief artifacts are allowed.

### Why explicit relay matters

Every relay spawns a **fresh agent** with an empty context window — the founder has no memory of prior handoffs or messages. The relay message must therefore contain ALL information the founder needs to act: file paths, state references, and behavioral reminders. State lives in the handoff files and `.startup/state.json`, never in conversational memory.

## Loop Control

The loop continues until the business founder writes `.startup/go-live/solution-signoff.md`. The Stop hook enforces this after iteration 2+ — earlier iterations allow free exit for testing.

**Iteration limit**: If `state.json` iteration reaches `max_iterations` (default: 20), alert the human investor and ask whether to continue or wrap up.

**Deadlock handling**: If either founder sends you a message saying they're stuck, escalate to the human investor with context about the deadlock.

## Communication to Investor

Investor-communication language: see `${CLAUDE_PLUGIN_ROOT}/templates/communication.md`.
