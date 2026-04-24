# Plan: PLUGIN_ISSUES.md capture (issue #16)

> **SUPERSEDED (2026-04-24):** Resolved differently in saas-startup-team v0.30.1 — option C: agents file GitHub issues directly via `gh issue create --repo paat/claude-plugins`. No `/plugin-issue` slash command; template deleted. Preserved for reference only; not a live plan.

> **Universality rule:** Pure infrastructure. `/plugin-issue` command is project-agnostic. The only hardcoded string is the plugin's OWN GitHub repo (`paat/claude-plugins`) as the target for plugin feedback — this is the plugin's meta-tracker and is not a project-specific detail.

## Goal & Scope

Fix the plugin's self-feedback channel so that friction encountered by agents during real-world use (hook failures, template gaps, contradictory instructions) becomes visible to the plugin maintainer. Current state: zero captured issues despite heavy usage. File exists in plugin checkout; agents nominally told about it; never written to.

**Out of scope**: product-bug capture (stays in `.startup/`), growth learnings, agent memory, CLAUDE.md auto-learnings.

## Root Cause Analysis

Four causes, in order of impact:

**1. Wrong write target (dominant cause).**
Agent instructions say "append to `${CLAUDE_PLUGIN_ROOT}/PLUGIN_ISSUES.md`."
- `${CLAUDE_PLUGIN_ROOT}` expands to the plugin checkout, not the project.
- Verified: downstream projects don't have a `PLUGIN_ISSUES.md` copy. The file was never copied into any project.
- Agents are trained by `enforce-delegation.sh` and surrounding instructions to treat anything outside `.startup/`, `docs/`, `CLAUDE.md` as forbidden. The file "belongs to the plugin" — effectively read-only from an agent's perspective.
- Even if they tried, writes modify the shared plugin checkout — clobbered on next update.

**2. Instruction is buried and passive.**
End of `business-founder.md` (line ~199) and `tech-founder.md` (line ~211), under generic "Plugin Issue Reporting" heading, no trigger condition, no concrete example, no slash command to invoke. Reads as optional.

**3. No mention in skills or commands.**
`grep -rn 'PLUGIN_ISSUES' plugins/saas-startup-team/skills/ plugins/saas-startup-team/commands/` returns nothing. Only referenced inside agent definitions, which get loaded fresh each dispatch. Nothing in the loop surfaces "that looked like a plugin issue, file it."

**4. Format is friction.**
Template asks for `Found by / When / Expected / Actual / Severity / CATEGORY`. Agents don't track "iteration N, phase X" in a paste-ready form. Looks like homework.

Also: `plugins/google-ads-strategist/agents/ads-strategist.md` points at `${CLAUDE_PLUGIN_ROOT}/PLUGIN_ISSUES.md` — same broken pattern elsewhere.

## Options Comparison

| Criterion | A. Kill it | B. Local capture (command + hook) | C. GH issues (`/plugin-issue`) |
|---|---|---|---|
| Implementation cost | ~1 hr | ~4 hr | ~4 hr |
| Works offline | n/a | Yes | No (degrades to local) |
| Auth dependency | None | None | Needs `gh` + auth |
| Survives plugin updates | n/a | Writes *outside* plugin checkout | Yes (GitHub canonical) |
| Maintainer visibility | Zero | Needs user push/share | Immediate |
| Avoids duplicates | n/a | No | Yes (`gh issue list`) |
| Privacy | n/a | Local only | Leaks to public GH unless scrubbed |
| Fork case | n/a | Fine | Only works if fork is upstream |
| Cross-project dedup | n/a | No | Yes |

## Recommendation: Hybrid — C with B as Fallback

`/plugin-issue` slash command that:
1. Tries `gh issue create --repo paat/claude-plugins` (label: `plugin-feedback`, pre-filled title/body from args + git + state.json).
2. On any failure (no `gh`, unauthenticated, no network, rate limited, wrong repo fork), falls back to appending to `<project>/.startup/plugin-issues.md` inside the project — not plugin checkout. Tells the user exactly where it went and how to file manually.

**Why hybrid over pure C**: plugin can't assume every user has `gh` installed/authed. Verified: plugin itself doesn't currently shell to `gh` anywhere. Hard-requiring breaks offline and fork stories.

**Why hybrid over pure B**: local-only replicates status quo — friction data invisible to maintainer.

**Why not A (kill it)**: issue explicitly says "any beats status quo." Killing loses the discoverable affordance.

## Detailed Design

### 1. New slash command: `plugins/saas-startup-team/commands/plugin-issue.md`

Frontmatter:
```yaml
---
name: plugin-issue
description: Report a bug or friction in the saas-startup-team plugin itself (hooks, templates, agent instructions, command flow). Opens a GitHub issue on paat/claude-plugins, or falls back to a local file if gh is unavailable. Usage: /plugin-issue [short description]
user_invocable: true
---
```

Procedure:
1. **Parse args.** If none, ask: "Describe the plugin issue in one sentence."
2. **Classify.** Ask/infer category: `HOOK | TEMPLATE | AGENT | MCP | STATE | COMMAND | OTHER`. Default `OTHER`.
3. **Gather context** (read-only):
   - `git rev-parse --show-toplevel` → project path
   - `.startup/state.json` → iteration, phase, active_role (if present)
   - Last handoff filename (most recent in `.startup/handoffs/`)
   - Plugin version: `git -C "$CLAUDE_PLUGIN_ROOT/../.." describe --tags --always 2>/dev/null` (best-effort)
   - OS / Claude Code version (best-effort)
4. **Check `gh` availability** with short-timeout probes:
   - `command -v gh`
   - `gh auth status`
   - `gh repo view paat/claude-plugins --json name -q .name`
5. **Deduplicate** (if step 4 passed): `gh issue list --repo paat/claude-plugins --label plugin-feedback --search "<title-ish>" --state open`. If strong match (≥80% title overlap), offer comment instead of new issue.
6. **Primary path — open issue**:
   ```bash
   gh issue create --repo paat/claude-plugins \
     --title "[saas-startup-team] <short description>" \
     --label plugin-feedback \
     --label "cat:<category-lowercased>" \
     --body "$(cat <<'EOF'
   ## Context
   - Plugin: saas-startup-team
   - Category: <CATEGORY>
   - Reporter: <business-founder|tech-founder|investor|other>
   - Project iteration: <N, phase=X>
   - Last handoff: <NNN-...>
   - Plugin version: <git describe>

   ## Expected
   <one or two sentences>

   ## Actual
   <one or two sentences; include verbatim error/hook-output if any>

   ## Reproduction hint
   <the user-prompt / command / file path that triggered it>

   ## Severity
   blocker | major | minor
   EOF
   )"
   ```
   Print issue URL.
7. **Fallback path** (step 4 or 6 fails):
   - Append to `<project>/.startup/plugin-issues.md` (lowercased, project-local).
   - Create with header/categories if missing.
   - Print: "`gh` unavailable (reason). Appended to `.startup/plugin-issues.md`. Submit later: `gh issue create --repo paat/claude-plugins -F .startup/plugin-issues.md` or open <https://github.com/paat/claude-plugins/issues/new>."
8. **Ask once, never loop.** If fallback also fails, print rendered body; user pastes manually. Never silently drop.

### 2. Agent instruction updates

Replace passive "Plugin Issue Reporting" section in `business-founder.md` / `tech-founder.md` with actionable trigger-based block:

```markdown
## Plugin Issue Reporting

When you hit a problem with the **plugin itself** — not the product you're building — report it with the slash command rather than burying the observation in your handoff.

**Triggers (any of these → file a plugin issue):**
- A hook blocked you with a message that looked wrong, unclear, or contradicted your instructions.
- A template referenced in `${CLAUDE_PLUGIN_ROOT}/templates/` was missing, broken, or didn't match what you were told to produce.
- Your agent instructions (this file or a skill) contradicted another instruction, or gave you no path forward.
- An MCP tool call failed with what looks like a plugin configuration error.
- A plugin slash command referenced something that doesn't exist.

**How to file:**
Tell the team lead: `FILE_PLUGIN_ISSUE: <one-line description> [category: HOOK|TEMPLATE|AGENT|MCP|STATE|COMMAND]`. The team lead will run `/plugin-issue` to submit it. Do NOT write to `${CLAUDE_PLUGIN_ROOT}/PLUGIN_ISSUES.md` directly — it lives in the shared plugin checkout and your writes would be lost on the next plugin update.

**What NOT to file as a plugin issue:** product bugs, UX feedback on the product being built, feature requests for the product, human-only tasks. Those stay in `.startup/` files.
```

The "tell the team lead" relay leverages existing communication channel rather than asking founders to invoke slash commands themselves (they can't — `/plugin-issue` is user-invocable, executed by orchestrator).

### 3. Team lead update (`commands/startup.md`)

New sub-section under Step 5 "Relay Handoffs":
```markdown
### When a founder signals "FILE_PLUGIN_ISSUE: <description> [category: X]"

Immediately invoke `/plugin-issue "<description>"` with the named category. Do not block the loop on it — after the issue is filed (or fallback-written), resume relaying handoffs. Briefly tell the investor what was filed and the GitHub URL (or fallback path).
```

### 4. Hook / delegation tightening

`scripts/enforce-delegation.sh` currently has an exception for `PLUGIN_ISSUES.md` (around line 74). Remove it — agents are no longer supposed to write there, so the exception exists to allow a bug. The `.startup/plugin-issues.md` fallback is already covered by `^\.startup/` rule.

### 5. Template & README compensations

- `plugins/saas-startup-team/PLUGIN_ISSUES.md` → maintainer-facing pointer: "Plugin issues are filed on GitHub at <https://github.com/paat/claude-plugins/issues?q=label:plugin-feedback>. Users and agents: run `/plugin-issue` (or file directly on GitHub). This file is no longer appended to." Keep category list for reference.
- `plugins/saas-startup-team/README.md` — short "Reporting plugin bugs" section pointing at `/plugin-issue` and GH tracker.
- `plugins/google-ads-strategist/agents/ads-strategist.md` line ~146 — fix broken reference. Point to GitHub issue tracker directly.

### 6. Tests

Update `plugins/saas-startup-team/tests/run-tests.sh` Suite J:
- **J1 keep**: `PLUGIN_ISSUES.md` exists (maintainer note).
- **J2 replace**: contains GitHub link + `/plugin-issue` mention.
- **J3 drop**: "What Goes Here" no longer required.
- **J4 drop**: "What Does NOT Go Here" no longer required.
- **J5/J6 spirit**: `business-founder.md`, `tech-founder.md` mention `FILE_PLUGIN_ISSUE` (new).
- **Add J7**: `commands/plugin-issue.md` exists.
- **Add J8**: `commands/startup.md` references `FILE_PLUGIN_ISSUE`.
- **Add J9**: `scripts/enforce-delegation.sh` no longer has `PLUGIN_ISSUES\.md$` exception.

## Agent Instruction Changes (concrete)

| File | Change |
|---|---|
| `plugins/saas-startup-team/agents/business-founder.md` | Replace with new block |
| `plugins/saas-startup-team/agents/tech-founder.md` | Same |
| `plugins/saas-startup-team/agents/business-founder-maintain.md` | Same |
| `plugins/saas-startup-team/agents/tech-founder-maintain.md` | Same |
| `plugins/saas-startup-team/agents/growth-hacker.md` | Same |
| `plugins/saas-startup-team/agents/lawyer.md` | Same |
| `plugins/saas-startup-team/agents/ux-tester.md` | Same |
| `plugins/google-ads-strategist/agents/ads-strategist.md` | Point to GitHub tracker directly |

## Files to Create / Modify / Delete

### Create
- `plugins/saas-startup-team/commands/plugin-issue.md`

### Modify
- Seven agent files above
- `plugins/saas-startup-team/commands/startup.md` — `FILE_PLUGIN_ISSUE` relay
- `plugins/saas-startup-team/PLUGIN_ISSUES.md` — rewrite as pointer
- `plugins/saas-startup-team/README.md` — "Reporting plugin bugs" section
- `plugins/saas-startup-team/scripts/enforce-delegation.sh` — remove exception
- `plugins/saas-startup-team/tests/run-tests.sh` — update Suite J
- `plugins/google-ads-strategist/agents/ads-strategist.md` — fix reference

### Delete
None. Repurpose existing `PLUGIN_ISSUES.md`.

## Step-by-Step Implementation Order

1. **Build `commands/plugin-issue.md`** — single load-bearing artifact.
2. **Smoke test manually** — `/plugin-issue "test"` with `gh` available → draft issue opens; simulate failure (unset `GH_TOKEN`, rename `gh` on PATH) → fallback writes to `.startup/plugin-issues.md`.
3. **Update team-lead relay** in `startup.md`.
4. **Update seven agent files** in one commit — consistency matters.
5. **Rewrite `PLUGIN_ISSUES.md`** as pointer.
6. **Update `README.md`** with reporting section.
7. **Remove exception** from `enforce-delegation.sh`.
8. **Update Suite J** in `run-tests.sh`. Run full suite; fix fallout.
9. **Fix stragglers** (ads-strategist).
10. **Manual end-to-end**: throwaway `/startup` session, business-founder reports fake plugin issue via `FILE_PLUGIN_ISSUE:`, confirm orchestrator routes it and GH issue appears. Close test issue.
11. **Commit with CHANGELOG entry** referencing #16.

## Open Questions

1. **Forks.** If user forked `paat/claude-plugins`, should `/plugin-issue` target fork or upstream? Upstream canonical; document override via env var if ever requested.
2. **Privacy.** Auto-gathered context can leak project info. Require explicit confirmation; show rendered body; let user edit. ~10 lines addition.
3. **Rate limits.** On `gh: auth required`, tell user specifically "run `gh auth login`" before fallback.
4. **Labels.** Does `paat/claude-plugins` have `plugin-feedback`, `cat:hook`, etc.? If not, `--label` fails. Pre-create labels manually OR have command tolerate missing labels (retry without).
5. **Scope: just saas-startup-team, or shared?** Four other plugins reference `PLUGIN_ISSUES.md`. Ship this iteration as saas-startup-team-local (`/saas-startup-team:plugin-issue`). If adoption good, extract into shared utility plugin in follow-up.
6. **Existing PLUGIN_ISSUES.md entry** — only the format-spec example. Safe to remove on repurpose.

## Critical Files for Implementation

- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/commands/plugin-issue.md` (new)
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/commands/startup.md`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/agents/business-founder.md`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/agents/tech-founder.md`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/enforce-delegation.sh`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/tests/run-tests.sh`
