# Module: Matching Engine

Status: legacy order-book prototype retained for harness coverage and isolated
matching tests. Canonical account mutation now lives in the clearinghouse path.

**File:** `src/node/engine/matching.zig`  
**Depends on:** `shared/types`, `store` (read-only), `risk` (pre-fill hook)

## Responsibilities

- Maintain a bid and ask order book per asset
- Match limit and market-style orders using price-time priority
- Implement `post-only`, `IOC`, and `FOK` semantics
- Manage trigger orders such as stop-market, stop-limit, and TP/SL variants
- Invoke `RiskEngine` before every fill

Current implementation note:

- `asset_id` is `u64`
- `price` is `u256` and must be a multiple of `10^36`
- `amount` / `size` is `u128`
- the current engine uses sorted per-side order id arrays plus an order map, which preserves price-time priority while staying simple enough for harness-driven testing

## Interface

```zig
pub const MatchingEngine = struct {
    allocator: std.mem.Allocator,
    books:     std.AutoHashMap(AssetId, OrderBook),
    risk:      *RiskEngine,

    pub fn init(risk: *RiskEngine, alloc: std.mem.Allocator) !MatchingEngine
    pub fn deinit(self: *MatchingEngine) void
    pub fn placeOrder(self: *MatchingEngine, order: Order, state: *GlobalState) ![]Fill
    pub fn cancelOrder(self: *MatchingEngine, cancel: CancelRequest, state: *GlobalState) !void
    pub fn cancelByCloid(self: *MatchingEngine, req: CancelByCloidRequest, state: *GlobalState) !void
    pub fn batchCancel(self: *MatchingEngine, user: Address, req: BatchCancelRequest, state: *GlobalState) !usize
    pub fn cancelAll(self: *MatchingEngine, user: Address, req: CancelAllRequest, state: *GlobalState) !usize
    pub fn checkTriggers(self: *MatchingEngine, asset_id: AssetId, price: Price, state: *GlobalState) ![]Fill
    pub fn getL2Snapshot(self: *MatchingEngine, asset_id: AssetId, depth: u32) !L2Snapshot
};
```

## Order Book Structures

```zig
pub const OrderBook = struct {
    asset_id:  AssetId,
    bids:      std.ArrayList(u64),
    asks:      std.ArrayList(u64),
    triggers:  std.ArrayList(u64),
    orders:    std.AutoHashMap(u64, BookOrder),
    cloid_map: CloidMap,
    seq:       u64,
};

pub const BookOrder = struct {
    id:         u64,
    user:       Address,
    asset_id:   AssetId,
    is_buy:     bool,
    price:      Price,
    remaining:  Quantity,
    order_type: OrderType,
    cloid:      ?[16]u8,
    placed_seq: u64,
};
```

## Matching Loop

```zig
fn matchAgainstBook(
    book: *OrderBook,
    taker: *OrderEntry,
    state: *GlobalState,
    fills: *FillList,
) !void {
    const maker_side = if (taker.is_buy) &book.asks else &book.bids;

    while (taker.remaining > 0 and maker_side.items.len > 0) {
        const maker_id = maker_side.items[0];
        const maker = book.orders.getPtr(maker_id).?;

        if (taker.is_buy and taker.price < maker.order.price) break;
        if (!taker.is_buy and taker.price > maker.order.price) break;

        const fill_size = @min(taker.remaining, maker.remaining);
        try risk.onFill(&taker.order, &maker.order, fill_size, maker.order.price, state);
        taker.remaining -= fill_size;
        maker.remaining -= fill_size;

        if (maker.remaining == 0) {
            try removeOrder(book, maker_id);
        }
    }
}
```

## Order Types

```zig
pub const OrderType = union(enum) {
    limit: struct {
        tif: TimeInForce,
    },
    trigger: struct {
        trigger_px: Price,
        is_market:  bool,
        tpsl:       TpslType,
    },
};

fn handleAlo(book: *OrderBook, order: *OrderEntry) !void {
    if (wouldCrossSpread(book, order)) {
        return error.WouldTakeNotPost;
    }
    insertIntoBook(book, order);
}
```

## Test Harness

```zig
// tests/engine_test.zig

test "crossing limit orders produce a fill" {
    var engine = try MatchingEngine.init(&risk, alloc);
    defer engine.deinit();

    _ = try engine.placeOrder(makeSell(.{ .price = 100, .size = 1 }), &state);
    const fills = try engine.placeOrder(makeBuy(.{ .price = 100, .size = 1 }), &state);

    try std.testing.expectEqual(@as(usize, 1), fills.len);
}

test "price-time priority fills the older maker first" {
    var engine = try MatchingEngine.initTest(alloc);
    defer engine.deinit();

    const maker1_id = 1001;
    const maker2_id = 1002;
    _ = try engine.placeOrder(makeSell(.{ .id = maker1_id, .price = 100, .size = 1, .time = 1000 }), &state);
    _ = try engine.placeOrder(makeSell(.{ .id = maker2_id, .price = 100, .size = 1, .time = 2000 }), &state);

    const fills = try engine.placeOrder(makeBuy(.{ .price = 100, .size = 1 }), &state);
    try std.testing.expectEqual(1, fills.len);
    try std.testing.expectEqual(maker1_id, fills[0].maker_order_id);
}

test "post-only order that would cross is rejected" {
    var engine = try MatchingEngine.initTest(alloc);
    defer engine.deinit();

    _ = try engine.placeOrder(makeSell(.{ .price = 100, .size = 1 }), &state);

    try std.testing.expectError(
        error.WouldTakeNotPost,
        engine.placeOrder(makeBuy(.{ .price = 100, .size = 1, .tif = .Alo }), &state),
    );
}

test "IOC, FOK, ALO, triggers, and the benchmark harness are covered in integration tests" {}
```

## Performance Notes

- The current benchmark lives in `tests/engine_test.zig` and measures bulk maker insertion plus a large taker match in a debug build.
- The current data structures favor determinism and debuggability over absolute throughput; a later pass can replace side arrays with trees or heaps without changing the harness contract.
