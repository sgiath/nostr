---
id: TASK-13
title: Add NIP-29 relay groups admin interface
status: To Do
assignee: []
created_date: "2026-06-13 13:17"
updated_date: "2026-06-13 13:17"
labels:
  - relay
  - relay-admin
  - nip
  - needs-planning
  - from-todo
dependencies:
  - TASK-11
references:
  - TODO.md
  - nips/29.md
priority: medium
ordinal: 13000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Add administrative management for NIP-29 relay groups using database-backed relay administration storage and existing admin conventions.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 Administrators can view and manage NIP-29 relay group data through the chosen admin surface or API.
- [ ] #2 Relay behavior uses the managed group data consistently with NIP-29 requirements.
- [ ] #3 Tests cover group administration behavior and relay-side effects.
- [ ] #4 Operational failures in group administration or relay use are logged with enough context to debug.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` nested relay item "NIP-29 relay groups admin interface" under "move some administrative config to the database instead of config file" during TODO-to-Backlog conversion.

Type: AFK.
Blocked by: `TASK-11`, which provides database-backed administrative policy/storage foundation.
Context: future planning should inspect both NIP-29 relay behavior and the selected admin interface approach.
Constraints: use `nips/29.md` as source of truth and do not edit the `nips/` submodule.

<!-- SECTION:NOTES:END -->
