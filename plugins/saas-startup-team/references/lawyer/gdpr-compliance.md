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
- EU/EEA to countries with adequacy decision: no additional safeguards needed
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
