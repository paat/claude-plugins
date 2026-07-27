---
name: goal-deliver
description: "Deliver issues, milestones, specs, or free-text goals through production gates. Usage: /goal-deliver [--full] <work>"
user_invocable: true
transitional: true
---

# /goal-deliver

Be token-frugal. Load the canonical deliver skill
`${CLAUDE_PLUGIN_ROOT}/skills/deliver/SKILL.md` once with
`SAAS_DELIVER_ENTRYPOINT=goal-deliver`, then follow it with `$ARGUMENTS`. The skill is
the sole delivery contract; do not restate its gates here.
