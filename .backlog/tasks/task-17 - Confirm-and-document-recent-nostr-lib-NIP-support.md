---
id: TASK-17
title: Confirm and document recent nostr-lib NIP support
status: Done
assignee: []
created_date: '2026-06-15 08:28'
updated_date: '2026-06-15 08:31'
labels:
  - documentation
dependencies: []
modified_files:
  - nostr-lib/README.md
  - nostr-lib/mix.exs
ordinal: 17000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Verify whether nostr-lib already implements support for NIPs 13, 29, 77, and 98, then update user-facing documentation to accurately reflect the implemented support.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Code inspection confirms whether NIPs 13, 29, 77, and 98 are implemented in nostr-lib.
- [x] #2 nostr-lib README and any directly related documentation list the confirmed NIP support accurately.
- [x] #3 Relevant documentation checks or project checks are run, with any pre-existing failures called out.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Inspect nostr-lib modules/tests for NIP-13, NIP-29, NIP-77, NIP-98 support.
2. Update README support table/module/event documentation with confirmed scope.
3. Update ExDoc grouping for new helper/event modules.
4. Run targeted tests and nostr-lib mix check --fix.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Confirmed implementations: `Nostr.NIP13` covers PoW difficulty, nonce commitment, validation, mining, and mine-and-sign with tests; `Nostr.NIP29` covers relay-based groups kind/tag/validation helpers with tests; NIP-77 support is the negentropy wire-message contract in `Nostr.Message` with parse/serialize tests; `Nostr.Event.HttpAuth` and `Nostr.NIP98` cover HTTP auth event creation/parsing and request semantic validation with tests. README marks NIP-29, NIP-77, and NIP-98 as partial where support is helper/event/wire-message scoped rather than a full relay/application implementation.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Updated nostr-lib documentation to reflect confirmed support for NIP-13, NIP-29, NIP-77, and NIP-98. The README now lists the new NIP support, adds the relevant helper modules and HttpAuth event type, and aligns the dependency snippet with the local 0.2.1 release metadata. ExDoc module grouping now includes the public NIP helper modules and the NIP-98 HttpAuth event module.

Verification: targeted NIP tests passed (119 tests), and `mix check --fix` passed in `nostr-lib` (compiler, formatter, unused_deps, mix_audit, credo, ex_doc, ex_unit, markdown). Optional checks for dialyzer, doctor, gettext, and sobelow were skipped because those packages are not installed.
<!-- SECTION:FINAL_SUMMARY:END -->
