# google-ads-strategist

A senior-level Google Ads strategist agent that designs campaigns through an **iterative improvement process** and verifies every iteration in the real browser before a cent is spent.

## Three revenue rules (enforced, not suggested)

1. **Every final URL has UTM parameters.** Without attribution, iteration can't learn what drove revenue. Every spec carries `utm_source`, `utm_medium`, `utm_campaign`, `utm_content=<iteration>`, and `utm_term={keyword}`. `/ads-ready` refuses to pass a spec without them.
2. **Every campaign has a defensive branded ad group.** Competitors will bid on your brand if you don't — defensive own-brand capture is the first thing v1 auto-generates when `brand_name` exists in `brief.md`.
3. **Buyer intent, not content relevance.** PPC spend only follows commercial + transactional queries. Informational modifiers become Day-1 negatives, not Week-3 lessons. Every keyword is SERP-verified to confirm commercial signals before entering a spec.

## Core discipline

- One hypothesis per iteration, **single-variable changes only**, browser-verified at every step
- Every iteration includes a `forecast.md` (expected daily clicks + spend + conversions) as a sanity check before the hypothesis is written
- Every iteration includes a `negatives.md` (aggressive Day-1 informational negatives, language-specific)
- The plugin is **design-only** — it never launches campaigns autonomously

## What it does

- **Pre-launch loop**: rapid hypothesis → Ad Preview Tool verification → competitive SERP capture → diagnose → revise, until every target keyword triggers the ad at position ≤ 3 with differentiated copy
- **Post-launch loop**: metrics pull → symptom diagnosis → single-variable hypothesis → wait gate → measure → update learnings
- **Per-campaign memory**: every campaign lives in `docs/ads/<campaign>/` as versioned iterations with hypotheses, results, and an accumulating `learnings.md`
- **Cross-campaign learnings**: patterns that hold across ≥ 2 campaigns graduate to project-level auto-memory
- **Chrome-first**: uses the Anonymous Ad Preview Tool, real Google SERP, and Google Ads Transparency Center via the `claude-in-chrome` MCP server — no Google Ads API developer token required

## Requirements

- Claude Code with the `claude-in-chrome` MCP server installed and logged into the user's Chrome browser
- `jq` on PATH (hook scripts parse the tool input JSON via jq)
- GNU `grep` with PCRE support (`grep -P`) — used by `check-single-variable.sh`; default on Linux, not on macOS unless replaced with `ggrep`
- Bash 4+ / standard POSIX tools
- Optional: logged-in Google Ads account in Chrome, for authenticated Ad Preview & Diagnosis and for metrics pulls (post-launch loop only)

No Google Ads API access is required for pre-launch design + verification. The Anonymous Ad Preview Tool is public and works for any keyword / location / device.

## Components

### Agent
- `ads-strategist` — senior PPC strategist, design-only, iteration-first discipline

### Commands
- `/ads-brief [name]` — create a new campaign folder + brief.md (interactive intake)
- `/ads-iterate` — run one iteration of the active campaign (delegates to ads-strategist)
- `/ads-verify [keyword]` — quick one-shot Ad Preview Tool verification
- `/ads-serp <keyword>` — capture real Google SERP in incognito and classify buyer intent
- `/ads-spy <competitor>` — pull all currently-running ads from the Google Ads Transparency Center
- `/ads-diff <v_a> <v_b>` — show what changed between two iterations
- `/ads-hypothesize` — propose 3-5 ranked candidate hypotheses for the next iteration
- `/ads-ready` — audit the current iteration against the launch-readiness checklist
- `/ads-metrics` — pull live campaign metrics via Chrome (post-launch only)
- `/ads-distill` — roll the hypothesis log into learnings and propose graduation candidates

### Skills
- `buyer-intent-targeting` — **first filter** — every keyword classified by intent; informational dropped
- `iterative-campaign-design` — pre-launch iteration loop discipline
- `iterative-optimization` — post-launch iteration loop decision tree
- `hypothesis-journaling` — how to write falsifiable hypotheses and distill learnings
- `browser-verification` — Chrome playbook for Ad Preview Tool, SERP capture, Transparency Center, and Google Ads UI metrics
- `competitor-intel` — Transparency Center workflow + differentiation matrix
- `clickable-copy` — RSA formulas per intent class, Quality Score alignment, character-count discipline

### Hooks
- **PreToolUse / Chrome navigate** → `check-launch-block.sh` — blocks navigation to Google Ads campaign creation/edit/delete URLs (the strategist never launches)
- **PostToolUse / Write** → `check-hypothesis-present.sh` — blocks writing `iterations/vN/spec.md` without a sibling `hypothesis.md`
- **PostToolUse / Write** → `check-single-variable.sh` — validates that `hypothesis.md` declares exactly one variable class (or justified multivariate)
- **PostToolUse / Write** → `check-wait-gate.sh` — post-launch only, blocks iteration specs before ≥ 7 days since last apply (for statistical significance)

### Templates
Located in `${CLAUDE_PLUGIN_ROOT}/templates/`:
- `campaign-brief.md`
- `iteration-hypothesis.md`
- `iteration-spec.md`
- `iteration-result.md`
- `learnings.md`
- `hypothesis-log.md`

## Campaign folder structure

```
docs/ads/<campaign>/
├── brief.md                         # product, audience, budget, goals, brand, final_url_template, forecast baseline
├── launched_at                      # marker file — presence + ISO timestamp = campaign is live
├── wait_days                        # optional — override default 7-day post-launch wait gate
├── iterations/
│   ├── v1/
│   │   ├── hypothesis.md            # single-variable test + prediction
│   │   ├── spec.md                  # ad groups (incl. AG_branded_defensive), keywords, UTM-tagged final URLs
│   │   ├── forecast.md              # expected daily clicks + spend + conversions
│   │   ├── negatives.md             # Day-1 informational negatives, language-specific
│   │   ├── verification/
│   │   │   ├── preview-*.png        # Ad Preview Tool screenshots
│   │   │   ├── serp-*.png           # real SERP captures (intent verification)
│   │   │   ├── transparency-*.md    # competitor ad inventory
│   │   │   └── preview-log.md       # structured log of every verification run
│   │   ├── result.md                # did the hypothesis hold?
│   │   └── applied_at               # marker file — presence + ISO timestamp = iteration applied to live account
│   ├── v2/
│   └── v3/
├── hypothesis-log.md                # append-only ledger
├── learnings.md                     # distilled patterns
└── current -> iterations/v3         # symlink to active iteration
```

State is tracked via plain marker files (`launched_at`, `applied_at`) — no embedded state in markdown. The hooks read these directly.

## Typical workflow (pre-launch)

```
/ads-brief aruannik-commercial-ee     # intake, create folder
/ads-iterate                           # agent generates v1 + verifies
# review agent report, approve next hypothesis
/ads-iterate                           # agent generates v2 hypothesis
# approve → agent writes v2 spec + verifies
...
/ads-ready                             # final audit against launch checklist
# hand off spec.md to human or growth-hacker for actual launch
```

## Typical workflow (post-launch)

```
/ads-metrics                           # pull current numbers
/ads-hypothesize                       # see candidate fixes, ranked
/ads-iterate                           # agent writes next hypothesis
# approve → agent writes spec → you apply it to the live account
# wait 7 days (enforced by hook)
/ads-metrics                           # measure the delta
/ads-distill                           # every ~5 iterations, distill learnings
```

## Safety & boundaries

**Hard limits enforced by hooks:**
- Never navigates to campaign creation / edit / delete / billing URLs in ads.google.com
- Never writes a spec.md without a hypothesis.md
- Never accepts a hypothesis without a declared variable class
- Never accepts a multivariate hypothesis without written justification
- Never proposes a post-launch iteration before the wait gate opens

**Soft limits via skill discipline:**
- Never targets informational buyer intent
- Never routes paid traffic to blog/guide pages
- Never fabricates metrics or verification results — every claim requires a screenshot or page capture on disk

**What the plugin does NOT do:**
- Launch, pause, or edit campaigns in a live Google Ads account
- Make bid or budget changes via the Google Ads API or UI
- Click on competitor ads in real SERPs
- Use third-party SERP scrapers (Transparency Center is Google's own first-party source)

## Relationship to other plugins

- **saas-startup-team / growth-hacker** is a generalist post-launch executor that already touches Google Ads via Chrome. `ads-strategist` is a specialist designer: it produces campaign specs, growth-hacker (or a human) handles the manual launch in the Ads UI.
- The two plugins compose: use `/ads-brief` + `/ads-iterate` + `/ads-ready` here, then hand the ready spec to growth-hacker for execution.

## License

MIT.
