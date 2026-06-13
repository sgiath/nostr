---
id: TASK-7
title: Handle NIP-88 relay vote and backdating rules
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
  - nips/88.md
priority: medium
ordinal: 7000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Update relay behavior for NIP-88 so vote events are retained correctly and backdated event handling can be configured.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 Relay does not delete NIP-88 vote events of kind 1018 when processing relevant cleanup or replacement behavior.
- [ ] #2 Backdated event handling is configurable where NIP-88 requires policy flexibility.
- [ ] #3 Tests cover vote retention and configured backdated-event behavior.
- [ ] #4 Policy decisions and unexpected rejection paths are logged with enough context to debug.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` relay item "NIP-88: do not delete votes (kind 1018) and make backdated events configurable" during TODO-to-Backlog conversion.

Type: AFK.
Context: this task contains two explicit behavioral requirements from the TODO line: preserve kind 1018 votes and make backdated event handling configurable.
Constraints: use `nips/88.md` as source of truth and inspect current event deletion/replacement paths before planning.

<!-- SECTION:NOTES:END -->
