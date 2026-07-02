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
