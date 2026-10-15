# saas-operations

Standalone post-launch SaaS operations for Claude Code and Codex: monitoring,
incident investigation, session replay, support triage, and deduplicated issue filing.
Works without saas-startup-team installed; no hooks or settings are required.

## Installation

- **Install for you** (user scope): `/plugin install saas-operations@paat-plugins`
- **Install for all collaborators on this repository** (project scope):
  `/plugin install saas-operations@paat-plugins --scope project`
- **Install for you, in this repo only** (local scope):
  `/plugin install saas-operations@paat-plugins --scope local`

Codex uses the same plugin's generated `saas-operations-*-workflow` skills and
bundled Playwright MCP configuration.

## Capabilities

| Command / skill | Purpose |
|---|---|
| `/saas-operations:operate` | Status, monitor, investigate, replay, or support mode |
| `/saas-operations:monitor` | Health, logs, analytics, and funnel checks |
| `/saas-operations:investigate` | Trace an incident and file actionable findings |
| `/saas-operations:replay-abandoned` | Replay abandoned sessions with Playwright |
| `/saas-operations:monitor-nightly` | Bounded nightly checks with issue deduplication |
| `saas-operations:issue-file` | Create or reuse issues; park sensitive findings locally |

Copy `saas-operations.local.md.example` to `.claude/saas-operations.local.md` in the
product repository and configure the `monitor:` / `operate:` blocks as needed.
Nightly monitoring retains `.startup/monitor-state.json`. Custom checks default to
`.startup/monitor-checks.sh` and emit JSONL findings; optional `monitor.repro_recipe`
appends reproducible steps, substituting `{entity}`.
Run `scripts/workflow-probe.sh monitor-nightly` before the assistant to skip empty
cycles (exit 3); scheduling examples: [host cron](docs/legacy/monitor-nightly-cron.md).

## Dependencies

- Claude Code or Codex; Bash 4+, `git`, authenticated GitHub CLI (`gh`), `jq`,
  `awk`, `sed`, `grep`, coreutils including GNU `date`, and `flock`.
- Node.js with npm/`npx` for the pinned Playwright MCP server (`@playwright/mcp@0.0.68`).
- `curl` for configured operations APIs; configured log/analytics/custom-check commands
  may require additional project tools.
- Development container recommended; the container is the execution boundary.

## Migration from saas-startup-team 1.x

Install: `/plugin install saas-operations@paat-plugins`.

| Surface | Old | New |
|---|---|---|
| Claude command | `/saas-startup-team:operate` | `/saas-operations:operate` |
| Claude command | `/saas-startup-team:monitor` | `/saas-operations:monitor` |
| Claude command | `/saas-startup-team:investigate` | `/saas-operations:investigate` |
| Claude command | `/saas-startup-team:replay-abandoned` | `/saas-operations:replay-abandoned` |
| Claude command | `/saas-startup-team:monitor-nightly` | `/saas-operations:monitor-nightly` |
| Codex skill | `saas-startup-team:saas-startup-team-operate-workflow` | `saas-operations:saas-operations-operate-workflow` |
| Codex skill | `saas-startup-team:saas-startup-team-monitor-workflow` | `saas-operations:saas-operations-monitor-workflow` |
| Codex skill | `saas-startup-team:saas-startup-team-investigate-workflow` | `saas-operations:saas-operations-investigate-workflow` |
| Codex skill | `saas-startup-team:saas-startup-team-replay-abandoned-workflow` | `saas-operations:saas-operations-replay-abandoned-workflow` |
| Codex skill | `saas-startup-team:saas-startup-team-monitor-nightly-workflow` | `saas-operations:saas-operations-monitor-nightly-workflow` |
| Skill | `saas-startup-team:issue-file` | `saas-operations:issue-file` |
| Issue script | `<saas-startup-team>/scripts/issue-file.sh` | `<saas-operations>/scripts/issue-file.sh` |
| Host cron probe | `<saas-startup-team>/scripts/workflow-probe.sh monitor-nightly` | `<saas-operations>/scripts/workflow-probe.sh monitor-nightly` |
| MCP allowlist prefix | `mcp__plugin_saas-startup-team_playwright__*` | `mcp__plugin_saas-operations_playwright__*` |

Operations use `.claude/saas-operations.local.md` when present; otherwise they read
`.claude/saas-startup-team.local.md`. Files are not merged. Keep delivery settings
such as `incident_labels` and `test_path_regex` in the old file for the delivery gate.
Bare `/monitor-nightly` and other moved command names are ambiguous while both
plugins are installed; use namespaced names. Delivery, maintenance, growth, and
`/digest` remain in saas-startup-team; digest scheduling is optional.
