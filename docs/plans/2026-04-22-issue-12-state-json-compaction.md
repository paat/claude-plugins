# Plan: compact state.json (issue #12)

> **Universality rule:** Pure infrastructure change — nothing in this plan is project-specific. Downstream data is cited only to size the problem. Allowlists, archive format, and compaction algorithm are domain-agnostic.

## 1. Goal & Scope

Prevent unbounded growth of `.startup/state.json` in long-running projects. Target: fresh project stays under 30 lines through 100 handoffs; existing projects (observed: 417 lines / ~34 KB / 471 handoffs) get a safe one-shot migration.

**In scope**: schema redesign, compaction algorithm, archive file, migration script, plugin script compatibility, tests, template/doc updates.

**Out of scope**: changing the handoff markdown format, changing per-role guidance beyond the allowed-keys list, rewriting agent orchestration.

## 2. Schema Audit

Reading every consumer in the plugin (`grep -l state.json plugins/saas-startup-team/scripts/*.sh`), keys fall into three classes.

| Key pattern | Class | Read by plugin? | Action |
|---|---|---|---|
| `iteration` | A keep | `status.sh`, `check-stop.sh`, `check-idle.sh`, `check-task-complete.sh`, tests | KEEP inline |
| `phase` | A keep | `check-stop.sh`, `check-idle.sh`, tests | KEEP inline |
| `active_role` | A keep | `enforce-delegation.sh`, tests | KEEP inline |
| `status` | A keep | tests | KEEP inline |
| `max_iterations` | A keep | `/startup` iteration-limit gate, tests | KEEP inline |
| `started`, `resumed` | A keep | tests, human-readable timeline | KEEP inline |
| `growth_*` (phase, status, iteration, started, resumed, last_activity, last_brief, last_report) | A keep | Written by `/growth` (canonical) | KEEP inline |
| `agent_handoffs` (object) | A keep | Per-founder tally; tiny | KEEP inline |
| `handoff_NNN_*` (ready/scope/result/pr/signoff/etc.) | C redundant | **Zero plugin reads** (`grep -rn 'handoff_[0-9]'` = 0 hits). Same info lives in handoff markdown files. | DROP from inline (optional: archive compact index) |
| `iterationN_signoff` / `iterationN_resume` / `signoff_vN` / `<feature>_signoff` / `<feature>_complete` / `<feature>_result` | B archival | Zero plugin reads. | ARCHIVE |
| Ad-hoc descriptors (`security_review_tasks`, `regression_result`, `email_campaign_note`, free-form notes, spec pointers, etc.) | B archival | Zero plugin reads. | ARCHIVE |

**Bottom line**: only ~15 coordination keys need to stay inline. Everything else moves to archive or is dropped.

## 3. New Schema (before/after)

**Before** (observed worst case, ~34 KB / 417 lines):
```json
{
  "max_iterations": 160, "status": "active", "started": "...", "resumed": "...",
  "growth_phase": "launch", "iteration": 13, "phase": "review",
  "signoff_v2": "...", "iteration8_signoff": "...",
  "handoff_471_result": "APPROVED — ...", ...  // hundreds more
}
```

**After** (target: < 30 lines):
```json
{
  "schema_version": 2,
  "max_iterations": 160,
  "status": "active",
  "started": "2026-02-25T12:00:00Z",
  "resumed": "2026-04-19T09:25:00Z",
  "iteration": 13,
  "phase": "review",
  "active_role": "business-founder",
  "growth_phase": "launch",
  "growth_status": "active",
  "growth_iteration": 2,
  "growth_started": "...",
  "growth_resumed": "...",
  "growth_last_activity": "...",
  "growth_last_brief": 399,
  "growth_last_report": 366,
  "agent_handoffs": {"business-founder": 1, "tech-founder": 1},
  "latest_handoff": 471,
  "archived_through": 461
}
```

**New scalars**:
- `schema_version` (int): enables future migrations.
- `latest_handoff` (int): fast replacement for scanning handoffs dir if scripts later want it.
- `archived_through` (int): highest handoff number whose keys have been moved out.

**Allowed-inline allowlist** (enforced by migration + helper):
```
schema_version, max_iterations, status, started, resumed,
iteration, phase, active_role,
growth_phase, growth_status, growth_iteration, growth_started,
growth_resumed, growth_last_activity, growth_last_brief, growth_last_report,
agent_handoffs, latest_handoff, archived_through
```

## 4. Archive Format

**Location**: `.startup/state-archive.json` (single file, append-only in practice). Gitignored (same rule as `state.json`).

**Shape** — top-level `entries` array for JSON validity (existing `validate-json.sh` still passes):
```json
{
  "schema_version": 2,
  "entries": [
    {
      "archived_at": "2026-04-22T10:00:00Z",
      "archived_through_handoff": 461,
      "keys": {
        "handoff_461_ready": "...",
        "handoff_461_signoff": "...",
        "handoff_461_result": "APPROVED — ...",
        "iteration8_signoff": "...",
        "signoff_v2": "..."
      }
    }
  ]
}
```

Each compaction appends one entry. Never rewrites existing entries — single safety property.

## 5. Compaction Trigger

**Opportunistic + manual.**

1. **Opportunistic**: new `scripts/compact-state.sh` runs as a **PostToolUse (Write) hook** scoped to `.startup/handoffs/*.md`. On each handoff write:
   - Count `handoff_[0-9]+_*` keys, group by handoff number.
   - If (highest - `archived_through`) > **10** (inline window), compact to `highest - 10`.
   - Otherwise exit 0.
2. **Manual**: `/status --compact` forces compaction. For first-time adoption and debugging.
3. **Threshold**: keep last 10 handoffs inline. Tunable via `STARTUP_INLINE_HANDOFFS` env.

## 6. Compaction Algorithm (pseudocode)

```
compact_state(state_path, archive_path, inline_window=10):
  flock state.json                     # prevent races
  state = read_json(state_path)
  handoff_keys = [k for k in state if matches /^handoff_(\d+)_/]
  if len(unique_handoff_numbers) <= inline_window: no-op

  keep_from = sorted(numbers)[-inline_window]
  archive_cutoff = keep_from - 1

  to_archive = { k:v for k,v in state if:
                 (matches /^handoff_(N)_/ and N <= archive_cutoff)
                 OR matches /^iteration\d+_(resume|signoff)/
                 OR in HISTORICAL_KEY_ALLOWLIST
                 OR (not in INLINE_ALLOWLIST and not growth_ and not handoff_) }

  if empty: no-op

  # 1. Append archive (atomic tmp+rename)
  # 2. Rewrite state without to_archive keys (atomic tmp+rename)
  # Ordering ensures crash-safety: any interruption leaves either old state
  # or (new archive + new state) — never a lossy intermediate.
```

## 7. Migration of Existing Projects

One-shot script: `scripts/migrate-state.sh`.

**Flags**:
- `--dry-run` (default): prints planned moves, writes nothing.
- `--yes`: performs migration. Creates `.startup/state.json.bak-YYYYMMDD-HHMMSS` first.
- `--inline-window N`: override default (10).

**Steps**:
1. Verify state.json exists + parses.
2. Timestamped backup.
3. Run compaction with default window.
4. Validate: both files valid JSON, round-trip equals original minus explicit-drop keys.
5. Print summary: lines/bytes before/after, count archived.

Smoke-test path: run against a fixture seeded from a real long-running project (dry-run first).

## 8. Script Compatibility (no breakage)

| Script | Reads | Affected? |
|---|---|---|
| `status.sh` | `jq '.'` full dump + `.iteration` | Preserved → no change |
| `check-stop.sh` | `.iteration`, `.phase` | Preserved → no change |
| `check-idle.sh` | `.iteration`, `.phase` | Preserved → no change |
| `check-task-complete.sh` | `.iteration` | Preserved → no change |
| `enforce-delegation.sh` | `.active_role` | Preserved → no change |
| `validate-json.sh` | syntactic only | Post-compaction output valid → no change |

Zero script edits required for correctness.

Agent docs (`business-founder.md`, `tech-founder.md`) already say "only update fields relevant to your role". Tighten with **explicit allowlist** + note: *"Do not add `handoff_NNN_*` keys — the handoff markdown file is the source of truth."*

## 9. Files to Create / Modify

**Create**:
- `plugins/saas-startup-team/scripts/compact-state.sh` — compaction engine, idempotent, safe from a hook.
- `plugins/saas-startup-team/scripts/migrate-state.sh` — migration wrapper with `--dry-run`/`--yes` + backup.
- `plugins/saas-startup-team/commands/compact-state.md` OR add `--compact` flag to `/status`.
- Tests in `plugins/saas-startup-team/tests/run-tests.sh`:
  - N1: fresh project after 100 simulated handoffs → state.json ≤ 30 lines.
  - N2: compaction preserves coordination keys.
  - N3: migration dry-run doesn't change files.
  - N4: migration with `--yes` creates .bak, halves byte size on a seeded fixture.
  - N5: archive + inline round-trip.
  - N6: no-op when count ≤ threshold.
  - N7: archive file is valid JSON after 3 successive compactions.
  - N8: `flock` safety under concurrent runs.

**Modify**:
- `plugins/saas-startup-team/hooks/hooks.json` — add PostToolUse(Write) entry for `compact-state.sh` (script self-gates on file_path = `.startup/handoffs/*.md`).
- `plugins/saas-startup-team/commands/startup.md` — initialise state.json with `schema_version: 2`, `archived_through: 0`, `latest_handoff: 0`.
- `plugins/saas-startup-team/commands/status.md` — document `--compact`.
- `plugins/saas-startup-team/commands/bootstrap.md` — add `.startup/state-archive.json` to gitignore.
- `plugins/saas-startup-team/agents/business-founder.md` — explicit inline allowlist + "no per-handoff keys".
- `plugins/saas-startup-team/agents/tech-founder.md` — same.
- `plugins/saas-startup-team/agents/business-founder-maintain.md`, `tech-founder-maintain.md` — same (if they duplicate state-management guidance).
- `plugins/saas-startup-team/README.md` — document schema_version and archive file.

## 10. Step-by-Step Implementation Order

1. Write `compact-state.sh` behind `--dry-run` default. Exercise against a copy of a long-running project's state.json.
2. Write `migrate-state.sh`. Run dry-run against fixture; verify no data loss.
3. Add tests N1–N8.
4. Wire `compact-state.sh` into `hooks.json` as PostToolUse(Write), gated to handoff files.
5. Update `startup.md` init to emit schema v2 defaults.
6. Update `business-founder.md` / `tech-founder.md` with explicit allowlist.
7. Update `bootstrap.md` gitignore.
8. Add `/status --compact` (lighter than a new command).
9. Run full test suite.
10. Document migration path in README; close issue.

## 11. Risks

- **State corruption during compaction** — mitigated: `flock`, archive-first ordering, atomic `tmp+rename`, timestamped `.bak`, `--dry-run` default.
- **Concurrent writes from two founders** — advisory today. Compaction adds `flock` around its window only. Unchanged pre-existing risk on coordination scalars.
- **Auto-commit picking up `state-archive.json`** — add to gitignore block.
- **validate-json hook race**: compaction uses atomic rename (not Edit/Write) so the hook doesn't fire on compaction output.
- **Lost historical context**: no agent/script reads handoff keys from state.json; historical info still greppable in archive + handoff markdown files.

## 12. Open Questions

1. **`/status` surface archive?** One-liner ("Archive: N entries at `.startup/state-archive.json`"); don't dump.
2. **Inline window = 10 — too aggressive?** Tuning knob (`STARTUP_INLINE_HANDOFFS`) makes reversible.
3. **Drop vs archive truly redundant keys?** Conservative: archive everything on first migration (zero data loss); drop on steady-state from then on. `--drop-redundant` flag supports both.
4. **schema v1 → v2 detection on `/startup` resume**: prompt once rather than auto-migrate.
5. **Second-tier archive** for very long-running projects: defer; archive remains trivial for years.

## Critical Files for Implementation

- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/compact-state.sh` (new)
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/migrate-state.sh` (new)
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/hooks/hooks.json`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/commands/startup.md`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/tests/run-tests.sh`
