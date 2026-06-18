# payment-contract-tester — enforcement harness

Two layers of enforcement for your generated payment contract tests. **CI is the authoritative
gate.** The local pre-push hook is fast-feedback convenience only — it is **bypassable**
(`git push --no-verify`) and is **not** the security boundary.

## 1. CI snippet (authoritative)

Templates live in [`ci/`](ci/):

- `ci/github-actions.yml` → copy into `.github/workflows/payment-contract.yml`
- `ci/gitlab-ci.yml` → merge into `.gitlab-ci.yml`

Each runs on push and PR/MR. Keep the block matching your stack, set the payment-test **subset**
selector (`pytest -k "…"` or `dotnet test --filter "…"`), and delete the other block. Because it
runs in CI, it is versioned, shared with the whole team, and cannot be skipped with `--no-verify`.

## 2. Optional pre-push hook (convenience)

`pre-push.sh` is the hook body; `install-pre-push.sh` installs it safely.

### Install

```bash
harness/install-pre-push.sh --test-cmd 'pytest -k "payment or webhook"'
# or, for xUnit:
harness/install-pre-push.sh --test-cmd 'dotnet test --filter "FullyQualifiedName~Payment"'
```

The installer:

- **Detects existing hook managers** (Husky, lefthook, pre-commit, `core.hooksPath`) and, if one is
  present, prints the integration to add to *that* manager instead of writing `.git/hooks/pre-push`.
- Otherwise writes a **clearly-delimited managed block** into `.git/hooks/pre-push`, composing with
  any existing hook content and preserving the executable bit.
- Records the subset command in `.pct-hook.conf` at the repo root (the hook reads it at push time;
  you can also override per-invocation with the `PCT_TEST_CMD` environment variable).
- **Fails safe**: if the setup is ambiguous (e.g. a non-executable hook already exists) it prints
  manual instructions and modifies nothing.

### Hook-manager snippets

If you use a manager, add a pre-push step that runs the hook body:

- **Husky** — in `.husky/pre-push`: `PCT_TEST_CMD='pytest -k "payment"' "$(git rev-parse --show-toplevel)/harness/pre-push.sh"`
- **lefthook** — under `pre-push.commands`: `run: harness/pre-push.sh` with `PCT_TEST_CMD` exported.
- **pre-commit** — a `repo: local` hook with `stages: [push]` invoking `harness/pre-push.sh`.

### Uninstall

```bash
harness/install-pre-push.sh --uninstall
```

Removes only the payment-contract-tester managed block, preserving the rest of your hook.

### Why pre-push (not pre-commit)

Full payment-test runners are too slow to run on every commit. Pre-push gives the signal before the
code leaves your machine without taxing each commit. CI still re-runs it as the real gate.
