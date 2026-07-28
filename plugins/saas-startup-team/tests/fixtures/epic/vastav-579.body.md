# Outcome

A non-technical Estonian business owner who paid **€49** for a *täisaruanne* can open the report on Monday morning and, without a lawyer or developer translating it:

1. know whether they have a **confirmed problem**, a **self-check**, a **lawyer question**, or **noise they can ignore**;
2. trust that the document does **not contradict itself**;
3. act on a **short** prioritised list — not 30 identical “vajab inimkontrolli” cards.

This epic is the **residual after #563 / #564**. Epic #563 defined the owner-ready product; #564 required a blind €49 customer read that would not refund. The **2026-07-28 aruannik.ee full report + gpt-5.6-sol owner read** failed that bar (fair price **~€15**, would strip the doc before showing a lawyer).

Evidence (read-only share):

| Path | What |
|------|------|
| `/mnt/vastav-share/aruannik.ee-full-report-2026-07-28/report/aruanne.md` | Customer markdown |
| `/mnt/vastav-share/aruannik.ee-full-report-2026-07-28/customer-read-gpt-5.6-sol.txt` | Blind owner persona (report-only) |
| `/mnt/vastav-share/aruannik.ee-full-report-2026-07-28/README.md` | Run metadata (codex CLI, 32 findings, registry VERIFIED) |

Related closed work (do not re-open wholesale): #329 (Report v3), #563 (owner-ready epic), #564 (validation), #532 (coverage “Puuduvad” for *Mida ei kontrollitud*), #496 (uniform hedging), #519 (duplicate do-first items), #557 (prior “not worth €49” read).

## Done when

- Re-run on **aruannik.ee** (and one unseen site) with the same owner-read prompt shape as #564.
- Blind non-technical reader: **would not refund**, fair price **≥ ~€40**, can name next actions without expert translation.
- No bare **«Skannimise piirangud: Puuduvad.»** while the same doc lists method limits.
- **One** WCAG automated-coverage figure everywhere.
- Verdict vocabulary and «Paranda esimesena» do not claim a confirmed legal breach for pure CAUTION / technical notes.
- No finding whose own evidence contradicts the claim (e.g. “100%” when the quote is “~60%”).
- First page is a decision matrix: *tee kohe / kontrolli ise / küsi juristilt / võid eirata* — not a wall of identical hedges.
- Empty sections (checklist, drafts) are **omitted**, not advertised as “Puudub”.
- Customer-facing emitters hide engine frontmatter (`token_usage_total`, model map, `post_reject_upgraded`).

## Delivery tracks

### Track A — honesty & non-contradiction (P0)

New issues filed under this epic + open blockers already filed:

- Dual WCAG coverage strings
- Residual «Skannimise piirangud: Puuduvad.»
- Verdict vs «Paranda esimesena» vocabulary
- Evidence-contradicting marketing FPs
- Existing: #533 (exec summary self-contradiction), #534 (lawyer-confirmation arithmetic), #536 (double-priced fixes), #522 (masthead counts), #443 (PASS = “could not check”)

### Track B — owner action surface (P0/P1)

- One-page decision matrix
- Kindlus hedge once (method), not every card
- Axe / occurrence dedupe for action counts
- Existing: #517 (axe ids / selectors on do-first page), #478 (address reconciliation)

### Track C — noise, empty promises, applicability (P1)

- Category-correct verify steps
- Omit empty advertised sections + strip MD frontmatter noise
- B2B/SaaS: do not lead consumer e-shop roadmap when consumers unconfirmed
- Existing: #494 (product jargon), #412 (absolute-claim proper-noun FP), #503 (Deque as occurrence URL), #484 (EAA gate), #418 (crawl/axe budget multiplication)

### Track D — revalidation (P0 process)

- Blind €49 owner-read gate on aruannik.ee + one unseen site (re-open of #564 acceptance, not a new product theory)

## Out of scope

- New law packs / sector radar expansion
- Separate lawyer or developer report products
- Implementation price calendars as the product (#536 remains a fix-not-feature)
- Requesty cost accounting unless it blocks generation
- Claude CLI re-auth (ops only; generation used codex successfully)

## Implementation

Each child is one `/improve` cycle. Prefer presentation + admission gates over more writer prose. **Fewer, non-contradictory claims** — this run already had 32 findings and still failed the owner.

## Child issues

*(filled after filing)*


## Child issues (filed)

### Track A — honesty
- [ ] #580 Single WCAG coverage figure
- [ ] #581 Residual «Skannimise piirangud: Puuduvad»
- [ ] #582 Verdict vs «Paranda esimesena» vocabulary
- [ ] #583 Evidence-contradicting marketing FPs

### Track B — action surface
- [ ] #584 First-page decision matrix
- [ ] #585 Kindlus hedge once
- [ ] #587 Axe occurrence dedupe

### Track C — noise & applicability
- [ ] #586 Category-correct verify steps
- [ ] #588 Omit empty sections + strip frontmatter
- [ ] #589 B2B/SaaS roadmap applicability

### Track D — proof
- [ ] #590 Revalidation + blind €49 owner read

### Existing open issues in scope (linked, not duplicated)
#534, #533, #536, #517, #443, #478, #494, #412, #503, #522, #418, #484
