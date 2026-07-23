#!/usr/bin/env bash
# Exit 0 when automatic hooks must stand down for an active worker phase.
set -euo pipefail

[ -n "${SAAS_PHASE:-}" ]
