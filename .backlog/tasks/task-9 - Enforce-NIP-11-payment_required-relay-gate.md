---
id: TASK-9
title: Enforce NIP-11 payment_required relay gate
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
ordinal: 9000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Enforce the relay information document's `payment_required` limitation before relay actions that require payment authorization.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 Relay actions covered by `payment_required` are gated before processing continues.
- [ ] #2 Rejected actions produce protocol-appropriate responses and log useful payment-gate context.
- [ ] #3 Tests cover allowed and rejected actions with the payment gate enabled and disabled.
- [ ] #4 NIP-11 relay information remains consistent with the enforced behavior.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` relay item "NIP-11 limitation: enforce `payment_required` gate before relay actions" during TODO-to-Backlog conversion.

Type: AFK.
Context: this task is a narrow NIP-11 policy enforcement slice and may later support pay-to-relay work.
Constraints: use `nips/11.md` as source of truth and inspect existing relay action/message pipeline before planning.

<!-- SECTION:NOTES:END -->
