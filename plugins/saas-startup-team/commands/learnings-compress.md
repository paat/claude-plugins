---
name: learnings-compress
description: Compress one docs/learnings/<topic>.md into the house style behind a semantic-preservation gate — strips over-emphasis, adds canonical labels, routes landmines, promotes general standards, splits docs over 30KB. Non-destructive preview + changelog before any write.
user_invocable: true
---

# /learnings-compress — gated backlog compression

Compresses ONE topic doc per run. Never trust an autonomous rewrite: every run
produces a changelog and a hard gate on risky changes. Style source:
`templates/learnings-style.md`. Worked transforms + reviewer checklist:
`templates/learnings-compress-golden.md`.

## Actions

1. Resolve git root (`git rev-parse --show-toplevel`). Argument is one topic path
   under `docs/learnings/`; if absent, list candidates by size (largest first) and
   ask which **one** to compress. Process **one topic** per run.
2. Read `templates/learnings-style.md` and `templates/learnings-compress-golden.md`.
   Match the golden transformations exactly in shape, and apply the golden file's
   "If DROPPED as obvious" checklist before any DROP.
3. For each dash-bullet, produce a candidate compressed line: strip rationed emphasis,
   add a canonical-term Label, keep the terse why, keep Fix only if concrete, reduce
   ref to a terse token. Keep overloaded terms spelled out.
4. Classify each change as:
   - **REWRITE** — same rule, tighter.
   - **MERGE** — fold into a named duplicate line (changelog must name the target).
   - **RELABEL** — add/fix the Label only.
   - **DROP** — allowed ONLY when the line is an exact duplicate elsewhere, OR pure
     general best-practice with NO project/library/version specificity, NO exact-behavior
     claim, NO counterintuitive claim, NO post-cutoff fact, and NO provenance tag (issue,
     incident, test, filename, observed failure). Calibration guard: ambiguous
     obviousness defaults to KEEP.
   - **PROMOTE** — a general standard / team convention worth enforcing but not
     project/library-specific → move to the relevant agent prompt's Standards section,
     remove from learnings.
   Route any catastrophic rule to a `## Critical Landmines` section at the top.
5. Emit a **changelog** grouped by class, applying the golden reviewer checklist to each
   REWRITE/MERGE. Show before→after for every changed line.
6. **Gate — require explicit `approve critical`** before any change that (a) touches a
   `## Critical Landmines` rule (DROP/MERGE/severity downgrade), (b) is a **DROP-as-obvious**
   (the calibration guard makes this the highest-risk class — gated even outside Critical
   Landmines), or (c) is a PROMOTE (edits a different file). Routine REWRITE/RELABEL and
   non-critical MERGE proceed on the changelog alone, and only when the changelog names the
   duplicate target and the checklist shows no semantic loss.
7. **Size cap:** if the compressed doc still exceeds **30KB**, propose a split by `##`
   section into sibling `docs/learnings/<topic>-<section>.md` files and update the
   `## Domain Learnings` index. Confirm before writing.
8. Print the preview (changelog + resulting byte size + any split plan). Ask
   `apply / skip: <line numbers> / cancel`. On `apply`, write the doc (and any splits)
   and update the index. Never drop a learning except an exact duplicate or a gated
   pure no-delta best-practice.

## Guarantees

- One topic per run; smallest-impact, reviewable diffs.
- Changelog before any write; nothing changes on `cancel` or session death.
- Critical-rule changes, DROP-as-obvious, and promotions are human-gated.
- Never silently loses a learning; ambiguous obviousness defaults to KEEP. DROP only an
  exact duplicate or a gated pure no-delta best-practice; PROMOTE relocates a standard into
  an agent prompt; everything else is rewritten, merged, relabeled, or split.
