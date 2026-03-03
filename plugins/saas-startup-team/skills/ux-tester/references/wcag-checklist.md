# WCAG 2.2 AA Compliance Checklist

## Perceivable

### 1.1 Text Alternatives

| Criterion | Level | What to Check | How to Test |
|-----------|-------|---------------|-------------|
| 1.1.1 Non-text Content | A | All `<img>` have `alt`, decorative images use `alt=""`, `<svg>` have `<title>` or `aria-label` | Grep for `<img` without `alt=`, `browser_evaluate` to find images missing alt |

### 1.2 Time-Based Media

| Criterion | Level | What to Check | How to Test |
|-----------|-------|---------------|-------------|
| 1.2.1 Audio/Video (Prerecorded) | A | Captions or transcripts for media content | Check `<video>` and `<audio>` elements for `<track>` elements |

### 1.3 Adaptable

| Criterion | Level | What to Check | How to Test |
|-----------|-------|---------------|-------------|
| 1.3.1 Info and Relationships | A | Semantic HTML used (headings, lists, tables, landmarks, form labels) | Grep for heading hierarchy, `browser_evaluate` to check form label associations |
| 1.3.2 Meaningful Sequence | A | DOM order matches visual order | `browser_evaluate` comparing element positions to DOM order |
| 1.3.3 Sensory Characteristics | A | Instructions don't rely solely on shape, color, size, or location | Review button labels, error indicators, status messages |
| 1.3.4 Orientation | AA | Content not locked to portrait or landscape | `browser_resize` to test both orientations |
| 1.3.5 Identify Input Purpose | AA | Form inputs use `autocomplete` attribute | Grep for `<input>` elements, check for `autocomplete` on common fields (name, email, address) |

### 1.4 Distinguishable

| Criterion | Level | What to Check | How to Test |
|-----------|-------|---------------|-------------|
| 1.4.1 Use of Color | A | Color is not the only visual means of conveying information | Check error states, required fields, status indicators for non-color cues |
| 1.4.2 Audio Control | A | Auto-playing audio can be paused or stopped | Check for `<audio autoplay>` or `<video autoplay>` |
| 1.4.3 Contrast (Minimum) | AA | Text: 4.5:1, large text (18pt/14pt bold): 3:1 | `browser_evaluate` to extract text colors and background colors, compute ratio |
| 1.4.4 Resize Text | AA | Text readable at 200% zoom without loss of content | `browser_evaluate` with `document.documentElement.style.fontSize = '200%'` |
| 1.4.5 Images of Text | AA | Real text used instead of images of text | Check for text rendered as images (logos exempt) |
| 1.4.10 Reflow | AA | No horizontal scroll at 320px width (1280px at 400% zoom) | `browser_resize` to 320px width |
| 1.4.11 Non-text Contrast | AA | UI components and graphics: 3:1 contrast | `browser_evaluate` to check border/icon colors against backgrounds |
| 1.4.12 Text Spacing | AA | No loss of content with modified text spacing (line-height 1.5x, paragraph spacing 2x, letter spacing 0.12em, word spacing 0.16em) | `browser_evaluate` to inject spacing overrides |
| 1.4.13 Content on Hover/Focus | AA | Tooltips/popovers: dismissible (Esc), hoverable, persistent | `browser_hover` on tooltip triggers, check behavior |

## Operable

### 2.1 Keyboard Accessible

| Criterion | Level | What to Check | How to Test |
|-----------|-------|---------------|-------------|
| 2.1.1 Keyboard | A | All functionality available via keyboard | `browser_press_key` Tab through entire page, Enter/Space on controls |
| 2.1.2 No Keyboard Trap | A | Focus can move away from all components | Tab into and out of modals, dropdowns, rich editors |
| 2.1.4 Character Key Shortcuts | A | Single-character shortcuts can be turned off or remapped | Check for keyboard shortcut implementations |

### 2.4 Navigable

| Criterion | Level | What to Check | How to Test |
|-----------|-------|---------------|-------------|
| 2.4.1 Bypass Blocks | A | Skip-to-content link available | `browser_press_key` Tab on page load → check for skip link |
| 2.4.2 Page Titled | A | Each page has a descriptive `<title>` | `browser_evaluate` to read `document.title` on each page |
| 2.4.3 Focus Order | A | Tab order follows logical reading order | Tab through page, verify sequence matches visual layout |
| 2.4.4 Link Purpose (In Context) | A | Link text describes destination (no "click here") | `browser_evaluate` to extract all link texts |
| 2.4.5 Multiple Ways | AA | More than one way to reach each page (nav, search, sitemap) | Check for navigation menu and search functionality |
| 2.4.6 Headings and Labels | AA | Headings and labels describe topic or purpose | `browser_evaluate` to extract heading hierarchy |
| 2.4.7 Focus Visible | AA | Keyboard focus indicator is clearly visible | Tab through elements → check for visible focus ring |
| 2.4.11 Focus Not Obscured (Minimum) | AA | Focused element not fully hidden by sticky headers/footers | Tab to elements near sticky regions |

### 2.5 Input Modalities

| Criterion | Level | What to Check | How to Test |
|-----------|-------|---------------|-------------|
| 2.5.1 Pointer Gestures | A | Multipoint/path gestures have single-pointer alternatives | Check for swipe/pinch gestures without button alternatives |
| 2.5.2 Pointer Cancellation | A | Down-event doesn't trigger action; can abort | Check for `mousedown`/`touchstart` handlers that fire actions |
| 2.5.3 Label in Name | A | Visible label text is included in accessible name | `browser_evaluate` comparing visible text to `aria-label` |
| 2.5.4 Motion Actuation | A | Shake/tilt features have UI alternatives | Check for device motion event handlers |
| 2.5.7 Dragging Movements | AA | Drag operations have non-dragging alternatives | Check sortable lists, file uploads for click alternatives |
| 2.5.8 Target Size (Minimum) | AA | Interactive targets at least 24x24 CSS px (with spacing exceptions) | `browser_evaluate` to measure button/link dimensions |

## Understandable

### 3.1 Readable

| Criterion | Level | What to Check | How to Test |
|-----------|-------|---------------|-------------|
| 3.1.1 Language of Page | A | `<html lang>` attribute set correctly | `browser_evaluate` → `document.documentElement.lang` |
| 3.1.2 Language of Parts | AA | Content in different languages marked with `lang` attribute | Check multilingual content sections |

### 3.2 Predictable

| Criterion | Level | What to Check | How to Test |
|-----------|-------|---------------|-------------|
| 3.2.1 On Focus | A | Focus doesn't trigger unexpected context changes | Tab through form fields → no auto-navigation or auto-submit |
| 3.2.2 On Input | A | Input changes don't auto-submit or auto-navigate | Change select/radio values → verify no unexpected actions |
| 3.2.3 Consistent Navigation | AA | Nav appears in same order across pages | Compare nav structure across 3+ pages |
| 3.2.4 Consistent Identification | AA | Same function has same label everywhere | Check button/link text consistency for repeated functions |

### 3.3 Input Assistance

| Criterion | Level | What to Check | How to Test |
|-----------|-------|---------------|-------------|
| 3.3.1 Error Identification | A | Errors described in text (not just color) | Submit invalid forms → check error messages |
| 3.3.2 Labels or Instructions | A | Form fields have visible labels | `browser_evaluate` checking `<label>` association |
| 3.3.3 Error Suggestion | AA | Error messages suggest correction | Submit wrong format → check if message explains expected format |
| 3.3.4 Error Prevention (Legal, Financial, Data) | AA | Confirmation step for important transactions | Test checkout/delete/submit flows for review step |
| 3.3.7 Redundant Entry | A | Previously entered info auto-populated (don't re-ask) | Complete multi-step form → check if info carries forward |
| 3.3.8 Accessible Authentication (Minimum) | AA | Login doesn't require cognitive function tests (no CAPTCHA without alternative) | Check login flow for cognitive barriers |

## Robust

### 4.1 Compatible

| Criterion | Level | What to Check | How to Test |
|-----------|-------|---------------|-------------|
| 4.1.2 Name, Role, Value | A | Custom components have correct ARIA roles and states | `browser_evaluate` to check `role`, `aria-*` attributes on custom widgets |
| 4.1.3 Status Messages | AA | Status updates use `role="status"` or `aria-live` regions | `browser_evaluate` to check live regions for toast/alert/status messages |

## Common ARIA Patterns

### Required ARIA for Custom Components

| Component | Required ARIA |
|-----------|---------------|
| Modal dialog | `role="dialog"`, `aria-modal="true"`, `aria-labelledby` |
| Tab panel | `role="tablist"`, `role="tab"`, `role="tabpanel"`, `aria-selected` |
| Accordion | `aria-expanded`, `aria-controls` |
| Dropdown menu | `role="menu"`, `role="menuitem"`, `aria-expanded` |
| Alert/toast | `role="alert"` or `aria-live="assertive"` |
| Status message | `role="status"` or `aria-live="polite"` |
| Progress bar | `role="progressbar"`, `aria-valuenow`, `aria-valuemin`, `aria-valuemax` |
| Toggle button | `aria-pressed="true/false"` |
| Combobox/autocomplete | `role="combobox"`, `aria-expanded`, `aria-activedescendant` |

### Focus Management Rules

1. **Modal open:** Move focus to first focusable element inside modal
2. **Modal close:** Return focus to the trigger element
3. **Item delete:** Move focus to next item, or previous if last was deleted
4. **Dynamic content:** Use `aria-live` regions, don't steal focus
5. **Error on submit:** Move focus to first invalid field
6. **Page navigation (SPA):** Announce new page, focus `<main>` or `<h1>`

## Contrast Ratio Reference

| Element Type | Minimum Ratio | Notes |
|-------------|---------------|-------|
| Normal text (<18pt) | 4.5:1 | Against immediate background |
| Large text (>=18pt or >=14pt bold) | 3:1 | Against immediate background |
| UI components (borders, icons) | 3:1 | Against adjacent colors |
| Focus indicators | 3:1 | Against both focused element and surrounding area |
| Disabled elements | None | Exempt from contrast requirements |
| Logos/brand text | None | Exempt from contrast requirements |

### Contrast Calculation

```javascript
// Relative luminance formula (WCAG 2.x)
function luminance(r, g, b) {
  const [rs, gs, bs] = [r, g, b].map(c => {
    c = c / 255;
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * rs + 0.7152 * gs + 0.0722 * bs;
}

function contrastRatio(l1, l2) {
  const lighter = Math.max(l1, l2);
  const darker = Math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}
```
