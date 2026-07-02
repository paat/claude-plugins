# YAML Guide Schema

Write a complete YAML file to `${VIDEO_GUIDE_CREATOR_ROOT}/guides/<slug>.yml`.

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
