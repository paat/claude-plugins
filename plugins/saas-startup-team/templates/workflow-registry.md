# Workflow Registry

This registry maps product workflows to routes, jobs, states, handoff contracts, and QA coverage.

## By Workflow

| Workflow | Spec | Status | Owner | QA Coverage |
|----------|------|--------|-------|-------------|
| Example workflow | `.startup/workflows/WORKFLOW-example.md` | Missing | TBD | Missing |

## By Component

| Component | Workflows | Notes |
|-----------|-----------|-------|
| `path/or/service` | Example workflow | Add routes, jobs, workers, services, migrations, or external systems here. |

## By User Journey

| Journey | Workflows Triggered | Customer/Operator State |
|---------|---------------------|-------------------------|
| Example journey | Example workflow | What the user or operator sees. |

## By State

| State | Entered By | Exited By | Workflows |
|-------|------------|-----------|-----------|
| `state-name` | Trigger/workflow | Trigger/workflow | Example workflow |

## By Handoff Contract

| Boundary | Payload | Success | Failure | Timeout | Recovery |
|----------|---------|---------|---------|---------|----------|
| system A -> system B | TBD | TBD | TBD | TBD | TBD |

## Missing Workflows

Use this section when code reveals a workflow that has not been specified yet.

- [ ] `WORKFLOW-<slug>.md` - why it is missing and who should fill it.
