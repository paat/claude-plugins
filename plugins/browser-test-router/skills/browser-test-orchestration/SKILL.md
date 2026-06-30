---
name: browser-test-orchestration
description: Multi-model delegation protocol for browser testing with compact routing to scenario playbooks.
---

# Browser Test Orchestration

Use this skill to route browser testing work through a cheap browser executor first and reserve the main session for planning, interpretation, severity, and final verdicts.

The default path is lightweight: health check, navigate, collect structured observations, analyze inline. Load detailed scenario playbooks from `references/` only when the task needs them.

## Pre-Flight

Before delegation:

1. Verify `opencode` is installed.
2. Verify `chrome-devtools` MCP is connected in `opencode mcp list`.
3. Run L1 HTTP reachability for target URLs.
4. Run L2 browser render check before deeper testing.
5. Create `/tmp/screenshots` only when screenshots or evidence mode are requested.

Abort when opencode or chrome-devtools MCP is missing. Do not fall back to curl/WebFetch for browser verification.

## Delegation Model

- **Main session**: parse the task, choose scenarios, pass complete context, classify findings, assign severity, write final report.
- **Kimi K2.5 via opencode**: navigation, snapshots, forms, clicks, screenshots, visual property extraction, repeated mechanical checks.

Every `opencode run` starts with zero context. Pass full URLs, credentials file path and variable names, test data, expected state, and prior result JSON explicitly.

## Model Routing

| Task | Route |
|------|-------|
| URL navigation, page inventory, health checks | Kimi via opencode |
| Form filling, click paths, login/logout, repeated interactions | Kimi via opencode |
| Screenshots and visual property extraction | Kimi via opencode |
| Test design, spec parsing, severity, readiness verdict | Main session |
| Issue/report synthesis | Main session |

## Reference Routing

Open only the references needed for the current task:

- Navigation and page inventory: `references/navigation.md`
- Forms, credentials, validation, and interaction state: `references/forms.md`
- Page/system comparisons and parallel navigation: `references/comparison.md`
- Visual properties, screenshots, responsive and layout checks: `references/visual-testing.md`
- CRUD lifecycle testing: `references/crud.md`
- Multi-step workflows and business rules: `references/workflows.md`
- Role/permission testing: `references/permissions.md`
- L1/L2/L3 health checks and preflight troubleshooting: `references/health-checks.md`
- Evidence QA report mode (`--evidence`): `references/evidence-reporting.md`

If the user asks for a broad audit, load the smallest set of references that covers the scope. Do not load all playbooks by default.

## Evidence Mode

When `/browser-test-router:browser-test ... --evidence` is requested, load `references/evidence-reporting.md`. Evidence mode is opt-in and must produce persistent Markdown and JSON artifacts. It cannot return `READY` unless evidence includes at least desktop and mobile browser observations plus mandatory screenshots.

## Output Contract

For normal lightweight runs, report:

```text
Pre-flight: opencode <ok/fail>, chrome-devtools MCP <ok/fail>, L1 <status>, L2 <ok/fail>
Target(s): <urls/modules>
Findings:
- <severity>: <finding> (evidence: <structured observation or screenshot path>)
Verdict: FAILED | NEEDS_WORK | READY
Model usage: Kimi calls <n>, wasted calls <n>, main-session reasoning inline
```

Default to `NEEDS_WORK` when evidence is incomplete or high-signal checks were skipped.

## Core Rules

- Do not assume browser state persists across opencode calls.
- Do not include actual credential values in prompts or reports; pass env var names and file paths.
- Prefer structured text observations and visual properties. Request screenshots only when visual evidence is required or in evidence mode.
- Screenshots are mandatory in `--evidence` mode, optional otherwise.
- Main session owns final judgment; delegated browser executor describes what happened.
