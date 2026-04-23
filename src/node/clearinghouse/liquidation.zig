const std = @import("std");
const shared = @import("../../shared/mod.zig");
const types = @import("types.zig");
const account = @import("account.zig");
const margin_mod = @import("margin.zig");

/// LiquidationEngine handles scanning, execution, and ADL for liquidatable accounts.
pub const LiquidationEngine = struct {
    allocator: std.mem.Allocator,
    insurance_fund: shared.types.Quantity,
    cfg: types.LiquidationConfig,

    pub fn init(
        alloc: std.mem.Allocator,
        insurance_fund: shared.types.Quantity,
        cfg: types.LiquidationConfig,
    ) LiquidationEngine {
        return .{
            .allocator = alloc,
            .insurance_fund = insurance_fund,
            .cfg = cfg,
        };
    }

    /// Scan all sub-accounts and return liquidation candidates.
    pub fn scanCandidates(
        self: *LiquidationEngine,
        margin_engine: *const margin_mod.MarginEngine,
        masters: *const std.AutoHashMap(shared.types.Address, account.MasterAccount),
        state: *const margin_mod.GlobalState,
    ) ![]types.LiquidationCandidate {
        var candidates = std.ArrayList(types.LiquidationCandidate).empty;
        errdefer candidates.deinit(self.allocator);

        var master_it = masters.iterator();
        while (master_it.next()) |master_entry| {
            const master = master_entry.value_ptr;
            var i: u8 = 0;
            while (i < types.MAX_SUB_ACCOUNTS) : (i += 1) {
                if (master.sub_accounts[i]) |*sub| {
                    if (!hasFreshPricingForAllPositions(sub, state)) continue;
                    const summary = margin_engine.compute(sub, state);
                    if (summary.health == .liquidatable) {
                        const covered_equity: shared.types.Quantity = if (summary.total_equity > 0)
                            @as(shared.types.Quantity, @intCast(summary.total_equity))
                        else
                            0;
                        const deficit = if (summary.maintenance_margin > covered_equity)
                            summary.maintenance_margin - covered_equity
                        else
                            0;

                        var snapshot = std.ArrayList(types.Position).empty;
                        errdefer snapshot.deinit(self.allocator);

                        var pos_it = sub.positions.iterator();
                        while (pos_it.next()) |pos_entry| {
                            try snapshot.append(self.allocator, pos_entry.value_ptr.*);
                        }

                        try candidates.append(self.allocator, .{
                            .user = sub.address,
                            .margin_ratio = summary.margin_ratio,
                            .deficit = deficit,
                            .snapshot = try snapshot.toOwnedSlice(self.allocator),
                        });
                    }
                }
            }
        }

        return try candidates.toOwnedSlice(self.allocator);
    }

    /// Execute liquidation by reducing the largest-risk positions first until the account is healthy
    /// or every position has been fully closed.
    pub fn execute(
        self: *LiquidationEngine,
        _: types.LiquidationCandidate,
        sub: *account.SubAccount,
        margin_engine: *const margin_mod.MarginEngine,
        state: *const margin_mod.GlobalState,
    ) !types.LiquidationResult {
        var total_pnl: shared.types.SignedAmount = 0;
        var liquidation_fee_total: shared.types.Quantity = 0;
        var reduced_notional: shared.types.Quantity = 0;
        var partially_reduced = false;

        if (!hasFreshPricingForAllPositions(sub, state)) return error.MarkPriceUnavailable;

        var summary = margin_engine.compute(sub, state);
        while (summary.health == .liquidatable) {
            const instrument_id = largestRiskPosition(sub, state) orelse break;
            const pos = sub.positions.getPtr(instrument_id) orelse break;
            const mark_px = state.freshMarkPrice(instrument_id) orelse break;
            const size_to_reduce = liquidationSliceSize(pos.size);
            if (size_to_reduce < pos.size) partially_reduced = true;

            total_pnl += realizedPnlForSlice(pos.*, size_to_reduce, mark_px);
            const notional = shared.fixed_point.mulPriceQty(mark_px, size_to_reduce);
            reduced_notional += notional;
            const liq_fee = @divTrunc(notional * @as(shared.types.Quantity, @intCast(self.cfg.liquidation_fee_bps)), 10_000);
            liquidation_fee_total += liq_fee;

            pos.size -= size_to_reduce;
            if (pos.size == 0) {
                _ = sub.positions.remove(instrument_id);
            }
            summary = margin_engine.compute(sub, state);
        }

        const net_pnl = total_pnl - @as(shared.types.SignedAmount, @intCast(liquidation_fee_total));

        if (net_pnl >= 0) {
            // Surplus - credit to insurance fund
            self.insurance_fund += @as(shared.types.Quantity, @intCast(net_pnl));
            if (!sub.hasOpenPositions()) {
                sub.collateral.assets.clearRetainingCapacity();
            }
        } else {
            // Deficit - debit from insurance fund
            const shortfall = @as(shared.types.Quantity, @intCast(-net_pnl));
            if (self.insurance_fund >= shortfall) {
                self.insurance_fund -= shortfall;
            } else {
                const remaining = shortfall - self.insurance_fund;
                self.insurance_fund = 0;
                return .{
                    .insurance_fund_delta = -@as(shared.types.SignedAmount, @intCast(shortfall)),
                    .adl_triggered = true,
                    .adl_shortfall = remaining,
                    .partially_reduced = partially_reduced,
                    .reduced_notional = reduced_notional,
                };
            }
        }

        return .{
            .insurance_fund_delta = net_pnl,
            .adl_triggered = false,
            .adl_shortfall = 0,
            .partially_reduced = partially_reduced,
            .reduced_notional = reduced_notional,
        };
    }

    /// Auto-Deleveraging - reduce opposing positions to cover shortfall.
    pub fn adl(
        self: *LiquidationEngine,
        instrument_id: types.InstrumentId,
        side: types.Side,
        shortfall: shared.types.Quantity,
        masters: *std.AutoHashMap(shared.types.Address, account.MasterAccount),
        state: *const margin_mod.GlobalState,
    ) !types.AdlResult {
        // Collect all opposing positions
        var candidates = std.ArrayList(struct { sub: *account.SubAccount, pos: *types.Position, rank: f64 }).empty;
        defer candidates.deinit();

        var master_it = masters.iterator();
        while (master_it.next()) |master_entry| {
            const master = master_entry.value_ptr;
            var i: u8 = 0;
            while (i < types.MAX_SUB_ACCOUNTS) : (i += 1) {
                if (master.sub_accounts[i]) |*sub| {
                    if (sub.positions.getPtr(instrument_id)) |pos| {
                        // Only consider opposing side positions
                        if (pos.side != side) {
                            if (state.freshMarkPrice(instrument_id)) |mark_px| {
                                const rank = types.adlRank(pos, mark_px);
                                try candidates.append(self.allocator, .{ .sub = sub, .pos = pos, .rank = rank });
                            }
                        }
                    }
                }
            }
        }

        // Sort by rank descending
        std.mem.sort(struct { sub: *account.SubAccount, pos: *types.Position, rank: f64 }, candidates.items, {}, struct {
            fn lessThan(_: void, a: @This(), b: @This()) bool {
                return a.rank > b.rank;
            }
        }.lessThan);

        var reduced: usize = 0;
        var total_reduced: shared.types.Quantity = 0;
        var remaining = shortfall;

        for (candidates.items) |candidate_entry| {
            if (remaining == 0) break;

            const pos = candidate_entry.pos;
            const notional = if (state.freshMarkPrice(instrument_id)) |mark_px|
                shared.fixed_point.mulPriceQty(mark_px, pos.size)
            else
                continue;

            const to_reduce = @min(notional, remaining);
            const size_to_reduce = @max(@as(shared.types.Quantity, 1), @divTrunc(to_reduce * pos.size, notional));

            pos.size -= size_to_reduce;
            remaining -= to_reduce;
            total_reduced += to_reduce;
            reduced += 1;

            if (pos.size == 0) {
                _ = candidate_entry.sub.positions.remove(instrument_id);
            }
        }

        return .{
            .reduced_accounts = reduced,
            .total_reduced = total_reduced,
            .remaining_shortfall = remaining,
        };
    }
};

fn hasFreshPricingForAllPositions(
    sub: *const account.SubAccount,
    state: *const margin_mod.GlobalState,
) bool {
    var it = sub.positions.iterator();
    while (it.next()) |entry| {
        if (state.freshMarkPrice(entry.key_ptr.*) == null) return false;
    }
    return true;
}

fn largestRiskPosition(
    sub: *const account.SubAccount,
    state: *const margin_mod.GlobalState,
) ?types.InstrumentId {
    var best_id: ?types.InstrumentId = null;
    var best_notional: shared.types.Quantity = 0;

    var it = sub.positions.iterator();
    while (it.next()) |entry| {
        const instrument_id = entry.key_ptr.*;
        const mark_px = state.freshMarkPrice(instrument_id) orelse continue;
        const notional = shared.fixed_point.mulPriceQty(mark_px, entry.value_ptr.size);
        if (best_id == null or notional > best_notional) {
            best_id = instrument_id;
            best_notional = notional;
        }
    }

    return best_id;
}

fn liquidationSliceSize(size: shared.types.Quantity) shared.types.Quantity {
    if (size <= 1) return size;
    return @max(@as(shared.types.Quantity, 1), size / 2);
}

fn realizedPnlForSlice(
    pos: types.Position,
    close_size: shared.types.Quantity,
    close_price: shared.types.Price,
) shared.types.SignedAmount {
    const diff: i256 = if (pos.side == .long)
        @as(i256, @intCast(close_price)) - @as(i256, @intCast(pos.entry_price))
    else
        @as(i256, @intCast(pos.entry_price)) - @as(i256, @intCast(close_price));
    return @intCast(@divTrunc(diff * @as(i512, @intCast(close_size)), shared.types.PRICE_SCALE));
}

test "scan finds account below maintenance margin" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 100 * types.USDC, &types.defaultCollateralRegistry);

    // Create a highly leveraged position
    sub.positions.put(1, .{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = sub.address,
        .size = 10,
        .side = .long,
        .entry_price = 100_000,
        .realized_pnl = 0,
        .leverage = 50,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    }) catch {};

    var masters = std.AutoHashMap(shared.types.Address, account.MasterAccount).init(alloc);
    defer masters.deinit();
    try masters.put(master_addr, master);

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(id: types.InstrumentId) ?shared.types.Price {
                _ = id;
                return 90_000; // Price dropped 10%
            }
        }.mark,
    };

    const margin_engine = margin_mod.MarginEngine.init(.{});
    var engine = LiquidationEngine.init(alloc, 0, .{});

    const candidates = try engine.scanCandidates(&margin_engine, &masters, &state);
    defer alloc.free(candidates);

    try std.testing.expect(candidates.len >= 1);
}

test "liquidation surplus - credited to insurance fund" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 10_000 * types.USDC, &types.defaultCollateralRegistry);

    sub.positions.put(1, .{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = sub.address,
        .size = 1,
        .side = .long,
        .entry_price = 90_000,
        .realized_pnl = 0,
        .leverage = 10,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    }) catch {};

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 100_000; // Price increased, profitable position
            }
        }.mark,
    };

    const margin_engine = margin_mod.MarginEngine.init(.{});
    var engine = LiquidationEngine.init(alloc, 0, .{});

    const candidate = types.LiquidationCandidate{
        .user = sub.address,
        .margin_ratio = 0.96,
        .deficit = 0,
        .snapshot = &.{},
    };

    const result = try engine.execute(candidate, sub, &margin_engine, &state);
    try std.testing.expect(result.insurance_fund_delta > 0);
    try std.testing.expect(!result.adl_triggered);
}

test "stale mark price skips liquidation scan" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 5_000 * types.USDC, &types.defaultCollateralRegistry);
    sub.positions.put(1, .{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = sub.address,
        .size = 1,
        .side = .long,
        .entry_price = 100_000,
        .realized_pnl = 0,
        .leverage = 50,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    }) catch {};

    var masters = std.AutoHashMap(shared.types.Address, account.MasterAccount).init(alloc);
    defer masters.deinit();
    try masters.put(master_addr, master);

    const now_ms: i64 = 1_700_000_000_000;
    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 90_000;
            }
        }.mark,
        .markPriceMetaFn = struct {
            fn mark(_: types.InstrumentId) ?margin_mod.MarkPriceView {
                return .{
                    .price = 90_000,
                    .updated_at_ms = 1_700_000_000_000 - 30_000,
                };
            }
        }.mark,
        .now_ms = now_ms,
        .max_mark_price_age_ms = 5_000,
    };

    const margin_engine = margin_mod.MarginEngine.init(.{});
    var engine = LiquidationEngine.init(alloc, 0, .{});
    const candidates = try engine.scanCandidates(&margin_engine, &masters, &state);
    defer alloc.free(candidates);

    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}

test "partial liquidation reduces position before full close" {
    const alloc = std.testing.allocator;
    const master_addr = [_]u8{0xAA} ** 20;
    var master = account.MasterAccount.init(alloc, master_addr, 0);
    defer master.deinit();

    const sub = try master.openSubAccount(0, null, 0);
    try sub.collateral.deposit(types.USDC_ID, 11_000 * types.USDC, &types.defaultCollateralRegistry);
    sub.positions.put(1, .{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = sub.address,
        .size = 2,
        .side = .long,
        .entry_price = 100_000,
        .realized_pnl = 0,
        .leverage = 50,
        .margin_mode = .cross,
        .isolated_margin = 0,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    }) catch {};

    const state = margin_mod.GlobalState{
        .markPriceFn = struct {
            fn mark(_: types.InstrumentId) ?shared.types.Price {
                return 95_000;
            }
        }.mark,
        .now_ms = 0,
    };

    const margin_engine = margin_mod.MarginEngine.init(.{});
    var engine = LiquidationEngine.init(alloc, 0, .{});
    const candidate = types.LiquidationCandidate{
        .user = sub.address,
        .margin_ratio = 0.5,
        .deficit = 0,
        .snapshot = &.{},
    };

    const result = try engine.execute(candidate, sub, &margin_engine, &state);
    try std.testing.expect(result.partially_reduced);
    try std.testing.expect(result.reduced_notional > 0);
    try std.testing.expectEqual(@as(shared.types.Quantity, 1), sub.positions.get(1).?.size);
}

test "ADL ranking - higher profit x leverage reduced first" {
    const pos_a = types.Position{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = [_]u8{1} ** 20,
        .size = 1,
        .side = .short,
        .entry_price = 50_000,
        .realized_pnl = 0,
        .leverage = 10,
        .margin_mode = .isolated,
        .isolated_margin = 1000,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    };

    const pos_b = types.Position{
        .instrument_id = 1,
        .kind = .{ .perp = .{
            .tick_size = 1,
            .lot_size = 1,
            .max_leverage = 50,
            .funding_interval_ms = 3_600_000,
            .mark_method = .oracle,
            .isolated_only = false,
        } },
        .user = [_]u8{2} ** 20,
        .size = 1,
        .side = .short,
        .entry_price = 90_000,
        .realized_pnl = 0,
        .leverage = 20,
        .margin_mode = .isolated,
        .isolated_margin = 5000,
        .funding_index = 0,
        .delta = 0,
        .gamma = 0,
        .vega = 0,
        .theta = 0,
    };

    const mark: shared.types.Price = 100_000;
    try std.testing.expect(types.adlRank(&pos_a, mark) > types.adlRank(&pos_b, mark));
}
