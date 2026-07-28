#!/usr/bin/env bash
# Pre-merge safety net scaffold (idempotent). Extracted from bootstrap skill (#391).
set -uo pipefail

# 1. Canonical entrypoint: check.sh (copy template, make executable)
if [ ! -f check.sh ]; then
  cp "${CLAUDE_PLUGIN_ROOT}/templates/check.sh" check.sh
  chmod +x check.sh

  # Detection: append INERT commented suggestions only. REQUIRED_SUITES stays
  # empty, so a mis-detection can never produce a falsely-green gate.
  if [ -f package.json ]; then
    {
      echo ""
      echo "# DETECTED package.json — consider:"
      if command -v jq >/dev/null 2>&1 && jq -e '.scripts.test' package.json >/dev/null 2>&1; then
        echo "#   REQUIRED_SUITES+=(frontend_tests); frontend_tests() { run_suite frontend_tests 'npm test'; }"
      fi
      if command -v jq >/dev/null 2>&1 && jq -e '.scripts.lint' package.json >/dev/null 2>&1; then
        echo "#   REQUIRED_SUITES+=(lint); lint() { run_suite lint 'npm run lint'; }"
      fi
      [ -f tsconfig.json ] && echo "#   REQUIRED_SUITES+=(typecheck); typecheck() { run_suite typecheck 'npx tsc --noEmit'; }"
    } >> check.sh
  fi
  if [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.cfg ]; then
    {
      echo ""
      echo "# DETECTED Python project — consider:"
      echo "#   REQUIRED_SUITES+=(backend_tests); backend_tests() { run_suite backend_tests 'pytest -q'; }"
    } >> check.sh
  fi
fi

# 2. CI workflow: .github/workflows/ci.yml (copy template, substitute STACK_SETUP)
if [ ! -f .github/workflows/ci.yml ]; then
  mkdir -p .github/workflows
  cp "${CLAUDE_PLUGIN_ROOT}/templates/ci-workflow.yml" .github/workflows/ci.yml

  # Build the runtime-setup block. Install command depends on which lock/manifest
  # files exist so CI does not fail before ./check.sh (npm ci needs a lockfile;
  # pip -r needs requirements.txt).
  setup=""
  if [ -f package.json ]; then
    if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
      setup='      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n          cache: npm\n      - run: npm ci'
    else
      setup='      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n      - run: npm install'
    fi
  elif [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.cfg ]; then
    if [ -f requirements.txt ]; then
      pyinstall='pip install -r requirements.txt'
    else
      pyinstall='pip install -e .'
    fi
    setup="      - uses: actions/setup-python@v5\n        with:\n          python-version: \"3.12\"\n      - run: $pyinstall"
  else
    # No stack detected: leave a marker for the tech-founder to fill in.
    setup='      # [TECH-FOUNDER: add language/runtime setup for your stack, then\n      #  install deps, before ./check.sh runs.]'
  fi
  # Replace the whole {{STACK_SETUP}} token line. GNU sed expands \n in the
  # replacement to newlines, producing the multi-line YAML block.
  sed -i "s|.*{{STACK_SETUP}}.*|$setup|" .github/workflows/ci.yml
fi

# 3. Branch-protection [HUMAN] task (sequenced, idempotent).
mkdir -p .startup docs
if [ ! -f docs/human-tasks.md ]; then
  if [ -f .startup/human-tasks.md ]; then
    cp .startup/human-tasks.md docs/human-tasks.md
  else
    cp "${CLAUDE_PLUGIN_ROOT}/templates/human-tasks.md" docs/human-tasks.md
  fi
fi
if ! grep -q "Require the CI check (branch protection)" docs/human-tasks.md; then
  cat "${CLAUDE_PLUGIN_ROOT}/templates/branch-protection-task.md" >> docs/human-tasks.md
fi
