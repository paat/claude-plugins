# Plan: worktree support (issue #15)

> **SUPERSEDED (2026-04-24):** Worktree isolation for saas-startup-team was scoped and abandoned as too complex. Preserved for reference only; not a live plan.

> **Universality rule:** Pure infrastructure. Directory layout, port formula, opt-in signal, and lifecycle are all generic. No project-specific strings enter the plugin.

## Goal & Scope

Eliminate the gap between (a) the plugin's single-branch handoff model and (b) the reality in long-running projects where parallel branch work is routine (one PR still in review, another handoff opens to replace it). Provide opt-in git worktree isolation for tech-founder implementation work so a closed PR's branch no longer shares a working copy — and therefore a running dev server — with the next in-flight handoff.

**Out of scope**: mandatory worktrees for every user, worktree support for business-founder / QA / lawyer / growth-hacker, multi-repo projects, migrating ongoing handoffs mid-flight.

## Decision: Wire It Up (Option A)

**Evidence**:
1. There's no actual stub — `grep -rn -i 'worktree' plugins/saas-startup-team/` returns zero hits. The "stub" is a reference in the bug report only.
2. The problem is real: a downstream project has 471+ handoffs on one working copy and carries a hard-won rule ("NEVER trust localhost:3000 after switching git branches — check `ps aux` start times"). That scar exists precisely because a dev-server started on branch X keeps serving branch X's bytes after `git checkout branch-Y` — what worktrees fix.
3. Superpowers plugin ships a production-grade `using-git-worktrees` skill. Delegate rather than reinvent — shrinks change surface to glue points.
4. Handoff = one cohesive unit of implementation work = the exact granularity a worktree wants.

**Justification against B (remove stub)**: removing a stub that doesn't exist documents ignorance of a real problem.

## Integration Model

Current arc:
```
business-founder writes .startup/handoffs/NNN-business-to-tech.md
  → team lead relays → tech-founder reads handoff
    → tech-founder implements in $repo_root
      → writes .startup/handoffs/NNN+1-tech-to-business.md
      → auto-commit.sh stages + commits on default branch
```

Proposed arc (opt-in):
```
business-founder writes .startup/handoffs/NNN-business-to-tech.md
  → team lead checks "worktree mode enabled?" (see opt-in)
  → if enabled: instructs tech-founder to invoke
       Skill('superpowers:using-git-worktrees')
       with branch = feature/handoff-NNN  location = .startup/worktrees/NNN/
  → tech-founder implements inside the worktree dir
  → writes handoff to SHARED .startup/ (absolute path to main repo)
  → business-founder QA navigates to worktree's dev-server port
  → roundtrip signoff triggers worktree cleanup
```

**Critical state-machine details**:
- `.startup/state.json` is single source of truth. Worktrees share it because `.startup/` is at repo root — `git worktree add` doesn't give the new branch a separate `.startup/`. Tech-founder `cd`s into worktree for code edits but writes handoffs to main repo's `.startup/handoffs/` via absolute path.
- New optional `active_worktree` field in state.json: `{"worktree": ".startup/worktrees/NNN/", "branch": "feature/handoff-NNN", "pid": <dev-server-pid>}`.
- Handoff files stay sequentially numbered globally — worktrees don't fork numbering.

## Directory Layout + Lifecycle

**Location: `.startup/worktrees/<handoff-N>/`.**

Rationale:
- `.startup/` already gitignored. Inherits no new rules. Superpowers skill's safety check (`git check-ignore`) passes.
- `<handoff-N>` naming matches existing mental model (everything in `.startup/` keyed by handoff/iteration number).
- Branch-name keying duplicates info already in the branch name; forces two identifiers.

**Rejected**: global `~/.config/superpowers/worktrees/<project>/` — survives `rm -rf .startup/` but requires second path. For saas-startup-team, per-project state wins.

**Lifecycle**:

| Phase | Trigger | Action |
|---|---|---|
| Creation | tech-founder dispatch, worktree mode ON | `Skill('superpowers:using-git-worktrees')` with path `.startup/worktrees/NNN/`, branch `feature/handoff-NNN` |
| Switching | team lead relay | Relay includes absolute worktree path; tech-founder `cd`s there first |
| QA | business-founder browser review | Team lead includes localhost URL + port + worktree path |
| Cleanup on merge | PR merged | Team lead: `git worktree remove .startup/worktrees/NNN --force` + `git branch -d feature/handoff-NNN` |
| Cleanup on abandon | handoff replaced | Same, but warn investor before removing unmerged commits |
| Orphan sweep | `/startup` Step 3 | For each worktree, check open PR; if none + no uncommitted changes, offer to prune |

## Dev-Server / Process Management

Load-bearing part. Worktrees only help if the dev server at port P serves the right worktree's bytes.

**Convention: port = 4000 + handoff_number % 1000.** Handoff 470 → port 4470. Up to 1000 concurrent worktrees; deterministic from handoff number alone.

- Tech-founder instructions (in `agents/tech-founder.md` Development Server section): compute port as above when worktree mode on; use 4000 otherwise.
- Handoff template adds `dev_port: <computed port>` frontmatter.
- `active_worktree.pid` tracks dev-server PID so cleanup can kill it before `git worktree remove`.
- Business-founder reads `dev_port` from handoff frontmatter (existing pain point: scanning prose for "localhost:NNNN").
- Loose convention, not hard guarantee — documenting the formula is enough.

## Reuse of Superpowers Skill

**Delegate, don't reimplement.** Skill handles directory priority, `git check-ignore` safety, branch creation, install auto-detection, baseline test run.

saas-startup-team wires up around it:
1. `skills/tech-founder/references/worktree-workflow.md` — tells tech-founder when and how to invoke the skill (with handoff-N naming, `.startup/worktrees/` location).
2. Team lead relay gains conditional block: "worktree mode enabled — before implementing, invoke `Skill('superpowers:using-git-worktrees')` with branch `feature/handoff-NNN`, location `.startup/worktrees/NNN/`. After ready, cd and implement."
3. Cleanup on merge/abandon: `scripts/worktree-cleanup.sh` (two commands, not worth a skill).
4. Superpowers dependency: **document in README prerequisites**. If user doesn't have it installed, worktree mode doesn't activate (fail soft).

## Backward Compatibility / Opt-In

**Zero behaviour change for existing users is non-negotiable.**

**Opt-in signal: presence of `.startup/worktrees/` directory.**
- To opt in: `mkdir .startup/worktrees/`.
- `/bootstrap` does NOT create by default. Creates only if user passes `--with-worktrees`.
- `/startup` checks existence once, caches in `state.json` as `worktree_mode: true|false`. Subsequent relays key off that field.
- Matches `.startup/improvements/` precedent (directory-presence-driven).

**Rejected alternatives**:
- CLAUDE.md flag — requires parsing markdown.
- `settings.json` field — plugin-level not project-level; wrong scope.
- `.startup/config.json` — no such file exists; introducing for one flag is overkill.

Existing users who never run `mkdir .startup/worktrees/` see today's behaviour forever.

## Files to Create / Modify

### Create
| Path | Purpose |
|---|---|
| `plugins/saas-startup-team/skills/tech-founder/references/worktree-workflow.md` | When/how tech-founder invokes superpowers skill |
| `plugins/saas-startup-team/scripts/worktree-cleanup.sh` | `git worktree remove` + branch delete + kill dev-server PID |
| `plugins/saas-startup-team/scripts/check-worktree-mode.sh` | Returns 0 if `.startup/worktrees/` exists |

### Modify
| Path | Change |
|---|---|
| `plugins/saas-startup-team/commands/bootstrap.md` | Optional Step 3b: `--with-worktrees` opt-in, `mkdir -p .startup/worktrees/`, add `.startup/worktrees/` to gitignore |
| `plugins/saas-startup-team/commands/startup.md` | Step 2: detect `.startup/worktrees/`, write `worktree_mode`. Step 3: orphan-worktree sweep. Step 5: conditional relay instructions |
| `plugins/saas-startup-team/agents/tech-founder.md` | Dev Server section: port formula. Worktree Mode subsection → new skill reference |
| `plugins/saas-startup-team/agents/business-founder.md` | Browser Verification: read `dev_port` from handoff frontmatter |
| `plugins/saas-startup-team/templates/handoff-tech-to-business.md` | Frontmatter: add `dev_port`, optional `worktree_path` |
| `plugins/saas-startup-team/scripts/auto-commit.sh` | Handle Write from inside worktree subdir — use `git rev-parse --path-format=absolute --git-common-dir` or `git worktree list` to normalise. **Trickiest change; needs test matrix.** |
| `plugins/saas-startup-team/README.md` | Prerequisites: document optional superpowers dependency. New "Parallel work support" section |
| `plugins/saas-startup-team/skills/startup-orchestration/references/handoff-protocol.md` | One paragraph on worktree-mode flow |

### Do NOT Touch
- `hooks/hooks.json` — lifecycle is command-driven, not event-driven.
- `check-*`, `validate-*` scripts — worktrees don't change what counts as valid handoff.
- `check-idle.sh`, `check-stop.sh` — read `.startup/state.json` which remains canonical.

## Step-by-Step Implementation Order

1. **Audit `auto-commit.sh` behaviour from inside a worktree.** Run `git rev-parse --show-toplevel` and `git rev-parse --git-common-dir` in a test worktree; confirm path resolution. Determines fix in step 6. (30 min, read-only.)
2. **Write `skills/tech-founder/references/worktree-workflow.md`** — pure doc.
3. **Write `scripts/worktree-cleanup.sh`** + `scripts/check-worktree-mode.sh`. Unit-test in scratch repo.
4. **Modify `/bootstrap`** — add opt-in + gitignore line. Does nothing for existing users.
5. **Modify `/startup`** — detect mode, write state, emit conditional instructions.
6. **Modify `auto-commit.sh`** based on step 1. Test matrix: (main, dirty docs/) × (worktree, dirty backend/) × (both, dirty).
7. **Modify `tech-founder.md` + handoff-tech-to-business template.** Port formula + frontmatter.
8. **Modify `business-founder.md`.** Read `dev_port` from frontmatter.
9. **Modify `README.md` + handoff-protocol.md.** Documentation.
10. **End-to-end dry run** in scratch repo: `mkdir .startup/worktrees/`, `/startup`, walk handoff cycle, confirm worktree created, dev-server on computed port, handoff written, auto-commit works, cleanup script removes cleanly.
11. **Migration note**: do NOT opt existing projects in mid-stream; create fresh project to validate.

Sequencing rationale: steps 2–4 are additive and invisible to existing users. Step 6 touches shared code paths so it's gated on step 1's audit.

## Trade-offs

| Decision | Upside | Downside |
|---|---|---|
| Directory-presence opt-in | Zero migration; `/improve` precedent | Users must discover opt-in |
| `.startup/worktrees/<N>/` | Inherits gitignore; one mental model | Diverges from superpowers default `.worktrees/` |
| Handoff-N naming | Less duplication | If handoff split (001→001a/001b) 1:1 breaks; unlikely |
| Port = 4000 + N%1000 | Deterministic, no discovery needed | Collides at N=1000, 2000… (document limitation) |
| Delegate to superpowers skill | Small surface; quality is Anthropic's | Soft dependency — silent fail without it |
| Shared `.startup/` across worktrees | One source of truth | Concurrent writes could race; mitigated by "one active handoff" invariant |
| `auto-commit.sh` adjustment | Works in both modes | Riskiest change; if wrong, breaks commits everywhere |

## Open Questions

1. **True parallel handoffs or just branch isolation?** Real pattern is sequential-with-overlap (N+1 opens while N's PR in review), not two tech-founders simultaneously. Proposal: single-active enough for v1.
2. **Shared or split `.startup/` per worktree?** Shared now. If ever two agents run in parallel, race condition on `state.json`. Solvable via file lock.
3. **Business-founder QA in worktree?** No code edits today; recommend no, unless QA spawns feedback handoff.
4. **`/improve` interaction?** Defer to follow-up. Recommend: `/improve` creates its own `.startup/worktrees/improvements-NNN/` or ignores worktree mode entirely.
5. **`/startup worktree-prune` command?** Orphan sweep in Step 3 may be enough; dedicated command nice-to-have, not required.
6. **`pkill -f 'agent-type saas-startup-team'` vs worktree dev-server?** Dev-server isn't an agent process; survives. Verify cleanup loop distinguishes.

## Critical Files for Implementation

- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/commands/startup.md`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/commands/bootstrap.md`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/agents/tech-founder.md`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/scripts/auto-commit.sh`
- `/mnt/data/ai/claude-plugins/plugins/saas-startup-team/templates/handoff-tech-to-business.md`
