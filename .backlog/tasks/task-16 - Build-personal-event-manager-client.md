---
id: TASK-16
title: Build personal event manager client
status: To Do
assignee: []
created_date: "2026-06-13 13:18"
updated_date: "2026-06-13 13:19"
labels:
  - personal-manager
  - client
  - needs-decision
  - from-todo
dependencies: []
references:
  - TODO.md
priority: medium
ordinal: 16000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->

Build a client for viewing a user's events across relays and managing those events through supported Nostr workflows.

<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria

<!-- AC:BEGIN -->

- [ ] #1 A user can connect to configured relays and view their own events from those relays.
- [ ] #2 The client provides at least one safe event management workflow selected during planning.
- [ ] #3 Relay/client failures are surfaced to the user and logged with enough context to debug.
- [ ] #4 Tests cover the initial event loading and management workflow.
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->

Provenance: imported from `TODO.md` personal manager item "client that displays all your events from relays and allows you to manage them" during TODO-to-Backlog conversion.

Type: HITL.
Context: this is a product-scope task and should be planned as a narrow first usable client slice. The phrase "all your events" may need practical bounds around relay selection, pagination, filters, and deletion/update semantics.
Constraints: future planning should inspect existing `nostr-client/` capabilities before choosing UI or workflow shape.

<!-- SECTION:NOTES:END -->
