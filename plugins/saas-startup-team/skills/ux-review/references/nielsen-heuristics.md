# Nielsen's 10 Usability Heuristics — UX Audit Reference

## H1: Visibility of System Status

**Principle:** The system should always keep users informed about what is going on, through appropriate feedback within reasonable time.

**What to check:**
- Loading indicators for async operations (API calls, form submissions, file uploads)
- Progress bars for multi-step processes
- Success/error feedback after user actions
- Active state indicators (selected tabs, current page in nav)
- Real-time validation feedback on form inputs

**Common violations:**
- Form submits with no loading state — user clicks multiple times
- Page navigation with no active indicator
- Background operations with no progress feedback
- Toast/notification messages that disappear too quickly (<3s)

**Browser testing approach:**
1. `browser_click` on every form submit button → check for loading state via `browser_snapshot`
2. `browser_navigate` between pages → check nav highlights
3. `browser_fill_form` with invalid data → check for inline validation
4. `browser_evaluate` to check for pending fetch/XHR requests without UI indicators

**Severity guidance:** Critical if user actions appear to do nothing (no feedback at all). Major if feedback is delayed >2s. Minor if feedback exists but is unclear.

## H2: Match Between System and Real World

**Principle:** The system should speak the users' language, with words, phrases, and concepts familiar to the user, rather than system-oriented terms.

**What to check:**
- Labels use domain language, not developer jargon
- Date/time/currency formats match target locale
- Icons are universally recognizable or labeled
- Error messages describe the problem in user terms
- Navigation labels match user mental models

**Common violations:**
- Error messages showing stack traces, HTTP status codes, or database errors
- Technical labels: "entity", "record", "instance" instead of domain terms
- Dates in ISO format (2024-01-15) instead of locale format
- Boolean toggles labeled "true/false" instead of meaningful labels

**Browser testing approach:**
1. `browser_snapshot` on all pages → scan text content for technical jargon
2. Trigger errors intentionally → read error message text
3. `browser_evaluate` to check `<html lang>` attribute and date formatting

**Severity guidance:** Major if error messages expose technical details. Minor if labels are technically accurate but not user-friendly.

## H3: User Control and Freedom

**Principle:** Users often perform actions by mistake. They need a clearly marked "emergency exit" to leave the unwanted state without having to go through an extended process.

**What to check:**
- Cancel buttons on all forms and modals
- Undo support for destructive actions (delete, archive)
- Back navigation works correctly (browser back button)
- Modal dialogs can be closed (X button, Escape key, backdrop click)
- Multi-step forms allow going back to previous steps

**Common violations:**
- Delete actions with no confirmation dialog
- Modals that can only be closed by completing the form
- Wizards with no back button
- No way to cancel a file upload in progress

**Browser testing approach:**
1. `browser_navigate_back` after form submission → check state preservation
2. `browser_press_key` Escape on modals → check if they close
3. `browser_click` outside modal → check backdrop dismissal
4. Look for delete/remove buttons → verify confirmation exists

**Severity guidance:** Critical if destructive actions have no confirmation. Major if users get trapped in flows they can't exit.

## H4: Consistency and Standards

**Principle:** Users should not have to wonder whether different words, situations, or actions mean the same thing. Follow platform conventions.

**What to check:**
- Consistent button styles for same-type actions (primary, secondary, destructive)
- Consistent terminology across pages (don't mix "delete"/"remove"/"discard")
- Consistent layout patterns (header, sidebar, content area)
- Standard interaction patterns (links look like links, buttons look like buttons)
- Consistent spacing, typography, and color usage

**Common violations:**
- Primary action button is blue on one page, green on another
- "Save" vs "Submit" vs "Confirm" for same type of action
- Different input field styles across forms
- Inconsistent icon usage (same icon means different things)

**Browser testing approach:**
1. `browser_evaluate` with style extraction helper across multiple pages
2. `browser_snapshot` on 3+ pages → compare layout structures
3. Catalog all button texts → check for synonym inconsistencies
4. Compare form field styles across different forms

**Severity guidance:** Major if inconsistencies cause confusion about functionality. Minor if purely cosmetic inconsistencies.

## H5: Error Prevention

**Principle:** Even better than good error messages is a careful design that prevents a problem from occurring in the first place.

**What to check:**
- Form validation prevents invalid submissions (email format, required fields)
- Dangerous actions require confirmation (delete account, bulk operations)
- Input constraints match expected data (number inputs for quantities, date pickers for dates)
- Autosave or draft preservation for long forms
- Disabled states for unavailable actions (grey out, don't hide)

**Common violations:**
- Free-text input where a dropdown would prevent errors
- No client-side validation — all errors come from server after submit
- Delete buttons without confirmation, especially for bulk operations
- Required fields not marked until submission fails

**Browser testing approach:**
1. `browser_fill_form` with empty required fields → check pre-submit validation
2. `browser_type` invalid formats (bad email, letters in phone) → check inline validation
3. Look for destructive action buttons → test confirmation flows
4. `browser_evaluate` to check `<input type>` attributes match expected data

**Severity guidance:** Critical if no validation on destructive actions. Major if common input errors aren't prevented. Minor if edge cases slip through.

## H6: Recognition Rather Than Recall

**Principle:** Minimize the user's memory load by making objects, actions, and options visible.

**What to check:**
- Recent items, search history, or suggestions in search fields
- Breadcrumbs for hierarchical navigation
- Labels on icons (not icon-only buttons without tooltips)
- Context preserved when returning to a page
- Placeholder text or examples in empty states

**Common violations:**
- Icon-only toolbars with no tooltips
- Empty search fields with no suggestions or recent searches
- No breadcrumbs in deeply nested content
- Filter settings lost when navigating away and back

**Browser testing approach:**
1. `browser_snapshot` → identify icon-only buttons without labels
2. `browser_hover` on icon buttons → check for tooltip appearance
3. Navigate away from filtered view and back → check if filters persist
4. `browser_click` on search field → check for autocomplete/suggestions

**Severity guidance:** Major if users must memorize codes, IDs, or paths. Minor if tooltips are missing but icons are standard.

## H7: Flexibility and Efficiency of Use

**Principle:** Accelerators — unseen by the novice user — may speed up interaction for expert users.

**What to check:**
- Keyboard shortcuts for common actions
- Bulk operations for list views (select all, bulk delete/edit)
- Search/filter functionality on data-heavy pages
- Customizable views or dashboards
- Direct URL access to specific items/views

**Common violations:**
- No keyboard navigation support (Tab order broken)
- Large lists with no search or filter
- No bulk operations — must act on items one by one
- Forms that can't be submitted with Enter key

**Browser testing approach:**
1. `browser_press_key` Tab through forms → verify focus order
2. `browser_press_key` Enter in forms → check if submit works
3. Look for list views → check for search/filter/sort controls
4. `browser_evaluate` to check `tabindex` attributes and keyboard event handlers

**Severity guidance:** Major if keyboard navigation is broken (accessibility overlap). Minor if power-user features are absent but basic flow works.

## H8: Aesthetic and Minimalist Design

**Principle:** Interfaces should not contain information that is irrelevant or rarely needed. Every extra unit of information competes with relevant information.

**What to check:**
- Visual hierarchy guides attention to primary content and actions
- No information overload on single pages
- Progressive disclosure for advanced options
- White space used effectively to group related content
- Primary action is visually prominent, secondary actions are subdued

**Common violations:**
- Dashboard showing 10+ metrics with equal visual weight
- Forms showing all optional fields by default
- Multiple competing CTAs on a single page
- Dense text without headings, spacing, or visual breaks

**Browser testing approach:**
1. `browser_snapshot` → assess information density per screen
2. `browser_evaluate` to count interactive elements per viewport
3. Check for visual hierarchy: primary buttons should be larger/bolder
4. `browser_resize` to mobile → check if content prioritization changes

**Severity guidance:** Major if information overload prevents task completion. Minor if pages are busy but usable.

## H9: Help Users Recognize, Diagnose, and Recover from Errors

**Principle:** Error messages should be expressed in plain language, precisely indicate the problem, and constructively suggest a solution.

**What to check:**
- Error messages are human-readable (no codes, no stack traces)
- Error messages indicate what went wrong AND how to fix it
- Form validation errors appear next to the relevant field
- 404 pages offer navigation options
- Network error states have retry options

**Common violations:**
- "An error occurred" with no details
- "Error 500" or "Something went wrong"
- Validation errors shown only at top of form, not inline
- Blank page or browser error on 404/500

**Browser testing approach:**
1. `browser_fill_form` with intentionally invalid data → check error message quality
2. `browser_navigate` to non-existent URL → check 404 page
3. `browser_evaluate` to temporarily break API calls → check error recovery UI
4. Check that error messages appear near the source of the problem

**Severity guidance:** Critical if errors show no message or show technical errors. Major if errors lack recovery guidance. Minor if errors are clear but could be more helpful.

## H10: Help and Documentation

**Principle:** It may be necessary to provide help and documentation. Such information should be easy to search, focused on the user's task, list concrete steps, and not be too large.

**What to check:**
- Contextual help (tooltips, info icons) for complex fields
- Onboarding flow for new users
- Empty states with guidance (what to do when a list is empty)
- Inline help or documentation links for complex features
- FAQ or help section accessible from the app

**Common violations:**
- Complex features with no documentation
- Empty states that just say "No items" with no guidance
- No onboarding — user dropped into full interface immediately
- Help docs exist but aren't linked from the application

**Browser testing approach:**
1. `browser_snapshot` on empty states → check for guidance text
2. Look for help icons (?) → check if they provide useful information
3. Navigate as a new user → check for onboarding or welcome flow
4. Check if complex features have inline documentation

**Severity guidance:** Major if critical features lack any documentation. Minor if help exists but could be more contextual.
