#!/usr/bin/env bash
# Unified test entrypoint for proton-bridge; delegates to run.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/run.sh" "$@"
