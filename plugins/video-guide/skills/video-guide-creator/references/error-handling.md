# Error Handling

| Error | Fix |
|-------|-----|
| Container not built | Run `docker compose -f "${VIDEO_GUIDE_CREATOR_ROOT}/docker-compose.yml" build` |
| Edge TTS network error | Check internet connectivity from container |
| Playwright selector not found | Verify selectors against current frontend code |
| YouTube auth missing | Run `youtube-auth` command first |
| ffmpeg error | Check container logs for encoding details |
