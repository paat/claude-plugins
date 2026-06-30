# Health Checks and Preflight

Use this playbook before browser testing and when debugging unreliable delegated calls.

## L1 HTTP Reachability

Use `curl` for a cheap availability check:

```bash
curl -s -o /dev/null -w "%{http_code}" <url>
```

Pass when status is 200-399.

## L2 Browser Render

Delegate a browser navigation and ask for visible text length, title, and obvious render errors. Pass when visible text is present and the app is not blank.

## L3 App Functional

When credentials are configured, run a minimal login or primary route check. Report warning if it fails and scope the rest of testing accordingly.

## Troubleshooting

If chrome-devtools MCP reports a stale browser profile lock, clear only the documented profile directory for that tool and retry. Do not switch to curl-only verification.
