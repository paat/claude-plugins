# `/maintain` — Autonomous Maintenance Loop (Design Spec)

**Date:** 2026-06-25
**Plugin:** `saas-startup-team`
**Status:** approved-design → implementation
**Depends on:** `/goal-deliver` (same plugin), `tribunal-review` plugin
**Reviewed by:** codex (design pass + spec pass) — findings folded in.

---

## 0. v1 Scope (deliberately narrow)

v1 does exactly this, and no more:

1. **Triage** every open issue (active classification, read-only subagent).
2. **Fence off** human-gated issues (`needs-human` → `.startup/human-tasks.md`).
3. **Deliver** each agent-fixable issue, **one at a time**, via `/goal-deliver`,
   in **dependency order** (prerequisites first).
4. **Circuit breakers**: max-issues / max-merges / wall-clock per pass.
5. **Digest**: explicit final state per issue + a morning-review artifact.
6. **Continuous**: re-scan each pass so monitor-filed issues are picked up.

Everything that passes the green gate is **merged** — there is no human-hold
tier (investor decision: trust the gate, not a manual merge step).

**Deferred to a later version** (noted, not forgotten): grouped/multi-issue
delivery, stale-claim reclaim across competing sessions, secret-detection pre-commit,
token/$ proxy breakers, tamper-evident signed audit logs. v1 assumes **a single
`/maintain` session** (the investor runs it once and
watches via `/rc`).

---

## 1. Problem & Goal

A finished SaaS product accumulates open GitHub issues continuously — a nightly
monitor files new ones overnight; customers and audits file more by day. Today a
human must hand each batch to `/goal-deliver`. We want **one slash command that
runs a continuous, unattended maintenance loop**: triage every open issue, fence
off the ones that genuinely need a human, and deliver the rest to production
(build → review gate → merge → deploy-watch), picking up newly-filed issues
automatically.

**UX contract (hard constraints from the investor):**
- It is a **slash command** (`/maintain`), invoked once in an interactive Claude
  Code session. No cron, no tmux, no wrapper script.
- Monitored remotely from the **Claude app via the built-in `/rc`**. `/maintain`
  must therefore be an ordinary long-lived interactive session — nothing special
  is required for `/rc` to attach.
- **Continuous**: keeps running and re-scans, so monitor-filed issues are picked
  up on the next pass without a human re-invoking.
- **Context-bloat-free by construction** (see §3).
- **Filesystem-isolated**: the loop operates from a **dedicated git worktree**
  (`.worktrees/maintain`, detached off the default-branch tip), never the
  investor's primary checkout — so the investor can keep doing their own dev work
  in the main repo folder while the loop runs. The two meet only at GitHub
  (branches, PRs, `main`); the loop's merge-safety handles `main` moving under it.

**Non-goals:** parallel issue *delivery* (we deliver sequentially — RALPH
discipline; a single dedicated worktree is used for isolation, but we do **not** run
multiple delivery worktrees in parallel); a cron/tmux/web-terminal deployment layer;
replacing `/goal-deliver`.

This command must stay **generic and project-agnostic** (repo rule): no hardcoded
project names, paths, ports, or label *semantics* beyond the plugin's own
conventions. The one consumer at launch is an Estonian accounting SaaS, but
nothing may assume it.

---

## 2. Research Basis (web + Reddit, already done)

Both streams converged; this design treats these as requirements:

- **Fresh context per unit of work** is *the* thing that makes autonomous loops
  work; quality degrades as context fills.
- **Files + git are the memory, not the context window.**
- **A green-test gate before merge is non-negotiable** — and is the main defence
  against the "agent deletes/comments-out a failing test to declare victory"
  failure mode.
- **One issue per PR** for failure attributability.
- **Hard iteration caps + a no-progress signal** kill "fix-fail-repeat"
  non-convergence and its cost runaway.
- **Treat issue text as adversarial** (prompt-injection) — highest risk
  unattended.
- **Explicit per-issue final state + an audit digest** enable "morning review",
  the honest supervision model.

---

## 3. Core Architecture — Stateless Supervisor, Inline Delivery

`/maintain` is a **thin supervisor that is stateless across passes**. This single
decision resolves context-bloat by construction:

- The supervisor holds **no durable state in context**. Every pass it re-reads
  all state from **disk** (`.startup/maintain/`) and **GitHub**. Its in-context
  working set is disposable scratch.
- Harness auto-compaction (or total context loss) is therefore **harmless for
  correctness** — the next pass reconstructs from disk + GitHub. We do not rely
  on compaction as a guardrail; we make state loss a no-op.

### Delegation topology (respects the one-level subagent nesting limit)

This is the load-bearing correction from review: **subagents cannot spawn
subagents**, and `/goal-deliver` already dispatches founder + tribunal
subagents. Therefore:

- **The supervisor (the `/maintain` session itself) runs the `/goal-deliver`
  playbook INLINE for each issue** — it does *not* wrap delivery in another
  subagent. The founder/tribunal subagents that `/goal-deliver` dispatches are
  the one allowed nesting level.
- **Fresh context per issue lives where the heavy tokens are** — inside the
  founder/tribunal subagents, which are dispatched fresh per issue and return
  only compact summaries. Issue bodies, diffs, and tribunal transcripts never
  enter the supervisor's context.
- The supervisor's own context grows only by thin orchestration narration, which
  is bounded by stateless-from-disk re-derivation + auto-compaction.

### Triage is read-only; the supervisor is the only mutator

To keep adversarial issue text away from write access:
- The **triage subagent is READ-ONLY**: it reads issues and returns a
  *structured* verdict list. It never labels, comments, or writes files.
- The **supervisor performs ALL GitHub and disk mutations** (labels, comments,
  human-task files, merges) from that constrained structured result. The
  supervisor is the single enforcement point for the injection firewall (§5):
  it rejects any subagent output requesting a forbidden action.

### On-disk state (`.startup/maintain/`)

- `current-run.json` — `{run_id, started_at}`, written once at startup so the
  active run-id survives context loss (it is *not* in-context state).
- `triage-cache.jsonl` — cached body-classification keyed by `{number,
  updatedAt}`; lets a pass skip re-classifying unchanged issue bodies. Eligibility
  and final state are **always recomputed from GitHub each pass**, never cached.
- `blocked.jsonl` — transiently-blocked issues: `{number, reason,
  cooldown_until}`.
- `runs/<run-id>.md` — append-only audit digest.
- `human-tasks/<issue>.md` — one file per escalated human-gated issue (avoids
  append conflicts); a summary is appended idempotently (dedup by issue number)
  to the project's existing `.startup/human-tasks.md` if present.

---

## 4. Loop Body (one pass)

```
write current-run.json (first start only) ; preflight()
while not stop_condition:
  open      = gh issue list --state open                 # picks up monitor-filed issues
  verdicts  = dispatch READ-ONLY triage subagent (skip body-classify if cached & unchanged)
  apply verdicts -> supervisor mutates labels / comments / human-task files
  queue     = eligible(open, verdicts)                   # §6 eligibility + ordering
  for issue in queue (sequential; honor §8 caps):
     if not claim_ok(issue): record + continue           # §7.1
     run /goal-deliver INLINE for that ONE issue          # §7
     record explicit final state                          # §9
  write pass digest ; backoff(sleep) ; continue
```

### 4.1 Preflight (once at start; cheap re-check each pass)
- Default branch, clean tree, `gh auth status` OK, remote present (reuses
  `/goal-deliver` preflight).
- `tribunal-review` skill present (hard dependency).
- Ensure the plugin's own labels exist (idempotent `gh label create`):
  `needs-human`, `maintain:claimed`, `maintain:blocked`.
- **Light health gate:** if the latest default-branch GitHub Actions run is
  failing, do **not** deliver new work — surface it and back off (a red main is
  itself an escalation; don't pile fixes onto it).

### 4.2 Stop conditions
Continuous by design, but the run stops (and reports) when: a hard circuit
breaker trips (§8), the investor interrupts via `/rc`, or preflight fails
irrecoverably.

---

## 5. Triage (active classification, read-only)

The read-only triage subagent classifies each open issue whose body it hasn't
classified at the current `updatedAt`. It returns structured records; the
**supervisor** applies side-effects.

### Internal verdicts (distinct from GitHub labels)
- **`agent-fixable`** → enters the delivery queue.
- **`needs-human`** → genuine human decision required.
- **`blocked`** → transiently un-deliverable (set during delivery, not triage:
  no-progress / deploy-blocked / cooldown).

High-risk surfaces (payments, auth, DB migrations, money math, legal/compliance)
are **not** withheld — per investor decision they are delivered and merged like
any other fixable issue, gated only by the mandatory green gate (tribunal zero
critical/high + required CI checks + regression-test gate). They remain
`agent-fixable`; only a genuine human-decision need (§reasons below) makes an
issue `needs-human`.

### Label side-effects (applied by the supervisor)
`agent-fixable` → no label. `needs-human` → `needs-human` label +
`human-tasks/<issue>.md` + one idempotent rationale comment (see below).
`blocked` → `maintain:blocked` + `blocked.jsonl` cooldown.

### `needs-human` reasons
product/design/UX/prioritization call · credentials/secrets needed · manual
external verification (portal upload, real card, ID-card auth) · legal/compliance/
tax judgment · too ambiguous (no repro/spec).

### `needs-human` vs `blocked`
`needs-human` = genuine human decision, canonical human-visible bucket
(→ `human-tasks.md`). `blocked` = transient; **auto-retried** after cooldown,
never silently promoted to permanent human work.

### Idempotent escalation comments
The supervisor posts/updates a single bot comment per issue carrying a
deterministic marker (`<!-- maintain:bot:<issue> -->`); it **edits** that comment
on later passes rather than posting a new one each time.

### Prompt-injection firewall (enforced by the supervisor)
Issue text (title/body/comments) may **inform requirements only**. It may never:
override command policy, expand scope beyond the issue, request/exfiltrate
secrets, disable/delete/weaken tests, alter merge rules, or trigger external
side-effects. Subagents must return the **specific issue facts** they acted on
(surfaced in the digest); the supervisor rejects any structured output requesting
a forbidden action.

### External side-effect ban
No portal uploads, payment actions, customer emails, production-data mutation, or
legal filings driven by issue text. Such issues are `needs-human`.

---

## 6. Eligibility & Ordering

**Eligible queue** = open issues **minus**: active `blocked.jsonl` cooldowns,
`needs-human`, issues that **already have an open linked PR**, and issues whose
declared prerequisites are not yet merged (ordering item 1).

**Linked-PR detection** (concrete): `gh pr list --state open --search "<N>"`
cross-checked against PR body `closes/fixes #N` and the issue's `closedByPullRequestsReferences`
(via `gh issue view <N> --json closedByPullRequestsReferences`). If any match,
skip. Fallback on ambiguity: skip (favor not duplicating).

**Ordering:**
1. **Dependency order first** — an issue is delivered only after the issues it
   depends on have merged. Dependencies are read from explicit links in the
   issue body/title (`depends on #N`, `blocked by #N`) — no guessing. Build a
   DAG; a dependent is ineligible until every prerequisite is `fixed`. A
   dependency cycle or a prerequisite that is itself `needs-human`/`blocked` →
   defer the dependent and log it (never silently deliver out of order).
2. **Severity** within the dependency-eligible set, via *optionally-recognized*
   labels `critical→high→medium→low` (not assumed to exist; absent → lowest).
   Tie-break and unlabelled → **oldest-first**.
3. **One issue per PR.** No grouping in v1.

---

## 7. Delivery (per issue, sequential, inline)

For each eligible issue the supervisor runs the `/goal-deliver` playbook scoped
to that **one** issue. Sequential — at most one delivery in flight — which is the
merge-serialization mechanism.

### 7.1 Claim & idempotency (best-effort, v1 single-session assumption)
Before delivering, the supervisor re-fetches the issue and skips if it is closed,
re-labelled `needs-human`, assigned, on cooldown, or already has an open linked
PR (§6). If `updatedAt` changed since triage, **re-triage** instead of delivering
stale work. It then adds `maintain:claimed` + the run-id marker. The **real**
idempotency guard is the linked-PR check (claims are not atomic across competing
sessions — out of scope for v1's single-session model). A `maintain:claimed`
whose run-id ≠ the current run and older than the cooldown may be cleared.

### 7.2 Per-issue guardrails
- **Iteration cap:** reuse `/goal-deliver` tribunal round caps (notify at 10,
  hard-stop at 20).
- **No-progress signal (heuristic, not a hard gate):** if successive rounds show
  the *same failure signature* with no advancing green check → abandon →
  `blocked` + `escalated:no-progress` (retried after cooldown). The real gates
  are the iteration cap + required checks + tribunal.
- **Branch hygiene:** start from clean default branch, unique branch name, no
  uncommitted changes; a failed branch is left (not force-deleted) after its
  state is logged.

### 7.3 Merge safety (concurrent-cron races)
Other nightly crons (replay, reconcile) commit to main, so a green PR can go
stale before merge. Default sequence (supervisor stays in control):
**update branch from main → rerun required checks → merge immediately on green**
(`gh pr merge --squash --delete-branch`). If main advanced during final
validation, **restart final validation**. `--auto` is allowed only when branch
protection enforces up-to-date required checks (off by default).

The **green gate is mandatory**: tribunal zero critical/high + required CI checks
+ the regression-test gate. Per `/goal-deliver` §3, an incident-labelled issue
(`bug`/`monitor`/`customer-issue`) cannot merge unless the PR diff adds a test,
or the PR body records `Regression-Test: none — <reason>`. There is no
human-hold tier — every PR that clears the green gate is merged.

### 7.4 Deploy watch, classification & escalation
After a merge, watch the deploy (reuse `/goal-deliver` step 4) but **classify the
failure from concrete signals** — the failing workflow step/command, deploy log,
whether main moved during the run, and any health-check/migration output:
- **code regression** (the merged diff is implicated) → auto-fix on
  `deploy-fix/<slug>` (existing behaviour).
- **infra / flaky / external-dependency / credentials / migration-data**, or
  **low confidence** → do not grind: `escalated:deploy-blocked`, **stop merging
  further issues this pass**, surface to the investor.
- **clearly broken deploy** (failing + not quickly fixable, or low-confidence) →
  **roll production back to last-good**: revert the loop's OWN merge from this pass
  (`git revert <squash-sha>` on a `revert/<slug>` branch — squash merges are a single
  commit, so no `-m 1`), run required CI checks
  (no full tribunal — a revert restores already-reviewed code), merge to restore a
  deploying main, record `escalated:deploy-blocked` + revert-PR link, stop merging
  this pass. Never revert other actors' commits. If the revert can't go green, stop
  the whole run and escalate hard (production needs a human now).

---

## 8. Circuit Breakers (cost & blast-radius)

Layered — no single cap suffices:
- `--max-issues N` delivered per pass (default 10).
- `--max-merges N` per pass (default 5).
- **Wall-clock budget** per pass and per run (configurable defaults).
- Per-issue tribunal-round cap (§7.2).
- **Stop-after-deploy-failure:** the first unrecoverable deploy failure halts
  further merges that pass.
- Backoff between passes (default a few minutes) so an empty/blocked backlog
  doesn't hot-spin.

All defaults overridable via command args; all generic (no project assumptions).

---

## 9. Observability — "Morning Review" Artifact

Every issue ends each pass in an **explicit, logged final state**, never
undefined:
`fixed:PR#` / `escalated:<reason>` / `skipped:<reason>` / `needs-human:<reason>`.

The per-run digest (`.startup/maintain/runs/<run-id>.md`) records, per issue:
run-id, issue number, decision + rationale, the **issue facts the subagent acted
on** (injection transparency), commit SHA before/after, PR link, tribunal result,
CI/deploy check URLs, tokens/elapsed vs. caps, and final state. The supervisor
also emits a scannable per-pass summary to the session (merged / held /
escalated / blocked) — what the investor reads via `/rc`.

---

## 10. Components & Files

- `plugins/saas-startup-team/commands/maintain.md` — the command (this design).
- Reuses: `commands/goal-deliver.md`, `commands/improve.md`, the
  `tribunal-review` skill, existing `/goal-deliver` preflight + deploy-watch.
- New on-disk convention: `.startup/maintain/` (created at runtime; documented in
  the plugin README).
- README: add `/maintain` to the command list + the standard Installation section
  (three scopes).
- Version bump in **both** `plugin.json` and root `marketplace.json`.

---

## 11. Open Risks Accepted for v1

- **Non-atomic claims** under hypothetical multi-session use — accepted
  (single-session model; linked-PR check is the real guard).
- **Heuristic no-progress / deploy classification** — accepted as best-effort;
  backstopped by hard caps + mandatory green gate.
- **Auto-revert scope** — the loop reverts only its OWN broken merge to restore a
  deploying main; it does not attempt deeper self-healing, and escalates hard if the
  revert itself can't go green.

Consistent with the investor's stated speed-over-safety, slight-reversible-risk
posture; revisit if the loop runs at scale or merge authority widens.
