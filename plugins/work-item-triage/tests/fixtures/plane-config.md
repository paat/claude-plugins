---
sources:
  # Commands implement the work-item-triage adapter contract.
  - name: plane
    list: "plane-stub list" # Page argument is appended.
    show: 'plane-stub show' # Item id is appended.
models:
  default: test-model
---

# Test repository configuration

The sibling models block is outside the source mapping.
