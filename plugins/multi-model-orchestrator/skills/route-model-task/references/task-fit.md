# Task fit and effort

These are source-backed starting candidates, not measured cross-provider winners. Choose
the complexity/risk tier first; a task label never lowers it. Prefer repeated local results
over vendor positioning. Evidence and limits: `evidence-2026-10.md` (load only when needed).

## Task matrix

| Task and acceptance | Starting candidates and effort | Selection rule |
|---|---|---|
| Mechanical edits, extraction, triage with an exact check | GPT-6 Luna `low`; existing local/Flash T1 routes | Use the cheapest route that passes the check. Local `default` needs an identified served model; its name alone proves no capability. |
| Well-specified implementation and tests | Sonnet 5.5 `medium` or GPT-6.1 Sol `medium` | Sonnet has explicit bounded-agent guidance; Sol has technical-work guidance. Use local results/headroom when neither is distinguished by the task. |
| Tight tool loops, cost-sensitive subagents, bounded reproduction | Muse Spark 1.3 `medium`; Grok 4.7 `medium` | Spark is positioned for short economical workloads; Grok is another implementation/reproduction candidate. Use `low` for genuinely simple calls, not a whole ambiguous feature. |
| Cross-module debugging, subtle root cause, refactor | GPT-6.1 Sol `high`, GPT-6 Astra `high`, Opus 5.5 `high`, or Argon `high` | Select from T3. Argon has engineering/debugging evidence; no inspected source proves it always beats the peers. Require executable reproductions and regression tests. |
| Contained architecture advice vs broad delivery | Opus 5.5 `medium` for contained advice; Astra `medium` for broad-context delivery; `high` for harder integration | Do not inherit Opus 5's `high` merely from its name. Keep T3 eligibility even when choosing a lower effort for a clear task. |
| Polished frontend, connected visual systems, conflicting design evidence | GPT-6.1 Sol `xhigh` when those demands are real; `medium` for ordinary frontend edits | OpenAI explicitly recommends this task/effort pairing. It is not proof of a universal UI winner. Require screenshot/browser tools and rendered acceptance; text coding scores cannot establish visual fidelity. |
| Sustained multi-file or multi-hour implementation | Muse Wonder Full 1.0 `high`; existing Opus/Astra T3 routes; Fable 5.1 `high` when unusually hard | Full is an explicit model, not Spark or plain Wonder with more effort. Fable remains a direct, outside-pool route after restriction/usage checks. Start with a bounded packet and checkpoints. |
| Source research and evidence reconciliation | Grok 4.7 `medium`, Sonnet 5.5 `medium`, or Muse Spark 1.3 `medium`; escalate for conflicting evidence | Require the runner's research mode and web/source access. agy has no research mode in this plugin. Source verification matters more than unsupported provider stereotypes. |
| Security, payments, destructive migration, subtle concurrency | Existing T4 Astra/Opus routes at `xhigh` | Preserve the high-risk floor, independent provider and executable validation. Vendor security anecdotes alone do not promote a new model to T4. |
| Adversarial review | Eligible model from another provider, task tier and at least T2; `medium` for bounded diffs, `high` for deep reasoning, T4 as above | Pick by defect/tool requirements. agy and local reviews remain advisory; higher effort cannot turn them into executing reviewers. Different providers do not guarantee independent errors. |

## Applying the choice

1. Check hard restrictions, role, required tools/modality and tier. If evidence cannot separate
   eligible candidates, retain pool order/headroom; do not invent a benchmark score.
2. Pass the candidate as `--prefer <exact-model>` to both pool `pick` and `run`. This is a soft
   preference within each tier, ahead of spare-usage ordering, not a hard pin or a tier jump.
   Prefer a provider instead of the ambiguous model name `default`.
3. Treat the returned row as the model/effort that pool execution will use. If the task needs
   a different supported effort, select eligibility through `pick` first and record a direct
   runner command with `--model` and `--effort`. Do not choose one effort and execute another.
   On unavailability, re-evaluate the remaining allowed candidates under the same tier/usage
   constraints; explicit user pins must never be replaced automatically.
4. Measure the acceptance check and total delivery time, including review and repair. Raise
   effort only for a specific reasoning gap; fix missing context/tools or an unavailable
   provider directly. Change one variable at a time, not model and effort together.

Examples (restrictions and usage snapshot must also be forwarded):

```bash
pool.sh pick --tier T3 --prefer gemini-4-argon --usage usage.txt
pool.sh run --tier T3 --prefer gemini-4-argon --usage usage.txt --repo . < task.txt
# A demanding visual task may choose Sol at xhigh after this eligibility check:
pool.sh pick --tier T3 --prefer gpt-6.1-sol --usage usage.txt
# Only if Sol was selected and the task justifies xhigh:
run-codex.sh --mode implement --repo . --model gpt-6.1-sol --effort xhigh < task.txt
```

## Effort is provider- and transport-specific

- Sonnet 5.5: `medium` for specified agentic coding; `high` for harder/longer tasks. Its API
  default is `high`, while Opus 5.5's is `medium`; neither dictates every task's setting.
- Codex: Luna `low` for narrow edits, Sol `medium` for technical work, Sol `xhigh` for demanding
  visual/evidence work, Astra `medium` for broad projects. Higher settings need task evidence.
- Grok: `low` for simple tool use, `medium` for analysis, `high` for difficult multistep work;
  `xhigh` on 4.6/4.7 only when its extra latency is justified.
- agy: `low` for simple edits, `medium` for ordinary engineering, `high` for subtle bugs and
  multi-file changes. Flash and Argon expose only those three levels here.
- Muse: use the plugin's `minimal`–`max` range. The CLI's higher/default settings and vendor
  `max` benchmark scores do not establish the cheapest successful setting for this task.
- The strict catalog describes **this plugin's** supported surface: Haiku omits effort,
  local effort is wrapper-controlled, and `ultra` is Astra-only even if upstream supports more.
