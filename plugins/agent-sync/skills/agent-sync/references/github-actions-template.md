# GitHub Actions Template for agent-sync

## Why CI does not regenerate AGENTS.md

`AGENTS.md` is a generated artifact. Verifying it by **regenerating it on the runner** re-derives it
in an environment that is, by construction, not pinned to wherever it was authored — so any
difference in the runner's `bash`/`awk`/`sed`/locale shows up as drift even when the committed file
is correct (issues #33, #92). That is a false-positive machine, not a safety net.

Instead, `AGENTS.md` is kept correct **at authoring time**: the agent-sync PostToolUse hook
regenerates it in the same environment that edited the source. CI therefore runs only the static
linter (which reads files and never re-derives `AGENTS.md`). An optional, opt-in drift backstop is
included for teams that pin their toolchain.

## Workflow

`/agent-sync:init` reads this template on demand and writes it to
`.github/workflows/agents-sync.yml` — this is the single source of truth for the YAML.

```yaml
name: agent-sync checks

on:
  pull_request:
    paths:
      - 'CLAUDE.md'
      - '.claude/**'
      - 'tools/agent-sync/sources.json'
      - '.agent-sync/sources.json'
      - 'tools/agent-sync/lint.sh'
      - '.agent-sync/lint.sh'
      - 'AGENTS.md'
      - '**/AGENTS.md'

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install jq
        run: sudo apt-get update -qq && sudo apt-get install -y jq

      - name: Lint agent-sync sources
        run: |
          if [ -f "tools/agent-sync/lint.sh" ]; then
            DIR=tools/agent-sync
          elif [ -f ".agent-sync/lint.sh" ]; then
            DIR=.agent-sync
          else
            echo "agent-sync scripts not found. Run /agent-sync:init to vendor them."
            exit 1
          fi
          bash "$DIR/lint.sh"

      # OPTIONAL drift backstop — DISABLED by default. Only enable this if your team pins the
      # toolchain so generation is deterministic across machines: a fixed runner image plus an
      # explicit `gawk` (and ideally `LC_ALL=C`). Without pinning this step false-positives when
      # the runner's shell tools differ from the author's. Uncomment to enable:
      #
      # - name: Verify AGENTS.md is in sync (pinned toolchain only)
      #   run: |
      #     sudo apt-get update -qq && sudo apt-get install -y gawk
      #     if [ -f "tools/agent-sync/generate.sh" ]; then DIR=tools/agent-sync; else DIR=.agent-sync; fi
      #     LC_ALL=C bash "$DIR/generate.sh" --check
```

## Setup

`/agent-sync:init` vendors both `generate.sh` and `lint.sh` into your repo automatically (next to `sources.json`),
so the workflow (and the optional backstop) runs without the plugin installed. If you are wiring CI
by hand instead, vendor the scripts yourself:

```bash
mkdir -p tools/agent-sync
cp "$(claude plugin path agent-sync)/scripts/generate.sh" tools/agent-sync/generate.sh
cp "$(claude plugin path agent-sync)/scripts/lint.sh" tools/agent-sync/lint.sh
```

## What It Does

- Triggers on PRs that modify Claude Code config files or AGENTS.md
- Runs `lint.sh` to catch stack contradictions, rules-file bloat, and soft directives
- Fails the check if lint finds error-severity issues
- Does **not** regenerate `AGENTS.md` by default — the PostToolUse hook keeps it in sync at
  authoring time; the optional pinned backstop above is the only place generation runs in CI
