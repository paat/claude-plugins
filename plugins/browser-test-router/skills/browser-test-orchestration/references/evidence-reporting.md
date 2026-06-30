# Evidence QA Report Mode

Use this playbook when the command includes `--evidence` or the user asks for an auditable QA artifact.

## Artifact Directory

Default output:

```text
docs/qa/browser-test/<timestamp>/
```

Allow a user-supplied output path when provided. Create:

- `report.md`
- `test-results.json`
- `screenshots/`
- optional `observations/` JSON files from delegated browser calls

## Required Evidence

Evidence mode must include:

- desktop and mobile browser observations;
- screenshots for desktop and mobile;
- before/after evidence for supplied or discovered interactions when safe;
- console errors and failed interactions;
- commands/tool calls executed;
- readiness verdict.

Default to `NEEDS_WORK` unless evidence is complete and no critical/high issues are found.

## Interaction Coverage

Attempt safe interactions: nav links, forms with harmless test data, modals, accordions, menus, toggles, and non-destructive buttons. Do not execute destructive actions unless the user explicitly supplied a safe test environment and instruction.

## JSON Shape

```json
{
  "schema_version": 1,
  "target": "<url-or-module>",
  "started_at": "<iso8601>",
  "finished_at": "<iso8601>",
  "viewports": ["desktop", "mobile"],
  "screenshots": ["screenshots/desktop.png", "screenshots/mobile.png"],
  "console_errors": [],
  "failed_interactions": [],
  "findings": [
    {
      "severity": "critical|high|medium|low",
      "title": "...",
      "evidence": ["relative/path/or/observation"],
      "recommendation": "..."
    }
  ],
  "verdict": "FAILED|NEEDS_WORK|READY"
}
```

## Markdown Report

Include:

- command and target;
- artifact directory;
- screenshots linked by relative path;
- what the page actually showed;
- interaction pass/fail;
- accessibility/responsive red flags visible from evidence;
- verdict and rationale.
