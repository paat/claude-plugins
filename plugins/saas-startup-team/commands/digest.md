---
name: digest
description: Assemble and send one daily needs-human digest per project — new run activity since the last send, human-tasks grouped approvals/credentials/FYI, shipped PRs, queued issues, and a spend/pass-summary section. Idempotent per day; unconfigured channel is a clean no-op. Usage: /digest [--date YYYY-MM-DD]
argument-hint: "[--date YYYY-MM-DD]"
allowed-tools: Bash, Read
user_invocable: true
---

# /digest — Daily needs-human digest

Batches a day of loop activity into one message so the investor gets one push, not a
ping per run. Assembles locally and sends once via `notify.sh --digest`. Token-frugal:
reads only `.startup/` state and `docs/human-tasks.md`.

```bash
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Resolve the effective date ONCE so all three subcommands agree even across midnight.
# An explicit --date in ARGUMENTS overrides today.
D="$(date +%F)"; case "${ARGUMENTS:-}" in *--date*) D="$(printf '%s' "${ARGUMENTS}" | sed -E 's/.*--date[= ]+([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/')" ;; esac
# Idempotent per day: if this date's digest was already sent, do not resend or thrash the
# cursor — exit 0 cleanly.
if bash "${CLAUDE_PLUGIN_ROOT}/scripts/digest.sh" already-sent --root "$ROOT" --date "$D"; then
  echo "digest: already sent for this date — skipping resend"; exit 0
fi
# assemble (idempotent — safe to re-run the same day; rebuilds from source each time)
OUT="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/digest.sh" assemble --root "$ROOT" --date "$D")"
# Advance the run cursor ONLY on a REAL send (notify.sh exit 0). Exit 3 = clean no-op
# (no channel configured): cursor stays put, command succeeds. Any other non-zero = real
# send failure: leave the cursor unadvanced (activity re-appears in a later digest) AND
# exit non-zero so cron/automation surfaces it instead of seeing a false success.
rc=0
bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" --digest \
  --title "Daily digest — $(basename "$OUT" .md)" --file "$OUT" --root "$ROOT" || rc=$?
if [ "$rc" -eq 0 ]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/digest.sh" mark-sent --root "$ROOT" --date "$D"
elif [ "$rc" -ne 3 ]; then
  echo "digest: send failed (notify rc=$rc); cursor unadvanced" >&2; exit "$rc"
fi
```

Channel config: `.startup/notify.json` (`{"kind":"ntfy|webhook|none","url":...,"token_env":...}`)
or env `SAAS_NOTIFY_KIND`/`SAAS_NOTIFY_URL`/`SAAS_NOTIFY_TOKEN_ENV`. Secrets live only in
the env var named by `token_env` — never in config or argv.

The **Spend & pass summary** section is a named placeholder a later budget governor
fills; it carries no speculative fields today. Blocker pushes are separate and
immediate — see §Blocker vs non-blocker escalation in `/maintain`.
