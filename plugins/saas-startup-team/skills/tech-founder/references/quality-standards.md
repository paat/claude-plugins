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
- [ ] Estonian text preserves exact diacritics (ä, ö, ü, õ, š, ž) — never use digraphs (ae, oe, ue)
- [ ] All source files use UTF-8 encoding for proper diacritic support

### Before Handing Off
- [ ] **Run the build** (`npm run build` or equivalent) and fix ALL errors — do not hand off with a broken build
- [ ] **Validate all modified JSON files** — run `python3 -m json.tool <file>` on every `.json` file you touched (i18n locale files are the #1 source of trailing comma bugs)
- [ ] **Check TypeScript errors** — `npx tsc --noEmit` if applicable
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

## Date and Time Handling

**NEVER use `Date.toISOString()` for user-facing dates.** It converts to UTC, which shifts dates backward in the Europe/Tallinn timezone (UTC+2/UTC+3). This has caused bugs in multiple sessions.

### Rules
- Use date-only string formatting (`YYYY-MM-DD`) for dates without time components
- Use `date.toLocaleDateString()` or locale-aware libraries for display
- When parsing dates from documents/APIs, preserve the original date string — do not round-trip through `Date` objects
- If you must use `Date` objects, use `getFullYear()`, `getMonth()`, `getDate()` — never `toISOString().slice(0,10)`

### Examples
```javascript
// BAD — shifts date in Europe/Tallinn
const dateStr = new Date("2024-12-31").toISOString().slice(0, 10); // "2024-12-30" !!

// GOOD — preserves the date
const dateStr = "2024-12-31"; // Keep as string
const formatted = new Intl.DateTimeFormat('et-EE').format(new Date("2024-12-31T12:00:00")); // Noon avoids TZ shift
```

## API Integration

**ALWAYS use environment variables for base URLs in external API integrations.** Never hardcode `localhost` or any specific host — external APIs (payment gateways, webhooks) will reject localhost URLs.

### Rules
- Use `process.env.BASE_URL` (or equivalent) for ALL callback, return, and notification URLs
- Check ALL URL fields in API requests: `returnUrl`, `notificationUrl`, `callbackUrl`, `redirectUrl`
- Validate that BASE_URL is set before making API calls — fail fast with a clear error
- In development, BASE_URL should point to a tunnel or public URL, not localhost

### Examples
```javascript
// BAD — localhost will be rejected by external APIs
const returnUrl = "http://localhost:3000/payment/callback";

// GOOD — uses environment variable
const returnUrl = `${process.env.BASE_URL}/payment/callback`;
if (!process.env.BASE_URL) throw new Error("BASE_URL not configured");
```
