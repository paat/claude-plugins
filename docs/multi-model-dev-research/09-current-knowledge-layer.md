# Current knowledge for coding agents — evidence and design (2026-10-30)

Research memo behind the North star pillar "current truth, loaded on demand" (`CLAUDE.md`).
Evidence comes from one owner's self-hosted fleet (Claude Code and Codex CLI on one host and 13 dev
containers, Dec 2025 – Oct 2026) and from public sources read on 2026-10-30.

Tiers: **A** spec, API or primary data; **B** official docs; **C** third-party or preprint.
**verified** = opened at the source by the memo author on 2026-10-30; **leg** = reported by a
research subagent, not re-opened. Internal counts are pattern matches plus hand-read samples and are
approximate.

## Conclusions

1. **Most re-taught knowledge is not universal.** Two independent hand-classified samples of owner
   standing instructions (~225 and ~82 prompts) put ~10% in universal truths and best practices,
   ~40% in owner/fleet conventions and ~50% in project-specific facts. Stale universal facts drove
   ≤5% of correction prompts; misread intent (~45%) and environment conventions (~30%) drove most
   (leg). The cheapest lever is one rule set delivered to every agent home, not a knowledge base.
2. **The universal share that matters is perishable facts**: AI models and CLIs change fastest (~41%
   of agent web searches on the infrastructure side; runner model catalogs hand-edited 4 times in 10
   weeks), then laws and rates, then vendor API capabilities. A shared legal store served Estonia's
   old 22% VAT rate after 24% took effect on 2025-07-01 (verified in transcript). Every incident
   turned on the as-of date and provenance, not on knowing the rule.
3. **Curated stores go stale too**, so every stored fact needs a source, an as-of or effective date,
   and an expiry when one is known. For the most volatile facts, live state beats any stored copy:
   the existing `scripts/refresh-model-versions.sh` reads each CLI's model catalog directly.
4. **A compact precomputed index beats skills for knowledge the model lacks.** Vercel's Next.js 16
   evals: an 8 KB docs index in `AGENTS.md` passed 100%; a skill passed 53% (no gain over baseline;
   never invoked in 56% of cases) and 79% with explicit instructions to use it [V1, verified, C].
   Curated skills raised SkillsBench pass rates from 33.9% to 50.5% (+16.6 pp) [V2, verified, C].
   Skill selection degrades past roughly 50–100 skills and with near-duplicate descriptions [S14, leg, C].
5. **Knowledge graphs: not now.** Graphiti is the one option with bi-temporal validity and source
   episodes per fact, self-hostable with an MCP server [S27, leg, A], but it adds LLM cost at
   ingestion, a retrieval round trip per query, and an unauthenticated reference server.
   Git-versioned markdown with `source` / `as_of` / `expires` fields gives the needed validity and
   provenance at near-zero per-task cost. Revisit when memory shared across agents is a requirement.
6. **Public skill hubs: copy, review, pin — never auto-install.** About 26% of 31,132 marketplace
   skills had at least one vulnerability [S44, leg, C]; 341 of 2,857 skills on one hub were
   malicious [S46, leg, C]. The Agent Skills spec has no signing or provenance field [S1, leg, A].
7. **Model routing: public feeds shortlist and flag staleness; local results decide.** The live
   OpenRouter catalog lists Claude Sonnet 5.5 (2026-09-28), GPT-6 Luna (2026-09-22), Gemini 4 Argon
   (2026-10-13) and GPT-6.1 Terra (2026-10-26) [E3, verified, A], all newer than this plugin's
   catalog. Terminal-Bench 4.0: Sonnet 5 (Claude Code, max) 12.4% vs Sonnet 5.5 61.8%; GPT-5.6 Terra
   (Codex, max) 21.5% vs GPT-6 Astra 58.2% [E5, verified from the raw leaderboard pull, B].

## Usage evidence

| Signal | Observation |
|---|---|
| Volume | ~23.7k typed Claude prompts; 16,006 Codex threads (78% `codex exec`, 18% Codex-spawned subagents, 3.3% interactive) |
| Frustration themes | Stalling and nudging, needless escalation, over-engineering, routing orders — process, not knowledge |
| Prompt-inlined project conventions | Peaked July 2026 (518 Codex threads); ~0 since August, after #321 (closed 2026-07-18) capped tribunal `AGENTS.md` injection — likely cause, not proven; resolved |
| Built-in knowledge features | Codex memories: 0 rows everywhere; a docs MCP installed but ~0 calls; web search in 1.2% of Codex sessions, mostly reviewers |
| Invalid model IDs | 13 Codex threads launched on retired or nonexistent IDs ran with 0 tokens, unnoticed (latest 2026-09-07, a direct `codex exec`); `run-codex.sh` now rejects unknown IDs against a hand-edited catalog |
| Model identity | 0 of 1,838 Codex reviewer JSON outputs named the model that actually ran (leg) |

## Live evaluation feeds (as of 2026-10-30)

| Feed | Measures | Script-pullable | Caveat |
|---|---|---|---|
| OpenRouter `/api/v1/models` [E3] | Catalog: new models within hours, dated `canonical_slug` | Yes, no key (verified) | No quality signal |
| Terminal-Bench 4.0 leaderboard [E5] | Model × vendor CLI × effort, CI95, tokens, cost | Yes, undocumented POST endpoint (leg) | 35 rows, weeks of lag, likely lab-submitted rows; licence UNKNOWN |
| Arena dataset on Hugging Face [E1] | Human preference (WebDev, Agent), CIs, per-effort rows | Yes, no key, CC-BY-4.0 (leg) | Preference on web apps; misorders the middle of the field |
| Artificial Analysis API [E7] | Independently run indices, price, speed | Free key, 1,000 req/day (leg) | API list prices, not plan usage |

Stale, do not wire in (leg): SWE-bench Verified (newest entry 2026-02-26; OpenAI stopped reporting it
2026-02-23), Aider leaderboards (2025-11-20), METR time horizons (not updated since 2026-09-08),
LiveCodeBench (2025). Arena WebDev and Terminal-Bench 4.0 agree at the top (Spearman 0.83, n = 23)
but disagree in the middle, where cheap-tier choices are made (leg). No public evidence shows that
leaderboard-driven routers beat a strong fixed default; LLMRouterBench found several fail to beat a
simple baseline [E29, leg, C]. No feed measures success on the owner's repos, plan-window usage, or a
local llama.cpp build.

## Design constraints (owner, 2026-10-30)

- **Fresh out of band, cheap in band.** A scheduled curl/jq job refreshes facts and evaluation data;
  a no-change day costs zero model calls; an LLM pass runs only on a material change and opens a PR.
  A per-task decision such as routing stays a deterministic lookup.
- **Global data shortlists; local gate results decide.** Tier defaults change only on local outcome
  evidence, which requires a machine-readable outcome record per leg.
- **No human code review.** Automated gates, including an independent model's review, are the review.

## Not pursued

- Temporal knowledge graph as the store for universal truths (see conclusion 5).
- Auto-installing skills or MCP servers from public hubs (conclusion 6).
- A research pass before each routine decision (token cost; owner constraint).
- A docs MCP as the primary channel: agents rarely call one unprompted; keep it as a fallback.
- Per-repository copies of shared rules: one principles block was found copied into 60 instruction
  files; shared rules belong in one user-level block.

## Unknowns

- Agent Skills support in Grok Build and Muse Code: UNKNOWN. Cheapest probe: place a test skill and
  ask the CLI to list its skills.
- Harness effect (vendor CLI vs generic scaffold) on Terminal-Bench 4.0: the published paired test is
  underpowered, so UNKNOWN rather than zero.
- Stability of the Terminal-Bench leaderboard endpoint: undocumented; a refresh job must validate its
  schema and keep the last good table.

## Sources

- [V1] vercel.com/blog/agents-md-outperforms-skills-in-our-agent-evals — 2026-01-27 — C
- [V2] arxiv.org/abs/2602.12670 (SkillsBench) — v4 2026-06-14 — C
- [S1] agentskills.io/specification — undated — A
- [S14] arxiv.org/abs/2601.04748 — 2026-01-08 — C
- [S27] github.com/getzep/graphiti — read 2026-10-30 — A
- [S44] arxiv.org/abs/2601.10338 — 2026-01-15 — C
- [S46] thehackernews.com/2026/02/researchers-find-341-malicious-clawhub.html — 2026-02 — C
- [E1] huggingface.co/datasets/lmarena-ai/leaderboard-dataset — latest split 2026-10-28 — A
- [E3] openrouter.ai/api/v1/models — probed 2026-10-30 — A
- [E5] Terminal-Bench 4.0 leaderboard (tbench.ai, Harbor Hub `leaderboard-read`) — rows to 2026-10-23 — B
- [E7] artificialanalysis.ai/documentation — read 2026-10-30 — A
- [E29] arxiv.org/abs/2601.07206 (LLMRouterBench) — 2026-01-12 — C
