# Chrome Campaign Creation — Log Template, Diacritics & Pitfalls

On-demand reference for `chrome-campaign-creation`.

## Common Estonian Diacritics Corrections

`spec.md` may use ASCII for portability; always type proper Estonian Unicode diacritics (`ä, ö, ü, õ, š, ž`) in ad copy (never in URL path slugs):

- `Mikroettevotjale` → `Mikroettevõtjale`
- `Lae ules pangavaljavote` → `Lae üles pangaväljavõte`
- `Odavaim lahendus turul` → `Odavaim lahendus turul` (no diacritics needed)
- `Tahtaeg 30. Juuni 2026` → `Tähtaeg 30. juuni 2026`
- `Tehisintellekt` → `Tehisintellekt` (correct as-is)

## `creation-log.md` Template

Write to `iterations/vN/verification/creation-log.md`:

```markdown
# Campaign creation log — <campaign> vN

**Created**: YYYY-MM-DD HH:MM UTC
**Google Ads campaign URL**: <URL>
**Campaign ID**: <id>
**Status**: PAUSED

## Creation summary

| Component | Count | Status |
|-----------|-------|--------|
| Campaign settings | 1 | Created |
| Ad groups | N | Created |
| Keywords | N | Entered |
| RSAs | N | Created |
| Sitelinks | N | Added |
| Callouts | N | Added |
| Campaign negatives | N | Added |

## Diacritics applied

| Spec text (ASCII) | Entered text (Unicode) |
|---|---|
| Mikroettevotjale | Mikroettevõtjale |
| ... | ... |

## Screenshots

| Step | Description | Screenshot ID |
|------|-------------|---------------|
| 01 | Campaign settings | creation-step-01-... |
| ... | ... | ... |
| final | Campaign overview (PAUSED) | creation-step-final-overview |

## Issues encountered

- (list any form failures, unexpected UI, workarounds used)
- If none: "Clean creation, no issues."
```

## Common Pitfalls

- **"Enhanced CPC" auto-selects**: Always explicitly uncheck it when choosing Manual CPC.
- **Campaign defaults to "Enabled"**: If no Paused toggle appears during creation, pause immediately from the campaigns list after saving.
- **Keyword match types stripped**: Verify `[exact]`, `"phrase"`, and broad formatting after entry.
- **Final URL validation**: If Google rejects a URL, simplify UTM parameters (drop `{gclid}` ValueTrack — auto-tagging adds GCLID automatically).
- **Display path limit**: 15 chars per segment, no spaces.
- **RSA headline limit**: 30 chars hard limit — verify count before entering.
- **Diacritics in URLs**: Keep URL paths ASCII; use Unicode diacritics only in ad copy text.
