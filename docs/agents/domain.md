# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT-MAP.md`** at the repo root — it points at one `CONTEXT.md` per context. Read each one relevant to the topic.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in. Also check `<project>/docs/adr/` for context-scoped decisions.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

This is a **multi-context** monorepo. Contexts live in the top-level project directories:

```
/
├── CONTEXT-MAP.md                     ← points at per-context CONTEXT.md files
├── docs/adr/                          ← system-wide decisions
├── nostr-lib/
│   ├── CONTEXT.md
│   └── docs/adr/                      ← protocol-library decisions
├── nostr-client/
│   ├── CONTEXT.md
│   └── docs/adr/                      ← client decisions
└── nostr-relay/
    ├── CONTEXT.md
    └── docs/adr/                      ← relay decisions
```

`nips/` and `nak/` are read-only submodules — never write domain docs there. `nips/` is the authoritative protocol spec and outranks local docs on protocol questions.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in the relevant `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_
