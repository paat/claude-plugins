---
name: i18n-parity
description: Run or bootstrap the translation key-parity gate for multilingual next-intl repositories.
---

Use this skill when the user asks to check translation key parity, bootstrap i18n parity config, or wire the i18n parity gate into CI or pre-push checks.

Workflow:

1. Find the repository root:

   ```bash
   git rev-parse --show-toplevel
   ```

2. Look for `.i18n-parity.json` at the repository root, or use `$I18N_PARITY_CONFIG` when it is set.

3. If config exists, run:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/i18n-parity.sh" --root "$(git rev-parse --show-toplevel)"
   ```

4. Interpret exits:
   - Exit 0 means all locales are in parity.
   - Exit 1 means parity violations were found. Group failures by check and name the file, key, and fix.
   - Exit 2 means config or usage failed. Surface the error and help fix the config.

5. If no config exists, inspect common next-intl layouts and propose `.i18n-parity.json`:
   - `**/messages/{locale}.json` maps to `{ "pattern": "<dir>/{locale}.json" }`.
   - `**/locales/{locale}/{namespace}.json` maps to `{ "pattern": "<dir>/{locale}/{namespace}.json" }`.
   - Infer `locales[]` from discovered locale codes and choose `primaryLocale` from the most complete catalog unless the user specifies another source of truth.

6. For hard enforcement, point the user to `harness/README.md`. The CI job is authoritative; `harness/install-pre-push.sh` adds the local convenience hook.
