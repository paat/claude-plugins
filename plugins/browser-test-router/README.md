# browser-test-router

Multi-model delegation plugin for browser testing workflows. Routes mechanical browser work to cheaper models, saving 45-60% of tokens on browser-heavy testing sessions.

## Problem

Claude Max subscriptions deplete tokens quickly when Opus handles everything — including zero-reasoning browser work like URL navigation, form filling, and screenshot capture.

## Solution

Route each task to the cheapest capable model:

| Task Type | Model | Cost vs Opus |
|-----------|-------|--------------|
| Navigation, health checks, screenshots | Haiku | 7% (93% savings) |
| Form filling, button clicking, login/logout | Haiku | 7% (93% savings) |
| Side-by-side page comparison | Sonnet | 20% (80% savings) |
| Spec parsing, gap classification, issue drafting | Opus (inline) | 100% (no savings) |

## Installation

```
/install browser-test-router
```

## Usage

### Command

```
/browser-test-router:browser-test [url_or_module]
```

### Standalone — test a single URL

```
/browser-test-router:browser-test https://example.com
```

### With acceptance-test skill — full module testing

Add the model routing section to your project's acceptance-test skill, then:

```
/acceptance-test crm
```

The skill will automatically delegate mechanical operations to Haiku and comparisons to Sonnet.

## Agents

| Agent | Model | Purpose |
|-------|-------|---------|
| `page-navigator` | Haiku | Navigate URLs, health checks, element inventory |
| `form-operator` | Haiku | Fill forms, click buttons, session management |
| `page-comparator` | Sonnet | Structural diff of two page snapshots |
| `test-analyst` | Opus | Gap classification, issue drafting (standalone use) |

## Delegation Pattern

```
Opus (orchestrator)
  ├── Task(haiku) → navigate legacy page  ─┐
  ├── Task(haiku) → navigate new page     ─┤
  │                                        ├→ Task(sonnet) → compare
  │                                        │
  └── Opus inline: analyze comparison, classify gaps, draft issues
```

## Advisory Hook

The plugin includes a PreToolUse hook that suggests delegation when Opus is about to run curl or browser commands directly. Advisory only — never blocks execution.

## Dependencies

- bash 4+
- curl (for health checks)
- Browser automation tool (Playwright MCP or equivalent) for screenshots

## Integration

This plugin provides the generic delegation pattern. Project-specific testing skills reference the pattern and map their own variables (URLs, routes, test accounts). See `skills/browser-test-orchestration/SKILL.md` for the full protocol and integration instructions.
