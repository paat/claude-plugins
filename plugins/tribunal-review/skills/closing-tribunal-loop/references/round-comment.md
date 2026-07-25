# Tribunal round PR comment template

Post one comment per `tribunal-loop` result after triage dispositions for that
round are decided. Use the stable HTML marker so rounds are greppable.

```markdown
<!-- tribunal-round:N -->
## Tribunal round N — <APPROVE|NEEDS_WORK|BLOCK>

- **PR:** #<number>
- **HEAD:** `<full sha>`
- **Decision:** …
- **Confidence:** …
- **Critical/high remaining:** <count>
- **Providers:** ok / failed / disabled summary (one line)

### Findings

| ID | Sev | Consensus | Disposition | Title |
|----|-----|-----------|-------------|-------|
| T-001 | high | CONSENSUS | fix-in-PR / follow-up #M / reject / open | … |

### Dispositions

Post this comment **before** applying code fixes for the round. Use:

- **Will-fix in this PR:** T-00x — planned commit message tag `tribunal T-00x`
- **Follow-up filed:** T-00y → #M
- **Rejected:** T-00z — <one-line verification reason>
- **Still open (blocking):** T-00… — next action

After fixes land, the **next** round’s HEAD and findings trail show the outcome.
Do not delay this comment until after the fix/push.

### YAGNI / medium-low (close round only)

- Dropped: … — <reason>
- Filed: … → #M

### Notes

- Step-back / checkpoint / ceiling notes when applicable
- Arbiter rationale (1–3 sentences)
```

## How to post

Write the body to a file, then post and verify (never inline multi-line
`--body "..."`):

```bash
ROUND_FILE="$(mktemp)"
# write markdown into $ROUND_FILE (Write tool — not shell-quoted prose)
gh pr comment "$PR_NUMBER" --body-file "$ROUND_FILE"
# Read back: confirm `<!-- tribunal-round:N -->` and HEAD sha are present.
# Unverified post = not done.
rm -f "$ROUND_FILE"
```

If `safe-text-post` is available:

```bash
bash "${SAFE_TEXT_POST_ROOT}/scripts/safe-post.sh" post \
  --via issue-comment --repo "$OWNER/$REPO" --number "$PR_NUMBER" --file "$ROUND_FILE"
```

Round 3 checkpoint and Round 5 ceiling notes go on the PR (same comment or a
short follow-up with the same `tribunal-round:N` marker).
