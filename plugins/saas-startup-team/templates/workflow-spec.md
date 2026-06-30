# Workflow: {{WORKFLOW_NAME}}

**Status:** Draft | Active | Missing | Deprecated
**Owner:** {{OWNER}}
**Last updated:** {{DATE}}

## Trigger / Entry Point

What starts this workflow: route, form, webhook, scheduled job, support action, or operator command.

## Actors

- Customer:
- Operator:
- System:
- External service:

## Happy Path

1. Step one.
2. Step two.
3. Successful terminal state.

## Validation Failures

- Input or precondition:
- Customer-visible message:
- Recovery action:

## Transient Failures

- Failure source:
- Retry/backoff:
- Timeout:
- Customer/operator state while waiting:

## Permanent Failures

- Failure source:
- Customer-visible state:
- Operator-visible state:
- Recovery or compensation:

## Partial Failure Cleanup / Compensation

What must be rolled back, retried, reconciled, refunded, or manually reviewed.

## Concurrent Conflict Behavior

Describe duplicate submissions, race conditions, idempotency keys, locks, and conflict resolution.

## State Model

| State | Entered By | Exited By | Customer Visible | Operator Visible |
|-------|------------|-----------|------------------|------------------|
| `state` | workflow step | workflow step | yes/no | yes/no |

## Handoff Contracts

| Boundary | Payload | Success Response | Failure Response | Timeout | Recovery |
|----------|---------|------------------|------------------|---------|----------|
| source -> target | TBD | TBD | TBD | TBD | TBD |

## Logs / Artifacts Expected

- Logs:
- Metrics:
- Files:
- Issues/support artifacts:

## QA Cases

- [ ] Happy path
- [ ] Validation failure
- [ ] Transient failure and retry
- [ ] Permanent failure
- [ ] Partial failure cleanup
- [ ] Concurrent duplicate/conflict
- [ ] Customer-visible state
- [ ] Operator-visible state
