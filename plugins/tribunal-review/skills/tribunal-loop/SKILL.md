---
name: tribunal-loop
description: "Use for multi-provider code review with repo-walking reviewers, diff-only review, and arbitration."
---

# Tribunal Loop

Multi-provider code review with inline arbitration. By default the tribunal selects 3 available legs for `TRIBUNAL_RISK` (default `T2`) from `scripts/review-panel.tsv` (e.g. Codex, Claude, Gemini, with Grok, Muse, DeepSeek, and Qwen in fallback order); `TRIBUNAL_<PROVIDER>=on|off` forces inclusion or exclusion. The calling context arbitrates inline and makes the final decision.

This skill is orchestration-only. Provider shell mechanics live in `scripts/` (shared via `scripts/lib.sh`); full shell invocation recipes live in `references/execution-guide.md`. Be token-frugal: read only cited files and exit early if preflight reports no reviewable diff.

## Provider Policy

Per-provider defaults, flags, and transport notes: `references/provider-policy.md`. Disabled providers emit `{"provider":"...","status":"disabled"}` and are excluded from quorum. Provider errors degrade the run; if all non-disabled providers fail, verdict must be `NEEDS_WORK` with confidence `0.0`.

Only a runner script can stamp `diff_stat` onto a leg, pinning the range at diff capture. A review-shaped leg without `diff_stat` did not come from a runner: treat it as a provider failure and exclude it from quorum whatever verdict it carries (issue #487).

## Step 1: Preflight

Set `TRIBUNAL_PLUGIN_ROOT` (plugin root, `../..` from this file) and `RUN_DIR="$(mktemp -d)"`, then run `bash "$TRIBUNAL_PLUGIN_ROOT/scripts/preflight.sh"` (prefix with `TRIBUNAL_RISK=<T1..T4>` when named; optional `TRIBUNAL_SMOKE_PROBE=on`). Stop on non-zero exit; otherwise report the resolved base ref and active leg status. Details: `references/execution-guide.md`.

## Step 2: Parallel Review

Run the provider scripts as parallel shell calls (not Task agents) after `. "$TRIBUNAL_PLUGIN_ROOT/scripts/lib.sh" && tribunal_select_panel`: `scripts/run-codex-review.sh`, `scripts/run-gemini-review.sh`, `scripts/run-deepseek-review.sh`, `scripts/run-qwen-review.sh`, `scripts/run-grok-review.sh`, `scripts/run-muse-review.sh`, and `scripts/run-claude-review.sh`, saving each JSON output to `$RUN_DIR/<provider>.json` and waiting for all legs (`references/execution-guide.md`).

Treat disabled markers as intentional absence; treat malformed JSON or `{"error":...}` as provider failure and continue with remaining legs. When a leg hits `plan limit:` or `ok` legs fall below `TRIBUNAL_MIN_OK_LEGS`, run backups per `references/provider-policy.md`. Report per-leg results with status per `references/output-contract.md`, including in human progress updates.

### PR delivery evidence

For a merge gate, standalone shell calls are not authoritative evidence. The delivery controller must validate `integrity/runner-bundle.json` with `scripts/check-runner-bundle.sh` and invoke `scripts/collect-review-evidence.sh collect` (passing `--prior-rejections FILE` on later rounds per `closing-tribunal-loop`). Retain `manifest_sha` in the controller, read the retained provider files for Step 3, and never accept caller-created provider JSON as merge evidence.

## Step 3: Inline Arbitration

Arbitrate inline in the current calling context; do not spawn another agent. `TRIBUNAL_CALLER_PROVIDER`, `TRIBUNAL_CALLER_MODEL`, and `TRIBUNAL_CALLER_EFFORT` are optional informational metadata (not routing controls); do not infer missing values, and standalone runs may leave all three unset and must continue normally. Also read `reachability.md` from the repo root if present (supporting context only; never lowers the blocking bar).

### 3a: Dedupe & Same-Class Merge (Every Round)

Merge findings describing the same underlying issue in the same file into one finding, preserve all providers, and mark findings from ≥2 providers as `CONSENSUS`. Merge same-class findings even when line numbers or wording differ (e.g., multiple "ordering window", "unawaited write", "missing idempotency", or "swallowed error" reports on the same changed behavior become one finding with one concrete fix path).

### 3b-0: Blocking-Finding Standard

A `critical` or `high` finding is valid only when it proves all three: (1) **Production reachability** — changed code can run in a realistic production path; (2) **Material impact** — failure can lose money/data, break availability, violate security/privacy, or corrupt externally visible behavior; (3) **Causation** — reviewed change caused or exposed the defect.

If any element is missing, cap at `medium`. Highest-severity merge rules never override 3b-0. Required for critical/high findings: `"blocking_proof": {"reachable_path": "...", "material_impact": "...", "caused_by_change": "..."}`.

### Marked Positions (`line_check`)

The runner marks findings whose position cannot exist (e.g., diff-global positions) or whose check could not run. Verify positions only against the leg's pinned tree: `git show <head_oid>:<path>` using that leg's stamped `diff_stat.head_oid`, never the ambient worktree. Verify marked findings before counting them toward severity or consensus; cap at `medium` unless independently confirmed against that pinned tree. If the pinned object is unavailable, report the provider and unavailable evidence in `summary` and the finding's `arbiter_notes`; retain the mark in those notes and keep the medium cap, with no ambient fallback.

### Repository-Policy & Mutation Signals

- **Ignored Added Paths:** If preflight warns or sealed `ignored-paths.json` exists, read preceding stanza comments from `git show HEAD:<source>` (never the ambient worktree) and make each signal a `repository-policy` finding — it must become a finding, not be reported and forgotten. The default is `medium`; escalate to `high` when the preceding ignore comment mentions `secret(s)`, `PII`, `credential(s)`, `key(s)`, or `never commit` (that `high` blocks the gate by design).
- **Deleted Policy Paths:** If preflight warns or sealed `deleted-paths.json` exists, make each path a medium `repository-policy` finding — it must become a finding, not be reported and forgotten.
- **Mutation Gate:** If sealed `mutation-gate.json` contains vacuous results, sealed vacuous mutation-gate results must become a finding (`repository-policy`), not forgotten.

### Conflicts & 3c: KISS / YAGNI Filter (Arbiter)

Prefer direct code evidence over reviewer confidence. For severity disagreements on a valid finding, pick the highest severity satisfying 3b-0 and explain in `arbiter_notes`. After 3b-0, filter every retained finding and suggested fix:

- **KISS / YAGNI:** Keep only the simplest fix closing a proven defect; reject speculative capability, premature abstractions, unused config, or defensive branches for unreachable states.
- Real defect + over-engineered suggestion: keep only if 3b-0 holds and rewrite `suggestion` to the smallest sufficient fix (note in `arbiter_notes`).
- Over-scoping finding (style purity, optional polish): reject or cap at `medium`/`low`; record under provider rejected / `false_positives`.
- Never promote to critical/high for a KISS/YAGNI violation alone; blocking still requires 3b-0. Scope-lens findings stay separate.

## Optional Scope Lens

If `TRIBUNAL_SCOPE_LENS=on`, run a minimal-diff scope pass against the visible task/PR/plan (`references/execution-guide.md`) and report issues separately in `scope_findings` (`references/output-contract.md`). Any `must-remove-before-merge` scope finding makes the verdict at least `NEEDS_WORK`.

## Verdict Rules

- All non-disabled providers failed → `NEEDS_WORK`, confidence `0.0`.
- Zero-findings shortcut (`APPROVE`, confidence `0.95`) requires every non-disabled provider to have `status == "ok"` with zero findings, no blocking scope findings, and no sealed ignored-path signals, deleted-path signals, or vacuous mutation-gate signals requiring repository-policy findings.
- `APPROVE` requires at least the sealed `panel_policy.min_ok_legs` floor of `ok` legs (`TRIBUNAL_MIN_OK_LEGS`, default 2; a 1-leg `APPROVE` is never allowed; `references/provider-policy.md`).
- `APPROVE` requires confidence `0.95` when every non-disabled provider is `ok`. Any `failed` provider prevents the shortcut but still permits `APPROVE` with confidence `> 0` and `< 0.95` — justify reduced confidence and name each failed provider and missing independent review in `tribunal_verdict.rationale` and `summary`. Keep manifest statuses in `provider_assessment`; `disabled` stays excluded from quorum.
- Any valid critical/high finding → `NEEDS_WORK` or `BLOCK` (by blast radius/risk). Medium/low findings may approve with notes when production-ready.

## Output Contract & Trust Hierarchy

Return JSON only, matching `references/output-contract.md` (with `blocking_proof` for critical/high findings). For a merge gate, save to `arbitration.json` and have the controller run `scripts/collect-review-evidence.sh finalize` from the same unchanged plugin root (`references/execution-guide.md`). Finalization emits the sole `tribunal-proof/v1` delivery proof and rechecks live PR drift, artifact/provenance digests, provider status, finding attribution, and strict schema.

The calling context makes the final decision; Codex, Gemini, DeepSeek, Qwen, Grok, Muse, and Claude are equal advisory peers. Verify reviewer claims against the diff and reachable code before accepting them.
