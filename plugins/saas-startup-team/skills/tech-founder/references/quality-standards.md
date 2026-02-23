# Code and UI Quality Standards

## Code Quality Checklist

### Before Writing Code
- [ ] Read the full handoff document
- [ ] Understand the "Why" (business justification)
- [ ] Review existing code structure
- [ ] Plan the approach (don't code first, think first)

### While Writing Code
- [ ] Functions are small and focused (< 30 lines)
- [ ] Variable names describe what they hold
- [ ] Function names describe what they do
- [ ] No magic numbers — use named constants
- [ ] Error messages are helpful to the customer
- [ ] Edge cases are handled (empty states, error states)

### Before Handing Off
- [ ] Code runs without errors
- [ ] Primary user flow works end-to-end
- [ ] Error flow is tested (what happens when things go wrong?)
- [ ] Mobile view is acceptable (if user-facing)
- [ ] Testing instructions are clear enough for non-technical reviewer

## UI Quality Standards

### Typography
- Use system font stack for fast loading:
  ```css
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  ```
- Heading hierarchy: h1 > h2 > h3 (never skip levels)
- Body text: 16px minimum, 1.5 line-height
- Limit line width to ~65 characters for readability

### Spacing
- Use a consistent scale: 4, 8, 12, 16, 24, 32, 48, 64px
- Card padding: 16-24px
- Section spacing: 32-64px
- Button padding: 8-12px vertical, 16-24px horizontal

### Colors
- Primary: 1 brand color for CTAs and key actions
- Accent: 1 secondary color for highlights
- Success: green (e.g., #10b981)
- Warning: amber (e.g., #f59e0b)
- Error: red (e.g., #ef4444)
- Neutrals: gray scale for text and backgrounds
- Ensure contrast ratio >= 4.5:1 for accessibility

### Component Standards

#### Buttons
- Clear hierarchy: primary (filled), secondary (outlined), ghost (text)
- Hover and focus states
- Loading state with spinner
- Disabled state with reduced opacity

#### Forms
- Labels above inputs (not placeholder-only)
- Validation messages below the field
- Required field indicators
- Focus ring visible for keyboard navigation

#### Tables / Lists
- Striped rows or dividers for readability
- Sortable headers if applicable
- Empty state message when no data
- Pagination or infinite scroll for long lists

#### Modals / Dialogs
- Clear title and close button
- Backdrop overlay
- Escape key to close
- Focus trap (Tab stays within modal)

### Responsive Design
- Mobile-first approach
- Breakpoints: 640px (sm), 768px (md), 1024px (lg), 1280px (xl)
- Stack layouts vertically on mobile
- Touch targets: minimum 44x44px
- Test at 320px width (smallest common phone)

## Error Handling Standards

### User-Facing Errors
```
BAD:  "Error 500: Internal Server Error"
GOOD: "Something went wrong. Please try again, or contact support if the problem persists."

BAD:  "Validation failed"
GOOD: "Please enter a valid email address (e.g., name@example.com)"

BAD:  "Not found"
GOOD: "We couldn't find that page. It may have been moved or deleted."
```

### Loading States
```
BAD:  Empty screen while loading
GOOD: Skeleton placeholder showing the expected layout

BAD:  Spinner with no context
GOOD: "Loading your dashboard..." with progress indication
```

### Empty States
```
BAD:  Blank page with no content
GOOD: Illustration + "No projects yet. Create your first project to get started." + CTA button
```
