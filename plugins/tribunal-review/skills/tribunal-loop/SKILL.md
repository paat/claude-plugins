---
name: tribunal-loop
description: "Use for multi-provider code review with repo-walking reviewers, diff-only review, and arbitration."
---

# Tribunal Loop

Multi-provider code review with inline arbitration. By default the panel is Codex
(repo-walking), DeepSeek through OpenCode Go (repo-walking), and Claude Code
(diff-only). Gemini, GLM, and Qwen are opt-in. The calling context arbitrates
inline and makes the final decision.

This skill is intentionally orchestration-only. Provider shell mechanics live in
the plugin `scripts/` directory:

- `scripts/preflight.sh`
- `scripts/run-codex-review.sh`
- `scripts/run-gemini-review.sh`
- `scripts/run-opencode-review.sh`
- `scripts/run-qwen-review.sh`
- `scripts/run-claude-review.sh`
- `scripts/lib.sh`

## Provider Policy

- Codex: on by default; disable with `TRIBUNAL_CODEX=off`; defaults to
  `gpt-5.6-sol` at `medium` effort; override with `TRIBUNAL_CODEX_MODEL` and
  `TRIBUNAL_CODEX_EFFORT`; repo-walking with unrestricted execution inside the
  development-container security boundary; the review prompt prohibits changes.
- DeepSeek: on by default through OpenCode; disable with
  `TRIBUNAL_DEEPSEEK=off`; model override `TRIBUNAL_DEEPSEEK_MODEL`; repo-walking
  read-only.
- Claude: on by default; disable with `TRIBUNAL_CLAUDE=off`; model override
  `TRIBUNAL_CLAUDE_MODEL`; diff-only from a scratch directory with tools disabled.
- Gemini: off by default; enable with `TRIBUNAL_GEMINI=on`; diff plus web/CVE
  lens.
- GLM: off by default; enable with `TRIBUNAL_GLM=on`; OpenCode diff-only leg.
- Qwen: off by default; enable with `TRIBUNAL_QWEN=on`; repo-walking on its own
  transport.

Disabled providers emit `{"provider":"...","status":"disabled"}` and are
excluded from quorum. Provider errors degrade the run, but if all non-disabled
providers fail the verdict must be `NEEDS_WORK` with confidence `0.0`.

## Step 1: Preflight

Set the plugin root and a per-run scratch dir for the provider JSON, then run preflight:

```bash
TRIBUNAL_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"   # this plugin's root
RUN_DIR="$(mktemp -d)"                          # collects one JSON file per leg
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/preflight.sh"
```

The preflight script resolves the repository default branch (`defaultBranchRef`,
`git remote show origin`, then `origin/HEAD`), honors `TRIBUNAL_BASE_BRANCH` and
`TRIBUNAL_BASE_REF`, refuses to review the default branch, verifies a diff with
`git diff "$BASE_REF"...HEAD`, checks enabled CLIs/model registry entries, and
reports usable/skipped/disabled active reviewer legs.

Stop if preflight exits non-zero. Otherwise report the base ref and active
reviewer leg status before launching review.

## Step 2: Parallel Review

Run the provider scripts as parallel shell calls, not Task agents. The OpenCode
script serializes GLM and DeepSeek internally to avoid OpenCode shared-state
deadlocks and prints one JSON object per leg.

```bash
mkdir -p "$RUN_DIR"
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-codex-review.sh" > "$RUN_DIR/codex.json" &
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-gemini-review.sh" > "$RUN_DIR/gemini.json" &
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-opencode-review.sh" > "$RUN_DIR/opencode.jsonl" &
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-qwen-review.sh" > "$RUN_DIR/qwen.json" &
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/run-claude-review.sh" > "$RUN_DIR/claude.json" &
wait
```

The scripts preserve the previous runner behavior: unique temp dirs, capped
`AGENTS.md` and `reachability.md` injection, default branch/base-ref overrides,
disabled-provider markers, large diff staging as files where needed, JSON output
normalization, and timeout-bounded provider calls.

Collect Codex, Gemini, GLM, DeepSeek, Qwen, and Claude outputs. Treat disabled
markers as intentional absence. Treat malformed JSON or `{"error":...}` as
provider failure and continue with remaining non-disabled providers.

### PR delivery evidence

For a merge gate, the provider shell calls above are not authoritative evidence.
The delivery controller must invoke the installed aggregate runner instead:

```bash
collection_json="$(bash "$TRIBUNAL_PLUGIN_ROOT/scripts/collect-review-evidence.sh" collect \
  --repo-root "$REPO_ROOT" --pr "$PR_NUMBER" --output "$CONTROLLER_OWNED_COLLECTION")"
manifest_sha="$(printf '%s' "$collection_json" | jq -r .manifest_sha256)"
```

The controller retains `manifest_sha`; do not take it back from model output.
It should also pin and validate `integrity/runner-bundle.json` with
`scripts/check-runner-bundle.sh --expected-manifest-sha256 SHA` before collection.
The runner launches the wrappers, assigns provider identity/status, and seals the
canonical repository, PR body/base/head/diff, runner/wrapper provenance, provider
artifacts, and timestamps. Read the retained provider files for Step 3. Never
accept caller-created provider JSON as merge evidence.

## Step 3: Inline Arbitration

Arbitrate inline in the current calling context. Do not spawn another agent.
`TRIBUNAL_CALLER_PROVIDER`, `TRIBUNAL_CALLER_MODEL`, and
`TRIBUNAL_CALLER_EFFORT` may identify that context when supplied. They are
informational metadata, not routing controls. Do not infer missing values;
standalone runs may leave all three unset and must continue normally.

Also read `reachability.md` from the repo root if present. It is supporting
context only; it never lowers the evidence bar for a blocking finding.

### 3a: Dedupe

Two findings are duplicates when they describe the same underlying issue in the
same file, even if phrased differently. Merge duplicates into one tribunal
finding, preserve all providers, and mark findings reported by two or more
providers as `CONSENSUS`.

### Same-Class Merge (Every Round)

Merge same-class findings even when line numbers or wording differ. For example,
multiple "ordering window", "unawaited write", "missing idempotency", or
"swallowed error" reports on the same changed behavior should become one finding
with one concrete fix path. Do not make the user fix the same defect repeatedly.

### 3b-0: Blocking-Finding Standard

A `critical` or `high` finding is valid only when it proves all three:

1. Production reachability: the changed code can run in a realistic production
   path.
2. Material impact: the failure can lose money/data, break availability,
   violate security/privacy, or corrupt externally visible behavior.
3. Causation: the reviewed change caused or exposed the defect.

If any element is missing, cap the finding at `medium`. Highest-severity merge
rules never override 3b-0. Required for critical/high findings:

```json
"blocking_proof": {
  "reachable_path": "...",
  "material_impact": "...",
  "caused_by_change": "..."
}
```

### Marked Positions (`line_check`)

The runner marks findings whose position cannot exist — a file outside the
reviewed diff or a line beyond the target file's length (providers sometimes
report diff-global positions). A `line_check`-marked finding has unreliable
evidence linking: verify it against the real file before counting it toward
severity or consensus, and cap it at `medium` unless independently confirmed.

### Conflicts

For conflicts, prefer direct code evidence over reviewer confidence. If two
reviewers disagree on severity for the same valid finding, use the highest
severity that satisfies 3b-0 and explain the disagreement in `arbiter_notes`.

## Optional Scope Lens

If `TRIBUNAL_SCOPE_LENS=on`, perform a minimal-diff scope-control pass before the
final verdict. Judge changed files and hunks against the visible task, issue,
plan, branch name, PR body, commit messages, and user instructions.

Report scope findings separately in `scope_findings`, not mixed with correctness
or security findings. Flag unrelated files, opportunistic refactors, unnecessary
abstractions, defensive branches for impossible internal states, rename/reformat
churn, and tests that assert unrelated implementation details. Do not reject an
intentional refactor when the task explicitly asks for one.

Each scope finding must include:

- `id` such as `S-001`
- `path`
- `why_out_of_scope`
- `disposition`: `must-remove-before-merge` or `follow-up-only`
- `conflicting_task_text` when available
- `smallest_acceptable_diff`

Any `must-remove-before-merge` scope finding makes the verdict at least
`NEEDS_WORK`.

## Verdict Rules

- If all non-disabled providers failed: `NEEDS_WORK`, confidence `0.0`.
- If all non-disabled providers returned zero findings and there are no blocking
  scope findings: `APPROVE`, confidence `0.95`.
- If any valid critical/high finding remains: `NEEDS_WORK` or `BLOCK` depending
  on blast radius and release risk.
- Medium/low findings may be approved with notes when the change is otherwise
  production-ready.

## Output Contract

Return JSON only, matching the schema in `references/output-contract.md` (top-level keys:
`tribunal_verdict`, `findings`, `scope_findings`, `provider_assessment`, `conflicts_resolved`,
`summary`; each finding carries a `consensus` of `CONSENSUS` or `SINGLE_PROVIDER`, and every
critical/high finding must include the `blocking_proof` block from 3b-0).

For a merge gate, save that JSON to `arbitration.json`, then have the delivery
controller finalize the collection with its retained manifest digest:

```bash
bash "$TRIBUNAL_PLUGIN_ROOT/scripts/collect-review-evidence.sh" finalize \
  --collection "$CONTROLLER_OWNED_COLLECTION" \
  --expected-manifest-sha256 "$manifest_sha" \
  --arbitration arbitration.json
```

Only the emitted `tribunal-proof/v1` digest is a delivery proof. Finalization
rechecks live PR drift, all artifact/provenance digests, provider status, finding
attribution, and the strict arbitration schema. A run with no successful provider
cannot approve. Retrying with identical arbitration returns the retained proof;
conflicting arbitration for that collection fails.

## Trust Hierarchy

The calling context makes the final decision. Codex, Gemini, GLM, DeepSeek,
Qwen, and Claude are equal advisory peers. Verify reviewer claims against the
diff and reachable code before accepting them.
