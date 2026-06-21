# i18n-parity harness

The **hard gate** that enforces translation key-parity. Three wiring options, in order of authority.

## 1. CI (authoritative)

Copy `ci/github-actions.yml` to `.github/workflows/i18n-parity.yml` (or include
`ci/gitlab-ci.yml`). CI is the only reliable whole-tree gate — make it a required check.
Adjust the `scripts/i18n-parity.py` path to wherever you vendored the engine.

## 2. check.sh one-liner

Add to your existing aggregate check script:

```bash
"$ROOT"/scripts/i18n-parity.sh || exit 1
```

## 3. Pre-push hook (convenience, NOT authoritative)

Local hooks are bypassable and inspect the working tree, not the exact pushed revision —
treat this as a fast safety net, never as the gate of record.

```bash
plugins/i18n-parity/harness/install-pre-push.sh
```

It merges into an existing `pre-push` hook (idempotent), honours `core.hooksPath`, resolves
the repo root via `git rev-parse`, reads `$I18N_PARITY_CONFIG` if set, and skips fast unless a
catalog/config path changed. On an ambiguous push range (new branch, no merge-base) it runs the
full gate rather than skipping.

## Config

All wiring runs the same engine against `<repo-root>/.i18n-parity.json` (override with
`$I18N_PARITY_CONFIG`). See the plugin README for the config schema. Requires `python3`.
