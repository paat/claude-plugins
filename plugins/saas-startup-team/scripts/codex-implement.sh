#!/usr/bin/env bash
# codex-implement.sh — delegate an implementation task to OpenAI Codex (gpt-5.5).
#
# Used by the tech-founder-codex / tech-founder-codex-maintain agents: they read a
# business->tech handoff and call this script to do the actual coding via `codex
# exec`, then verify the result and write their own tech->business handoff (which
# the plugin's auto-commit hook stages). Codex itself must NOT commit.
#
# Usage:  codex-implement.sh --handoff <file>   [--model M] [--timeout T] [--log F]
#         codex-implement.sh --task "<text>"    [--model M] [--timeout T] [--log F]
#
# Dependencies (documented per repo policy): the `codex` CLI must be installed and
# authenticated. Runs from the git repo root.
#
# SANDBOX POSTURE: saas-startup-team is, BY DESIGN, run only inside a disposable dev
# container (see README "Prerequisites"). The container IS the isolation boundary, so
# Codex is run with its own approvals/sandbox bypassed (the container's bwrap is also
# typically unavailable). This default is only safe under that container-only design —
# do NOT run this on a host. To harden anyway, set CODEX_NO_BYPASS=1 — that drops the
# bypass flag and enables a REAL sandbox (default workspace-write). CODEX_SANDBOX only
# selects the mode (read-only|workspace-write) AFTER bypass is disabled; on its own,
# while the bypass flag is active, it has no effect.
set -euo pipefail

HANDOFF="" TASK="" MODEL="${TF_CODEX_MODEL:-gpt-5.5}" TIMEOUT="${TF_CODEX_TIMEOUT:-30m}" LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --handoff) HANDOFF="$2"; shift 2;;
    --task)    TASK="$2"; shift 2;;
    --model)   MODEL="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --log)     LOG="$2"; shift 2;;
    *) echo "codex-implement.sh: unknown arg $1" >&2; exit 2;;
  esac
done

# Exit-code contract: 3 = codex CLI unavailable (re-route to the Claude engine);
# 2 = usage error; 4 = environment/setup error (not a "codex missing" signal).
command -v codex >/dev/null 2>&1 || { echo "ERROR: codex CLI not found — cannot use the codex engine. Install codex or route this task to tech-founder-claude." >&2; exit 3; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: not inside a git repo" >&2; exit 4; }

if [ -n "$HANDOFF" ]; then
  # Handoff paths are repo-root-relative by contract: always resolve a non-absolute
  # path against $REPO_ROOT (don't fall back to the caller's cwd, which could match a
  # different file in a subdir).
  case "$HANDOFF" in /*) : ;; *) HANDOFF="$REPO_ROOT/$HANDOFF" ;; esac
  [ -f "$HANDOFF" ] || { echo "ERROR: handoff file not found: $HANDOFF" >&2; exit 4; }
  TASK_TEXT="$(cat "$HANDOFF")"
elif [ -n "$TASK" ]; then
  TASK_TEXT="$TASK"
else
  echo "usage: --handoff <file> | --task <text>" >&2; exit 2
fi
LOG="${LOG:-$REPO_ROOT/.startup/.codex-implement.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# Engine-agnostic tech-founder contract (mirrors agents/tech-founder-claude.md).
PROMPT="$(cat <<'EOF'
You are the technical co-founder implementing a task on a PRODUCTION application.
Rules:
- Production quality: real error handling, validation, auth on sensitive endpoints.
  No placeholders, no "MVP later" — ship production or nothing.
- ALL non-English UI/text/templates MUST use correct Unicode (Estonian ä ö ü õ š ž,
  Cyrillic where relevant) — NEVER ASCII transliterations. UTF-8 source files.
- Keep the diff MINIMAL and FOCUSED; reuse existing abstractions; follow the repo's
  existing conventions and any CLAUDE.md / AGENTS.md.
- If this resolves a bug/incident: write a regression test that FAILS before your
  change and PASSES after, and verify it.
- Set 10s timeouts on HTTP calls; never retry a failed call more than 3 times.
- Implement the task, then run the project's check/gate if one exists and fix until
  green or clearly report the blocker.
- Do NOT git commit, push, branch, or open a PR. Leave changes in the working tree
  (the team's handoff hook commits). Do not touch files unrelated to the task.

================  HANDOFF / TASK  ================
EOF
)"
PROMPT="$PROMPT
$TASK_TEXT"

# Sandbox handling: a dev container's bwrap is typically unavailable, so by default
# we bypass approvals+sandbox and run danger-full-access. CODEX_NO_BYPASS=1 opts into
# a real sandbox: drop the bypass AND default the policy to workspace-write (not
# danger-full-access), unless the caller explicitly set CODEX_SANDBOX.
if [ "${CODEX_NO_BYPASS:-0}" = "1" ]; then
  SANDBOX="${CODEX_SANDBOX:-workspace-write}"
  BYPASS=""
else
  SANDBOX="${CODEX_SANDBOX:-danger-full-access}"
  BYPASS="--dangerously-bypass-approvals-and-sandbox"
fi

echo "[codex-implement] model=$MODEL timeout=$TIMEOUT sandbox=$SANDBOX root=$REPO_ROOT" >&2
set +e
# shellcheck disable=SC2086
timeout "$TIMEOUT" codex exec --json -s "$SANDBOX" $BYPASS -m "$MODEL" -C "$REPO_ROOT" - \
  <<<"$PROMPT" | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
[ "$rc" = "124" ] && echo "[codex-implement] TIMED OUT after $TIMEOUT" >&2
echo "[codex-implement] codex exit=$rc (log: $LOG)" >&2
exit "$rc"
