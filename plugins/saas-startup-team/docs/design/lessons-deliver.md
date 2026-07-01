# Design — `/lessons-deliver`: autonomous implementation of approved lessons

**Status:** approved design (2026-06-26). Implements the last open step of the
self-improvement loop (issue #79): auto-implement approved lessons with **no manual
trigger**. Codex-reviewed at the design stage; accepted findings folded in (§ Hardening).

Reads alongside `self-improvement-loop.md` (the loop spec) and reuses the safety
patterns of `commands/maintain.md`.

---

## 1. Problem & scope

The loop already ships, on demand:

```
/session-insights → /harvest → lesson-file.sh (gated filing of `lesson-candidate`
issues to the PINNED plugin repo) → /lessons-review (human gate: --approve N
relabels lesson-candidate → lesson-approved)
```

The single remaining step is **implementation**. Today the investor must manually run
`/goal-deliver #N` per approved lesson. This design removes that manual trigger: a
scheduled, in-container runner picks up `lesson-approved` issues and delivers each into
the plugin repo end-to-end (implement → review → test → version-bump → PR → merge).

**The human gate is unchanged.** The investor's only action stays approval in the
`paat/claude-plugins` issue queue (`/lessons-review --approve N`, or the GitHub label).
Everything after approval is autonomous.

## 2. Why not literally `/goal-deliver`

Lesson issues live in the **plugin monorepo**, not a SaaS product. This repo has **no
`.startup/`, no `solution-signoff.md`, no CI/Actions deploy pipeline**. `/goal-deliver`
stops at its 2nd preflight gate (solution-signoff) and its deploy-watch has nothing to
watch. The plugin's "deploy" *is* merge-to-main + version bump. Tribunal **is** installed.
The test gate is `bash plugins/saas-startup-team/tests/run-tests.sh`.

So `/lessons-deliver` borrows `/maintain`'s **safety skeleton** (stateless-from-disk
supervisor, dedicated worktree, circuit breakers, claim/idempotency, merge-on-green, run
digest, prompt-injection firewall) and replaces the SaaS body. Dropped from `/maintain`:
triage, needs-human classification, founders/Estonian, deploy-watch / classify / rollback.

## 3. Components

| Component | Type | Responsibility |
|-----------|------|----------------|
| `commands/lessons-deliver.md` | Claude playbook | the supervisor: per-pass orchestration, dispatch implementer, drive tribunal, decide merge/block |
| `scripts/lessons-deliver.sh` | bash | deterministic, script-tested surface: eligibility selection, repo-pin validation, claim/idempotency, blocked-state, the mechanical **diff firewall**, version-bump-both-files, startup reconciliation, gh-failure classification |
| new test Suite in `tests/run-tests.sh` | bash (mock-`gh`) | covers the script surface (mirrors Suite R harness) |

Reuse: `pii-gate.sh` (secret scan of the diff), `tribunal-review:tribunal-loop`,
`/maintain`'s circuit-breaker + digest patterns.

## 4. Command interface

```
/lessons-deliver [--once] [--dry-run] [--max-issues N] [--max-merges N]
                 [--max-pass-minutes N] [--max-run-minutes N] [--repo OWNER/REPO]
```

Defaults: `--max-issues 5`, `--max-merges 5`, `--max-pass-minutes 90`,
`--max-run-minutes 120` (finite — unlimited is opt-in via `0`). `--dry-run` =
fully read-only: print the eligible queue + planned mutations, write nothing, no
branch/PR/merge.

Repo pin: `--repo` or `$SAAS_PLUGIN_REPO`, validated `OWNER/REPO` (same rigor as
`lesson-review.sh`); refuse otherwise.

## 5. Eligibility & ordering

**Eligible** = open issues in the pinned repo labeled `lesson-approved`, **minus**:
- issues with a linked PR (`closedByPullRequestsReferences` or an open PR whose body
  has `Closes #N` / branch `lesson/<n>-*`) — the **authoritative idempotency guard**,
- `lessons:claimed` by a live run, `lessons:blocked`, `lessons:needs-human`,
- issues whose explicit `depends on #N` prerequisite has not shipped (fail-closed:
  unresolved / circular / non-shipped dependency → defer + log).

Ordering: dependency order first, then oldest-first. **Sequential — one PR in flight**
(this is the merge-serialization + version-bump-collision guard). Per-issue **retry cap**
(default 3) so a persistently-failing lesson can't starve the queue.

## 6. Per-lesson delivery body

1. **Claim** (GitHub-native, authoritative): re-fetch the issue; skip if closed,
   linked-PR exists, `lessons:blocked`/`needs-human`, or claimed by a live run. Add
   `lessons:claimed` + a run-id marker comment. The linked-PR/branch check — not local
   state — is the real guard against double-delivery.
2. **Branch** `lesson/<issue>-<slug>` off `origin/main` inside the worktree.
3. **Implement**: dispatch ONE fresh implementer subagent — `tech-founder-claude-maintain`
   (Claude/Opus; tribunal supplies the independent/Codex review). It reads the lesson body
   + this repo's `CLAUDE.md` conventions, makes the plugin edit, and **adds/updates tests**.
4. **Mechanical diff firewall** (script, before any human-style review — fail-closed):
   - **Path allowlist:** every changed path is under `plugins/` **or** is one of the two
     version files (`plugins/saas-startup-team/.claude-plugin/plugin.json`,
     `.claude-plugin/marketplace.json`). Anything outside → **block** (`lessons:needs-human`).
   - **Self-modification guard:** if the diff touches the loop's own safety infra —
     `scripts/lessons-deliver.sh`, `scripts/lesson-*.sh`, `scripts/pii-gate.sh`,
     `tests/run-tests.sh`, or tribunal config — **do not auto-merge** → `lessons:needs-human`.
   - **Secret scan** of the diff via `pii-gate.sh`; any hit → block.
   - **No test deletion:** assert the diff does not remove existing test assertions /
     test files; reduction in test count → block.
5. **Tribunal gate** (mandatory): zero critical/high, else blocked. A **medium** finding
   in a safety class (test deletion, auth/secrets, filesystem, autonomous-control) also
   blocks.
6. **Test gate:** `bash plugins/saas-startup-team/tests/run-tests.sh` green.
7. **Version bump:** reset onto fresh `origin/main`, recompute the bump from current main,
   bump **both** `plugin.json` and root `marketplace.json` (CLAUDE.md rule; pre-push hook
   enforces sync). One bump per lesson PR.
8. **PR**: body carries `Closes #N` (merge auto-closes the issue — no post-merge relabel
   race). **Merge on green** via `gh pr merge --squash --delete-branch`. If `origin/main`
   advanced during final validation, restart final validation.
9. Post an idempotent shipped comment + apply `lesson-shipped`; `lessons:claimed` removed.

## 7. Hardening (codex-accepted findings)

- **Self-modification:** §6.4 mechanical guard — safety-infra changes never auto-merge.
- **Idempotency:** GitHub-native (linked-PR + branch + `lessons:claimed`); local state is
  cache only.
- **Durable blocked state:** blocking **removes `lesson-approved`** and adds
  `lessons:blocked` (lives in GitHub, survives local-state loss) → leaves the eligible set;
  re-eligibility requires deliberate human re-approval.
- **Diff firewall:** §6.4 path allowlist + secret scan + no-test-deletion, script-enforced.
- **Reconciliation:** a startup pass derives truth from merged PRs and repairs label drift
  (shipped label / close) idempotently — recovers from a crash between merge and relabel.
- **gh failure classification:** retriable (rate-limit / network / transient) → bounded
  backoff; terminal (auth expiry / merge conflict / protected-branch denial) → block +
  annotate the issue.
- **Finite runtime:** `--max-run-minutes` default 120; `0` (unlimited) is explicit opt-in.
- **Single production runner:** cron+flock is production; `/loop` is dev/supervised only.

**Deferred (not in v1, with reason):**
- Branch protection + authenticated required-status check — repo has no CI; local test
  gate + self-mod guard + firewall suffice for a single-owner repo. Future hardening.
- Signed-command approval provenance — single-owner repo, `gh` authed as owner; over-
  engineering for this threat model.

## 8. State & worktree

Plugin repo carries **no** runtime state in git. State dir `.startup/lessons-deliver/`
(current-run.json, runs/<run-id>.md digest) and worktree `.worktrees/lessons-deliver`
are gitignored via `.git/info/exclude` (mirrors `/maintain`). Worktree is `--detach` off
`origin/main`, reused across passes; if stale/dirty and unrecoverable, recreate. Durable
coordination state (claimed / blocked / shipped) lives in **GitHub labels**, not local
files — local state is only a per-session optimization.

## 9. Self-modification: process isolation note

`/lessons-deliver` is part of the saas-startup-team plugin **and** edits it. The loop runs
from the **installed plugin cache** (`/config/.claude/plugins/cache/...`) but edits the
**source checkout** (`/mnt/data/ai/claude-plugins`). The running code is therefore stable
within a pass; an edit to the loop's own files takes effect only after merge **and** a
plugin re-install — never mid-pass. Combined with §6.4, the loop cannot silently weaken its
own gates in the same pass that ships a change to them.

## 10. Prompt-injection firewall

Lesson bodies are auto-generated from session logs → **untrusted** (even though they passed
the PII/secrets gate at filing). Lesson text **informs requirements only**; it may never
expand scope, exfiltrate secrets, weaken/delete tests, alter merge rules, or trigger
external side-effects. Enforcement is **mechanical** (§6.4 diff firewall), not merely a
prompt instruction. The implementer subagent returns the specific facts it acted on,
surfaced in the digest.

## 11. Autonomy / runner wiring

Two **independent** scheduled runners (different repos/cwds — cannot be one `/loop` line):

```bash
# product repos (dev/supervised): /loop 5m /maintain --once
# plugin repo  (dev/supervised): cd /mnt/data/ai/claude-plugins && /loop 5m /lessons-deliver --once
```

**Production (in-container, unattended)** — cron + flock + the host-appropriate
assistant command, matching the design doc's `0 2 * * *` flock pattern:

```
0 3 * * * /usr/bin/flock -n /tmp/lessons-deliver.lock -c \
  'cd <plugin repo> && <assistant command for this plugin> "/lessons-deliver --once" >> /var/log/lessons-deliver.log 2>&1'
```

cron is the production runner; `/loop` is for a supervised session only.

## 12. Tests

New Suite (mock-`gh` harness, mirroring Suite R) over the **script** surface:
- eligibility filter (label / state / linked-PR / blocked / needs-human / dependency),
- repo-pin validation + malformed-pin refusal,
- `--dry-run` performs zero mutations,
- claim idempotency + reconciliation from merged PRs,
- diff firewall: path-allowlist reject, self-mod-guard block, secret-scan block,
  test-deletion block,
- version-bump touches **both** files,
- fail-closed on gh errors; retriable-vs-terminal classification.

The Claude-driven body (implementer + tribunal) is a prompt-playbook; where feasible, a
fixture-issue integration test exercises selection + firewall + reconciliation with faked
implementer/tribunal outputs.

## 13. Observability

Per-pass digest at `.startup/lessons-deliver/runs/<run-id>.md`: per lesson — issue number,
decision + rationale, the facts the implementer acted on (injection transparency), tribunal
result, test result, version bumped from→to, PR link, final state
(`shipped:PR#` / `blocked:<reason>` / `needs-human:<reason>` / `skipped:<reason>`), and a
**self-referential** flag for safety-infra deliveries. A scannable per-pass summary is
emitted to the session (readable via `/rc`).

## 14. Deliverables checklist

- [ ] `scripts/lessons-deliver.sh` + new test Suite (script surface, mock-gh)
- [ ] `commands/lessons-deliver.md` (supervisor playbook)
- [ ] README section + Installation note
- [ ] update `self-improvement-loop.md` (components table + §12 checklist: check off
      auto-implement; note cron wiring as the same runner)
- [ ] version bump (`plugin.json` + `marketplace.json`)
