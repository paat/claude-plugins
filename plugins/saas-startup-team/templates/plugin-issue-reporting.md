# Plugin Issue Reporting

If you hit a problem with the **plugin itself** (not the product or work you're
producing), file a GitHub issue on the pinned plugin repo — `$SAAS_PLUGIN_REPO`
(`OWNER/REPO`, set in `.claude/saas-startup-team.local.md`; if unset, ask the
investor rather than guessing a repo):

```bash
gh issue create --repo "${SAAS_PLUGIN_REPO}" \
  --title "saas-startup-team: <short title>" \
  --body "<what went wrong, reproduction steps, expected vs actual>"
```

**Plugin issues**: hook failures, template problems, agent instruction gaps, MCP issues,
state.json schema bugs, command flow bugs.
**NOT plugin issues**: product bugs, UX feedback, feature requests, human tasks — those go
in `.startup/` files.
