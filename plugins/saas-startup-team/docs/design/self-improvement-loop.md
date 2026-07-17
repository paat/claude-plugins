# Design Spec — Self-Improvement Loop (Live Issues + Session History)

Status: IMPLEMENTED (rev 4 — automatic two-model lesson review, optional manual override,
authoritative root-terminal event harvesting)
Plugin: saas-startup-team
Author: design session 2026-06-22

---

## 1. Goals

Two end goals, each served by one loop:

1. **Meet customer demand** — *this* SaaS gets better (Loop A, product).
2. **Minimize investor involvement** — *every* SaaS the team builds needs the
   human to step in less over time (Loop B, plugin/autonomy).

Hard constraints: (a) never flood agent context with tokens; (b) only **generic,
de-identified, paraphrased** improvements reach the plugin repo — never project
specifics or customer data; (c) automatic review must fail closed, with manual review
available as an explicit override rather than a required gate (see §4).

---

## 2. Signal hierarchy (what we learn from, ranked)

Internal QA catches correctness, not *value*. The two strongest signals are real
customer behaviour and **points where the investor had to steer** — the latter is
the literal measure of the autonomy we want to remove.

| Priority | Signal | Source | Serves |
|----------|--------|--------|--------|
| **P0** | Customer behaviour: non-payment & errors | nightly replay/monitor (production) | Loop A (demand/UX/logic) |
| **P0** | **Investor interventions** | session logs: interrupts, corrections, `/nudge`, manual edits | **Loop B (autonomy)** |
| P0 | Customer feedback | investor relay + GH issues | Loop A |
| P1 | Agent friction (thrash, repeated tool failures, dead-ends) | session logs | Loop B |
| P1 | Production failures hitting users | `monitor-nightly` | Loop A |
| P2 | UX-test / a11y findings | `/ux-test` | Loop A |
| **P3 (low)** | Tribunal / code-review findings | `tribunal-review` | merge gate only; not a learning driver |

**Pre-launch vs live:** a live product (aruannik) yields P0 customer behaviour. A
pre-launch product (varustame) yields no customer data **but full session
history** — so the session-log scraper (§5) is the universal signal that works
for every project regardless of launch status.

---

## 3. The two loops

```
   PRODUCTION (live)            SESSION LOGS (every project)
   monitor/replay notes         interrupts · corrections · /nudge ·
   funnel · payments · errors    manual edits · thrash · tool failures
          │                              │
          ▼                              ▼
   ┌──────────────────────────────────────────────────┐
   │ AUTOMATED harvester (own context, nightly cron)    │
   │  distill → genericity+scope gate → de-identify →   │
   │  PII gate → dedup vs target repo                   │
   └───────────────┬───────────────────┬───────────────┘
   project-specific│                   │ generic / transferable
                   ▼                   ▼
   LOOP A — PRODUCT (project repo)   LOOP B — PLUGIN (paat/claude-plugins)
   • product backlog issues          • paraphrased, de-identified IMPROVEMENT issue
   • verbatim quotes OK (local)      • NO customer data, NO project nouns
   • AUTONOMOUS via /goal-deliver    • selection criterion: "would this have
   • meets customer demand             removed a future investor intervention?"
                                              │
                                     ┌────────┴──────────────┐
                                     │ AUTOMATIC REVIEW       │
                                     │ Opus/xhigh; conditional│
                                     │ Sol/xhigh arbitration  │
                                     └────────┬──────────────┘
                                              ▼
                                     AUTOMATED implement (/lessons-deliver on plugin)
                                     → lesson becomes plugin code/prompt/hook
```

The normal path is automated. Loop A stays local (low privacy risk). Loop B writes to
the public plugin repo — hence the non-negotiable PII gate (§4) before any write and the
bounded, fail-closed review stage before implementation.

---

## 4. Automatic review + automation boundary

`lesson-auto-review.sh` reviews at most three open `lesson-candidate` issues per pass.
Each candidate gets a fresh isolated Opus/xhigh verdict. A structurally valid,
high-confidence Opus approval or rejection is decisive without a second model.
Sol/xhigh runs independently only when the Opus verdict is unresolved or structurally
malformed; its decisive verdict approves or rejects, while unresolved or zero-exit
malformed Sol output quarantines the issue. Only nonzero model transport failures and
timeouts leave the candidate queued for retry. `/lessons-review` remains available for
explicit manual inspection or override, but normal delivery does not wait for it.

The bounded model input contains the complete title/body or leaves the issue queued. Before
mutation, the reviewer re-fetches and matches the exact content digest; a checked
digest marker is then required again by delivery listing and claiming.

**Non-negotiable automated gate (safety, not burden):** a hard **PII/secrets
check** (reuse `check-handoff-secrets.sh` pattern) runs before any write to the
public plugin repo. It is the one gate that never relaxes. Paraphrase-only:
verbatim customer quotes, screenshots, URLs, emails, tenant/invoice IDs, raw
error strings, and event names **never leave the project repo**.

This is the minimal-involvement design: routine review is bounded and automated, while a
human can still inspect or override exceptional queue state without becoming a scheduled
dependency.

---

## 5. Signal sources (the harvester inputs)

### 5.1 Production signal (live projects) — REUSE, don't rebuild
aruannik **already runs** a mature nightly monitor + replay (`.monitor/
nightly-state.json`): it simulates non-payers/error-hitters, tracks funnel drops,
payments, pipeline errors, LLM health, and files deduped, grounded issues with
lineage notes to its project repo. The harvester **reads the already-distilled
`nightly-state.json` notes** — not raw handoffs (396 handoffs / 1403 commits = a
token flood). The notes are tiny, grounded (cite session IDs + issue lineage),
and human-readable: the ideal feed.

- The stock plugin `monitor-nightly` (markers + `monitor-checks.sh` producer
  contract) is the generic engine; a project supplies project-specific checks.
- varustame has **no** monitor yet (pre-launch) — wiring stock `monitor-nightly`
  is optional for v1 (it has little production signal anyway).

### 5.2 Session-history scraper (every project) — NEW, the universal signal
Mines Claude Code transcripts at `~/.claude/projects/<escaped-cwd>/*.jsonl` for
**genuine improvement points**, in the spirit of an "insights" pass.

- **Prime signal = investor interventions** (directly measures the autonomy to
  remove): `[Request interrupted by user]`, corrective user turns ("no, do X",
  re-explaining), `/nudge` invocations, manual edits after an agent "finished".
- **Secondary = agent friction:** repeated identical tool failures/retries,
  permission denials, file thrash, hook rejections firing repeatedly (a guardrail
  firing often may mean the *guidance* should change), many iterations to green.
- **Token discipline (critical — logs are large):** aruannik = 74M / 15 sessions.
  The scraper (1) processes **only sessions newer than last run** (watermark),
  (2) **greps for sparse marker lines first** (interrupts/errors/nudge), (3)
  LLM-distills **only the matched spans**, never whole transcripts. Intervention
  markers are rare spikes → cheap to extract from a 74M file.
- **Genuine = recurring:** a single thrash is noise; the same intervention/
  friction class across multiple sessions (or projects) is a candidate.

### 5.3 Customer feedback (live)
Investor relay or GH issue, as today → Loop A; cross-project patterns → Loop B.

### 5.4 Workflow terminal events (every project)

When `.startup/runs/agent-events.jsonl` is supplied, `harvest.sh` never consumes raw rows
directly. It asks `agent-events.sh terminals` for the normalized root `pass-outcome`
projection. Child activity, incomplete roots, conflicting lifecycle records, and raw file
ordering therefore cannot become lesson evidence. Projection or validation failure stops
the event-backed harvest instead of silently treating broken telemetry as an empty signal.

---

## 6. Distill + classify (genericity + scope gate)

Structure every item so the prescription is separable from the fact:

```
Observation:    where the investor intervened / what failed   (fact)
Hypothesis:     why the plugin let it happen                   (inference)
Recommendation: the plugin change that prevents recurrence     (prescription)
Evidence:       concrete instances (session ids / issue ids), ideally cross-project
```

A change is **generic** only if, after stripping project nouns, it still
expresses a reusable pattern *about how the agent team builds SaaS* AND can be
phrased **conditionally** (unconditional "always do X" lessons are rejected as
folk wisdom):

```
When [context], the plugin should prefer/avoid [behavior], because [evidence].
Counterexamples: [where this does not apply].
```

Low-confidence-generic → quarantined to Loop A (local only). The classify +
de-identify step emits a **typed record**, not free text.

**Real generic examples already visible in aruannik's exhaust** (proof the loop
yields signal, not noise):
- *Contradictory validation gates* (#1062: a hard error blocks the exact case a
  soft warning calls valid) → generic logic lesson.
- *Stale failure markers* (#694: set on fail, never cleared on success) → generic
  ops lesson.
- *Fragile agent-output parsing* (#746: monitor grep missed a code-fenced agent
  summary → false-positive failure) → **literally a plugin bug**; exactly what
  should become a `claude-plugins` issue.

---

## 7. Token & cost discipline

The big simplification of the "review → implement" model: approved lessons become
**plugin code/prompt/hook edits**, so there is **no per-dispatch runtime lesson
injection to cap** — the lesson lives in the plugin's static prompts. Token
discipline therefore reduces to keeping the *harvester* cheap:

1. Read distilled monitor notes, not raw handoffs (§5.1).
2. Session logs: watermark + grep-first + distill-matched-spans-only (§5.2).
3. Harvester runs in its **own** context (zero build-agent hot-path cost).

Loop control (so the nightly job can't amplify cost):
- Hard per-run budgets: max sessions scanned, max spans distilled, max issues/
  comments filed per run.
- **Lockfile** (matches existing `flock` cron convention); backoff; explicit skip
  when `gh` auth missing or rate-limited.
- Dedup vs target repo before filing (advisory `gh search` + deterministic
  fingerprint); never auto-supersede.
- (Optional, later) an injected "constitution" of top lessons remains available
  for lessons not yet implemented as code — capped + relevance-gated — but is no
  longer the primary path.

---

## 8. Components

| # | Component | Type | Responsibility |
|---|-----------|------|----------------|
| 1 | `session-insights.sh` + scraper agent | script+agent | watermark + grep-first over `~/.claude/projects/<cwd>/*.jsonl`; distill intervention/friction spans → typed records |
| 2 | `harvest.sh` + `/harvest` cmd | script+cmd | merge normalized root-terminal, session, production, and feedback records → genericity/scope gate → de-identify → **PII gate** → dedup → local candidate artifacts |
| 2a | `lesson-file.sh` | script | exact-enable-flag and repo-pinned public filing boundary; repeat PII gate, advisory issue dedup, bounded writes, and nonzero failure reporting |
| 3 | replay producer for `monitor-nightly` | agent | (live projects) simulate non-payers/error-hitters → findings JSONL via `monitor-checks.sh` contract — **aruannik already has this; generalize it** |
| 4 | `lesson-auto-review.sh` + optional `/lessons-review` | script+cmd | bounded automatic Opus/xhigh review with conditional independent Sol/xhigh arbitration; approve, reject, quarantine, or retry transport failures; manual inspection/override remains available |
| 5 | config keys | `.claude/saas-startup-team.local.md` | `SAAS_PLUGIN_REPO` pin, enable flags, budgets, watermark file, telemetry sources |
| 6 | `lessons-deliver.sh` + `/lessons-deliver` cmd | script+cmd | autonomous implementation of `lesson-approved` issues into the plugin repo: claim → implement (impl subagent) → mechanical diff firewall → tribunal → `run-tests.sh` → dual version bump → PR `Closes #N` → merge on green → ship. Plugin-native (no SaaS gates / deploy-watch); cron-driven. See `lessons-deliver.md`. |
| 7 | per-project cron line | crontab | nightly harvester **and** nightly `/lessons-deliver` under `flock` (matches existing `0 2 * * *` pattern) |

Reuse: `monitor-dedup.sh`, `monitor-nightly`, `check-handoff-secrets.sh`, `pii-gate.sh`
(the firewall's secret scan), `tribunal-review:tribunal-loop` (the lesson quality gate).
Note: `/goal-deliver` is the SaaS-product implementer; lessons land in the plugin monorepo
(no `.startup/`/signoff/Actions deploy), so component #6 `/lessons-deliver` is the
plugin-native implementer — see `lessons-deliver.md` §2.

---

## 9. Wiring (concrete, from container inspection)

- **Plugin (Loop B target):** `paat/claude-plugins`. **`gh` is authed as `paat`**
  with `repo` scope on both containers → can write there (and to `r-53-ou/aruannik`).
- **Projects:** aruannik `git@github.com:r-53-ou/aruannik.git` (live; monitor +
  replay running); varustame `git@github.com:paat/varustame.ee.git` (pre-launch;
  session logs only).
- **Scheduler:** `crontab` exists with an established nightly `flock` pattern
  (`0 2 * * * /usr/bin/flock -n /tmp/<x>.lock -c '…'`). Add one harvester line per
  project container.
- **Session logs:** `/config/.claude/projects/-mnt-data-ai-est-biz-aruannik/`
  (74M/15) and `…-varustame-ee/` (808K/2). Line `type`s include `user`,
  `assistant`, `system`, `mode`, `last-prompt` — interventions live in `user`
  turns and interrupt markers.
- **Pin safety:** Loop B writes require explicit `SAAS_PLUGIN_REPO=paat/claude-plugins`
  + enable flag; the default `gh` target is the local project repo (Loop A).

---

## 10. Defaults (override in config)

- Filing improvement issues: **fully automated** (label `improvement` + domain
  `ux·logic·demand·process·tooling`).
- Review: automatic, at most three candidates per pass; a high-confidence Opus/xhigh
  approval or rejection is decisive, and Sol/xhigh arbitrates only unresolved/malformed
  Opus output. Only transport failures/timeouts retry.
- Implementation: automatically approved issues flow to plugin-native
  `/lessons-deliver`; `/lessons-review` is optional.
- "Genuine" threshold: a pattern recurs (≥2 sessions, or structurally generic
  from a single clear instance like #746).
- Harvester cadence: nightly via cron under `flock`.
- North-star metric: **investor interventions per project per week, trending down**
  (counted by the scraper as a byproduct).

---

## 11. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| Privacy leak to public plugin repo | Paraphrase-only; PII/secrets hard gate; pinned repo + enable flag; verbatim stays local |
| Bad/over-general lesson | Observation/Hypothesis/Recommendation split; conditional phrasing + counterexamples; bounded independent model review; unresolved cases quarantined; manual override remains available |
| Token flood from logs | Watermark + grep-first + distill-matched-spans-only; read distilled monitor notes not handoffs |
| Cost/API amplification | Per-run budgets, lockfile, backoff, gh-auth skip |
| Replay mutates prod / spends money | Staging + synthetic accounts; non-prod URL enforced; test-mode payments; read-only telemetry |
| Noise issues in plugin repo | Recurrence threshold; dedup before filing; automatic approve/reject/quarantine review; bounded retries only for transport failures |

---

## 12. Follow-up decisions

1. **Pre-launch monitoring** — wire stock `monitor-nightly` before launch only when it has
   meaningful synthetic or operational evidence; session history remains the baseline.
2. **Recurrence threshold** — the current default permits a single structurally generic
   instance (#746-style); automatic review rejects or quarantines weak candidates.
3. **Replay generalization** — aruannik's replay producer remains the reference for a
   future generic `monitor-nightly` producer.

---

> Changelog rev3: dual goals (demand + investor-minimization); investor
> interventions promoted to P0 (Loop B objective); session-history scraper added
> as the universal/pre-launch signal; single review-before-implement gate replaces
> candidate/lesson promotion tiers + auto-graduation; lessons become plugin code
> so runtime constitution de-emphasized; concrete wiring from container inspection
> (repos, `paat` gh auth, cron flock pattern, log paths/sizes); aruannik replay
> reused not rebuilt.

> Changelog rev4: replaced required human approval with bounded automatic Opus/xhigh
> review and conditional independent Sol/xhigh arbitration; made `/lessons-review` an
> optional inspection/override; added quarantine and transport-only retry semantics; made
> normalized root-terminal event projection authoritative for event-backed harvesting.

---

## Implementation status

Tracking issue: **#79** (keep open until the loop runs end-to-end live).

- [x] **v1 — `session-insights.sh`** (local-only intervention extractor). Component #1.
  - Defensive per-line JSON parse; user text unified across string + array
    `{type:text}` blocks; byte-offset watermark with partial-line handling;
    high-confidence signals (`interrupt`, `nudge`, `correction`, `tool_failure`);
    harness command-output wrappers excluded; length + start-anchor gating to kill
    pasted-content false positives; per-file budget (defers, never drops). Runner:
    `/session-insights` (no args; outputs confined to `.startup/insights/`).
  - **Note vs §5.2:** v1 is *pure deterministic* bash/jq — **no LLM**. It parses
    only new (post-watermark) lines, which is why it's cheap; the LLM-distill of
    matched spans described in §5.2 is a later stage, not part of v1.
  - Tests: Suite Z in `tests/run-tests.sh` (golden fixtures incl. real-log shapes).
  - **Precision (measured on real logs):** aruannik → 5 interrupts (all genuine),
    21 tool-failures, **0 false-positive corrections/nudges** after the wrapper +
    anchor fixes. This is the "prove precision before filing" gate codex required.
- [x] **v2 — `harvest.sh` + `/harvest`** (dry-run candidate generator). Component #2.
  - Deterministic safety layer: clusters records by de-identified fingerprint
    (`sha1`), aggregates recurrence, **hard PII/secrets gate** (blocks the whole
    cluster), project-noun → `{{PROJECT}}` de-identification, recurrence
    thresholds per signal, dedup vs `harvest-ledger.json`. Emits
    `candidates.jsonl` (Observation/Hypothesis/Recommendation skeleton) + report.
    **No `gh`, no network, no filing.** Genericity/phrasing is the `/harvest`
    agent plus the downstream automatic review, not the deterministic script.
  - Tests: Suite H (HV1–HV9) in `tests/run-tests.sh` (660 total, all green).
  - End-to-end on aruannik: 26 records → 2 candidates (5 interrupts, 21
    tool-failures), 0 PII-blocked, 0 deduped.
- [x] **v3 — `lesson-file.sh`** (gated public filing). Component (filing stage).
  - Files harvester candidates as `lesson-candidate` issues in the pinned plugin
    repo, but ONLY when `SAAS_LESSON_SYNC_ENABLED=true` AND a repo is pinned —
    otherwise **dry-run** (files nothing). Re-runs the shared PII gate at the
    filing boundary; idempotent via the fingerprint ledger; advisory dedup vs
    open issues; per-run budget. An all-state fingerprint-marker lookup closes the
    create-before-ledger crash window; ledger writes are checked and atomic. PII gate extracted to shared `pii-gate.sh`
    (single source of truth for `harvest.sh` + `lesson-file.sh`).
  - Tests: Suite F (F1–F9) with the mock-`gh` harness (684 total, all green).
  - End-to-end on aruannik stays dry-run by default: 2 candidates → "would file
    2, filed 0", ledger empty, no `gh` contact.
- [x] **v4 — `lesson-auto-review.sh` + optional `/lessons-review`**. Component #4.
  - Reviews at most three verified candidates per pass. A fresh isolated Opus/xhigh
    verdict is primary and decisive when it is a high-confidence approval or rejection;
    unresolved or zero-exit malformed Opus output invokes independent Sol/xhigh
    arbitration. A decisive Sol verdict approves or rejects; unresolved or zero-exit
    malformed final Sol output quarantines. Only nonzero transport failures/timeouts
    retry. Repo pinning, fresh issue verification, idempotent labels/comments, and
    fail-closed GitHub mutations remain mandatory.
  - `/lessons-review` lists the queue and provides explicit approve, close, quarantine,
    or skip overrides without becoming a delivery prerequisite.
- [ ] Validate cross-project recurrence against a larger record sample.
- [x] Auto-implement approved issues via **`/lessons-deliver`** (autonomous,
  cron-driven). The original "`/goal-deliver #N` by hand" path does not fit the plugin
  monorepo — `/goal-deliver` is the SaaS-product implementer; `/lessons-deliver` is the
  plugin-native one (no `.startup/`/signoff/Actions deploy). Script surface fully tested
  (Suite L, mock-`gh`); the nightly cron line is the same runner (folds the cron item
  below). See `lessons-deliver.md`.
- [ ] Deploy the nightly `flock` cron in-container (harvester **and** `/lessons-deliver`)
  so candidates accumulate and approved lessons ship where the sessions live.
- [ ] (replay) generalize aruannik's replay producer for `monitor-nightly`.

The public-repo path remains disabled unless the exact filing enable flag and pinned repo
are present. Local harvesting stays read-only; automated review and delivery operate only
on issues that crossed that filing boundary.
