---
name: ads-iterate
description: "Run the core iteration loop — read the current iteration state, verify it, diagnose gaps, and produce the next hypothesis + spec. Delegates to the ads-strategist agent. Works for both pre-launch and post-launch loops. Usage: /ads-iterate [campaign-name]"
user_invocable: true
allowed-tools: Task, Read, Glob, Bash
argument-hint: [campaign-name]
---

# /ads-iterate — Run one iteration of a campaign

Delegates the iteration loop to the **ads-strategist** agent. The agent reads state, verifies, diagnoses, and proposes the next hypothesis; the user confirms or redirects before `spec.md` is written.

## Step 0: Determine the campaign

Use the passed campaign argument; otherwise list `docs/ads/*/brief.md` (auto-select if only one, else ask). If no brief exists, **STOP** and direct the user to run `/ads-brief` first.

## Step 1: Detect the loop (pre-launch or post-launch)

```bash
[ -f "docs/ads/<campaign>/launched_at" ] && echo post-launch || echo pre-launch
```

- **Marker absent** → pre-launch loop | **Marker present** → post-launch loop (ISO timestamp written manually on launch or by `/ads-metrics` on first post-launch read).

## Step 2: Dispatch the ads-strategist

Spawn `ads-strategist` via Task tool (`subagent_type: "general-purpose"`):

### For pre-launch iteration:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/ads-strategist.md` for your identity, tools, and hard rules.
>
> **Task: Run one pre-launch iteration on campaign `<campaign>`.**
>
> Be token-frugal: read only what each step needs (targeted ranges, never re-read) and exit early if nothing changed. Load skills only when needed (a verify-only cycle loads only `browser-verification`):
> - `google-ads-strategist:buyer-intent-targeting` (v1 or keyword-change hypothesis)
> - `google-ads-strategist:iterative-campaign-design` (v1 or diagnosing gaps for `v_{n+1}`)
> - `google-ads-strategist:browser-verification` (Ad Preview / SERP capture)
> - `google-ads-strategist:hypothesis-journaling` (writing `v1` or `v_{n+1}` hypothesis)
> - `google-ads-strategist:competitor-intel` (building/refreshing differentiation matrix)
> - `google-ads-strategist:clickable-copy` (writing/revising RSA copy)
>
> Read in order: `docs/ads/<campaign>/brief.md`, `learnings.md`, `hypothesis-log.md`, and `current/spec.md` (if it exists).
>
> **If no current iteration exists**: follow `${CLAUDE_PLUGIN_ROOT}/references/v1-generation-playbook.md` (steps 1–10: seed keywords, intent classification, product-value gate, mandatory SERP evidence, competitor Transparency Center pull, `AG_branded_defensive`, UTM tagging, forecast sanity check, Day-1 negatives, `iterations/v1/hypothesis.md`) and **STOP after `hypothesis.md` for user approval — do NOT write `spec.md` in this call**.
>
> **If a current iteration exists**:
> 1. Read `current/spec.md` and `current/hypothesis.md`.
> 2. Run Ad Preview Tool for every keyword and compare against `verification/`.
> 3. Diagnose gaps per `iterative-campaign-design`.
> 4. If stop conditions are met → write `current/result.md` with `"READY TO LAUNCH"` and STOP.
> 5. Otherwise → write `iterations/v_{n+1}/hypothesis.md` with ONE variable-class change, then **STOP without writing `spec.md`** (checkpoint for user approval).
>
> Report: current iteration version, stop-condition status (yes/no/partial + details), proposed next hypothesis (or `"READY TO LAUNCH"`), and artifacts written.

### For post-launch iteration:

> Read `${CLAUDE_PLUGIN_ROOT}/agents/ads-strategist.md`.
>
> **Task: Run one post-launch iteration on campaign `<campaign>`.**
>
> Load skills as needed: `iterative-optimization`, `hypothesis-journaling`, `browser-verification`, `buyer-intent-targeting`, plus `clickable-copy` (copy hypothesis) or `competitor-intel` (competitive pressure).
>
> Check the wait gate first: compare `current/applied_at` against `docs/ads/<campaign>/wait_days` (default 7). If closed, **STOP** and report when it opens — do not write a hypothesis yet.
>
> If open:
> 1. Pull metrics via `browser-verification` Tool 5 (Google Ads UI) and compare to `brief.md` targets + prior `result.md`.
> 2. Run the `iterative-optimization` decision tree to identify the dominant symptom.
> 3. Write `iterations/v_{n+1}/hypothesis.md` with ONE variable-class change, then **STOP before writing `spec.md`**.
>
> Report: current metrics vs targets, dominant symptom, proposed next hypothesis, and next wait-gate status.

## Step 3: Present the agent's report & handle approval

Show the user the summary for `<campaign> v_{n+1}` and ask whether to **Approve** (write `spec.md` + verify), **Redirect**, or **Stop**.

On approval, dispatch the agent again:

> Write `iterations/v_{n+1}/spec.md` based on the approved `iterations/v_{n+1}/hypothesis.md` (for `v1`, also follow the post-approval checklist in `${CLAUDE_PLUGIN_ROOT}/references/v1-generation-playbook.md`: `## Dropped keywords` reconciliation and `flags-for-investor.md`). Then update the `current` symlink, run verification, and write `result.md`.

## Notes

- Design-only: iterations are NEVER auto-applied to a live account. After `result.md` says `"READY TO LAUNCH"`, the human or `growth-hacker` launches it.
- If Chrome, auth, or browser MCP fails, the agent MUST stop and report — never fabricate results.
- **Force-override for the wait gate**: per `iterative-optimization` ("The Wait Gate"), only in a genuine emergency (tracking breakage, policy violation, budget emergency, competitor crisis — never impatience), include `force-wait-override` with written justification in `hypothesis.md` so `check-wait-gate.sh` permits the spec write.
