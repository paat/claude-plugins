# July 2026 Reddit evidence

This policy uses current practitioner reports as operational signals. These are anecdotes, not
controlled benchmarks; harness, prompt, repository, subscription, and server load are confounders.
Conflicting reports are preserved rather than turned into a permanent leaderboard.

## Strong recurring signals

- Sol low/medium is often sufficient for bounded technical work; highest effort is not reliably
  better. Sources: [Sol low sweet spot](https://www.reddit.com/r/OpenAI/comments/1usoe1c/comment/owpag2c/),
  [Ultra consumed a full allowance](https://www.reddit.com/r/OpenAI/comments/1usoe1c/comment/owpd1ya/),
  [selected debug tasks where medium beat high](https://www.reddit.com/r/codex/comments/1uy9eax/codex_wasnt_a_good_fit_for_gpt56_so_i_built_a/).
- Sol is repeatedly favored for bounded backend/logic execution and technical contradiction
  hunting; Claude is repeatedly favored for product intent, UI, and orchestration visibility.
  Sources: [backend/UI routing](https://www.reddit.com/r/claude/comments/1uv0ju4/gpt_56_big_improvement_overall_but_claude_still/),
  [mixed GPT-5.6 vs Claude reports](https://www.reddit.com/r/ClaudeCode/comments/1uuow9o/for_fable_users_how_are_you_finding_gpt56/),
  [Opus delegates implementation to GPT-5.6](https://www.reddit.com/r/ClaudeAI/comments/1uulhd9/comment/ox4awvk/).
- Opus effort should scale with ambiguity and coupling. High/xhigh helps planning and cross-module
  work; max often overthinks without improving coding. Sources:
  [Opus routing by effort](https://www.reddit.com/r/ClaudeAI/comments/1umo1q3/comment/ovdnssk/),
  [high adequate; max exceptional](https://www.reddit.com/r/ClaudeAI/comments/1uraypd/comment/oweet3c/).
- Cross-model final review is useful, but reviewer findings need code/test evidence. Sources:
  [Sol adversarial review workflow](https://www.reddit.com/r/claude/comments/1uuptnr/gpt_56_sol_xhigh_in_claude_code_workflow/),
  [GPT-5.6 caught mistakes in Claude output](https://www.reddit.com/r/ClaudeCode/comments/1uwie3b/comment/oxjb6gt/).

## Ultra-specific warning

July reports describe successful Ultra output, but also quota exhaustion, recursive delegation,
speculative findings, and multi-day failure to finish. Sources:

- [Ultra reviewer derailed an autonomous workflow](https://www.reddit.com/r/ClaudeCode/comments/1usy759/chatgpt_56_broke_my_claude_code_epic_orchestrator/)
- [72 hours of Sol Ultra](https://www.reddit.com/r/codex/comments/1uw1179/72_hours_of_sol_ultra/)
- [recursive review/fix loop](https://www.reddit.com/r/ClaudeCode/comments/1uwie3b/comment/oxjezil/)
- [Ultra thoroughness described as overkill](https://www.reddit.com/r/codex/comments/1uvfsa6/claude_code_to_codex/)

Therefore explicit Ultra requests are honored, but the runner prompt must impose one pass, a
finding cap, realistic reachability, a severity threshold, and a stop condition.

## Evidence gaps

- No July controlled benchmark compares all effort levels on the same orchestration task.
- No July controlled benchmark proves dual Opus + Sol review reduces production defects.
- Reports conflict on planning, debugging, documentation reading, and large-repository reliability.
- The routing policy must remain adaptive and evidence-gated rather than claiming one universal
  winner.
