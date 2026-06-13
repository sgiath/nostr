---
id: TASK-14
title: Implement pay-to-relay
status: To Do
assignee: []
created_date: "2026-06-13 13:18"
updated_date: "2026-06-13 13:18"
labels:
  - relay
  - payment
  - needs-decision
  - from-todo
dependencies:
  - TASK-9
references:
  - TODO.md
  - nips/11.md
priority: medium
ordinal: 14000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Design and implement pay-to-relay behavior so relay access can be gated by payment while remaining consistent with relay policy and NIP-11 disclosure.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 A pay-to-relay flow is selected and documented in the task notes or follow-up decision record before implementation proceeds.
- [ ] #2 Relay actions that require payment are blocked until payment requirements are satisfied.
- [ ] #3 Payment-gated rejection and success paths produce useful operational logs.
- [ ] #4 Tests cover unpaid, paid, expired or invalid payment, and disabled pay-to-relay behavior.
- [ ] #5 NIP-11 relay information accurately reflects payment requirements.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` relay item "implement pay-to-relay" during TODO-to-Backlog conversion.

Type: HITL.
Blocked by: `TASK-9`, which establishes enforcement of the NIP-11 `payment_required` gate before broader payment mechanics are layered on.
Context: payment flow details were not present in `TODO.md`; planning must choose the payment model before implementation.
Constraints: keep relay access behavior and NIP-11 metadata consistent.

<!-- SECTION:NOTES:END -->
