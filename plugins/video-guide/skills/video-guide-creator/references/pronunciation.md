# TTS Pronunciation Fixes

Edge TTS reads URLs and domains literally. Write them phonetically in narration text:

| Written in narration | TTS reads as |
|---------------------|--------------|
| `naide.ee` | "naide-e" (wrong) |
| `naide ee ee` | "naide ee ee" (correct, how Estonians say it) |
| `example.com` | "example dot com" (usually fine in English) |

**Rule:** For non-English domains, write them as locals pronounce them. Estonians say "ee ee" not "punkt ee ee". The visual slides still show the real domain — only the narration text needs the spoken version.
