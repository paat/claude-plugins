# CRUD Testing

Use this playbook for create/read/update/delete lifecycles.

## Create

1. Main session designs test data from the spec.
2. Browser executor inventories form fields.
3. Browser executor fills and submits with explicit field values.
4. Main session evaluates result against acceptance criteria.

## Read

Verify created data appears in the expected list/detail views, with expected columns, labels, filters, and empty states.

## Update

Choose one meaningful field, submit an update, reload or revisit the record, and confirm persistence.

## Delete

Check confirmation, cancel path, successful delete path, and whether the result should be hard delete, soft delete, cascade, or blocked by dependencies.

## Report

For each operation, include action, input, observed result, expected result, and pass/fail.
