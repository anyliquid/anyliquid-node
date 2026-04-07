# Module: Aggregator

**File:** `src/oracle_fetcher/aggregator.zig`  
**Depends on:** `shared/types`, `config`

## Responsibility

Collect raw price sets from all sources, apply staleness and deviation filters, and produce a single canonical `AggregatePriceSet` per fetch cycle ready for submission. This module contains no I/O — it is a pure function over incoming data.

## Interface

```zig
pub const Aggregator = struct {
    cfg:       AggregatorConfig,
    assets:    []AssetConfig,
    last_submitted: []?Price,   // per asset_id, for deviation guard

    pub fn init(cfg: AggregatorConfig, assets: []AssetConfig, alloc: std.mem.Allocator) Aggregator
    pub fn deinit(self: *Aggregator) void

    /// Called by the main loop each time a source emits a RawPriceSet.
    /// Accumulates prices for the current round.
    pub fn ingest(self: *Aggregator, raw: RawPriceSet) void

    /// Called once per fetch interval after all fetchAll() completions
    /// have been harvested. Returns a submittable price set if the round
    /// passes all guards, or null with a reason if it should be skipped.
    pub fn finalize(self: *Aggregator, now_ms: i64) FinalizeResult

    /// Reset accumulated state for the next round.
    pub fn reset(self: *Aggregator) void
};

pub const FinalizeResult = union(enum) {
    ready:   AggregatePriceSet,
    skip:    SkipReason,
};

pub const SkipReason = enum {
    too_few_sources,       // fewer than min_sources responded
    all_assets_stale,      // every asset failed staleness check
    deviation_exceeded,    // per-asset price moved > max_deviation_pct from last submission
};

pub const AggregatePriceSet = struct {
    prices:     []AssetPrice,   // one per asset, after filtering
    produced_at: i64,           // unix ms
};
```

## Aggregation Pipeline

```
Per fetch round, for each asset:

  1. Staleness filter
       Drop any source price where (now_ms - fetched_at) > max_age_ms.
       Remaining prices: surviving_prices[]

  2. Source count guard
       If len(surviving_prices) < min_sources → mark asset as absent.
       Absent assets are excluded from the submission (not set to 0).

  3. Weighted median
       Sort surviving_prices by value.
       Apply source weights from config (default: all weight = 1 → simple median).
       result = weightedMedian(surviving_prices, weights)

  4. Deviation guard
       If last_submitted[asset_id] exists:
         deviation = abs(result - last_submitted) / last_submitted
         If deviation > max_deviation_pct → mark asset as suspect, log warning.
         Suspect assets are included with a flag; submitter decides whether to hold.

  5. If zero assets survived → return skip(all_assets_stale)
     If surviving asset count < min_submittable_assets → return skip(too_few_sources)
     Otherwise → return ready(AggregatePriceSet)
```

## Weighted Median

```zig
pub fn weightedMedian(prices: []const SourcPrice, weights: []const f64) Price {
    // Sort by price ascending
    // Compute cumulative weight
    // Return price at which cumulative weight crosses 0.5 of total weight
    var sorted = prices; // caller ensures sorted
    var total: f64 = 0;
    for (weights) |w| total += w;

    var cumulative: f64 = 0;
    for (sorted, 0..) |sp, i| {
        cumulative += weights[i];
        if (cumulative >= total / 2.0) return sp.price;
    }
    return sorted[sorted.len - 1].price;
}
```

## Test Harness

```zig
// src/oracle_fetcher/aggregator_test.zig

test "three sources agree - median returned" {
    var agg = Aggregator.init(test_cfg, test_assets, alloc);
    defer agg.deinit();

    agg.ingest(rawSet("binance", .{ .btc = 50000 }));
    agg.ingest(rawSet("okx",     .{ .btc = 50100 }));
    agg.ingest(rawSet("bybit",   .{ .btc = 49900 }));

    const result = agg.finalize(now_ms);
    try std.testing.expect(result == .ready);
    try std.testing.expectEqual(priceFromFloat(50000), result.ready.prices[0].price);
}

test "one source stale - excluded from median" {
    var agg = Aggregator.init(test_cfg, test_assets, alloc);
    defer agg.deinit();

    agg.ingest(rawSet("binance", .{ .btc = 50000 }, fetched_at: now_ms - 5000)); // stale
    agg.ingest(rawSet("okx",     .{ .btc = 50100 }, fetched_at: now_ms));
    agg.ingest(rawSet("bybit",   .{ .btc = 50200 }, fetched_at: now_ms));

    const result = agg.finalize(now_ms);
    try std.testing.expect(result == .ready);
    // median of [50100, 50200] = 50150, binance excluded
    try std.testing.expectEqual(priceFromFloat(50150), result.ready.prices[0].price);
}

test "only one source responds - skip if min_sources = 2" {
    var agg = Aggregator.init(.{ .min_sources = 2 }, test_assets, alloc);
    defer agg.deinit();

    agg.ingest(rawSet("binance", .{ .btc = 50000 }));
    // okx and bybit did not respond

    const result = agg.finalize(now_ms);
    try std.testing.expect(result == .skip);
    try std.testing.expectEqual(.too_few_sources, result.skip);
}

test "price deviation exceeds threshold - asset flagged" {
    var agg = Aggregator.init(.{ .max_deviation_pct = 2.0 }, test_assets, alloc);
    agg.last_submitted[0] = priceFromFloat(50000); // BTC last submitted at 50000
    defer agg.deinit();

    // All sources now report 55000 — 10% deviation
    agg.ingest(rawSet("binance", .{ .btc = 55000 }));
    agg.ingest(rawSet("okx",     .{ .btc = 55000 }));
    agg.ingest(rawSet("bybit",   .{ .btc = 55000 }));

    const result = agg.finalize(now_ms);
    // Still submitted (large moves are valid), but flagged for monitoring
    try std.testing.expect(result == .ready);
    try std.testing.expect(result.ready.prices[0].deviation_flagged);
}

test "all sources fail - skip(all_assets_stale)" {
    var agg = Aggregator.init(test_cfg, test_assets, alloc);
    defer agg.deinit();
    // No ingest() calls

    const result = agg.finalize(now_ms);
    try std.testing.expect(result == .skip);
    try std.testing.expectEqual(.all_assets_stale, result.skip);
}

test "weighted median - higher-weight source breaks tie toward its value" {
    var cfg = test_cfg;
    cfg.source_weights = &.{
        .{ .source = "binance", .weight = 2 },
        .{ .source = "okx",     .weight = 1 },
        .{ .source = "bybit",   .weight = 1 },
    };
    var agg = Aggregator.init(cfg, test_assets, alloc);
    defer agg.deinit();

    agg.ingest(rawSet("binance", .{ .btc = 50000 })); // weight 2
    agg.ingest(rawSet("okx",     .{ .btc = 50400 })); // weight 1
    agg.ingest(rawSet("bybit",   .{ .btc = 50200 })); // weight 1

    const result = agg.finalize(now_ms);
    // Effective samples: [50000, 50000, 50200, 50400]
    // Weighted median = 50100 (midpoint of the two middle values)
    try std.testing.expect(result == .ready);
    try std.testing.expectEqual(priceFromFloat(50100), result.ready.prices[0].price);
}
```

---

# Module: Submitter

**File:** `src/oracle_fetcher/submitter.zig`  
**Depends on:** `shared/types`, `shared/protocol`, `shared/crypto`

## Responsibility

Sign an `AggregatePriceSet` with the validator's agent key and deliver it to the Node as a signed `OracleSubmission` action. The delivery is fire-and-forget — the fetcher does not wait for an ACK from the Node. If the IPC connection is unavailable, the submitter buffers the latest price set and retries on reconnect.

## Interface

```zig
pub const Submitter = struct {
    agent_key:   ScalarPrivateKey,     // secp256k1, used for ECDSA signing
    ipc:         IpcConn,              // connection to the Node
    pending:     ?AggregatePriceSet,   // buffer if IPC is down
    nonce_base:  u64,                  // last submitted nonce (unix ms)
    metrics:     *Metrics,

    pub fn init(
        agent_key:     ScalarPrivateKey,
        node_ipc_path: []const u8,
        metrics:       *Metrics,
        alloc:         std.mem.Allocator,
    ) !Submitter

    pub fn deinit(self: *Submitter) void

    /// Sign and send. Returns immediately; does not wait for Node ACK.
    /// If IPC is down, buffers prices and returns error.NodeUnavailable.
    pub fn submit(self: *Submitter, prices: AggregatePriceSet) !void

    /// Called by the main loop on each IPC reconnect.
    /// Flushes any buffered price set (discards if a newer one has arrived).
    pub fn flushPending(self: *Submitter) void

    pub fn isConnected(self: *Submitter) bool
};
```

## Signing

The `OracleSubmission` action is signed with the same EIP-712 mechanism used for all exchange actions, making it indistinguishable from the Node's perspective:

```zig
pub fn buildAndSign(
    self:      *Submitter,
    prices:    AggregatePriceSet,
    now_ms:    i64,
) !Transaction {
    const action = OracleSubmissionAction{
        .type   = "oracleSubmission",
        .prices = prices.prices,
    };

    const action_hash = eip712.hashAction(action);
    const sig         = secp256k1.sign(action_hash, self.agent_key);

    return Transaction{
        .action    = .{ .oracle_submission = action },
        .nonce     = @intCast(now_ms),
        .signature = sig,
        .user      = addressFromKey(self.agent_key),
    };
}
```

## Buffering Policy

Only the **most recent** price set is buffered. If the IPC connection is down for multiple fetch cycles, older sets are discarded — submitting stale prices after reconnection would be worse than submitting nothing.

```zig
pub fn submit(self: *Submitter, prices: AggregatePriceSet) !void {
    const tx = try self.buildAndSign(prices, std.time.milliTimestamp());

    if (!self.ipc.isConnected()) {
        self.pending = prices; // overwrite any older buffered set
        self.metrics.submission_skipped_total += 1;
        return error.NodeUnavailable;
    }

    try self.ipc.writeFrame(.{
        .msg_id = 0,                  // fire-and-forget, no reply expected
        .msg_type = .action_req,
        .payload  = msgpack.encode(tx),
    });

    self.pending = null;
    self.nonce_base = tx.nonce;
    self.metrics.submission_total += 1;
}
```

## Test Harness

```zig
// src/oracle_fetcher/submitter_test.zig

test "submit - IPC frame contains correctly signed action" {
    var mock_ipc = MockIpc.init();
    var sub = try Submitter.initWithMock(&mock_ipc, test_agent_key, alloc);
    defer sub.deinit();

    try sub.submit(sample_price_set);

    const frame = mock_ipc.lastWritten();
    const tx    = msgpack.decode(Transaction, frame.payload);

    // Verify the signature recovers to the agent address
    const signer = try secp256k1.ecrecover(
        eip712.hashAction(tx.action),
        tx.signature,
    );
    try std.testing.expectEqual(addressFromKey(test_agent_key), signer);
}

test "submit - nonce equals unix ms at submission time" {
    var mock_ipc = MockIpc.init();
    var sub = try Submitter.initWithMock(&mock_ipc, test_agent_key, alloc);
    defer sub.deinit();

    const before = std.time.milliTimestamp();
    try sub.submit(sample_price_set);
    const after = std.time.milliTimestamp();

    const frame = mock_ipc.lastWritten();
    const tx    = msgpack.decode(Transaction, frame.payload);
    try std.testing.expect(tx.nonce >= before and tx.nonce <= after);
}

test "IPC unavailable - buffers latest prices" {
    var mock_ipc = MockIpc.init();
    mock_ipc.setConnected(false);

    var sub = try Submitter.initWithMock(&mock_ipc, test_agent_key, alloc);
    defer sub.deinit();

    try std.testing.expectError(error.NodeUnavailable, sub.submit(sample_price_set_a));
    try std.testing.expect(sub.pending != null);
    try std.testing.expectEqual(1, sub.metrics.submission_skipped_total);
}

test "IPC unavailable then reconnects - flushes most recent buffered set" {
    var mock_ipc = MockIpc.init();
    mock_ipc.setConnected(false);

    var sub = try Submitter.initWithMock(&mock_ipc, test_agent_key, alloc);
    defer sub.deinit();

    _ = sub.submit(sample_price_set_old) catch {};   // buffered
    _ = sub.submit(sample_price_set_new) catch {};   // overwrites older

    mock_ipc.setConnected(true);
    sub.flushPending();

    const frame = mock_ipc.lastWritten();
    const tx    = msgpack.decode(Transaction, frame.payload);
    // Should have sent the newer price set, not the older one
    try std.testing.expectEqual(
        sample_price_set_new.prices[0].price,
        tx.action.oracle_submission.prices[0].price,
    );
    try std.testing.expectEqual(null, sub.pending);
}

test "successive submits increment nonce monotonically" {
    var mock_ipc = MockIpc.init();
    var sub = try Submitter.initWithMock(&mock_ipc, test_agent_key, alloc);
    defer sub.deinit();

    try sub.submit(sample_price_set_a);
    std.time.sleep(2 * std.time.ns_per_ms); // ensure ms advances
    try sub.submit(sample_price_set_b);

    const frames = mock_ipc.allWritten();
    const nonce_a = msgpack.decode(Transaction, frames[0].payload).nonce;
    const nonce_b = msgpack.decode(Transaction, frames[1].payload).nonce;
    try std.testing.expect(nonce_b > nonce_a);
}
```