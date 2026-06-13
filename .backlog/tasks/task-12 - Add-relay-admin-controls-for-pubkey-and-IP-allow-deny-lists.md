---
id: TASK-12
title: Add relay admin controls for pubkey and IP allow/deny lists
status: To Do
assignee: []
created_date: "2026-06-13 13:17"
updated_date: "2026-06-13 13:17"
labels:
  - relay
  - admin
  - policy
  - needs-planning
  - from-todo
dependencies:
  - TASK-11
references:
  - TODO.md
priority: medium
ordinal: 12000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Add administrative controls for relay pubkey and IP allow/deny lists using database-backed policy storage.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 Administrators can manage pubkey allow/deny entries through the chosen admin surface or API.
- [ ] #2 Administrators can manage IP allow/deny entries through the chosen admin surface or API.
- [ ] #3 Relay policy enforcement reads the database-backed allow/deny lists consistently.
- [ ] #4 Tests cover create/update/delete behavior and relay enforcement for allowed and denied pubkeys and IP addresses.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` nested relay item "whitelist/blacklist pubkeys and IP addresses" under "move some administrative config to the database instead of config file" during TODO-to-Backlog conversion.

Type: AFK.
Blocked by: `TASK-11`, which provides database-backed administrative policy storage.
Context: terminology in the task title uses allow/deny lists while preserving the original TODO wording in provenance.
Constraints: future planning should align the admin surface with broader relay admin interface decisions.

<!-- SECTION:NOTES:END -->
