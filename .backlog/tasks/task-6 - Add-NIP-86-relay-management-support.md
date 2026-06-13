---
id: TASK-6
title: Add NIP-86 relay management support
status: To Do
assignee: []
created_date: "2026-06-13 13:16"
updated_date: "2026-06-13 13:16"
labels:
  - relay
  - nip
  - needs-planning
  - from-todo
dependencies: []
references:
  - TODO.md
  - nips/86.md
priority: medium
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Add relay management behavior required by NIP-86 while preserving existing relay policy and operational logging conventions.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 NIP-86 management operations supported by this relay are implemented according to the local spec.
- [ ] #2 Unsupported or unauthorized management requests are rejected consistently and logged with useful context.
- [ ] #3 Tests cover successful operations, authorization failures, and malformed requests.
- [ ] #4 Relay behavior remains compatible with existing message handling outside the management surface.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` relay item "Support NIP-86" during TODO-to-Backlog conversion.

Type: AFK.
Context: this may overlap with broader relay administration work; planning should check existing admin/auth conventions before implementation.
Constraints: use `nips/86.md` as source of truth and keep management authorization explicit.

<!-- SECTION:NOTES:END -->
