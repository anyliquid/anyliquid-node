Here is a **clean, direct design spec** for your system, incorporating:

* block-based execution (50–100ms)
* multi-product (spot + perp + options)
* unified risk engine
* zeno as storage backend

---

# 🧠 1. Core Model

> **Deterministic, block-based state machine**

* Orders are processed in **batches (blocks)**
* Each block produces **one atomic state transition**
* State is updated **once per block**, not per order

---

# ⚙️ 2. Execution Pipeline

```text
Ingress → Order Queue → Block Builder → Execute → Validate → Commit → Persist
```

### Block timing

* Interval: **50–100 ms**
* Bounded by:

  * max orders
  * max execution time

---

# 📦 3. Block Structure

```zig
const Block = struct {
    id: u64,
    orders: []Order,
};
```

---

# 🔁 4. Execution Model (Two-Phase)

---

## Phase 1: Execute (no mutation)

* Match orders
* Compute results into a diff

```zig
const StateDiff = struct {
    account_deltas: []AccountDelta,
    position_deltas: []PositionDelta,
    orderbook_deltas: []OrderbookDelta,
};
```

---

## Phase 2: Validate

* Apply diff **virtually**
* Run risk checks per account

```text
if any account violates margin:
    reject offending orders (or fail block)
```

---

## Phase 3: Commit (atomic)

```zig
applyDiff(state, diff)
```

---

# ⚠️ 5. In-Block Risk Control

Must be **incremental**, not only final:

```text
for each order:
    update diff
    run partial risk check
    reject early if unsafe
```

---

# 🧱 6. State Model

---

## Account (unified)

```zig
const Account = struct {
    collateral: i128,
    spot_balances: Map<Asset, i128>,
    perp_positions: Map<MarketId, PerpPosition>,
    option_positions: Map<OptionId, OptionPosition>,
};
```

---

## Product-specific

* Spot → balances
* Perp → size, entry, funding
* Options → strike, expiry, type

---

# 🧠 7. Risk Engine

Global across all products:

```text
equity =
    collateral
  + spot_value
  + perp_pnl
  + option_value

if equity < maintenance_margin:
    liquidation
```

---

# 💾 8. Persistence Design

---

## Source of truth

> **Event WAL (block-based)**

```zig
const BlockLog = struct {
    block_id: u64,
    orders: []Order,
};
```

---

## KV Store (zeno)

Used as **persistent snapshot**, not truth.

---

### Write pattern

* **one write per block**
* batched, shard-parallel

```text
apply diff → writeBatch()
```

---

## Key schema

```text
acct:{id}:collateral

acct:{id}:spot:{asset}
acct:{id}:perp:{market}
acct:{id}:option:{id}

ob:{type}:{market}:{side}:{price}
```

---

# 🔄 9. Data Flow

---

## Per block

```text
collect orders
→ execute (build diff)
→ validate (risk)
→ commit state
→ append WAL
→ async flush to zeno
→ build state root
```

---

# 🌲 10. Merkle / State Root

* computed **per block**
* built from snapshot (async)

```text
global_root
 ├── shard_0_root
 ├── ...
 └── shard_255_root
```

---

# ⚡ 11. Performance Benefits

* no per-order locking
* no per-order disk writes
* batch-friendly (CPU + IO)
* deterministic replay

---

# ⚠️ 12. Tradeoffs

* * throughput

* − latency (50–100ms delay)

* requires:

  * careful ordering
  * incremental risk checks
  * bounded block size

---

# 🧾 13. Final Model

```text
Block-based execution
        +
StateDiff aggregation
        +
Unified risk engine
        +
Event-sourced WAL
        +
Async KV persistence (zeno)
        +
Per-block Merkle root
```
