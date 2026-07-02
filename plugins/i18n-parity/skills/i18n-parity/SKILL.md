---
name: i18n-parity
description: Run or bootstrap the translation key-parity gate for multilingual next-intl repositories.
---

Use this skill when the user asks to check translation key parity, bootstrap i18n parity config, or wire the i18n parity gate into CI or pre-push checks.

Source command: `../../commands/i18n-parity.md`

Read that file and follow it — it is the authoritative workflow (config lookup, running the
engine, exit-code handling, bootstrapping `.i18n-parity.json` when absent, and pointing to
`harness/README.md` for hard enforcement).
