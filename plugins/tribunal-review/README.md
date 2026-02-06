# tribunal-review

Multi-provider code review plugin for Claude Code. Runs Codex (GPT-5.3) and Gemini (3 Pro Preview) reviews in parallel, then uses Opus as the final arbiter to deduplicate findings, resolve conflicts, and issue a single authoritative verdict.

## Prerequisites

- [OpenAI Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`)
- [Google Gemini CLI](https://github.com/google-gemini/gemini-cli)
- Valid API keys configured for both CLIs

## Installation

```bash
claude plugin add paat/claude-plugins/plugins/tribunal-review
```

## Usage

On a feature branch with changes vs `origin/main`:

```
/tribunal-loop
```

The skill will verify you're on a feature branch, run both reviews in parallel, and produce an arbitrated verdict.

## How It Works

### Step 1: Pre-flight
Verifies you're on a feature branch (not main) and that there are changes to review.

### Step 2: Parallel Review
Runs Codex and Gemini as two parallel Bash calls. Each analyzes the `git diff origin/main...HEAD` and returns structured JSON findings covering logic errors, security vulnerabilities, edge cases, performance issues, and architectural concerns.

### Step 3: Inline Arbitration (Opus)
Opus deduplicates findings, resolves severity conflicts (always using the higher severity), evaluates each finding for validity, and issues a final verdict: **APPROVE**, **NEEDS_WORK**, or **BLOCK**.

## Output Format

The tribunal produces a JSON verdict:

```json
{
  "tribunal_verdict": {
    "decision": "APPROVE|NEEDS_WORK|BLOCK",
    "confidence": 0.92,
    "rationale": "Both providers agree code is production-ready..."
  },
  "findings": [
    {
      "id": "T-001",
      "consensus": "CONSENSUS",
      "severity": "medium",
      "category": "security",
      "file": "src/auth/login.ts",
      "line": 42,
      "title": "Missing input sanitization",
      "description": "User input passed directly to query...",
      "suggestion": "Add parameterized query...",
      "confidence": 0.90,
      "arbiter_notes": "Both providers identified this issue"
    }
  ],
  "provider_assessment": {
    "codex": { "findings_accepted": 2, "findings_rejected": 1, "status": "ok" },
    "gemini": { "findings_accepted": 3, "findings_rejected": 0, "status": "ok" }
  },
  "summary": "Code quality is good with one medium-severity finding to address."
}
```

## Trust Hierarchy

```
Opus (Final authority, runs inline)
  |
Codex (Trusted for logic)
  |
Gemini (Advisory, verify findings)
```

Opus can override any Codex or Gemini finding.

## License

MIT
