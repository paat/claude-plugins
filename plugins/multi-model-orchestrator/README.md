# multi-model-orchestrator

Route each software task to a current Claude Code, Codex, Grok Build, Muse Code, Antigravity
(Gemini Flash/Argon), Mistral Vibe, or local Qwen worker by task fit, complexity, plan-limit headroom, and availability, then verify the
result deterministically and review it independently when the risk justifies another pass.

The standalone `route-model-task` skill can return route cards without executing work, and
`scripts/pool.sh` picks or runs a worker from any shell. The `multi-model-orchestration` skill,
`/multi-model-orchestrator:orchestrate`, and `/multi-model-orchestrator:meta-orchestrate` dispatch
through the same pool.

Example requests:

> Implement this change. Choose the model and effort per task.

> Use Codex only. Do not call Claude or Grok.

> Do not use Claude. Use Grok for the bounded implementation and GPT-6.2 Astra for review.

Natural-language restrictions are hard constraints. The router never silently substitutes a
denied provider, model, or unsupported effort.

## Current model catalog

Prior Claude generations (Opus 5, Sonnet 5, Fable 5.1, Fable 5, Haiku 4.5) are kept for compatibility and are never routed by default.

| Provider | Models | Typical role |
|---|---|---|
| Claude Code | `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5`, `claude-fable-5-2`; prior-generation `claude-haiku-4-5`, `claude-sonnet-5`, `claude-opus-5`, `claude-fable-5-1`, `claude-fable-5` | Fast triage through highest-capability long-running work |
| Codex | `gpt-6-luna`, `gpt-6.2-sol`, `gpt-6.2-astra`; fallbacks `gpt-6.1-sol`, `gpt-6-astra`, `gpt-5.6-luna`; directly pinnable only, not in the pool: `gpt-6-sol`, `gpt-6.1-terra`, `gpt-5.6-terra` | Mechanical work through hard technical implementation and review |
| Grok Build | `grok-4.7` (default), `grok-4.6`, `grok-4.5` | Fast bounded implementation, reproduction, and independent review |
| Muse Code (`muse`) | `muse-spark-1.3` (bounded default), `muse-wonder-full-1.0` (T3); `default` passes no `--model` | Bounded implementation, reproduction, research, and review. Plain `muse-wonder-1.0` is not routed |
| Local Qwen | `default` (whatever the llama.cpp endpoint serves); explicit pin: a served model id | Free mechanical edits and a cheap second review lens; one GPU slot, skipped when busy, down, or not serving a pinned model (needs the `subagent-local-qwen3.8-27b` plugin) |
| Antigravity (`agy`) | `gemini-3.8-flash`, `gemini-4-argon`, `gemini-4-hydrogen`, `gemini-4-carbon`, `claude-sonnet-5-5`, `claude-opus-5-5` | Flash for bounded edits (the default agy model); Argon for complex coding; Hydrogen as a T2 `medium` worker ahead of Flash `high` and a T3 route behind Argon; Carbon as an available T3 flagship behind Hydrogen, not preferred and not the default (owner correction 2026-11-19; `agy models` 2026-11-20 lists low/medium/high, no xhigh); Sonnet/Opus as small same-model overflow when the Claude plan window is spent; advisory in review mode except `claude-opus-5-5` (paat/ai-overlord#474, 2026-11-18) |
| Mistral Vibe (`vibe`) | `mistral-large-4` (T2 `medium`, T3 `high`, lowest preference); `default` passes no `--model` | Worker-only. `run-vibe.sh` always passes `--max-price 0` and stops on the plan budget (2026-11-19, paat/ai-overlord#474). Review is advisory; vibe 3+ only |

Haiku 5.5 is the latest Haiku; the wrapper runs it without `--effort`. Claude Fable 5.2,
Fable 5.1, Fable 5, Opus 5.5, Opus 5, Sonnet 5.5, and Sonnet 5 support `low` through `max`; GPT-5.6 and GPT-6 support `low` through `max`, with
Astra-only `ultra` available for bounded internal fan-out; Grok 4.7 and Grok 4.6 support `low`,
`medium`, `high`, and `xhigh`; Grok 4.5, Gemini 3.8 Flash, Argon, Hydrogen, and Carbon support `low`, `medium`, and `high`; Muse catalog models support
`minimal` through `max`. Vibe's `default` passes no `--thinking`; Mistral Large 4 (`mistral-large-4-0`, or `mistral-large-4`) takes only `low`, `medium`, `high` (`off`, `xhigh`, `max` exit 2: API 400, mistral-vibe#1439, 2026-11-05); `default` and other aliases pass the level as written.

## Routing policy

The router applies provider/model restrictions, then assesses task family, ambiguity,
scope/coupling, risk, validation, modality, tools, latency, and duration. It chooses model and
effort separately using the [task-fit matrix](skills/route-model-task/references/task-fit.md):
Luna/low for mechanical work, Sonnet/medium for specified coding, Sol/xhigh for demanding
visual systems, and Argon/high as a complex-debugging candidate. These are dated starting
recommendations, not universal winners; local acceptance and repair results decide preference.

Complexity sets a tier; `scripts/pool-tiers.tsv` lists each tier's workers in order:

| Tier | Task evidence | Workers, in order |
|---|---|---|
| T1 | Exact rename, fixture, file map, focused check | Local Qwen, Gemini 3.8 Flash low, GPT-6 Luna low |
| T2 | Well-specified change with known tests | Sonnet 5.5 plan/API, Sonnet 5.5 via agy, GPT-6.2 Sol, Grok 4.7, Gemini 4 Hydrogen, Gemini 3.8 Flash high, GPT-6.1 Sol, Muse `muse-spark-1.3`, Mistral Large 4 (all medium unless noted) |
| T3 | Cross-module work, hard debugging, ambiguous design | GPT-6.2 Astra, Opus 5.5 plan/API, Opus 5.5 via agy, Muse `muse-wonder-full-1.0`, GPT-6.2 Sol, Gemini 4 Argon, Gemini 4 Hydrogen, Gemini 4 Carbon, GPT-6 Astra, GPT-6.1 Sol, Mistral Large 4 (all high unless noted) |
| T4 | Security, payments, destructive migration, concurrency | GPT-6.2 Astra xhigh, Opus 5.5 plan xhigh, GPT-6 Astra xhigh |

`pool.sh` drops workers that are not allowed, not installed, advisory on a review (local Qwen,
agy, Vibe; agy `claude-opus-5-5` excepted, paat/ai-overlord#474, 2026-11-18), or at 90%+ of a plan window that resets after the leg's timeout, then tries the rest in
order and moves past any that exit 75 (busy, down, or at a limit), skipping a provider/model that already exited 75 later in the run. T1 and T2 fall back to the
higher tiers' workers; T3 and T4 never fall to a weaker tier and exit 75 with the earliest reset
instead.

T4 excludes API overflow because API legs skip project deny rules and hooks.

`claude-api` follows each T2/T3 Claude plan row at the same model/effort and runs only after that plan
window is tight or the matching plan leg returns `exit=75 failure=limit`; transient failures do not
enable API spending. Set `MMO_CLAUDE_API_KEY_FILE` to a linked Console organization's key file;
`run-claude.sh --api` uses it only in the leg, bypasses plan-window gates, and exits 75 when
unavailable or credits are exhausted. API legs clear inherited Claude/OAuth variables and use an
empty, private per-leg `CLAUDE_CONFIG_DIR`, removed on exit or stop, to isolate the host OAuth login.
`apiKeyHelper` sends the file key in both `x-api-key` and `Authorization` (as documented) without
exporting it to CLI or tool environments. They explicitly load root `CLAUDE.md` (or root `AGENTS.md` when the repo has no CLAUDE file) and `.claude/` rules;
with settings sources disabled, only unconditional rules load, while rules with `paths:` frontmatter
require project settings. They do not load nested or ancestor `CLAUDE.md`, `CLAUDE.local.md`,
`~/.claude/CLAUDE.md`,
user/project/local hooks, settings `env`, or project permission rules (including `deny`); runner
`--allowedTools`/`--disallowedTools` still apply. They retain the system prompt and normal tools,
and remain Claude for restrictions and reviewer independence. To deny API spend, unset
`MMO_CLAUDE_API_KEY_FILE`. This uses monthly plan API credit, separate from subscription limits;
purchased credits/auto-reload can extend usage ([credit
terms](https://support.claude.com/en/articles/17154008), [`claude -p`
eligibility](https://support.claude.com/en/articles/15036540), read 2026-10-30).
A same-uid agent can still read the key file (as with plan legs' OAuth credentials); API-leg output
is not redacted, so treat it as sensitive.

```bash
pool.sh pick --tier T2 --deny claude              # one "tier provider model effort" line per worker
pool.sh pick --tier T3 --prefer gemini-4-argon     # task-fit preference, still subject to filters
pool.sh run --tier T1 --repo . <<< "<task packet>" # run on the first available worker
pool.sh run --tier T3 --mode review --base main --deny codex <<< "<review request>"
```

Flags: `--allow`/`--deny` (comma-separated providers or models), `--prefer <provider|exact-model>` (first
within its tier), `--usage <usage.sh output>` (default: a fresh `usage.sh` run), `--timeout`,
`--out`. Preferences are soft and never jump tiers or bypass limits; user pins remain binding.
Forward the same preference/restrictions/usage snapshot from `pick` to `run`. A task-specific
effort differing from the table uses an eligible candidate's direct runner with explicit
`--model`/`--effort`; preserve restrictions/headroom on fallback. Unusually hard or days-long
work can pin Fable 5.2 outside the pool after the same restriction and usage checks.

These are starting hypotheses, not a universal leaderboard. Local completion, latency,
scope-control, and test data should override them. Higher effort is not a repair for unclear
acceptance criteria. `max` and `ultra` require exceptional evidence or an explicit request.

The [dated evidence](skills/route-model-task/references/evidence-2026-10.md) distinguishes vendor
guidance, observed availability, and unmeasured comparisons. Record task family, served model,
effort, runner/tools, acceptance, elapsed time, repairs and known cost in the existing ledger.
Compare repeated tasks under the same harness; unavailable providers are not capability failures.

## Local outcomes

Every runner invocation appends one TSV row on exit, including failures, timeouts, unavailable
providers and invalid arguments. `run-opus.sh` delegates to Claude and records only its one row.
The shared helper writes a header on creation at
`${MMO_OUTCOMES_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator/outcomes.tsv}`.
Append failures are silent and preserve the leg's output and exit code; recording makes no network
or model calls. Claude Code and Codex workflows use these same scripts and this same record.
Keep an override outside the checkout, or at an untracked path covered by `.gitignore`: the
existing dirty-tree guard treats any other in-repository log change as a repository edit and
stops pool fall-through. The default state location is outside the checkout.

| Column | Meaning |
|---|---|
| 1 `utc_time` | Exit time, UTC ISO 8601 |
| 2 `repo` | Origin remote's `owner/name`, otherwise directory basename |
| 3 `tier` | Attempted worker's pool tier; empty on direct runner calls |
| 4 `role` | Runner mode, or `gate` |
| 5 `provider` | `claude`, `codex`, `grok`, `muse`, `agy`, `vibe`, or `qwen`; empty for gate |
| 6 `requested_model` | Requested model, including aliases such as `default` |
| 7 `served_model` | Model named by the captured provider output; empty when unknown |
| 8 `effort` | Runner effort (`n/a` for Claude Haiku); empty when inapplicable |
| 9 `exit_code` | Final runner/gate status, including 75/77 reclassification |
| 10 `duration_seconds` | Whole elapsed seconds |
| 11 `tokens` | Reported token count; empty when unknown |
| 12 `head_sha` | Gate only: checkout HEAD captured at gate entry |
| 13 `verdict` | Gate only: emitted `APPROVE` or `NEEDS_WORK`; empty on gate errors |

Tabs and newlines in values become spaces. Pool fall-through records each attempted runner with
its selected tier; the pool adds no row. Run `review-gate.sh` from the reviewed checkout with HEAD
still at the reviewed commit so its `head_sha` identifies that review.

Metadata coverage (2026-10-30, from the runner output formats): Claude `--stream-log` reads the
assistant message model (or system/init model) and result usage, summing input, output, cache-read
and cache-creation tokens. Codex reads the terminal stderr `tokens used` footer; its startup model
is a requested setting, so served model stays empty. Muse reads `run.model.configured`'s model ID;
local Qwen reads its wrapper's running-model stderr line. Vibe reads its run export: `usage.total_tokens`, and `config.active_model`, which is empty when the default model is server-routed. Muse/Qwen token counts, agy/Grok metadata,
and plain-text Claude metadata stay empty because these captured formats expose no supported
fields. Requested models are never substituted for missing served models.

Execution pass rate (`exit_code == 0`, including unavailable attempts in the denominator) per
`tier, provider, requested_model, effort`, followed by successes/attempts and percentage:

```bash
awk -F '\t' 'NR>1 && $4!="gate" {k=$3 FS $5 FS $6 FS $8; n[k]++; ok[k]+=($9==0)} END {for(k in n) printf "%s\t%d/%d\t%.1f%%\n", k,ok[k],n[k],100*ok[k]/n[k]}' "${MMO_OUTCOMES_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator/outcomes.tsv}" | sort
```

This measures execution success, not review approval; combined review verdicts are separate gate rows.

### Leg checks

`scripts/leg-check.sh --repo DIR --base REF [--baseline FILE] [--allow-paths GLOBS]
[--verify-cmd CMD] [--verify-pattern ERE] [--verify-timeout SECONDS] [--final FILE] [--out PATH]...
[--task ID] [--cycle N] [--tier T] [--provider P] [--model M] [--effort E]` checks an implement
leg's result against the commit it started from, without the leg `--out` files. Without
`--baseline`, every committed, staged, unstaged or untracked change since REF counts (submodules
included). `--snapshot FILE --repo DIR` records each dirty or untracked path's index and
working-tree state before dispatch (the file itself never counts); with `--baseline FILE` only the leg's own changes count:
commits since REF, new or differently changed dirty paths, and snapshot paths it changed or
reverted. First failure wins: exit 10 `no_change`; exit 8 `scope` (a changed path matches no
comma-separated glob, compared with bash `[[ path == glob ]]` so `*` crosses `/`; `dir/` allows
that directory); exit 9 `verify` (`--verify-cmd` run with `bash -c` in the repository under
`timeout`, default 900 s, failed or timed out, or its output missed `--verify-pattern`, so a runner
that ran nothing fails); else exit 0 `pass`. After a passing verify the paths are enumerated and
checked again, so a test that writes outside the allow-list fails `scope`. The verify command runs
in the scrubbed leg environment: a test that needs a variable gets it through `MMO_LEG_ENV`, as a
leg does. Exit 11 `error` means the check could not run (a git command failed, or `--baseline` is not a
complete snapshot); it is never a
pass. A final message (`--final`) ending with an ask-to-continue phrase ("want me to", "would you
like me to", "shall I", "should I continue/proceed", "let me know if you") adds
`note=asks-to-continue` without changing the exit. Usage errors and an invalid REF exit 2; `--validate` with the contract flags only validates them (exit 0 or 2).
`pool.sh run --mode implement` takes `--allow-paths`, `--verify-cmd`, `--verify-pattern`, `--task`
and `--cycle`, validates them before any worker runs, snapshots the tree and HEAD before dispatch,
runs the check after a worker exit 0, exits with the check's code, and adds `check=` to its final
line. A dirty tree or a closed issue number exits 56 before dispatch; see below.

Each check appends a row to
`${MMO_LEG_CHECKS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator/leg-checks.tsv}`
with the outcome file's header and failure rules: `utc_time`, `repo`, `task`, `cycle`, `tier`,
`provider`, `model`, `effort`, `check`, `detail` (first offending path, `verify-exit=N`,
`verify-timeout`, `verify-pattern`, the failed `git <command>` on error, else the note), `head_sha` (HEAD at check time),
`changed_paths` (count), `duration_seconds`. First-pass rate per provider/model/effort (share of
(repo, task) pairs whose lowest-cycle row is `pass`; rows without `--task` are left out):

```bash
awk -F '\t' 'NR>1 && $3!="" {k=$2 FS $3; if (!(k in c) || $4+0<c[k]+0) {c[k]=$4; g[k]=$6 FS $7 FS $8; r[k]=$9}} END {for (k in g) {n[g[k]]++; ok[g[k]]+=(r[k]=="pass")} for (x in n) printf "%s\t%d/%d\t%.1f%%\n", x, ok[x], n[x], 100*ok[x]/n[x]}' "${MMO_LEG_CHECKS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator/leg-checks.tsv}" | sort
```

### Friction report and adjustments

`scripts/friction-report.sh` turns both records into recurring friction per `provider`, `model`
(served, else requested), `effort` and `role` (check rows: `implement`), over the last `--days`
(30). Output columns: `provider model effort role kind count legs rate_pct first_seen last_seen
flag`. Runner kinds, out of the group's runner exits: `timeout` (124), `empty_output` (5),
`no_verdict` (6), `guard_failed` (7: a read-only or probe leg changed the repository, Muse served
another model, or Grok's tool allowlist was not proven enforced), `budget_exhausted` (55/76/78:
turn or step cap, or local Qwen's wall-time or session-turn budget), `provider_error` (1), `exit_N`
otherwise. Check kinds, out of the group's checks: `scope`, `verify`, `no_change`, and
`asks-to-continue` (the note on a `pass` or `no_change` row). `unavailable` (75), `auth` (77),
`cli_missing` (127), `usage` (2/3/4) and `interrupted` (129/130/143) are not model friction: flag
`info`, left out of the other rates. Rows with a malformed or future timestamp and check rows with
an unknown result are skipped. `flag` is `yes` when count >= `--min-count` (3) and 100 x count >=
`--min-rate` (30) x legs; `--outcomes`/`--checks` repeat to combine hosts:

```bash
scripts/friction-report.sh --flags-only --outcomes host-a.tsv --outcomes host-b.tsv --checks host-a-checks.tsv
```

`scripts/harness-adjustments.tsv` (columns `provider model_glob mode line evidence as_of`) holds
the provider-specific prompt lines: every runner adds the lines whose provider, model glob (bash
pattern on the exact model id) and mode (`implement`, `review`, `research`, `advise`, `*`) match
to that leg's prompt. `{budget}` becomes the leg's turn or step cap (Grok, Muse, Vibe; Claude only
with `--max-turns`, else the line is skipped with a warning). `{timeout}` becomes a Grok review
leg's `--timeout` when it is below the 1200 s default; otherwise the line is left out. Each row cites the friction it answers
and a calendar date. The test suite rejects a malformed row, a mode its runner does not take, and
`{budget}` for a runner without one; runners skip such a row with a warning. Probe prompts take none.

## Meta orchestration

`/multi-model-orchestrator:meta-orchestrate <mission brief>` runs the show over a queue of
work. The brief is free-form and describes WHAT to achieve — an epic issue, an issue list to
prioritize and implement, a goal to discover tasks for, or "scan for new workitems" — plus any
autonomy bounds and model restrictions. HOW is the orchestrator's job: per-item worker legs
routed through the model catalog, adversarial review plus a bounded delta re-review by a
different provider, merge only on a review-gate exit of 0, and a crash-safe handoff file updated
after every decision. `scripts/handoff-lease.sh` keeps one orchestrator per checkout: a second
session on the same handoff directory (a cron `--resume` beside a live run) is refused with exit 75
until the lease expires. A run in another worktree has its own handoffs and its own lease. `--resume [handoff-path]` continues from the newest (or named) handoff;
trailing text is treated as overrides of decided judgment calls and brief deltas. A scan that finds nothing new writes
nothing and stops; recurrence belongs to `/loop` or cron.

Long runs reset through compaction: the handoff is always current, and after a
compaction the re-attached skill plus a `SessionStart` `compact` hook send the orchestrator back to
the newest handoff (modified within 24 hours) to continue as `--resume`. The default window lets a
1M-context session grow to ~967k tokens before that happens, so every turn re-sends up to that
much. Cap it in the dev container's user settings so resets happen early:
`"autoCompactWindow": 500000` in `~/.claude/settings.json` (Claude Code) and
`model_auto_compact_token_limit = 200000` in `~/.codex/config.toml` (Codex, whose window is ~258k). The same hook
runs on Codex, which also re-runs `SessionStart` hooks after compaction.

A `PostToolUse` hook (`hooks/context-watch.sh`, needs `jq`) reads the last usage record from the
session transcript and, once context crosses `MMO_CONTEXT_WARN_TOKENS` (default 400000), tells a
meta-orchestrator to bring its handoff current and keep the item lean before compaction. It speaks
only in a session that invoked the workflow (slash command, Skill tool, or the Codex workflow skill).
It warns once per crossing and re-arms after compaction. With the recommended 500k Claude window it
fires ~65k tokens before compaction (~467k); below a ~435k window it never fires.

The orchestrator reads plan limits (percent used and reset time per 5-hour, weekly and per-model
window) at start, resume and every item boundary: the desktop app's `get_usage` tool for Claude, or
`scripts/usage.sh`, which reads Codex session logs, Muse `run.usage` allowances from a run stream
(`--muse-log`; `weekly` as `7d`, `window` as `5h`), agy's local `/usage` command (one window per
quota pool: `5h_flash`/`7d_flash`, `5h_claude`/`7d_claude`, `7d_argon`), and Claude
`rate_limit_event`s (a run-claude stream log, or one tiny `--probe-claude` call). `pool.sh` skips
a provider or model whose window is at 90% or more and resets after the next leg would finish, and
moves the rows a weekly window binds (a provider, or one agy pool's models) to the front of each
tier when it is at most 60% used and resets within 24h (use it or lose it; an explicit `--prefer` still goes first); when no allowed route has headroom, or the host
itself passes 95%, the run stops at the item boundary with the reset time in the handoff. Grok
exposes no limit data and is left to the exit-75 fallback unless the operator appends a
line in `usage.sh`'s format (e.g. `grok 7d 40% resets 2026-10-16T09:00Z`) to the `--usage` file.

When an item depends on out-of-repo facts, a research leg records tiered evidence in a tracked
memo. Unknowns are researched before a judgment call is decided with the recommended default and recorded.

Delivery chains `tribunal-review:closing-tribunal-loop` (epic PR in epic mode, per-item PRs
otherwise), so that plugin must be installed. Code delivers through GitHub branches/PRs;
additional workitem trackers (e.g. Plane) and model constraints for orchestrator legs are
configured per repo in `.claude/multi-model-orchestrator.local.md`:

```yaml
---
sources:
  - name: plane
    list: "curl -s -H \"X-API-Key: $PLANE_API_KEY\" $PLANE_URL/.../issues/ | jq -r '...'"
    close: "curl -s -X PATCH ..."
models:
  allow: [gpt-6.2-sol, grok-4.7]
  worker: "gpt-6.2-sol high"
---
```

Model constraints bind worker/reviewer/advise/research legs; the tribunal panel keeps its own
`TRIBUNAL_*` configuration.

For an unattended Claude Code auto-mode run, pre-authorize leg dispatch. The classifier treats
destinations it has not been told about as outside the trust boundary; describe trusted infrastructure in prose under
`autoMode.environment` (keep `"$defaults"` in the array) and prose exceptions under `autoMode.allow`. It reads `autoMode` only from
`~/.claude/settings.json`, managed settings, or `--settings`, not the project's `.claude/settings.json` or `.claude/settings.local.json`
([auto-mode config](https://code.claude.com/docs/en/auto-mode-config.md), [permission modes](https://code.claude.com/docs/en/permission-modes.md), checked 2026-11-15).
`claude auto-mode config` prints the effective rules; `/auto-mode-setup` drafts entries. Narrow `permissions.allow` Bash rules resolve before the classifier,
except a command carrying per-command allowed domains still goes to the classifier. Broad rules that grant arbitrary code execution (blanket `Bash(*)`, wildcarded interpreters) are suspended in auto mode, and every subcommand
of a compound command must match ([permissions](https://code.claude.com/docs/en/permissions.md), checked 2026-11-15: "Every subcommand must be allowed for a compound command to run without a prompt"), so a rule for the runner paths is not a reliable lever for the wrapped `…; echo $? > <marker>` dispatch.
After 3 consecutive (or 20 total) classifier blocks, auto mode pauses and prompts. Example `autoMode.environment` entry — prose the classifier reads, not a pattern. Replace `<marketplace>` and `<version>`, or describe the directory in your own words, and write the home directory as an absolute path:
"The multi-model-orchestrator runners at /home/yourname/.claude/plugins/cache/<marketplace>/multi-model-orchestrator/<version>/scripts/ and the
codex, grok, muse, agy, vibe, and qwen CLIs they call are trusted for sending repository diffs."

## Execution posture

- The controller owns intent, restrictions, architecture judgment, task boundaries, and final
  arbitration.
- One fresh worker owns one bounded task. Writes are sequential unless files and generated state
  are disjoint.
- Every CLI leg runs in YOLO mode inside the development-container security boundary: Codex uses
  `--dangerously-bypass-approvals-and-sandbox`, Claude uses `--dangerously-skip-permissions`, and
  Grok uses `--sandbox none --permission-mode bypassPermissions`, Muse uses `--yolo` (headless
  `muse exec` otherwise blocks on an approval prompt until the timeout). Advice and review legs still
  receive semantic no-write contracts and read-only tool allowlists; Muse's drop write and shell
  tools and exit 7 if the repository changed anyway. A reviewer that must run probes uses
  `--mode probe` (`run-claude.sh`, `run-grok.sh`, `run-muse.sh`): it keeps its shell, must end
  with a verdict line (exit 6) and must leave the repository unchanged (exit 7). Claude and Grok research legs have web-only
  tool allowlists with no file access; Muse research has no write or shell tools and runs from an
  empty directory but keeps read tools. Vibe implement uses
  `--trust --auto-approve`; its advise and review enable `read_file` only in an untrusted folder (no project `.vibe/` config or
  hooks, no shell, no search; a headless run denies every call that needs approval), are advisory, and exit 7 on writes. The Codex CLI has no per-tool allowlist and
  keeps shell access, so Codex research runs from a scratch working root instead of the repository,
  bounded by that root and its prompt contract. This bounds blast radius rather than enforcing
  read-only, so a Codex or Claude advise, review, or research leg that changed the repository
  exits 7: inspect `git status` before trusting its report.
- The host's `.env` deny rules do not bind a leg, so runners keep secrets out of provider context
  instead. Every leg except Claude, Codex, and Grok research refuses a checkout holding untracked `.env*` files outside
  ignored directories (exit 2); run from a `git worktree add` checkout, which has none. Every CLI starts under
  `env -i` with `PATH HOME USER LOGNAME SHELL LANG LC_ALL TERM TMPDIR`, proxy and CA variables,
  its own provider variables, and the names in `MMO_LEG_ENV`. A test database URL passed that
  way must point at a dev/test database. This stops accidental reads, not a leg that goes looking
  outside its checkout. The local Qwen route sends nothing to a hosted provider and is exempt.
- Every task names allowed files and an exact gate. Reviewer prose is advisory until verified
  against code, tests, or rendered output.
- Final review defaults to the tribunal flow: push, PR, `tribunal-review:closing-tribunal-loop`
  until zero critical/high. Inline reviewer legs are the fallback when tribunal-review is not
  installed or the run is explicitly local/no-PR; there, ordinary nontrivial work gets at most
  one independent provider review and a second must pay for itself through risk or conflicting
  evidence. User provider restrictions remain authoritative.
- Grok legs use an isolated configuration to avoid inheriting host agents, plugins, hooks, and
  MCPs. OAuth `auth.json`, `XAI_API_KEY`, and `GROK_*` variables are preserved; config-only
  enterprise authentication should use Grok's equivalent `GROK_*` environment variables.
- Muse legs pass `--no-foreign-personal-context` so they do not load host Claude rules and skills,
  and keep `MUSE_*`, `META_API_KEY`, and `XDG_*` for authentication. A `-contributor` model id
  lets Meta use content for product improvement; that applies when `MMO_MUSE_MODEL=default`
  passes no `--model` and the CLI selects one. Bounded work requests `muse-spark-1.3`; the T3
  pin is `muse-wonder-full-1.0`. Pool rows supply their own `--model`. A pinned leg that ran
  another model exits 7.

## Review gate

`scripts/review-gate.sh [--author <provider-or-model>] --leg <provider>=<final-message-file> [--leg ...]` combines reviewer legs
into one verdict taken from each leg's last verdict line: `0` APPROVE, `1` NEEDS_WORK, `2` a missing
file or a leg without a terminal verdict, and `3` when no leg is from an independent hosted provider.
With `--author`, a leg from the author's own provider family (a Codex reviewer for a GPT worker)
does not count as independent either; omit it only for a run restricted to one provider.
An agy worker passes `--author agy/<model>`; a bare `--author agy` conflicts with any Claude-family leg.
Classification is fail-closed: only labels naming a hosted catalog provider or model (Claude, Codex,
GPT, Grok, Muse and their model names) count as independent, plus the qualified `agy/claude-opus-5-5`
leg, which counts as Claude; `Local Qwen`, `qwen3.8-27b-local`, a bare `agy`, `vibe`, or
an unrecognized label are advisory. The local and Vibe reviewers, and unqualified agy legs,
read the diff and cannot run probes, so none can be the only reviewer — the gate enforces that rather
than trusting a prompt to say so. agy enforces no read-only mode in print mode, so `run-agy.sh --mode review` runs from an empty
directory and exits 7 if the repository changed anyway.

TERM, HUP, and INT to a runner or `pool.sh run` stop the active provider, including
nested timeout wrappers, with the existing 10-second kill grace. The runner records
one outcome with exit 143, 129, or 130 respectively.

## Prerequisites

- bash 4+
- git and GNU coreutils (`timeout`, `date -d`, `stat -c`, `realpath -m`)
- `ps` (procps) to stop nested provider watchdogs (`claude-api`, local Qwen) on a leg stop; without it the root watchdog is still signalled
- `awk` and `setsid` (util-linux) for forwarding stops through nested provider watchdogs
- The authenticated CLI for each selected route:
  - Claude Code (`claude`)
  - OpenAI Codex CLI (`codex`)
  - latest Grok Build (`grok`), using Grok 4.7 by default
  - Meta Muse Code (`muse`); bounded work requests `muse-spark-1.3`, T3 pins `muse-wonder-full-1.0`, and `default` passes no `--model`
  - Google Antigravity CLI (`agy`) for the Gemini and Claude-overflow routes
  - Mistral Vibe 3 or newer (`vibe`, PyPI `mistral-vibe`) with `MISTRAL_API_KEY` in `~/.vibe/.env`; vibe 2 is not supported
- Optional local engine: the `subagent-local-qwen3.8-27b` plugin, a llama.cpp endpoint, the `qwen`
  CLI, `curl`, `jq`, and `flock`. Missing any of them makes local routes report unavailable (exit 75) and
  the pool moves to the next worker.
- `flock` (util-linux) for `handoff-lease.sh`

Only selected providers are required; `pool.sh` skips a provider whose CLI is not installed. `jq` is required for `run-claude.sh --stream-log`, `run-agy.sh`, `run-muse.sh`, `run-vibe.sh`, and the local-Qwen route, all of which extract a final message from a JSON stream; `usage.sh` also needs it. `run-claude.sh --mcp` also uses `jq` to encode each server URL. `run-claude.sh --api` requires `jq` for settings.

## Configuration

Defaults can be overridden without editing the plugin. Overrides must remain in the strict current
catalog.

Check `truncated=` on the exit line of every Grok review or advise leg. Advice marked `truncated=turns` is partial even on exit 0. On `truncated=timeout`, rerun with a larger `--timeout` or use another reviewer before acting on the report or starting a fix cycle.

| Variable | Default | Purpose |
|---|---|---|
| `MMO_CLAUDE_MODEL` | `claude-opus-5-5` | Claude worker/reviewer model |
| `MMO_CLAUDE_EFFORT` | `high` | Claude effort except Haiku |
| `MMO_CODEX_MODEL` | `gpt-6.2-astra` | Codex worker/reviewer model |
| `MMO_GROK_MODEL` | `grok-4.7` | Grok worker/reviewer model |
| `MMO_GROK_EFFORT` | `medium` | Grok reasoning effort |
| `MMO_GROK_MAX_TURNS` | `30` (`60` for review, `150` for implement and probe) | Turn cap of 1–100 (1–300 for implement and probe). Other modes clamp env values above 100. Explicit turn limits take precedence. Review/advise can resume once with the read-only allowlist after hitting the turn cap (`truncated=turns`). If inspection or synthesis times out, the leg exits 124 with `truncated=timeout` and an empty final report. The stream retains any progress. A truncated review cannot approve. An exhausted turn cap without a report exits 78, including in research mode. Review, advise and probe with `--out FILE` default to `FILE.stream` |
| `MMO_GROK_CONTINUE_ON_MAX_TURNS` | `1` | Implement only: finishing `--resume` passes (0-3) after a max-turns stop on a changed tree, within the one `--timeout`; a max-turns stop exits 76 |
| `MMO_MUSE_MODEL` | `muse-spark-1.3` | Direct runner default. `default` passes no `--model`. Pool rows supply their own `--model` |
| `MMO_MUSE_EFFORT` | `medium` | Muse reasoning effort |
| `MMO_MUSE_MAX_STEPS` | `50` | Muse model-step cap, from 1 to 200. A leg that uses its last step exits 76 (implement: work may be partial) or 78 (any other mode: no report) |
| `MMO_VIBE_MODEL` | `default` | Vibe model alias; `default` passes no `--model` |
| `MMO_VIBE_EFFORT` | `default` | Vibe thinking level (`off`, `low`, `medium`, `high`, `xhigh`, `max`; Mistral Large 4 only `low`–`high`); `default` passes no `--thinking` |
| `MMO_VIBE_MAX_TURNS` | `50` | Vibe assistant-turn cap, from 1 to 200. A leg that uses its last turn exits 76 (implement: work may be partial) or 78 (any other mode: no report) |
| `MMO_REVIEW_DIFF_MAX_BYTES` | `1048576` | Maximum diff supplied to Claude/Grok/Muse/agy/Vibe/local-Qwen review |
| `MMO_CONTEXT_WARN_TOKENS` | `400000` | Context size at which the context-watch hook warns a meta-orchestrator |
| `MMO_HANDOFF_DIR` | `.claude/handoffs` | Repo-relative handoff directory in the target repository |
| `MMO_AGY_MODEL` | `gemini-3.8-flash` | agy worker/reviewer model |
| `MMO_AGY_EFFORT` | `medium` | agy effort (`low`, `medium`, `high`) |
| `MMO_POOL_TIERS` | `scripts/pool-tiers.tsv` | Replacement tier table for `pool.sh`, same format |
| `MMO_QWEN_LOCAL_RUN` | discovered | Path to the `subagent-local-qwen3.8-27b` wrapper when it is not on `PATH` or in a plugin cache |
| `MMO_LEG_ENV` | empty | Space-separated variable names (or `PREFIX*` patterns) passed into the scrubbed leg environment, e.g. `DATABASE_URL` for a test database |
| `MMO_ALLOW_ENV_FILES` | `0` | `1` lets legs run in a checkout holding untracked `.env*` files |
| `MMO_LEG_CHECKS_FILE` | `${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator/leg-checks.tsv` | `leg-check.sh` record (one row per check); default `--checks` of `friction-report.sh` |
| `MMO_OUTCOMES_FILE` | `${XDG_STATE_HOME:-$HOME/.local/state}/multi-model-orchestrator/outcomes.tsv` | Runner outcome record; default `--outcomes` of `friction-report.sh` |
| `MMO_HARNESS_ADJUSTMENTS` | `scripts/harness-adjustments.tsv` | Replacement harness-adjustments table, same format |

`MMO_OPUS_MODEL` and `MMO_OPUS_EFFORT` remain compatibility variables for `run-opus.sh`. The old
moving value `MMO_OPUS_MODEL=opus` maps explicitly to `claude-opus-5-5`; versioned IDs older than the previous generation are
still rejected. The default is `claude-opus-5-5` at `high`.

`run-claude.sh` accepts repeatable `--mcp NAME=URL` to attach named HTTP MCP servers to that leg
(for example a local browser server). Each server is `{"type":"http","url":URL}` inside
`--mcp-config`, `--strict-mcp-config` stays on, and `mcp__NAME` is appended to the active mode's
`--allowedTools`. `NAME` must match `[A-Za-z0-9_-]+`. With no `--mcp`, the MCP config stays
`{"mcpServers":{}}`. Encoding `--mcp` uses `jq`.

## Research basis

The routing policy was checked against current primary guidance for
[Claude model selection](https://platform.claude.com/docs/en/about-claude/models/choosing-a-model),
[Claude effort](https://platform.claude.com/docs/en/build-with-claude/effort),
[OpenAI model guidance](https://developers.openai.com/api/docs/guides/latest-model),
[Grok reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning), and the
[Grok Build CLI](https://docs.x.ai/build/cli/reference). Existing Reddit evidence remains clearly
marked as anecdotal and is used only as an operational signal.

## Worker preflight and ship gates

`pool.sh run --mode implement` exits 56 `check=preflight` on a dirty tree (`git status --porcelain`, so ignored and `info/exclude` paths do not count) or when `--task` is a closed GitHub issue. A missing GitHub remote is not a closed issue. `gh` failing to read the issue warns and allows. After a worker exit 0, a still-dirty tree exits 56 `check=uncommitted`, except when the prompt bars committing (`the orchestrator commits`, `leave the tree uncommitted`, `Do not edit any other path or commit`, or `Do not broaden scope or commit`) because that leg's contract says the orchestrator commits. A line that says `Commit on` without `when your leg's contract permits` still requires a commit. Escapes, printed on stderr, are `MMO_ALLOW_DIRTY`, `MMO_ALLOW_REDO`, and `MMO_ALLOW_UNCOMMITTED`, each `=<reason>`. `pick` and `--mode review` are not gated. Exit 55 and timeouts are unchanged.

`hooks/ship-gates.sh` is a `PreToolUse` Bash hook (Claude and Codex share `hooks.json`). Every other command exits 0 without calling git or gh, and an unparseable command or a missing tool is allowed. Configure the target checkout in `.claude/multi-model-orchestrator.local.md` frontmatter:

```yaml
---
push_check: "<bash -c command; absent allows, non-zero blocks>"
test_path_regex: "<optional ERE; default matches common test layouts>"
live_recheck: true
---
```

On `git push` and `git -C <dir> push` (not a delete-ref push), `push_check` runs in the repo. A deleted test path blocks; a rename (`-M`) does not. Net removal of `def test_`, `func Test`, `it(`, or `test(` on test paths blocks. A commit in the push range may carry `Push-Gate: skip — <reason>` or `Test-Deletion: justified — <reason>`. `live_recheck: true` blocks `gh issue close` unless the close comment (`-c`/`--comment`) or an existing comment contains `VERIFIED LIVE:` plus a hex SHA, or `Live-Recheck: no-live-surface — <reason>`. Without that key, close is not checked. A `gh` read failure warns and allows. `gh pr merge` is not this hook.

## Installation

- **Install for you** (user scope) — available in all your projects:
  `/plugin install multi-model-orchestrator@paat-plugins`
- **Install for all collaborators on this repository** (project scope) — commit
  `.claude/settings.json` with the plugin enabled.
- **Install for you, in this repo only** (local scope) — enable it in
  `.claude/settings.local.json`.

## Tests

```bash
bash plugins/multi-model-orchestrator/tests/run-tests.sh
```

The tests stub all model execution and, when Grok Build is installed, also inspect `grok --help`;
they do not call a model or consume quota.

## License

MIT
