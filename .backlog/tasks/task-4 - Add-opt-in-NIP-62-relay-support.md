---
id: TASK-4
title: Add opt-in NIP-62 relay support
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
  - nips/62.md
priority: medium
ordinal: 4000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Add NIP-62 relay behavior behind explicit opt-in configuration so the relay can support the NIP without changing default behavior unexpectedly.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 NIP-62 behavior is disabled by default unless explicit relay configuration enables it.
- [ ] #2 Enabled NIP-62 behavior follows the authoritative local NIP specification.
- [ ] #3 Tests cover disabled, enabled, and invalid-input paths.
- [ ] #4 Operational or policy failures log enough context to debug relay behavior.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` relay item "Opt-in NIP-62 support" during TODO-to-Backlog conversion.

Type: AFK.
Context: the original TODO explicitly says opt-in, so default relay behavior should remain unchanged unless planning discovers an existing project convention that says otherwise.
Constraints: use `nips/62.md` as source of truth and follow current relay configuration style.

<!-- SECTION:NOTES:END -->
