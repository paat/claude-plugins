#!/bin/bash
# Thin shim → scripts/gate.sh spend ads (issue #391). Prefer: bash scripts/gate.sh spend ads ...
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/gate.sh" spend ads --hook-stdin
