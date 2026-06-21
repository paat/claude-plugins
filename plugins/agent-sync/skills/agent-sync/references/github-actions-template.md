# GitHub Actions Template for AGENTS.md Drift Detection

## Workflow

`/agent-sync:init` writes this to `.github/workflows/agents-sync.yml`. It is reproduced here for
reference — keep the two copies identical.

```yaml
name: AGENTS.md Sync Check

on:
  pull_request:
    paths:
      - 'CLAUDE.md'
      - '.claude/**'
      - 'tools/agent-sync/sources.json'
      - '.agent-sync/sources.json'
      - 'AGENTS.md'
      - '**/AGENTS.md'

jobs:
  check-sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install jq
        run: sudo apt-get update -qq && sudo apt-get install -y jq

      - name: Check AGENTS.md sync and lint
        run: |
          if [ -f "tools/agent-sync/generate.sh" ] && [ -f "tools/agent-sync/lint.sh" ]; then
            DIR=tools/agent-sync
          elif [ -f ".agent-sync/generate.sh" ] && [ -f ".agent-sync/lint.sh" ]; then
            DIR=.agent-sync
          else
            echo "agent-sync scripts not found. Run /agent-sync:init to vendor them."
            exit 1
          fi
          bash "$DIR/generate.sh" --check
          bash "$DIR/lint.sh"
```

## Setup

`/agent-sync:init` vendors both `generate.sh` and `lint.sh` into your repo automatically (next to `sources.json`),
so the workflow runs without the plugin installed. If you are wiring CI by hand instead, vendor
the script yourself:

```bash
mkdir -p tools/agent-sync
cp "$(claude plugin path agent-sync)/scripts/generate.sh" tools/agent-sync/generate.sh
cp "$(claude plugin path agent-sync)/scripts/lint.sh" tools/agent-sync/lint.sh
```

## What It Does

- Triggers on PRs that modify Claude Code config files or AGENTS.md
- Runs `generate.sh --check` to verify AGENTS.md matches current config
- Runs `lint.sh` to catch stack contradictions, rules-file bloat, and soft directives
- Fails the check if drift is detected or lint finds error-severity issues
- Suggests running `/agent-sync:generate` to fix drift
