---
id: TASK-1
title: Add NIP-05 relay verification policy
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
  - nips/05.md
priority: medium
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Add relay-side support for NIP-05 identity verification policy so the relay can verify DNS-based identities where required and enforce configured domain allow/deny behavior.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 Relay configuration can require NIP-05 verification before accepting relevant relay actions.
- [ ] #2 Relay configuration supports allow and deny domain policy for NIP-05 checks.
- [ ] #3 Verification failures are rejected with useful context logged for debugging.
- [ ] #4 Targeted tests cover allowed, denied, missing, and failed verification cases.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` relay item "NIP-05 support (configure DNS verification as required, allow/deny domains)" during TODO-to-Backlog conversion.

Type: AFK.
Context: `nips/` is read-only and authoritative for NIP behavior; future planning should inspect relay acceptance/policy pipeline before implementation.
Constraints: preserve project JSON rule (`JSON` only), use TDD where practical, and add operational/error logging for rejected or failed verification paths.

<!-- SECTION:NOTES:END -->
