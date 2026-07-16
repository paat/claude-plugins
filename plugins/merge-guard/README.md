# merge-guard

Post-merge verification tail. Pre-merge review (tribunal-review and friends)
gates the diff before it lands; this plugin covers the uncovered tail after
the merge: junk dotfiles leaked onto main by a squash merge, a silently
dropped attribution parameter, or a "cleanup" commit that reset
previously-working user-facing options.

## What it does

- **`skills/merge-guard`** — the post-merge workflow: capture the pre-merge
  base and merge commit, run the deterministic check, open a cleanup PR for
  junk, treat invariant violations as regressions to fix or revert, and
  spot-check user-facing behavior adjacent to the touched code (what the diff
  *removed*, not only what it added).
- **`scripts/merge-guard.sh`** — the deterministic part:
  - `check --base <pre-merge-ref> [--head <ref>] [--intended-file F]` — flags
    files **added** in the range matching junk signatures (editor droppings,
    temp/log files, agent-session artifacts; extendable per repo), flags
    changed paths not matched by the intended-globs file, and evaluates
    configured grep-based business invariants at `head`. Exit 3 on findings.
  - `cleanup --base <ref> --apply` — creates a `cleanup/merge-guard-<sha>`
    branch removing the flagged junk, pushes it, and opens a PR (never pushes
    to the default branch directly). Without `--apply` it only prints.

## Requirements

- bash 4+, git. `jq` for the per-repo config; `gh` for `cleanup --apply`.

## Installation

Add this marketplace, then install the plugin at the scope you want:

- **Install for you** (user scope) — available in all your projects:
  `/plugin install merge-guard@paat-plugins`
- **Install for all collaborators on this repository** (project scope) —
  committed to the repo and shared with your team via `.claude/settings.json`.
- **Install for you, in this repo only** (local scope) — just you, just this
  repository, via `.claude/settings.local.json`.

## Configuration (optional)

`.claude/merge-guard.json`: `extra_junk` / `not_junk` glob lists and an
`invariants` array (`{id, path_glob, pattern, must: present|absent, message}`)
— see the skill for a worked example. Junk globs match the full path with `*`
crossing `/`, plus a basename match; invariant `path_glob` uses git pathspec
matching. A path listed by `--intended-file` is still checked independently for
junk: intended globs constrain the changed-file set, but do not whitelist junk.
Use `not_junk` to exempt a deliberate match, or a narrow `extra_junk` glob for
project-specific runtime leakage such as `.startup/reviews/*`; `.startup/`
itself can contain durable tracked artifacts and is not a built-in junk signal.
Filenames containing newlines are unsupported.

## Testing

```bash
bash plugins/merge-guard/tests/run.sh
```
