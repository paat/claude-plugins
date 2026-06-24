# Learnings House Style

How every learnings entry is written. One source of truth for the learnings pipeline, used by
`scripts/auto-learn.sh`, `commands/learnings-migrate.md`, `commands/learnings-compress.md`,
and the maintain-agent prompts. Consumers link here rather than restating these rules — except `scripts/auto-learn.sh`, which must inline them because a PostToolUse hook cannot read a file at fire time.

## Why terse-but-reasoned

Terseness alone is not an accuracy lever. Shrink by cutting narrative and using
canonical terms — not by telegraphic grammar. Keep a terse "why": a rule plus its
reason generalizes to unseen cases; a bare rule does not.

## Record the delta, not the corpus (novelty gate)

A line is worth its tokens only if it is **surprising to a competent model** — the
delta between what the model already knows and what is actually true here.
Information = surprise: a rule the model would produce anyway is ~0 bits — do not
record it; it only dilutes the lines that aren't obvious. The more a rule
*contradicts* the model's default, the more it earns its tokens (and the rare emphasis).

**Do NOT record** general/textbook best-practice the model already applies
(e.g. "validate input", "use parameterized queries", "handle errors").

**Where a fact lives (three tiers):** (i) model does it by default → nowhere;
(ii) a general standard or team convention the model won't reliably apply → the
**agent prompt's Standards sections** (once, durable, cross-project), NOT here;
(iii) project/library/version-specific surprising delta → here. If a candidate is
tier-(ii), promote it to the agent prompt instead of recording it as a learning.

**DO record — calibration guard (asymmetric):** models are overconfident about what
they "know," so KEEP anything project-specific, library/version-specific, exact-behavior
(inheritance/typing facts like `httpx.ConnectTimeout does NOT inherit from ConnectError`),
post-cutoff, counterintuitive, or **provenance-tagged** (`#issue`, incident, test) —
even when it pattern-matches something "obvious." That is where confident-but-wrong lives.
When unsure, keep it.

## Routine rule — one line

    - <Label>: <imperative rule> — <terse why>. Fix: <reusable pattern>. (ref)

- **Label** — a canonical term or failure-mode handle before the colon
  (`Idempotency:`, `Token hygiene:`, `Retry semantics:`). It is the model's
  retrieval handle. Prefer canonical terms over prose.
- **Rule** — imperative voice, not hedged ("retry only idempotent methods",
  not "we try to avoid…").
- **Why** — mandatory, terse. Drop only if self-evident.
- **Fix** — include only when there is a concrete reusable action; omit when vague.
- **(ref)** — optional, a single terse token (`#548`, `categorizer.py`). Never a
  provenance sentence.
- ~25 words max excluding ref.

## Emphasis is rationed

`ALWAYS` / `NEVER` / ALL-CAPS now over-trigger and dilute on current models —
they make the genuinely critical rules disappear into noise. Use them ONLY for a
catastrophic landmine, never for routine rules. Most lines need none.

Ration emphasis: reserve `ALWAYS`/`NEVER`/ALL-CAPS for the `## Critical Landmines`
section only. Routine rules should read as plain imperatives.

## Canonical vs overloaded terms

Use canonical names for unambiguous concepts (idempotent, TOCTOU, fail-closed,
cache stampede, backoff+jitter, least-privilege, surgical edit). For **overloaded**
terms (atomic, fail-safe, consistent) the model silently picks a sense — spell out
the behavior instead.

## Structure of a topic doc

- A `## Critical Landmines` section near the **top** holds the few catastrophic
  rules; stronger language is allowed only here.
- Remaining rules grouped under failure-mode `##` sections (e.g. Retry Semantics,
  Timeout Handling, Error Wrapping, Token Hygiene, Observability, Tests).
- A topic doc over 30KB is split by `##` section into sibling docs.

## Example

    - Idempotency: retry only idempotent HTTP methods; never POST/PATCH/DELETE
      after 5xx or ReadTimeout — server may have already committed the mutation.
      Fix: gate retries by method + idempotency key. (#548)
