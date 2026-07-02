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

Screenshots are optional for lightweight mode and mandatory for evidence mode. Text-based visual properties are sufficient for most changes; request a screenshot only when text is insufficient.

Skip screenshots for:

- simple color changes (judge from `rgb()` values directly);
- small position shifts (10-20px movement);
- font size changes;
- a single element's visibility changing.

Request screenshots for:

- overlapping elements;
- responsive layout breakage;
- multiple elements shifted (suggests broken layout);
- a form or container that shrank significantly (e.g. 400px to 350px width);
- complex grid/table layout differences;
- visual proof needed for a report;
- page-wide before/after comparison;
- cases where structured properties cannot explain the defect.

| Visual change | Text description | Screenshot needed? |
|---|---|---|
| Element invisible | `visible: false`, `opacity: "0"` | Optional |
| Border color changed | `borderColor` rgb X to rgb Y | No |
| Layout shifted | multiple elements' positions changed | Yes |
| Element moved | `position.y` changed by 10-20px | No |
| Color shade changed | `backgroundColor` rgb X to rgb Y (similar hue) | No |
| Font size changed | `fontSize` changed | No |

Save screenshots under a run-specific directory (create with `mktemp -d`) and link them in the report.

## Responsive Checks

At minimum, use desktop and mobile widths. Evidence mode should include screenshot artifacts for both.
