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
