#!/bin/bash
# Thin shim → scripts/gate.sh schema (issue #391).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/gate.sh" schema --hook-stdin
