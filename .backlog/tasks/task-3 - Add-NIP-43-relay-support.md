---
id: TASK-3
title: Add NIP-43 relay support
status: To Do
assignee: []
created_date: "2026-06-13 13:15"
updated_date: "2026-06-13 13:15"
labels:
  - relay
  - nip
  - needs-planning
  - from-todo
dependencies: []
references:
  - TODO.md
  - nips/43.md
priority: medium
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Add relay behavior needed for NIP-43 support, grounded in the authoritative local NIP specification and existing relay pipeline conventions.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 Relay behavior required by NIP-43 is implemented or explicitly rejected where out of scope.
- [ ] #2 Relevant event handling, validation, or policy paths are covered by targeted tests.
- [ ] #3 Operational failures or rejected inputs log enough context to diagnose issues.
- [ ] #4 Implementation remains compatible with existing relay behavior unless the NIP requires a documented change.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` relay item "NIP-43 support" during TODO-to-Backlog conversion.

Type: AFK.
Context: future planning should inspect current relay event validation and message handling before choosing the implementation shape.
Constraints: `nips/` is read-only; use local NIP spec as source of truth.

<!-- SECTION:NOTES:END -->
