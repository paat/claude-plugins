#!/usr/bin/env bash
# Mint a one-use supervisor secret for authenticating mutation receipts.
set -euo pipefail

command -v openssl >/dev/null 2>&1 || {
  echo "mutation-auth-token: openssl is required" >&2
  exit 1
}
umask 077
openssl rand -hex 32
