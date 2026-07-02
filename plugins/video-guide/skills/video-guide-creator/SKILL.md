---
name: video-guide-creator
description: "Use to create tutorial, walkthrough, demo, screencast, or YouTube-style video guides with TTS, subtitles, and optional upload."
---

# Video Guide Creator

Create professional video guides with TTS narration, auto-generated subtitles, and optional YouTube upload. The video-guide-creator container handles all rendering — you generate the YAML guide definition and run it.

## Container Requirements

This skill requires a pre-built `video-guide-creator` Docker container reachable via `VIDEO_GUIDE_CREATOR_ROOT`. See the plugin README for the container requirements table, directory layout, and build command.

## Cross-Repo Usage

This skill can be invoked from any repository. When working across repos:

- **Frontend code research** happens in the **current working directory** (the repo you're in)
- **Container operations** (YAML output, rendering, brands, auth) always target `VIDEO_GUIDE_CREATOR_ROOT`
- Brand presets and auth states are shared across all projects

## Workflow

### 1. Understand what to build

Determine from the user's request:
- **Topic**: What the guide is about
- **Type**: slides-only (educational/explainer), screencast (UI walkthrough), or mixed
- **Language**: What language for narration (check brand preset first)
- **Brand**: Check if a brand preset exists at `${VIDEO_GUIDE_CREATOR_ROOT}/brands/`
- **Defaults**: If no brand preset and language is not specified, default to English with `en-US-AriaNeural` voice
- If the topic or argument text is in a non-English language, match the voice to that language

### 2. Load brand preset (if available)

Check `${VIDEO_GUIDE_CREATOR_ROOT}/brands/` for a YAML file matching the product name. Brand presets contain default colors, voice, language, and logo — use them instead of hardcoding values in every guide.

### 3. Research the topic (for screencast guides)

If the guide involves recording a web application:
- Identify the specific pages/routes/components involved in this flow, then Grep/Glob for them by filename, route, or button/label text — read only those files **in the current working directory** to find correct CSS selectors. Do not read the whole frontend tree.
- Understand the user flow (which pages, which buttons, what order)
- Check if an auth state file exists at `${VIDEO_GUIDE_CREATOR_ROOT}/auth/`

### 4. Generate the YAML guide definition

Write a complete YAML file to `${VIDEO_GUIDE_CREATOR_ROOT}/guides/<slug>.yml`. See `references/yaml-schema.md` for the full structure.

### 5. Validate the guide

Always validate before rendering to catch YAML errors early:

```bash
docker compose -f "${VIDEO_GUIDE_CREATOR_ROOT}/docker-compose.yml" \
  run --rm video-guide-creator validate guides/<slug>.yml
```

If validation fails, fix the YAML and re-validate before proceeding.

### 6. Run the container

```bash
docker compose -f "${VIDEO_GUIDE_CREATOR_ROOT}/docker-compose.yml" \
  run --rm video-guide-creator generate guides/<slug>.yml
```

### 7. Report the result

Tell the user:
- Output path: `${VIDEO_GUIDE_CREATOR_ROOT}/output/<slug>.mp4`
- Video duration (from ffprobe if needed)
- Ask if the user wants to upload to YouTube (requires prior `youtube-auth` setup)
- If yes, re-run with `--upload` flag or run the upload separately

## Writing Good Narration

- Keep sentences short (1-2 clauses)
- Match narration to what's visible on screen
- For screencasts: describe the action before it happens ("Click the blue button")
- For slides: explain the content, don't just read bullet points
- Use natural, conversational tone
- Non-English domains need phonetic narration text — see `references/pronunciation.md`

## References

- `${CLAUDE_PLUGIN_ROOT}/skills/video-guide-creator/references/yaml-schema.md` — Full YAML guide schema
- `${CLAUDE_PLUGIN_ROOT}/skills/video-guide-creator/references/voice-catalog.md` — Listing Edge TTS voices, common voice IDs
- `${CLAUDE_PLUGIN_ROOT}/skills/video-guide-creator/references/pronunciation.md` — TTS pronunciation fixes for domains/URLs
- `${CLAUDE_PLUGIN_ROOT}/skills/video-guide-creator/references/slide-templates.md` — Available slide templates
- `${CLAUDE_PLUGIN_ROOT}/skills/video-guide-creator/references/error-handling.md` — Common errors and fixes
