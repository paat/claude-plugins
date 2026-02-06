---
allowed-tools: Bash(gemini:*)
description: Research any topic using Reddit via Gemini CLI
argument-hint: <topic to research on Reddit>
---

Research a topic by searching Reddit via Gemini CLI. Gemini has web access and can fetch Reddit content that Claude's WebFetch cannot.

## Instructions

The user wants to research the following topic on Reddit:

**Topic:** $ARGUMENTS

## Steps

1. Analyze the topic and determine the best search approach:
   - If the topic maps to specific subreddits, include them in the prompt
   - If it's a comparison ("X vs Y"), use comparison framing
   - If it's troubleshooting, focus on threads with solutions
   - Otherwise, use a general research prompt

2. Run the Gemini command with a Reddit-focused prompt:
   ```bash
   timeout 120 gemini -m gemini-3-flash-preview -p "Search Reddit for discussions about TOPIC. Find the most relevant and recent threads. For each thread, provide: the subreddit, thread title, key opinions and advice from top comments, and any consensus or disagreements. Focus on practical, experience-based insights rather than speculation." -o text 2>/dev/null
   ```

   Replace TOPIC with the user's actual topic, expanding it into a clear search query.

3. If the response is empty or an error occurs:
   - Retry once with a rephrased or more specific query
   - If a "model not found" error occurs, retry with `-m gemini-2.5-flash` (stable fallback)
   - If Gemini is still unavailable, inform the user and suggest alternatives (WebSearch, manual browsing)

4. Present the findings in a structured format:

   ```
   ## Reddit Research: [Topic]

   *Sourced from Reddit via Gemini CLI*

   ### Key Findings
   [Organized summary of what Reddit discussions reveal]

   ### Popular Recommendations
   [Bullet points of common advice/recommendations]

   ### Common Concerns
   [Issues or caveats people mention]

   ### Notable Threads
   [Specific threads worth reading, with subreddit and title]

   ### Caveats
   - Reddit opinions are anecdotal and may not reflect current state
   ```

5. After presenting Reddit's findings, add own analysis or synthesis where relevant — note agreements or disagreements with the Reddit consensus.
