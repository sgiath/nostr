---
id: TASK-10
title: Enforce NIP-11 restricted_writes EVENT gate
status: To Do
assignee: []
created_date: "2026-06-13 13:17"
updated_date: "2026-06-13 13:17"
labels:
  - relay
  - nip-11
  - policy
  - needs-planning
  - from-todo
dependencies: []
references:
  - TODO.md
  - nips/11.md
priority: medium
ordinal: 10000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Enforce the relay information document's `restricted_writes` limitation when accepting EVENT messages.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 EVENT acceptance checks apply the configured `restricted_writes` policy before persistence or downstream processing.
- [ ] #2 Rejected EVENT messages receive protocol-appropriate responses and are logged with relevant policy context.
- [ ] #3 Tests cover permitted and rejected EVENT acceptance paths with restricted writes enabled and disabled.
- [ ] #4 NIP-11 relay information remains consistent with the enforced write policy.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` relay item "NIP-11 limitation: enforce `restricted_writes` policy gate for EVENT acceptance" during TODO-to-Backlog conversion.

Type: AFK.
Context: this is a narrow EVENT acceptance policy slice.
Constraints: use `nips/11.md` as source of truth and keep rejection behavior consistent with existing relay protocol responses.

<!-- SECTION:NOTES:END -->
