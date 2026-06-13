---
id: TASK-11
title: Move relay administrative policy config into database
status: To Do
assignee: []
created_date: "2026-06-13 13:17"
updated_date: "2026-06-13 13:17"
labels:
  - relay
  - admin
  - database
  - needs-planning
  - from-todo
dependencies: []
references:
  - TODO.md
priority: medium
ordinal: 11000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Move relay administrative policy configuration that currently belongs in static config into database-backed storage so it can be managed at runtime.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 A database-backed model exists for relay administrative policy settings that should no longer live only in config files.
- [ ] #2 Runtime relay code reads the administrative policy from the database-backed source with a clear fallback or migration behavior.
- [ ] #3 Changes include tests for loading, missing data, and persistence behavior.
- [ ] #4 Operational failures during policy loading or persistence are logged with enough context to debug.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` relay item "move some administrative config to the database instead of config file" during TODO-to-Backlog conversion.

Type: AFK.
Context: this is the shared persistence foundation for follow-up admin tasks covering pubkey/IP allow-deny lists and NIP-29 relay groups admin UI.
Constraints: future planning should inspect current relay config, persistence, and migration conventions before implementation.

<!-- SECTION:NOTES:END -->
