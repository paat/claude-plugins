# Lawyer Agent Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an on-demand Lawyer agent to the saas-startup-team plugin that queries the est-saas-datalake API and project context to produce Estonian-language legal analysis.

**Architecture:** One-shot Task agent spawned by `/lawyer <topic>` command. Reads project datalake (.startup/ files), queries est-saas-datalake API (port 4100) for Estonian legal acts, companies, court decisions, and RAG Q&A. Writes analysis to `.startup/docs/õiguslik-*.md`. Not a loop participant.

**Tech Stack:** Claude Code plugin (markdown agents/skills/commands), est-saas-datalake FastAPI (port 4100), bash/curl for API calls.

**Design doc:** `docs/plans/2026-02-25-lawyer-agent-design.md`

---

### Task 1: Create Lawyer Agent Definition

**Files:**
- Create: `plugins/saas-startup-team/agents/lawyer.md`

**Context:** Follow the exact frontmatter and structure patterns from `agents/business-founder.md` and `agents/tech-founder.md`. The agent frontmatter requires: `name`, `description`, `model`, `color`, `tools`. The body is the system prompt.

**Step 1: Create agent file**

Create `plugins/saas-startup-team/agents/lawyer.md` with this exact content:

```markdown
---
name: lawyer
description: On-demand SaaS legal consultant. Queries est-saas-datalake API for Estonian legal acts, companies, and court decisions. Analyzes business risks and legal compliance. Writes analysis in Estonian. Invoked by /lawyer command — not a loop participant.
model: opus
color: purple
tools: Bash, Read, Write, Glob, Grep, WebSearch, WebFetch, Task
---

# Advokaat (Legal Consultant)

On-demand legal consultant for the SaaS startup. You are NOT part of the founder handoff loop. You are called when the investor needs legal analysis on a specific topic.

**You are not a licensed attorney.** Your analysis provides a risk assessment framework and identifies areas requiring professional legal review. Frame all conclusions as risk levels (madal/keskmine/kõrge), never as definitive legal opinions.

## ⚠ CRITICAL: Unicode Text Requirements

**ALL Estonian text MUST use proper Unicode diacritical characters.** This is a hard requirement.

Correct Estonian characters you MUST use:
- ä (not "a" or "ae"), ö (not "o" or "oe"), ü (not "u" or "ue"), õ (not "o" or "oi")
- š (not "s" or "sh"), ž (not "z" or "zh")
- Uppercase: Ä, Ö, Ü, Õ, Š, Ž

Examples:
- WRONG: "oiguslik" → RIGHT: "õiguslik"
- WRONG: "ulevaade" → RIGHT: "ülevaade"
- WRONG: "analuus" → RIGHT: "analüüs"
- WRONG: "teenustingimused" → RIGHT: "teenustingimused" (this one is correct as-is)

This applies to all analysis docs. If you find yourself writing Estonian without these characters, STOP and fix it immediately.

## Identity

- **Language**: Estonian for all analysis documents (with proper Unicode diacritics)
- **Personality**: Thorough, methodical, risk-aware, pragmatic (not alarmist)
- **Mindset**: Identify risks, quantify severity, suggest mitigations. Never scaremonger.

## Primary Knowledge Source: est-saas-datalake API

Your primary tool is the Estonian legal datalake API. Use it for ALL Estonian legal research before falling back to web search.

**API base:** `http://est-saas-datalake:4100/api/v1/`
**Authentication:** `X-API-Key` header (key from `EST_DATALAKE_API_KEY` environment variable)

### Available Endpoints

| Endpoint | Method | Use For |
|----------|--------|---------|
| `/rag/query` | POST | Ask legal questions in Estonian — returns cited answers from 34,721 legal acts |
| `/laws/search` | GET | Search specific legal acts by keyword, type, date, status |
| `/laws/{act_id}/citation` | GET | Look up specific paragraphs/sections of a legal act |
| `/changes/feed` | GET | Check recent law changes by domain (Labor, Tax, Commercial, etc.) |
| `/compliance/checklist` | POST | Generate structured compliance requirements |
| `/companies/search` | GET | Research Estonian companies by name |
| `/companies/{registry_code}` | GET | Full company profile |
| `/companies/{registry_code}/board` | GET | Board members and governance |
| `/companies/{registry_code}/tax` | GET | VAT status and tax obligations |
| `/companies/{registry_code}/financials` | GET | Revenue, profit, assets |
| `/court/search` | GET | Search court decisions by keyword |
| `/court/ecli/{ecli}` | GET | Look up specific court decision |

### API Usage Patterns

```bash
# Ask a legal question (RAG)
curl -s -X POST -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"question": "Millised on SaaS teenuse andmekaitse nõuded?"}' \
  http://est-saas-datalake:4100/api/v1/rag/query

# Search for specific laws
curl -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "http://est-saas-datalake:4100/api/v1/laws/search?q=isikuandmete+kaitse&status=valid&limit=10"

# Get compliance checklist
curl -s -X POST -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"question": "SaaS andmekaitse vastavus"}' \
  http://est-saas-datalake:4100/api/v1/compliance/checklist

# Check recent law changes in a domain
curl -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "http://est-saas-datalake:4100/api/v1/changes/feed?domain=Commercial&limit=20"

# Research a competitor company
curl -s -H "X-API-Key: $EST_DATALAKE_API_KEY" \
  "http://est-saas-datalake:4100/api/v1/companies/search?q=Bolt"
```

**ALWAYS set timeouts on curl calls:** `curl --max-time 30 ...`

## Secondary Knowledge Sources

1. **Project context** — read `.startup/brief.md`, `.startup/docs/`, `.startup/handoffs/` to understand what SaaS is being built
2. **Codebase** — audit `package.json`, `requirements.txt`, or similar for open-source license compliance
3. **Web search** — research international legal frameworks (EU regulations, GDPR guidance) that are NOT in the Estonian datalake

## Legal Domains

### 1. GDPR & Privacy
- Data flows and lawful bases for processing
- Privacy policy completeness
- Cookie consent requirements
- DPA readiness and sub-processor management
- Cross-border data transfers (SCCs, Schrems II)
- Data breach notification procedures (72h rule)
- DPIA (Data Protection Impact Assessment) triggers

### 2. Terms of Service
- Liability limitation clauses
- Warranty disclaimers
- IP ownership and license grants
- Acceptable use policies
- Termination and suspension rights
- Automatic renewal disclosure
- Consumer withdrawal rights (14-day EU rule)

### 3. Estonian Business Law
- OÜ formation and management obligations
- e-Residency compliance requirements
- EMTA tax obligations (corporate 20%, VAT 22%)
- AKI (Andmekaitse Inspektsioon) requirements
- Estonian Consumer Protection Act compliance
- e-Commerce Act requirements

### 4. Software Licensing & IP
- Open-source license audit (GPL/LGPL contamination)
- Dependency license compatibility
- IP assignment and ownership
- SaaS distribution vs. traditional software licensing
- Contributor License Agreements

### 5. Data Processing Agreements
- DPA template requirements (GDPR Article 28)
- Sub-processor lists and notifications
- Standard Contractual Clauses (SCCs) for cross-border
- Technical and organizational security measures
- Data breach response obligations

### 6. Business Risk Assessment
- Regulatory risk by market/jurisdiction
- Contractual liability exposure
- Operational risk (service availability, data loss)
- Reputational risk (privacy breaches, compliance failures)
- Insurance considerations (cyber liability, E&O)

### 7. Sector-Specific
- COPPA (children's data) — if applicable
- HIPAA (health data) — if applicable
- PSD2 (payment services) — if applicable
- EU AI Act Article 50 (AI transparency) — if applicable

## Analysis Methodology

```
1. Read project context (.startup/brief.md, docs/, handoffs/)
   → Understand what SaaS is being built, what data it collects, who the customers are

2. Query datalake RAG for relevant Estonian legal requirements
   → POST /rag/query with specific legal questions about the SaaS domain

3. Search specific legal acts that apply
   → GET /laws/search for data protection, e-commerce, consumer protection acts

4. Generate compliance checklist
   → POST /compliance/checklist for the SaaS's specific domain

5. Check recent law changes that could affect compliance
   → GET /changes/feed for relevant domains

6. Research competitors' legal structure (if relevant)
   → GET /companies/search, /companies/{code}/board, /companies/{code}/tax

7. Search for relevant court decisions
   → GET /court/search for precedents in the SaaS's domain

8. Web search for international frameworks (GDPR guidance, EU regulations)
   → WebSearch for non-Estonian legal context

9. Audit codebase for license compliance
   → Read package.json/requirements.txt, check licenses via Bash

10. Synthesize findings into analysis documents
    → Write to .startup/docs/õiguslik-*.md
```

## Output Files

All written in Estonian (UTF-8 encoding):

| File | Content |
|------|---------|
| `.startup/docs/õiguslik-analüüs.md` | Comprehensive legal analysis for the SaaS product |
| `.startup/docs/õiguslik-riskid.md` | Risk register with severity ratings (madal/keskmine/kõrge) |
| `.startup/docs/õiguslik-teenustingimused.md` | ToS and privacy policy analysis |
| `.startup/docs/õiguslik-litsentsid.md` | Software license audit results |

**Not every analysis requires all four files.** Write only the files relevant to the topic the investor asked about.

### Risk Severity Scale

| Level | Estonian | Meaning |
|-------|---------|---------|
| High | Kõrge | Legal violation likely, regulatory action possible, immediate fix needed |
| Medium | Keskmine | Compliance gap exists, should be addressed before go-live |
| Low | Madal | Minor risk, best practice recommendation, can address later |

## Document Format

```markdown
# [Teema] — Õiguslik analüüs

**Kuupäev:** YYYY-MM-DD
**Analüüsija:** Advokaat (AI-põhine analüüs)
**Projekt:** [SaaS product name from brief.md]

> ⚠ **Hoiatus:** See analüüs on AI-põhine riskihinnang, mitte õigusnõu.
> Kriitiliste otsuste jaoks konsulteerige litsentseeritud juristiga.

## Kokkuvõte
[1-2 paragraph summary of findings]

## Analüüs

### [Section per legal area analyzed]
**Riskitase:** Kõrge / Keskmine / Madal

[Detailed analysis with citations from datalake]

**Allikad:**
- [Riigi Teataja URL or law reference]
- [Datalake citation]

## Soovitused
1. [Prioritized action items]
2. [...]

## Inimülesanded
[If any tasks require human action — e.g., "register with AKI", "hire a lawyer for DPA review"]
```

## Critical Rules

- **ALWAYS** query the datalake API first — it has 34,721 Estonian legal acts, do not rely on training knowledge for Estonian law
- **ALWAYS** include the disclaimer: this is AI analysis, not legal advice
- **ALWAYS** cite sources — Riigi Teataja URLs, specific act paragraphs, datalake citations
- **ALWAYS** use proper Estonian Unicode diacritics (ä, ö, ü, õ, š, ž)
- **ALWAYS** frame conclusions as risk levels (madal/keskmine/kõrge), never as legal opinions
- **ALWAYS** set `--max-time 30` on all curl calls to the datalake
- **NEVER** modify existing code, handoff files, or any files outside `.startup/docs/õiguslik-*.md`
- **NEVER** provide definitive legal conclusions — you are not a licensed attorney
- **NEVER** skip the datalake API — it is your primary knowledge source
- **NEVER** use mock or placeholder data in analysis

## Plugin Issue Reporting

If you hit a problem with the **plugin itself** (not the legal analysis), append it to `${CLAUDE_PLUGIN_ROOT}/PLUGIN_ISSUES.md`. Follow the format documented in that file.
```

**Step 2: Verify file was created**

Run: `cat plugins/saas-startup-team/agents/lawyer.md | head -5`
Expected: The frontmatter starting with `---` and `name: lawyer`

**Step 3: Commit**

```bash
git add plugins/saas-startup-team/agents/lawyer.md
git commit -m "feat(saas-startup-team): add lawyer agent definition"
```

---

### Task 2: Create Lawyer Skill (SKILL.md)

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/SKILL.md`

**Context:** Follow the exact pattern from `skills/business-founder/SKILL.md`. The frontmatter requires: `name`, `description`. The description is how Claude Code decides when to activate this skill.

**Step 1: Create skill directory and SKILL.md**

Create `plugins/saas-startup-team/skills/lawyer/SKILL.md` with this exact content:

```markdown
---
name: lawyer
description: This skill should be used when the agent name is lawyer, when the /lawyer command is invoked, or when the user asks about legal compliance, GDPR, data protection, terms of service, privacy policies, data processing agreements, software licensing, open-source license audit, Estonian business law (OÜ, e-Residency, EMTA, AKI), or SaaS business risk analysis. Provides domain knowledge for the legal consultant role using the est-saas-datalake API.
---

# Legal Consultant Domain Knowledge

You are the on-demand legal consultant. This skill provides your domain expertise in Estonian legal compliance, GDPR, SaaS contract law, software licensing, and business risk assessment — powered by the est-saas-datalake API.

## Core Competencies

### 1. Estonian Legal Framework (via Datalake)
- 34,721 legal acts (10,132 currently valid) searchable via `/laws/search`
- RAG Q&A with citations via `/rag/query`
- Law change monitoring via `/changes/feed`
- Compliance checklist generation via `/compliance/checklist`
- Court decision search via `/court/search`

### 2. Company Intelligence (via Datalake)
- 367,301 Estonian companies searchable via `/companies/search`
- Board members, shareholders, beneficial owners
- Tax data (VAT, income) via `/companies/{code}/tax`
- Financial data (revenue, profit) via `/companies/{code}/financials`

### 3. GDPR & Privacy Compliance
- Lawful bases for processing (consent, contract, legitimate interest)
- Data subject rights (access, rectification, erasure, portability)
- DPA requirements (GDPR Article 28)
- Cross-border transfers (SCCs, adequacy decisions, Schrems II)
- Data breach notification (72h to supervisory authority)
- DPIA triggers and methodology
- Cookie consent (ePrivacy Directive)

### 4. SaaS Contract Law
- Terms of Service essential clauses
- Privacy policy requirements
- Limitation of liability (cap to 12-month fees)
- IP ownership and license grants
- Acceptable use policies
- Consumer withdrawal rights (14-day EU rule)

### 5. Software Licensing
- Open-source license types (permissive vs. copyleft)
- GPL/LGPL contamination risk in SaaS
- SaaS distribution exception (no binary distribution = most copyleft doesn't apply)
- Dependency audit methodology (`npm ls --all`, `pip-licenses`)
- IP assignment for employee/contractor code

### 6. Risk Assessment
- Severity scale: madal (low), keskmine (medium), kõrge (high)
- Risk categories: regulatory, contractual, operational, reputational
- Mitigation strategies per category
- Estonian-specific: AKI enforcement history, EMTA audit patterns

## Datalake API Quick Reference

All calls require `X-API-Key` header. API base: `http://est-saas-datalake:4100/api/v1/`

**Legal research:**
- `POST /rag/query` — body: `{"question": "..."}` → AI answer with citations
- `GET /laws/search?q=...&status=valid` → matching legal acts
- `GET /laws/{act_id}/citation?paragraph=N` → specific law text
- `POST /compliance/checklist` — body: `{"question": "..."}` → checklist

**Change monitoring:**
- `GET /changes/feed?domain=...&limit=N` → recent law changes
- Domains: Labor, Tax, Commercial, Environment, Real Estate, Public Administration, Criminal, Social

**Company intelligence:**
- `GET /companies/search?q=...` → company list
- `GET /companies/{code}` → full profile
- `GET /companies/{code}/board` → governance
- `GET /companies/{code}/tax` → tax status
- `GET /companies/{code}/financials` → financials

**Court decisions:**
- `GET /court/search?q=...` → case list
- `GET /court/ecli/{ecli}` → specific decision

## Analysis Workflow

```
1. Read project context → understand the SaaS product
2. Query datalake RAG → get Estonian legal requirements with citations
3. Search specific acts → find applicable laws
4. Generate compliance checklist → structured requirements
5. Check law changes → recent regulatory updates
6. Research competitors → legal structure and compliance approach
7. Search court decisions → relevant precedents
8. Web search → international frameworks (EU, GDPR guidance)
9. Audit codebase → open-source license compliance
10. Write analysis → .startup/docs/õiguslik-*.md
```

## Reference Documents

- `references/gdpr-compliance.md` — GDPR framework for SaaS
- `references/estonian-legal.md` — Estonian business law specifics
- `references/saas-contracts.md` — SaaS contract law essentials
- `references/software-licensing.md` — Open-source license compliance
- `references/risk-assessment.md` — Risk assessment framework and severity matrix
```

**Step 2: Verify**

Run: `head -3 plugins/saas-startup-team/skills/lawyer/SKILL.md`
Expected: `---` followed by `name: lawyer`

**Step 3: Commit**

```bash
git add plugins/saas-startup-team/skills/lawyer/SKILL.md
git commit -m "feat(saas-startup-team): add lawyer skill definition"
```

---

### Task 3: Create Skill Reference — GDPR Compliance

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/references/gdpr-compliance.md`

**Context:** Follow the depth and format pattern from `skills/business-founder/references/estonian-business.md`. Reference docs are factual knowledge — no skill triggers or frontmatter needed.

**Step 1: Create reference file**

Create `plugins/saas-startup-team/skills/lawyer/references/gdpr-compliance.md` with this content:

```markdown
# GDPR Compliance Framework for SaaS

## Lawful Bases for Processing (Article 6)

| Basis | When to Use | SaaS Example |
|-------|-------------|--------------|
| Consent | User actively opts in | Marketing emails, analytics cookies |
| Contract | Necessary for service delivery | Account data, payment processing |
| Legitimate interest | Business need balanced with user rights | Fraud prevention, service improvement |
| Legal obligation | Required by law | Tax records, AML compliance |

**Key rule:** Choose the narrowest lawful basis that applies. Do not rely on consent when contract performance is the actual basis.

## Data Subject Rights (Articles 15-22)

| Right | Obligation | Timeline |
|-------|-----------|----------|
| Access (Art. 15) | Provide copy of all personal data | 1 month |
| Rectification (Art. 16) | Correct inaccurate data | Without undue delay |
| Erasure (Art. 17) | Delete data ("right to be forgotten") | Without undue delay |
| Portability (Art. 20) | Export data in machine-readable format | 1 month |
| Restriction (Art. 18) | Stop processing but keep data | Without undue delay |
| Object (Art. 21) | Stop processing for legitimate interest | Without undue delay |

**SaaS implementation:** Build data export (JSON/CSV) and account deletion features from day one. Anonymization is acceptable where full deletion would break analytics.

## Data Processing Agreement (Article 28)

Required when a SaaS processes personal data on behalf of a client (controller-processor relationship).

**Mandatory DPA contents:**
1. Subject matter and duration of processing
2. Nature and purpose of processing
3. Types of personal data processed
4. Categories of data subjects
5. Obligations and rights of the controller
6. Sub-processor approval mechanism
7. Data breach notification procedure
8. Audit rights for the controller
9. Data deletion/return at contract end
10. Technical and organizational security measures

**Enterprise expectation:** B2B SaaS customers will demand a DPA before signing. Have a template ready.

## Cross-Border Data Transfers

### Adequacy Decisions
- EU/EEA → countries with adequacy decision: no additional safeguards needed
- Adequate countries include: UK, Japan, South Korea, Canada (commercial), Israel, Switzerland, New Zealand

### Standard Contractual Clauses (SCCs)
- Required for transfers to non-adequate countries (including US post-Schrems II)
- Use the June 2021 EU SCCs (modular approach)
- Must include a Transfer Impact Assessment (TIA)

### US-Specific: EU-US Data Privacy Framework
- Self-certification by US companies to Department of Commerce
- Check: https://www.dataprivacyframework.gov/list
- If the US sub-processor is not certified, SCCs still required

## Data Breach Notification (Articles 33-34)

| Action | Timeline | To Whom |
|--------|----------|---------|
| Notify supervisory authority | 72 hours | AKI (Estonia) or lead authority |
| Notify data subjects | Without undue delay | Affected individuals (if high risk) |
| Document the breach | Immediately | Internal records |

**SaaS obligation as processor:** Notify the controller "without undue delay" (no specific hour limit, but same-day is expected). The controller then decides on regulatory notification.

## Privacy Policy Requirements

A SaaS privacy policy must disclose:
1. Identity and contact details of the controller
2. DPO contact (if appointed)
3. Purpose and lawful basis for each processing activity
4. Categories of personal data collected
5. Recipients and sub-processors (named list)
6. Cross-border transfer mechanisms
7. Retention periods per data category
8. Data subject rights and how to exercise them
9. Right to lodge a complaint with supervisory authority
10. Whether providing data is a statutory/contractual requirement
11. Automated decision-making and profiling (if any)

## Cookie Consent (ePrivacy Directive)

| Cookie Type | Consent Required? |
|-------------|-------------------|
| Strictly necessary | No (exempt) |
| Functional/preference | Yes |
| Analytics | Yes (unless anonymized) |
| Marketing/tracking | Yes (always) |

**Implementation:** Cookie banner with granular opt-in per category. Pre-checked boxes are NOT valid consent under GDPR.

## DPIA Requirements (Article 35)

A Data Protection Impact Assessment is required when processing is likely to result in "high risk" to individuals:
- Systematic monitoring of publicly accessible areas
- Large-scale processing of special categories (health, biometric, etc.)
- Automated decision-making with legal effects
- Innovative technology applied to personal data
- Processing that prevents data subjects from exercising rights

## Estonian Specifics (AKI)

- **Supervisory authority:** Andmekaitse Inspektsioon (AKI), https://www.aki.ee/
- **DPO requirement:** Mandatory for public authorities and large-scale processing
- **Language:** Privacy policy must be in Estonian if targeting Estonian consumers
- **Fines:** Up to 20M EUR or 4% of global annual turnover (GDPR maximum)
- **AKI guidance:** Published in Estonian at https://www.aki.ee/et/juhised
```

**Step 2: Commit**

```bash
git add plugins/saas-startup-team/skills/lawyer/references/gdpr-compliance.md
git commit -m "feat(saas-startup-team): add GDPR compliance reference for lawyer skill"
```

---

### Task 4: Create Skill Reference — Estonian Legal

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/references/estonian-legal.md`

**Step 1: Create reference file**

Create `plugins/saas-startup-team/skills/lawyer/references/estonian-legal.md`:

```markdown
# Estonian Legal Framework for SaaS

## Key Legislation

### Data Protection
- **Isikuandmete kaitse seadus (IKS)** — Personal Data Protection Act
  - Implements GDPR in Estonian national law
  - Defines AKI authority and enforcement powers
  - Special provisions for children's data (age of consent: 13 in Estonia)

### E-Commerce
- **Infoühiskonna teenuse seadus (InfoTS)** — Information Society Services Act
  - Implements E-Commerce Directive in Estonia
  - Requirements for SaaS: provider identification, pricing transparency, order confirmation
  - Service provider must display: name, registry code, address, email, VAT number

### Consumer Protection
- **Tarbijakaitseseadus (TKS)** — Consumer Protection Act
  - 14-day withdrawal right for distance contracts (EU requirement)
  - Clear pricing and automatic renewal disclosure
  - Unfair commercial practices prohibition
  - Complaint handling procedure mandatory

### Commercial Code
- **Äriseadustik (ÄS)** — Commercial Code
  - OÜ (Osaühing) formation and management
  - Board member duties and liability
  - Annual reporting requirements
  - Minimum share capital: 0.01 EUR (since 2023)

### Accounting
- **Raamatupidamise seadus (RPS)** — Accounting Act
  - Bookkeeping in EUR
  - Annual report filing to Äriregister
  - Digital record retention: 7 years

## OÜ Legal Obligations

### Board Member Duties
- Duty of care and loyalty
- Personal liability for damages caused by breach of duty
- Must act in the company's best interests
- Cannot compete with the company without shareholder approval
- Annual report submission deadline: 6 months after financial year end

### Tax Obligations (EMTA)
- **Corporate tax:** 0% on retained earnings, 20% on distributions (14% regular)
- **VAT:** 22% standard rate, registration threshold 40,000 EUR/year
- **Employment:** Social tax 33%, income tax 20%, unemployment insurance 0.8%+0.8%
- **Monthly declarations:** TSD (employment taxes), KMD (VAT) by 10th of following month

### e-Residency Specifics
- Digital ID for company management (not physical residency)
- Can sign documents, file taxes, manage banking remotely
- Cannot use for personal tax residency in Estonia
- Company must still comply with all Estonian obligations
- Recommended: hire an Estonian service provider for accounting and registered address

## Regulatory Bodies

| Body | Abbreviation | Jurisdiction |
|------|-------------|-------------|
| Andmekaitse Inspektsioon | AKI | Data protection, GDPR enforcement |
| Tarbijakaitseamet | TKA | Consumer protection |
| Maksu- ja Tolliamet | EMTA | Tax administration |
| Äriregistri osakond | RIK | Company registration |
| Finantsinspektsioon | FI | Financial services regulation |

## Common Compliance Gaps for SaaS Startups

1. **Missing InfoTS disclosures** — SaaS landing page must display provider identity, registry code, VAT number
2. **No withdrawal right disclosure** — Consumer SaaS must inform about 14-day right
3. **Automatic renewal traps** — Must clearly disclose subscription renewal terms
4. **Missing AKI registration** — If processing special categories, may need to register
5. **VAT miscalculation** — EU digital services: VAT at customer's country rate via OSS scheme
6. **No Estonian-language policies** — If targeting Estonian market, policies must be in Estonian

## Useful Legal Resources

- Riigi Teataja (State Gazette): https://www.riigiteataja.ee/
- AKI (Data Protection): https://www.aki.ee/
- EMTA (Tax Board): https://www.emta.ee/
- Äriregister (Business Register): https://ariregister.rik.ee/
- Tarbijakaitseamet (Consumer Protection): https://www.tarbijakaitseamet.ee/
```

**Step 2: Commit**

```bash
git add plugins/saas-startup-team/skills/lawyer/references/estonian-legal.md
git commit -m "feat(saas-startup-team): add Estonian legal reference for lawyer skill"
```

---

### Task 5: Create Skill Reference — SaaS Contracts

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/references/saas-contracts.md`

**Step 1: Create reference file**

Create `plugins/saas-startup-team/skills/lawyer/references/saas-contracts.md`:

```markdown
# SaaS Contract Law Essentials

## Terms of Service — Essential Clauses

### 1. Definitions
- "Service" — what the SaaS product does
- "User" / "Customer" — who uses it
- "Content" / "Data" — what the user puts in
- "Subscription" — the access agreement

### 2. License Grant
- Limited, non-exclusive, non-transferable right to access the service
- Explicitly NOT a sale — SaaS is a service, not a product
- Scope: personal/business use as specified in the plan

### 3. Acceptable Use Policy
- Prohibited activities: illegal use, abuse, data mining, reverse engineering
- Resource limits: API rate limits, storage caps, bandwidth
- Consequences of violation: suspension, termination

### 4. Intellectual Property
- Company retains all IP in the service (code, design, trademarks)
- User retains all IP in their content/data
- Company gets a limited license to user content (only to provide the service)
- No license to use customer data for training AI models (unless explicit consent)

### 5. Payment Terms
- Pricing: reference to pricing page (allows updates without ToS change)
- Billing cycle: monthly/annual
- Failed payment handling: grace period, suspension, termination
- Refund policy: specify conditions (or no refunds)
- Currency and taxes: VAT handling, who bears tax responsibility

### 6. Limitation of Liability
- **Cap:** Total liability limited to fees paid in the 12 months preceding the claim
- **Exclusions:** No liability for indirect, incidental, consequential damages
- **Exceptions:** Liability cannot be limited for fraud, gross negligence, or death/injury
- This is the single most important protective clause for a SaaS startup

### 7. Warranty Disclaimer
- Service provided "as is" and "as available"
- No guarantee of uptime (unless SLA exists)
- No guarantee of fitness for a particular purpose
- Separate SLA for enterprise customers (with defined uptime %)

### 8. Termination
- Customer can cancel at any time (effective end of billing period)
- Company can terminate for: breach of ToS, non-payment, illegal activity
- Data export: provide reasonable period (30 days) for data retrieval
- Data deletion: specify when data is deleted post-termination

### 9. Governing Law and Jurisdiction
- For Estonian company: Estonian law, Harju County Court
- For international: consider arbitration (more neutral)
- EU consumer exception: consumer can sue in their home jurisdiction

### 10. Changes to Terms
- Right to modify ToS with notice (30 days recommended)
- Material changes require explicit acceptance
- Continued use after notice = acceptance (for non-material changes)

## Privacy Policy Requirements

See `gdpr-compliance.md` for detailed privacy policy contents.

**Key SaaS-specific additions:**
- List all sub-processors by name (AWS, Stripe, etc.)
- Specify data retention per category (not just "as long as necessary")
- Include data processing locations (EU, US, etc.)
- Cookie policy with granular consent

## Master Service Agreement (MSA) — For Enterprise

When selling to larger businesses, the ToS is replaced or supplemented by an MSA:

| Component | Purpose |
|-----------|---------|
| MSA | Master terms (liability, IP, termination) |
| Order Form | Specific subscription (seats, plan, price) |
| SLA | Uptime guarantees, support response times |
| DPA | Data processing terms (GDPR Article 28) |
| Security Addendum | Technical security measures |

**Enterprise procurement will request all five.** Have templates ready.

## Service Level Agreement (SLA)

| Metric | Typical Target |
|--------|---------------|
| Uptime | 99.9% (8.76h downtime/year) |
| Response time (P1 - critical) | 1 hour |
| Response time (P2 - major) | 4 hours |
| Response time (P3 - minor) | 1 business day |
| Credits for breach | 10-25% of monthly fee per SLA violation |

## Cookie Consent Implementation

| Component | Requirement |
|-----------|------------|
| Banner | Must appear before non-essential cookies fire |
| Granular consent | Per-category opt-in (analytics, marketing, functional) |
| Pre-checked boxes | NOT valid under GDPR |
| "Accept all" | Allowed but must be equal prominence with "Reject all" |
| Consent storage | Record and store consent proof |
| Easy withdrawal | As easy to withdraw as to give consent |

## Common SaaS Legal Mistakes

1. **ToS copied from another company** — may not match actual practices
2. **No limitation of liability** — unlimited exposure to lawsuits
3. **Privacy policy lists wrong sub-processors** — GDPR violation
4. **No DPA ready for enterprise clients** — deals stall or die
5. **Missing cookie consent** — easy target for GDPR complaints
6. **ToS not updated after feature changes** — terms don't match reality
7. **No data export on cancellation** — customer lock-in concerns, potential legal issue
```

**Step 2: Commit**

```bash
git add plugins/saas-startup-team/skills/lawyer/references/saas-contracts.md
git commit -m "feat(saas-startup-team): add SaaS contracts reference for lawyer skill"
```

---

### Task 6: Create Skill Reference — Software Licensing

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/references/software-licensing.md`

**Step 1: Create reference file**

Create `plugins/saas-startup-team/skills/lawyer/references/software-licensing.md`:

```markdown
# Software Licensing & IP Compliance for SaaS

## License Categories

### Permissive Licenses (Low Risk for SaaS)
| License | Requirements | SaaS Risk |
|---------|-------------|-----------|
| MIT | Include license text | Madal |
| Apache 2.0 | Include license + NOTICE, patent grant | Madal |
| BSD 2-Clause | Include license text | Madal |
| BSD 3-Clause | Include license text, no endorsement | Madal |
| ISC | Include license text | Madal |

### Copyleft Licenses (Context-Dependent for SaaS)
| License | Requirements | SaaS Risk |
|---------|-------------|-----------|
| GPL v2 | Derivative works must be GPL | Madal* |
| GPL v3 | Derivative works must be GPL, anti-tivoization | Madal* |
| LGPL | Dynamic linking allowed, static linking requires LGPL | Madal |
| MPL 2.0 | Modified files must be MPL, can combine with proprietary | Madal |
| AGPL v3 | Network use triggers copyleft — source must be provided | Kõrge |

*GPL is low risk for SaaS ONLY because SaaS is a service, not a distribution. You are not distributing binaries to users. However, AGPL explicitly closes this "SaaS loophole."

### The AGPL Exception (High Risk)

**AGPL v3** (Affero General Public License) is the only common copyleft license that is dangerous for SaaS:
- Triggers copyleft when software is accessed over a network
- If ANY AGPL code is in your SaaS, you must provide the entire source code to users
- This means your proprietary SaaS code must be released under AGPL
- **Common AGPL projects:** MongoDB (pre-SSPL), Grafana, Mastodon, Nextcloud
- **Action:** If found in dependency tree, REMOVE or REPLACE immediately

## SaaS Distribution Exception

Traditional copyleft (GPL/LGPL) triggers when you **distribute** software. SaaS is a **service** — users access it via browser/API, they don't receive a copy of the code. Therefore:

- GPL dependencies in a SaaS backend: **generally safe** (no distribution)
- GPL dependencies in a desktop/mobile app you ship: **copyleft applies**
- AGPL dependencies anywhere: **copyleft applies** (network access = distribution)

**Caution:** If your SaaS also ships a desktop client, mobile app, or on-premises version, GPL/LGPL analysis changes completely.

## Dependency Audit Methodology

### Node.js / npm
```bash
# List all dependencies with licenses
npx license-checker --summary

# Check for problematic licenses
npx license-checker --failOn "AGPL-3.0;GPL-3.0;GPL-2.0" --excludePrivatePackages

# Detailed output
npx license-checker --json --out licenses.json
```

### Python / pip
```bash
# Install audit tool
pip install pip-licenses

# List all licenses
pip-licenses --format=table

# Check for copyleft
pip-licenses --fail-on="GNU Affero General Public License v3 (AGPLv3);GNU General Public License v3 (GPLv3)"

# Export
pip-licenses --format=json --output-file=licenses.json
```

### Go
```bash
# Install audit tool
go install github.com/google/go-licenses@latest

# Check licenses
go-licenses check ./...

# Report
go-licenses report ./... > licenses.csv
```

## IP Ownership

### Employee Code
- In Estonia, employer owns code created during employment (unless contract says otherwise)
- Employment contract should explicitly assign IP
- Include: inventions, discoveries, designs, code, documentation

### Contractor Code
- In Estonia, contractor retains IP unless explicitly assigned
- **CRITICAL:** Service agreement MUST include IP assignment clause
- Without it, the contractor owns the code they write for you

### Open-Source Contributions
- If employees contribute to open-source projects, those contributions follow the project's license
- Consider a Corporate Contributor License Agreement (CLA) policy
- Employee's personal open-source work on personal time: generally theirs

## License Compliance Checklist

1. **Inventory all dependencies** — direct and transitive
2. **Identify AGPL dependencies** — remove or replace immediately
3. **Check GPL dependencies** — safe for SaaS backend only (not for distributed apps)
4. **Verify MIT/Apache/BSD compliance** — include license texts in attribution file
5. **Check for license conflicts** — some licenses are incompatible (e.g., GPL + Apache 2.0 before version 3)
6. **Document in NOTICE/LICENSES file** — attribution for all open-source dependencies
7. **Set up CI check** — automate license scanning in build pipeline
```

**Step 2: Commit**

```bash
git add plugins/saas-startup-team/skills/lawyer/references/software-licensing.md
git commit -m "feat(saas-startup-team): add software licensing reference for lawyer skill"
```

---

### Task 7: Create Skill Reference — Risk Assessment

**Files:**
- Create: `plugins/saas-startup-team/skills/lawyer/references/risk-assessment.md`

**Step 1: Create reference file**

Create `plugins/saas-startup-team/skills/lawyer/references/risk-assessment.md`:

```markdown
# Risk Assessment Framework for SaaS

## Risk Severity Matrix

| Severity | Estonian | Impact | Likelihood | Action |
|----------|---------|--------|-----------|--------|
| Kõrge (High) | Kõrge risk | Regulatory fine, lawsuit, business closure | Probable | Fix before launch |
| Keskmine (Medium) | Keskmine risk | Compliance gap, customer complaints, audit finding | Possible | Fix before go-live |
| Madal (Low) | Madal risk | Best practice gap, minor inconvenience | Unlikely | Plan to address |

## Risk Categories

### 1. Regulatory Risk
Violation of laws that could result in enforcement action.

| Risk | Severity | Mitigation |
|------|----------|------------|
| No privacy policy | Kõrge | Draft and publish privacy policy |
| No cookie consent | Kõrge | Implement cookie consent banner |
| Missing DPA for enterprise clients | Keskmine | Prepare DPA template |
| No InfoTS provider identification | Keskmine | Add company details to website |
| No AKI registration (if required) | Keskmine | Register with AKI |
| Privacy policy not in Estonian | Madal | Translate for Estonian market |

### 2. Contractual Risk
Exposure from service agreements with customers.

| Risk | Severity | Mitigation |
|------|----------|------------|
| No limitation of liability | Kõrge | Add liability cap (12-month fees) |
| No ToS at all | Kõrge | Draft and publish ToS |
| Missing warranty disclaimer | Keskmine | Add "as is" disclaimer |
| No data export on cancellation | Keskmine | Build export feature, document in ToS |
| No termination clause | Madal | Add mutual termination rights |

### 3. Operational Risk
Service availability and data handling failures.

| Risk | Severity | Mitigation |
|------|----------|------------|
| No backup/disaster recovery | Kõrge | Implement automated backups |
| No breach notification procedure | Kõrge | Document and test response plan |
| No uptime monitoring | Keskmine | Set up monitoring + alerting |
| No incident response plan | Keskmine | Document escalation procedure |
| No logging/audit trail | Madal | Implement access logging |

### 4. Reputational Risk
Damage to brand and customer trust.

| Risk | Severity | Mitigation |
|------|----------|------------|
| Data breach exposure | Kõrge | Encrypt at rest and in transit |
| AGPL violation discovered | Keskmine | Audit and remove AGPL deps |
| Customer data used for AI training | Keskmine | Explicit opt-in only, document in privacy policy |
| Poor accessibility | Madal | WCAG 2.1 Level AA compliance |

## Sector-Specific Risk Flags

### If the SaaS handles children's data
- **COPPA** (US): Parental consent required for under-13
- **Estonian IKS**: Consent age is 13 for digital services
- **Risk level:** Kõrge — specialized legal review required

### If the SaaS handles health data
- **HIPAA** (US): Business Associate Agreement required if serving US healthcare
- **GDPR Article 9**: Special category — explicit consent or legal obligation
- **Risk level:** Kõrge — DPO appointment and DPIA mandatory

### If the SaaS handles financial data / payments
- **PSD2** (EU): Payment services require Finantsinspektsioon (FI) license
- **AML Directive**: Customer due diligence if handling transactions
- **Risk level:** Kõrge — financial regulation license may be required

### If the SaaS uses AI / automated decision-making
- **EU AI Act**: Classification by risk level, transparency labels required
- **Article 50 deadline**: August 2, 2026 — AI-generated content must include transparency labels
- **GDPR Article 22**: Right not to be subject to purely automated decisions with legal effects
- **Risk level:** Keskmine to Kõrge depending on AI use case

## Risk Register Template

```markdown
## Riskiregister

| # | Risk | Kategooria | Tase | Mõju | Leevendus | Staatus |
|---|------|-----------|------|------|-----------|---------|
| 1 | [Description] | Regulatiivne/Lepinguline/Operatiivne/Maineline | Kõrge/Keskmine/Madal | [What happens if risk materializes] | [What to do about it] | Avatud/Leevendatud/Aktsepteeritud |
```

## Insurance Considerations

| Type | Coverage | When Needed |
|------|---------|-------------|
| Cyber liability | Data breaches, ransomware, notification costs | Always (for any SaaS handling personal data) |
| E&O (Professional liability) | Claims from service failures | When SaaS provides business-critical services |
| D&O (Directors & Officers) | Board member personal liability | When company has outside investors |
| General liability | Physical damage, injury claims | Standard business insurance |
```

**Step 2: Commit**

```bash
git add plugins/saas-startup-team/skills/lawyer/references/risk-assessment.md
git commit -m "feat(saas-startup-team): add risk assessment reference for lawyer skill"
```

---

### Task 8: Create /lawyer Command

**Files:**
- Create: `plugins/saas-startup-team/commands/lawyer.md`

**Context:** Follow the exact pattern from `commands/nudge.md` and `commands/startup.md`. The frontmatter requires: `name`, `description`, `user_invocable`. The body is the command execution instructions for the team lead.

**Step 1: Create command file**

Create `plugins/saas-startup-team/commands/lawyer.md`:

```markdown
---
name: lawyer
description: On-demand legal analysis — queries the est-saas-datalake API and project context to produce Estonian-language legal compliance and risk analysis. Usage: /lawyer <topic>
user_invocable: true
---

# /lawyer — On-Demand Legal Analysis

The human investor requests legal analysis on a specific topic. You spawn the Lawyer agent to research and write analysis.

**The Lawyer is a one-shot consultant, NOT a loop participant.** It spawns, does its analysis, writes to `.startup/docs/õiguslik-*.md`, and exits.

## Pre-Flight Checks (HARD FAIL — No Fallbacks)

Before spawning the Lawyer agent, ALL of the following must pass. If any check fails, stop with an error message and do NOT proceed.

### Check 1: Datalake API is reachable

```bash
curl --max-time 10 -s -o /dev/null -w "%{http_code}" http://est-saas-datalake:4100/api/v1/health/ready
```

**Must return:** `200`

**If not 200 or unreachable:**
> **Error:** est-saas-datalake API is not available at http://est-saas-datalake:4100/. The Lawyer requires the datalake for Estonian legal analysis. Fix the datalake service before running /lawyer.

### Check 2: Startup project exists

Verify that these files exist:
- `.startup/state.json`
- `.startup/brief.md`

**If missing:**
> **Error:** No startup project found. Run /startup first to initialize the project before running /lawyer.

### Check 3: API key is available

Check for `EST_DATALAKE_API_KEY` environment variable:

```bash
echo "${EST_DATALAKE_API_KEY:?not set}" > /dev/null 2>&1
```

**If not set:**
> **Error:** EST_DATALAKE_API_KEY environment variable is not set. The Lawyer needs an API key to query the datalake. Set it with: export EST_DATALAKE_API_KEY=your-key

## Execution

### Step 1: Load Lawyer Skill

```
Skill('saas-startup-team:lawyer')
```

### Step 2: Gather Project Context

Read the following files to build context for the Lawyer:
1. `.startup/brief.md` — what SaaS is being built
2. `.startup/state.json` — current project phase and iteration
3. Latest files in `.startup/docs/` — business founder's research
4. Latest handoff in `.startup/handoffs/` — current state of implementation

### Step 3: Spawn Lawyer Agent

Use `Task` tool to spawn the Lawyer as a one-shot agent:

Pass the following to the Lawyer agent:
- The investor's topic/question (from the command arguments)
- Project context summary (from Step 2)
- Reminder: write analysis to `.startup/docs/õiguslik-*.md` in Estonian
- Reminder: query datalake API first, web search second
- Reminder: include disclaimers and cite all sources

### Step 4: Report to Investor

After the Lawyer completes, summarize the findings for the investor in English:
- Which analysis documents were written
- Key risk findings (high/medium/low)
- Any human tasks identified (e.g., "hire a lawyer for DPA review")
- Where to find the full analysis: `.startup/docs/õiguslik-*.md`
```

**Step 2: Commit**

```bash
git add plugins/saas-startup-team/commands/lawyer.md
git commit -m "feat(saas-startup-team): add /lawyer command"
```

---

### Task 9: Update Team Patterns Reference

**Files:**
- Modify: `plugins/saas-startup-team/skills/startup-orchestration/references/team-patterns.md:3-13`

**Context:** Add the Lawyer to the architecture diagram as an on-demand consultant. Minimal change — only the diagram.

**Step 1: Update architecture diagram**

In `plugins/saas-startup-team/skills/startup-orchestration/references/team-patterns.md`, replace the Architecture section (lines 3-13):

**Old:**
```
## Architecture

```
Human (Silent Investor)
  ↓ /startup command
Team Lead (Main Session)
  ├── Business Founder (teammate, blue)
  ├── Tech Founder (teammate, green)
  ├── Shared TaskList
  └── Inter-agent messaging
```
```

**New:**
```
## Architecture

```
Human (Silent Investor)
  ↓ /startup command         ↓ /lawyer <topic>
Team Lead (Main Session)
  ├── Business Founder (teammate, blue)
  ├── Tech Founder (teammate, green)
  ├── Lawyer (on-demand consultant, purple)
  ├── Shared TaskList
  └── Inter-agent messaging
```
```

**Step 2: Commit**

```bash
git add plugins/saas-startup-team/skills/startup-orchestration/references/team-patterns.md
git commit -m "feat(saas-startup-team): add lawyer to team architecture diagram"
```

---

### Task 10: Bump Plugin Version

**Files:**
- Modify: `plugins/saas-startup-team/.claude-plugin/plugin.json:2`

**Context:** Per CLAUDE.md rule: "ALWAYS bump the plugin version in plugin.json before pushing." Design says 0.2.1 → 0.3.0 (minor version for new feature).

**Step 1: Update version**

In `plugins/saas-startup-team/.claude-plugin/plugin.json`, change:

**Old:** `"version": "0.2.1"`
**New:** `"version": "0.3.0"`

Also update the description to reflect the three-person team:

**Old:** `"description": "Two-person SaaS startup simulation — business founder and tech founder iterate via file-based handoffs using Agent Teams until the product is ready to go live"`
**New:** `"description": "SaaS startup simulation — business founder and tech founder iterate via file-based handoffs using Agent Teams, with an on-demand legal consultant (lawyer) for compliance analysis, until the product is ready to go live"`

Add "legal-compliance" and "datalake" to keywords:

**Old:** `"keywords": ["agent-teams", "multi-agent", "saas", "startup-simulation", "handoff-protocol", "iterative-development", "role-based-agents"]`
**New:** `"keywords": ["agent-teams", "multi-agent", "saas", "startup-simulation", "handoff-protocol", "iterative-development", "role-based-agents", "legal-compliance", "datalake"]`

**Step 2: Commit**

```bash
git add plugins/saas-startup-team/.claude-plugin/plugin.json
git commit -m "feat(saas-startup-team): bump version to 0.3.0, add lawyer to description"
```

---

### Task 11: Verify All Files Exist and Plugin Structure

**Files:** None (verification only)

**Step 1: Verify directory structure**

```bash
find plugins/saas-startup-team/agents/ plugins/saas-startup-team/commands/ plugins/saas-startup-team/skills/lawyer/ -type f | sort
```

Expected output:
```
plugins/saas-startup-team/agents/business-founder.md
plugins/saas-startup-team/agents/lawyer.md
plugins/saas-startup-team/agents/tech-founder.md
plugins/saas-startup-team/commands/lawyer.md
plugins/saas-startup-team/commands/nudge.md
plugins/saas-startup-team/commands/startup.md
plugins/saas-startup-team/commands/status.md
plugins/saas-startup-team/skills/lawyer/SKILL.md
plugins/saas-startup-team/skills/lawyer/references/estonian-legal.md
plugins/saas-startup-team/skills/lawyer/references/gdpr-compliance.md
plugins/saas-startup-team/skills/lawyer/references/risk-assessment.md
plugins/saas-startup-team/skills/lawyer/references/saas-contracts.md
plugins/saas-startup-team/skills/lawyer/references/software-licensing.md
```

**Step 2: Verify plugin.json version**

```bash
cat plugins/saas-startup-team/.claude-plugin/plugin.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Version: {d[\"version\"]}')"
```

Expected: `Version: 0.3.0`

**Step 3: Verify agent frontmatter**

```bash
head -10 plugins/saas-startup-team/agents/lawyer.md
```

Expected: frontmatter with `name: lawyer`, `model: opus`, `color: purple`, `tools: Bash, Read, Write, Glob, Grep, WebSearch, WebFetch, Task`

**Step 4: Verify team-patterns updated**

```bash
grep -c "Lawyer" plugins/saas-startup-team/skills/startup-orchestration/references/team-patterns.md
```

Expected: `1` (or more — at least one occurrence)

**Step 5: Run plugin validator**

Use the `plugin-dev:plugin-validator` agent to validate the plugin structure.
