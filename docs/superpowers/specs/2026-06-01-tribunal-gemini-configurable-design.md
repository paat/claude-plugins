# Configurable Gemini Review — tribunal-review

**Date:** 2026-06-01
**Plugin:** `plugins/tribunal-review`
**Status:** Approved (design)

## Problem

The Gemini leg of the `tribunal-loop` workflow is hardcoded: it always runs, always
uses `--model gemini-3-pro-preview`, and there is no way to skip it short of editing
the skill. Operators need to:

- **Turn the Gemini leg off** without editing the skill — e.g. no Gemini auth, rate
  limits, cost concerns, or because Gemini is the slow leg on a given run. The
  existing preflight only skips Gemini when the `gemini` CLI is absent from `PATH`;
  CLI-presence is not the same as *intent to use it*.
- **Swap the Gemini model** — e.g. point at a faster/cheaper flash slot to keep a full
  4-provider quorum while controlling latency/cost (the README already names
  model-swapping as the genuine speed lever).

## Decision

Add a thin **environment-variable** configuration layer for the Gemini leg only.
Two knobs, both defaulting to current behavior (fully backward compatible):

| Variable | Default | Effect |
|---|---|---|
| `TRIBUNAL_GEMINI` | `on` | `off` → skip the Gemini leg; degrade to a 3-provider quorum |
| `TRIBUNAL_GEMINI_MODEL` | `gemini-3-pro-preview` | value passed to `gemini --model` |

Values are read inline in the skill's bash with a default fallback:

```bash
GEMINI_ENABLED="${TRIBUNAL_GEMINI:-on}"
GEMINI_MODEL="${TRIBUNAL_GEMINI_MODEL:-gemini-3-pro-preview}"
```

Operators set them by exporting in the shell before launching `claude` (per-session).
No persistent settings file and no `.local.md` parsing layer.

### Why env vars, not a settings file

The tribunal-loop skill is self-contained inline bash with no hidden state and a
fail-fast / degrade-to-quorum design. A settings file would require Claude to read,
parse, and inject values before each run — a new failure mode that contradicts that
design. Env vars read inline with a default are minimal, robust, and architecture-
consistent.

### Why these two knobs only (scope)

- **Enable/disable** — requested; not redundant with the preflight PATH check.
- **Model override** — nearly free (same mechanism), and more useful than a binary
  off because it preserves a full quorum.
- **Timeout** and **web/CVE-search toggle** — deliberately excluded (YAGNI). Timeout
  rarely needs tuning and is moot once a fast model can be selected; the search toggle
  needs prompt-templating for low value.

The naming (`TRIBUNAL_<PROVIDER>` / `TRIBUNAL_<PROVIDER>_MODEL`) is intentionally
extensible to the other providers later, but that is **not** built now.

## Design — changes by location

All changes live in `plugins/tribunal-review`.

### 1. `skills/tribunal-loop/SKILL.md` — Step 1 (Pre-flight)

- Read `GEMINI_ENABLED` early in the preflight bash block.
- When `off`: do **not** probe `gemini` on PATH and do **not** count it toward the
  "zero usable providers" failure check. Add a note to `WARN` /
  status line, e.g. `gemini: disabled via TRIBUNAL_GEMINI=off — leg will be skipped`.
- The `USABLE` count semantics stay the same for the other CLIs. A disabled Gemini is
  reported as an intentional skip, distinct from a "NOT on PATH" warning.
- Step 1 output line continues to report providers ready; mention Gemini disabled when
  applicable.

### 2. `skills/tribunal-loop/SKILL.md` — Step 2, Bash call 2 (Gemini Review)

- Top-of-script guard, before the `git diff`:

  ```bash
  if [ "${TRIBUNAL_GEMINI:-on}" = "off" ]; then
    printf '%s\n' '{"provider": "gemini", "status": "disabled", "note": "Gemini leg disabled via TRIBUNAL_GEMINI=off"}'
    exit 0
  fi
  ```

- Replace the hardcoded `--model gemini-3-pro-preview` with:

  ```bash
  GEMINI_MODEL="${TRIBUNAL_GEMINI_MODEL:-gemini-3-pro-preview}"
  ...
  gemini --model "$GEMINI_MODEL" -p "..."
  ```

  The prompt's inner JSON template keeps `"model": "default"` exactly as today
  (Gemini reports its own model name into the field; no change to schema).

### 3. `skills/tribunal-loop/SKILL.md` — Step 3 (Arbitration)

- Add `"disabled"` to the allowed `provider_assessment.gemini.status` values
  (`ok|failed|partial|disabled`).
- Add a short rule in **3e (Degraded Input)**: a `status: "disabled"` marker is an
  intentional skip, NOT a provider failure — exclude Gemini from quorum entirely and
  do not count it toward the "all providers failed" branch. The verdict is computed
  from the remaining 3 providers.

### 4. `agents/gemini-reviewer.md`

- Mirror the model override (`GEMINI_MODEL="${TRIBUNAL_GEMINI_MODEL:-gemini-3-pro-preview}"`
  → `gemini --model "$GEMINI_MODEL"`) so the standalone/doc script stays consistent.
- The enable/disable guard is **not** added here — this agent is only invoked when one
  deliberately wants a Gemini review, so an off-switch is meaningless in that path.
  A one-line note documents that disabling is a tribunal-loop concern.

### 5. `README.md`

- New short "Configuration" subsection documenting both env vars, their defaults, and
  that `TRIBUNAL_GEMINI=off` degrades to a 3-provider quorum. Show the per-session
  export usage:

  ```bash
  export TRIBUNAL_GEMINI=off                 # skip Gemini this session
  export TRIBUNAL_GEMINI_MODEL=gemini-3-flash # or swap the model instead
  ```

### 6. Version bump

- Bump `plugins/tribunal-review/.claude-plugin/plugin.json` `version` and the matching
  entry in the root `.claude-plugin/marketplace.json` (repo rule: keep both in sync).
  `0.5.0` → `0.6.0` (new user-facing feature, backward compatible).

## Error handling / edge cases

- **Unset vars** → current behavior exactly (enabled, `gemini-3-pro-preview`).
- **`TRIBUNAL_GEMINI` set to anything other than `off`** → treated as enabled (only the
  literal `off` disables). Documented.
- **Disabled + all other providers also fail** → arbiter's existing "all failed" branch
  still applies to the *non-disabled* set; if every non-disabled provider failed,
  verdict = NEEDS_WORK as today. Gemini being disabled never by itself triggers the
  all-failed branch.
- **Invalid model ID** → `gemini` CLI fails at runtime; the leg degrades via the
  existing Gemini error-JSON path (no new handling needed).

## Out of scope

- Timeout override, web/CVE-search toggle.
- Configurability for Codex / GLM / DeepSeek (naming is extensible for a future change).
- Persistent settings file / `.local.md`.

## Testing

- Manual: with no env vars set, confirm Step 2 Gemini call is byte-for-byte equivalent
  in behavior (model + run path) to current.
- `TRIBUNAL_GEMINI=off` → Step 2 emits the `disabled` marker, Step 1 reports it,
  arbiter degrades to 3-provider quorum without flagging a failure.
- `TRIBUNAL_GEMINI_MODEL=gemini-3-flash` → `gemini --model gemini-3-flash` is invoked.
- Bash syntax check of the edited blocks (`bash -n` on extracted snippets).
