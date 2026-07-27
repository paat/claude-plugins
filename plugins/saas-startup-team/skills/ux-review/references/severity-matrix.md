# UX Audit Severity Matrix

## Severity Definitions

| Severity | Impact | User Effect | Action Required |
|----------|--------|-------------|-----------------|
| **Critical** | Blocks a user flow or violates WCAG A | User cannot complete a core task, or assistive technology users are excluded | Must fix before go-live |
| **Major** | Significant usability issue or WCAG AA violation | User can complete task but with significant difficulty, frustration, or workaround | Should fix before go-live |
| **Minor** | Suboptimal UX or cosmetic inconsistency | User notices but is not meaningfully impacted | Fix when convenient |
| **Enhancement** | Best practice or polish improvement | User doesn't notice absence but would benefit | Consider for future iterations |

## Domain → Typical Severity Mapping

### Accessibility (WCAG 2.2)

| Issue | Typical Severity | Rationale |
|-------|-----------------|-----------|
| Missing alt text on functional images | Critical | Screen reader users cannot understand image purpose |
| No keyboard access to core functionality | Critical | Keyboard-only users are blocked |
| Keyboard trap (cannot Tab out of component) | Critical | User is stuck, must refresh |
| Contrast ratio below 3:1 (normal text) | Critical | Text is unreadable for low-vision users |
| Contrast ratio between 3:1 and 4.5:1 (normal text) | Major | Below AA requirement |
| Missing form labels | Major | Screen reader users cannot identify fields |
| No skip-to-content link | Major | Keyboard users must Tab through nav on every page |
| Missing ARIA on custom widgets | Major | Screen reader users get no semantic info |
| Focus indicator not visible | Major | Keyboard users cannot see where they are |
| Missing `lang` attribute on `<html>` | Minor | Screen readers may mispronounce content |
| Decorative images without `alt=""` | Minor | Screen readers announce filenames unnecessarily |
| Target size below 24x24px but above 20x20px | Minor | Slightly below minimum, most users unaffected |

### Usability (Nielsen Heuristics)

| Issue | Typical Severity | Rationale |
|-------|-----------------|-----------|
| No feedback after form submission | Critical (H1) | User doesn't know if action succeeded |
| Destructive action with no confirmation | Critical (H3) | User can accidentally delete data |
| Error messages show technical details | Major (H9) | User cannot understand or recover from error |
| No loading indicator for async operations | Major (H1) | User thinks system is broken |
| Inconsistent primary button styling | Major (H4) | User uncertain which action is primary |
| Missing empty states | Major (H10) | New user sees blank page with no guidance |
| Form can't be submitted with Enter key | Minor (H7) | Slightly inconvenient for keyboard users |
| Missing breadcrumbs in deep navigation | Minor (H6) | User must remember their location |
| No tooltips on icon-only buttons | Minor (H6) | Most icons are recognizable |
| Help documentation could be more contextual | Enhancement (H10) | Existing docs work but could be better |

### Visual Consistency

| Issue | Typical Severity | Rationale |
|-------|-----------------|-----------|
| Same action uses different button styles on different pages | Major | Breaks user expectations and learnability |
| More than 4 font families in use | Major | Looks unprofessional, increases cognitive load |
| Near-duplicate colors (e.g., #333 and #343434) | Minor | Technically inconsistent but visually indistinguishable |
| Spacing doesn't follow a consistent scale | Minor | Layout feels slightly off but is functional |
| Inconsistent border-radius across components | Minor | Cosmetic inconsistency |
| Slight alignment differences between similar pages | Enhancement | Barely noticeable |

### Responsive Design

| Issue | Typical Severity | Rationale |
|-------|-----------------|-----------|
| Content not accessible on mobile (hidden, overflowing, unusable) | Critical | Mobile users cannot use the product |
| Horizontal scroll on mobile | Major | Content is cut off or hard to read |
| Touch targets below 44px on mobile | Major | Users misclick frequently |
| Navigation inaccessible on mobile (no hamburger/alternative) | Major | Users cannot navigate |
| Text below 14px on mobile | Minor | Readable but strains eyes |
| Minor layout shift between breakpoints | Minor | Noticeable but doesn't affect usability |
| Could use more adaptive layout at tablet sizes | Enhancement | Works but could be optimized |

### Interaction Design

| Issue | Typical Severity | Rationale |
|-------|-----------------|-----------|
| No way to undo a destructive action | Critical | Data loss risk |
| Multi-step form loses data on back navigation | Major | User must re-enter information |
| Modal cannot be dismissed with Escape | Major | Inconsistent with platform conventions |
| Form doesn't preserve state on validation error | Major | User must re-fill valid fields |
| Missing hover states on interactive elements | Minor | User unsure what is clickable |
| Transition animations are jerky or missing | Enhancement | Polish issue |

## Prioritization Guidance for Team Lead

When the UX audit produces findings across multiple domains, use this priority order to assign work:

### Immediate (Block Go-Live)
1. **Critical accessibility violations** — legal risk (ADA/EAA compliance), excludes users entirely
2. **Critical usability blockers** — users cannot complete core tasks

### Before Go-Live
3. **Major accessibility issues** — WCAG AA failures
4. **Major usability issues** — significant friction on core flows
5. **Major responsive issues** — mobile users significantly impacted

### Post-Launch
6. **Minor issues** — functional but suboptimal
7. **Enhancements** — nice-to-have improvements

### Assignment Heuristic

| Finding Type | Assign To | Why |
|-------------|-----------|-----|
| Code fix needed (ARIA, contrast, responsive CSS, missing states) | Tech Founder | Requires code changes |
| Interaction pattern unclear, needs user research | Business Founder | Requires user perspective and competitive research |
| Content issue (labels, error messages, empty states) | Business Founder first (define copy) → Tech Founder (implement) | Business defines what to say, tech implements |
| Design system inconsistency | Tech Founder | Requires CSS/component refactoring |
