# Epic #192 dev process — lanes, routing, token budget

Status: approved 2026-07-09 (option: no human gate; owner relies on agent judgment).
Scope: how the 15 children of epic #192 get designed, implemented, and merged —
not what they contain. Constraint driving everything: do not spend Fable-tier
tokens on recurring or trivial work. Budget pools: Claude Max (Fable ≫ Opus ≫
Sonnet burn rates) and ChatGPT Pro (Codex).

## Lanes

### Lane 0 — one Fable spec pass (one-time)
A single Fable session dependency-orders the epic and posts an
implementation-ready spec as a comment on each child issue: acceptance
criteria, files touched, dual-surface (Claude + Codex) requirement, tests,
version bump. Each issue is classified:

- **loop-safe** — deliverable by the autonomous loop; gets the
  `lesson-approved` label immediately (Phase 1/rollout children) or when its
  phase unblocks.
- **self-mod / architecture** — trips the lessons-deliver firewall or needs
  real design; routed to Lane 2.
- **rollout** — ops in a product container; routed to Lane 3.

Recon reading is done by cheap Explore subagents; Fable only writes the specs.

### Lane 1 — autonomous delivery (recurring, cheap)
Nightly cron on this repo runs `/lessons-deliver --once` under `flock`,
headless, **model pinned explicitly to a non-Fable model** (an unpinned
headless run inherits the default model — the main Fable leak vector).
The loop's own machinery (claim → fresh implementer → mechanical firewall →
tribunal → run-tests.sh → dual version bump → PR `Closes #N` → merge on
green) is reused unchanged. Epic children ride the existing `lesson-approved`
label: zero new machinery, at the accepted cost of epic deliveries appearing
in lessons digests alongside real lessons. Verified against
`scripts/lessons-deliver.sh`: hand-labeled non-lesson issues are eligible
(only the label + open state + no linked PR are checked), and
`--bump-version` hardcodes saas-startup-team — acceptable because every Lane 1
child is a saas-startup-team change.

Firewall facts (verified): allowlist is `plugins/*` +
`.claude-plugin/marketplace.json`; self-mod blocklist is
`scripts/lessons-deliver.sh`, `scripts/lesson-*.sh`, `scripts/pii-gate.sh`,
`tests/run-tests.sh`, `commands/lessons-*.md`, and any path containing
`tribunal`. Lane 1 specs must keep diffs inside the allowlist and off the
blocklist.

**Enabling change (one-time, done in the Lane 0 session, outside the loop):**
`tests/run-tests.sh` is itself blocklisted, yet workers must add tests — as
shipped, every test-adding lesson would land `lessons:needs-human`. Fix:
add an auto-discovery hook to `run-tests.sh` that executes
`tests/*.tests.sh`, so workers add tests as new files. The protected harness
stays untouched by workers; tribunal still reviews their test files.

### Lane 2 — architecture lane (Fable designs, never types)
For issues that are new architecture or would trip the self-mod firewall.
Per issue: Fable brainstorm → spec → plan, implementation dispatched to Codex
(`codex exec`, ChatGPT Pro pool) or an Opus subagent, Fable reviews the final
diff only (targeted read, no re-exploration). Merge on green tests + tribunal,
same as Lane 1, just supervised.

### Lane 3 — rollouts
Executed in the product containers (aruannik, vastav, varustame) on those
containers' own sessions and pools, after Phase 2 lands. The spec pass turns
the rollout issues into self-contained runbooks; nothing runs in this repo.

## Routing

| Issue | Lane | Note |
|---|---|---|
| #193 merge policy | 2 | mechanically allowed, but merge-policy changes are what the prompt firewall tells workers to refuse — supervised lane |
| #194 digest/push | 1 | |
| #195 auto-file issues | 1 | |
| #196 memory lifecycle | 1 | |
| #197 reliability floor | 2 | poll/backoff changes touch maintain-loop machinery; policy-sensitive |
| #198 scheduler | 2 | new mission-control plugin |
| #199 budget governor | 2 | new mission-control plugin |
| #200 aruannik rollout | 3 | after #198+#199; runbook written then |
| #201 vastav/varustame rollout | 3 | after #200 beds in |
| #202 handoff bus | 2 | after #198 |
| #203 UX quality gate | 2 | design judgment |
| #204 spend envelope | 1 | labeled immediately — no mission-control dependency |
| #205 demand validation | 1 | labeled immediately; ad-smoke leg refuses without #204's envelope, oldest-first ordering guarantees #204 ships first |
| #206 non-interactive bootstrap | 1 | plugin side only; admission gate (WIP cap, veto) moved into #198's scope |
| #207 lessons-gate decision | Fable direct | decision doc, written last with real data |

Final loop-safe vs self-mod classification is made in the spec pass against
the firewall's actual blocked-path list, not guessed.

## Token rules

- Fable appears exactly three places: the Lane 0 spec pass, Lane 2
  design + final-diff review, and #207.
- All recurring work (loop supervision, implementation, test-fixing, tribunal
  rounds, version bumps) runs on Opus/Sonnet or Codex.
- Every headless/cron invocation pins its model explicitly.
- Codex is the default implementer wherever the surface supports it; the
  Claude-side implementer is the Opus maintain agent, never Fable.

## Reach-back (hard requirement)

Errors observed in product dev containers must reach this repo. Channel: the
existing harvester files de-identified `lesson-candidate` issues here (gated
by `SAAS_LESSON_SYNC_ENABLED` in each product container); approved candidates
flow into the same Lane 1 loop. Process obligations:

- Verify/enable `SAAS_LESSON_SYNC_ENABLED` in all three product containers —
  folded into the #200/#201 runbooks, plus a one-time check at rollout.
- `/lessons-review` approval stays human at digest cadence for now; relaxing
  it is exactly #207's decision, taken at the end of the epic with data.

## Ordering

Phase 1 rides Lane 1 immediately after the spec pass (oldest-first serial
delivery preserves intra-phase order). #198/#199 proceed in Lane 2 in
parallel (different pools). #202 after #198. Rollouts after Phase 2. Phase 3
loop-safe children are labeled up front (oldest-first delivery keeps them
behind Phase 1); #207 last.

## Accepted risks / judgment calls

- Reusing `lesson-approved` for non-lesson issues pollutes lessons digests —
  accepted; extending `lessons-deliver.sh` would itself be a self-mod change.
- No human gate anywhere in Lanes 0–2 (owner decision 2026-07-09); safety
  rails are the loop's mechanical firewall, tribunal, tests, and circuit
  breakers.
- One supervised headless `--once` run validates Lane 1 before the cron is
  trusted nightly.
