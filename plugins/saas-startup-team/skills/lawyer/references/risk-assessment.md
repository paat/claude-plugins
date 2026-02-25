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
