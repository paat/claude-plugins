# Lawyer Agent Design

**Date:** 2026-02-25
**Status:** Approved

## Summary

Add an on-demand legal consultant (Lawyer) to the SaaS startup team. The Lawyer is invoked via `/lawyer <topic>` by the investor. It queries the est-saas-datalake API (Estonian legal acts, companies, court decisions, RAG Q&A) and reads the startup project context to produce legal analysis in Estonian. It is an advisory consultant, not a permanent loop participant.

## Architecture

```
Human (Silent Investor)
  |  /lawyer <topic>
  v
Team Lead (Main Session)
  |  spawns one-shot Task agent
  v
Lawyer (on-demand consultant, purple)
  |  queries
  v
est-saas-datalake API (port 4100)
  + .startup/ project files
  + codebase (license audit)
  + web (international frameworks)
```

The Lawyer does NOT join the handoff loop. It writes analysis to `.startup/docs/oiguslik-*.md` and exits. The business founder references these docs in subsequent handoffs.

## Agent Definition

**File:** `agents/lawyer.md`

**Identity:**
- SaaS startup legal consultant (advokaat)
- Writes analysis in Estonian with proper Unicode diacritics
- Not a licensed attorney — provides risk framework, not legal advice
- Personality: thorough, methodical, risk-aware, pragmatic

**Tools:**
- `Bash` — curl calls to datalake API + license auditing (npm ls, pip licenses)
- `Read`, `Glob`, `Grep` — read .startup/ files and codebase
- `WebSearch`, `WebFetch` — research international legal frameworks
- `Write` — create analysis docs in .startup/docs/oiguslik-*.md
- `Task` — spawn sub-agents for parallel research

**No access to:** Edit, browser/Playwright tools, TeamCreate

**Legal domains:**
1. GDPR & privacy — data flows, DPA readiness, privacy policy, cookies, cross-border
2. Terms of Service — liability caps, warranties, IP, termination, acceptable use
3. Estonian business law — OU obligations, e-Residency, EMTA, AKI requirements
4. Software licensing & IP — open-source audit, GPL contamination, dependency compliance
5. Data Processing Agreements — sub-processors, SCCs, Schrems II
6. Business risk assessment — regulatory risk, liability exposure, insurance
7. Sector-specific — COPPA, HIPAA, PSD2, as relevant to the SaaS product

**Critical rules:**
- ALL Estonian text MUST use proper Unicode diacritics
- ALWAYS include disclaimer: analysis is framework, not legal advice
- ALWAYS cite sources (regulation references, Riigi Teataja URLs, datalake citations)
- NEVER modify existing code or handoff files
- NEVER provide definitive legal conclusions — use risk levels (madal/keskmine/kõrge)

## Datalake Integration

**API base:** `http://est-saas-datalake:4100/api/v1/`
**Authentication:** `X-API-Key` header

### Endpoints Used

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health/ready` | GET | Pre-flight check (must return 200) |
| `/rag/query` | POST | Ask legal questions, get cited answers |
| `/laws/search` | GET | Search legal acts by keyword/type/date |
| `/laws/{act_id}/citation` | GET | Look up specific paragraphs/sections |
| `/changes/feed` | GET | Check recent law changes affecting the SaaS |
| `/compliance/checklist` | POST | Generate compliance requirements |
| `/companies/search` | GET | Research competitors' legal structure |
| `/companies/{code}/board` | GET | Competitor governance |
| `/companies/{code}/tax` | GET | Competitor VAT/tax status |
| `/court/search` | GET | Find relevant court decisions |

### Pre-flight Checks (Hard Fail, No Fallbacks)

1. `curl http://est-saas-datalake:4100/api/v1/health/ready` must return 200
2. `.startup/` directory must exist with `state.json` and `brief.md`
3. API key must be available (environment variable or .startup/.env)

If any check fails: hard error with specific message. No degraded mode.

## Output Files

All written in Estonian with UTF-8 encoding:

| File | Content |
|------|---------|
| `.startup/docs/oiguslik-analuus.md` | Comprehensive legal analysis |
| `.startup/docs/oiguslik-riskid.md` | Risk register with severity ratings |
| `.startup/docs/oiguslik-teenustingimused.md` | ToS/privacy review |
| `.startup/docs/oiguslik-litsentsid.md` | Software license audit results |

## Skill

**Directory:** `skills/lawyer/`

**SKILL.md triggers:**
- Agent name is `lawyer`
- User invokes `/lawyer` command
- Questions about legal compliance, GDPR, ToS, licensing, business risk, DPA

**Reference documents:**
1. `references/gdpr-compliance.md` — GDPR framework for SaaS
2. `references/estonian-legal.md` — Estonian business law
3. `references/saas-contracts.md` — SaaS contract law
4. `references/software-licensing.md` — Open-source license compliance
5. `references/risk-assessment.md` — Risk assessment framework

## Command

**File:** `commands/lawyer.md`

**Usage:** `/lawyer <topic>`

**Workflow:**
1. Load lawyer skill
2. Pre-flight checks (datalake health, .startup/ exists, API key)
3. Read .startup/state.json for current phase
4. Read .startup/brief.md for project context
5. Read recent handoffs and .startup/docs/ for build state
6. Spawn Lawyer agent as one-shot Task
7. Lawyer researches (datalake API + web + project files)
8. Lawyer writes analysis to .startup/docs/oiguslik-*.md
9. Return summary to investor

If pre-flight fails: hard error, no fallback.

## Integration Changes

| File | Change |
|------|--------|
| `agents/lawyer.md` | NEW — agent definition |
| `commands/lawyer.md` | NEW — slash command |
| `skills/lawyer/SKILL.md` | NEW — skill definition |
| `skills/lawyer/references/*.md` | NEW — 5 reference documents |
| `skills/startup-orchestration/references/team-patterns.md` | UPDATE — add Lawyer to architecture diagram |
| `.claude-plugin/plugin.json` | UPDATE — bump version 0.2.1 -> 0.3.0 |

No changes to: hooks.json, existing agents, existing commands, existing skills.

## Non-Goals

- Lawyer does NOT participate in the handoff loop
- Lawyer does NOT have browser/Playwright tools
- Lawyer does NOT modify code or existing files
- No automatic triggering via hooks (pure on-demand)
- No gated checkpoint before solution signoff
