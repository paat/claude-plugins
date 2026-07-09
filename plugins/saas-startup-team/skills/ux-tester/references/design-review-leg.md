# Design-review leg + post-deploy visual smoke

Shared browser-operator procedure for UI-touching changes. The JUDGE is the
business founder, scoring against `severity-matrix.md`. Capture screenshots at
**375px** and **1280px**. If the project serves multiple locales, repeat per
locale (locale list from project config/docs; else the single default). Set 10s
HTTP timeouts.

## Pre-merge design-review leg

Trigger: `scripts/ui-touch.sh` classifies the branch diff as `ui`.

1. From the tech-founder handoff, list the affected pages and open each at the
   localhost URL.
2. Capture 375px + 1280px screenshots per affected page (× each locale).
3. Score each against the severity matrix on:
   - alignment/spacing to rendered neighbors
   - text contrast ≥ 4.5:1
   - responsive integrity at both breakpoints (no overflow, overlap, clipping)
   - diacritics/Cyrillic render correctly (no mojibake/tofu)
   - loading and empty states on the affected pages
4. Emit this verdict block into the PR body (one line per FAILED heuristic only):
   ```
   ## Design-review: PASS|FAIL
   - <heuristic>: <severity> — <one line>
   ```
   FAIL on any **critical** or **major** finding. QA cannot PASS while the
   design-review is FAIL.

## Post-deploy visual smoke

Trigger: deploy is green AND this pass merged ≥1 `ui`-classified PR.

1. Visit the live URL (`SAAS_LIVE_URL`, else the architecture-doc config) key
   pages (project smoke list from config/docs; fallback: landing page + app
   entry).
2. Capture 375px + 1280px screenshots (× each locale).
3. Judge **render regressions only**: blank/unstyled sections, overlapping
   elements, broken images, mojibake/diacritics.
4. Regression **attributable to this pass's merge** → the revert path
   (maintain.md `revert/<pr-slug>` block). Non-attributable or ambiguous →
   the existing `maintain:blocked` escalation.
