# tribunal-review

Multi-provider code review plugin for Claude Code. Runs four reviewers in parallel — Codex (GPT-5.3), Gemini (3 Pro Preview), and two OpenCode Go models (GLM-5.1, DeepSeek-V4-Pro) — then uses Opus as the final arbiter to deduplicate findings, resolve conflicts, and issue a single authoritative verdict.

## Prerequisites

- [OpenAI Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`)
- [Google Gemini CLI](https://github.com/google-gemini/gemini-cli)
- [OpenCode CLI](https://opencode.ai) with an [OpenCode Go](https://opencode.ai/go) subscription (provides the `opencode-go/glm-5.1` and `opencode-go/deepseek-v4-pro` models)
- `jq` (used to parse and validate reviewer JSON output)
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

The skill will verify you're on a feature branch, run all four reviews in parallel, and produce an arbitrated verdict.

## How It Works

### Step 1: Pre-flight
Verifies you're on a feature branch (not main) and that there are changes to review.

### Step 2: Parallel Review
Runs Codex, Gemini, GLM, and DeepSeek as four parallel Bash calls. Each analyzes the `git diff origin/main...HEAD` and returns structured JSON findings covering logic errors, security vulnerabilities, edge cases, performance issues, and architectural concerns. The two OpenCode reviewers run read-only (`opencode run --agent plan`).

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
