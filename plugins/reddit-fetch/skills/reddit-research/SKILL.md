---
name: reddit-research
description: This skill should be used when the user asks to "research on reddit", "what does reddit say about", "reddit opinions on", "search reddit for", "check reddit for", "reddit discussion about", "reddit recommendations for", "community feedback on", "what do people think about", "has anyone on reddit", or needs real-world user experiences, community opinions, troubleshooting solutions, or tool/product comparisons from Reddit. Also applies when Claude's WebFetch cannot access Reddit content.
---

# Reddit Research via Gemini CLI

Research any topic using Reddit by delegating web searches to Gemini CLI, which has full web access and can fetch Reddit content that Claude's WebFetch cannot.

## Prerequisites

Gemini CLI must be installed (`npm install -g @google/gemini-cli`) and authenticated. Run `gemini` interactively once to complete OAuth login.

Enable preview features in `~/.gemini/settings.json` to use `gemini-3-flash-preview`:

```json
{
  "general": {
    "previewFeatures": true
  }
}
```

## How It Works

Gemini CLI has web access and can search, read, and summarize Reddit content. Construct prompts that instruct Gemini to:
1. Search Reddit for the given topic
2. Find relevant threads and discussions
3. Extract key opinions, advice, and consensus
4. Return structured findings

## Crafting Effective Reddit Prompts

### Basic Research Prompt

```bash
timeout 120 gemini -m gemini-3-flash-preview -p "Search Reddit for discussions about [TOPIC]. Find the most relevant and recent threads. For each thread, provide: the subreddit, thread title, key opinions and advice from top comments, and any consensus or disagreements. Focus on practical, experience-based insights." -o text 2>/dev/null
```

### Targeted Subreddit Prompt

When the topic maps to a known subreddit, specify it:

```bash
timeout 120 gemini -m gemini-3-flash-preview -p "Search r/[SUBREDDIT] for discussions about [TOPIC]. Summarize the top threads, common recommendations, and community consensus." -o text 2>/dev/null
```

### Comparison/Recommendation Prompt

For "X vs Y" or "best tool for Z" queries:

```bash
timeout 120 gemini -m gemini-3-flash-preview -p "Search Reddit for comparisons of [X] vs [Y]. Find threads where users share real-world experience with both. Summarize: which one users prefer and why, common pros/cons mentioned, and any dealbreakers people report." -o text 2>/dev/null
```

### Troubleshooting Prompt

For debugging or problem-solving:

```bash
timeout 120 gemini -m gemini-3-flash-preview -p "Search Reddit for people who experienced [PROBLEM/ERROR]. Find threads with solutions that worked. Summarize: what caused the issue, which solutions were confirmed working, and any workarounds." -o text 2>/dev/null
```

## Prompt Construction Guidelines

- Always include "Search Reddit" in the prompt so Gemini knows to look at Reddit specifically
- Request structured output (thread titles, subreddits, key points)
- Ask for "recent" threads when freshness matters
- Specify subreddits when the domain is clear (e.g., r/programming, r/homelab, r/selfhosted)
- Request "experience-based" or "practical" insights to filter out speculation
- For technical topics, ask Gemini to prioritize threads with confirmed solutions

## Model and Timeout

- **Model**: Always use `-m gemini-3-flash-preview` — fast enough for research, good at web search
- **Timeout**: Use `timeout 120` for standard research, `timeout 180` for broad or multi-topic queries
- **Output**: Always use `-o text 2>/dev/null` for clean output. When troubleshooting, remove `2>/dev/null` to see Gemini CLI error messages

## Presenting Results

After receiving Gemini's response:

1. **Label the source** — Clearly indicate this comes from Reddit via Gemini
2. **Structure the findings** — Organize by theme, subreddit, or relevance
3. **Highlight consensus** — Note where multiple threads agree
4. **Flag caveats** — Reddit opinions may be biased, outdated, or anecdotal
5. **Add own analysis** — Synthesize findings with own knowledge

Example output format:

```
## Reddit Research: [Topic]

*Sourced from Reddit via Gemini CLI*

### Key Findings

**Community consensus:** [summary]

**Popular recommendations:**
- [item 1] — mentioned in r/subreddit, r/subreddit2
- [item 2] — recommended by multiple users in r/subreddit

**Common concerns:**
- [concern 1]
- [concern 2]

**Notable threads:**
- r/subreddit: "[thread title]" — [key takeaway]
- r/subreddit: "[thread title]" — [key takeaway]

### Caveats
- Reddit opinions are anecdotal and may not reflect current state
- Results depend on Gemini's web search coverage
```

## Error Handling

| Error | Action |
|---|---|
| Empty response | Retry with more specific subreddit or rephrased query |
| Auth errors | Tell user to run `gemini` interactively to re-authenticate |
| Timeout | Increase to 180s; if still fails, narrow the search scope |
| Model not found | Fall back to `gemini-2.5-flash`. User may need to enable `previewFeatures` in `~/.gemini/settings.json` |
| Gemini unavailable | Inform user; suggest they try WebSearch or manual Reddit browsing |

If Gemini is unavailable, do not block the workflow. Proceed with available tools and note the limitation.
