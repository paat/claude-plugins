---
description: Run the translation key-parity gate, or bootstrap its config by inspecting the repo
---

# /i18n-parity

Run the i18n key-parity gate against this repo and explain any failures. This command is
**optional convenience** — the real enforcement is the CI/pre-push harness (`harness/`).

## Steps

1. Find the config: look for `.i18n-parity.json` at the repo root (or `$I18N_PARITY_CONFIG`).

2. **If a config exists**, run the engine and report:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/i18n-parity.sh" --root "$(git rev-parse --show-toplevel)"
   ```
   - Exit 0 → report "all locales in parity".
   - Exit 1 → summarise the violations grouped by check; for each, name the file/key and the
     fix (add the missing key / fill the empty value / restore the ICU arg / match the shape /
     add the missing namespace file / remove the stale waiver / de-duplicate the key). Remind
     the user that intentional divergences belong in a `waivers` entry, never by deleting the
     key from the locale that owns it.
   - Exit 2 → surface the config/usage error verbatim and help fix the config.

3. **If no config exists**, inspect the repo to propose one:
   - Look for `**/messages/{locale}.json` (next-intl single-file-per-locale) → propose a
     `{ "pattern": "<dir>/{locale}.json" }` catalog.
   - Look for `**/locales/{locale}/{namespace}.json` (multi-namespace) → propose a
     `{ "pattern": "<dir>/{locale}/{namespace}.json" }` catalog.
   - Infer `locales[]` from the discovered locale codes and set `primaryLocale` (ask the user
     which locale is the source of truth; default to the most-complete one).
   - Write the proposed `.i18n-parity.json`, then run the gate once to show the baseline.

4. Offer to wire the hard gate: point the user at `harness/README.md` (CI job is authoritative;
   `harness/install-pre-push.sh` adds the local convenience hook).
