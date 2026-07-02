# Available Edge TTS Voices

To find voices for a language:

```bash
docker compose -f "${VIDEO_GUIDE_CREATOR_ROOT}/docker-compose.yml" \
  run --rm video-guide-creator voices --language <code>
```

Common voices:
- Estonian: `et-EE-AnuNeural` (female), `et-EE-KertNeural` (male)
- English: `en-US-AriaNeural` (female), `en-US-GuyNeural` (male)
