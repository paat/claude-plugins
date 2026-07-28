# Migration — self-improvement / telemetry / evaluation removed (issue #390)

**Version:** saas-startup-team **0.90.24** (1.0.0 train).  
**Policy:** 1.0.0 has **no in-plugin replacement**. Historical source remains in Git history.

## Removed commands (no silent emulation)

| Removed command | Former role |
|-----------------|-------------|
| `/harvest` | Local self-improvement candidate harvester |
| `/session-insights` | Session log intervention extractor |
| `/lessons-review` | Manual lesson queue inspection/override |
| `/lessons-deliver` | Autonomous implementation of `lesson-approved` issues |
| `/learnings-migrate` | Staged learnings → topic-file sweep |
| `/learnings-compress` | Gated backlog compression of `docs/learnings/` |

Codex aliases `saas-startup-team-*-workflow` for the same names are also gone.

## Removed scripts / schemas / hooks / references

- `scripts/agent-events.sh`, `agent-events-export.sh`, `agent-events-aggregate.sh`
- `scripts/standard-medium-eval.sh` (already deleted earlier on this train)
- `scripts/harvest.sh`, `session-insights.sh`
- `scripts/lesson-auto-review.sh`, `lesson-file.sh`, `lesson-review.sh`,
  `lesson-review-binding.sh`, `lessons-deliver.sh`
- `scripts/auto-learn.sh` and its PostToolUse hook entry
- `references/schemas/lesson-auto-review.schema.json`
- `references/workflows/routing-telemetry.md`
- `templates/learnings-style.md`, `templates/learnings-compress-golden.md`
- Design docs: `docs/design/self-improvement-loop.md`, `docs/design/lessons-deliver.md`

## What remains (not a replacement)

- **Maintain v3** `release-facts`: privacy-safe terminal PR, merge, deployment, and close evidence only
- **`scripts/pii-gate.sh`**: shared secret/PII pattern for product issue filing (`issue-file.sh`)
- **`scripts/memory-gc.sh`**: optional project-memory grant retirement / stale flags (no harvest, no filing)
- Harness-native tracing and Git/PR/CI as the authority for delivery outcomes

## Operator actions

1. Remove crons that invoke `/harvest`, `/session-insights`, `/lessons-deliver`,
   `lesson-auto-review.sh`, or `workflow-probe.sh lessons-deliver`.
2. Stop setting `SAAS_LESSON_SYNC_ENABLED` / depending on `SAAS_PLUGIN_REPO` for lesson filing.
3. Leave existing `.startup/runs/agent-events.jsonl` and `.startup/insights/` in place if present;
   the plugin no longer reads or writes them on normal paths.
4. Do not reintroduce meta packaging into the 1.0 runtime dependency graph.
