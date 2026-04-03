---
name: video-guide-creator
description: This skill should be used when the user asks to "create a video guide", "make a tutorial video", "record a video showing how to", "video for YouTube", "make a video about" a product or feature, "create video instructions", "generate a video tutorial", "make a screencast", "record a demo", "create a walkthrough video", or "how-to video". It handles professional video guides with TTS narration, auto-generated subtitles, and optional YouTube upload, rendered via the video-guide-creator Docker container.
---

# Video Guide Creator

Create professional video guides with TTS narration, auto-generated subtitles, and optional YouTube upload. The video-guide-creator container handles all rendering — you generate the YAML guide definition and run it.

## Container Requirements

This skill requires a pre-built `video-guide-creator` Docker container at `/mnt/data/ai/video-guide-creator/`. The container must provide:

- **Edge TTS** — Microsoft neural text-to-speech engine (internet access required)
- **FFmpeg** — video encoding and muxing
- **Playwright + Chromium** — headless browser for screencast recording
- **Python runtime** — orchestrator that parses YAML guides and drives rendering

Expected directory layout inside the container project:

| Directory | Purpose |
|-----------|---------|
| `brands/` | Brand presets (YAML) — colors, voice, language, logo per product |
| `guides/` | Generated guide definitions (YAML) — input for rendering |
| `output/` | Rendered video files (MP4) |
| `auth/` | Playwright auth state files for authenticated screencasts |
| `credentials/` | YouTube API OAuth credentials (for upload feature) |

Build the container (one-time):

```bash
docker compose -f /mnt/data/ai/video-guide-creator/docker-compose.yml build
```

## Cross-Repo Usage

This skill can be invoked from any repository. When working across repos:

- **Frontend code research** happens in the **current working directory** (the repo you're in)
- **Container operations** (YAML output, rendering, brands, auth) always target `/mnt/data/ai/video-guide-creator/`
- Brand presets and auth states are shared across all projects

## Workflow

### 1. Understand what to build

Determine from the user's request:
- **Topic**: What the guide is about
- **Type**: slides-only (educational/explainer), screencast (UI walkthrough), or mixed
- **Language**: What language for narration (check brand preset first)
- **Brand**: Check if a brand preset exists at `/mnt/data/ai/video-guide-creator/brands/`
- **Defaults**: If no brand preset and language is not specified, default to English with `en-US-AriaNeural` voice
- If the topic or argument text is in a non-English language, match the voice to that language

### 2. Load brand preset (if available)

Check `/mnt/data/ai/video-guide-creator/brands/` for a YAML file matching the product name. Brand presets contain default colors, voice, language, and logo — use them instead of hardcoding values in every guide.

### 3. Research the topic (for screencast guides)

If the guide involves recording a web application:
- Read the application's frontend code **in the current working directory** to find correct CSS selectors
- Understand the user flow (which pages, which buttons, what order)
- Check if an auth state file exists at `/mnt/data/ai/video-guide-creator/auth/`

### 4. Generate the YAML guide definition

Write a complete YAML file to `/mnt/data/ai/video-guide-creator/guides/<slug>.yml`.

#### YAML Structure

```yaml
meta:
  title: "Guide Title"
  description: "Brief description"
  language: et              # Language code
  voice: et-EE-AnuNeural    # Edge TTS voice ID
  resolution: [1920, 1080]

brand:
  logo: "brands/logo.png"   # Optional
  colors:
    primary: "#2563eb"
    background: "#0f172a"
    text: "#f8fafc"

intro:                       # Optional
  title: "Guide Title"
  subtitle: "Product name"
  narration: "Welcome narration text in target language."
  duration_padding: 1.5

steps:
  - type: slide              # Slide step
    template: bullet-points  # title-card | bullet-points | outro
    title: "Slide Title"
    bullets:
      - "Point one"
      - "Point two"
    narration: "Narration for this slide."

  - type: screencast         # Screencast step
    narration: "Narration describing what's happening."
    auth:
      storage_state: "auth/session.json"  # Optional
    actions:
      - navigate: "https://app.example.com"
      - wait: 1.5
      - highlight: "#button"
      - click: "#button"
      - fill:
          selector: "#input"
          value: "text"
      - scroll:
          y: 500
      - hover: "#element"
      - screenshot_pause: 2.0

outro:                       # Optional
  narration: "Thank you narration."
  cta_text: "Visit Us"
  cta_url: "https://example.com"

youtube:                     # Optional — omit to skip upload
  title: "YouTube Title"
  description: "YouTube description"
  tags: ["tag1", "tag2"]
  category: 27               # Education
  privacy: unlisted
  language: et
```

### 5. Validate the guide

Always validate before rendering to catch YAML errors early:

```bash
docker compose -f /mnt/data/ai/video-guide-creator/docker-compose.yml \
  run --rm video-guide-creator validate guides/<slug>.yml
```

If validation fails, fix the YAML and re-validate before proceeding.

### 6. Run the container

```bash
docker compose -f /mnt/data/ai/video-guide-creator/docker-compose.yml \
  run --rm video-guide-creator generate guides/<slug>.yml
```

### 7. Report the result

Tell the user:
- Output path: `/mnt/data/ai/video-guide-creator/output/<slug>.mp4`
- Video duration (from ffprobe if needed)
- Ask if the user wants to upload to YouTube (requires prior `youtube-auth` setup)
- If yes, re-run with `--upload` flag or run the upload separately

## Available Edge TTS Voices

To find voices for a language:

```bash
docker compose -f /mnt/data/ai/video-guide-creator/docker-compose.yml \
  run --rm video-guide-creator voices --language <code>
```

Common voices:
- Estonian: `et-EE-AnuNeural` (female), `et-EE-KertNeural` (male)
- English: `en-US-AriaNeural` (female), `en-US-GuyNeural` (male)

## Writing Good Narration

- Keep sentences short (1-2 clauses)
- Match narration to what's visible on screen
- For screencasts: describe the action before it happens ("Click the blue button")
- For slides: explain the content, don't just read bullet points
- Use natural, conversational tone

### TTS Pronunciation Fixes

Edge TTS reads URLs and domains literally. Write them phonetically in narration text:

| Written in narration | TTS reads as |
|---------------------|--------------|
| `aruannik.ee` | "aruannik-e" (wrong) |
| `aruannik ee ee` | "aruannik ee ee" (correct, how Estonians say it) |
| `example.com` | "example dot com" (usually fine in English) |

**Rule:** For non-English domains, write them as locals pronounce them. Estonians say "ee ee" not "punkt ee ee". The visual slides still show the real domain — only the narration text needs the spoken version.

## Slide Templates

| Template | Use for |
|----------|---------|
| `title-card` | Intro screens, section dividers |
| `bullet-points` | Key points, feature lists, step summaries |
| `outro` | Final CTA, closing screen |

## Error Handling

| Error | Fix |
|-------|-----|
| Container not built | Run `docker compose -f /mnt/data/ai/video-guide-creator/docker-compose.yml build` |
| Edge TTS network error | Check internet connectivity from container |
| Playwright selector not found | Verify selectors against current frontend code |
| YouTube auth missing | Run `youtube-auth` command first |
| ffmpeg error | Check container logs for encoding details |
