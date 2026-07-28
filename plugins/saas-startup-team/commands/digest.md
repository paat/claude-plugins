---
name: digest
description: "Daily needs-human digest. Host-scheduled. Usage: /digest [--date YYYY-MM-DD]"
argument-hint: "[--date YYYY-MM-DD]"
allowed-tools: Bash, Read
user_invocable: true
transitional: true
---

# /digest

**Scheduling lives outside prompts.** Job body only.

```bash
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
D="$(date +%F)"; case "${ARGUMENTS:-}" in *--date*) D="$(printf '%s' "$ARGUMENTS" | sed -E 's/.*--date[= ]+([0-9-]+).*/\1/')" ;; esac
bash "${CLAUDE_PLUGIN_ROOT}/scripts/workflow-probe.sh" digest || exit 0
bash "${CLAUDE_PLUGIN_ROOT}/scripts/digest.sh" already-sent --root "$ROOT" --date "$D" && exit 0
path=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/digest.sh" assemble --root "$ROOT" --date "$D")
bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" --digest --file "$path" || true
bash "${CLAUDE_PLUGIN_ROOT}/scripts/digest.sh" mark-sent --root "$ROOT"
```

No model required when probe or already-sent short-circuits.
