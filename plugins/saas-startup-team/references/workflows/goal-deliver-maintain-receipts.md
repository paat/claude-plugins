# Goal-deliver maintain receipts (retired)

Primary-only claim/receipt orchestration was removed in #389.

Use:

- Isolation: `scripts/maintain-v3.sh isolate prepare --repo-root DIR --issue N`
- Delivery: `skills/deliver/SKILL.md` with `SAAS_DELIVER_ENTRYPOINT=goal-deliver`
- Terminal release facts: `scripts/maintain-v3.sh release-facts`
- Stranded legacy receipts: `scripts/legacy-drain.sh inventory|drain|verify`

Do not create `maintain:claimed` labels, claim comments, or compatibility receipts.
Do not trust an earlier green check without re-proving current-head gates.
Never open a replacement PR when a bound PR already owns the work.
gh pr merge --match-head-commit &lt;receipt-head&gt; remains the exact-head merge form for
release when GitHub is the merge surface.
