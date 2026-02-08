# GitHub Actions Template for AGENTS.md Drift Detection

## Workflow

Add this to `.github/workflows/agents-sync.yml`:

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
        run: sudo apt-get install -y jq

      - name: Check AGENTS.md sync
        run: |
          # Find the generate script
          if [ -f "tools/agent-sync/generate.sh" ]; then
            bash tools/agent-sync/generate.sh --check
          elif [ -f ".agent-sync/generate.sh" ]; then
            bash .agent-sync/generate.sh --check
          else
            echo "agent-sync generate.sh not found. Copy it from the plugin or install agent-sync."
            exit 1
          fi
```

## Setup

To use this workflow, copy `generate.sh` from the agent-sync plugin into your project:

```bash
mkdir -p tools/agent-sync
cp "$(claude plugin path agent-sync)/scripts/generate.sh" tools/agent-sync/generate.sh
```

Or reference the plugin script directly if the plugin is installed in CI.

## What It Does

- Triggers on PRs that modify Claude Code config files or AGENTS.md
- Runs `generate.sh --check` to verify AGENTS.md matches current config
- Fails the check if drift is detected
- Suggests running `/agent-sync:generate` to fix
