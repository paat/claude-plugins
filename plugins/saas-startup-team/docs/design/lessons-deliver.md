# Design — `/lessons-deliver`: autonomous implementation of approved lessons

**Status:** implemented design, updated 2026-07-17 for automatic lesson review.
Implements the delivery leg of the self-improvement loop: auto-implement approved lessons
with **no manual trigger**. Codex-reviewed at the design stage; accepted findings folded
in (§ Hardening).

Reads alongside `self-improvement-loop.md` (the loop spec) and reuses the safety
patterns of `commands/maintain.md`.

---

## 1. Problem & scope

The loop ships:

```
/session-insights → /harvest → lesson-file.sh (gated filing of `lesson-candidate`
issues to the PINNED plugin repo) → lesson-auto-review.sh (fresh Opus/xhigh verdict;
conditional independent Sol/xhigh arbitration; approved candidates become
`lesson-approved`)
```

`/lessons-deliver` removes the old manual `/goal-deliver #N` trigger: a scheduled,
in-container runner picks up `lesson-approved` issues and delivers each into the plugin
repo end-to-end (implement → review → test → version-bump → PR → merge).

Normal approval is automated. `lesson-auto-review.sh` reviews at most three candidates per
pass. High-confidence decisions approve or reject; unresolved Opus output invokes Sol, and
a still-unresolved or zero-exit malformed final Sol verdict is quarantined. Only model
transport failures and timeouts remain queued for retry. `/lessons-review` is an optional
manual inspection/override surface, not a delivery prerequisite.

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
| test suites in `tests/run-tests.sh` and `tests/*.tests.sh` | bash (mock-`gh`) | cover the deterministic delivery and review surfaces |

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
2. **Branch** `lesson/<issue>-<slug>` off `origin/${default}` inside the worktree.
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
5. **Preliminary tribunal gate** (mandatory): zero critical/high, else blocked. A
   **medium** finding in a safety class (test deletion, auth/secrets, filesystem,
   autonomous-control) also blocks.
6. **Test + supervisor commit gate:**
   `bash plugins/saas-startup-team/tests/run-tests.sh` green; implementers and reviewers
   never commit.
7. **Version bump + generated surface:** reset onto fresh `origin/${default}`, recompute the
   bump from the current default tip, bump **both** `plugin.json` and root `marketplace.json`
   (CLAUDE.md rule; pre-push hook enforces sync), regenerate the Codex surface, rerun the
   full suite, and commit through the supervisor gate. One bump per lesson PR.
8. **Final-head tribunal gate:** rerun the tribunal on the committed version/generated
   `HEAD`. Any later commit or regenerated change invalidates the verdict; fixes return
   through firewall, generation, tests, and supervisor commit before another tribunal.
9. **PR**: body carries `Closes #N` (merge auto-closes the issue — no post-merge relabel
   race). **Merge on green** via `gh pr merge --squash --delete-branch`. If `origin/${default}`
   advanced during final validation, restart final validation.
10. Post an idempotent shipped comment + apply `lesson-shipped`; `lessons:claimed`
    removed. Before another issue, detach at the latest default and verify a clean
    worktree. Every failed attempt resets its exact clean-start branch/index/worktree and
    reconciles any exact PR/remote branch first; unknown cleanup state stops the pass.

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
(current-run.json, runs/<run-id>.md digest) on the primary checkout (no linked worktree)
is gitignored via `.git/info/exclude` (mirrors `/maintain`). Each pass starts from the
fast-forwarded `${default}` tip; a dirty or non-fast-forwardable primary stops the pass. Durable
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
# product repos: probe maintain, then /loop 5m /maintain --once only on exit 0
# plugin repo: probe lessons-deliver, then /loop 5m /lessons-deliver --once only on exit 0
```

**Production (in-container, unattended)** — cron + flock + the host-appropriate
assistant command, matching the design doc's `0 2 * * *` flock pattern:

```
0 3 * * * /usr/bin/flock -n /tmp/lessons-deliver.lock -c \
  'cd <plugin-repo> && PLUGIN_ROOT=<installed-plugin-path>; export PLUGIN_ROOT; if bash "$PLUGIN_ROOT/scripts/workflow-probe.sh" lessons-deliver; then <assistant-command> "/lessons-deliver --once" >> <log-path> 2>&1; else test $? -eq 3; fi'
```

cron is the production runner; `/loop` is for a supervised session only.

## 12. Tests

Mock-`gh` suites cover the **script** surface:
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

- [x] `scripts/lessons-deliver.sh` + mock-`gh` script-surface tests
- [x] `commands/lessons-deliver.md` supervisor playbook
- [x] README and installation documentation
- [x] `self-improvement-loop.md` integration
- [x] synchronized source and generated version surfaces
