# Migration: hooks/gates collapse (0.90.25, #391)

## Removed hook scripts

`auto-commit.sh`, `auto-commit-growth.sh`, `enforce-delegation.sh`,
`enforce-handoff-naming.sh`, `enforce-tone.sh`, `check-duplicate-handoff.sh`,
`check-handoff-secrets.sh`, `validate-growth-brief.sh`, `check-task-complete.sh`.

Hooks never commit or mutate orchestration state.

## New surfaces

- `hooks/dispatch.sh` — sole path-scoped dispatcher (PreToolUse Write|Edit/Bash, PostToolUse Write|Edit)
- `scripts/gate.sh` — schema · pii · legal · spend · regression · acceptance · release

Call `bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate.sh" …` instead of removed helpers.
Thin shims remain: `check-ad-budget.sh`, `validate-json.sh`, `check-linkedin-limits.sh`,
plus `legal-verdict-gate.sh` / `acceptance-packs.sh` / `solution-signoff-gate.sh` /
`check-regression-test.sh` / `poll-gate.sh` as gate backends.

## Browser

`agents/browser-operator*.md` and unconditional Playwright `alwaysLoad` removed.
UX uses host browser capability when available.

## Commands / docs

Every `commands/*.md` is a generated alias → capability skill. Sole playbooks:
`references/delivery-playbook.md`, `references/workflows/maintain-policy.md`.
