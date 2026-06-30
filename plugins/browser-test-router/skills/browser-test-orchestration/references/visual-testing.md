# Visual Testing

Use this playbook for CSS/layout checks, responsive behavior, screenshots, accessibility indicators, focus states, and visual regression.

## Text-First Visual Properties

Prefer computed style extraction before screenshots:

```javascript
function describeElementVisually(selector) {
  const elem = document.querySelector(selector);
  if (!elem) return null;
  const rect = elem.getBoundingClientRect();
  const computed = window.getComputedStyle(elem);
  return {
    selector,
    visual: {
      color: computed.color,
      backgroundColor: computed.backgroundColor,
      borderColor: computed.borderColor,
      fontSize: computed.fontSize,
      fontWeight: computed.fontWeight,
      borderWidth: computed.borderWidth,
      position: {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height)
      },
      state: {
        visible: computed.display !== "none" && computed.visibility !== "hidden",
        enabled: !elem.disabled && !elem.hasAttribute("aria-disabled"),
        focused: document.activeElement === elem,
        opacity: computed.opacity,
        hasError: elem.classList.contains("error") ||
          elem.classList.contains("invalid") ||
          elem.getAttribute("aria-invalid") === "true"
      }
    }
  };
}
```

## Screenshots

Screenshots are optional for lightweight mode and mandatory for evidence mode. Use screenshots for:

- overlapping elements;
- responsive layout breakage;
- visual proof for a report;
- page-wide before/after comparison;
- cases where structured properties cannot explain the defect.

Save screenshots under a run-specific directory and link them in the report.

## Responsive Checks

At minimum, use desktop and mobile widths. Evidence mode should include screenshot artifacts for both.
