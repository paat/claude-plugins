---
name: tribunal-loop
description: "Use for multi-provider code review with repo-walking reviewers, diff-only review, and arbitration."
---

# Tribunal Loop

Multi-provider code review with inline arbitration. By default the panel is Codex
(repo-walking), DeepSeek through OpenCode Go (repo-walking), and Claude Code
(diff-only). Gemini, GLM, and Qwen are opt-in. Opus arbitrates inline and is the
final authority.

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

- Codex: on by default; disable with `TRIBUNAL_CODEX=off`; model override
  `TRIBUNAL_CODEX_MODEL`; repo-walking read-only.
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

Resolve the tribunal-review plugin root, then run:

```bash
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

## Step 3: Inline Arbitration

Arbitrate inline. Do not spawn another agent.

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

Return JSON only:

```json
{
  "tribunal_verdict": {
    "decision": "APPROVE|NEEDS_WORK|BLOCK",
    "confidence": 0.92,
    "rationale": "..."
  },
  "findings": [
    {
      "id": "T-001",
      "consensus": "CONSENSUS|SINGLE_PROVIDER",
      "providers": ["codex", "deepseek"],
      "severity": "critical|high|medium|low",
      "category": "logic|security|performance|quality|edge-case|architecture|testing",
      "file": "src/example.ts",
      "line": 42,
      "title": "...",
      "description": "...",
      "suggestion": "...",
      "confidence": 0.9,
      "blocking_proof": {
        "reachable_path": "...",
        "material_impact": "...",
        "caused_by_change": "..."
      },
      "arbiter_notes": "..."
    }
  ],
  "scope_findings": [
    {
      "id": "S-001",
      "path": "src/example.ts",
      "why_out_of_scope": "...",
      "disposition": "must-remove-before-merge|follow-up-only",
      "conflicting_task_text": "...",
      "smallest_acceptable_diff": "..."
    }
  ],
  "provider_assessment": {
    "codex": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled"},
    "gemini": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled"},
    "glm": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled"},
    "deepseek": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled"},
    "qwen": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled"},
    "claude": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|partial|disabled"}
  },
  "conflicts_resolved": [],
  "summary": "..."
}
```

## Trust Hierarchy

Opus is final authority. Codex, Gemini, GLM, DeepSeek, Qwen, and Claude are equal
advisory peers. Verify reviewer claims against the diff and reachable code
before accepting them.
