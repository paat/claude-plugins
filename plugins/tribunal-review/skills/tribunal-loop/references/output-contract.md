# Tribunal-loop output contract

The inline arbitration (Step 3 of the `tribunal-loop` skill) returns JSON only, matching this
schema. All numeric values must reflect actual counts from the provider inputs. The `consensus`
field is `CONSENSUS` (reported by ≥2 providers) or `SINGLE_PROVIDER` (one provider).

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
    "codex": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|disabled"},
    "gemini": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|disabled"},
    "glm": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|disabled"},
    "deepseek": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|disabled"},
    "qwen": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|disabled"},
    "claude": {"findings_accepted": 0, "findings_rejected": 0, "false_positives": [], "status": "ok|failed|disabled"}
  },
  "conflicts_resolved": [],
  "summary": "..."
}
```

For sealed PR delivery, this is an exact schema: unknown keys, unknown enum
values, duplicate IDs/providers, invalid counts, provider status that differs
from the wrapper-owned collection, and critical/high findings without all three
`blocking_proof` strings are rejected. Each provider attributed to a finding
must have returned a finding for that file. `findings_accepted` must equal the
number of final findings attributed to that provider.

`collect-review-evidence.sh finalize` retains the canonical arbitration and
emits a proof with this shape:

```json
{
  "schema": "tribunal-proof/v1",
  "finalized_at": "2026-01-01T00:00:00Z",
  "manifest_sha256": "...",
  "pull_request": {
    "number": 123,
    "head_oid": "...",
    "body_sha256": "...",
    "diff_sha256": "..."
  },
  "arbitration": {
    "path": "arbitration.json",
    "sha256": "...",
    "decision": "APPROVE|NEEDS_WORK|BLOCK",
    "confidence": 0.92,
    "critical_count": 0,
    "high_count": 0
  }
}
```

The controller must retain the collection manifest digest returned by `collect`
and the proof digest returned by `finalize`; neither digest may be accepted back
from the model context. An identical `finalize` retry returns those same digests;
a conflicting arbitration is rejected, and an interrupted run with only the
identical canonical `arbitration.json` retained can finish its proof.
