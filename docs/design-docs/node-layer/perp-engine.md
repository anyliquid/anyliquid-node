# Module: Perp Engine

Status: legacy perp prototype. The clearinghouse perp unit is the active design
for funding settlement, price protection, and liquidation integration.

**File:** `src/node/engine/perp.zig`  
**Depends on:** `shared/types`, `oracle`

## Responsibilities

- Calculate and settle funding rates on a fixed cadence
- Maintain mark prices
- Maintain index prices sourced from the oracle layer
- Calculate unrealized PnL from mark prices
- Own the liquidation center queue, insurance fund, and ADL fallback metrics for perp trading

Current implementation note:

- `PerpEngine` now exposes a concrete `LiquidationCenter`
- `asset_id` is `u64`, `price` is scaled `u256`, and `amount` is `u128`

## Interface

```zig
pub const PerpEngine = struct {
    liquidation_center: LiquidationCenter,

    pub fn init(alloc: std.mem.Allocator) PerpEngine
    pub fn calcFundingRate(self: *PerpEngine, asset_id: AssetId, state: *GlobalState) FundingRate
    pub fn settleFunding(self: *PerpEngine, asset_id: AssetId, state: *GlobalState) !FundingEvent
    pub fn updateMarkPrice(self: *PerpEngine, asset_id: AssetId, state: *GlobalState) void
    pub fn updateMarkPriceFromBook(self: *PerpEngine, asset_id: AssetId, best_bid: ?Price, best_ask: ?Price, state: *GlobalState) void
    pub fn unrealizedPnl(pos: *const Position, mark_px: Price) SignedAmount
};

pub const LiquidationCenter = struct {
    insurance_fund: SignedAmount,
    adl_invocations: u64,

    pub fn enqueue(self: *LiquidationCenter, event: LiquidationEvent) !void
    pub fn queued(self: *const LiquidationCenter) []const LiquidationEvent
    pub fn execute(self: *LiquidationCenter, event: LiquidationEvent, entry_price: Price) LiquidationOutcome
};
```

## Funding Formula

```text
basis premium = (mark price - index price) / index price
funding rate = clamp(basis premium + interest basis (0.01%), -0.05%, 0.05%)

settlement:
  longs pay = position notional * funding rate      when rate > 0
  shorts pay = position notional * abs(funding rate) when rate < 0
```

## Mark Price

```zig
pub fn calcMarkPrice(book: *const OrderBook, index_px: Price) Price {
    const mid = bookMidPrice(book);
    const basis = mid - index_px;
    const max_dev = index_px * 0.005;
    const clamped = std.math.clamp(basis, -max_dev, max_dev);
    return index_px + clamped;
}
```

## Test Harness

```zig
test "positive funding means longs pay shorts" {
    const state = testStateWithPrices(.{ .mark = 50500, .index = 50000 });
    var perp = PerpEngine.init(alloc);

    const event = try perp.settleFunding(0, &state);
    try std.testing.expect(event.long_payment > 0);
}

test "funding rate is clamped at 0.05%" {
    const state = testStateWithPrices(.{ .mark = 60000, .index = 50000 });
    var perp = PerpEngine.init(alloc);

    const rate = perp.calcFundingRate(0, &state);
    try std.testing.expectApproxEqAbs(0.0005, rate.value, 1e-9);
}

test "mark price stays within +/-0.5% of index" {
    const book = testBook(.{ .best_bid = 50400, .best_ask = 50600 });
    const mark = calcMarkPrice(&book, 50000);
    try std.testing.expect(mark <= 50000 * 1.005);
    try std.testing.expect(mark >= 50000 * 0.995);
}
```
