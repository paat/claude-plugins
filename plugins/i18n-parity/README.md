# i18n-parity

A vendorable, zero-dependency **translation key-parity gate** for multilingual apps
(next-intl and friends). It catches keys that exist in one locale but are missing, empty, or
structurally different in another — before a real user sees a raw `dotted.key.path` or a blank.

The enforcement is a **hard gate** (CI + optional pre-push), not a command you must remember to
run. An optional `/i18n-parity` command runs it ad-hoc and bootstraps the config.

## Mission Fit

`i18n-parity` is delivery infrastructure for multilingual SaaS products. It prevents
localized customer-facing flows from shipping with missing keys, blank strings, or broken
ICU arguments after an autonomous implementation.

## What it checks

Per namespace, across every locale (strict all-locales parity by default):

- **Presence** — every key exists in every locale (direction-scoped per ordered pair).
- **Empty values** — no `""`/whitespace-only leaves.
- **ICU arguments** — the set of `{argName}` placeholders matches across locales.
- **Leaf shape** — array vs scalar vs null is consistent for shared keys.
- **Whole-namespace presence** — a namespace file missing for a locale is one clear violation.
- **Duplicate keys** — a key declared twice in one catalog (silent last-wins) is flagged.
- **Stale waivers** — a waiver that no longer protects a live key fails loudly.

Intentional divergences are declared as **waivers** — never by deleting the key from the locale
that owns it.

## Requirements

- **Python 3** (standard library only — no `pip install`).
- `git` only for the optional pre-push convenience hook.

## Configuration — `.i18n-parity.json`

```json
{
  "primaryLocale": "et",
  "locales": ["et", "en", "ru"],
  "catalogs": [
    { "pattern": "frontend/messages/{locale}.json" }
  ],
  "waivers": {
    "localeOnlyKeys": { "en": ["guide.sections.H.title"] },
    "emptyAllowed":   { "ru": ["legal.placeholder.notice"] },
    "directionPrefixes": [
      { "present": "ru", "absentIn": ["en", "et"], "prefixes": ["landing.eresidentInfo."] }
    ]
  }
}
```

- `catalogs[].pattern` MUST contain `{locale}`; `{namespace}` is optional (e.g.
  `packages/i18n/src/locales/{locale}/{namespace}.json`). Give multiple catalogs unique `id`s.
- Exit codes: `0` clean, `1` violations, `2` config/usage error. `--json` for machine output.
- Run directly: `python3 scripts/i18n-parity.py --root .`

## Wiring the hard gate

See `harness/README.md`. CI (`harness/ci/*`) is authoritative; `harness/install-pre-push.sh`
adds a local convenience hook; or add `scripts/i18n-parity.sh || exit 1` to an existing
`check.sh`.

## Installation

- **Install for you** (user scope) — available in all your projects:
  ```
  /plugin install i18n-parity
  ```
- **Install for all collaborators on this repository** (project scope) — committed, shared with
  the team: add `i18n-parity` to the project's `.claude/settings.json` `plugins` list (or run
  `/plugin install i18n-parity --scope project`) and commit it.
- **Install for you, in this repo only** (local scope):
  ```
  /plugin install i18n-parity --scope local
  ```

## License

MIT.
