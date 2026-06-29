---
allowed-tools: Bash, Read
description: Pure-reasoning critic via Codex/gpt-5.5 — paste the artifact + context, no repo access needed
argument-hint: <question or topic> [--model <id>]
---

Use the OpenAI Codex CLI (`codex exec`, gpt-5.5) as a **pure-reasoning critic**. Unlike `/codex-review`, this needs no filesystem access — you paste the full artifact and context into the prompt. Good for "critique this methodology", "poke holes in this design", "review this self-contained snippet", "stress-test this argument".

**Question / topic:** $ARGUMENTS

## Steps

1. **Assemble the full context into the prompt.** Codex will reason only about what you paste — there is no repo walk here. Include the artifact (plan text, methodology, snippet, decision) and the specific question you want pressure-tested. Optional `--model <id>`.

2. **Dispatch as a critic.** Pass everything on stdin. The wrapper's default `-s danger-full-access` is fine (it sidesteps the broken bwrap sandbox and passes Claude Code's classifier); Codex simply won't touch the FS because the prompt is self-contained:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" [--model <id>] --timeout 300 <<'PROMPT'
   You are a sharp, skeptical critic. Pressure-test the following. Be specific and
   concrete; prefer naming real flaws over hedging. If something is sound, say so.

   QUESTION: <the user's question>

   CONTEXT / ARTIFACT:
   <paste the full methodology / design / snippet / argument here>

   Give: (1) the strongest objections, (2) hidden assumptions or failure modes,
   (3) what you'd change, ranked by impact.
   PROMPT
   ```

   Use a Bash-tool `timeout` of at least 300000 ms to match `--timeout 300`.

3. **Synthesize.** Present Codex's critique, then your own assessment — where you agree (higher confidence), where you push back and why, and a unified recommendation. Don't just relay; reconcile.

4. If Codex is unavailable, give your own critique and note Codex was unavailable.

## Notes

- No `--dir` / repo walking — this is deliberately context-only. If the critique would benefit from Codex reading the real source tree, use `/codex-review` instead.
