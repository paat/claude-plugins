#!/bin/bash
# Thin shim → scripts/gate.sh spend linkedin (issue #391).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/gate.sh" spend linkedin --hook-stdin
