# Mission Control — portfolio scheduler (#198)

Status: designed 2026-07-09 (Lane 2, epic #192). Implementation dispatched to
Codex/Opus; Fable reviews the final diff.
Companion spec: `2026-07-09-mission-control-governor-design.md` (#199) — merges
after this one, onto the governor interface defined here.

## Goal

A new generic plugin `plugins/mission-control` that keeps at most two 24/7
autonomous loops running across a portfolio of SaaS projects, armed by one
human-installed cron line, spending zero LLM tokens on scheduling decisions.
LLM tokens are spent only inside dispatched passes.

## Decisions (settled in the design session)

- Cron runs in the webtop container (persistent crontab via
  `/config/crontabs/<user>` + s6 `init-crontab-config`), not the Ubuntu host.
  Failure mode is safe-idle; agents can inspect cron/logs/locks locally.
- Arming mission-control retires the standalone nightly lessons-deliver cron
  line; lessons-deliver becomes Slot B's idle rung. The idea-generator cron is
  out of scope and stays.
- Slots, pools, and engines are decoupled. Slots = concurrency capacity (2,
  lockfile-enforced). Pools = budget attribution per engine actually used.
  Engines = per-project config. "Slot A → Claude, Slot B → Codex" is default
  configuration, not a code invariant; lessons-deliver runs on `claude-opus`
  by config.
- Human surface stays in the Claude Code world: ntfy push + `/mission-status`
  + digest files under state. No ai-dashboard integration; an optional
  `digest_export_path` config field preserves that option (absent = off).
- Veto/pause mechanism is `hold: true` on a portfolio entry — one field edit,
  no GitHub ceremony.

## Plugin layout

```
plugins/mission-control/
  .claude-plugin/plugin.json        # v0.1.0
  README.md                         # deps (bash4+, jq, flock, docker, gh in
                                    # containers), Installation (3 scopes),
                                    # routing rules, runbook pointer
  commands/mission-status.md        # read-only status command
  scripts/mission-control.sh        # tick | arm | status (bash, no LLM)
  scripts/governor.sh               # sourced library; STUB in this spec
  scripts/notify.sh                 # minimal push sender (~20 lines): POST
                                    # body to the URL in the env var named by
                                    # notify_env; unset var = skip + log once.
                                    # Deliberately duplicated from
                                    # saas-startup-team: a cross-plugin script
                                    # dependency would couple install ordering
  examples/portfolio.example.json   # template values only, no real names
  docs/runbook.md                   # arming instructions
  tests/run-tests.sh                # auto-discovers tests/*.tests.sh
  tests/scheduler.tests.sh
```

Register in root `.claude-plugin/marketplace.json`. Version bumps for this
plugin are always manual dual bumps (lessons-deliver's `--bump-version`
hardcodes saas-startup-team). Codex surface (`.codex-plugin/`) is generated
with `python3 scripts/sync-codex-marketplace.py` in the supervised session;
`.agents/plugins/marketplace.json` regeneration also happens in the
supervised lane, never inside the loop.

## portfolio.json (per-host config; only the example ships in the repo)

Path is given to every invocation via `--config`. Sibling `state/` dir is
created on first tick (overridable with top-level `state_dir`).

| Field | Type | Meaning |
|---|---|---|
| `timezone` | string, optional | TZ for date roll and digest hour; default system TZ |
| `digest_export_path` | string, optional | if set, daily digest is additionally copied there |
| `notify_env` | string | NAME of the env var holding the push (ntfy/webhook) URL; unset var = pushes silently skipped, logged |
| `engines.<name>.pool` | string | pool this engine's passes are charged to |
| `engines.<name>.cmd` | string | launch template; `{prompt}` is replaced with the project's `command` |
| `pools.<name>.daily_pass_quota` | int, optional | governor field (see companion spec); absent = unlimited |
| `slots.A.pinned` | string | project name Slot A continuously maintains |
| `slots.B` | object | reserved; Slot B rotates by ladder |
| `projects[]` | array | portfolio entries, fields below |
| `admission.wip_cap` | int | max admitted+unheld pre-launch projects; default 1 |
| `admission.confidence_min` | number | validated-confidence bar; default 0.7 |
| `admission.veto_hours` | int | veto window; default 72 |

Project entry:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | unique key, used in state and digests |
| `container` | string | docker container name, or `"local"` = run in this container without docker exec |
| `repo_path` | string | repo path inside the container |
| `stage` | enum | `live` \| `pre-launch` \| `validation` \| `meta` |
| `engine` | string | key into `engines` |
| `command` | string | the pass, e.g. `/maintain --once` — carries its own loop caps (`--max-run-minutes` etc.) |
| `hold` | bool | universal pause/veto; checked every tick |
| `incident_labels` | array, optional | default `["incident","production","critical"]`; `live` stage only |
| `work_probe` | string, optional | shell snippet run in the container; nonempty stdout = work exists. Overrides the stage default probe. Config is human-owned per-host — same trust level as the cron line itself |

## State (`state/` next to config)

- `tick.lock`, `slot-A.lock`, `slot-B.lock`, `state.lock` — flock files. The
  tick lock is taken by the script itself (not the cron line), so manual
  `tick` runs and cron share one guard. Slot locks are held by dispatch
  wrappers for the full pass duration.
- `state.json` — single JSON doc; every mutation happens under `state.lock`
  via tmp-file + `mv`. Keys: `date`, `pools.<name>` (`passes_today`,
  `backoff_until`, `backoff_level` — governor-owned),
  `projects.<name>` (`consecutive_errors`, `cooldown_until` — governor-owned;
  `probe_failures` streak — scheduler-owned, read by the digest),
  `admissions.<name>` (`requested_at`, `admitted_at`), `cursor.<rung>`
  (round-robin position), `alerts.<key>` (last-sent epoch for dedup),
  `digest.last_sent_date`.
- `dispatches/<utc-ts>-<slot>-<project>.log` and `.json` — per-pass log and
  outcome record (`slot`, `project`, `engine`, `started_at`, `ended_at`,
  `exit_code`, `outcome`: `ok|rate-limit|timeout|error|orphaned`).
- `digests/<date>.md` — daily aggregated digest (companion spec).

## Tick algorithm (`mission-control.sh tick --config <path> [--dry-run]`)

1. Acquire `tick.lock` non-blocking; already held → exit 0 silently.
2. Preflight: config parses (`jq`), required tools present, `docker info`
   reachable (skipped if every project is `local`). Failure → deduped alert
   (push at most once per 24h per key) + exit non-zero.
3. Date roll: if `state.json .date` ≠ today (config TZ), reset pool counters,
   set `.date`.
4. For each slot in order A, B — only if its flock is free (a held lock means
   a pass is running; long passes span ticks; never preempt):
   - Build the candidate list (below). Skip candidates whose `hold` is true,
     whose project cooldown is active, or whose engine fails
     `governor_check` — on governor refusal continue down the ladder (a
     backed-off Codex pool must not block a Claude-pool rung).
   - First surviving candidate wins. No candidate → slot idles this tick.
5. Dispatch (per winning candidate): spawn a detached wrapper (`setsid`);
   the tick exits without waiting.
6. Call `governor_daily <config> <state_dir>` — every tick; the governor owns
   the once-per-day guard (stub: no-op).

Under `--dry-run`, print every decision (slot states, ladder walk, probe
results, would-dispatch) and mutate nothing, including skipping
`governor_daily`.

Candidate selection:

- **Slot A**: the pinned project, if its work probe is nonempty. Incidents
  are open issues, so the generic probe covers them.
- **Slot B ladder**, top rung with any eligible project wins; round-robin
  inside a rung via `cursor.<rung>`:
  1. `live` projects other than the pinned one whose incident probe hits
     (any open issue carrying an `incident_labels` label).
  2. **Admitted** `pre-launch` projects with a nonempty work probe
     (admission gate below).
  3. `validation` projects with a nonempty work probe (empty rung until
     #205 ships — the ladder tolerates unpopulated rungs).
  4. `meta` projects with a nonempty work probe.

Probes are mechanical, run only for free slots, wrapped in `timeout 30`:
`docker exec <container> bash -lc 'cd <repo_path> && <probe>'` (or plain
`bash -lc` for `local`). Stage defaults: incident probe =
`gh issue list --state open --label <l> --limit 1` per incident label; work
probe = open issues excluding `needs-human`, `maintain:blocked`,
`lessons:blocked`, `lessons:needs-human`, `epic` labels, `--limit 1`; `meta`
default = open `lesson-approved` issues minus the same excludes. A probe
failure (non-zero/timeout) counts as empty — fail toward idle — and is
logged; 3 consecutive failures for one project raise a digest warning line.
The work probe is deliberately coarser than the loops' own queue builders: a
false positive costs one pass that itself exits near-zero.

## Admission gate (absorbed from #206)

Evaluated during rung 2 candidate selection for `pre-launch` entries not yet
admitted:

- Gate: admitted+unheld pre-launch count < `wip_cap`, and
  `.startup/provenance.json` in the project repo (read via the same exec
  mechanism) has `.validation.confidence >= confidence_min`. Missing file or
  field → not admitted (fail closed). The #206 bootstrap side owns writing
  provenance.json; this is the contract it must satisfy.
- On gate pass: stamp `admissions.<name>.requested_at`, push + digest line
  ("<name> enters Slot B delivery in <veto_hours>h — set hold:true in
  portfolio.json to veto"). Do not dispatch.
- After `veto_hours` with `hold` still false: stamp `admitted_at`; project is
  rung-2 eligible thereafter.
- `hold` flipped true at any point pauses immediately (pre- or
  post-admission). Clearing `hold` on a never-admitted project restarts the
  veto clock (fresh `requested_at`). Admitted projects keep `admitted_at`
  across holds.

## Dispatch wrapper

A detached subshell that, in order: acquires the slot flock non-blocking
(failure → log + exit; the tick already checked, this is belt-and-braces);
increments the engine's pool counter under `state.lock` (counted at dispatch
— fail toward under-spend); renders the command from the engine template
(`{prompt}` ← project `command`); runs it via
`timeout <envelope> docker exec <container> bash -lc 'cd <repo_path> && …'`
(or `bash -lc` for `local`) with stdout+stderr to the dispatch log; calls
`governor_report` with the exit code and log path; writes the outcome
`.json`; releases the flock by exiting. A wrapper crash releases the flock
automatically; the next tick logs the missing outcome file as `orphaned`
(the pass stays counted).

## Governor interface (stub here; implemented by #199)

`scripts/governor.sh` is sourced by `mission-control.sh` and owns all budget
policy:

- `governor_check <engine>` → exit 0 = may dispatch. Stub: always 0.
- `governor_envelope <engine> <project>` → prints pass timeout in minutes.
  Stub: 90.
- `governor_report <engine> <project> <exit_code> <log_path>` → post-pass
  accounting; prints the outcome word. Stub: `ok` on exit 0, `error`
  otherwise; no state mutation.
- `governor_daily <config> <state_dir>` → daily digest/housekeeping job,
  invoked by every tick; owns its own once-per-day guard. Stub: no-op.

The scheduler calls only these four; #199 changes no scheduler code.

## `arm` and `/mission-status`

`mission-control.sh arm --config <path>` validates config, then only PRINTS:
the cron line (every 30 min, plain — locking lives inside the script, unlike
the older flock-in-crontab pattern, so manual runs share the guard), where to
paste it (`/config/crontabs/<user>`, edit the file not `crontab -e`), the
instruction to delete the standalone lessons-deliver cron line, and the env
var to set for `notify_env`. It never installs anything — agents are
classifier-blocked from installing skip-permissions crons; the human pastes
the line once.

`/mission-status` (command, read-only): renders config + state — slot lock
holders, per-pool counters/backoffs, cooldowns, pending admissions with
deadlines, last digest path, and the last N dispatch outcomes.

## Error handling summary

Fail toward idle, alert with dedup: config invalid / tools missing / docker
down → alert + exit; probe failure → empty rung + log (+ digest warning after
3 consecutive); wrapper crash → flock self-releases, `orphaned` outcome;
container missing at dispatch → `error` outcome, governor's
consecutive-error cooldown (#199) contains repeat offenders. Nothing in the
scheduler retries within a tick; cron cadence is the retry loop.

## Testing & acceptance

`tests/scheduler.tests.sh` under the auto-discovery harness, using temp
config/state dirs and PATH-shimmed `docker`/`gh`/`date` stubs:

- Two-slot enforcement (#198 acceptance): two stub passes hold both slot
  locks; a tick must dispatch nothing.
- Ladder order and round-robin cursor; pinned project excluded from rung 1;
  held/cooldown/governor-refused candidates skipped with ladder continuing.
- Admission: fail-closed on missing provenance; veto-window stamping; hold
  semantics incl. clock restart; wip_cap.
- No-op cost (#198 acceptance): busy-slots tick and empty-portfolio tick make
  zero docker/gh calls (assert via stub call-log), zero dispatches.
- Date roll resets counters exactly once.
- `arm` prints, never writes outside state.
- Genericness: `grep` guard — no real project/container names outside
  `examples/` and docs.

Self-resume (#198 acceptance) is demonstrated by design + test: kill a stub
pass mid-flight, next tick redispatches (locks released, loops are stateless
supervisors reconciling from GitHub).

## Out of scope

Quotas, backoff, envelopes beyond the stub default, digest assembly, spend
summary, push content (all #199); cross-container handoff bus (#202);
demand-validation passes (#205); provenance.json writing (#206 bootstrap
side); real portfolio values (rollout issues #200/#201).
