## Definition-of-Done Checklist (additional items)

- **reachability.md** — if this change touches the deployment, concurrency, or
  session model, update `reachability.md` (and its `last-verified:` marker) in
  this PR. See `references/tech-founder/reachability-convention.md`.
- **Tribunal step-back** — from review round 3, stop adding guards: simplify,
  descope (remove the mechanism + file a follow-up), or take the finding class
  to the arbiter. A step-back round must not increase the net count of
  defensive mechanisms. See `tribunal-review:closing-tribunal-loop`.
