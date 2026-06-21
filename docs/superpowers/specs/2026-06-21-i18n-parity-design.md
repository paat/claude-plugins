# i18n-parity — Design Spec

**Issue:** #54 — New plugin: i18n-parity — translation key-parity gate (ET/EN/RU)
**Date:** 2026-06-21
**Status:** Approved design, pre-implementation
**Reviewers:** Codex (two passes — initial shape + revised hard-gate placement)

## 1. Problem

Multilingual surfaces ship with missing translation keys silently. A key exists in the
primary locale, is absent (or empty) in another, and the UI renders a raw dotted key path or a
blank to a real user — customer- and SEO-visible. The failure is quiet: nothing errors at build
time, the wrong-locale page just looks broken.

Two live Estonian SaaS apps demonstrate the exposure and the exact shape of a correct gate:

- **Aruannik** — next-intl, trilingual ET/EN/RU. Catalogs at `frontend/messages/{locale}.json`
  (one nested JSON file per locale, ~2890 leaf keys). It already hand-rolled a `vitest`
  parity test (`frontend/src/lib/i18nKeyParity.test.ts`) — the battle-tested reference this
  plugin generalises. Its `check.sh` does **not** run i18n parity (documented gap).
- **Varustame** — bilingual ET/EN via a `@varustame/i18n` workspace package. Catalogs at
  `packages/i18n/src/locales/{locale}/{namespace}.json` — **multi-namespace** (`common.json` +
  `admin.json` per locale). Same exposure, different on-disk layout.

Every multilingual app needs this gate, and today each reinvents it project-local with hardcoded
specifics.

## 2. Goal

Ship a generic, project-agnostic Claude Code plugin whose **primary deliverable is a hard
enforcement gate** (not a command a human must remember to run). It must:

1. Provide a **vendorable, zero-dependency parity engine** (`scripts/i18n-parity.py`, Python 3
   stdlib only) that diffs translation catalogs across locales and exits non-zero on any
   violation. It works **standalone** — copied into a repo with no plugin installed — and reads a
   small `.i18n-parity.json` config.
2. Wire that engine as an **automatic hard gate**: a CI required-job snippet (the authoritative
   gate) plus an optional git **pre-push** hook (a fast local safety net) and a one-line
   `check.sh` integration. The harness mirrors the existing `payment-contract-tester` plugin.
3. Prove the engine catches the canonical drift classes via **green/red self-test fixtures**:
   green on a balanced catalog set, red on each of {missing key, empty value, ICU-argument
   drift, leaf-shape mismatch, missing namespace, stale waiver, duplicate key}.
4. Offer an **optional** `/i18n-parity` command — convenience to run the gate ad-hoc and to
   **bootstrap a `.i18n-parity.json`** by inspecting the repo. Secondary to the hard gate.

**Non-goals (v0.1):**

- **Edit-time blocking hook.** Parity is a cross-file invariant — adding a key to `et.json`
  before `en.json`/`ru.json` is a legitimate intermediate state, so a blocking `PreToolUse` hook
  on a single catalog Write can never be satisfied atomically and would fight the natural
  edit-one-locale-then-the-others flow. The hard block belongs at push/CI/whole-tree time. A
  *non-blocking* edit-time warning hook is deferred to future work.
- **Estonian diacritics check.** Domain-specific, not core to parity; deferred to future work as
  an optional, separately-toggleable check category. (The reusable pattern already exists at
  `google-ads-strategist/scripts/check-estonian-diacritics.sh`.)
- **Full ICU semantic parsing / plural-branch parity.** v0.1 does ICU **argument-name-set**
  parity (catches a dropped `{count}`); it does not parse/compare `plural`/`select` branch
  categories. Deferred.
- **Locale value/translation-quality checks** (machine-translation, length, terminology). Out of
  scope — this is a *parity* gate, not a linter for translation content.

## 3. Mental model (the load-bearing decision)

**Default: strict all-locales parity.** Every locale must carry the same set of leaf keys, with
the same leaf shape and the same ICU argument set, and no empty values. This is the mental model
the output leads with.

**Waivers are the exception mechanism**, never the default. Real apps have a small, explicitly
enumerated set of intentionally locale-specific keys (e.g. Aruannik's EN-richer onboarding guide
leaves, and RU-exclusive landing sections gated on `locale === "ru"`). Those are declared in
config and carved out — and a waiver that no longer matches a live key fails loudly (a stale
waiver is a silent hole). Direction-scoped rules exist **only** inside the waiver mechanism
("present in `ru`, absent in `en`/`et` is allowed; the reverse is not") — they are not the default
comparison model. The report explains this plainly so a user whose mental model is "all locales
have the same keys" is not confused by a direction-scoped waiver.

This mirrors the Aruannik reference test precisely (strict ordered-pair diffs + an enumerated
`EN_ONLY_KEYS` set + `RU_ONLY_PREFIXES` direction-scoped prefixes + stale-waiver assertions).

## 4. Architecture

Four bounded units (plus tests). Each does one thing, is independently testable, and the engine
has zero dependency on the rest of the plugin.

```
plugins/i18n-parity/
  .claude-plugin/plugin.json
  README.md                       # Installation (3 scopes) + usage + config reference
  scripts/
    i18n-parity.py                # vendorable zero-dep engine (the artifact users copy)
    i18n-parity.sh                # thin wrapper: resolve config + python3, forward args, exit code
  harness/
    install-pre-push.sh           # installs/merges the pre-push hook into .git/hooks (or hooksPath)
    pre-push.sh                    # the hook body: fast safety net, blocks push on parity failure
    ci/github-actions.yml         # drop-in required CI job
    ci/gitlab-ci.yml              # drop-in required CI job
    README.md                     # harness wiring incl. one-line check.sh integration; CI-is-authoritative note
    tests/                        # harness self-tests (install/doc snippets), shell-based
  commands/
    i18n-parity.md                # OPTIONAL: run ad-hoc + bootstrap .i18n-parity.json
  tests/
    run-tests.sh                  # asserts engine exit codes against fixtures
    fixtures/                     # balanced + one fixture per red case (see §7)
```

### 4.1 Engine (`scripts/i18n-parity.py`) — the core unit

Pure pipeline, no side effects beyond reading catalog files and writing a report:

1. **Load config.** Locate `.i18n-parity.json` (CLI `--config PATH`, else `$I18N_PARITY_CONFIG`,
   else `<repo-root>/.i18n-parity.json` where repo-root = `git rev-parse --show-toplevel` or the
   cwd if not a repo). **Validate strictly** — unknown top-level/waiver fields fail with exit 2
   (a typo'd waiver field must not silently no-op).
2. **Resolve catalogs.** Each `catalogs[]` entry is a path template with a required `{locale}`
   placeholder and an optional `{namespace}` placeholder, plus an optional `id` (see below).
   Expand over `locales[]`; when `{namespace}` is present, discover namespaces by globbing across
   **all** locales (union), and group files into a `(catalog-id, namespace, locale) -> file` grid.
   - **Catalog id & collisions.** Each `catalogs[]` entry gets a stable id: its explicit `id`, else
     a deterministic id derived from the literal (non-placeholder) path segments. Two entries that
     resolve to the same id, or two entries whose grids would map the same `(id, namespace, locale)`
     cell to different files, is a **config error (exit 2)** — the user must add an explicit `id`.
     The reported path prefix is `id/namespace` (or just `id` when the catalog has no
     `{namespace}`).
   - **Missing-locale behavior.** A `(namespace)` discovered for some locales but absent for others
     is reported as **one** "namespace `X` missing for locale `Y`" violation (exit 1), not a cascade
     of per-key misses — as long as at least one *other* locale provides namespaces for that catalog.
     If a catalog entry resolves to **zero** files across all locales (nothing matched the glob at
     all), that is a **config error (exit 2)**, not a violation.
3. **Parse.** `json.load` with an `object_pairs_hook` that **detects duplicate keys** (Python
   silently keeps last-wins otherwise). A duplicate key is a **content violation (exit 1)**, NOT a
   parse error — it is distinct from malformed JSON, which is a **config/usage error (exit 2)** for
   that file with a clear message.
4. **Flatten.** Recurse nested objects to dotted leaf paths. Record each leaf's **shape**:
   `scalar` (string/number/bool), `array`, or `null`. Arrays are opaque leaves — intra-array
   structure is out of scope (matches the reference test). The reported path is
   `id/namespace:dot.path` (the `id/namespace` prefix disambiguates; for single-file-per-locale
   catalogs the namespace segment is omitted, leaving `id:dot.path`).
5. **Run checks** (see §5), grouped per namespace.
6. **Report.** Deterministic: sorted by namespace, then check, then key. Human-readable text to
   stderr by default; `--json` emits a machine object (list of violations with `{check, namespace,
   key, locales, detail}`) to stdout. Exit `0` clean / `1` violations / `2` config-or-usage error.

### 4.2 Shell wrapper (`scripts/i18n-parity.sh`)

Thin: resolves repo root, finds a `python3`, locates the config, forwards all args to the engine,
propagates the exit code. This is what `check.sh` / CI / the pre-push hook call, so they need no
Python knowledge. Errors clearly if `python3` is absent.

### 4.3 Harness (the hard gate)

- **`harness/ci/*.yml`** — the **authoritative** gate. A required job that checks out the repo and
  runs `scripts/i18n-parity.sh` (or the vendored `i18n-parity.py`); exit 1 fails the build.
- **`harness/pre-push.sh` + `install-pre-push.sh`** — a **convenience** fast local net, explicitly
  documented as *not* authoritative (local hooks are bypassable and check the working tree, not the
  exact pushed revision). The installer merges into an existing pre-push hook rather than clobbering
  and respects `core.hooksPath`. The hook body resolves root via `git rev-parse --show-toplevel`,
  honours `$I18N_PARITY_CONFIG`, and **skips fast when no configured catalog or the config file
  itself changed** in the range being pushed (avoids false-gating unrelated monorepo pushes).
  **Ref-range edge cases (fail-safe):** pre-push receives `<local-ref> <local-sha> <remote-ref>
  <remote-sha>` lines on stdin; a new branch has an all-zero remote sha and a deletion an all-zero
  local sha. When the changed-file diff range cannot be determined (new branch, no merge base),
  the hook **falls back to running the full gate** rather than skipping — it never silently passes
  because the range was ambiguous. A deletion-only push runs no gate.
- **`harness/README.md`** — wiring instructions, the one-line `check.sh` integration
  (`"$ROOT"/scripts/i18n-parity.sh || exit 1`), and a prominent "CI is the authoritative gate;
  pre-push is a convenience" note.

### 4.4 Command (`commands/i18n-parity.md`) — optional

`/i18n-parity`: runs the gate against the current repo and explains failures. If **no config
exists**, it inspects the repo — detecting the next-intl `messages/{locale}.json` layout vs the
`locales/{locale}/{namespace}.json` layout — and proposes a `.i18n-parity.json` for the user to
commit. Convenience only; never the enforcement mechanism.

## 5. Engine checks (v0.1)

All run per namespace; all contribute to a single exit-1 verdict; all waivable only via the
explicit config waiver mechanism.

1. **Presence parity** — every leaf key in locale A must exist in locale B, asserted for each
   **ordered** locale pair independently (so a key missing from *either* side fails; a symmetric
   union diff would mask one direction). Default is strict full parity; a missing key is waived
   only by a matching `localeOnlyKeys` entry or a `directionPrefixes` rule.
2. **Empty-value** — a leaf whose value is `""` or whitespace-only is a violation (it renders
   blank). Waivable per-key only via the dedicated `emptyAllowed` waiver (§6) — an intentionally-
   blank label in one locale — kept separate from `localeOnlyKeys` so "key is locale-exclusive" and
   "value is intentionally blank" never get conflated.
3. **ICU argument-name parity** — for a key present in ≥2 locales, the **set of `{argName}`
   placeholders** must match across those locales. Catches a dropped/renamed `{count}` that leaves
   the key present but renders/format-fails. **Grammar (deliberately limited):** an argument name is
   the identifier matched by `\{\s*([A-Za-z0-9_]+)` — i.e. the first token after an opening brace,
   which captures both simple `{name}` and the arg of `{name, plural, …}`/`{name, select, …}`.
   Apostrophe-escaped literal braces (ICU quoting, e.g. `'{'`) are stripped before matching,
   best-effort. Branch *categories* (`one`/`other`/`=0`) are **not** parsed or compared (deferred).
   Documented limits: nested sub-arguments inside plural branches and doubled-apostrophe escapes may
   yield rare false positives/negatives — acceptable for v0.1, waivable like any other finding.
4. **Leaf-shape parity** — for a key present in ≥2 locales, the shape (`scalar`/`array`/`null`,
   and object-vs-leaf) must match. An array in one locale and a string in another renders wrong
   even though the path matches.
5. **Whole-namespace-missing** — a namespace file absent for one locale but present for others is
   one clear violation, not a per-key cascade.
6. **Stale-waiver detection** — every waiver must still protect something live, or it fails loudly
   (a dead no-op masks future drift): a `localeOnlyKeys` entry must match a live key in the locale
   that owns it; an `emptyAllowed` entry must match a key that is actually empty in that locale; and
   a `directionPrefixes` rule must match at least one live key under one of its prefixes in the
   `present` locale.
7. **Duplicate-key detection** — a key declared twice in the same JSON object (last-wins in the
   parser) is a violation.

## 6. Config schema (`.i18n-parity.json`)

JSON (not YAML) to keep the engine stdlib-only and dependency-free; these are JS repos where JSON
is native. Unknown fields fail loudly.

```jsonc
{
  "primaryLocale": "et",
  "locales": ["et", "en", "ru"],
  "catalogs": [
    // single-file-per-locale (Aruannik); `id` optional, derived from literal path when omitted:
    { "pattern": "frontend/messages/{locale}.json" }
    // multi-namespace (Varustame) would instead be:
    // { "id": "pkg", "pattern": "packages/i18n/src/locales/{locale}/{namespace}.json" }
  ],
  "waivers": {
    // exact leaf keys that legitimately exist in only some locales.
    // Keyed by the locale that OWNS the key; stale entries (key no longer present) fail.
    "localeOnlyKeys": {
      "en": ["guide.sections.H.title", "guide.steps.30.instruction"]
    },
    // exact leaf keys that are intentionally blank in a given locale (kept separate from
    // localeOnlyKeys so "locale-exclusive" and "intentionally empty" never get conflated).
    // Keyed by the locale where the value is blank; entry that isn't actually empty there fails.
    "emptyAllowed": {
      "ru": ["legal.placeholder.notice"]
    },
    // direction-scoped subtree waivers: keys under these prefixes are allowed to be
    // present in `present` and absent in every locale of `absentIn` (and not the reverse).
    // A rule matching zero live keys under its prefixes in `present` fails (stale).
    "directionPrefixes": [
      { "present": "ru", "absentIn": ["en", "et"],
        "prefixes": ["landing.eresidentInfo.", "landing.eresidentSteps."] }
    ]
  }
}
```

Notes:
- `primaryLocale` anchors report phrasing and the bootstrap command's "source of truth" locale.
- A catalog `pattern` MUST contain `{locale}`; `{namespace}` is optional. Multiple `catalogs[]`
  entries are allowed (an app with both a `messages/` set and a workspace package); when more than
  one entry would share a derived id, each MUST carry an explicit `id` (else exit 2, §4.1).
- `directionPrefixes` is the only place direction asymmetry lives; everything else is strict.
- All three waiver kinds (`localeOnlyKeys`, `emptyAllowed`, `directionPrefixes`) are subject to the
  stale-waiver check (§5.6): a waiver protecting nothing live fails.

## 7. Testing

`tests/run-tests.sh` runs the engine against fixtures and asserts the **exit code** (and, for a
couple, that the report names the right key) — real green/red proofs, not assertions about
internals.

- **`fixtures/balanced/`** — a small ET/EN/RU catalog set, fully in parity → **exit 0**.
- **`fixtures/missing-key/`** — ET has a key absent in RU → **exit 1**, report names the key.
- **`fixtures/empty-value/`** — a key present everywhere but `""` in one locale → **exit 1**.
- **`fixtures/icu-arg-drift/`** — `{count}` present in EN, absent in ET for a shared key → exit 1.
- **`fixtures/shape-mismatch/`** — array in one locale, scalar in another → **exit 1**.
- **`fixtures/missing-namespace/`** — `admin.json` exists for EN, missing for ET → **exit 1**,
  one namespace-level violation (not a key cascade).
- **`fixtures/stale-waiver/`** — config waives a key that no longer exists → **exit 1**.
- **`fixtures/dup-key/`** — a catalog with a duplicated key → **exit 1**.
- **`fixtures/waived-ok/`** — divergence that IS correctly waived (exact-key + direction-prefix)
  → **exit 0** (proves waivers actually suppress, and that a 100%-locale-exclusive subtree passes).

Harness self-tests (`harness/tests/`, shell): the pre-push installer merges idempotently into an
existing hook; the CI snippets reference the right entrypoint; the documented `check.sh` one-liner
matches the shipped wrapper path.

## 8. Plugin metadata & repo conventions

- `plugin.json` **and** the root `marketplace.json` both bumped (kept in sync) when added —
  initial version `0.1.0`.
- `README.md` includes the mandatory **Installation** section with all three scopes (user /
  project / local), per repo CLAUDE.md.
- External dependency documented in README: **Python 3** (stdlib only — no `pip install`). `git`
  for the pre-push convenience hook (CI/standalone engine need only `python3`).
- Generic and project-agnostic: no hardcoded `aruannik`/`varustame`, hostnames, or app paths —
  everything project-specific lives in `.i18n-parity.json`. The two apps appear only as fixture
  inspiration, never as literals in shipped code.

## 9. Future work (explicitly out of v0.1)

- Non-blocking **edit-time warning hook** (PostToolUse on Write|Edit to a configured catalog).
- **Estonian-diacritics** optional check category (reuse the existing google-ads pattern).
- **Plural/select branch** parity (full ICU category comparison).
- **`.jsonc`** config support (comments/trailing commas) if achievable without a dependency.
- Per-package **scoped configs** for large monorepos (multiple `.i18n-parity.json` discovery).
