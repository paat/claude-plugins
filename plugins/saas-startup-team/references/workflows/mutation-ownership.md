# Mutation ownership gates

Use these gates around every model-backed phase. The supervisor creates and verifies
them; workers never run, edit, or remove guard files.

## Role boundary

Before dispatch, derive the smallest exact allowlist from the accepted brief and create
a guard in the Git directory. Mint a fresh one-use authentication token and keep it only
in the supervisor's context: never put it in a worker prompt, handoff, file, environment,
process argument, or event. Feed it only to the gate's stdin after the worker has exited.

```bash
MUTATION_AUTH=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/mutation-auth-token.sh")
ROLE_GUARD="$(git rev-parse --git-path "saas-startup-team/role-${run_id}-${phase}.json")"
guard=(bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-mutation-guard.sh"
  --snapshot "$ROLE_GUARD" --auth-stdin)
for path in "${ROLE_ALLOWED_PATHS[@]}"; do guard+=(--allow "$path"); done
"${guard[@]}" <<<"$MUTATION_AUTH"
```

Verify it immediately when the worker returns, before reading its verdict or handoff:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/delivery-mutation-guard.sh" \
  --verify "$ROLE_GUARD" --auth-stdin <<<"$MUTATION_AUTH"
```

A non-zero result rejects the phase. Do not commit, push, or silently restore the
worker's unauthorized writes; report the paths and clean only the isolated attempt.
The guard's authenticated active marker disables PostToolUse artifact auto-commits while
the worker runs, so HEAD cannot advance between snapshot and verification. Successful
verification also imports the preflighted, privacy-safe event receipts before removing
the marker; an authenticated import marker makes interrupted batches resumable without
re-accepting product mutations. On rejection, leave the active marker in place until the
supervisor cleans the isolated attempt. After verification and, for a tech phase, after the gated
product commit, replay the deferred deterministic hooks: run `index-handoff.sh` for an
exact new handoff, then `compact-state.sh`; run `auto-learn.sh` and route any returned
learning write through a fresh exact-path artifact guard. In an artifact-only business
phase, the supervisor must persist each verified durable `docs/` artifact separately
with `commit-artifact.sh`; that helper never executes repository hooks. Reviews and
other ephemeral `.startup/` artifacts remain local. This replay is mandatory, not a
best-effort cleanup.

- Business phases allow only their exact brief, research, or handoff artifacts. They
  never allow product source, tests, workflow specs, Git metadata, or supervisor state.
- Tech phases allow only task-approved source, tests, exact workflow-spec files, and
  the expected tech handoff. Ambiguous scope routes deep before dispatch; it does not
  justify a repository-wide allowlist.
- QA allows only its exact review artifact. It reads product code but never edits it.
- The supervisor alone writes state, checks, commits, refs, GitHub state, and deploy
  records.

## Trusted commit boundary

Immediately before a tech or mechanical writer, snapshot the current base and active
hooks outside the worker's mutation scope:

```bash
COMMIT_TRUST="$(git rev-parse --git-path "saas-startup-team/commit-${run_id}-${attempt}.json")"
commit_trust=(bash "${CLAUDE_PLUGIN_ROOT}/scripts/supervisor-commit.sh"
  --snapshot-trust "$COMMIT_TRUST" --auth-stdin)
for path in "${ROLE_ALLOWED_PATHS[@]}"; do commit_trust+=(--allow "$path"); done
# A workflow with a separate mechanical firewall adds --require-approved-diff here.
"${commit_trust[@]}" <<<"$MUTATION_AUTH"
```

After the role guard and semantic post-diff containment pass, commit through the same
receipt:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/supervisor-commit.sh" \
  --message "$COMMIT_MESSAGE" --check "$CHECK_SCRIPT" \
  --trust-receipt "$COMMIT_TRUST" --auth-stdin <<<"$MUTATION_AUTH"
```

The supervisor reconstructs, stages, and commits the candidate in a disposable clone
with the trusted Git binary; the mechanical firewall, deterministic checks, and frozen
product hooks run inside a credentialless, network-off sandbox that cannot write Git
metadata. A failed gate leaves the primary HEAD and index unchanged
and retains the receipt for a same-base retry. A successful or no-op commit consumes it.
The authenticated receipt binds the exact allowlist, branch, refs, base, configuration,
and hooks. Create a fresh token and receipt after every successful commit; never reuse
either across phases or HEADs.
