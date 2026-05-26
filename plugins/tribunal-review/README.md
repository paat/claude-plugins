# tribunal-review

Multi-provider code review plugin for Claude Code. Runs four reviewers — Codex (GPT-5.3), Gemini (3 Pro Preview), and two OpenCode Go models (GLM-5.1, DeepSeek-V4-Pro) — then uses Opus as the final arbiter to deduplicate findings, resolve conflicts, and issue a single authoritative verdict.

## Prerequisites

- [OpenAI Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`)
- [Google Gemini CLI](https://github.com/google-gemini/gemini-cli)
- [OpenCode CLI](https://opencode.ai) with an [OpenCode Go](https://opencode.ai/go) subscription (provides the `opencode-go/glm-5.1` and `opencode-go/deepseek-v4-pro` models)
- `jq` (used to parse and validate reviewer JSON output)
- `timeout` (GNU coreutils; on macOS install coreutils for `gtimeout` or it will fall back to an error-JSON for that reviewer) — caps each reviewer at 10 minutes; the two OpenCode reviewers retry once if they hit the cap (the GLM/DeepSeek reasoning models stream long, high-variance chains-of-thought via `opencode --agent plan`)
- Valid API keys / auth configured for each CLI

Each reviewer degrades gracefully: if a CLI is missing or a model fails, that reviewer emits an error object and the arbiter proceeds with the remaining reviewers.

## Installation

```bash
claude plugin add paat/claude-plugins/plugins/tribunal-review
```

## Usage

On a feature branch with changes vs `origin/main`:

```
/tribunal-loop
```

The skill will verify you're on a feature branch, run the four reviews, and produce an arbitrated verdict.

When the verdict comes back `NEEDS_WORK` or `BLOCK`, the `closing-tribunal-loop` skill guides the iterative close-out: per-finding triage (fix-in-PR vs file-follow-up vs reject), committing fixes one finding at a time, and re-running the tribunal until the arbiter returns `APPROVE` with zero findings on the latest diff.

## How It Works

### Step 1: Pre-flight
Verifies you're on a feature branch (not main) and that there are changes to review.

### Step 2: Parallel Review
Runs Codex, Gemini, and OpenCode as **three parallel Bash calls**. Each analyzes the `git diff origin/main...HEAD` and returns structured JSON findings covering logic errors, security vulnerabilities, edge cases, performance issues, and architectural concerns. The two OpenCode reviewers run read-only (`opencode run --agent plan`) and **sequentially within the single OpenCode call** — running them concurrently deadlocks on OpenCode's shared data dir (issue #31), so they are serialized (~8-15s each, back-to-back). If the repo has an `AGENTS.md`, it is injected into every reviewer's prompt (capped at 16KB) as a shared **Project Conventions** block, so all four assess the diff against the same standards.

### Step 3: Inline Arbitration (Opus)
Opus deduplicates findings, resolves severity conflicts (always using the highest severity), marks any issue flagged by ≥2 reviewers as CONSENSUS, evaluates each finding for validity, and issues a final verdict: **APPROVE**, **NEEDS_WORK**, or **BLOCK**.

## Output Format

The tribunal produces a JSON verdict:

```json
{
  "tribunal_verdict": {
    "decision": "APPROVE|NEEDS_WORK|BLOCK",
    "confidence": 0.92,
    "rationale": "Multiple reviewers agree code is production-ready..."
  },
  "findings": [
    {
      "id": "T-001",
      "consensus": "CONSENSUS",
      "providers": ["codex", "glm"],
      "severity": "medium",
      "category": "security",
      "file": "src/auth/login.ts",
      "line": 42,
      "title": "Missing input sanitization",
      "description": "User input passed directly to query...",
      "suggestion": "Add parameterized query...",
      "confidence": 0.90,
      "arbiter_notes": "Flagged independently by codex and glm"
    }
  ],
  "provider_assessment": {
    "codex":    { "findings_accepted": 2, "findings_rejected": 1, "status": "ok" },
    "gemini":   { "findings_accepted": 3, "findings_rejected": 0, "status": "ok" },
    "glm":      { "findings_accepted": 2, "findings_rejected": 0, "status": "ok" },
    "deepseek": { "findings_accepted": 1, "findings_rejected": 1, "status": "ok" }
  },
  "summary": "Code quality is good with one medium-severity finding to address."
}
```

## Trust Hierarchy

```
Opus (Final authority, runs inline)
  |
Codex · Gemini · GLM · DeepSeek (equal advisory peers — verify findings)
```

The four reviewers are equal peers; a finding flagged by ≥2 is CONSENSUS. Opus can override any reviewer finding.

## License

MIT
