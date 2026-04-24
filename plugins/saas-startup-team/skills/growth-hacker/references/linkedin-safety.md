# LinkedIn Safety Protocol

## Context

Apollo.io and Seamless.ai were banned in March 2025 for mass scraping — thousands of profiles per hour. Real ban rate for moderate, human-like automation (40-60 requests/week) is 2-5%, and most "bans" are temporary 24-72 hour restrictions.

## Hard Limits

| Action | Daily Limit | Weekly Limit |
|--------|------------|-------------|
| Profile views | 40 | — |
| Connection requests | — | 50 |
| Messages to connections | 20 | — |
| Template rotation | — | Every 30-40 sends |

## Rules

- **Business hours only**: 8:00-18:00 local time, Monday-Friday
- **No bulk scraping**: Research prospects individually with natural timing gaps
- **Personalize first line**: Generic templates get flagged by LinkedIn's spam detection
- **Rotate templates**: Switch message templates every 30-40 sends to avoid pattern detection
- **Track everything**: Update counters in `docs/growth/channels/linkedin.md` after every action

## Cool-Down Protocol

If LinkedIn restricts the account:

1. **Pause all LinkedIn activity for 72 hours**
2. Resume at **50% volume** (20 views/day, 25 connections/week, 10 messages/day)
3. Maintain 50% volume for **7 days**
4. Return to full volume
5. Log the restriction in `docs/growth/channels/linkedin.md`

Meanwhile, shift effort to cold email and communities. A temporary restriction is a speed bump, not a crisis.

## Counter Tracking Format

In `docs/growth/channels/linkedin.md`:

```
## Activity Counters
- **Week of YYYY-MM-DD**: connections sent: N/50, messages sent today: N/20, profiles viewed today: N/40
- **Template rotation**: current template set since: YYYY-MM-DD, sends on current set: N/40
- **Restrictions**: [date — duration — resumed at]
```
