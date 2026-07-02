# Comparison and Parallel Navigation

Use this playbook for legacy vs new, before vs after, desktop vs mobile, and variant comparisons.

## Default Comparison

1. Capture structured observations for URL A.
2. Capture structured observations for URL B.
3. Compare in the main session.

Do not delegate final severity or business meaning.

## Parallel Navigation

Parallel opencode calls require chrome-devtools MCP configured with isolated browser profiles. If isolation is not confirmed, run comparisons sequentially.

```bash
RUN_DIR=$(mktemp -d)
(opencode run -m "$MODEL" "...navigate URL A and return JSON..." > "$RUN_DIR/page-a.json") &
(opencode run -m "$MODEL" "...navigate URL B and return JSON..." > "$RUN_DIR/page-b.json") &
wait
```

## Compare

Compare:

- visible text and headings;
- form fields and validation;
- table/list columns and counts;
- primary actions;
- console/network errors;
- visual properties when visual mode is requested.

Load `visual-testing.md` for layout differences and screenshots.
