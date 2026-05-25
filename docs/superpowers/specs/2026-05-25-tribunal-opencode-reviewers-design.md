# Tribunal Review — Add OpenCode Go Reviewers

**Date:** 2026-05-25
**Plugin:** `plugins/tribunal-review`
**Version bump:** 0.1.1 → 0.2.0 (new feature)

## Problem

The tribunal currently runs two parallel reviewers — Codex (`codex` CLI) and Gemini
(`gemini` CLI) — and arbitrates inline with Opus. The user wants to **add** two more
reviewers backed by their **OpenCode Go** subscription, without removing Codex or
Gemini. This turns the tribunal into a four-reviewer consensus panel.

## Goals

- Add two OpenCode-backed reviewers using the `opencode` CLI and the user's Go subscription.
- Keep Codex and Gemini exactly as they are.
- All four reviewers run the **same comprehensive review prompt**; Opus's dedup/consensus
  engine is what extracts signal (a finding ≥2 reviewers agree on becomes CONSENSUS).
- Generalize the Opus arbiter from 2 hardcoded providers to N providers.

## Non-goals

- No removal of Codex or Gemini.
- No web-search grounding for the OpenCode reviewers (OpenCode Go models have none built in;
  Gemini retains its CVE-search role).
- No external script files / no `opencode serve` server lifecycle (keep the plugin's
  self-contained inline-block pattern).

## Model selection (research conclusion)

Two models from the `opencode-go/` provider, chosen for **lineage diversity** and
**complementary strengths** relative to the existing two reviewers:

| Reviewer | Model | Lineage | Strength reinforced |
|----------|-------|---------|---------------------|
| Codex (existing) | GPT-5.3-codex | OpenAI | logic, edge cases, quality |
| Gemini (existing) | gemini-3-pro-preview | Google | security, architecture, + web/CVE search |
| **GLM (new)** | `opencode-go/glm-5.1` | Zhipu | strongest agentic coder → architecture, code structure, quality |
| **DeepSeek (new)** | `opencode-go/deepseek-v4-pro` | DeepSeek | strongest pure reasoner → logic, concurrency, math/edge-cases |

Rationale: four **different model families** maximize the value of a consensus panel.
DeepSeek **Pro** (not Flash) is used — Flash is the speed/cost tier and too shallow for a
deep review. Caveat: these exact version numbers post-date the assistant's training
cutoff; ranking is by each family's track record and tier position in the Go lineup, not
benchmarks of these specific builds.

## Approach (chosen: A — four inline parallel reviewer blocks)

Alternatives considered:
- **B** — one shared parameterized wrapper script under `${CLAUDE_PLUGIN_ROOT}/scripts/`.
  Rejected: introduces external script files the plugin doesn't currently use (architecture change).
- **C** — `opencode serve` + `--attach` for warm reuse. Rejected: adds server lifecycle complexity.

Chosen A because the two OpenCode blocks differ only by `-m` and the `provider` label, and
keeping them inline matches how Codex/Gemini already live in `SKILL.md`.

## Design

### 1. Step 2 — four parallel Bash reviewers

`SKILL.md` Step 2 grows from 2 parallel Bash calls to **4**. Codex and Gemini blocks are
unchanged. Two new near-identical OpenCode blocks are added, differing only in `-m` and the
`provider` field:

```bash
cd "$(git rev-parse --show-toplevel)"
TMPDIR=$(mktemp -d) && trap 'rm -rf "$TMPDIR"' EXIT
DIFF=$(git diff origin/main...HEAD)

if [ -z "$DIFF" ]; then
  printf '%s\n' '{"provider":"glm","model":"opencode-go/glm-5.1","findings":[],"summary":{"total_findings":0,"critical":0,"high":0,"medium":0,"low":0,"quality_score":10.0,"verdict":"APPROVE","note":"No changes detected vs origin/main"}}'
  exit 0
fi

# Diff-size guard (GLM/DeepSeek have large context; cap higher than Codex's 100KB)
DIFF_SIZE=${#DIFF}
DIFF_TRUNCATED=false
if [ "$DIFF_SIZE" -gt 204800 ]; then
  DIFF=$(echo "$DIFF" | head -c 204800); DIFF_TRUNCATED=true
fi

opencode run --agent plan -m opencode-go/glm-5.1 --variant high --format default --pure \
  "<comprehensive review prompt — identical to the other reviewers — with the diff inline
    and an explicit instruction: do NOT use any tools; analyze ONLY the diff below; output
    ONLY the JSON object, no markdown>" \
  >"$TMPDIR/glm-raw.txt" 2>"$TMPDIR/glm-stderr.txt"
OC_EXIT=$?

# JSON extraction (no --output-schema in opencode): strip fences, slice first { .. last },
# jq-validate; on failure emit standard error JSON so the arbiter degrades gracefully.
...
```

Key parameters:
- `--agent plan` — OpenCode's built-in read-only agent (cannot edit/write the repo);
  defense-in-depth alongside the inline diff and the "no tools" instruction.
- `--variant high` — deeper reasoning effort.
- `--format default` — prints the assistant's text answer (the `json` format emits a raw
  *event stream*, which is messier to reduce to one JSON blob).
- `--pure` — run without external plugins/MCP.

**JSON extraction is the main implementation risk.** OpenCode has no `--output-schema`
(unlike Codex). Plan: capture stdout, strip ```` ``` ```` fences, slice from the first `{`
to the last `}`, and `jq`-validate. On any failure, emit
`{"error":"OpenCode execution failed","exit_code":N,"stderr":"..."}` matching the existing
Codex/Gemini error pattern. **Before finalizing the extractor, run one throwaway
`opencode run` against a tiny diff to confirm the exact stdout shape**, then build the
extractor to match.

### 2. Generalize the Opus arbiter (2 → N providers)

`SKILL.md` Step 3 and `agents/opus-arbiter.md` currently hardcode `codex` and `gemini`.
Generalize:

- **`provider_assessment`** becomes keyed by provider name — `codex`, `gemini`, `glm`,
  `deepseek` — each with `findings_accepted`, `findings_rejected`, `false_positives`, `status`.
- **Consensus rule:** a finding is `CONSENSUS` when **≥2 providers** independently report it;
  record the supporting providers. Highest severity among reporters wins (existing HARD RULE,
  extended to N). Single-provider findings keep lower confidence.
- **Trust model:** all four reviewers are **equal advisory peers**; Opus retains final
  authority. Replaces the current `Codex > Gemini` hierarchy.
- **`consensus` field** on each finding: `CONSENSUS | SINGLE | ARBITRATED`, plus a
  `providers: [...]` array naming which reviewers flagged it.
- **Confidence bands:** CONSENSUS (≥2) 0.85–0.99; SINGLE 0.60–0.80; ARBITRATED 0.50–0.70;
  self-added 0.50–0.65.
- **Degraded input:** "any subset of providers failed → proceed with the rest, note failures";
  "all failed → NEEDS_WORK, confidence 0.0"; "all returned zero findings → APPROVE, 0.95".

### 3. Metadata + docs

- Bump version `0.1.1 → 0.2.0` in **both** `plugins/tribunal-review/.claude-plugin/plugin.json`
  and the root `.claude-plugin/marketplace.json` (repo rule: keep in sync).
- Update plugin `description` and `keywords` to include `opencode`, `glm`, `deepseek`.
- Add `agents/opencode-reviewer.md` doc stub (documentation/standalone-test, mirroring the
  existing reviewer stubs).
- Update `SKILL.md` prose: providers list, trust-hierarchy diagram, quick-reference table
  (4 parallel Bash calls), and the `[TRIBUNAL 2/3]` output line to report 4 reviewers.

## Error handling

- Each reviewer is independent; a failure emits standard error JSON and the arbiter proceeds
  with the rest.
- OpenCode CLI not installed → `{"error":"OpenCode CLI not found. Install from https://opencode.ai"}`.
- Diff truncation noted in the prompt when triggered.

## Testing

1. Run one throwaway `opencode run -m opencode-go/glm-5.1` on a tiny diff to confirm stdout
   shape and that `--agent plan` blocks writes.
2. Dry-run all four reviewer blocks on the current branch's diff (or a small synthetic diff);
   confirm each emits valid JSON.
3. Confirm the arbiter merges 4 inputs and marks a planted duplicate finding as CONSENSUS with
   the correct `providers` array.
4. Confirm graceful degradation when one OpenCode model is forced to fail.
