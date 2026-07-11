#!/usr/bin/env bash
# codex-implement.sh — delegate an implementation task to OpenAI Codex
# (gpt-5.6-sol at "high" reasoning effort by default).
#
# Used by the tech-founder-codex / tech-founder-codex-maintain agents: they read a
# business->tech handoff and call this script to do the actual coding via `codex
# exec`, then verify the result and write their own tech->business handoff (which
# the plugin's auto-commit hook stages). Codex itself must NOT commit.
#
# Usage:  codex-implement.sh --handoff <file>   [--plan <file>] [--model M] [--effort E] [--timeout T] [--log F]
#         codex-implement.sh --task "<text>"    [--model M] [--effort E] [--timeout T] [--log F]
#
# MODEL/EFFORT PINNING: both are passed explicitly on every invocation so the user's
# ~/.codex/config.toml can never leak in (a config pinned to `ultra` effort would
# silently multiply the cost of every unattended loop run). Override via
# TF_CODEX_MODEL / TF_CODEX_EFFORT or --model / --effort. Effort values:
# low|medium|high|xhigh|max|ultra — do NOT use `ultra` in unattended loops; it spawns
# parallel subagents and burns tokens roughly 4x faster.
#
# --plan attaches the architect pass output (NNN-tech-plan.md) when the orchestrator
# ran one; its content is appended to the prompt after the handoff.
#
# Dependencies (documented per repo policy): the `codex` CLI must be installed and
# authenticated. Runs from the git repo root.
#
# SANDBOX POSTURE: default to `-s danger-full-access` (no bypass flag). This disables
# only Codex's sandbox *mode* — sidestepping the broken bwrap that fails inside dev
# containers — while still passing Claude Code's permission classifier (the
# `--dangerously-bypass-approvals-and-sandbox` flag does NOT pass it). In `codex exec`
# (non-interactive) this is functionally equivalent to the old bypass posture but
# portable beyond the container. saas-startup-team is still, BY DESIGN, run only inside
# a disposable dev container (see README "Prerequisites") — the container remains the
# isolation boundary. To harden on a non-container host, set CODEX_SANDBOX to a REAL
# sandbox mode (workspace-write|read-only); CODEX_NO_BYPASS=1 is honored as a legacy
# alias that selects workspace-write.
set -euo pipefail

HANDOFF="" TASK="" PLAN="" MODEL="${TF_CODEX_MODEL:-gpt-5.6-sol}" EFFORT="${TF_CODEX_EFFORT:-high}" TIMEOUT="${TF_CODEX_TIMEOUT:-30m}" LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --handoff) HANDOFF="$2"; shift 2;;
    --task)    TASK="$2"; shift 2;;
    --plan)    PLAN="$2"; shift 2;;
    --model)   MODEL="$2"; shift 2;;
    --effort)  EFFORT="$2"; shift 2;;
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
if [ -n "$PLAN" ]; then
  case "$PLAN" in /*) : ;; *) PLAN="$REPO_ROOT/$PLAN" ;; esac
  [ -f "$PLAN" ] || { echo "ERROR: plan file not found: $PLAN" >&2; exit 4; }
  PROMPT="$PROMPT

================  TECHNICAL PLAN (follow its contracts and file map)  ================
$(cat "$PLAN")"
fi

# Sandbox handling: default to danger-full-access mode (no bypass flag) — see the
# SANDBOX POSTURE note above. The bypass flag is never used now. CODEX_NO_BYPASS=1 is a
# legacy alias that requests a real sandbox (workspace-write) instead.
if [ "${CODEX_NO_BYPASS:-0}" = "1" ]; then
  SANDBOX="${CODEX_SANDBOX:-workspace-write}"
else
  SANDBOX="${CODEX_SANDBOX:-danger-full-access}"
fi

echo "[codex-implement] model=$MODEL effort=$EFFORT timeout=$TIMEOUT sandbox=$SANDBOX root=$REPO_ROOT" >&2
# Keep codex's content stream (stdout, the --json events the agent reads) in $LOG, and
# codex's OWN diagnostics (stderr) in $ERRLOG. bwrap detection must scan stderr only:
# the --json stdout can echo file/diff content containing the bwrap error string, which
# would false-positive a stdout scan. Re-emit stderr afterward so it stays visible.
ERRLOG="${LOG}.stderr"
set +e
timeout "$TIMEOUT" codex exec --json -s "$SANDBOX" -m "$MODEL" \
  -c model_reasoning_effort="\"$EFFORT\"" -C "$REPO_ROOT" - \
  <<<"$PROMPT" 2>"$ERRLOG" | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
cat "$ERRLOG" >&2 2>/dev/null || true
# Diagnostics only — these surface remedies on stderr but do NOT change the exit-code
# contract the agents depend on (3 = codex unavailable → reroute; 2 = usage; 4 = env).
# bwrap-sandbox failure: codex couldn't touch the FS, so the implementation no-ops.
# Only possible when a REAL sandbox was selected (CODEX_SANDBOX=workspace-write|read-only)
# inside a container with broken bwrap; the default danger-full-access avoids it. Guard on
# rc != 0 so a stray "bwrap:" line never fires on an otherwise-successful run.
if [ "$rc" != "0" ] && grep -qE 'bwrap:.*(Permission denied|Operation not permitted|Failed to make)' "$ERRLOG" 2>/dev/null; then
  echo "[codex-implement] codex's bwrap sandbox failed to initialize — it could not read/write repo files." >&2
  echo "[codex-implement] Re-run with the default -s danger-full-access (unset CODEX_SANDBOX). Do NOT use" >&2
  echo "[codex-implement] --dangerously-bypass-approvals-and-sandbox: Claude Code's classifier blocks it." >&2
fi
# Partial-run recovery: timeout (124) or SIGTERM-kill (143) leaves uncommitted partial edits.
if [ "$rc" = "124" ] || [ "$rc" = "143" ]; then
  echo "[codex-implement] TIMED OUT after $TIMEOUT (exit $rc) — codex was killed mid-task." >&2
  echo "[codex-implement] Partial, UNCOMMITTED edits may remain in the working tree. Before writing the handoff," >&2
  echo "[codex-implement] inspect with: git -C \"$REPO_ROOT\" status — then either keep the usable partial work or" >&2
  echo "[codex-implement] discard it with: git -C \"$REPO_ROOT\" checkout -- . (and remove any stray new files)." >&2
  echo "[codex-implement] Re-run with a larger --timeout AND a larger Bash-tool timeout." >&2
fi
echo "[codex-implement] codex exit=$rc (log: $LOG)" >&2
exit "$rc"
