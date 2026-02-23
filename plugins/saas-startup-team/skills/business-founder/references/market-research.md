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
