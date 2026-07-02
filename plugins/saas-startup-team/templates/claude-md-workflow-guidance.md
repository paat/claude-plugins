## Workflow Guidance

### Use `/startup` (agent loop) when:
- Starting a new product or major pivot — needs market research, competition analysis, pricing
- Building 3+ features that need business justification and browser verification
- You want structured business-to-tech-to-review cycles with quality gates

### Use plain Claude Code when:
- Bug fixes, hotfixes, deployment issues
- SEO tweaks, content updates, copy changes
- Single feature where you already know the "why"
- Ops/infrastructure work (docker, nginx, CI)
- Quick research tasks (use `/lawyer` or `/ux-test` standalone)

### Use `/growth` (growth track) when:
- Product is live and ready for customers — need to acquire paying users
- Want to run outreach, content marketing, ad campaigns, community engagement
- Pre-launch audience building (`/growth --pre-launch`)

### Use `/improve` (one-shot fixes) when:
- Product is complete (solution signoff exists) but needs minor tweaks
- Bug fixes, styling changes, copy updates on a shipped product
- Changes that don't need market research or new feature design

### Either way:
- Save research findings to `docs/` (not ad-hoc locations)
- Check relevant `docs/` before making design decisions
- Update `docs/` when decisions change
- Update `.startup/workflows/` when routes, jobs, states, or handoff contracts change
