# reddit-fetch

Research any topic using Reddit via Gemini CLI's web access capabilities.

Claude's WebFetch cannot access Reddit content. This plugin delegates Reddit research to Gemini CLI, which has full web access and can search, read, and summarize Reddit discussions.

## Prerequisites

1. **Gemini CLI** must be installed and authenticated:
   ```bash
   npm install -g @google/gemini-cli
   gemini  # Run once interactively to complete OAuth
   ```

2. **Enable preview features** in `~/.gemini/settings.json`:
   ```json
   {
     "general": {
       "previewFeatures": true
     }
   }
   ```
   This is required to use the `gemini-3-flash-preview` model.

> **Note:** This plugin does not install Gemini CLI. It must already be available in your PATH.

## Components

### Command: `/reddit-fetch <topic>`

Quick slash command to research any topic on Reddit.

```
/reddit-fetch best static site generators 2025
/reddit-fetch NixOS vs Arch Linux for development
/reddit-fetch fix Docker compose networking issues
```

### Skill: reddit-research

Automatically activates when you ask about community opinions, real-world experiences, or Reddit discussions. Provides prompt patterns and result formatting guidance.

### Agent: reddit-researcher

Triggers proactively when your question would benefit from Reddit community insights — tool comparisons, troubleshooting, community recommendations, etc.

## How It Works

1. Constructs a Reddit-focused prompt for Gemini CLI
2. Calls `gemini -m gemini-3-flash-preview -p "..." -o text 2>/dev/null`
3. Parses and presents Reddit findings in a structured format
4. Adds caveats about anecdotal nature of Reddit opinions

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Empty response | Gemini may not find Reddit results — try more specific terms or subreddits |
| Auth error | Run `gemini` interactively to re-authenticate OAuth |
| Model not found | Enable `previewFeatures` in `~/.gemini/settings.json`, or fall back to `gemini-2.5-flash` |
| Command not found | Install Gemini CLI: `npm install -g @google/gemini-cli` |
| Timeout | Increase timeout or narrow the search scope |
