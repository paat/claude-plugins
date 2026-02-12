# AI Browser Testing Workflows

## Playwright MCP Integration

The dominant approach for browser testing with Claude Code. Uses accessibility tree
snapshots instead of screenshots -- 2-5KB of structured data, 10-100x faster than
screenshot-based approaches.

### Setup
1. Install `@playwright/mcp`
2. Connect to Claude Code via MCP config
3. Claude navigates pages, clicks buttons, fills forms, observes results

### Key Advantage
Accessibility tree snapshots:
- 2-5KB structured data (vs 500KB-2MB screenshots)
- 10-100x faster than vision-based approaches
- Claude reads DOM structure, not pixels

## Testing Workflows

### Test Generation from Requirements
1. Feed requirements/user stories to Claude
2. Claude generates Playwright test files
3. Run tests, Claude analyzes failures
4. Claude fixes tests and implementation iteratively

### Self-Healing Locators
- Claude adapts selectors when UI changes
- Uses accessibility tree to find stable selectors
- Reduces maintenance burden on test suites

### AI QA Engineer Pattern (alexop.dev)
Claude acts as automated QA engineer:
1. Reads requirements
2. Writes test scenarios
3. Executes via Playwright MCP
4. Analyzes failures
5. Collaborates in real-time with developer

## Playwright MCP Servers (2026)

| Server | Approach | Best For |
|--------|----------|----------|
| @playwright/mcp (official) | Accessibility tree | Standard web testing |
| browser-use | Hybrid vision + DOM | Complex visual testing |
| stagehand | AI-native selectors | Dynamic content |
| browserbase | Cloud browsers | Scale testing |
| Puppeteer MCP | CDP protocol | Chrome-specific |
| midscene | Visual AI | Visual regression |

## Playwright Skill Plugin
**GitHub**: [lackeyjb/playwright-skill](https://github.com/lackeyjb/playwright-skill)

Model-invoked skill: Claude autonomously writes and executes custom Playwright
automation for testing and validation. Not just running pre-written tests --
Claude generates the test code dynamically based on the task.

## Multi-Model Browser Testing Strategy

For token optimization in browser testing workflows:

1. **Haiku** for initial page exploration (reading DOM, listing elements)
2. **Sonnet** for test generation and fixing failing tests
3. **Opus** for debugging complex test failures and flaky test analysis
4. **Ralph loop** for iteratively fixing all failing tests overnight

### Workflow
```
Opus: Analyze requirements, plan test strategy
  |
  +-> Sonnet: Generate Playwright test files
  +-> Haiku: Run tests, collect results
  |
  +-> Sonnet: Fix failing tests (Ralph loop)
  |
Opus: Review final test coverage and quality
```

## Browser Testing + Ralph Loop

Combining Ralph with Playwright for autonomous test fixing:

```bash
# PROMPT.md for Ralph browser test loop
1. Read failing test results from test-results/
2. Identify the root cause of each failure
3. Fix either the test or the implementation
4. Run `npx playwright test` to verify
5. Commit passing changes
6. Repeat until all tests pass
```

Exit condition: All Playwright tests pass with 0 failures.

## MCP Tool Search Integration

Playwright and Puppeteer tools load on-demand when browser automation is needed.
Keep context free for other tasks when not doing browser testing.

Enable: `ENABLE_TOOL_SEARCH=1`

## Sources

- [Playwright MCP Claude Code | testomat.io](https://testomat.io/blog/playwright-mcp-claude-code/)
- [lackeyjb/playwright-skill | GitHub](https://github.com/lackeyjb/playwright-skill)
- [Browser Automation | claudefast](https://claudefa.st/blog/tools/mcp-extensions/browser-automation)
- [AI QA Engineer | alexop.dev](https://alexop.dev/posts/building_ai_qa_engineer_claude_code_playwright/)
- [6 Playwright MCP servers | Bug0](https://bug0.com/blog/playwright-mcp-servers-ai-testing)
- [Tests with Claude Code | Momentic](https://momentic.ai/blog/what-tests-look-like-with-claude-code)
- [Playwright MCP AI Testing | testleaf](https://www.testleaf.com/blog/playwright-mcp-ai-test-automation-2026/)
