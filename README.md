# AnyLiquid Node

Design repository for the AnyLiquid Node and API stack.

This repository currently serves as a structured design and architecture knowledge base rather than a finished implementation repository. It documents the intended system layout, shared contracts, module responsibilities, harness-driven testing assumptions, and implementation constraints.

## Project Goals

- Target implementation language: `Zig 0.15.2`
- Long-term throughput target: `1,000,000 TPS`
- Keep the Node layer as the single source of truth for execution and consensus
- Scale the API layer horizontally for authenticated writes, cached reads, and realtime streaming
- Prefer mature third-party libraries for cryptography, serialization, parsing, storage, and low-level networking

## Repository Status

The current repository contents are design documents, not production source code.

Use this repository to:

- understand the target system architecture
- review module boundaries and shared contracts
- align implementation work with harness-driven documentation rules
- choose dependency and storage strategies before scaffolding code

## Start Here

1. Read [ARCHITECTURE.md](ARCHITECTURE.md)
2. Read [AGENTS.md](AGENTS.md)
3. Read [docs/design-docs/index.md](docs/design-docs/index.md)

## Documentation Layout

```text
docs/
├── design-docs/
│   ├── api-layer/
│   ├── node-layer/
│   ├── shared/
│   ├── core-beliefs.md
│   └── harness-driven-documentation.md
├── product-specs/
└── references/
```

## Design Areas

- [docs/design-docs/api-layer/index.md](docs/design-docs/api-layer/index.md): REST, WebSocket, auth, gateway, and state cache
- [docs/design-docs/node-layer/index.md](docs/design-docs/node-layer/index.md): matching, risk, perp, oracle, mempool, store, IPC, P2P, and consensus
- [docs/design-docs/shared/shared-contracts.md](docs/design-docs/shared/shared-contracts.md): shared types, protocol framing, crypto, and fixed-point utilities
- [docs/references/dependencies.md](docs/references/dependencies.md): dependency policy and preferred mature libraries

## Working Rules

- `docs/` is the system of record for durable project knowledge.
- When behavior changes, update the relevant design document in the same change.
- All documentation and code comments must be written in English.
- Root-level files should stay short and point into the indexed documentation tree.

## Design Method

This repository follows the documentation pattern described in OpenAI’s Harness Engineering article:

- short root-level entrypoints
- structured domain documentation under `docs/`
- harness-driven module specifications
- explicit shared contracts and cross-links

Reference: [Harness Engineering](https://openai.com/index/harness-engineering/)

## Next Step for Implementation

When code scaffolding starts, the expected first tasks are:

1. define the concrete dependency set for Zig `0.15.2`
2. create the initial source tree and `build.zig` setup
3. implement shared contracts and low-level adapters first
4. wire harness-friendly seams before filling in business logic
