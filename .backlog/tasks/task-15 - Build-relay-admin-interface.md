---
id: TASK-15
title: Build relay admin interface
status: To Do
assignee: []
created_date: "2026-06-13 13:18"
updated_date: "2026-06-13 13:18"
labels:
  - relay-admin
  - admin
  - needs-decision
  - from-todo
dependencies: []
references:
  - TODO.md
priority: medium
ordinal: 15000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Build an administrative interface for operating the relay and managing relay configuration or policy through supported admin workflows.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 Relay administrators have an authenticated admin surface for the selected initial relay management workflows.
- [ ] #2 The interface exposes useful relay state or policy management without requiring manual config-file edits for supported workflows.
- [ ] #3 Admin failures and unexpected exceptions are logged with enough context to debug.
- [ ] #4 Tests cover the initial admin workflows and authorization boundaries.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` relay admin item "admin interface for the relay" during TODO-to-Backlog conversion.

Type: HITL.
Context: this is intentionally broad and should be planned as an initial usable admin slice, not a full admin product in one pass.
Constraints: future planning should inspect the existing `relay-admin/` project and align scope with relay administration tasks such as `TASK-12` and `TASK-13`.

<!-- SECTION:NOTES:END -->
