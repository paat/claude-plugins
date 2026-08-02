#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${MMO_CLAUDE_MODEL:-}" ]; then
  case "${MMO_OPUS_MODEL:-claude-opus-5}" in
    opus) export MMO_CLAUDE_MODEL=claude-opus-5 ;;
    *) export MMO_CLAUDE_MODEL="${MMO_OPUS_MODEL:-claude-opus-5}" ;;
  esac
fi
[ -n "${MMO_CLAUDE_EFFORT:-}" ] || export MMO_CLAUDE_EFFORT="${MMO_OPUS_EFFORT:-high}"
exec "$SCRIPT_DIR/run-claude.sh" "$@"
