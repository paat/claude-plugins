#!/usr/bin/env bash
# Run a deterministic, non-agent command in a workspace-write Codex sandbox with
# no outbound destinations. AI workers never use this helper.
# The limited proxy policy keeps anonymous AF_UNIX socketpairs usable for asyncio
# while denying pathname Unix sockets and direct outbound connections.
set -euo pipefail

CODEX_BIN=${CODEX_BIN:-codex}
if [ -n "${HOME:-}" ] && [ -d "$HOME" ] && [ -w "$HOME" ]; then
  ISOLATION_PARENT="$HOME/.cache"
  mkdir -p -- "$ISOLATION_PARENT"
else
  ISOLATION_PARENT=${TMPDIR:-/tmp}
fi
ISOLATED_CODEX_HOME=$(mktemp -d "$ISOLATION_PARENT/saas-codex-sandbox.XXXXXXXX")
cleanup() { rm -rf -- "$ISOLATED_CODEX_HOME"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

CODEX_HOME="$ISOLATED_CODEX_HOME" "$CODEX_BIN" sandbox --enable network_proxy \
  -c 'permissions.saas-network-off.extends=":workspace"' \
  -c 'permissions.saas-network-off.network.enabled=true' \
  -c 'permissions.saas-network-off.network.mode="limited"' \
  --permission-profile saas-network-off "$@"
