# Node Layer Architecture

The Node layer is the core state machine of the system. It runs as a single authoritative process for local execution, owns all canonical state, and never exposes HTTP directly. It communicates with the API layer over IPC and with peer validators over P2P.

The repository-wide documentation contract is defined in [`../harness-driven-documentation.md`](../harness-driven-documentation.md).

Execution note: account mutation, margining, liquidation, funding settlement,
and collateral accounting are now clearinghouse-first concerns. The standalone
`Matching Engine` / `Risk Engine` / `Perp Engine` documents below should be read
as legacy prototypes unless a document explicitly says otherwise.

```text
┌─────────────────────────────────────────────────────────────┐
│                        Node Process                        │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                    IPC Server                         │  │
│  │ Receives API actions and queries, pushes Node events  │  │
│  └──────────────────────────┬────────────────────────────┘  │
│                             │                               │
│  ┌──────────────────────────▼────────────────────────────┐  │
│  │                 Execution Pipeline                    │  │
│  │                                                       │  │
    │  │ Mempool -> Block Proposal -> Matching Engine          │  │
    │  │                               -> Clearinghouse        │  │
    │  │                               -> Oracle / Timers      │  │
│  └──────────────────────────┬────────────────────────────┘  │
│                             │                               │
│         ┌───────────────────┼───────────────────┐           │
│         ▼                   ▼                   ▼           │
│   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐   │
│   │ Consensus    │   │ Oracle       │   │ Store        │   │
│   │ HyperBFT     │   │ Aggregator   │   │ Block+State  │   │
│   └──────┬───────┘   └──────────────┘   └──────────────┘   │
│          │                                                  │
└──────────┼──────────────────────────────────────────────────┘
           │
     P2P Network Layer
           │
     Other Validator Nodes
```

## Execution Model

The Node layer follows a **single-threaded main loop plus `io_uring` async I/O** design:

```text
loop {
    1. harvest completed I/O events
    2. process IPC messages from API processes
    3. process P2P messages from peers
    4. advance the consensus state machine
    5. if leader, package mempool transactions into a block proposal
    6. execute committed blocks
    7. emit events back to API clients
    8. run timers for funding and oracle updates
}
```

Matching and execution within a block are synchronous and deterministic.

The implementation target is `Zig 0.15.2`. Performance-oriented design decisions in this layer should be judged against the long-term requirement of reaching `1,000,000 TPS`.

## Module Map

| Module | Document | Responsibility |
| --- | --- | --- |
| IPC Server | [`ipc-server.md`](ipc-server.md) | receive API actions and queries, push Node events |
| Clearinghouse | [`../impovement/Cleanhouse.md`](../impovement/Cleanhouse.md) | canonical account mutation, margin, liquidation, funding, collateral |
| Matching Engine | [`matching-engine.md`](matching-engine.md) | legacy order-book prototype; maintain books and produce fills |
| Risk Engine | [`risk-engine.md`](risk-engine.md) | legacy margin prototype |
| Perp Engine | [`perp-engine.md`](perp-engine.md) | legacy perp prototype |
| Oracle Aggregator | [`oracle-aggregator.md`](oracle-aggregator.md) | aggregate external prices |
| Consensus | [`consensus-hyperbft.md`](consensus-hyperbft.md) | HyperBFT voting and finality |
| P2P Network | [`p2p-network.md`](p2p-network.md) | gossip, peer communication, block sync |
| Store | [`store.md`](store.md) | block persistence, state roots, proofs |
| Mempool | [`mempool.md`](mempool.md) | queued transactions for proposers |
| Shared Contracts | [`../shared/shared-contracts.md`](../shared/shared-contracts.md) | shared types and IPC contracts |

## Global State

```zig
pub const GlobalState = struct {
    order_books:     []OrderBook,
    accounts:        AccountTable,
    oracle_prices:   OraclePriceTable,
    funding_history: FundingHistory,
    block_height:    u64,
    state_root:      [32]u8,
    timestamp:       i64,
};
```

## Block Execution Order

Within a block, operations execute in this order:

1. oracle price updates
2. funding settlement, if due
3. user actions in mempool order
4. system-triggered liquidation checks

## Harness Entry Points

Node-layer docs should support:

- `TestCluster` for consensus, leadership rotation, and Byzantine behavior
- `TestNode` for local execution, block production, IPC queries, and event emission
- fake oracle data and fake clocks for time-based transitions
- temporary directories or mock stores for recovery and state-root tests

## Performance Targets

| Metric | Target |
| --- | --- |
| End-to-end throughput design target | 1,000,000 transactions per second |
| Matching throughput target | 1,000,000 orders per second |
| Block time | < 1 second |
| Consensus finality | < 500 ms P99 |
| State update latency | < 100 us per order |
