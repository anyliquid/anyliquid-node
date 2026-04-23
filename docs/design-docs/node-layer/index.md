# Node Layer Index

The Node layer is the authoritative state machine. The primary execution path is
`clearinghouse`; the older `matching` / `risk` / `perp` engine documents remain
available as legacy prototypes and harness references.

## Documents

- [`overview.md`](overview.md)
- [`consensus-hyperbft.md`](consensus-hyperbft.md)
- [`ipc-server.md`](ipc-server.md)
- [`matching-engine.md`](matching-engine.md)
- [`mempool.md`](mempool.md)
- [`oracle-aggregator.md`](oracle-aggregator.md)
- [`p2p-network.md`](p2p-network.md)
- [`perp-engine.md`](perp-engine.md)
- [`risk-engine.md`](risk-engine.md)
- [`store.md`](store.md)

## Reading Order

1. [`overview.md`](overview.md)
2. [`../impovement/Cleanhouse.md`](../impovement/Cleanhouse.md)
3. [`oracle-aggregator.md`](oracle-aggregator.md)
4. [`mempool.md`](mempool.md)
5. [`store.md`](store.md)
6. [`ipc-server.md`](ipc-server.md)
7. [`p2p-network.md`](p2p-network.md)
8. [`consensus-hyperbft.md`](consensus-hyperbft.md)
9. [`matching-engine.md`](matching-engine.md) (legacy order-book prototype)
10. [`risk-engine.md`](risk-engine.md) (legacy margin prototype)
11. [`perp-engine.md`](perp-engine.md) (legacy perp prototype)
