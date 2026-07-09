# Mission Control — budget governor (#199)

Status: designed 2026-07-09 (Lane 2, epic #192). Implements the governor
interface stubbed in `2026-07-09-mission-control-scheduler-design.md` (#198);
merges after it. Implementation dispatched to Codex/Opus; Fable reviews the
final diff.

## Goal

Behavioral cross-loop budget control on two subscription pools (Claude Max,
ChatGPT Pro/Codex) with no reliable remaining-quota API: per-pass wall-clock
envelopes, daily pass quotas, rate-limit backoff with clean resume, engine
routing declared once in config, and a daily human-facing digest with a spend
& pass summary. Never degrade output quality to stretch quota — an
over-budget pass is not dispatched or is killed, never asked to be brief.

## Scope

All changes live in `plugins/mission-control/` (v0.1.0 → v0.2.0, manual dual
bump): `scripts/governor.sh` replaces its stub bodies (using the
`scripts/notify.sh` sender shipped by #198), plus tests and README/runbook
additions. No
scheduler (`mission-control.sh`) changes — the four-function interface is the
contract:

- `governor_check <engine>`
- `governor_envelope <engine> <project>`
- `governor_report <engine> <project> <exit_code> <log_path>`
- `governor_daily <config> <state_dir>`

## Config additions (portfolio.json)

| Field | Type | Meaning |
|---|---|---|
| `pools.<name>.daily_pass_quota` | int, optional | max dispatches charged to this pool per local day; absent = unlimited (documented) |
| `engines.<name>.pass_timeout_minutes` | int, optional | envelope; default 90 |
| `engines.<name>.rate_limit_patterns` | array, optional | extra grep -E patterns merged with built-in defaults |
| `projects[].pass_timeout_minutes` | int, optional | per-project envelope override |
| `digest_hour` | int, optional | local hour after which the daily job runs; default 7 |
| `retention_days` | int, optional | dispatch log/outcome retention; default 14 |

Engine routing (#199 acceptance: "routing rules stated once") is not code —
it is the example config plus one README section: Codex is the default
`engine` on every product entry; `claude-opus` only on `meta`
(lessons-deliver) and entries the owner marks for architecture/UX/
Estonian-language judgment. The governor attributes and enforces; it never
chooses engines.

## `governor_check <engine>`

Resolve `pool = engines.<engine>.pool`. Refuse (exit 1) when
`pools.<pool>.backoff_until` is in the future, or `daily_pass_quota` is set
and `passes_today >= quota`. Otherwise allow. Unknown engine/pool → refuse
with an alert (config error, fail closed). The scheduler already continues
down the ladder on refusal, so one pool's exhaustion never blocks the other
pool's rungs.

## `governor_envelope <engine> <project>`

Print `projects[].pass_timeout_minutes` else
`engines.<name>.pass_timeout_minutes` else 90. The scheduler wraps the pass
in `timeout` with this value; loop-level caps (`--max-run-minutes`, …) ride
in the configured `command` string and are not the governor's concern.

## `governor_report <engine> <project> <exit_code> <log_path>`

Classify, then account under `state.lock`:

- **rate-limit**: log matches any built-in or configured pattern. Built-ins
  (case-insensitive `grep -E`): `429`, `rate.?limit`, `usage limit`,
  `quota exceeded`, `limit (will )?reset`, `overloaded`. Set the pool's
  `backoff_until`: best-effort reset-time extraction from the log (the
  implementation documents its regexes for `resets at <time>` phrasings and
  ISO timestamps; parsed time is interpreted in config TZ); on parse failure,
  exponential fallback 30m → 1h → 2h → 4h (cap) via `backoff_level`, which
  increments per consecutive rate-limit and resets to 0 on the pool's next
  `ok`. Rate-limit classification wins over exit code (a limited pass may
  still exit 0 after partial work).
- **timeout**: exit code 124 (and not rate-limit). No backoff — envelope
  expiry is not a pool problem. Counts toward the project error streak.
- **ok**: exit 0. Clears the pool's `backoff_level` and the project's error
  streak.
- **error**: anything else. Per-project breaker: 3 consecutive
  `error`/`timeout` outcomes set `projects.<name>.cooldown_until = now+24h`
  plus a push + digest warning — a broken container must not burn the daily
  quota. Cooldown clears by expiry or by the streak resetting on `ok`.

Ambiguity rule: if classification is uncertain, prefer `rate-limit` — backoff
is always safe (clean resume comes free from the tick cadence: first tick
after `backoff_until` with a free slot just dispatches; nothing to resume
because the loops are stateless supervisors).

## `governor_daily <config> <state_dir>`

Idempotent per day (`digest.last_sent_date` guard); runs on the first tick
after `digest_hour`. Steps:

1. **Per-project digests**: for each non-`meta` project, resolve
   saas-startup-team's `digest.sh` inside the container —
   `<repo_path>/plugins/saas-startup-team/scripts/digest.sh` if present
   (monorepo case), else newest version under the plugin cache (same
   find-by-version pattern maintain-loop uses for issue-closure-audit.sh) —
   then `assemble` + `mark-sent` via exec, and pull the assembled file's
   content. Resolution failure → section header with a warning line, not a
   failed job. For `meta` projects, include the latest
   `.startup/lessons-deliver/runs/` digest entries newer than the last sent
   date. Rollout note (#200/#201, not this plugin): once mission-control owns
   digest delivery for a project, that project's own digest send wiring
   (monitor-nightly) must be disabled — two senders would race the
   `mark-sent` cursor and double-deliver.
2. **Assemble** `state/digests/<date>.md`: per-project sections (content from
   step 1), a `## Mission control warnings` section (probe-failure streaks,
   orphaned dispatches, cooldowns, pending admissions with veto deadlines),
   and `## Spend & pass summary` — per pool: passes used / quota, backoff
   status with until-time; per slot: dispatches today as
   `project (engine) → outcome`. The per-project digest files keep their own
   placeholder section; this aggregated digest is the human-facing artifact
   (#194's named-section handoff lands here, where the cross-pool view
   lives).
3. **Push** via `scripts/notify.sh` (shipped by #198): the needs-human lines
   + warnings + spend summary (not the full digest).
4. **Copy** the digest to `digest_export_path` if configured.
5. **Housekeeping**: delete `dispatches/*` older than `retention_days`; mark
   orphaned outcomes (dispatch log without outcome JSON and lock no longer
   held).

Alert pushes elsewhere in mission-control (preflight failures, admission
announcements, cooldown breakers) go through the same `notify.sh` with 24h
dedup keys in `state.json .alerts`.

## Error handling

Every governor failure fails toward not dispatching (check) or toward
backoff (report), never toward extra spend. `governor_daily` failures alert
+ leave `last_sent_date` unset so the next tick retries. State writes stay
under `state.lock` (tmp + `mv`).

## Testing & acceptance

`tests/governor.tests.sh` (auto-discovered), fixture logs + stubbed
`docker`/`curl`/`date`:

- Quota: check refuses at quota, allows after date roll (#199 acceptance:
  quotas configurable).
- Backoff: fixture rate-limit logs → `backoff_until` set (parsed reset time
  and exponential fallback paths); check refuses during backoff; a
  simulated post-reset tick dispatches again (#199 acceptance: observed
  rate-limit produces backoff + clean resume); `ok` clears `backoff_level`.
- Classification precedence: rate-limit beats exit 0; timeout ≠ backoff;
  3-strike cooldown sets/clears correctly.
- Daily job: idempotent per day; digest contains all sections; spend summary
  reflects state fixtures; push payload = needs-human + warnings + summary;
  unset notify env skips cleanly; retention deletes only old files.
- Routing stated once: README section exists; example config carries the
  default engine assignments (#199 acceptance).

## Out of scope

Precise token/cost ledgers (quota signals are unreliable — the governor is
behavioral by design); mid-pass budget enforcement beyond `timeout`;
cross-container handoff (#202); dashboard rendering of the exported digest
(optional field only).
