# Learnings House Style — compress prose, raise trigger-signal

**Date:** 2026-06-24
**Scope:** saas-startup-team plugin (the *generators*) + the live learnings corpora in the aruannik and varustame dev containers (the *backlog*).
**Decision authority:** delegated by user ("decide based on research"); validated by Codex second-opinion. User will not review this doc.

## Problem

Agent-generated `docs/learnings/*.md` are growing into prose walls (aruannik `accounting-engine.md` 175KB, `frontend-i18n.md` 145KB). Each entry is a full English sentence drowning in `ALWAYS`/`NEVER`/ALL-CAPS. Goal: **both** physically shrink the text **and** raise the signal so terse lines reliably *trigger* correct LLM behavior. The two are one move, not a trade-off.

## Research basis (cited, condensed)

1. Terseness is **not** an accuracy lever. Shrink by cutting low-signal content + using canonical terms — never by telegraphic grammar, disemvoweling, or symbol-DSLs (LLMLingua family; those Reddit tricks are contradicted by evidence).
2. ALL-CAPS / `ALWAYS` / `NEVER` now **over-trigger and dilute** on current Claude/Opus. Reserve emphasis for the rare genuine landmine (Anthropic Claude-4 best practices).
3. Keep a **terse why** — rule+reason generalizes to unseen cases; the bare rule does not (Anthropic A/B).
4. **Canonical terms** (idempotent, TOCTOU, fail-closed, cache stampede, backoff+jitter, least-privilege, surgical edit) collapse a paragraph. **Overloaded terms** (atomic, fail-safe, consistent) must spell out behavior — the model silently picks a sense otherwise.
5. **Lost-in-the-middle + context rot**: a 175KB doc loses 30–50% recall regardless of per-line quality. Landmark rules go top/bottom; oversized docs get split. (Liu et al. TACL'23; Chroma 2025.)
5b. **Three-tier knowledge routing (where a fact lives).** (i) Model does it reliably by default → state *nowhere*. (ii) General best-practice / team standard the model won't reliably apply, or a team convention → the **agent prompt's Standards sections** (e.g. tech-founder `### Quality/Security Standards`, `## Guidelines`), stated *once*, durable, cross-project. (iii) Project/library/version-specific surprising delta → the **learnings doc**. The learnings gate must *promote* a keep-worthy tier-(ii) rule into the agent prompt rather than drop it or re-derive it per-project. Corollary: those Standards sections follow the same house style — they are themselves currently over-emphasized (e.g. tech-founder `## Guidelines` is ~12 straight `ALWAYS`/`NEVER` lines, several of them model-defaults) and get the same ration treatment.

6. **Record the delta, not the corpus.** A line is worth its tokens only if it is *surprising to a competent model* — the delta between ingrained/parametric knowledge and what is actually true here. Information = surprise: a rule the model would produce anyway is ~0 bits (delete it); a rule that *contradicts* the model's default is high bits (keep it, and it earns the rare emphasis). Inclusion and emphasis both track surprise, not abstract importance. **Calibration guard (asymmetric):** models are overconfident about what they "know" — so drop only *general/textbook best-practice*; KEEP anything project-specific, library/version-specific, exact-behavior (e.g. inheritance/typing facts), post-cutoff, counterintuitive, or provenance-tagged (`#issue`, incident, test), even when it pattern-matches something "obvious." This is where confident-but-wrong lives.

## House style (final)

### Routine rule — one line
```
- <Label>: <imperative rule> — <terse why>. Fix: <reusable pattern>. (ref)
```
- **Label** = canonical term or failure-mode handle, prefix before the colon (`Idempotency:`, `Token hygiene:`, `Retry semantics:`). Gives the model a stable retrieval handle.
- **Rule** = imperative voice, not hedged ("retry only idempotent methods", not "we try to avoid…").
- **Why** = mandatory, terse. Drop only if self-evident.
- **Fix** = conditional — include only when there is a concrete reusable action; omit when it would be vague.
- **(ref)** = optional, terse trailing token only (`#548`, `categorizer.py`). Never a multi-clause provenance sentence. Per-line refs are de-emphasized, not expanded.
- `ALWAYS`/`NEVER`/ALL-CAPS: rationed — most routine lines need none.

Example:
```
- Idempotency: retry only idempotent HTTP methods; never POST/PATCH/DELETE after 5xx or ReadTimeout — server may have already committed the mutation. Fix: gate retries by method + idempotency key. (#548)
```

### Landmark / critical rule — different shape, retrieval priority
Critical rules are structurally distinct so they don't get lost and don't dilute routine lines:
- Grouped under a `## Critical Landmines` section near the **top** of the doc.
- Limited in number; stronger language allowed **only here**.
- Optionally recapped in a short bottom list (for start+end placement).

### Per-doc structure (retrieval-oriented)
Each topic doc carries a small failure-mode taxonomy of `##` sections, e.g. for an HTTP doc: `Critical Landmines / Retry Semantics / Timeout Handling / Error Wrapping / Token Hygiene / Observability / Tests`. Section title + label prefix + canonical term + fix give the model four independent handles, and make splitting safe (each split doc is one coherent domain).

### Size cap
A topic doc exceeding a configurable byte/line cap triggers a **split** by `##` section into sibling docs, with the index updated. Default cap chosen during planning (candidate: ~30KB or ~150 lines).

## Lever A — fix the generators (durable; do first)

The bloat is born here, so this stops it at source.

1. **`scripts/auto-learn.sh`** — rewrite the `msg` extraction instruction. Replace `"laconic (~15 words max), NEVER/ALWAYS for rules"` with the house-style line shape (Label-first, terse why, conditional Fix, rationed emphasis, terse ref). This is the single highest-leverage edit.
2. **Shared house-style block** — factor the rules into one canonical snippet (e.g. `templates/learnings-style.md` or a heredoc constant) referenced by `auto-learn.sh`, `commands/learnings-migrate.md`, and the maintain agent prompts, so there is one source of truth.
3. **`commands/learnings-migrate.md`** — on bootstrap, create topic files with the `##` failure-mode taxonomy skeleton + a `## Critical Landmines` section, and append entries in house-style shape.
4. **Agent/maintain prompts** — reference the shared block where they instruct writing or maintaining learnings (do not duplicate the rules inline).

## Lever B — compress the backlog (after A; agent-run, gated)

Run by the now-updated agents on their next maintenance pass — not hand-edited. **Biggest risk (Codex): autonomous compression silently weakens semantics** (broader scope, dropped exception case, lost trigger condition) while looking cleaner. De-risk with a semantic-preservation harness:

- **Golden sample** — an approved before/after for ~10 representative entries; the pass must match its transformations.
- **Changelog** — every pass emits a diff of dropped / merged / rewritten / relabeled rules.
- **Reviewer checklist** focused on semantic loss: scope, exception cases, trigger condition, prohibited behavior, required fix preserved.
- **Batch by domain**, smallest docs first — never one 600KB rewrite.
- **Human approval gate** for any deletion, merge, or severity downgrade of a `## Critical Landmines` rule. Routine compression can proceed on the changelog alone.
- Mechanism: a new `/learnings-compress` command (sibling to `/learnings-migrate`) that is append/rewrite with the changelog + gate, OR an extension of the maintain agents — decided during planning.

## Out of scope

- Compressing agent *system prompts* is **partially in scope**: the founder Standards/Guidelines sections (tech-founder + business-founder) are the canonical home for tier-(ii) standards and get the ration treatment now. Role-specific prompt prose for the other agents (lawyer, growth-hacker, ux-tester) is a **follow-up** — same principles, different files and risk profile.
- No new infra; bash 4 + jq + awk only, matching existing hooks.

## Success criteria

- New learnings are born in house-style shape (verified by inspecting post-change auto-learn output on a real handoff).
- A representative backlog doc shrinks materially with a changelog showing zero semantic loss on spot-checked rules.
- Emphasis density (`ALWAYS`/`NEVER`/ALL-CAPS per 100 lines) drops sharply except in `## Critical Landmines`.
- Lines that merely restate general best-practice the model already applies are dropped; provenance-tagged / version-specific lines survive compression.
