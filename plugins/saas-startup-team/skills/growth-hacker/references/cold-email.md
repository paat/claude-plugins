# Cold Email Setup & Execution

Cold email is the #1 channel cited by B2B SaaS founders for reaching $10K MRR.

## Setup (Human Tasks)

1. **Buy a separate domain** — never use primary domain for cold email
   - Example: product is `acme.com` → buy `tryacme.com` or `acme-app.com`
   - Cost: ~$10
2. **Set up 3-5 email accounts** on the cold domain (Google Workspace or similar)
3. **Configure warm-up service** (Instantly, Smartlead, Woodpecker) — 2-3 weeks warm-up before sending

## Execution (Growth Agent)

- **Volume**: 50-100 emails per day per domain
- **Templates**: 5 personalized templates, short (under 150 words), single CTA
- **Rotation**: Switch templates every 30-40 sends
- **Personalization**: First line MUST reference something specific about the prospect or their company
- **Sequence**: 3 emails over 2 weeks (initial → follow-up day 3 → final follow-up day 10)

## Target Metrics

| Metric | Target |
|--------|--------|
| Deliverability | > 70% inbox placement |
| Reply rate | 3-5% (good), 8-15% (excellent) |
| Reply-to-meeting | 15-30% |
| First paying customer | Within 2-3 weeks of active sending |

## Legal Compliance

Before launching the first cold email campaign, request a legal review from the lawyer agent (`/lawyer cold email compliance`). Key requirements:
- CAN-SPAM: physical address, unsubscribe link, honest subject lines
- GDPR Article 6: legitimate interest basis for B2B cold outreach (document your reasoning)
- Estonian e-Commerce Act requirements for commercial communications

## Troubleshooting

- **Deliverability below 70%**: Pause sending, check domain reputation, reduce to 20/day for a week, warm up again
- **Reply rate below 1%**: Rewrite templates — probably too generic or too long
- **High unsubscribe rate**: Check ICP targeting — might be reaching wrong audience

## Tracking

All metrics tracked in `docs/growth/channels/cold-email.md`:
```
## Campaign Status
- **Domain**: tryacme.com
- **Warm-up started**: YYYY-MM-DD
- **Sending started**: YYYY-MM-DD
- **Volume**: N/day
- **Deliverability**: N%
- **Reply rate**: N%
- **Meetings booked**: N
- **Paying customers**: N
```
