# Issue tracker: Linear

Issues and PRDs for this repo live as Linear issues. Use the Linear MCP tools for all operations.

## Project

Tickets for this repo are tracked under the Linear project **Nostr**
(<https://linear.app/sgiath/project/nostr-b1bfae9269f0>, team `SGI`).
Always pass this project when creating issues.

Note: this repo also contains a legacy `.backlog/` directory (Backlog.md tasks). The
engineering skills use **Linear** as the issue tracker; treat `.backlog/` as historical
context only unless the user says otherwise.

## Conventions

- **Discover workspace context**: use `list_teams`, `list_issue_statuses`, and `list_issue_labels` when the team, states, or labels are not already known. Creating issues requires a Linear team.
- **Create an issue**: `save_issue` without `id`, passing `title`, `team`, `description`, and the `project` above. Pass `priority`, `labels`, `state`, `parentId`, `blockedBy`, or `blocks` only when known.
- **Read an issue**: `get_issue` with the issue identifier, usually with `includeRelations: true`; then use `list_comments` with `issueId` to fetch discussion.
- **List issues**: `list_issues` with appropriate `team`, `state`, `label`, `project`, `assignee`, `parentId`, or `query` filters. Use `includeArchived: false` unless archived issues are explicitly needed.
- **Comment on an issue**: `save_comment` with `issueId` and Markdown `body`. Use literal newlines in Markdown; do not escape them.
- **Apply / remove labels**: `save_issue` replaces the full label set when `labels` is passed. Read the current issue first, then pass the complete desired label list.
- **Close**: `save_issue` with `id` and the team's done/canceled state. If a closing note is needed, call `save_comment` first.

Linear issue identifiers look like `TEAM-123`. Prefer identifiers over UUIDs in human-facing instructions.

## Relationship to Shortcut

Linear is the personal work tracker (user + agents only) — agents write here freely. Shortcut is the company collaboration hub and is **never** a publish target; it is read-only context. When work originates from a Shortcut story (`sc-XXXXX`), link the story URL from the Linear issue (via `links` or a Parent section in the description). Linear issues with no Shortcut counterpart are normal.

## Pull requests as a triage surface

**PRs as a request surface: no.**

When set to `yes`, PRs can be reviewed through Linear diffs, but feature/request triage should still resolve to Linear issues:

- **Read a PR/diff**: use `list_diffs` to find it, then `get_diff_threads` for review discussion.
- **Create a request from a PR**: create or update a Linear issue with `save_issue`, linking the PR URL via `links`.
- **Comment / label / close the request**: operate on the Linear issue with `save_comment` and `save_issue`.

Bare `#42` references are not Linear identifiers. Ask for the `TEAM-42` identifier or search with `list_issues` if the team or title is known.

## When a skill says "publish to the issue tracker"

Create a Linear issue with `save_issue`.

## When a skill says "fetch the relevant ticket"

Run `get_issue` with `includeRelations: true`, then `list_comments` for the same `issueId`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single Linear issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog description. Create it with `save_issue` and the appropriate team.
- **Child ticket**: a Linear issue with `parentId` set to the map issue identifier. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, assign the ticket to the driving dev.
- **Blocking**: Linear issue relations are canonical. Add blockers with `save_issue` on the child using `blockedBy: ["TEAM-123"]`; add issues it blocks with `blocks: ["TEAM-456"]`. Remove stale blockers with `removeBlockedBy`. A ticket is unblocked when every blocking issue is in a completed or canceled state.
- **Frontier query**: list the map's open children with `list_issues` using `parentId` and active state filters. For each candidate, read it with `get_issue` and `includeRelations: true`; drop any with an open blocker or an assignee. First in map order wins.
- **Claim**: `save_issue` with `id` and `assignee: "me"` - the session's first write.
- **Resolve**: `save_comment` on the child with the answer, then `save_issue` to move it to the team's done state, then update the map issue description with a context pointer in Decisions-so-far.
