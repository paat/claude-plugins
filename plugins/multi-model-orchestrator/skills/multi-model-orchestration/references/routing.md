# Routing policy

Use the cheapest route that preserves one-shot delivery quality. Explicit user choices override
these defaults.

| Work | Primary route | Default effort | Escalate when |
|---|---|---|---|
| Exact rename, fixture, focused test, small config edit | GPT-5.6 Sol worker | low | Touchpoints are unclear or the first test exposes coupling |
| Bounded backend/data/API feature with clear acceptance | GPT-5.6 Sol worker | medium | Cross-module contracts, concurrency, or subtle compatibility appear |
| Multi-file refactor or difficult root-cause debugging | GPT-5.6 Sol worker | high | Evidence remains contradictory after a bounded investigation |
| Security, payments, destructive migration, subtle concurrency | Sol worker plus Opus advice | xhigh | Use max only when xhigh fails with new evidence |
| Ambiguous product intent, architecture, user-facing copy, UI/UX | Opus advice/controller | high or xhigh | Max only for exceptional unresolved design risk |
| CI/CD, dependency, environment, or build-system diagnosis | Opus advice, then bounded worker | high | Run independent Sol investigation when evidence conflicts |
| Final architecture/intent/scope review | Opus reviewer | xhigh | Max only after a concrete unresolved high-risk finding |
| Final technical adversarial review | GPT-5.6 Sol reviewer | high | Honor explicit xhigh/max/ultra; otherwise escalate only for high risk |

## Effort meanings

- `low`: localized, explicit, reversible, deterministic test available.
- `medium`: ordinary nontrivial implementation; several known files, clear contracts.
- `high`: real ambiguity, cross-module reasoning, hard debugging, or broad review.
- `xhigh`: high-impact correctness where competing explanations must be reconciled.
- `max`: exceptional unresolved work after a lower effort produced new evidence but no answer.
- `ultra` (Sol only): maximum reasoning with automatic task delegation. Use only when explicit or
  when a bounded, high-impact task benefits from independent internal fan-out.

## Hard routing rules

- Do not use effort as a substitute for a clear task packet.
- Do not use Ultra for routine workers, open-ended “find everything” review, or iterative cleanup.
- Keep fan-out depth at one. A worker does not commission another implementation worker.
- Prefer low/medium for well-specified implementation even when the overall project is important.
- Frontend/UI work still needs browser or screenshot evidence; model choice does not prove visual
  quality.
- For a difficult production diagnosis, independent Opus and Sol investigations may be more
  useful than raising one model to maximum effort.
- Re-route after repeated constraint violations, token/time runaway, scope spread, or no useful
  output. Do not retry by blindly raising effort.
