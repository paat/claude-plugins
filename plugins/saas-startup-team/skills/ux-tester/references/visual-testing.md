# Visual Testing Methodology

## Text-First Principle

You are an LLM — you work with text, not pixels. Your primary testing method is extracting computed styles as structured data via `browser_evaluate`, then analyzing the values. Screenshots are supplementary evidence, not your analysis tool.

**Workflow:**
1. Extract styles as JSON → analyze values → identify issues
2. Take screenshot only when you need visual evidence for your report

## JavaScript Style Extraction Helper

Use this helper via `browser_evaluate` to extract computed styles from elements on the page:

```javascript
// Extract visual properties from all elements matching a selector
function extractStyles(selector, properties) {
  const elements = document.querySelectorAll(selector);
  return Array.from(elements).map(el => {
    const computed = getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    const result = {
      tag: el.tagName.toLowerCase(),
      text: el.textContent.trim().substring(0, 80),
      visible: rect.width > 0 && rect.height > 0,
      rect: { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) }
    };
    properties.forEach(prop => {
      result[prop] = computed.getPropertyValue(prop);
    });
    return result;
  });
}
```

### Usage Patterns

**Extract all heading styles:**
```javascript
extractStyles('h1, h2, h3, h4, h5, h6', ['font-size', 'font-weight', 'font-family', 'color', 'line-height', 'margin-top', 'margin-bottom'])
```

**Extract button styles:**
```javascript
extractStyles('button, [role="button"], a.btn, .button', ['background-color', 'color', 'border', 'border-radius', 'padding', 'font-size', 'font-weight', 'cursor'])
```

**Extract link styles:**
```javascript
extractStyles('a', ['color', 'text-decoration', 'font-weight'])
```

**Extract input styles:**
```javascript
extractStyles('input, select, textarea', ['border', 'border-radius', 'padding', 'font-size', 'background-color', 'color', 'outline'])
```

**Extract spacing between siblings:**
```javascript
(function() {
  const containers = document.querySelectorAll('main, [role="main"], .content, .container');
  return Array.from(containers).flatMap(container => {
    const children = Array.from(container.children);
    return children.slice(1).map((el, i) => {
      const prev = children[i];
      const gap = el.getBoundingClientRect().top - prev.getBoundingClientRect().bottom;
      return { between: prev.tagName + ' → ' + el.tagName, gap: Math.round(gap) + 'px' };
    });
  });
})()
```

**Extract color palette from the page:**
```javascript
(function() {
  const colors = new Map();
  document.querySelectorAll('*').forEach(el => {
    const cs = getComputedStyle(el);
    ['color', 'background-color', 'border-color'].forEach(prop => {
      const val = cs.getPropertyValue(prop);
      if (val && val !== 'rgba(0, 0, 0, 0)' && val !== 'transparent') {
        const key = prop + ':' + val;
        colors.set(key, (colors.get(key) || 0) + 1);
      }
    });
  });
  return Array.from(colors.entries())
    .sort((a, b) => b[1] - a[1])
    .slice(0, 30)
    .map(([k, v]) => ({ property: k.split(':')[0], value: k.split(':').slice(1).join(':'), count: v }));
})()
```

## Color Audit Methodology

### Step 1: Extract Color Palette
Use the color palette helper above. Look for:
- Total unique colors used (>15 distinct colors suggests inconsistency)
- Color values that are very close but not identical (e.g., `#333` vs `#343434`)
- Colors used only once (potential one-off inconsistencies)

### Step 2: Check Brand Consistency
If a design system or CSS custom properties exist:
```javascript
(function() {
  const root = getComputedStyle(document.documentElement);
  const vars = Array.from(document.styleSheets)
    .flatMap(sheet => {
      try { return Array.from(sheet.cssRules); } catch(e) { return []; }
    })
    .filter(rule => rule.selectorText === ':root' || rule.selectorText === ':host')
    .flatMap(rule => Array.from(rule.style))
    .filter(prop => prop.startsWith('--'))
    .map(prop => ({ name: prop, value: root.getPropertyValue(prop).trim() }));
  return vars;
})()
```

### Step 3: Contrast Checking
For each text element, extract foreground and background colors and compute contrast ratio:
```javascript
(function() {
  function getLuminance(r, g, b) {
    const [rs, gs, bs] = [r, g, b].map(c => {
      c = c / 255;
      return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * rs + 0.7152 * gs + 0.0722 * bs;
  }
  function parseColor(color) {
    const m = color.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
    return m ? [parseInt(m[1]), parseInt(m[2]), parseInt(m[3])] : null;
  }
  function getEffectiveBg(el) {
    let current = el;
    while (current) {
      const bg = getComputedStyle(current).backgroundColor;
      const parsed = parseColor(bg);
      if (parsed && (parsed[0] !== 0 || parsed[1] !== 0 || parsed[2] !== 0 || !bg.includes('0)'))) {
        return parsed;
      }
      current = current.parentElement;
    }
    return [255, 255, 255]; // default white
  }
  const results = [];
  document.querySelectorAll('p, span, a, li, td, th, label, h1, h2, h3, h4, h5, h6, button').forEach(el => {
    if (!el.offsetWidth || !el.offsetHeight) return;
    const fg = parseColor(getComputedStyle(el).color);
    const bg = getEffectiveBg(el);
    if (!fg || !bg) return;
    const l1 = getLuminance(...fg);
    const l2 = getLuminance(...bg);
    const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
    const fontSize = parseFloat(getComputedStyle(el).fontSize);
    const fontWeight = parseInt(getComputedStyle(el).fontWeight);
    const isLarge = fontSize >= 24 || (fontSize >= 18.66 && fontWeight >= 700);
    const required = isLarge ? 3 : 4.5;
    if (ratio < required) {
      results.push({
        tag: el.tagName,
        text: el.textContent.trim().substring(0, 60),
        fg: `rgb(${fg.join(',')})`,
        bg: `rgb(${bg.join(',')})`,
        ratio: Math.round(ratio * 100) / 100,
        required: required,
        pass: false
      });
    }
  });
  return results;
})()
```

## Typography Audit

### Check Consistency
```javascript
(function() {
  const fonts = new Map();
  document.querySelectorAll('*').forEach(el => {
    if (!el.offsetWidth) return;
    const cs = getComputedStyle(el);
    const key = cs.fontFamily + '|' + cs.fontSize + '|' + cs.fontWeight;
    if (!fonts.has(key)) fonts.set(key, { family: cs.fontFamily, size: cs.fontSize, weight: cs.fontWeight, count: 0, examples: [] });
    const entry = fonts.get(key);
    entry.count++;
    if (entry.examples.length < 3) entry.examples.push(el.tagName + ': ' + el.textContent.trim().substring(0, 40));
  });
  return Array.from(fonts.values()).sort((a, b) => b.count - a.count);
})()
```

### Look For
- More than 3 font families (suggests inconsistency)
- More than 6 font size values (suggests no type scale)
- Font sizes below 12px (readability concern)
- Inconsistent heading sizes (h2 larger than h1, etc.)

## Spacing Audit

### Check for Spacing System
```javascript
(function() {
  const spacings = new Map();
  document.querySelectorAll('*').forEach(el => {
    if (!el.offsetWidth) return;
    const cs = getComputedStyle(el);
    ['margin-top', 'margin-bottom', 'padding-top', 'padding-bottom', 'padding-left', 'padding-right', 'gap'].forEach(prop => {
      const val = cs.getPropertyValue(prop);
      if (val && val !== '0px') {
        spacings.set(val, (spacings.get(val) || 0) + 1);
      }
    });
  });
  return Array.from(spacings.entries()).sort((a, b) => b[1] - a[1]).slice(0, 20);
})()
```

### Look For
- Spacing values that don't follow a consistent scale (e.g., 4/8/12/16/24/32/48)
- Many one-off spacing values
- Inconsistent gaps between similar elements

## Responsive Testing Protocol

### Required Breakpoints

Test at minimum these 2 breakpoints (test more if time permits):

| Breakpoint | Width | Represents |
|-----------|-------|------------|
| Mobile | 375px | iPhone SE / small phone |
| Desktop | 1280px | Standard laptop |

Optional additional breakpoints:
| Breakpoint | Width | Represents |
|-----------|-------|------------|
| Tablet | 768px | iPad portrait |
| Wide | 1920px | Full HD desktop |

### Per-Breakpoint Checklist

At each breakpoint, check:

1. **No horizontal scrollbar** — `browser_evaluate`: `document.documentElement.scrollWidth > document.documentElement.clientWidth`
2. **No content overflow** — visual check for truncated text, overlapping elements
3. **Touch targets >= 44px on mobile** — `browser_evaluate` to measure button/link dimensions
4. **Navigation is accessible** — hamburger menu works, all links reachable
5. **Images scale correctly** — no overflow, maintain aspect ratio
6. **Text remains readable** — font sizes don't shrink below 14px on mobile
7. **Forms are usable** — input fields are full-width or appropriately sized

### Responsive Testing Workflow

```
1. browser_resize to 1280px height 800 → snapshot → extract styles → analyze
2. browser_resize to 375px height 667 → snapshot → extract styles → analyze
3. Compare extracted values between breakpoints
4. Document any layout breakages, overflow, or touch target issues
```

## Screenshot Protocol

Screenshots supplement text-based analysis. Use them for:
- Evidence of visual bugs (overlap, misalignment, overflow)
- Before/after comparisons at different breakpoints
- Documenting the overall layout at each tested breakpoint

**Do NOT rely on screenshots for:**
- Reading text content (use `browser_snapshot` for accessible text)
- Measuring sizes or colors (use `browser_evaluate` for computed values)
- Detailed UI analysis (use style extraction helpers)
