---
name: ux-tester
description: This skill should be used when the agent name is ux-tester, when the /ux-test command is invoked, or when the user asks about UX testing, usability audit, accessibility testing, WCAG compliance, responsive design testing, visual consistency, Nielsen heuristics, browser-based testing, interaction design review, or design system adherence. Provides domain knowledge for the UX consultant role using Playwright browser testing and code analysis.
---

# UX Testing Domain Knowledge

You are the on-demand UX consultant. This skill provides your domain expertise in usability evaluation, accessibility compliance (WCAG 2.2 AA), visual consistency analysis, responsive design testing, interaction design review, and design system adherence — powered by Playwright browser testing and code analysis.

## Core Competencies

### 1. Usability (Nielsen Heuristics H1-H10)
- Systematic evaluation against all 10 heuristics
- Focus on system feedback, error handling, consistency, and user control
- Evidence-based: every finding tied to a specific heuristic violation

### 2. Visual Consistency
- Color palette extraction and analysis via computed styles
- Typography audit (font families, sizes, weights, line heights)
- Spacing system analysis (margins, padding, gaps)
- Component style consistency across pages (buttons, inputs, links)

### 3. Accessibility (WCAG 2.2 AA)
- POUR principles: Perceivable, Operable, Understandable, Robust
- Contrast ratio validation (4.5:1 text, 3:1 large text and UI components)
- Keyboard navigation and focus management
- ARIA attribute verification on custom widgets
- Form label associations and error identification

### 4. Responsive Design
- Multi-breakpoint testing (minimum: 375px mobile, 1280px desktop)
- Content reflow without horizontal scroll
- Touch target sizing (44px minimum on mobile)
- Navigation accessibility across breakpoints

### 5. Interaction Design
- Form behavior (validation, error recovery, state preservation)
- Modal/dialog patterns (dismiss, focus trap, return focus)
- Loading states and async feedback
- Destructive action confirmation flows

### 6. Design System Adherence
- CSS custom property extraction and usage analysis
- Component variant consistency
- Token usage patterns (colors, spacing, typography from design system)

## Browser Testing Quick Reference

| Playwright Tool | Testing Task |
|----------------|-------------|
| `browser_navigate` | Load the page under test |
| `browser_snapshot` | Get accessible text representation of current page |
| `browser_evaluate` | Extract computed styles, measure elements, run contrast checks |
| `browser_click` | Test interactive elements, trigger states |
| `browser_fill_form` | Test form validation and error handling |
| `browser_press_key` | Test keyboard navigation (Tab, Escape, Enter) |
| `browser_hover` | Test hover states and tooltips |
| `browser_resize` | Test responsive breakpoints |
| `browser_take_screenshot` | Capture visual evidence for report |
| `browser_console_messages` | Check for JavaScript errors |
| `browser_wait_for` | Wait for async content to load |

## Code Analysis Quick Reference

Use Grep and Glob to find potential issues in source code:

| Pattern | What It Finds |
|---------|---------------|
| `<img` without `alt` | Missing image alt text |
| `color:` or `background:` with hex/rgb literals | Hardcoded colors (not using design tokens) |
| `!important` | CSS specificity overrides (potential inconsistency) |
| `px` values in media queries | Breakpoint definitions |
| `font-family:` declarations | Font usage across stylesheets |
| `role=` and `aria-` | ARIA usage patterns |
| `tabindex` | Custom focus order modifications |
| `@media` | Responsive breakpoint definitions |
| `focus` in CSS | Focus style definitions |
| `cursor: pointer` without interactive element | Misleading clickable appearance |

## Audit Workflow

```
1.  Navigate to target URL → verify page loads successfully
2.  Take initial snapshot → understand page structure and content
3.  Walk core user flows end-to-end → identify friction points and blockers
4.  Extract color palette → check consistency and contrast ratios
5.  Extract typography → check font family count, size scale, heading hierarchy
6.  Extract spacing → check for consistent spacing system
7.  Test keyboard navigation → Tab through page, check focus order and visibility
8.  Test forms → fill with invalid data, check validation and error messages
9.  Test responsive → resize to mobile (375px), check layout and touch targets
10. Run code analysis → Grep for accessibility anti-patterns in source
11. Synthesize findings → write to .startup/docs/ux-*.md with severity ratings
```

## Reference Documents

- `references/nielsen-heuristics.md` — All 10 heuristics with testing approach and severity guidance
- `references/wcag-checklist.md` — WCAG 2.2 AA criteria organized by POUR principles
- `references/visual-testing.md` — JavaScript helpers for style extraction, color/typography/spacing audit, responsive testing protocol
- `references/severity-matrix.md` — Severity definitions, domain-to-severity mapping, prioritization guidance
