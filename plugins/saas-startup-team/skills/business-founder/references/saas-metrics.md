# SaaS Metrics Reference

## Primary Growth Metrics

### MRR (Monthly Recurring Revenue)
- Definition: Predictable monthly revenue from subscriptions
- Components: New MRR + Expansion MRR - Churned MRR - Contraction MRR
- Target growth: 10-20% month-over-month for early-stage SaaS

### ARR (Annual Recurring Revenue)
- Definition: MRR × 12
- Milestone benchmarks: $100K ARR (validation), $1M ARR (product-market fit), $10M ARR (scale)

### Net Revenue Retention (NRR)
- Definition: (Starting MRR + Expansion - Contraction - Churn) / Starting MRR
- Target: > 100% (means existing customers grow even without new sales)
- Best-in-class: 120-140%

## Unit Economics

### CAC (Customer Acquisition Cost)
- Definition: (Sales + Marketing spend) / New customers acquired
- Include: ads, content, sales team costs, tools
- Benchmark by segment:
  - Self-serve SMB: $50-$500
  - Mid-market: $5K-$50K
  - Enterprise: $50K-$500K

### LTV (Lifetime Value)
- Definition: Average Revenue Per Account / Monthly Churn Rate
- Or: ARPA × Gross Margin × (1 / Churn Rate)
- Must be calculated with gross margin, not just revenue

### LTV:CAC Ratio
- Target: > 3:1 (healthy business)
- < 1:1 = losing money on every customer
- 1:1 - 3:1 = not yet sustainable
- > 5:1 = potentially under-investing in growth

### CAC Payback Period
- Definition: CAC / (ARPA × Gross Margin)
- Target: < 12 months for SMB, < 18 months for mid-market
- Tells you how long until a customer becomes profitable

## Churn Metrics

### Customer Churn Rate
- Definition: Customers lost / Total customers at start of period
- Monthly targets by segment:
  - SMB: < 3-5%
  - Mid-market: < 1-2%
  - Enterprise: < 0.5-1%

### Revenue Churn Rate
- Definition: MRR lost / Total MRR at start of period
- Often different from customer churn (losing big vs small customers)
- Negative revenue churn = expansion > contraction + churn (the holy grail)

## Pricing Frameworks

### Value-Based Pricing Steps
1. Identify the value metric (what scales with customer value?)
2. Research willingness to pay (competitor pricing, customer interviews)
3. Set price at ~10% of the value delivered
4. Create 3-4 tiers with clear differentiation
5. Include a free tier or trial for acquisition

### Common Value Metrics
- Per user/seat (Slack, Notion)
- Per unit of work (Stripe per transaction, Twilio per message)
- Per resource (storage, API calls, contacts)
- Flat rate with limits (simple, predictable)

### Pricing Page Best Practices
- 3 tiers maximum (Good / Better / Best)
- Highlight the recommended tier
- Annual billing discount (typically 15-20%)
- Enterprise tier with "Contact us"
- Show the value metric clearly
