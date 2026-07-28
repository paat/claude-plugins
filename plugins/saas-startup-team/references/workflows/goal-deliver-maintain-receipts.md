# Maintain embed receipts (retired)

Compatibility receipts were removed in #389. Terminal evidence via
`maintain-v3.sh release-facts` only.

Do not trust an earlier green check after head advances.
Never open a replacement PR for the same issue WIP.
Use `gh pr merge --match-head-commit` for exact-head merge.
