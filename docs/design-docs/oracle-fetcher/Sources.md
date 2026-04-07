# Module: Source — Binance

**File:** `src/oracle_fetcher/source/binance.zig`  
**Depends on:** `shared/types`, `config`

## Responsibility

Fetch the latest mid-price for each configured asset from the Binance public REST API. Uses the spot ticker endpoint; if a perp symbol is configured for an asset, fetches both and returns the average.

## Interface

```zig
pub const BinanceSource = struct {
    cfg:        SourceConfig,
    asset_map:  []AssetSymbol,     // asset_id → binance symbol
    http:       AsyncHttp,         // io_uring-backed HTTP client

    pub fn init(cfg: SourceConfig, assets: []AssetConfig, alloc: std.mem.Allocator) !BinanceSource
    pub fn deinit(self: *BinanceSource) void

    /// Issue async HTTP requests for all assets. Returns immediately.
    /// Completions are harvested by the main loop via handleCompletion().
    pub fn fetchAll(self: *BinanceSource, ring: *io_uring) !void

    /// Called by the main loop for each completed io_uring CQE.
    /// Returns a PriceSet if a full response has been parsed, null otherwise.
    pub fn handleCompletion(self: *BinanceSource, cqe: io_uring.CQE) ?RawPriceSet
};
```

## API Endpoints

```
GET https://api.binance.com/api/v3/ticker/bookTicker?symbols=["BTCUSDT","ETHUSDT",...]

Response:
[
  { "symbol": "BTCUSDT", "bidPrice": "50000.00", "askPrice": "50001.00" },
  { "symbol": "ETHUSDT", "bidPrice": "3000.00",  "askPrice": "3000.50"  }
]

mid_price = (bidPrice + askPrice) / 2
```

Batch all symbols in a single request to minimize HTTP round-trips.

## Data Structures

```zig
pub const RawPriceSet = struct {
    source:    []const u8,         // "binance"
    fetched_at: i64,               // unix ms at response receipt
    prices:    []RawPrice,
};

pub const RawPrice = struct {
    asset_id: u32,
    price:    Price,               // mid = (bid + ask) / 2, fixed-point
};
```

## Error Handling

| Condition | Behavior |
|-----------|----------|
| HTTP status != 200 | Log warning, return null — aggregator will note missing source |
| JSON parse failure | Log error with raw body snippet, return null |
| Response > max_age_ms old (clock skew) | Drop and log warning |
| Connection refused / timeout | Exponential backoff on next cycle, increment `oracle_fetch_err_total` |

## Test Harness

```zig
// src/oracle_fetcher/source/binance_test.zig

test "parse valid bookTicker response - returns correct mid prices" {
    const body =
        \\[{"symbol":"BTCUSDT","bidPrice":"50000.00","askPrice":"50002.00"},
        \\  {"symbol":"ETHUSDT","bidPrice":"3000.00","askPrice":"3001.00"}]
    ;
    const result = try BinanceSource.parseResponse(body, &asset_map, std.testing.allocator);

    try std.testing.expectEqual(2, result.prices.len);
    try std.testing.expectEqual(priceFromFloat(50001.0), result.prices[0].price); // BTC mid
    try std.testing.expectEqual(priceFromFloat(3000.5),  result.prices[1].price); // ETH mid
}

test "HTTP 429 rate limit - returns null, increments error counter" {
    var source = try BinanceSource.initWithMockHttp(.{ .status = 429 }, alloc);
    defer source.deinit();

    const result = source.handleCompletion(mock_cqe);
    try std.testing.expectEqual(null, result);
    try std.testing.expectEqual(1, source.metrics.fetch_err_total);
}

test "malformed JSON - returns null without panic" {
    const body = "not json at all }{";
    const result = BinanceSource.parseResponse(body, &asset_map, alloc) catch null;
    try std.testing.expectEqual(null, result);
}

test "missing symbol in response - that asset gets no price" {
    const body = \\[{"symbol":"BTCUSDT","bidPrice":"50000.00","askPrice":"50002.00"}];
    const result = try BinanceSource.parseResponse(body, &two_asset_map, alloc);

    try std.testing.expectEqual(1, result.prices.len); // only BTC, ETH absent
}
```

---

# Module: Source — OKX

**File:** `src/oracle_fetcher/source/okx.zig`  
**Depends on:** `shared/types`, `config`

## Responsibility

Fetch mid-prices from OKX public REST API. OKX uses a different symbol format (`BTC-USDT` vs Binance's `BTCUSDT`) and a different response schema — this module normalizes both to the shared `RawPriceSet` format.

## Interface

Identical to `BinanceSource` — implements the same `Source` interface duck-typed by the `Aggregator`.

```zig
pub const OkxSource = struct {
    pub fn init(cfg: SourceConfig, assets: []AssetConfig, alloc: std.mem.Allocator) !OkxSource
    pub fn deinit(self: *OkxSource) void
    pub fn fetchAll(self: *OkxSource, ring: *io_uring) !void
    pub fn handleCompletion(self: *OkxSource, cqe: io_uring.CQE) ?RawPriceSet
};
```

## API Endpoint

```
GET https://www.okx.com/api/v5/market/tickers?instType=SPOT&instId=BTC-USDT,ETH-USDT

Response:
{
  "code": "0",
  "data": [
    { "instId": "BTC-USDT", "bidPx": "50000.00", "askPx": "50002.00", "ts": "1700000000000" },
    { "instId": "ETH-USDT", "bidPx": "3000.00",  "askPx": "3001.00",  "ts": "1700000000000" }
  ]
}

mid_price = (bidPx + askPx) / 2
```

## Test Harness

```zig
test "parse valid OKX response - returns normalized prices" {
    const body =
        \\{"code":"0","data":[
        \\  {"instId":"BTC-USDT","bidPx":"50000.00","askPx":"50002.00","ts":"1700000000000"}
        \\]}
    ;
    const result = try OkxSource.parseResponse(body, &asset_map, alloc);
    try std.testing.expectEqual(priceFromFloat(50001.0), result.prices[0].price);
}

test "OKX error code non-zero - returns null" {
    const body = \\{"code":"51001","msg":"Instrument ID does not exist"};
    const result = OkxSource.parseResponse(body, &asset_map, alloc) catch null;
    try std.testing.expectEqual(null, result);
}

test "ts field too old - price dropped as stale" {
    const stale_ts = std.time.milliTimestamp() - 10_000; // 10s ago
    const body = std.fmt.allocPrint(alloc,
        \\{{"code":"0","data":[{{"instId":"BTC-USDT","bidPx":"50000","askPx":"50002","ts":"{d}"}}]}}
    , .{stale_ts});
    const result = try OkxSource.parseResponse(body, &asset_map, alloc);
    try std.testing.expectEqual(0, result.prices.len); // stale price dropped
}
```

---

# Module: Source — Bybit

**File:** `src/oracle_fetcher/source/bybit.zig`  
**Depends on:** `shared/types`, `config`

## Responsibility

Fetch mid-prices from Bybit public REST API. Implements the same `Source` interface.

## API Endpoint

```
GET https://api.bybit.com/v5/market/tickers?category=spot&symbol=BTCUSDT

Response (one request per symbol, or use batch):
{
  "result": {
    "list": [
      { "symbol": "BTCUSDT", "bid1Price": "50000.00", "ask1Price": "50002.00" }
    ]
  }
}
```

Note: Bybit's v5 API does not support multi-symbol batch for spot tickers in a single request — issue requests concurrently via `io_uring`, one per asset.

## Test Harness

```zig
test "parse valid Bybit response" {
    const body =
        \\{"retCode":0,"result":{"list":[
        \\  {"symbol":"BTCUSDT","bid1Price":"50000.00","ask1Price":"50002.00"}
        \\]}}
    ;
    const result = try BybitSource.parseResponse(body, &asset_map, alloc);
    try std.testing.expectEqual(priceFromFloat(50001.0), result.prices[0].price);
}

test "retCode non-zero - returns null" {
    const body = \\{"retCode":10001,"retMsg":"params error"};
    const result = BybitSource.parseResponse(body, &asset_map, alloc) catch null;
    try std.testing.expectEqual(null, result);
}

test "concurrent per-symbol requests - all assets collected before emitting PriceSet" {
    // Bybit requires one request per symbol; PriceSet only emitted when all complete
    var source = try BybitSource.initWithMockHttp(.{ .assets = 3 }, alloc);
    defer source.deinit();

    // Simulate 3 completions arriving
    _ = source.handleCompletion(cqe_btc); // 1st asset — returns null
    _ = source.handleCompletion(cqe_eth); // 2nd asset — returns null
    const result = source.handleCompletion(cqe_sol); // 3rd asset — returns full PriceSet

    try std.testing.expect(result != null);
    try std.testing.expectEqual(3, result.?.prices.len);
}
```