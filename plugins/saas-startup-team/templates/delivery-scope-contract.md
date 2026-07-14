# Delivery Scope Contract

- The accepted requirements and mandatory triggered gates define `Done`.
- `Preserve` covers named invariants and all existing behavior not changed by `Done`; `Out of Scope` covers every unrelated change.
- Use the smallest complete change consistent with the existing architecture. Do not add features, dependencies, abstractions, refactors, fallbacks, or generalized edge-case machinery unless `Done` requires them.
- Expand scope only when a reproduced failure, log, or test proves an adjacent issue causally blocks `Done`. Otherwise list it under `Not Addressed`; do not investigate or fix it.
- Validate changed and affected paths plus mandatory existing gates. Fix failures caused by the diff; report unrelated or pre-existing failures without changing unrelated code.
- Do not begin a general or recursive audit. Once `Done` and mandatory gates pass, stop product investigation and mutation; complete the required handoff or report, then exit.
