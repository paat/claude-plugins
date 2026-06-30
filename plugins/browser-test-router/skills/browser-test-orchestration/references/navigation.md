# Navigation and Page Inventory

Use this playbook for single-page checks, route smoke tests, and content/behavior inventory.

## Prompt Pattern

Pass the full URL and ask the browser executor to:

1. navigate to the URL;
2. wait for the main content to render;
3. list visible buttons, links, forms, tables, headings, and key text;
4. report console errors and failed network requests when available;
5. return JSON only.

Example shape:

```json
{
  "url": "https://example.test/page",
  "status": 200,
  "title": "...",
  "visible_text_summary": "...",
  "elements": [
    {"type": "button", "text": "Submit", "selector": "...", "enabled": true}
  ],
  "errors": []
}
```

## Analysis

The main session compares observations against the user's task or acceptance criteria. Do not ask the browser executor to judge product readiness.

## When To Escalate

Load `visual-testing.md` if layout, responsive behavior, screenshots, or visual styling matters. Load `forms.md` if the page requires interaction.
