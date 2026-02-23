# Market Research Methodology

## Competition Analysis Framework

### Step 1: Identify Competitors
- **Direct competitors**: Same problem, same approach
- **Indirect competitors**: Same problem, different approach
- **Potential competitors**: Adjacent products that could add this feature

Search patterns:
```
"[category] tools" OR "[category] software"
"[problem] solution" OR "[problem] app"
"best [category] for [audience]"
"[competitor name] alternative" OR "[competitor name] vs"
site:g2.com "[category]"
site:capterra.com "[category]"
```

### Step 2: Analyze Each Competitor
For each competitor, document:

| Dimension | What to Look For |
|-----------|------------------|
| Positioning | Who do they say they're for? |
| Features | What can it do? What's missing? |
| Pricing | How much? What model? |
| UX | How does it feel to use? (browser check) |
| Reviews | What do users love/hate? (G2, Reddit) |
| Size | Employee count, funding, market share |

### Step 3: Find Gaps
- Features competitors don't offer
- Customer segments competitors ignore
- Pricing models that exclude certain users
- UX problems competitors haven't solved
- Integrations competitors lack

## International Benchmarking

### Why Research International Solutions

- **Market maturity**: Some countries are years ahead in specific SaaS categories — learn from their evolution
- **Cultural UX patterns**: Japanese SaaS favors information density; Scandinavian SaaS favors minimalism — both inform design
- **Pricing approaches**: Emerging markets use different pricing models (usage-based, mobile-first) that may reveal opportunities
- **Feature discovery**: International competitors often solve the same problem with different features you haven't considered

### Search Patterns

```
"[category] SaaS [country]"
"[category] software [country]"
"best [category] tools in [country]"
site:producthunt.com "[category]"
"[category] startup [country]"
"[localized category term] [country-specific platform]"
```

### Key Markets

| Market | Rationale |
|--------|-----------|
| US | Largest SaaS market, sets global trends |
| UK | Mature market, English-language, strong fintech/healthtech |
| Germany | Enterprise-focused, strong data privacy culture |
| Japan | Unique UX patterns, mobile-first, high information density |
| India | Price-sensitive, mobile-first, massive scale solutions |
| Brazil | Largest Latin American market, mobile payments innovation |
| Australia | English-language, often early adopter of US/UK trends |

### Extraction Template

For each international solution, document:

| Dimension | What to Extract |
|-----------|-----------------|
| Unique features | Features not found in domestic competitors |
| UX patterns | Navigation, information density, onboarding flow |
| Pricing model | Tiers, currency, localization of pricing |
| Localization | Multi-language, regional compliance, local integrations |
| Mobile approach | Mobile-first vs desktop-first, app vs responsive |
| Integrations | Region-specific services (payment, communication, government) |
| Market fit | Why this approach works in that country |

### Documentation Format

Save findings to `.startup/docs/rahvusvaheline-analüüs.md` using Estonian field names:

```markdown
# Rahvusvaheline analüüs

## [Riik: Country Name]

### Lahendus: [Solution Name]
- **Veebileht**: [URL]
- **Unikaalsed funktsioonid**: [Features not found locally]
- **UX mustrid**: [Notable UX patterns]
- **Hinnamudel**: [Pricing approach]
- **Õppetunnid**: [Key takeaways for our product]

## Universaalsed mustrid
[Patterns appearing in 3+ countries — likely essential features]

## Riigipõhised kohandused
[Country-specific adaptations — may not apply globally]
```

## Customer Discovery

### Reddit Research Methodology
```
1. Search: "site:reddit.com [problem] frustrating"
2. Search: "site:reddit.com [competitor] hate OR terrible OR switching"
3. Search: "site:reddit.com [category] recommendation"
4. Read threads — extract customer language
5. Note: pain points, desired features, willingness to pay
```

### Customer Language Mining
When reading customer feedback, extract:
- **Exact phrases** they use to describe the problem
- **Emotional words** (frustrated, hate, love, wish)
- **Feature requests** stated as wishes ("I wish it could...")
- **Switching triggers** (what made them leave a competitor?)
- **Price sensitivity** (comments about cost, value, alternatives)

Save these in the customer language of `.startup/docs/kliendi-tagasiside.md` — this informs copywriting, positioning, and feature prioritization.

## TAM/SAM/SOM Estimation

### TAM (Total Addressable Market)
- Total revenue if you captured 100% of the market
- Method: # of potential customers × annual contract value
- Sources: industry reports, government statistics, market research

### SAM (Serviceable Addressable Market)
- Portion of TAM you can reach with your product/distribution
- Filter by: geography, company size, industry vertical, language

### SOM (Serviceable Obtainable Market)
- Realistic market share in 1-3 years
- Typically 1-5% of SAM for early-stage startups
- Based on: competition intensity, differentiation, distribution

## Validation Signals

### Strong Signals (Build This)
- Multiple Reddit threads complaining about the problem
- Competitors exist but have significant gaps
- Customers actively searching for alternatives
- Willingness to pay expressed in public forums

### Weak Signals (Investigate More)
- Only one or two mentions of the problem
- Competitors seem to cover the space well
- Problem exists but unclear if people would pay
- Market size is small or shrinking

### Red Flags (Reconsider)
- No one talks about this problem online
- Strong incumbents with no clear gaps
- Problem is a "nice to have," not a "must have"
- Heavily regulated with high compliance costs
